import { COLLECTOR_LOG_ENABLED } from './Log';
/**
 * 图片缓存淘汰（近似对齐 Flutter 侧 image_cache_store 的文件级 LRU）。
 *
 * 能力边界（如实记录）：
 *  - ArkUI 的 Image 组件缓存由系统托管，**没有**公开的逐条 LRU 接口，拿不到"某张图多久没被看过"；
 *    因此这里的"最近使用"只能落到文件系统层：cacheDir 下每个文件的 atime / mtime。
 *  - 本模块只处理 context.cacheDir（图片缓存、ArkWeb 缓存都在里面）；
 *    filesDir 是已下载漫画，**一律不碰**——统计与删除的路径全部由 cacheDir 递归得来，
 *    另外在删除前再校验一次路径前缀，双保险。
 *  - 统计复用 pages/CacheTools.ets 的 collectStorageStats（其内部就是既有的 cacheDir 递归统计），
 *    本模块不另造一套"目录占用统计"；时间戳遍历（按文件淘汰所需）是 CacheTools 没有的能力，单独实现。
 *
 * 分工：CacheTools = 设置页的「看总量 + 一键清空」；ImageCacheTrim = 静默的、按上限的增量淘汰。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { collectStorageStats, formatBytes } from '../pages/CacheTools';
import { settingsStore } from './SettingsStore';

/** 1 MB，与设置页 imageCacheLimitMb 同单位。 */
const MB: number = 1024 * 1024;
/** 两次淘汰之间的最小间隔：45 秒内重复触发直接忽略。 */
const MIN_INTERVAL_MS: number = 45 * 1000;
/** 淘汰目标：清到上限的 80%，留出余量，避免刚清完又立刻超限。 */
const TRIM_TARGET_RATIO: number = 0.8;
/** 每处理这么多条目让出一次主线程，避免大目录遍历卡住页面。 */
const YIELD_EVERY: number = 48;

/** Collector 日志：与 NetStatus / ReaderPage 同一 tag，稀疏输出。 */
function logCollector(message: string): void {
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(0x0000, 'Collector', '%{public}s', message);
  }
}

function appContext(): common.UIAbilityContext | null {
  const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
  return context !== undefined ? context : null;
}

function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (error) {
    return false;
  }
}

function breathe(): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout(() => resolve(), 0);
  });
}

function describeError(error: Error): string {
  const text = (error as Error).message;
  if (text !== undefined && text.length > 0) {
    return text;
  }
  return '未知错误';
}

/** cacheDir 里的一次遍历结果：只记文件，目录只是容器。 */
interface CacheFileEntry {
  path: string;
  bytes: number;
  /** 最后被碰的时间（毫秒）：取 atime / mtime 中较新者。 */
  touchedAt: number;
}

/**
 * 递归收集 cacheDir 下的文件与时间戳（按文件 LRU 必需，CacheTools 没有这一层）。
 * 单个条目失败不中断整体；每 YIELD_EVERY 项让出一次主线程。
 */
async function collectCacheFiles(directory: string, out: CacheFileEntry[]): Promise<void> {
  if (!exists(directory)) {
    return;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(directory);
  } catch (error) {
    return;
  }
  for (let i = 0; i < names.length; i++) {
    const path = directory + '/' + names[i];
    try {
      const stat = fileIo.statSync(path);
      if (stat.isDirectory()) {
        await collectCacheFiles(path, out);
      } else {
        // 用户数据分区默认 noatime（见 @ohos.file.fs 的 FilesStat 说明），atime 往往不更新，
        // 用 max(atime, mtime) 兜底：任一时间更新都算"刚被碰过"，不会因为 atime 陈旧误删新文件。
        let touchedAt = stat.mtime > 0 ? stat.mtime : stat.atime;
        if (stat.atime > touchedAt) {
          touchedAt = stat.atime;
        }
        out.push({ path: path, bytes: stat.size, touchedAt: touchedAt });
      }
    } catch (error) {
      // 读不到的条目直接跳过：宁可少删，不可删错
    }
    if (i % YIELD_EVERY === YIELD_EVERY - 1) {
      await breathe();
    }
  }
}

/** 删除单个文件；返回是否真的删掉了。 */
function unlinkQuietly(path: string): boolean {
  try {
    fileIo.unlinkSync(path);
    return true;
  } catch (error) {
    return false;
  }
}

class ImageCacheTrimService {
  /** 上次真正跑过一轮的时刻（毫秒），0 表示从未跑过。 */
  private lastRunAt: number = 0;
  /** 单飞标记：进行中的淘汰不允许并发再起一轮。 */
  private running: boolean = false;

  /**
   * 触发入口：发现页 / 收藏页（MangaGridView）与下载页的 aboutToAppear 调用即可，
   * 不必挂在 Index 上。任何一次调用都只是 O(1) 的节流判断：45 秒最小间隔 + 单飞。
   */
  async maybeTrim(): Promise<void> {
    const now = Date.now();
    if (this.running || now - this.lastRunAt < MIN_INTERVAL_MS) {
      return;
    }
    this.running = true;
    // 起跑时就记时间：失败也不再 45 秒内反复重试
    this.lastRunAt = now;
    try {
      await this.trimOverLimit();
    } catch (error) {
      logCollector('图片缓存淘汰：异常 ' + describeError(error as Error));
    } finally {
      this.running = false;
    }
  }

  private async trimOverLimit(): Promise<void> {
    const context = appContext();
    if (context === null) {
      return;
    }
    const cacheDir = context.cacheDir;
    if (cacheDir.length === 0 || !exists(cacheDir)) {
      return;
    }
    const limitMb = await settingsStore.imageCacheLimitMb();
    if (limitMb <= 0) {
      // 设置页的 0 = 不限量
      return;
    }
    const limitBytes = limitMb * MB;

    // 统计复用 CacheTools（内部即既有的 cacheDir 递归统计），不在这里另造一套
    const stats = await collectStorageStats();
    if (stats.cacheBytes <= limitBytes) {
      return;
    }

    const targetBytes = Math.floor(limitBytes * TRIM_TARGET_RATIO);
    const entries: CacheFileEntry[] = [];
    await collectCacheFiles(cacheDir, entries);
    if (entries.length === 0) {
      return;
    }
    // 从旧到新：先删最久没被碰过的
    entries.sort((left: CacheFileEntry, right: CacheFileEntry): number => left.touchedAt - right.touchedAt);

    let remaining = stats.cacheBytes;
    let freedBytes = 0;
    let removedCount = 0;
    let failedCount = 0;
    for (let i = 0; i < entries.length; i++) {
      if (remaining <= targetBytes) {
        break;
      }
      const entry = entries[i];
      // 双保险：路径必须落在 cacheDir 里（filesDir 等其它目录绝不删除）
      if (entry.path.indexOf(cacheDir + '/') !== 0) {
        continue;
      }
      if (unlinkQuietly(entry.path)) {
        remaining -= entry.bytes;
        freedBytes += entry.bytes;
        removedCount++;
      } else {
        failedCount++;
      }
      if (i % YIELD_EVERY === YIELD_EVERY - 1) {
        await breathe();
      }
    }

    if (removedCount > 0 || failedCount > 0) {
      let note = '图片缓存淘汰：上限 ' + limitMb + ' MB，删除 ' + removedCount + ' 个文件（' +
        formatBytes(freedBytes) + '），剩余约 ' + formatBytes(Math.max(0, remaining));
      if (failedCount > 0) {
        note += '，失败 ' + failedCount + ' 个';
      }
      logCollector(note);
    }
  }
}

export const imageCacheTrim: ImageCacheTrimService = new ImageCacheTrimService();
