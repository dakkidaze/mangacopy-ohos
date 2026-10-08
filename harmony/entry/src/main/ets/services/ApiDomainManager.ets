/**
 * API 域名管理（规格 A.1）：
 * 候选列表 + 用户自定义 + `network4` 引导 + 并发探测（sticky）。
 * 域名强依赖网络出口，无单一默认——由 probeBest / bootstrapFromNetwork4 运行时决定。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { apiHeaders } from './ApiHeaders';

const DOMAIN: number = 0x0000;
const TAG: string = 'ApiDomainMgr';

export interface ProbeOutcome {
  domain: string;
  ok: boolean;
  elapsedMs: number;
}

const DEFAULT_PROBE_TIMEOUT_MS: number = 5000;

export class ApiDomainManager {
  /** 引导/评论优先的候选域（顺序即优先级，用作探测并列时的次序）。 */
  candidates: string[] = [
    'https://api.copy202601.com',
    'https://api.copy4000.com',
    'https://api.mangacopy.com',
    'https://mapi.copy20.com',
    // 备用域名（2026-10-06 实测可用：章节接口 200）
    'https://api.copy202602.com',
    'https://api.manga2026.xyz'
  ];

  /** 支持评论（roasts/comments）的域 host（规格 A.1 commentCapableHosts）。 */
  static readonly COMMENT_CAPABLE_HOSTS: string[] = [
    'api.copy202601.com',
    'api.copy4000.com',
    'api.mangacopy.com',
    'mapi.copy20.com'
  ];

  /** 用户自定义域（非空时优先）。 */
  customDomain: string = '';

  /** 当前生效域。 */
  active: string = 'https://api.copy202601.com';

  static normalize(domain: string): string {
    return domain.startsWith('http') ? domain : 'https://' + domain;
  }

  static hostOf(domain: string): string {
    const n = ApiDomainManager.normalize(domain);
    const rest = n.startsWith('https://') ? n.substring('https://'.length) : n;
    const slash = rest.indexOf('/');
    return slash >= 0 ? rest.substring(0, slash) : rest;
  }

  supportsComments(domain: string): boolean {
    return ApiDomainManager.COMMENT_CAPABLE_HOSTS.indexOf(ApiDomainManager.hostOf(domain)) >= 0;
  }

  /**
   * 拉官方当前线路：`GET {seed}/api/v3/system/network4` → `results.api` 里第一个字符串。
   * `results.api` 可能是 string 或 list。
   */
  async bootstrapFromNetwork4(seed: string, timeoutMs: number = 10000): Promise<string> {
    const url = ApiDomainManager.normalize(seed) + '/api/v3/system/network4';
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: apiHeaders(),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      if (Number(response.responseCode) !== 200) {
        return '';
      }
      const body = JSON.parse(response.result as string) as Record<string, Object>;
      const results = body['results'];
      if (results === null || results === undefined || typeof results !== 'object') {
        return '';
      }
      const api = (results as Record<string, Object>)['api'];
      const host = ApiDomainManager.firstString(api);
      return host.length > 0 ? ApiDomainManager.normalize(host) : '';
    } catch (error) {
      const be = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'network4 failed: %{public}s', be.message);
      return '';
    } finally {
      request?.destroy();
    }
  }

  /** results.api 兼容：字符串直接取；数组递归取第一个字符串。 */
  private static firstString(v: Object | undefined | null): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (Array.isArray(v)) {
      const arr = v as Object[];
      for (let i = 0; i < arr.length; i++) {
        const s = ApiDomainManager.firstString(arr[i]);
        if (s.length > 0) {
          return s;
        }
      }
    }
    return '';
  }

  /**
   * 并发探测候选（自定义域优先），返回最快可用域并写入 active。
   * 结果按耗时升序（同毫秒按候选序）；全部失败时返回 active 原值。
   */
  async probeBest(timeoutMs: number = DEFAULT_PROBE_TIMEOUT_MS): Promise<string> {
    const custom = this.customDomain;
    if (custom.length > 0) {
      const cd = ApiDomainManager.normalize(custom);
      const outcome = await ApiDomainManager.probe(cd, timeoutMs);
      if (outcome.ok) {
        this.active = cd;
        return this.active;
      }
    }

    const list: string[] = [];
    for (let i = 0; i < this.candidates.length; i++) {
      const n = ApiDomainManager.normalize(this.candidates[i]);
      if (n.length > 0 && list.indexOf(n) < 0) {
        list.push(n);
      }
    }

    const tasks: Promise<ProbeOutcome>[] = [];
    for (let i = 0; i < list.length; i++) {
      tasks.push(ApiDomainManager.probe(list[i], timeoutMs));
    }
    const probed = await Promise.all(tasks);

    let best = '';
    let bestMs = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < probed.length; i++) {
      const p = probed[i];
      if (!p.ok) {
        continue;
      }
      // 升序取最快；同毫秒按候选序（先出现的赢）。
      if (p.elapsedMs < bestMs || (p.elapsedMs === bestMs && best.length === 0)) {
        best = p.domain;
        bestMs = p.elapsedMs;
      }
    }
    if (best.length > 0) {
      this.active = best;
    }
    return this.active;
  }

  /** 探测单域：GET /api/v3/recs?pos=3200102&limit=1&offset=0，HTTP 200 且 code==200 才算可用。 */
  static async probe(domain: string, timeoutMs: number): Promise<ProbeOutcome> {
    const startedAt = Date.now();
    const url = domain + '/api/v3/recs?pos=3200102&limit=1&offset=0';
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: apiHeaders(),
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs
      });
      const elapsedMs = Date.now() - startedAt;
      let ok = Number(response.responseCode) === 200;
      if (ok) {
        try {
          const body = JSON.parse(response.result as string) as Record<string, Object>;
          ok = Number(body['code']) === 200;
        } catch (error) {
          ok = false;
        }
      }
      return { domain: domain, ok: ok, elapsedMs: elapsedMs };
    } catch (error) {
      const be = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'probe %{public}s failed: %{public}s', domain, be.message);
      return { domain: domain, ok: false, elapsedMs: Date.now() - startedAt };
    } finally {
      request?.destroy();
    }
  }
}
