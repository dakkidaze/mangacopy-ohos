import { COLLECTOR_LOG_ENABLED } from './Log';
/**
 * Web 域管理（规格 A.1 / E.1）：候选、probe、sticky（含过慢切换）、rehost、toPcUrl。
 * 对应 Dart url_manager.dart。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { kDesktopUserAgent } from './ApiHeaders';
import { settingsStore, KEY_ACTIVE_URL, KEY_MANUAL_URL } from './SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'UrlManager';

export interface WebProbeResult {
  url: string;
  elapsedMs: number; // -1 = 无效
}

/** 相对最快延迟达到该毫秒数，才可能因「过慢」换源（还需满足倒数 2 名）。 */
export const SLOW_ABSOLUTE_MS: number = 1000;
/** 相对最快达到该倍数，才可能因「过慢」换源（还需满足倒数 2 名）。 */
export const SLOW_RATIO: number = 2;
/** 绝对延时超过该值强制换源。 */
export const FORCE_SWITCH_MS: number = 4000;

export class UrlManager {
  static readonly candidates: string[] = [
    'https://www.copy3000.com',
    'https://www.2026copy.com',
    'https://www.copy4000.com',
    'https://www.mangacopy.com'
  ];

  static activeUrl: string = UrlManager.candidates[0];
  static manualMode: boolean = false;
  static hasCachedUrl: boolean = false;
  static allSourcesDown: boolean = false;
  static lastProbeNote: string = '';

  static comicDetailUrl(): string {
    return UrlManager.activeUrl + '/comic';
  }

  static allowedPrefixes(): string[] {
    const out: string[] = [];
    for (let i = 0; i < UrlManager.candidates.length; i++) {
      out.push(UrlManager.candidates[i]);
      out.push(UrlManager.candidates[i].replace('://www.', '://'));
    }
    return out;
  }

  /** URL 归一化：去首尾空白；无协议头则补 https://；空串返回空。 */
  static normalizeUrl(u: string): string {
    const text = u.trim();
    if (text.length === 0) {
      return '';
    }
    if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) {
      return text;
    }
    return 'https://' + text;
  }

  /**
   * 落盘 sticky 源站：写前归一化，保证偏好里永远存带协议头的完整地址。
   * 裸域名一旦入库，网页侧直接 loadUrl 会被 chromium 判 invalidUrl。
   */
  private static async saveActiveUrl(url: string): Promise<void> {
    await settingsStore.putString(KEY_ACTIVE_URL, UrlManager.normalizeUrl(url));
  }

  /** 仅读本地缓存（manual_url → active_url），不访问网络。返回是否已有缓存/手动源。 */
  static async bootstrap(): Promise<boolean> {
    const manualRaw = await settingsStore.getString(KEY_MANUAL_URL, '');
    const manual = UrlManager.normalizeUrl(manualRaw);
    if (manual.length > 0 && manual !== manualRaw) {
      // 读侧自愈：存量偏好存的可能是裸域名，顺手把修正值写回
      await settingsStore.putString(KEY_MANUAL_URL, manual);
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(DOMAIN, TAG, '自愈 manual_url：%{public}s → %{public}s', manualRaw, manual);
      }
    }
    if (manual.length > 0 && UrlManager.candidates.indexOf(manual) >= 0) {
      UrlManager.manualMode = true;
      UrlManager.activeUrl = manual;
      UrlManager.hasCachedUrl = true;
      return true;
    }
    const cachedRaw = await settingsStore.getString(KEY_ACTIVE_URL, '');
    const cached = UrlManager.normalizeUrl(cachedRaw);
    if (cached.length > 0 && cached !== cachedRaw) {
      // 读侧自愈：同上，修正后写回 active_url
      await settingsStore.putString(KEY_ACTIVE_URL, cached);
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(DOMAIN, TAG, '自愈 active_url：%{public}s → %{public}s', cachedRaw, cached);
      }
    }
    if (cached.length > 0 && UrlManager.candidates.indexOf(cached) >= 0) {
      UrlManager.activeUrl = cached;
      UrlManager.hasCachedUrl = true;
      return true;
    }
    UrlManager.hasCachedUrl = false;
    return false;
  }

  /** 手机版章节 URL 转 PC 版（供隐藏 WebView 收图）。 */
  static toPcUrl(mobileUrl: string): string {
    if (mobileUrl.indexOf('/comicContent/') < 0) {
      return '';
    }
    const rest = mobileUrl.split('comicContent/')[1];
    const slug = rest.split('/')[0];
    const uuid = mobileUrl.substring(mobileUrl.lastIndexOf('/') + 1);
    return UrlManager.comicDetailUrl() + '/' + slug + '/chapter/' + uuid;
  }

  /** 详情页/章节页 URL 统一转 PC 版。 */
  static toHiddenUrl(url: string): string {
    const detailMarker = '/details/comic/';
    const idx = url.indexOf(detailMarker);
    if (idx >= 0) {
      const after = url.substring(idx + detailMarker.length - '/comic'.length);
      return UrlManager.comicDetailUrl() + after;
    }
    if (url.indexOf('/comicContent/') >= 0) {
      return UrlManager.toPcUrl(url);
    }
    return '';
  }

  /** 任意源的章节 URL 换到当前源（下载列表里存的 URL 可能来自旧源）。 */
  static rehost(url: string): string {
    const prefixes = UrlManager.allowedPrefixes();
    for (let i = 0; i < prefixes.length; i++) {
      if (url.startsWith(prefixes[i])) {
        return UrlManager.activeUrl + url.substring(prefixes[i].length);
      }
    }
    return url;
  }

  /** 手动指定源站（写侧归一化：入库前补全协议头，避免裸域名进偏好库）。 */
  static async setManualUrl(url: string): Promise<void> {
    const normalized = UrlManager.normalizeUrl(url);
    UrlManager.manualMode = true;
    UrlManager.activeUrl = normalized;
    UrlManager.hasCachedUrl = true;
    await settingsStore.putString(KEY_MANUAL_URL, normalized);
  }

  /** 恢复自动选源并立即测速。 */
  static async clearManualUrl(): Promise<string> {
    UrlManager.manualMode = false;
    await settingsStore.remove(KEY_MANUAL_URL);
    return UrlManager.probe();
  }

  /**
   * 当前源是否因「过慢」应换掉（spec A.1 shouldSwitchForSlow）：
   * validSorted 按耗时升序；preferredIdx 为当前源下标。
   * 有效结果里排倒数 2 名，且相对最快 ≥1000ms 且 ≥2 倍；或绝对 >4000ms 强制。
   */
  static shouldSwitchForSlow(validSorted: WebProbeResult[], preferredIdx: number): boolean {
    if (validSorted.length < 2) {
      return false;
    }
    if (preferredIdx < validSorted.length - 2) {
      return false;
    }
    const currentMs = validSorted[preferredIdx].elapsedMs;
    const bestMs = validSorted[0].elapsedMs;
    if (bestMs <= 0) {
      return false;
    }
    if (currentMs > FORCE_SWITCH_MS) {
      return true;
    }
    const slowerByMs = currentMs - bestMs;
    const twiceOrMore = currentMs >= bestMs * SLOW_RATIO;
    return slowerByMs >= SLOW_ABSOLUTE_MS && twiceOrMore;
  }

  /** 并发校验全部候选；手动模式不改 activeUrl；自动模式按 sticky 规则选/换源。 */
  static async probe(): Promise<string> {
    const tasks: Promise<WebProbeResult>[] = [];
    for (let i = 0; i < UrlManager.candidates.length; i++) {
      tasks.push(UrlManager.validate(UrlManager.candidates[i]));
    }
    const results = await Promise.all(tasks);

    const valid: WebProbeResult[] = [];
    for (let i = 0; i < results.length; i++) {
      if (results[i].elapsedMs >= 0) {
        valid.push(results[i]);
      }
    }
    valid.sort((a: WebProbeResult, b: WebProbeResult) => a.elapsedMs - b.elapsedMs);
    UrlManager.allSourcesDown = valid.length === 0;

    if (UrlManager.manualMode) {
      UrlManager.lastProbeNote = valid.length === 0
        ? '全部源不可用；手动模式仍使用 ' + UrlManager.activeUrl
        : '最快 ' + valid[0].url + '（' + valid[0].elapsedMs + 'ms）；手动模式仍使用 ' + UrlManager.activeUrl;
      return UrlManager.activeUrl;
    }

    if (valid.length === 0) {
      UrlManager.lastProbeNote = '全部源不可用';
      return UrlManager.activeUrl;
    }

    const best = valid[0];

    // 首次无缓存：选最快
    if (!UrlManager.hasCachedUrl) {
      UrlManager.activeUrl = best.url;
      UrlManager.hasCachedUrl = true;
      await UrlManager.saveActiveUrl(UrlManager.activeUrl);
      UrlManager.lastProbeNote = '首次选源：' + best.url + '（' + best.elapsedMs + 'ms）';
      return UrlManager.activeUrl;
    }

    let preferredIdx = -1;
    for (let i = 0; i < valid.length; i++) {
      if (valid[i].url === UrlManager.activeUrl) {
        preferredIdx = i;
        break;
      }
    }

    // 当前源失效 → 换最快
    if (preferredIdx < 0) {
      const prev = UrlManager.activeUrl;
      UrlManager.activeUrl = best.url;
      await UrlManager.saveActiveUrl(UrlManager.activeUrl);
      UrlManager.lastProbeNote = '原源站失效（' + prev + '），已切换至 ' + best.url + '（' + best.elapsedMs + 'ms）';
      return UrlManager.activeUrl;
    }

    // 有效但过慢 → 换最快
    if (UrlManager.shouldSwitchForSlow(valid, preferredIdx)) {
      const prev = UrlManager.activeUrl;
      const prevMs = valid[preferredIdx].elapsedMs;
      UrlManager.activeUrl = best.url;
      await UrlManager.saveActiveUrl(UrlManager.activeUrl);
      UrlManager.lastProbeNote =
        '原源站过慢（' + prev + ' ' + prevMs + 'ms），已切换至 ' + best.url + '（' + best.elapsedMs + 'ms）';
      return UrlManager.activeUrl;
    }

    // 忠诚保持
    const curMs = valid[preferredIdx].elapsedMs;
    UrlManager.lastProbeNote = curMs === best.elapsedMs
      ? '保持当前源站 ' + UrlManager.activeUrl + '（' + curMs + 'ms，仍为最快）'
      : '保持当前源站 ' + UrlManager.activeUrl + '（' + curMs + 'ms；最快 ' + best.url + ' ' + best.elapsedMs + 'ms）';
    await UrlManager.saveActiveUrl(UrlManager.activeUrl);
    return UrlManager.activeUrl;
  }

  /** 校验域名确实是拷贝漫画站点并测量耗时；无效返回 elapsedMs=-1。 */
  static async validate(url: string): Promise<WebProbeResult> {
    const startedAt = Date.now();
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': kDesktopUserAgent },
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 5000,
        readTimeout: 5000
      });
      if (Number(response.responseCode) !== 200) {
        return { url: url, elapsedMs: -1 };
      }
      const body = response.result as string;
      const isCopyManga = body.indexOf('拷貝漫畫') >= 0 || body.indexOf('拷贝漫画') >= 0 ||
        body.indexOf('copymanga') >= 0;
      return { url: url, elapsedMs: isCopyManga ? Date.now() - startedAt : -1 };
    } catch (error) {
      const be = error as BusinessError;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.debug(DOMAIN, TAG, 'validate %{public}s failed: %{public}s', url, be.message);
      }
      return { url: url, elapsedMs: -1 };
    } finally {
      request?.destroy();
    }
  }
}
