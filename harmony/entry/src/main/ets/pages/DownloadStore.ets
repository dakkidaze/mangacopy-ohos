/**
 * 章节下载与离线目录索引。
 * 文件协议严格保持：downloads/{comicName}/章节_{uuid前8}/、meta.json、.done、chapters.json。
 * 作品目录下另有封面文件 cover.url 与 cover.jpg|cover.webp（只由本模块读写，不进章节协议）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { kDesktopUserAgent } from '../services/ApiHeaders';
import { Chapter } from '../model/Models';
import { wrapResolution } from '../shared/Images';
import { getBrowseSource } from './BrowseSupport';
import { loadChapterImages } from './HiddenCollector';
import { UrlManager } from '../services/UrlManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOWNLOAD_FOLDER: string = 'downloads';
const CHAPTERS_FILE: string = 'chapters.json';
const META_FILE: string = 'meta.json';
const DONE_FILE: string = '.done';
/**
 * 作品目录里的封面（下载时顺手落盘）：
 *  cover.url  存封面地址 —— 联网时可直接 Image(url) 吃系统缓存；
 *  cover.jpg / cover.webp 是图片字节 —— 离线也能显示头图。
 */
const COVER_URL_FILE: string = 'cover.url';
const COVER_IMAGE_NAMES: string[] = ['cover.jpg', 'cover.webp'];
const DOWNLOAD_CONCURRENCY: number = 4;
const IMAGE_RETRIES: number = 3;
const IMAGE_TIMEOUT_MS: number = 30000;
/**
 * 停滞守护：连续 STALL_TIMEOUT_MS 毫秒没有任何「进度产物」（新页落盘 / 进度上报），
 * 该章判失败（errorText=「下载停滞」），走既有失败流程、可重试。单章与批量共用。
 */
const STALL_TIMEOUT_MS: number = 90000;
/** 停滞守护检查周期：命中时间落在 90s ~ 95s 之间。 */
const STALL_CHECK_INTERVAL_MS: number = 5000;
/**
 * 作品级下载索引（漫画目录内的 .index.json）：把每章的字节数 / 页数 / 完成态在下载时落盘，
 * 列表读取时一次小文件读即可，避免对每个章节目录做全树递归统计。
 * 既有协议文件（chapters.json / meta.json / .done）语义完全不变，本文件是纯新增缓存。
 */
const INDEX_FILE: string = '.index.json';
const INDEX_VERSION: number = 1;

export interface ChapterDownloadRequest {
  comicName: string;
  comicId: string;
  chapterName: string;
  chapterId: string;
  /**
   * 该章在详情页默认（正序）列表中的序号，取自数据源自带的官方 index 字段。
   * 与 UI 正/倒序切换无关；旧请求 / 老数据可能缺省，读取侧会退回自然序。
   */
  orderIndex?: number;
}

export interface ChapterDownloadProgress {
  completed: number;
  total: number;
}

export type ChapterDownloadProgressCallback = (progress: ChapterDownloadProgress) => void;

interface StoredChapterEntry {
  name: string;
  url: string;
}

interface StoredChapterGroup {
  name: string;
  chapters: StoredChapterEntry[];
}

interface StoredChapterMeta {
  uuid: string;
  comicId: string;
  name: string;
  comicName?: string;
  /** 详情页默认顺序序号（旧 meta 可能缺省，读取时退回自然序）。 */
  orderIndex?: number;
}

/** 索引里的单章记录：字段口径与 DownloadedChapterInfo 对齐，供列表直接映射。 */
interface StoredIndexChapter {
  folder: string;
  name: string;
  uuid: string;
  comicId: string;
  comicName: string;
  completed: boolean;
  pageCount: number;
  bytes: number;
  /** 详情页默认顺序序号；缺失（旧索引 / 旧 meta）时整表退回自然序。 */
  orderIndex?: number;
}

interface StoredComicIndex {
  version: number;
  /** 作品目录一层成员名（不含本索引文件与其原子写临时文件），用于轻量校验。 */
  members: string[];
  /** 非章节目录、非索引文件的字节数（封面 / chapters.json / 无法解析的目录等）。 */
  otherBytes: number;
  chapters: StoredIndexChapter[];
}

interface DownloadQueue {
  nextIndex: number;
}

/**
 * 章节下载状态机（store 级）：
 *   Idle（初始/空闲，不展示） → Queued（等待中，入队登记） → Downloading（执行中）
 *     → Completed / Failed
 *   取消：Queued → Cancelled（出队）、Downloading → Cancelled（掐在途请求）
 *   失败重试：Failed → Downloading（单章直下）或 Failed → Queued（批量入队）
 * Completed 之后要重下必须先删章（磁盘 .done 优先于内存状态）。
 */
export enum ChapterDownloadStatus {
  Idle = 0,
  Downloading = 1,
  Completed = 2,
  Failed = 3,
  Cancelled = 4,
  /** 等待中：已在 store 队列里排队，还没轮到执行。 */
  Queued = 5
}

/**
 * 批次视图（「下载所选」的进度条数据源）：字段全部由 DownloadStore 的队列执行器维护，
 * 详情页只读——单一数据源，批次 UI 不再自持任何进度状态。
 * @ObservedV2 + @Trace：详情页 build 里读字段即可自动重绘。
 */
@ObservedV2
export class DownloadBatchView {
  @Trace running: boolean = false;
  /** 本批入队章节数。 */
  @Trace total: number = 0;
  /** 本批已收口为 Completed 的章节数。 */
  @Trace done: number = 0;
  /** 执行器当前章名；没有在跑的章时给队首（下一章）。 */
  @Trace currentChapterName: string = '';
}

@ObservedV2
export class ChapterDownloadState {
  @Trace status: ChapterDownloadStatus = ChapterDownloadStatus.Idle;
  @Trace completed: number = 0;
  @Trace total: number = 0;
  @Trace errorText: string = '';
  /**
   * 展示名（下载管理页的行标题 / 副标题）：taskFor 取任务时写入一次。
   * 名字在任务被任何页面观察之前就已经落好，之后不再变；仍给 @Trace 是为了
   * 万一同 key 的请求换了名字（同 id 不同标题）也能立刻重绘。
   */
  @Trace comicName: string = '';
  @Trace chapterName: string = '';
  /**
   * 失败项被下载管理页「移除」：只让它从管理页列表消失（snapshot 过滤），
   * 不删任务对象、不改 status——详情页那一行可能还持有本对象引用。
   */
  dismissed: boolean = false;
  /**
   * 开跑所需的完整请求：taskFor 每次刷新。
   * 失败重试 / 取消都靠它自持（管理页不需要回详情页取上下文）。
   */
  request: ChapterDownloadRequest | null = null;
  cancelRequested: boolean = false;
  activeRequests: Map<number, http.HttpRequest> = new Map<number, http.HttpRequest>();
  /** 最近一次「进度产物」时间戳：开跑、取到页清单、每页落盘都会刷新。停滞守护据此判 90s。 */
  lastProgressAt: number = 0;
  /** 停滞守护已命中：让在途请求尽快中断，并统一按「下载停滞」收口。 */
  stalled: boolean = false;
  /** 上一次 downloadChapter 尚未收口（停滞判失败后调用方可能立刻重试）：禁止并发重入。 */
  inFlight: boolean = false;

  progressPercent(): number {
    if (this.total <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.completed * 100 / this.total));
  }
}

export interface DownloadedChapterInfo {
  name: string;
  uuid: string;
  comicId: string;
  directory: string;
  completed: boolean;
  pageCount: number;
  bytes: number;
}

export interface DownloadedComicInfo {
  name: string;
  /** 作品 id（取自章节 meta），封面补拉要用；老数据缺 meta 时可能为空串。 */
  comicId: string;
  directory: string;
  /** 已完成章节数（与 completedCount 同值：未完成章不进这份名单）。 */
  chapterCount: number;
  completedCount: number;
  pageCount: number;
  bytes: number;
}

export interface OfflineChapterData {
  name: string;
  uuid: string;
  comicId: string;
  directory: string;
  imagePaths: string[];
  completed: boolean;
}

function appContext(): common.UIAbilityContext {
  const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (context === undefined) {
    throw new Error('abilityContext not ready');
  }
  return context;
}

function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (error) {
    return false;
  }
}

function ensureDirectory(path: string): void {
  if (!exists(path)) {
    fileIo.mkdirSync(path, true);
  }
}

function removeFileQuietly(path: string): void {
  try {
    if (exists(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (error) {
  }
}

function removeTree(path: string): void {
  if (!exists(path)) {
    return;
  }
  const stat = fileIo.statSync(path);
  if (!stat.isDirectory()) {
    fileIo.unlinkSync(path);
    return;
  }
  const names = fileIo.listFileSync(path);
  for (let i = 0; i < names.length; i++) {
    removeTree(path + '/' + names[i]);
  }
  fileIo.rmdirSync(path);
}

function writeFile(path: string, data: string | ArrayBuffer): void {
  let fd = -1;
  try {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
    fd = file.fd;
    fileIo.writeSync(fd, data);
  } finally {
    if (fd >= 0) {
      fileIo.closeSync(fd);
    }
  }
}

function writeFileAtomically(path: string, data: string | ArrayBuffer): void {
  const temp = path + '.part';
  removeFileQuietly(temp);
  writeFile(temp, data);
  removeFileQuietly(path);
  fileIo.moveFileSync(temp, path);
}

function sanitizePathSegment(value: string): string {
  const trimmed = value.trim();
  const safe = trimmed.replace(/[\\/:*?"<>|]/g, '_').replace(/\.+$/g, '');
  return safe.length > 0 ? safe : '未命名漫画';
}

function chapterFolderName(uuid: string): string {
  const shortId = uuid.substring(0, Math.min(8, uuid.length));
  return '章节_' + shortId;
}

function threeDigitIndex(index: number): string {
  let value = Math.max(0, index).toString();
  while (value.length < 3) {
    value = '0' + value;
  }
  return value;
}

function imageExtension(url: string): string {
  const clean = url.split('?')[0].toLowerCase();
  return clean.endsWith('.jpg') || clean.endsWith('.jpeg') ? '.jpg' : '.webp';
}

function isImageName(name: string): boolean {
  const lower = name.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.webp');
}

function fileIsComplete(path: string): boolean {
  try {
    return fileIo.statSync(path).size > 0;
  } catch (error) {
    return false;
  }
}

function directorySize(path: string): number {
  if (!exists(path)) {
    return 0;
  }
  try {
    const stat = fileIo.statSync(path);
    if (!stat.isDirectory()) {
      return stat.size;
    }
    let bytes = 0;
    const names = fileIo.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      bytes += directorySize(path + '/' + names[i]);
    }
    return bytes;
  } catch (error) {
    return 0;
  }
}

function isChapterFolderName(name: string): boolean {
  return name.startsWith('章节_');
}

function baseName(path: string): string {
  const index = path.lastIndexOf('/');
  return index >= 0 ? path.substring(index + 1) : path;
}

/** 作品目录一层成员名：剔除索引文件自身与其原子写临时文件，并排序，便于集合比对。 */
function indexMembers(names: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < names.length; i++) {
    const name = names[i];
    if (name === INDEX_FILE || name === INDEX_FILE + '.part') {
      continue;
    }
    result.push(name);
  }
  result.sort();
  return result;
}

function sortedCopy(values: string[]): string[] {
  const copy: string[] = values.slice();
  copy.sort();
  return copy;
}

/** 老数据里可能缺字段 / 非字符串：统一兜成空串，避免读取方直接 .length 抛异常。 */
function safeText(value: string | undefined | null): string {
  return value !== undefined && value !== null ? value : '';
}

/** 取章节名里首个数字串（自然序用）；没有数字返回 -1。 */
function nameNumber(name: string): number {
  // 手写扫描，避免正则 / match 的返回类型在 ArkTS 下不确定
  let start = -1;
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (code >= 48 && code <= 57) {
      start = i;
      break;
    }
  }
  if (start < 0) {
    return -1;
  }
  let end = start;
  while (end < name.length) {
    const code = name.charCodeAt(end);
    if (code < 48 || code > 57) {
      break;
    }
    end++;
  }
  const parsed = parseInt(name.substring(start, end), 10);
  return isNaN(parsed) ? -1 : parsed;
}

/**
 * 章节名自然序（数字感知）：第2话 < 第10话。
 * 双方都有数字 → 先比数字、相同再比名字；一方无数字 → 有数字的排前；
 * 都无数字 → 退回名字字典序。用于老数据 / 无 orderIndex 时的兜底排序。
 */
function compareChapterName(left: string, right: string): number {
  const leftNumber = nameNumber(left);
  const rightNumber = nameNumber(right);
  if (leftNumber >= 0 && rightNumber >= 0) {
    if (leftNumber !== rightNumber) {
      return leftNumber - rightNumber;
    }
    return left.localeCompare(right);
  }
  if (leftNumber >= 0) {
    return -1;
  }
  if (rightNumber >= 0) {
    return 1;
  }
  return left.localeCompare(right);
}

/**
 * 章节条目排序，与「详情页默认（正序）列表」对齐：
 *   全部条目都带 orderIndex（新数据）→ 按 orderIndex 升序；
 *   任一条目缺失（旧数据 / 旧索引）→ 整表退回自然序。
 * 混合场景统一走自然序：两种序混排会产生非良序比较器，反而更乱。
 */
function sortedChapterEntries(entries: StoredIndexChapter[]): StoredIndexChapter[] {
  const copy: StoredIndexChapter[] = entries.slice();
  let allOrdered = copy.length > 0;
  for (let i = 0; i < copy.length; i++) {
    if (copy[i].orderIndex === undefined) {
      allOrdered = false;
      break;
    }
  }
  if (allOrdered) {
    copy.sort((left: StoredIndexChapter, right: StoredIndexChapter): number => {
      const leftOrder = left.orderIndex !== undefined ? left.orderIndex : 0;
      const rightOrder = right.orderIndex !== undefined ? right.orderIndex : 0;
      if (leftOrder !== rightOrder) {
        return leftOrder - rightOrder;
      }
      return compareChapterName(left.name, right.name);
    });
  } else {
    copy.sort((left: StoredIndexChapter, right: StoredIndexChapter): number =>
      compareChapterName(left.name, right.name));
  }
  return copy;
}

function readMeta(directory: string): StoredChapterMeta | null {
  const path = directory + '/' + META_FILE;
  if (!exists(path)) {
    return null;
  }
  try {
    return JSON.parse(fileIo.readTextSync(path)) as StoredChapterMeta;
  } catch (error) {
    return null;
  }
}

/** meta 里的 comicId：老文件可能整个字段都缺，读出来统一兜成空串，避免调用方 .length 直接抛。 */
function metaComicId(meta: StoredChapterMeta | null): string {
  if (meta === null) {
    return '';
  }
  const value = meta.comicId as string | undefined;
  return value !== undefined && value !== null ? value : '';
}

function imagePaths(directory: string): string[] {
  const result: string[] = [];
  if (!exists(directory)) {
    return result;
  }
  try {
    const names = fileIo.listFileSync(directory);
    names.sort();
    for (let i = 0; i < names.length; i++) {
      if (isImageName(names[i])) {
        result.push(directory + '/' + names[i]);
      }
    }
  } catch (error) {
  }
  return result;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout(() => resolve(), ms);
  });
}

function taskKey(comicId: string, chapterId: string): string {
  return comicId + ':' + chapterId;
}

export class DownloadCancelledError extends Error {
  constructor() {
    super('下载已取消');
    this.name = 'DownloadCancelledError';
  }
}

/** 停滞守护命中：连续 90s 无进度产物，该章按失败流程收口（可重试）。 */
export class DownloadStalledError extends Error {
  constructor() {
    super('下载停滞');
    this.name = 'DownloadStalledError';
  }
}

export class DownloadStore {
  private tasks: Map<string, ChapterDownloadState> = new Map<string, ChapterDownloadState>();
  /** 进行中的封面补拉（按作品目录去重）：并发触发时共用同一次请求。 */
  private coverTasks: Map<string, Promise<void>> = new Map<string, Promise<void>>();
  /**
   * store 级排队序列：只收 Queued 任务，数组顺序＝执行顺序（先入先出）。
   * 任务对象与 tasks 表里是同一份引用，状态一律写在 ChapterDownloadState 上。
   */
  private queue: ChapterDownloadState[] = [];
  /** 单飞执行器的在途 Promise：非 null 表示 runQueue 已经在跑，后来者复用同一个。 */
  private queuePromise: Promise<void> | null = null;
  /** 本批任务键（最近一次 enqueueChapters 真正入队的那些），批次视图按它统计。 */
  private batchKeys: string[] = [];
  /** 批次视图（只读出口）：详情页浮条、选择条都读它，进度由执行器维护。 */
  readonly batchView: DownloadBatchView = new DownloadBatchView();

  downloadRoot(): string {
    return appContext().filesDir + '/' + DOWNLOAD_FOLDER;
  }

  comicDirectory(comicName: string): string {
    return this.downloadRoot() + '/' + sanitizePathSegment(comicName);
  }

  chapterDirectory(comicName: string, chapterId: string): string {
    return this.comicDirectory(comicName) + '/' + chapterFolderName(chapterId);
  }

  taskFor(request: ChapterDownloadRequest): ChapterDownloadState {
    const key = taskKey(request.comicId, request.chapterId);
    let task = this.tasks.get(key);
    if (task === undefined) {
      task = new ChapterDownloadState();
      this.tasks.set(key, task);
    }
    // 展示名与重跑请求随取任务刷新：详情页每次 build 都会调这里，
    // 名字只在真的变了才写，避免对同值 @Trace 反复赋值
    if (task.comicName !== request.comicName) {
      task.comicName = request.comicName;
    }
    if (task.chapterName !== request.chapterName) {
      task.chapterName = request.chapterName;
    }
    task.request = request;
    // Queued 与 Downloading 都不动状态：排队中的任务正等执行器轮到，
    // 这里若按磁盘重算会把 Queued 冲回 Idle（丢出队列语义）。
    if (task.status !== ChapterDownloadStatus.Downloading &&
      task.status !== ChapterDownloadStatus.Queued) {
      task.status = this.isChapterComplete(request.comicName, request.chapterId) ?
        ChapterDownloadStatus.Completed : task.status === ChapterDownloadStatus.Failed ?
          ChapterDownloadStatus.Failed : ChapterDownloadStatus.Idle;
    }
    return task;
  }

  isChapterComplete(comicName: string, chapterId: string): boolean {
    return exists(this.chapterDirectory(comicName, chapterId) + '/' + DONE_FILE);
  }

  cancel(comicId: string, chapterId: string): void {
    const task = this.tasks.get(taskKey(comicId, chapterId));
    if (task === undefined) {
      return;
    }
    if (task.status === ChapterDownloadStatus.Queued) {
      // 排队中：出队置 Cancelled，还没跑过，不需要碰任何网络请求
      this.dequeue(task);
      task.cancelRequested = true;
      task.status = ChapterDownloadStatus.Cancelled;
      task.errorText = '';
      this.refreshBatchView();
      return;
    }
    if (task.status !== ChapterDownloadStatus.Downloading) {
      return;
    }
    task.cancelRequested = true;
    task.status = ChapterDownloadStatus.Cancelled;
    task.activeRequests.forEach((request: http.HttpRequest) => {
      try {
        request.destroy();
      } catch (error) {
      }
    });
    task.activeRequests.clear();
    this.refreshBatchView();
  }

  /** 按 map 键（comicId:chapterId）取消：键与任务一一对应，队列与批次共用同一把钥匙。 */
  private cancelKey(key: string): void {
    const at = key.indexOf(':');
    if (at > 0) {
      this.cancel(key.substring(0, at), key.substring(at + 1));
    }
  }

  /** 从排队序列里摘掉一个任务：只动顺序数组，状态由调用方写。 */
  private dequeue(task: ChapterDownloadState): void {
    const index = this.queue.indexOf(task);
    if (index >= 0) {
      this.queue.splice(index, 1);
    }
  }

  /** 队列位置（1 起）；不在队里返回 0。供下载管理页 / 详情行展示「第几位」。 */
  queuePosition(task: ChapterDownloadState): number {
    const index = this.queue.indexOf(task);
    return index >= 0 ? index + 1 : 0;
  }

  /**
   * 只读枚举当前任务表：供下载管理页做「列表增删」的内存重扫。
   *
   * 不走 taskFor——它会改 status、可能打磁盘（isChapterComplete），还会新建项；
   * 这里只读 Map、原样返回对象引用（引用共享是刻意的：行内数值靠 @Trace 直连自动刷新）。
   * Completed / Cancelled / Idle 一律不进快照：不做破坏性清理，详情页持有的引用保持有效。
   * Queued 进快照（管理页的「等待中」组）：排队是活状态，不展示就等于任务凭空消失。
   */
  snapshotTasks(): ChapterDownloadState[] {
    const result: ChapterDownloadState[] = [];
    this.tasks.forEach((task: ChapterDownloadState): void => {
      if (task.status === ChapterDownloadStatus.Downloading ||
        task.status === ChapterDownloadStatus.Queued) {
        result.push(task);
        return;
      }
      if (task.status === ChapterDownloadStatus.Failed && !task.dismissed) {
        result.push(task);
      }
    });
    return result;
  }

  /**
   * 失败项从下载管理页移除：只打标记（snapshot 从此过滤掉它），不删任务对象、不动磁盘。
   * 后续若在详情页重试，downloadChapter 开跑时会清掉这个标记，失败会重新出现。
   */
  dismissFailed(task: ChapterDownloadState): void {
    if (task.status !== ChapterDownloadStatus.Failed) {
      return;
    }
    task.dismissed = true;
  }

  /**
   * 取消全部活任务：运行中的 + 排队中的，枚举后逐个走既有单章 cancel()——
   * 收口状态、掐在途请求、排队出队与单章取消完全同一套代码，不另造取消路径。
   * 执行器 drainQueue 取下一项时发现队列已空（或拿到的任务已非 Queued）会安全退出，
   * 所以这里能把整批连同后续排队一并停掉。
   *
   * @return 实际取消掉的章节数。
   */
  cancelAll(): number {
    let count = 0;
    const keys: string[] = [];
    this.tasks.forEach((task: ChapterDownloadState, key: string): void => {
      if (task.status === ChapterDownloadStatus.Downloading ||
        task.status === ChapterDownloadStatus.Queued) {
        keys.push(key);
      }
    });
    for (let i = 0; i < keys.length; i++) {
      this.cancelKey(keys[i]);
      count++;
    }
    this.refreshBatchView();
    return count;
  }

  /**
   * 批量入队：按传入顺序把每章注册为 Queued（写好展示名与重跑请求所需信息），
   * 并把「本次真正入队的这些」记为本批（批次视图 total＝返回值）。
   * 只入队不执行：执行交给 runQueue() 的单飞串行执行器。
   *
   * 已完成（磁盘 .done 优先）/ 正在下载 / 已在队里 / 正在收口的章跳过，不重复入队。
   *
   * @return 本次真正入队的章节数。
   */
  enqueueChapters(requests: ChapterDownloadRequest[]): number {
    const added: ChapterDownloadState[] = [];
    const keys: string[] = [];
    for (let i = 0; i < requests.length; i++) {
      const request = requests[i];
      const task = this.taskFor(request);
      const status = task.status;
      if (status === ChapterDownloadStatus.Queued ||
        status === ChapterDownloadStatus.Downloading ||
        status === ChapterDownloadStatus.Completed ||
        task.inFlight) {
        continue;
      }
      task.status = ChapterDownloadStatus.Queued;
      task.cancelRequested = false;
      task.stalled = false;
      task.completed = 0;
      task.total = 0;
      task.errorText = '';
      task.dismissed = false;
      added.push(task);
      keys.push(taskKey(request.comicId, request.chapterId));
    }
    if (added.length > 0) {
      this.batchKeys = keys;
      for (let i = 0; i < added.length; i++) {
        this.queue.push(added[i]);
      }
    }
    this.refreshBatchView();
    return added.length;
  }

  /**
   * 单飞串行执行器：反复取队首 Queued 任务执行到收口，再取下一个，直到队列清空。
   * 已经有执行器在跑时直接返回同一个 Promise（单飞），调用方 await 到的就是整队结束。
   * 取消 / 清空队列会让循环自然退出；队列本来就是空的则立即返回完成态。
   */
  runQueue(): Promise<void> {
    if (this.queuePromise !== null) {
      return this.queuePromise;
    }
    if (this.queue.length === 0) {
      this.refreshBatchView();
      return Promise.resolve();
    }
    const loop = this.drainQueue();
    const tracked: Promise<void> = loop.then((): void => {
      this.queuePromise = null;
    }, (_error: Object): void => {
      this.queuePromise = null;
    });
    this.queuePromise = tracked;
    return tracked;
  }

  /** 取消本批（批次视图里登记的那些章）：在跑的收口、排队的出队，其余任务不受影响。 */
  cancelBatch(): number {
    let count = 0;
    for (let i = 0; i < this.batchKeys.length; i++) {
      const task = this.tasks.get(this.batchKeys[i]);
      if (task === undefined) {
        continue;
      }
      const status = task.status;
      if (status !== ChapterDownloadStatus.Queued && status !== ChapterDownloadStatus.Downloading) {
        continue;
      }
      this.cancelKey(this.batchKeys[i]);
      count++;
    }
    this.refreshBatchView();
    return count;
  }

  private async drainQueue(): Promise<void> {
    while (this.queue.length > 0) {
      const task = this.queue[0];
      this.queue.shift();
      if (task.status !== ChapterDownloadStatus.Queued) {
        // 已被取消（出队与执行之间的竞态）：出队即走，不启动下载
        this.refreshBatchView();
        continue;
      }
      const request = task.request;
      if (request === null) {
        // 理论上走不到：enqueueChapters 必写 request。保底不空跑
        task.status = ChapterDownloadStatus.Cancelled;
        this.refreshBatchView();
        continue;
      }
      this.refreshBatchView();
      try {
        await this.runChapterTask(task, request);
      } catch (error) {
        // runChapterTask 内部把成功 / 失败 / 取消全部收口，这里只兜底，绝不外抛
      }
      this.refreshBatchView();
    }
    this.refreshBatchView();
  }

  /**
   * 批次视图重算（唯一数据源＝tasks 表）：按本批键统计 total / done / running / 当前章名。
   * Failed / Cancelled 的章既不算完成也不占队列（running 只看 Queued 与 Downloading）。
   * 只在值真的变了才写 @Trace，避免执行器每收一章都无谓触发重绘。
   */
  private refreshBatchView(): void {
    const view = this.batchView;
    if (this.batchKeys.length === 0) {
      if (view.running) {
        view.running = false;
      }
      if (view.total !== 0) {
        view.total = 0;
      }
      if (view.done !== 0) {
        view.done = 0;
      }
      if (view.currentChapterName !== '') {
        view.currentChapterName = '';
      }
      return;
    }
    let done = 0;
    let pending = 0;
    let runningName = '';
    let queuedName = '';
    for (let i = 0; i < this.batchKeys.length; i++) {
      const task = this.tasks.get(this.batchKeys[i]);
      if (task === undefined) {
        continue;
      }
      const status = task.status;
      if (status === ChapterDownloadStatus.Completed) {
        done++;
      } else if (status === ChapterDownloadStatus.Downloading) {
        pending++;
        if (runningName.length === 0) {
          runningName = task.chapterName;
        }
      } else if (status === ChapterDownloadStatus.Queued) {
        pending++;
        if (queuedName.length === 0) {
          queuedName = task.chapterName;
        }
      }
    }
    const currentName = runningName.length > 0 ? runningName : queuedName;
    const running = pending > 0;
    if (view.total !== this.batchKeys.length) {
      view.total = this.batchKeys.length;
    }
    if (view.done !== done) {
      view.done = done;
    }
    if (view.running !== running) {
      view.running = running;
    }
    if (view.currentChapterName !== currentName) {
      view.currentChapterName = currentName;
    }
  }

  /** 单章直下的入口：保持「立即 Downloading」，不进队列（排队只给批量批次用）。 */
  async downloadChapter(request: ChapterDownloadRequest,
    onProgress?: ChapterDownloadProgressCallback): Promise<ChapterDownloadState> {
    const task = this.taskFor(request);
    if (task.status === ChapterDownloadStatus.Downloading || task.status === ChapterDownloadStatus.Completed) {
      return task;
    }
    if (task.status === ChapterDownloadStatus.Queued) {
      // 排队中：交给 runQueue 按序执行，不抢跑；想取消走 cancel()（出队）
      return task;
    }
    if (task.inFlight) {
      // 上一次调用还在收口（例如停滞守护刚判失败、链路尚未返回）：不并发重入，
      // 直接把当前失败态交还调用方，等它 finally 收口后再重试。
      return task;
    }
    return this.runChapterTask(task, request, onProgress);
  }

  /**
   * 单章执行内核（单章直下与队列执行器共用）：置 Downloading → 拉页清单 → 4 路并发落盘
   * → 写 .done；停滞守护 / inFlight / 进度上报 / 索引收口语义都在这里，两条路径完全一致。
   * 所有结果（Completed / Failed / Cancelled）都在内部收口，不向外抛。
   */
  private async runChapterTask(task: ChapterDownloadState, request: ChapterDownloadRequest,
    onProgress?: ChapterDownloadProgressCallback): Promise<ChapterDownloadState> {
    task.status = ChapterDownloadStatus.Downloading;
    task.cancelRequested = false;
    task.stalled = false;
    task.completed = 0;
    task.total = 0;
    task.errorText = '';
    task.dismissed = false;
    task.lastProgressAt = Date.now();
    this.refreshBatchView();

    const comicDirectory = this.comicDirectory(request.comicName);
    const chapterDirectory = this.chapterDirectory(request.comicName, request.chapterId);
    const donePath = chapterDirectory + '/' + DONE_FILE;
    task.inFlight = true;
    const stallGuard = this.startStallGuard(task);
    try {
      ensureDirectory(this.downloadRoot());
      ensureDirectory(comicDirectory);
      ensureDirectory(chapterDirectory);
      removeFileQuietly(donePath);
      this.writeChapterMeta(chapterDirectory, request);
      // 顺手把封面（URL + 图片字节）落到作品目录：离线后下载页照样显示头图。
      // 后台跑、失败静默，既不 await 也不影响本次章节下载。
      this.ensureComicCover(comicDirectory, request.comicId).catch((_error: Object): void => {});
      await this.updateChaptersManifest(comicDirectory, request);

      // 图源由设置决定：chapterSource='webview' 走隐藏收图，否则走 API。
      // allowLocal=false：下载必须走网络，避免「查到本地→返回本地」导致零字节下载。
      const urls = await loadChapterImages(request.comicId, request.chapterId, false);
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (task.stalled) {
        throw new DownloadStalledError();
      }
      if (urls.length === 0) {
        throw new Error('章节没有可下载的图片');
      }
      task.total = urls.length;
      // 取到页清单算一个进度产物：停滞计时从这里重新起算
      task.lastProgressAt = Date.now();
      const queue: DownloadQueue = { nextIndex: 0 };
      const workers: Promise<void>[] = [];
      for (let i = 0; i < DOWNLOAD_CONCURRENCY; i++) {
        workers.push(this.runWorker(task, queue, urls, chapterDirectory, onProgress));
      }
      await Promise.all(workers);
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (task.stalled) {
        throw new DownloadStalledError();
      }
      writeFileAtomically(donePath, 'done');
      task.status = ChapterDownloadStatus.Completed;
      task.completed = task.total;
      this.reportProgress(task, onProgress);
      return task;
    } catch (error) {
      removeFileQuietly(donePath);
      task.activeRequests.forEach((active: http.HttpRequest) => {
        try {
          active.destroy();
        } catch (_error) {
        }
      });
      task.activeRequests.clear();
      if (task.cancelRequested || error instanceof DownloadCancelledError) {
        task.status = ChapterDownloadStatus.Cancelled;
        task.errorText = '';
      } else if (task.stalled || error instanceof DownloadStalledError) {
        // 停滞：沿用既有失败流程（errorText 展示在章节行上，可重试）
        task.status = ChapterDownloadStatus.Failed;
        task.errorText = '下载停滞';
      } else {
        task.status = ChapterDownloadStatus.Failed;
        const value = error as Error;
        task.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '下载失败';
      }
      return task;
    } finally {
      clearInterval(stallGuard);
      task.inFlight = false;
      // 成功 / 失败 / 取消都在此收口：把该章当前磁盘状态补进索引，保持索引与目录同步
      this.syncIndexChapter(comicDirectory, request, chapterDirectory);
      // 批次视图跟着收口刷新（done / running / 当前章名），单章直下也走这里
      this.refreshBatchView();
    }
  }

  /**
   * 停滞守护（单章直下与队列执行器共用：两条路径都经 runChapterTask，每章各起一个守护）。
   * 每 STALL_CHECK_INTERVAL_MS 查一次，连续 STALL_TIMEOUT_MS 没有进度产物就置 stalled、
   * 掐断在途请求，让本章尽快按「下载停滞」失败收口；守护本身随本章结束必被 clearInterval。
   */
  private startStallGuard(task: ChapterDownloadState): number {
    return setInterval((): void => {
      if (task.stalled || task.status !== ChapterDownloadStatus.Downloading) {
        return;
      }
      if (Date.now() - task.lastProgressAt < STALL_TIMEOUT_MS) {
        return;
      }
      task.stalled = true;
      task.status = ChapterDownloadStatus.Failed;
      task.errorText = '下载停滞';
      task.activeRequests.forEach((request: http.HttpRequest) => {
        try {
          request.destroy();
        } catch (error) {
        }
      });
      task.activeRequests.clear();
    }, STALL_CHECK_INTERVAL_MS);
  }

  private async runWorker(task: ChapterDownloadState, queue: DownloadQueue, urls: string[], directory: string,
    onProgress?: ChapterDownloadProgressCallback): Promise<void> {
    while (true) {
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (task.stalled) {
        throw new DownloadStalledError();
      }
      const index = queue.nextIndex;
      queue.nextIndex++;
      if (index >= urls.length) {
        return;
      }
      const url = wrapResolution(urls[index]);
      const target = directory + '/' + threeDigitIndex(index) + imageExtension(url);
      const existing = this.existingPageFile(directory, index);
      if (existing.length === 0) {
        await this.downloadImage(task, index, url, target);
      }
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (task.stalled) {
        throw new DownloadStalledError();
      }
      task.completed++;
      // 每落盘一页就是一个进度产物：停滞计时刷新
      task.lastProgressAt = Date.now();
      this.reportProgress(task, onProgress);
    }
  }

  private existingPageFile(directory: string, index: number): string {
    const stem = directory + '/' + threeDigitIndex(index);
    const candidates: string[] = [stem + '.webp', stem + '.jpg'];
    for (let i = 0; i < candidates.length; i++) {
      if (fileIsComplete(candidates[i])) {
        return candidates[i];
      }
    }
    return '';
  }

  private async downloadImage(task: ChapterDownloadState, index: number, url: string, target: string): Promise<void> {
    let lastError = '图片下载失败';
    for (let attempt = 0; attempt <= IMAGE_RETRIES; attempt++) {
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (task.stalled) {
        throw new DownloadStalledError();
      }
      let request: http.HttpRequest | null = null;
      try {
        request = http.createHttp();
        task.activeRequests.set(index, request);
        const response = await request.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': kDesktopUserAgent,
            'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
          },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false,
          maxLimit: 100 * 1024 * 1024,
          connectTimeout: IMAGE_TIMEOUT_MS,
          readTimeout: IMAGE_TIMEOUT_MS
        });
        if (task.cancelRequested) {
          throw new DownloadCancelledError();
        }
        const status = Number(response.responseCode);
        if (status < 200 || status >= 300) {
          throw new Error('HTTP ' + status);
        }
        if (!(response.result instanceof ArrayBuffer) || response.result.byteLength === 0) {
          throw new Error('图片响应为空');
        }
        writeFileAtomically(target, response.result);
        return;
      } catch (error) {
        if (task.cancelRequested || error instanceof DownloadCancelledError) {
          throw new DownloadCancelledError();
        }
        if (task.stalled) {
          throw new DownloadStalledError();
        }
        const value = error as Error;
        lastError = value.message !== undefined && value.message.length > 0 ? value.message : String(error);
        removeFileQuietly(target + '.part');
        if (attempt < IMAGE_RETRIES) {
          await delay(500 * (attempt + 1));
        }
      } finally {
        task.activeRequests.delete(index);
        try {
          request?.destroy();
        } catch (error) {
        }
      }
    }
    throw new Error(lastError);
  }

  private reportProgress(task: ChapterDownloadState, callback?: ChapterDownloadProgressCallback): void {
    if (callback !== undefined) {
      callback({ completed: task.completed, total: task.total });
    }
  }

  private writeChapterMeta(directory: string, request: ChapterDownloadRequest): void {
    const meta: StoredChapterMeta = {
      uuid: request.chapterId,
      comicId: request.comicId,
      name: request.chapterName,
      comicName: request.comicName
    };
    if (request.orderIndex !== undefined) {
      meta.orderIndex = request.orderIndex;
    }
    writeFileAtomically(directory + '/' + META_FILE, JSON.stringify(meta));
  }

  private async updateChaptersManifest(comicDirectory: string, request: ChapterDownloadRequest): Promise<void> {
    await UrlManager.bootstrap();
    const path = comicDirectory + '/' + CHAPTERS_FILE;
    let groups: StoredChapterGroup[] = [];
    if (exists(path)) {
      try {
        const parsed = JSON.parse(fileIo.readTextSync(path)) as StoredChapterGroup[];
        if (Array.isArray(parsed)) {
          groups = parsed;
        }
      } catch (error) {
        groups = [];
      }
    }
    let group: StoredChapterGroup | undefined = undefined;
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].name === 'default') {
        group = groups[i];
        break;
      }
    }
    if (group === undefined) {
      group = { name: 'default', chapters: [] };
      groups.push(group);
    }
    const url = UrlManager.activeUrl + '/comic/' + request.comicId + '/chapter/' + request.chapterId;
    let replaced = false;
    for (let i = 0; i < group.chapters.length; i++) {
      if (group.chapters[i].url.endsWith('/' + request.chapterId)) {
        group.chapters[i] = { name: request.chapterName, url: url };
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      group.chapters.push({ name: request.chapterName, url: url });
    }
    writeFileAtomically(path, JSON.stringify(groups));
  }

  /**
   * 作品列表：优先读每部漫画目录内的 .index.json（一次小文件读 + 一层成员校验），
   * 索引缺失 / 与磁盘一层成员不一致时按旧逻辑整目录扫一遍并写回（旧数据一次性迁移）。
   *
   * 「我的下载」只认已完成（.done）章节：只统计 completed 的章，
   * 一章都没完成的作品直接不出现在网格里（未完成的只在下载管理可见）。
   * bytes 仍取整部目录总占用（含未完成章的字节），让「占用」数字如实反映磁盘。
   */
  listDownloadedComics(): DownloadedComicInfo[] {
    const started = Date.now();
    const root = this.downloadRoot();
    const comics: DownloadedComicInfo[] = [];
    if (!exists(root)) {
      return comics;
    }
    try {
      const names = fileIo.listFileSync(root);
      for (let i = 0; i < names.length; i++) {
        const directory = root + '/' + names[i];
        if (!fileIo.statSync(directory).isDirectory()) {
          continue;
        }
        const index = this.loadValidIndex(directory);
        if (index === null || index.chapters.length === 0) {
          continue;
        }
        const ordered = this.orderedEntries(index);
        const completed: StoredIndexChapter[] = [];
        for (let j = 0; j < ordered.length; j++) {
          if (ordered[j].completed) {
            completed.push(ordered[j]);
          }
        }
        if (completed.length === 0) {
          continue;
        }
        let pages = 0;
        for (let j = 0; j < completed.length; j++) {
          pages += completed[j].pageCount;
        }
        const displayName = completed[0].comicName.length > 0 ? completed[0].comicName : names[i];
        comics.push({
          name: displayName,
          comicId: this.firstIndexComicId(completed),
          directory: directory,
          chapterCount: completed.length,
          completedCount: completed.length,
          pageCount: pages,
          bytes: this.comicBytes(index)
        });
      }
    } catch (error) {
      return [];
    }
    comics.sort((left: DownloadedComicInfo, right: DownloadedComicInfo) => left.name.localeCompare(right.name));
    hilog.info(0x0000, 'Collector', '%{public}s',
      '下载列表扫描 ' + comics.length + ' 部 ' + (Date.now() - started) + 'ms');
    return comics;
  }

  /**
   * 章节列表：只列已完成（.done，取索引里的 completed 字段）的章节。
   * 离线打开、上下章序列、删除后的重写名单都基于它 —— 与「我的下载」同一套「仅完成章」语义。
   */
  listDownloadedChapters(comicDirectory: string): DownloadedChapterInfo[] {
    const chapters: DownloadedChapterInfo[] = [];
    if (!exists(comicDirectory)) {
      return chapters;
    }
    try {
      const index = this.loadValidIndex(comicDirectory);
      if (index === null) {
        return chapters;
      }
      return this.chaptersFromIndex(comicDirectory, index, true);
    } catch (error) {
      return [];
    }
  }

  /**
   * 章节列表（全部，含未完成）：清理逻辑专用，只读，不改任何既有语义。
   *
   * listDownloadedChapters 只列完成章（「我的下载」语义），于是未完成章既不在清理
   * 名单里、也数不进「保留」数量。清理前需要一份「这部作品里所有被识别出来的章节
   * 目录」——含索引里 completed 为 false 的残留 / 下载中章——用来判定「名单外的新
   * 目录」并统计未完成数。它来自索引的 chapters 数组，含全部条目。
   */
  listAllChapters(comicDirectory: string): DownloadedChapterInfo[] {
    const chapters: DownloadedChapterInfo[] = [];
    if (!exists(comicDirectory)) {
      return chapters;
    }
    try {
      const index = this.loadValidIndex(comicDirectory);
      if (index === null) {
        return chapters;
      }
      return this.chaptersFromIndex(comicDirectory, index, false);
    } catch (error) {
      return [];
    }
  }

  private indexFilePath(comicDirectory: string): string {
    return comicDirectory + '/' + INDEX_FILE;
  }

  private writeIndex(comicDirectory: string, index: StoredComicIndex): void {
    index.version = INDEX_VERSION;
    writeFileAtomically(this.indexFilePath(comicDirectory), JSON.stringify(index));
  }

  private readIndexRaw(comicDirectory: string): StoredComicIndex | null {
    const path = this.indexFilePath(comicDirectory);
    if (!exists(path)) {
      return null;
    }
    try {
      const parsed = JSON.parse(fileIo.readTextSync(path)) as StoredComicIndex;
      if (parsed === null || parsed === undefined) {
        return null;
      }
      if (parsed.version !== INDEX_VERSION) {
        return null;
      }
      if (!Array.isArray(parsed.members) || !Array.isArray(parsed.chapters)) {
        return null;
      }
      if (typeof parsed.otherBytes !== 'number') {
        return null;
      }
      return parsed;
    } catch (error) {
      return null;
    }
  }

  /** 索引记录的成员集合是否与目录一层完全一致（数量 + 名称，顺序无关）。 */
  private membersMatch(comicDirectory: string, expected: string[]): boolean {
    let names: string[] = [];
    try {
      names = indexMembers(fileIo.listFileSync(comicDirectory));
    } catch (error) {
      return false;
    }
    if (names.length !== expected.length) {
      return false;
    }
    const want = sortedCopy(expected);
    for (let i = 0; i < names.length; i++) {
      if (names[i] !== want[i]) {
        return false;
      }
    }
    return true;
  }

  private loadValidIndex(comicDirectory: string): StoredComicIndex | null {
    if (!exists(comicDirectory)) {
      return null;
    }
    const raw = this.readIndexRaw(comicDirectory);
    if (raw !== null && this.membersMatch(comicDirectory, raw.members)) {
      return raw;
    }
    return this.rebuildIndex(comicDirectory);
  }

  /** 只读路径用：能直接用现有索引就用，否则返回 null（由调用方走旧递归兜底，不写盘）。 */
  private peekValidIndex(comicDirectory: string): StoredComicIndex | null {
    const raw = this.readIndexRaw(comicDirectory);
    if (raw !== null && this.membersMatch(comicDirectory, raw.members)) {
      return raw;
    }
    return null;
  }

  /** 旧数据迁移 / 校验失败重建：按旧逻辑扫一遍整部作品，写入索引并打耗时日志。 */
  private rebuildIndex(comicDirectory: string): StoredComicIndex {
    const started = Date.now();
    const index: StoredComicIndex = {
      version: INDEX_VERSION,
      members: [],
      otherBytes: 0,
      chapters: []
    };
    let names: string[] = [];
    try {
      names = indexMembers(fileIo.listFileSync(comicDirectory));
    } catch (error) {
      names = [];
    }
    index.members = names;
    let other = 0;
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const path = comicDirectory + '/' + name;
      let isDirectory = false;
      try {
        isDirectory = fileIo.statSync(path).isDirectory();
      } catch (error) {
        continue;
      }
      if (isDirectory && isChapterFolderName(name)) {
        const meta = readMeta(path);
        if (meta === null) {
          // mkdir 与 meta 落盘之间的中间态目录：不进章节列表，下次完成时补录
          continue;
        }
        const metaName = safeText(meta.name);
        const images = imagePaths(path);
        const rebuilt: StoredIndexChapter = {
          folder: name,
          name: metaName.length > 0 ? metaName : name,
          uuid: safeText(meta.uuid),
          comicId: metaComicId(meta),
          comicName: safeText(meta.comicName),
          completed: exists(path + '/' + DONE_FILE),
          pageCount: images.length,
          bytes: directorySize(path)
        };
        if (meta.orderIndex !== undefined) {
          rebuilt.orderIndex = meta.orderIndex;
        }
        index.chapters.push(rebuilt);
      } else {
        other += directorySize(path);
      }
    }
    index.otherBytes = other;
    this.writeIndex(comicDirectory, index);
    hilog.info(0x0000, 'Collector', '%{public}s',
      '下载列表扫描 重建 ' + baseName(comicDirectory) + ' ' + (Date.now() - started) + 'ms 章节=' +
        index.chapters.length);
    return index;
  }

  /** 增量刷新一层成员名与非章节字节（封面 / chapters.json 等），避免被误判为不一致而重建。 */
  private refreshIndexMeta(comicDirectory: string, index: StoredComicIndex): void {
    let names: string[] = [];
    try {
      names = indexMembers(fileIo.listFileSync(comicDirectory));
    } catch (error) {
      return;
    }
    index.members = names;
    let other = 0;
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (isChapterFolderName(name)) {
        continue;
      }
      other += directorySize(comicDirectory + '/' + name);
    }
    index.otherBytes = other;
  }

  /** 封面落盘后只刷新元信息，不重扫章节（索引缺失时留给下次重建补记）。 */
  private refreshComicIndex(comicDirectory: string): void {
    const index = this.readIndexRaw(comicDirectory);
    if (index === null) {
      return;
    }
    this.refreshIndexMeta(comicDirectory, index);
    this.writeIndex(comicDirectory, index);
  }

  /** 单章收口（成功 / 失败 / 取消均调）：把该章当前磁盘状态补进索引。 */
  private syncIndexChapter(comicDirectory: string, request: ChapterDownloadRequest,
    chapterDirectory: string): void {
    if (!exists(comicDirectory) || !exists(chapterDirectory)) {
      return;
    }
    let index = this.readIndexRaw(comicDirectory);
    if (index === null) {
      index = this.rebuildIndex(comicDirectory);
    }
    const folder = chapterFolderName(request.chapterId);
    let orderIndex = request.orderIndex;
    const entry: StoredIndexChapter = {
      folder: folder,
      name: request.chapterName,
      uuid: request.chapterId,
      comicId: request.comicId,
      comicName: request.comicName,
      completed: exists(chapterDirectory + '/' + DONE_FILE),
      pageCount: imagePaths(chapterDirectory).length,
      bytes: directorySize(chapterDirectory)
    };
    let found = -1;
    for (let i = 0; i < index.chapters.length; i++) {
      if (index.chapters[i].folder === folder) {
        // 请求缺 orderIndex（老调用）时保留索引里已有的序号，避免把新数据冲回旧值
        if (orderIndex === undefined) {
          orderIndex = index.chapters[i].orderIndex;
        }
        found = i;
        break;
      }
    }
    if (orderIndex !== undefined) {
      entry.orderIndex = orderIndex;
    }
    // 标准 upsert：命中则整条覆盖写回，未命中才追加。此前命中分支只 break 不写回，
    // 导致该章本次同步（completed/pageCount/bytes/orderIndex）全部落空、索引永久陈旧。
    // 真机实证：批量下载中某章先被 rebuildIndex 记成 completed:false，随后下载成功也不刷新，
    // 列表与详情章节数长期不一致。改为覆盖写回后此竞态即消解。
    if (found >= 0) {
      index.chapters[found] = entry;
    } else {
      index.chapters.push(entry);
    }
    // 廉价自愈：顺带复核本漫画中所有「未完成」条目的磁盘 .done 标记（通常极少），
    // 若磁盘其实已完成则改正为 true，并刷新 pageCount/bytes。
    // 对应上述实证：存量陈旧条目会在该漫画下一次任意同步（如下载/删除相邻章）时被自动纠回。
    for (let i = 0; i < index.chapters.length; i++) {
      const item = index.chapters[i];
      if (item.completed) {
        continue;
      }
      const targetDirectory = comicDirectory + '/' + item.folder;
      if (exists(targetDirectory + '/' + DONE_FILE)) {
        item.completed = true;
        item.pageCount = imagePaths(targetDirectory).length;
        item.bytes = directorySize(targetDirectory);
      }
    }
    this.refreshIndexMeta(comicDirectory, index);
    this.writeIndex(comicDirectory, index);
  }

  private removeIndexChapter(comicDirectory: string, folder: string): void {
    let index = this.readIndexRaw(comicDirectory);
    if (index === null) {
      index = this.rebuildIndex(comicDirectory);
    }
    const remaining: StoredIndexChapter[] = [];
    for (let i = 0; i < index.chapters.length; i++) {
      if (index.chapters[i].folder !== folder) {
        remaining.push(index.chapters[i]);
      }
    }
    index.chapters = remaining;
    this.refreshIndexMeta(comicDirectory, index);
    this.writeIndex(comicDirectory, index);
  }

  private chaptersFromIndex(comicDirectory: string, index: StoredComicIndex,
    onlyCompleted: boolean): DownloadedChapterInfo[] {
    const chapters: DownloadedChapterInfo[] = [];
    // 先按「详情页默认顺序（orderIndex）／自然序」排好条目，再映射展示结构
    const ordered = sortedChapterEntries(index.chapters);
    for (let i = 0; i < ordered.length; i++) {
      const entry = ordered[i];
      // onlyCompleted：未完成的残留在「我的下载」里不可见，也不会进离线序列
      if (onlyCompleted && !entry.completed) {
        continue;
      }
      chapters.push({
        name: entry.name,
        uuid: entry.uuid,
        comicId: entry.comicId,
        directory: comicDirectory + '/' + entry.folder,
        completed: entry.completed,
        pageCount: entry.pageCount,
        bytes: entry.bytes
      });
    }
    return chapters;
  }

  private orderedEntries(index: StoredComicIndex): StoredIndexChapter[] {
    return sortedChapterEntries(index.chapters);
  }

  private comicBytes(index: StoredComicIndex): number {
    let bytes = index.otherBytes;
    for (let i = 0; i < index.chapters.length; i++) {
      bytes += index.chapters[i].bytes;
    }
    return bytes;
  }

  /** 作品 id：优先排在第一的章节，缺失时往后翻（老数据兼容），都没有返回空串。 */
  private firstIndexComicId(entries: StoredIndexChapter[]): string {
    for (let i = 0; i < entries.length; i++) {
      const id = safeText(entries[i].comicId);
      if (id.length > 0) {
        return id;
      }
    }
    return '';
  }

  /** 本地封面图绝对路径（下载时落盘的字节）；没有则空串。 */
  comicCoverPath(comicDirectory: string): string {
    for (let i = 0; i < COVER_IMAGE_NAMES.length; i++) {
      const path = comicDirectory + '/' + COVER_IMAGE_NAMES[i];
      if (fileIsComplete(path)) {
        return path;
      }
    }
    return '';
  }

  /** 元数据里存的封面 URL（联网时可直接 Image(url) 吃系统缓存）；没有则空串。 */
  coverUrl(comicDirectory: string): string {
    const path = comicDirectory + '/' + COVER_URL_FILE;
    if (!fileIsComplete(path)) {
      return '';
    }
    try {
      return fileIo.readTextSync(path).trim();
    } catch (error) {
      return '';
    }
  }

  /**
   * 补齐封面：缺 URL 就查一次详情接口，缺图片就把字节落到作品目录。
   * 幂等 + 并发去重；离线/接口不可用一律静默返回，调用方可以放心不 await。
   */
  async ensureComicCover(comicDirectory: string, comicId: string): Promise<void> {
    const running = this.coverTasks.get(comicDirectory);
    if (running !== undefined) {
      await running;
      return;
    }
    const task = this.fetchComicCover(comicDirectory, comicId);
    this.coverTasks.set(comicDirectory, task);
    try {
      await task;
    } finally {
      this.coverTasks.delete(comicDirectory);
    }
  }

  private async fetchComicCover(comicDirectory: string, comicId: string): Promise<void> {
    try {
      if (comicId.length === 0 || !exists(comicDirectory)) {
        return;
      }
      let url = this.coverUrl(comicDirectory);
      if (url.length > 0 && this.comicCoverPath(comicDirectory).length > 0) {
        return;
      }
      if (url.length === 0) {
        const source = await getBrowseSource();
        const detail = await source.detail(comicId);
        if (detail === null || detail.cover.length === 0) {
          return;
        }
        url = detail.cover;
        writeFileAtomically(comicDirectory + '/' + COVER_URL_FILE, url);
        this.refreshComicIndex(comicDirectory);
      }
      if (this.comicCoverPath(comicDirectory).length === 0) {
        await this.cacheCoverImage(url, comicDirectory);
      }
    } catch (error) {
      // 离线或接口不可用：静默放弃，下次进下载页 / 再下载时重试
    }
  }

  /** 封面字节落盘（离线显示用）；只在作品目录里写一个 cover.*，不动章节协议。 */
  private async cacheCoverImage(url: string, comicDirectory: string): Promise<void> {
    const target = comicDirectory + '/' + 'cover' + imageExtension(url);
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': kDesktopUserAgent,
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
        },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        maxLimit: 10 * 1024 * 1024,
        connectTimeout: IMAGE_TIMEOUT_MS,
        readTimeout: IMAGE_TIMEOUT_MS
      });
      const status = Number(response.responseCode);
      if (status < 200 || status >= 300) {
        throw new Error('HTTP ' + status);
      }
      if (!(response.result instanceof ArrayBuffer) || response.result.byteLength === 0) {
        throw new Error('封面响应为空');
      }
      writeFileAtomically(target, response.result);
      this.refreshComicIndex(comicDirectory);
    } finally {
      try {
        request?.destroy();
      } catch (error) {
      }
    }
  }

  /** 只读查询：按 comicId + chapterUuid 找到已下载章节目录（不写任何文件）。 */
  findDownloadedChapter(comicId: string, chapterUuid: string): DownloadedChapterInfo | null {
    const root = this.downloadRoot();
    if (!exists(root)) {
      return null;
    }
    try {
      const comicNames = fileIo.listFileSync(root);
      for (let i = 0; i < comicNames.length; i++) {
        const comicDirectory = root + '/' + comicNames[i];
        if (!fileIo.statSync(comicDirectory).isDirectory()) {
          continue;
        }
        const chapterNames = fileIo.listFileSync(comicDirectory);
        for (let j = 0; j < chapterNames.length; j++) {
          const chapterDirectory = comicDirectory + '/' + chapterNames[j];
          if (!chapterNames[j].startsWith('章节_') || !fileIo.statSync(chapterDirectory).isDirectory()) {
            continue;
          }
          const meta = readMeta(chapterDirectory);
          if (meta === null) {
            continue;
          }
          if (meta.comicId !== comicId || meta.uuid !== chapterUuid) {
            continue;
          }
          const images = imagePaths(chapterDirectory);
          return {
            name: meta.name.length > 0 ? meta.name : chapterNames[j],
            uuid: meta.uuid,
            comicId: metaComicId(meta),
            directory: chapterDirectory,
            completed: exists(chapterDirectory + '/' + DONE_FILE),
            pageCount: images.length,
            bytes: directorySize(chapterDirectory)
          };
        }
      }
    } catch (error) {
      return null;
    }
    return null;
  }

  /**
   * 按漫画一次性取「已下载完成」章节的 uuid 集合（只读扫描，不写任何文件）。
   * 供批量下载页标记已下载、避免重复入队；不做逐章查询是为了几百章时只扫一遍目录。
   */
  completedChapterIds(comicId: string): Set<string> {
    const result = new Set<string>();
    if (comicId.length === 0) {
      return result;
    }
    const root = this.downloadRoot();
    if (!exists(root)) {
      return result;
    }
    try {
      const comicNames = fileIo.listFileSync(root);
      for (let i = 0; i < comicNames.length; i++) {
        const comicDirectory = root + '/' + comicNames[i];
        if (!fileIo.statSync(comicDirectory).isDirectory()) {
          continue;
        }
        const chapterNames = fileIo.listFileSync(comicDirectory);
        for (let j = 0; j < chapterNames.length; j++) {
          const chapterDirectory = comicDirectory + '/' + chapterNames[j];
          if (!chapterNames[j].startsWith('章节_') || !fileIo.statSync(chapterDirectory).isDirectory()) {
            continue;
          }
          const meta = readMeta(chapterDirectory);
          if (meta === null || meta.comicId !== comicId) {
            continue;
          }
          if (exists(chapterDirectory + '/' + DONE_FILE)) {
            result.add(meta.uuid);
          }
        }
      }
    } catch (error) {
      return result;
    }
    return result;
  }

  loadOfflineChapter(directory: string): OfflineChapterData | null {
    const meta = readMeta(directory);
    if (meta === null) {
      return null;
    }
    return {
      name: meta.name,
      uuid: meta.uuid,
      comicId: metaComicId(meta),
      directory: directory,
      imagePaths: imagePaths(directory),
      completed: exists(directory + '/' + DONE_FILE)
    };
  }

  /**
   * 下载根目录总占用：优先走各作品索引求和，索引缺失/不一致时退回旧递归统计（不写盘）。
   * 结果口径与旧 directorySize(root) 基本一致（索引文件自身不计入）。
   */
  totalBytes(): number {
    const root = this.downloadRoot();
    if (!exists(root)) {
      return 0;
    }
    let total = 0;
    try {
      const names = fileIo.listFileSync(root);
      for (let i = 0; i < names.length; i++) {
        const path = root + '/' + names[i];
        let isDirectory = false;
        let size = 0;
        try {
          const stat = fileIo.statSync(path);
          isDirectory = stat.isDirectory();
          size = stat.size;
        } catch (error) {
          continue;
        }
        if (!isDirectory) {
          total += size;
          continue;
        }
        const index = this.peekValidIndex(path);
        total += index !== null ? this.comicBytes(index) : directorySize(path);
      }
    } catch (error) {
      return 0;
    }
    return total;
  }

  deleteChapter(comicDirectory: string, chapterDirectory: string): void {
    const meta = readMeta(chapterDirectory);
    if (meta !== null) {
      this.cancel(meta.comicId, meta.uuid);
    }
    const folder = baseName(chapterDirectory);
    removeTree(chapterDirectory);
    // 先按目录名从索引摘除（不触发重扫），再据此判断作品是否已空
    this.removeIndexChapter(comicDirectory, folder);
    const remaining = this.listDownloadedChapters(comicDirectory);
    if (remaining.length === 0) {
      // 「我的下载」只认完成章：没有完成章这部作品就彻底消失，
      // 没收口的残留目录一并清掉，避免留下看不见又清不掉的死目录。
      // 但若本作品还有排队 / 在跑的章（别的章正在写盘），目录留给任务自己收口。
      if (this.hasActiveTaskIn(comicDirectory)) {
        return;
      }
      removeTree(comicDirectory);
      return;
    }
    this.rewriteManifestFromDownloads(comicDirectory, remaining);
  }

  deleteComic(comicDirectory: string): void {
    // 取消范围按「索引里的全部章节」：排队 / 在跑的章也得停，不能只停已完成的
    const index = this.readIndexRaw(comicDirectory);
    if (index !== null) {
      for (let i = 0; i < index.chapters.length; i++) {
        this.cancel(index.chapters[i].comicId, index.chapters[i].uuid);
      }
    }
    const chapters = this.listDownloadedChapters(comicDirectory);
    for (let i = 0; i < chapters.length; i++) {
      this.cancel(chapters[i].comicId, chapters[i].uuid);
    }
    removeTree(comicDirectory);
  }

  /** 这部作品是否还有「排队 / 下载中」的任务（按索引里的 comicId + uuid 查内存任务表）。 */
  private hasActiveTaskIn(comicDirectory: string): boolean {
    const index = this.readIndexRaw(comicDirectory);
    if (index === null) {
      return false;
    }
    for (let i = 0; i < index.chapters.length; i++) {
      const entry = index.chapters[i];
      const task = this.tasks.get(taskKey(entry.comicId, entry.uuid));
      if (task === undefined) {
        continue;
      }
      if (task.status === ChapterDownloadStatus.Queued ||
        task.status === ChapterDownloadStatus.Downloading) {
        return true;
      }
    }
    return false;
  }

  private rewriteManifestFromDownloads(comicDirectory: string, chapters: DownloadedChapterInfo[]): void {
    const entries: StoredChapterEntry[] = [];
    for (let i = 0; i < chapters.length; i++) {
      entries.push({
        name: chapters[i].name,
        url: UrlManager.activeUrl + '/comic/' + chapters[i].comicId + '/chapter/' + chapters[i].uuid
      });
    }
    const groups: StoredChapterGroup[] = [{ name: 'default', chapters: entries }];
    writeFileAtomically(comicDirectory + '/' + CHAPTERS_FILE, JSON.stringify(groups));
  }
}

export const downloadStore: DownloadStore = new DownloadStore();
