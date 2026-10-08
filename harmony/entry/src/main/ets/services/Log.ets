/**
 * 业务日志总开关。
 *
 * 发布默认静音：COLLECTOR_LOG_ENABLED 为 false 时，logCollector 直接返回，
 * 全部业务日志（Collector 收图取证、WebShell、UrlManager、ApiDomainMgr、
 * ApiClient 等业务 info/warn）零输出。
 * flip 为 true 即恢复全部业务日志（单个开关，无需改各调用点）。
 *
 * 注意：hilog.error 不经过这里，真实错误始终输出。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

export const COLLECTOR_LOG_ENABLED: boolean = false;

export function logCollector(message: string): void {
  if (!COLLECTOR_LOG_ENABLED) {
    return;
  }
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(0x0000, 'Collector', '%{public}s', message);
  }
}
