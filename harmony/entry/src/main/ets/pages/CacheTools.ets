/**
 * 设置页「缓存统计与清理」的只读统计与二段式清理。
 *
 * 数据来源只有两类，都不重写下载逻辑：
 *  1) pages/DownloadStore.ets 已有的目录/文件信息——listDownloadedComics、listDownloadedChapters、
 *     deleteChapter；统计与删除都走它，索引（chapters.json / meta.json / .done）由它自己维护。
 *  2) 官方公开 API——Context.cacheDir + fileIo（应用沙箱内递归统计与删除）、
 *     webview.WebviewController.removeAllCache（ArkWeb 官方清缓存接口）。
 *
 * 「不能删正在进行的下载任务」的判定依据（见 DownloadStore.downloadChapter）：
 * 任务开始时会先 removeFileQuietly(.done)，全部图片写完才 writeFileAtomically(.done)；
 * 因此「章节目录存在 .done」⇒ 该章不可能有进行中的任务，删除是安全的。
 * 没有 .done 的章节（下载中 / 失败 / 已取消）一律保留，并把数量回报给调用方。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { DownloadedChapterInfo, DownloadedComicInfo, downloadStore } from './DownloadStore';

const MB: number = 1024 * 1024;
/** 每处理这么多条目就让出一次主线程，避免大目录统计/删除时卡住设置页。 */
const YIELD_EVERY: number = 48;

export interface StorageStats {
  /** 是否拿到了完整统计（false 表示读取失败，数值不可信）。 */
  ready: boolean;
  /** 离线下载占用字节数。 */
  downloadBytes: number;
  comicCount: number;
  chapterCount: number;
  /** 没有 .done 的章节：下载中 / 失败 / 已取消，清理时一律保留。 */
  pendingChapterCount: number;
  /** 应用缓存目录（context.cacheDir）占用字节数，ArkWeb 缓存也在这里。 */
  cacheBytes: number;
  errorText: string;
}

export interface ClearResult {
  ok: boolean;
  freedBytes: number;
  /** 真正删除的条目数（下载=章节数，缓存=cacheDir 下的顶层条目数）。 */
  clearedCount: number;
  /** 保留的条目数（下载=未完成章节数）。 */
  keptCount: number;
  errorText: string;
  note: string;
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

/** 递归统计目录占用；不存在返回 0，单个子项失败不中断整体。 */
async function directorySizeAsync(path: string): Promise<number> {
  if (!exists(path)) {
    return 0;
  }
  let bytes = 0;
  try {
    const stat = fileIo.statSync(path);
    if (!stat.isDirectory()) {
      return stat.size;
    }
    const names = fileIo.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      bytes += await directorySizeAsync(path + '/' + names[i]);
      if (i % YIELD_EVERY === YIELD_EVERY - 1) {
        await breathe();
      }
    }
  } catch (error) {
    return bytes;
  }
  return bytes;
}

/** 删除单个文件或整棵树；失败返回 false（不抛出）。 */
async function removePathAsync(path: string): Promise<boolean> {
  if (!exists(path)) {
    return true;
  }
  try {
    const stat = fileIo.statSync(path);
    if (stat.isDirectory()) {
      const names = fileIo.listFileSync(path);
      for (let i = 0; i < names.length; i++) {
        await removePathAsync(path + '/' + names[i]);
      }
      fileIo.rmdirSync(path);
      return true;
    }
    fileIo.unlinkSync(path);
    return true;
  } catch (error) {
    return false;
  }
}

interface SweepResult {
  removedCount: number;
  failedCount: number;
}

/** 清空目录下的所有条目（保留目录本身）。 */
async function emptyDirectoryAsync(directory: string): Promise<SweepResult> {
  const result: SweepResult = { removedCount: 0, failedCount: 0 };
  if (!exists(directory)) {
    return result;
  }
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(directory);
  } catch (error) {
    result.failedCount = 1;
    return result;
  }
  for (let i = 0; i < names.length; i++) {
    const ok = await removePathAsync(directory + '/' + names[i]);
    if (ok) {
      result.removedCount++;
    } else {
      result.failedCount++;
    }
    if (i % YIELD_EVERY === YIELD_EVERY - 1) {
      await breathe();
    }
  }
  return result;
}

/** 取路径最后一段（章节目录名）。 */
function baseName(path: string): string {
  const index = path.lastIndexOf('/');
  return index >= 0 ? path.substring(index + 1) : path;
}

/**
 * 作品目录里是否出现了「不在本次名单里的新目录」。
 *
 * 关心的是目录而不是文件：新任务的章节目录是先 mkdir、再写 meta，中间有个窗口期，
 * 它既没有 meta 也没有 .done；一旦它出现，deleteChapter 在最后一章时会把整棵作品目录
 * 连它一起删掉。文件（chapters.json / chapters.json.part）由 DownloadStore 自己维护，
 * 视为正常内容。读不到目录就当不安全，宁可少删。
 */
function hasForeignDirectory(directory: string, known: Set<string>): boolean {
  let names: string[] = [];
  try {
    names = fileIo.listFileSync(directory);
  } catch (error) {
    return true;
  }
  for (let i = 0; i < names.length; i++) {
    if (known.has(names[i])) {
      continue;
    }
    try {
      if (fileIo.statSync(directory + '/' + names[i]).isDirectory()) {
        return true;
      }
    } catch (error) {
      return true;
    }
  }
  return false;
}

/** 统一的人类可读大小：MB 为主，超过 1 GB 用 GB。 */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 MB';
  }
  const megabytes = bytes / MB;
  if (megabytes >= 1024) {
    return (megabytes / 1024).toFixed(1) + ' GB';
  }
  if (megabytes >= 100) {
    return Math.round(megabytes) + ' MB';
  }
  if (megabytes >= 1) {
    return megabytes.toFixed(1) + ' MB';
  }
  // 小于 1 MB 但确实占了空间：按最小 0.1 MB 展示，避免出现「0 MB」这种误导
  return '0.1 MB';
}

/** 只读统计：下载占用来自 DownloadStore，缓存占用来自 context.cacheDir。全程不写任何文件。 */
export async function collectStorageStats(): Promise<StorageStats> {
  const stats: StorageStats = {
    ready: false,
    downloadBytes: 0,
    comicCount: 0,
    chapterCount: 0,
    pendingChapterCount: 0,
    cacheBytes: 0,
    errorText: ''
  };
  const errors: string[] = [];
  try {
    // 复用 DownloadStore 既有的目录信息：bytes 由它统计，章节完成情况看它的 .done 判定
    const comics = downloadStore.listDownloadedComics();
    stats.comicCount = comics.length;
    for (let i = 0; i < comics.length; i++) {
      stats.downloadBytes += comics[i].bytes;
      stats.chapterCount += comics[i].chapterCount;
      // 未完成数只能从「全部章节」取：listDownloadedComics 的 chapterCount 与 completedCount
      // 同值（仅完成章），相减恒为 0。listAllChapters 含索引里未完成的条目。
      const all = downloadStore.listAllChapters(comics[i].directory);
      for (let k = 0; k < all.length; k++) {
        if (!all[k].completed) {
          stats.pendingChapterCount++;
        }
      }
      if (i % 6 === 5) {
        await breathe();
      }
    }
  } catch (error) {
    errors.push('下载统计失败：' + describeError(error as Error));
  }
  await breathe();
  try {
    const context = appContext();
    if (context === null) {
      errors.push('缓存统计失败：应用上下文未就绪');
    } else {
      stats.cacheBytes = await directorySizeAsync(context.cacheDir);
    }
  } catch (error) {
    errors.push('缓存统计失败：' + describeError(error as Error));
  }
  stats.errorText = errors.join('；');
  stats.ready = stats.errorText.length === 0;
  return stats;
}

/**
 * 清理应用缓存（不含离线下载）：
 *  1) 先调 ArkWeb 官方接口 removeAllCache(true) 清 ROM+RAM 的 Web 缓存；
 *  2) 再清空 context.cacheDir 下的条目（应用自己的沙箱缓存目录，ArkWeb 的 cache/web 就在里面）；
 *  3) 前后各测一次大小，如实回报释放量；任何一步失败都写进 errorText，不抛异常。
 */
export async function clearAppCache(): Promise<ClearResult> {
  const result: ClearResult = {
    ok: false,
    freedBytes: 0,
    clearedCount: 0,
    keptCount: 0,
    errorText: '',
    note: ''
  };
  const context = appContext();
  if (context === null) {
    result.errorText = '应用上下文未就绪';
    result.note = '清理失败：应用上下文未就绪';
    return result;
  }
  const cacheDir = context.cacheDir;
  const before = await directorySizeAsync(cacheDir);

  let webError = '';
  try {
    // 官方 API：清掉本应用所有 Web 组件的缓存（ROM + RAM），不需要持有 WebviewController 实例
    webview.WebviewController.removeAllCache(true);
  } catch (error) {
    webError = describeError(error as Error);
  }
  await breathe();

  const sweep = await emptyDirectoryAsync(cacheDir);
  if (sweep.failedCount > 0) {
    result.errorText = '有 ' + sweep.failedCount + ' 项未能删除';
  }
  if (webError.length > 0) {
    result.errorText += (result.errorText.length > 0 ? '；' : '') + 'ArkWeb 清理接口报错：' + webError;
  }

  const after = await directorySizeAsync(cacheDir);
  result.freedBytes = Math.max(0, before - after);
  result.clearedCount = sweep.removedCount;
  // 释放到字节才算成功：接口报错但实际已清掉，也算成功，只是把报错如实带出去
  result.ok = result.freedBytes > 0 || (sweep.failedCount === 0 && webError.length === 0);
  if (result.ok) {
    if (result.freedBytes === 0) {
      result.note = '应用缓存已清空，未发现占用';
    } else {
      result.note = '已清理应用缓存 ' + formatBytes(result.freedBytes);
      if (after > 0) {
        result.note += '（仍有 ' + formatBytes(after) + ' 被占用，可能正在使用）';
      }
    }
    if (result.errorText.length > 0) {
      result.note += '；部分未完成：' + result.errorText;
    }
  } else {
    result.note = '清理未完成：' + (result.errorText.length > 0 ? result.errorText : '未能释放空间');
  }
  return result;
}

/**
 * 清理离线下载：只删「已完成（有 .done）」的章节；没有 .done 的章节原样保留并计数。
 * 删除逐章调用 DownloadStore.deleteChapter，由它先 cancel 再重写索引，避免索引与磁盘不一致。
 */
export async function clearDownloads(): Promise<ClearResult> {
  const result: ClearResult = {
    ok: false,
    freedBytes: 0,
    clearedCount: 0,
    keptCount: 0,
    errorText: '',
    note: ''
  };
  const errors: string[] = [];
  const warnings: string[] = [];
  let pendingKept: number = 0;
  let comics: DownloadedComicInfo[] = [];
  try {
    comics = downloadStore.listDownloadedComics();
  } catch (error) {
    result.errorText = '读取下载目录失败：' + describeError(error as Error);
    result.note = '清理失败：' + result.errorText;
    return result;
  }

  for (let i = 0; i < comics.length; i++) {
    const comic = comics[i];
    let all: DownloadedChapterInfo[] = [];
    try {
      all = downloadStore.listAllChapters(comic.directory);
    } catch (error) {
      errors.push(comic.name + '：读取失败');
      continue;
    }
    // 名单：这个作品下所有被识别出来的章节目录（含未完成 / 残留）。
    // 只用 listDownloadedChapters（仅完成章）会让残留半成品目录变成「名单外新目录」，
    // 从而误判「目录已变化」整部停手。未完成章单独计数、一律不删。
    const known = new Set<string>();
    const completed: DownloadedChapterInfo[] = [];
    for (let k = 0; k < all.length; k++) {
      known.add(baseName(all[k].directory));
      if (all[k].completed) {
        completed.push(all[k]);
      } else {
        // 无 .done = 可能正在下载（或失败/取消残留）：一律不删
        result.keptCount++;
        pendingKept++;
      }
    }
    for (let j = 0; j < completed.length; j++) {
      const chapter = completed[j];
      if (hasForeignDirectory(comic.directory, known)) {
        // 目录里有名单外的新目录：很可能是刚起步的任务，停手，剩下的整章保留
        const skipped = completed.length - j;
        result.keptCount += skipped;
        warnings.push(comic.name + ' 目录已变化，剩余 ' + skipped + ' 章未清理');
        break;
      }
      try {
        const chapterBytes = chapter.bytes;
        downloadStore.deleteChapter(comic.directory, chapter.directory);
        result.clearedCount++;
        result.freedBytes += chapterBytes;
      } catch (error) {
        errors.push(chapter.name + '：' + describeError(error as Error));
      }
      await breathe();
    }
    await breathe();
  }

  result.errorText = errors.join('；');
  result.ok = result.errorText.length === 0;
  if (result.clearedCount === 0 && result.keptCount === 0) {
    result.ok = true;
    result.note = '没有可清理的离线下载';
    return result;
  }
  let note = result.clearedCount > 0 ?
    '已删除 ' + result.clearedCount + ' 章（约 ' + formatBytes(result.freedBytes) + '）' :
    '没有已下载完成的章节';
  if (pendingKept > 0) {
    note += '；保留 ' + pendingKept + ' 章进行中/未完成';
  }
  if (warnings.length > 0) {
    note += '；' + warnings.join('；');
  }
  if (!result.ok) {
    note += '；部分失败：' + result.errorText;
  }
  result.note = note;
  return result;
}
