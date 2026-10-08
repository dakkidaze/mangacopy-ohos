/**
 * NetStatus：网络状态探测（独立模块，与阅读器解耦、可复用）。
 *
 * 背景：`connection.getDefaultNet()` / `getNetCapabilities()` 在真机上"已授权仍抛 201"——
 * 系统侧异常（社区同类案例无解），短期修不了；而且它还要 `GET_NETWORK_INFO`。
 * 这里改用两个**不需要该权限**的信号：
 *
 *   ① `wifiManager.isWifiActive()` —— 本地 Wi-Fi 开关状态（`GET_WIFI_INFO`，装机即授权）；
 *   ② 向**境内 `generate_204` 端点**发一个极小 HTTP 请求 —— `@ohos.net.http` **只吃 `INTERNET`**。
 *
 * 设计约束（对应实测 bug「本地缓存显示无网络」）：
 * - 可达性结果带 **TTL 缓存**（成功 45s / 失败 15s）与 **2.5s 超时**，并把并发请求合并成一个 in-flight
 *   Promise —— 阅读器 4 秒刷新节拍里**绝不会裸发请求**，最坏也是"每 45s 一次、且是补上次的过期"；
 * - **不看本地章节/离线模式**：网络状态只由真实探测决定，本地图不参与判定；
 * - 未知即保守：探测没跑完、或抛的是配置/权限类错误 → 返回 `null`（调用方省略该段），
 *   **绝不把"没测出来"显示成"无网络"**；
 * - 日志一律 `Collector` tag，只在状态跳变 / 首次失败时各打一条（稀疏）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 一次探测的原始信号。
 * `null` 表示「未知 / 未完成 / 出错」，**不是** `false`，调用方必须区别对待。
 */
export interface NetStatusSnapshot {
  /** Wi-Fi 开关是否打开；查询失败为 null。 */
  wifiActive: boolean | null;
  /** 互联网是否可达（generate_204 探测）；未完成/异常为 null。 */
  reachable: boolean | null;
}

/**
 * 可达性端点（按优先级，全为境内门户的 generate_204，且用 **https** 以避开
 * `2300997 Cleartext traffic not permitted` 之类的明文限制）。
 *
 * 选点依据（已在本机 curl 实测，均回 204、~20–45ms）：
 *  1. `connectivitycheck.platform.hicloud.com` —— 华为自家连通性检查端点，HarmonyOS/EMUI 设备的
 *     Wi-Fi 可达性就用它，境内可达性最好，作为首选；
 *  2. `connect.rom.miui.com` —— MIUI 的同类端点，覆盖非华为设备的常用兜底；
 *  3. `wifi.vivo.com.cn` —— vivo 的同类端点，再兜一层。
 * 任一端点收到 HTTP 响应即判可达；全部传输层失败才判不可达。
 * （若实测发现首选端点在某些运营商网络被劫持/不通，只需改这张表，调用方无感。）
 */
const PROBE_ENDPOINTS: string[] = [
  'https://connectivitycheck.platform.hicloud.com/generate_204',
  'https://connect.rom.miui.com/generate_204',
  'https://wifi.vivo.com.cn/generate_204'
];

/** 探测成功的缓存时长：4s 节拍下约每 45s 才补一发。 */
const REACH_TTL_OK_MS: number = 45000;
/** 探测失败（含异常）的缓存时长：短一些，网络刚恢复时能更快翻回"有网"。 */
const REACH_TTL_FAIL_MS: number = 15000;
/** 单次探测的连接/读取超时（规格要求 2–3s）。 */
const PROBE_TIMEOUT_MS: number = 2500;

/**
 * 判「确实不可达」的传输层错误码（@ohos.net.http 的 @throws）：
 * 2300006 解析主机失败 / 2300007 连接失败 / 2300028 超时 / 2300052 服务器无响应 /
 * 2300055 发送失败 / 2300056 接收失败 / 2300008 服务器响应非法。
 * 其余（401 参数、201 权限、2300001 协议不支持、2300997 明文被禁…）一律按「未知」保守处理。
 */
const UNREACHABLE_CODES: number[] = [2300006, 2300007, 2300008, 2300028, 2300052, 2300055, 2300056];

function logCollector(message: string): void {
  hilog.info(0x0000, 'Collector', '%{public}s', message);
}

export class NetStatusProbe {
  /** 可达性缓存：0 表示从未探测过（null 也受 TTL 保护，避免节拍里反复重试）。 */
  private reachValue: boolean | null = null;
  private reachAt: number = 0;
  private reachTtl: number = REACH_TTL_OK_MS;
  /** in-flight 探测：并发调用合并成一个请求。 */
  private reachInflight: Promise<boolean | null> | null = null;
  /** 日志节流标记：Wi-Fi / 可达性各自记「首次失败 + 由败转成」。 */
  private wifiFailed: boolean = false;
  private reachFailed: boolean = false;
  /** 上一次对外标签，用于「只在跳变时打日志」。 */
  private lastLabel: string = '';

  /** 预热：进阅读器/开胶囊时后台先跑一发，别让用户第一拍干等探测超时。 */
  warmup(): void {
    this.reachable().then((value: boolean | null): void => {
      logCollector('网络探测：预热完成 reachable=' +
        (value === null ? '未知' : (value ? '可达' : '不可达')));
    });
  }

  /** 清缓存（网络切换/需要立刻复测时用）。 */
  reset(): void {
    this.reachValue = null;
    this.reachAt = 0;
    this.reachTtl = REACH_TTL_OK_MS;
    this.lastLabel = '';
  }

  /**
   * ① Wi-Fi 开关状态：本地同步查询，失败返回 null 并留稀疏日志（**不闩**，每拍仍会重试）。
   */
  private wifiActive(): boolean | null {
    try {
      const active = wifiManager.isWifiActive();
      if (this.wifiFailed) {
        this.wifiFailed = false;
        logCollector('网络探测(wifi)：由失败恢复为成功');
      }
      return active;
    } catch (error) {
      const be = error as BusinessError;
      if (!this.wifiFailed) {
        this.wifiFailed = true;
        logCollector('网络探测(wifi)：isWifiActive 失败 code=' + be.code + ' ' + be.message +
          '（仅日志节流，下次仍会重试）');
      }
      return null;
    }
  }

  /**
   * ② 可达性：TTL 缓存 + 超时 + 并发合并。
   * 返回 `true` 可达 / `false` 不可达 / `null` 未知（探测没跑起来，保守）。
   */
  async reachable(force: boolean = false): Promise<boolean | null> {
    const now = Date.now();
    if (!force) {
      if (this.reachInflight !== null) {
        return this.reachInflight;
      }
      if (this.reachAt > 0 && now - this.reachAt < this.reachTtl) {
        return this.reachValue;
      }
    }
    const probe: Promise<boolean | null> = this.probeReachable()
      .catch((error: Error): boolean | null => {
        // 理论到不了这里（probeReachable 内部已吞异常）；兜底按未知处理并计一次失败 TTL
        logCollector('网络探测：探测异常 ' + error.message);
        return null;
      });
    this.reachInflight = probe;
    try {
      const value = await probe;
      this.reachValue = value;
      this.reachAt = Date.now();
      // 非 true（不可达 / 未知）都用短 TTL：网络刚恢复时能更快翻回"有网"
      this.reachTtl = value === true ? REACH_TTL_OK_MS : REACH_TTL_FAIL_MS;
      return value;
    } finally {
      if (this.reachInflight === probe) {
        this.reachInflight = null;
      }
    }
  }

  /**
   * 逐端点发一个极小请求：**收到任何 HTTP 响应（含门户 200/302）都算可达**——
   * 只有传输层失败（连不上/超时/无响应）才判不可达。
   * 这是刻意的保守方向：宁可把"门户未登录"算成有网，也不要复现"明明有网却显示无网络"。
   */
  private async probeReachable(): Promise<boolean | null> {
    for (let i = 0; i < PROBE_ENDPOINTS.length; i++) {
      const url = PROBE_ENDPOINTS[i];
      let request: http.HttpRequest | null = null;
      try {
        request = http.createHttp();
        await request.request(url, {
          method: http.RequestMethod.GET,
          connectTimeout: PROBE_TIMEOUT_MS,
          readTimeout: PROBE_TIMEOUT_MS,
          usingCache: false
        });
        this.noteReachOk();
        return true;
      } catch (error) {
        const be = error as BusinessError;
        if (UNREACHABLE_CODES.indexOf(be.code) < 0) {
          // 配置/权限/协议类错误：换端点也没用 → 判「未知」，保守省略
          this.noteReachUnknown(be.code, be.message);
          return null;
        }
        if (be.code === 2300028 || be.code === 2300052) {
          // 超时/无响应：多半是"整机没路由"，换端点只会再各等一轮超时 → 立刻收工，
          // 把单次探测的总时长压回 2.5s 左右（不拖慢胶囊刷新节拍）。
          this.noteReachFail(be.code, be.message);
          return false;
        }
        if (i === PROBE_ENDPOINTS.length - 1) {
          this.noteReachFail(be.code, be.message);
        }
      } finally {
        if (request !== null) {
          request.destroy();
        }
      }
    }
    // 走到这里：所有端点都是传输层失败
    return false;
  }

  /** 一次探测的原始信号（Wi-Fi + 可达性），供调用方自定义映射。 */
  async snapshot(): Promise<NetStatusSnapshot> {
    const wifiActive = this.wifiActive();
    const reachable = await this.reachable();
    return { wifiActive: wifiActive, reachable: reachable };
  }

  /**
   * 对外标签（可直接进胶囊）：
   * - Wi-Fi 开着 → `WIFI`；
   * - 非 Wi-Fi 且可达 → `流量`；
   * - 确认不可达 → `无网络`；
   * - 探测未完成 / 异常 → 空串（**省略**，绝不假装"无网络"）。
   */
  async label(): Promise<string> {
    const snap = await this.snapshot();
    let label = '';
    if (snap.wifiActive === true) {
      label = 'WIFI';
    } else if (snap.wifiActive === false && snap.reachable === true) {
      label = '流量';
    } else if (snap.reachable === false) {
      label = '无网络';
    } else {
      label = '';
    }
    if (label !== this.lastLabel) {
      this.lastLabel = label;
      logCollector('网络状态 → ' + (label.length > 0 ? label : '省略') +
        '（wifi=' + this.describeNull(snap.wifiActive) +
        ' reachable=' + this.describeNull(snap.reachable) + '）');
    }
    return label;
  }

  private describeNull(value: boolean | null): string {
    return value === null ? '未知' : (value ? '1' : '0');
  }

  /** 可达性由败转成：一条。 */
  private noteReachOk(): void {
    if (!this.reachFailed) {
      return;
    }
    this.reachFailed = false;
    logCollector('网络探测：由失败恢复为成功');
  }

  /** 全端点传输层失败：这一轮只在最后一个端点打一条，之后靠 lastLabel 跳变继续节流。 */
  private noteReachFail(code: number, message: string): void {
    if (this.reachFailed) {
      return;
    }
    this.reachFailed = true;
    logCollector('网络探测：可达性探测失败 code=' + code + ' ' + message +
      '（全部端点传输层失败，判不可达）');
  }

  /** 配置/权限类错误：判「未知」，同样只打一条。 */
  private noteReachUnknown(code: number, message: string): void {
    if (this.reachFailed) {
      return;
    }
    this.reachFailed = true;
    logCollector('网络探测：探测未跑起来 code=' + code + ' ' + message +
      '（非传输层错误，按未知保守处理）');
  }
}

/** 全局单例：调用方直接 `netStatus.label()`。 */
export const netStatus: NetStatusProbe = new NetStatusProbe();
