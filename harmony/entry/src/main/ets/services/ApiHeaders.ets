/**
 * 拷贝漫画 API 通用请求头（规格 A.2）。
 *
 * 身份约定（"网页身份自洽"，与 Dart api_headers.dart 一致）：
 * - API 客户端与可见 WebView 用移动 UA；
 * - 桌面 UA 只给隐藏收图 WebView 用。
 */

/** 官方 App 版本头；上游更新时最易变。 */
export const kApiVersion: string = '2025.11.21';

/** 可见 WebView / API 客户端使用的移动 UA。 */
export const kMobileUserAgent: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/** 隐藏收图 WebView 使用的桌面 UA（PC 版章节页）。 */
export const kDesktopUserAgent: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/** 默认请求头（网页身份：移动 UA + 浏览器式 XHR 头）。 */
export function apiHeaders(webp: string = '0', userAgent: string = ''): Record<string, Object> {
  const h: Record<string, Object> = {};
  h['User-Agent'] = userAgent.length > 0 ? userAgent : kMobileUserAgent;
  h['Accept'] = 'application/json, text/plain, */*';
  h['Accept-Language'] = 'zh-CN,zh;q=0.9';
  h['Version'] = kApiVersion;
  h['Region'] = '0';
  h['Webp'] = webp;
  h['platform'] = '1';
  h['Origin'] = 'https://www.mangacopy.com';
  h['Referer'] = 'https://www.mangacopy.com/h5/';
  h['X-Requested-With'] = 'XMLHttpRequest';
  return h;
}

/** 热辣系域判定：`/chapter/` 且 `Webp:1`；其余用 `/chapter2/`。 */
export const kHotDomainRe: RegExp = new RegExp('manga2025|hotmanga|fgjf|elfgj|relamanhua', 'i');

export function isHotDomain(domain: string): boolean {
  return kHotDomainRe.test(domain);
}
