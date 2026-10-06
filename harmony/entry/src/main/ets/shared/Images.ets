/**
 * 章节图片 URL 分辨率改写（规格 E.2）：
 * 任意 `c{数字}x.` 提升为 `c1500x.`（下载前必调）。
 */
const RESOLUTION_RE: RegExp = new RegExp('c[0-9]+x\\.', 'g');

export function wrapResolution(url: string): string {
  return url.replace(RESOLUTION_RE, 'c1500x.');
}
