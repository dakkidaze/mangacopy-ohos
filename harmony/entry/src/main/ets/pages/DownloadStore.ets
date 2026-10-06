/**
 * 章节下载与离线目录索引。
 * 文件协议严格保持：downloads/{comicName}/章节_{uuid前8}/、meta.json、.done、chapters.json。
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

const DOWNLOAD_FOLDER: string = 'downloads';
const CHAPTERS_FILE: string = 'chapters.json';
const META_FILE: string = 'meta.json';
const DONE_FILE: string = '.done';
const DOWNLOAD_CONCURRENCY: number = 4;
const IMAGE_RETRIES: number = 3;
const IMAGE_TIMEOUT_MS: number = 30000;

export interface ChapterDownloadRequest {
  comicName: string;
  comicId: string;
  chapterName: string;
  chapterId: string;
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
}

interface DownloadQueue {
  nextIndex: number;
}

export enum ChapterDownloadStatus {
  Idle = 0,
  Downloading = 1,
  Completed = 2,
  Failed = 3,
  Cancelled = 4
}

@ObservedV2
export class ChapterDownloadState {
  @Trace status: ChapterDownloadStatus = ChapterDownloadStatus.Idle;
  @Trace completed: number = 0;
  @Trace total: number = 0;
  @Trace errorText: string = '';
  cancelRequested: boolean = false;
  activeRequests: Map<number, http.HttpRequest> = new Map<number, http.HttpRequest>();

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
  directory: string;
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

export class DownloadStore {
  private tasks: Map<string, ChapterDownloadState> = new Map<string, ChapterDownloadState>();

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
    if (task.status !== ChapterDownloadStatus.Downloading) {
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
    if (task === undefined || task.status !== ChapterDownloadStatus.Downloading) {
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
  }

  async downloadChapter(request: ChapterDownloadRequest,
    onProgress?: ChapterDownloadProgressCallback): Promise<ChapterDownloadState> {
    const task = this.taskFor(request);
    if (task.status === ChapterDownloadStatus.Downloading || task.status === ChapterDownloadStatus.Completed) {
      return task;
    }
    task.status = ChapterDownloadStatus.Downloading;
    task.cancelRequested = false;
    task.completed = 0;
    task.total = 0;
    task.errorText = '';

    const comicDirectory = this.comicDirectory(request.comicName);
    const chapterDirectory = this.chapterDirectory(request.comicName, request.chapterId);
    const donePath = chapterDirectory + '/' + DONE_FILE;
    try {
      ensureDirectory(this.downloadRoot());
      ensureDirectory(comicDirectory);
      ensureDirectory(chapterDirectory);
      removeFileQuietly(donePath);
      this.writeChapterMeta(chapterDirectory, request);
      await this.updateChaptersManifest(comicDirectory, request);

      // 图源由设置决定：chapterSource='webview' 走隐藏收图，否则走 API。
      const urls = await loadChapterImages(request.comicId, request.chapterId);
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
      }
      if (urls.length === 0) {
        throw new Error('章节没有可下载的图片');
      }
      task.total = urls.length;
      const queue: DownloadQueue = { nextIndex: 0 };
      const workers: Promise<void>[] = [];
      for (let i = 0; i < DOWNLOAD_CONCURRENCY; i++) {
        workers.push(this.runWorker(task, queue, urls, chapterDirectory, onProgress));
      }
      await Promise.all(workers);
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
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
      } else {
        task.status = ChapterDownloadStatus.Failed;
        const value = error as Error;
        task.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '下载失败';
      }
      return task;
    }
  }

  private async runWorker(task: ChapterDownloadState, queue: DownloadQueue, urls: string[], directory: string,
    onProgress?: ChapterDownloadProgressCallback): Promise<void> {
    while (true) {
      if (task.cancelRequested) {
        throw new DownloadCancelledError();
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
      task.completed++;
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

  listDownloadedComics(): DownloadedComicInfo[] {
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
        const chapters = this.listDownloadedChapters(directory);
        if (chapters.length === 0) {
          continue;
        }
        let completedCount = 0;
        let pages = 0;
        for (let j = 0; j < chapters.length; j++) {
          if (chapters[j].completed) {
            completedCount++;
          }
          pages += chapters[j].pageCount;
        }
        const firstMeta = readMeta(chapters[0].directory);
        const displayName = firstMeta !== null && firstMeta.comicName !== undefined &&
          firstMeta.comicName.length > 0 ? firstMeta.comicName : names[i];
        comics.push({
          name: displayName,
          directory: directory,
          chapterCount: chapters.length,
          completedCount: completedCount,
          pageCount: pages,
          bytes: directorySize(directory)
        });
      }
    } catch (error) {
      return [];
    }
    comics.sort((left: DownloadedComicInfo, right: DownloadedComicInfo) => left.name.localeCompare(right.name));
    return comics;
  }

  listDownloadedChapters(comicDirectory: string): DownloadedChapterInfo[] {
    const chapters: DownloadedChapterInfo[] = [];
    if (!exists(comicDirectory)) {
      return chapters;
    }
    try {
      const names = fileIo.listFileSync(comicDirectory);
      for (let i = 0; i < names.length; i++) {
        const directory = comicDirectory + '/' + names[i];
        if (!names[i].startsWith('章节_') || !fileIo.statSync(directory).isDirectory()) {
          continue;
        }
        const meta = readMeta(directory);
        if (meta === null) {
          continue;
        }
        const images = imagePaths(directory);
        chapters.push({
          name: meta.name.length > 0 ? meta.name : names[i],
          uuid: meta.uuid,
          comicId: meta.comicId,
          directory: directory,
          completed: exists(directory + '/' + DONE_FILE),
          pageCount: images.length,
          bytes: directorySize(directory)
        });
      }
    } catch (error) {
      return [];
    }
    chapters.sort((left: DownloadedChapterInfo, right: DownloadedChapterInfo) =>
      left.name.localeCompare(right.name));
    return chapters;
  }

  loadOfflineChapter(directory: string): OfflineChapterData | null {
    const meta = readMeta(directory);
    if (meta === null) {
      return null;
    }
    return {
      name: meta.name,
      uuid: meta.uuid,
      comicId: meta.comicId,
      directory: directory,
      imagePaths: imagePaths(directory),
      completed: exists(directory + '/' + DONE_FILE)
    };
  }

  totalBytes(): number {
    return directorySize(this.downloadRoot());
  }

  deleteChapter(comicDirectory: string, chapterDirectory: string): void {
    const meta = readMeta(chapterDirectory);
    if (meta !== null) {
      this.cancel(meta.comicId, meta.uuid);
    }
    removeTree(chapterDirectory);
    const remaining = this.listDownloadedChapters(comicDirectory);
    if (remaining.length === 0) {
      removeTree(comicDirectory);
      return;
    }
    this.rewriteManifestFromDownloads(comicDirectory, remaining);
  }

  deleteComic(comicDirectory: string): void {
    const chapters = this.listDownloadedChapters(comicDirectory);
    for (let i = 0; i < chapters.length; i++) {
      this.cancel(chapters[i].comicId, chapters[i].uuid);
    }
    removeTree(comicDirectory);
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
