/**
 * 「网页收图」图源：用隐藏的 Web（PC UA）打开 PC 版章节页，
 * 注入 `gm_shim.js` + `h.js` 自动滚动收集图片，返回 [ChapterData]。
 *
 * 对应 `AppSettings.chapterSource == 'webview'`；与 Flutter 版 WebViewChapterLoader 同语义。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { kDesktopUserAgent } from '../services/ApiHeaders';
import { settingsStore } from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';
import { wrapResolution } from '../shared/Images';
import { getBrowseSource } from './BrowseSupport';

const GM_METHODS: string[] = [
  'loadComic',
  'hideFab',
  'enterProfile',
  'openSettings',
  'loadChapter',
  'setTitle',
  'setFab',
  'setLoadingDialog',
  'setLoadingDialogProgress',
  'toggleStatusBar'
];

const COLLECT_TIMEOUT_MS: number = 45000;
const INJECT_DELAY_MS: number = 400;

export interface ChapterData {
  title: string;
  uuid: string;
  nextChapterUrl: string;
  previousChapterUrl: string;
  imgUrls: string[];
}

/** h.js 收图结果的解析，对应 native 版 ChapterData 的协议。 */
function parseChapterData(raw: string): ChapterData | null {
  const lines = raw.split('\n');
  if (lines.length < 3) {
    return null;
  }
  const head = lines[0];
  const sp = head.lastIndexOf(' ');
  const title = sp > 0 ? head.substring(0, sp) : head;
  const uuid = sp > 0 ? head.substring(sp + 1) : '';
  let nextChapterUrl = lines[1] === 'null' ? '' : lines[1];
  let previousChapterUrl = lines[2] === 'null' ? '' : lines[2];
  const imgUrls: string[] = [];
  for (let i = 3; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim().length > 0) {
      imgUrls.push(line);
    }
  }
  return {
    title: title,
    uuid: uuid,
    nextChapterUrl: nextChapterUrl,
    previousChapterUrl: previousChapterUrl,
    imgUrls: imgUrls
  };
}

interface CollectSession {
  key: string;
  resolve: (data: ChapterData) => void;
  reject: (error: Error) => void;
  timer: number;
}

export class HiddenCollector {
  private controller: webview.WebviewController | null = null;
  private controllerReady: boolean = false;
  private gmScript: string = '';
  private hiddenScript: string = '';
  private assetsLoaded: boolean = false;
  private session: CollectSession | null = null;

  /** 由页面组件在 build 时绑定隐藏 Web 的控制器。 */
  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  /** onControllerAttached 回调：注册 GM 桥 + 桌面 UA。 */
  onControllerAttached(): void {
    const controller = this.controller;
    if (controller === null) {
      return;
    }
    this.loadAssets();
    try {
      controller.registerJavaScriptProxy(this, 'GM', GM_METHODS);
      controller.setCustomUserAgent(kDesktopUserAgent);
      this.controllerReady = true;
    } catch (error) {
      this.controllerReady = false;
    }
  }

  private loadAssets(): void {
    if (this.assetsLoaded) {
      return;
    }
    const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (context === undefined) {
      return;
    }
    try {
      const decoder = util.TextDecoder.create('utf-8');
      this.gmScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/gm_shim.js'));
      this.hiddenScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/h.js'));
      this.assetsLoaded = true;
    } catch (error) {
      this.assetsLoaded = false;
    }
  }

  /** PC 版章节页 URL：`{webHost}/comic/{pathWord}/chapter/{uuid}`。 */
  private pcUrl(comicId: string, chapterUuid: string): string {
    return UrlManager.activeUrl + '/comic/' + comicId + '/chapter/' + chapterUuid;
  }

  private async injectScripts(): Promise<void> {
    const controller = this.controller;
    if (controller === null || !this.assetsLoaded) {
      return;
    }
    await new Promise<void>((resolve: (value: void) => void) => {
      setTimeout(() => resolve(), INJECT_DELAY_MS);
    });

    const sourceProfile = await settingsStore.sourceProfile();
    await controller.runJavaScript(
      "window.__CM_SOURCE_PROFILE='" + sourceProfile + "';" +
      "window.__CM_ACTIVE_URL='" + UrlManager.activeUrl + "';"
    );
    await controller.runJavaScript(this.gmScript);
    await controller.runJavaScript(this.hiddenScript);
  }

  /** onPageEnd 回调：注入全局变量 + gm_shim.js + h.js（顺序不能反）。 */
  onPageEnd(): void {
    if (this.session === null) {
      return;
    }
    this.injectScripts().catch(() => {
      // 注入失败时保留等待，由 45s 超时统一收口。
    });
  }

  /** GM 桥：h.js 收图结果入口。 */
  loadChapter(result: string): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    const data = parseChapterData(result);
    if (data === null || data.imgUrls.length === 0) {
      return;
    }
    clearTimeout(session.timer);
    this.session = null;
    session.resolve(data);
  }

  async load(comicId: string, chapterUuid: string): Promise<ChapterData> {
    if (!this.controllerReady || this.controller === null) {
      throw new Error('隐藏收图 Web 初始化失败');
    }
    if (!this.assetsLoaded) {
      this.loadAssets();
    }
    await UrlManager.bootstrap();

    const key = comicId + '/' + chapterUuid;
    if (this.session !== null && this.session.key === key) {
      // 同一章重复请求：复用当前等待
      return new Promise<ChapterData>((resolve: (data: ChapterData) => void,
        reject: (error: Error) => void) => {
        const previous = this.session as CollectSession;
        const resolveChain = previous.resolve;
        previous.resolve = (data: ChapterData): void => {
          resolveChain(data);
          resolve(data);
        };
        const rejectChain = previous.reject;
        previous.reject = (error: Error): void => {
          rejectChain(error);
          reject(error);
        };
      });
    }

    this.cancel();
    const controller = this.controller as webview.WebviewController;
    return new Promise<ChapterData>((resolve: (data: ChapterData) => void,
      reject: (error: Error) => void) => {
      const timer = setTimeout(() => {
        if (this.session !== null && this.session.key === key) {
          const session = this.session;
          this.session = null;
          session.reject(new Error('网页收图超时'));
        }
      }, COLLECT_TIMEOUT_MS);

      this.session = {
        key: key,
        resolve: resolve,
        reject: reject,
        timer: timer
      };

      try {
        controller.loadUrl(this.pcUrl(comicId, chapterUuid));
      } catch (error) {
        clearTimeout(timer);
        this.session = null;
        const value = error as Error;
        reject(new Error(value.message !== undefined && value.message.length > 0 ?
          value.message : '网页收图加载失败'));
      }
    });
  }

  cancel(): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    clearTimeout(session.timer);
    this.session = null;
    session.reject(new Error('网页收图已取消'));
  }

  // ---- GM 桥其余方法：与 gm_shim.js 清单一致，本阶段安全空实现 ----

  loadComic(_url: string): void {
  }

  hideFab(): void {
  }

  enterProfile(): void {
  }

  openSettings(): void {
  }

  setTitle(_title: string): void {
  }

  setFab(_json: string): void {
  }

  setLoadingDialog(_visible: boolean): void {
  }

  setLoadingDialogProgress(_index: number, _count: number): void {
  }

  toggleStatusBar(): void {
  }
}

export const hiddenCollector: HiddenCollector = new HiddenCollector();

/** 章节图源统一入口：按设置选择 API 或网页收图，统一 wrapResolution。 */
export async function loadChapterImages(comicId: string, chapterUuid: string): Promise<string[]> {
  const chapterSource = await settingsStore.chapterSource();
  if (chapterSource === 'webview') {
    const data = await hiddenCollector.load(comicId, chapterUuid);
    const out: string[] = [];
    for (let i = 0; i < data.imgUrls.length; i++) {
      out.push(wrapResolution(data.imgUrls[i]));
    }
    return out;
  }
  const source = await getBrowseSource();
  const urls = await source.pages(comicId, chapterUuid);
  const out: string[] = [];
  for (let i = 0; i < urls.length; i++) {
    out.push(wrapResolution(urls[i]));
  }
  return out;
}