import { COLLECTOR_LOG_ENABLED } from '../services/Log';
/**
 * 「网页收图」图源：用隐藏的 Web（PC UA）打开 PC 版章节页，
 * 注入 `gm_shim.js` + `h.js` 自动滚动收集图片，返回 [ChapterData]。
 *
 * 对应 `AppSettings.chapterSource == 'webview'`；与 Flutter 版 WebViewChapterLoader 同语义。
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { kDesktopUserAgent } from '../services/ApiHeaders';
import { CopyApiSource } from '../services/CopyApiSource';
import { settingsStore } from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';
import { wrapResolution } from '../shared/Images';
import { getBrowseSource } from './BrowseSupport';
import { downloadStore } from './DownloadStore';

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

/**
 * 收图停滞判定：连续 45s 没有任何新增进度（扫到的新页数没涨）即按停滞收口。
 * 原先是「整章 45s 硬超时」，慢站点会被误杀；现在只要还在出图就继续收。
 */
const COLLECT_IDLE_TIMEOUT_MS: number = 45000;
/** 总时长兜底：即便一直零星出图，整章也不超过 3 分钟（防止无上限挂着）。 */
const COLLECT_TOTAL_TIMEOUT_MS: number = 180000;
/** 停滞/总时长检查周期（5s 一次，命中落在 45s ~ 50s 之间）。 */
const COLLECT_WATCH_INTERVAL_MS: number = 5000;
/**
 * 页面身份未确认时的重新导航时机：页面自身章节 uuid 一直与请求章不一致
 * （导航失败 / 被站点重定向到别处）时，到点重新导航一次做有界重试；
 * 仍不一致则由停滞兜底按失败收口，绝不写盘。
 */
const COLLECT_IDENTITY_RETRY_MS: number = 20000;
const INJECT_DELAY_MS: number = 400;
// 增量轮询节奏（fast 默认档）：首帧稍晚（等 h.js 注入），之后 700ms 一次，平衡开销与及时性。
// 其他档位的节奏见 pollRhythmFor()；fast 与未识别值一律沿用这两个常量，保证默认体验不变。
const POLL_INITIAL_DELAY_MS: number = 1200;
const POLL_INTERVAL_MS: number = 700;

/** 设置页「源档位」合法取值（与 SettingsPage.validSourceProfile 一致，未识别回退 fast）。 */
const SOURCE_PROFILES: string[] = ['conservative', 'normal', 'fast', 'turbo'];

function normalizeSourceProfile(value: string): string {
  return SOURCE_PROFILES.indexOf(value) >= 0 ? value : 'fast';
}

/** 读取「源档位」并归一化（SettingsStore 只给原始字符串，这里兜底 fast）。 */
async function resolveSourceProfile(): Promise<string> {
  return normalizeSourceProfile(await settingsStore.sourceProfile());
}

/** 增量轮询节奏。 */
interface PollRhythm {
  initialDelayMs: number;
  intervalMs: number;
}

/**
 * 档位 → 轮询节奏。h.js 的滚动速度由注入的 window.__CM_SOURCE_PROFILE 控制（见 injectScripts），
 * 这里让原生轮询节奏与之匹配：
 * - conservative：滚动慢、出图慢，放宽轮询省开销；
 * - normal：h.js 固定 320px/帧，节奏略缓；
 * - turbo：滚动快、出图快，收紧轮询让增量上报更及时；
 * - fast（默认）与未识别值：与既有节奏完全一致。
 */
function pollRhythmFor(profile: string): PollRhythm {
  switch (profile) {
    case 'conservative':
      return { initialDelayMs: 1600, intervalMs: 1100 };
    case 'normal':
      return { initialDelayMs: 1200, intervalMs: 800 };
    case 'turbo':
      return { initialDelayMs: 900, intervalMs: 450 };
    default:
      return { initialDelayMs: POLL_INITIAL_DELAY_MS, intervalMs: POLL_INTERVAL_MS };
  }
}

/** 「进入阅读器前预载页数」的持久化 key（规格表后续补录）。 */
export const KEY_READER_PREFETCH_COUNT: string = 'readerPrefetchCount';

/** 本地文件路径 → 应用沙箱 URI；依据 docs Image.src 说明。 */
export function localImageUri(path: string): string {
  if (path.startsWith('file://')) {
    return path;
  }
  return 'file://' + path;
}

/** 收图取证日志统一前缀（%{public}s 才能在真机看到内容）。 */
function truncate(value: string, maxLength: number = 160): string {
  return value.length > maxLength ? value.substring(0, maxLength) + '…' : value;
}

function logBatchHead(prefix: string, urls: string[]): void {
  if (urls.length === 0) {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', prefix + ' [' + urls.length + '] 无新增');
    }
    return;
  }
  const head: string[] = [];
  const count = Math.min(3, urls.length);
  for (let i = 0; i < count; i++) {
    head.push(truncate(urls[i]));
  }
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(0x0000, 'Collector', '%{public}s', prefix + ' 前' + count + '=' + head.join(' | '));
  }
}

export function logCollectorBatch(urls: string[]): void {
  logBatchHead('新增', urls);
}

/**
 * 取证：打印 runJavaScript 回来的**原始**文本片段（截断 160 字符），
 * 与清洗后的结果对照，用于判定杂字符来源（站点 DOM vs 我们链路）。
 */
function logRawScan(raw: string, cleaned: string[]): void {
  const head: string[] = [];
  const count = Math.min(3, cleaned.length);
  for (let i = 0; i < count; i++) {
    head.push(truncate(cleaned[i]));
  }
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(
    0x0000,
    'Collector',
    '%{public}s',
    '首帧原始片段=' + truncate(raw) + ' || 清洗后前' + count + '=' + head.join(' | ')
  );
  }
}

/**
 * 清洗单条 URL：去掉包裹/尾随的杂字符（双引号、单引号、反引号、空白、全角引号等）。
 *
 * 实测站点 DOM 的 data-src 里会出现尾部粘了一个 `"` 的地址（…webp"），
 * 直接拿去请求必然 404；叠加手动重载的 `_r=N` 后会变成 …webp"?_r=9 依旧 404，
 * 于是"反复失败且怎么点都好不了"。这里在收集/解析环节就把它剥干净。
 * 只剥首尾杂字符，不动中间——URL 中间出现引号的情况极其罕见且改坏代价大。
 */
function cleanUrl(value: string): string {
  let s = value;
  // 先去首尾空白（含全角空格）
  s = s.replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
  // 再去成对包裹的引号
  while (s.length > 1) {
    const first = s.charAt(0);
    const last = s.charAt(s.length - 1);
    const isQuote = (c: string): boolean =>
      c === '"' || c === '\'' || c === '`' || c === '\u201C' || c === '\u201D' ||
      c === '\u2018' || c === '\u2019';
    if (isQuote(first) && isQuote(last)) {
      s = s.substring(1, s.length - 1);
      continue;
    }
    break;
  }
  // 最后去单侧残留的引号（站点 HTML 引号不配对时的情形）
  s = s.replace(/^["'`\u201C\u201D\u2018\u2019]+/, '');
  s = s.replace(/["'`\u201C\u201D\u2018\u2019]+$/, '');
  return s.trim();
}

/**
 * runJavaScript 回来的文本里，换行可能是「字面 \n」（两个字符）而不是真换行，
 * 直接 split('\n') 会把整串粘成一条 → 首图变成无法加载的巨型 URL（实测 code=101000）。
 * 这里先把字面 \n 还原成真换行，再逐条清洗 + 按 URL 形状过滤。
 */
function parseScannedUrls(raw: string): string[] {
  const normalized = raw.split('\\n').join('\n');
  const lines = normalized.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = cleanUrl(lines[i]);
    if (isLikelyImageUrl(line)) {
      out.push(line);
    }
  }
  return out;
}

/** 形状校验：只接受 http(s) 且不含空白/反斜杠的条目，避免把粘在一起的大块当成一页。 */
function isLikelyImageUrl(value: string): boolean {
  if (value.length < 10 || value.indexOf(' ') >= 0 || value.indexOf('\t') >= 0) {
    return false;
  }
  if (value.indexOf('\\') >= 0 || value.indexOf('\n') >= 0) {
    return false;
  }
  return value.indexOf('http://') === 0 || value.indexOf('https://') === 0;
}

/** 页面章标识（形如 `pathWord/uuid`）→ 取最后一段 uuid；无斜杠时原样返回。 */
function pageUuidOf(pageId: string): string {
  const slash = pageId.lastIndexOf('/');
  return slash >= 0 ? pageId.substring(slash + 1) : pageId;
}

/**
 * 身份归一化：小写、去 query / hash、去尾斜杠。
 * 用于「请求章 uuid」与「页面章 uuid」的宽容比对，避免大小写 / 尾斜杠造成误判，
 * 同时保证「页 A 的图写进章 B」这类真实错位一定被判为不符。
 */
function normalizeIdentity(value: string): string {
  let s = value.trim().toLowerCase();
  const q = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  const h = s.indexOf('#');
  if (h >= 0) {
    s = s.substring(0, h);
  }
  while (s.length > 0 && s.charAt(s.length - 1) === '/') {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/**
 * 「同章重读也重报」：不再做永久去重，只做「同一章同时只发一个进行中请求」的短路。
 * 这样每次进入阅读器都会向服务端补报一次观看历史（离线/失败静默，不阻塞阅读）。
 */
const historyInFlight: Set<string> = new Set<string>();

/** 补报云端观看历史：异步、不阻塞首屏，失败静默；同章重读也会再次上报。 */
export function reportChapterViewOnce(comicId: string, chapterUuid: string): void {
  const key = comicId + '/' + chapterUuid;
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(0x0000, 'Collector', '%{public}s', '云端观看历史：进入 ' + key);
  }
  if (historyInFlight.has(key)) {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '云端观看历史：跳过（已有进行中请求）' + key);
    }
    return;
  }
  historyInFlight.add(key);
  getBrowseSource().then((source: CopyApiSource) => {
    return source.pages(comicId, chapterUuid);
  }).then(() => {
    historyInFlight.delete(key);
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '云端观看历史：成功 ' + key);
    }
  }).catch((error: Error) => {
    historyInFlight.delete(key);
    const message = error.message !== undefined ? error.message : String(error);
    if (COLLECTOR_LOG_ENABLED) {
      hilog.warn(0x0000, 'Collector', '%{public}s', '云端观看历史：失败 ' + key + ' ' + message);
    }
  });
}

/**
 * 与 h.js 相同的选择器逻辑：按 DOM 顺序读取 PC 章节页里已收集到的图片 URL。
 *
 * 首行额外回报页面自身的章节标识 `ID:pathWord/uuid`（取自 location.href），
 * 供调用方在写盘前做身份校验 —— 只有页面确实是请求的那一章才接受扫描结果。
 * 次行 `HEAD:0/1` 是首个 li 的 data-src 是否就绪，其余行才是图片 URL。
 */
const DOM_SCAN_SCRIPT: string =
  "(function(){" +
  "var href=location.href||'';" +
  "var path=href;" +
  "var q=path.indexOf('?');if(q>=0)path=path.substring(0,q);" +
  "var hs=path.indexOf('#');if(hs>=0)path=path.substring(0,hs);" +
  "var m=path.match(/\\/comic\\/([^\\/]+)\\/chapter\\/([^\\/]+)/);" +
  "var id=m?(m[1]+'/'+m[2]):'';" +
  "var el=document.getElementsByClassName('container-fluid comicContent')[0];" +
  "var head='0';" +
  "var out=[];" +
  "if(el){" +
  "var items=el.getElementsByTagName('li');" +
  "if(items.length>0){var f=items[0].getElementsByTagName('img')[0];if(f&&f.dataset&&f.dataset.src)head='1';}" +
  "for(var i=0;i<items.length;i++){" +
  "var img=items[i].getElementsByTagName('img')[0];" +
  "if(img&&img.dataset&&img.dataset.src) out.push(img.dataset.src);" +
  "}" +
  "}" +
  "return 'ID:'+id+'\\n'+'HEAD:'+head+'\\n'+out.join('\\n');" +
  "})()";

export interface ChapterData {
  title: string;
  uuid: string;
  nextChapterUrl: string;
  previousChapterUrl: string;
  imgUrls: string[];
}

/** h.js 收图结果的解析，对应 native 版 ChapterData 的协议。 */
function parseChapterData(raw: string): ChapterData | null {
  // 同 parseScannedUrls：桥回来的文本可能是字面 \n，先还原成真换行再切
  const lines = raw.split('\\n').join('\n').split('\n');
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
    const line = cleanUrl(lines[i]);
    if (isLikelyImageUrl(line)) {
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

/** 增量收图会话：先报告已有页，再逐批追加，最终以 loadChapter 结果收尾。 */
export interface ChapterStreamHandlers {
  onBatch: (urls: string[]) => void;
  onDone: (total: number) => void;
  onError: (message: string) => void;
}

interface CollectSession extends ChapterStreamHandlers {
  key: string;
  /** 停滞看门狗（5s 周期：45s 无新增进度 + 180s 总上限兜底）。 */
  watchdog: number;
  poller: number;
  reported: number;
  finished: boolean;
  /** 会话开跑时间戳：总上限兜底用。 */
  startedAt: number;
  /** 最近一次「新增进度」时间戳（扫到的新页数上涨时刷新）。 */
  lastProgressAt: number;
  /** 首图 data-src 未就绪时的等待次数（避免把「从第 2 页开始」的列表当成完整列表）。 */
  headWaits: number;
  /** 请求章 uuid（归一化后）：页面 uuid 必须与之一致，否则扫描/收尾结果一律丢弃、绝不写盘。 */
  expectedUuid: string;
  /** 是否已确认页面身份（至少一次扫描或 h.js 收尾回报与请求章一致）。 */
  identityVerified: boolean;
  /** 最近一次观察到的页面章标识（取证日志去重用）。 */
  lastIdentity: string;
  /** 身份未确认时是否已重新导航过一次（有界重试，避免无限重载）。 */
  identityRetried: boolean;
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

    const sourceProfile = normalizeSourceProfile(await settingsStore.sourceProfile());
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
      // 注入失败时保留等待，由停滞看门狗（45s 无新增进度 / 180s 总上限）统一收口。
    });
  }

  /** GM 桥：h.js 收图结果入口，作为最终收尾校验。 */
  loadChapter(result: string): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    const data = parseChapterData(result);
    if (data === null || data.imgUrls.length === 0) {
      return;
    }
    // 身份校验：h.js 回报的 uuid 必须与请求章一致，否则整批丢弃（绝不写盘）。
    // 覆盖导航失败 / 被重定向到别章 / 上一章 DOM 残留等情形。
    if (normalizeIdentity(data.uuid) !== session.expectedUuid) {
      this.noteIdentityMismatch(session, data.uuid);
      return;
    }
    if (!session.identityVerified) {
      session.identityVerified = true;
      session.lastIdentity = data.uuid;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '身份校验通过(h.js) 请求章=' + session.expectedUuid + ' 页面章=' + data.uuid);
      }
    }
    // 补齐尾部：以一次性结果为准，补发尚未上报的新增项
    if (data.imgUrls.length > session.reported) {
      const tail: string[] = [];
      for (let i = session.reported; i < data.imgUrls.length; i++) {
        tail.push(wrapResolution(data.imgUrls[i]));
      }
      session.reported = data.imgUrls.length;
      session.onBatch(tail);
    }
    this.finishSession(data.imgUrls.length);
  }

  private finishSession(total: number): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    clearInterval(session.watchdog);
    clearInterval(session.poller);
    this.session = null;
    session.finished = true;
    session.onDone(total);
  }

  private failSession(message: string): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    clearInterval(session.watchdog);
    clearInterval(session.poller);
    this.session = null;
    session.onError(message);
  }

  /**
   * 取证 + 去重：页面章与请求章不一致时记录一次（同一页面标识不重复刷屏），
   * 调用方据此丢弃本次扫描 / 收尾结果，不写盘。
   */
  private noteIdentityMismatch(session: CollectSession, pageUuid: string): void {
    const actual = pageUuid.length > 0 ? pageUuid : '(无法识别)';
    if (session.lastIdentity === actual) {
      return;
    }
    session.lastIdentity = actual;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '身份校验不符 请求章=' + session.expectedUuid + ' 页面章=' + actual + '，丢弃本次结果');
    }
  }

  /** 增量收图：边收边上报；同一时刻只允许一个任务。 */
  async loadStream(comicId: string, chapterUuid: string, handlers: ChapterStreamHandlers,
    alreadyHave: number = 0): Promise<void> {
    if (!this.controllerReady || this.controller === null) {
      throw new Error('隐藏收图 Web 初始化失败');
    }
    if (!this.assetsLoaded) {
      this.loadAssets();
    }
    await UrlManager.bootstrap();

    const key = comicId + '/' + chapterUuid;
    let firstScanLogged = false;
    if (this.session !== null) {
      if (this.session.key === key) {
        // 同一章重复请求：复用当前收图任务
        return;
      }
      this.cancel();
    }

    const controller = this.controller as webview.WebviewController;
    // 轮询节奏随「源档位」走：h.js 滚动速度由注入的档位变量控制，这里与之匹配
    const rhythm = pollRhythmFor(await resolveSourceProfile());
    const session: CollectSession = {
      key: key,
      watchdog: 0,
      poller: 0,
      reported: alreadyHave > 0 ? alreadyHave : 0,
      finished: false,
      startedAt: Date.now(),
      lastProgressAt: Date.now(),
      headWaits: 0,
      expectedUuid: normalizeIdentity(chapterUuid),
      identityVerified: false,
      lastIdentity: '',
      identityRetried: false,
      onBatch: handlers.onBatch,
      onDone: handlers.onDone,
      onError: handlers.onError
    };
    this.session = session;

    const poll = async (): Promise<void> => {
      const active = this.session;
      if (active === null || active.key !== key) {
        return;
      }
      try {
        const raw = await controller.runJavaScript(DOM_SCAN_SCRIPT);
        const activeNow = this.session;
        if (activeNow === null || activeNow.key !== key) {
          return;
        }
        // 扫描协议：首行 ID:pathWord/uuid = 页面自身章节标识（身份校验），
        // 次行 HEAD:0/1 = 首个 li 的 data-src 是否就绪，其余行才是 URL。
        const text = String(raw === undefined ? '' : raw).split('\\n').join('\n');
        let body = text;
        let pageId = '';
        if (text.indexOf('ID:') === 0) {
          const idNl = text.indexOf('\n');
          pageId = idNl >= 0 ? text.substring(3, idNl) : text.substring(3);
          body = idNl >= 0 ? text.substring(idNl + 1) : '';
        }
        // 身份校验：页面 uuid 必须与请求章一致，否则本次扫描结果一律丢弃、绝不写盘。
        // 这堵住了「上一章 DOM 残留 / 导航未完成 / 被重定向」读错章图的竞态。
        const pageUuid = pageUuidOf(pageId);
        if (normalizeIdentity(pageUuid) !== activeNow.expectedUuid) {
          this.noteIdentityMismatch(activeNow, pageUuid);
          return;
        }
        if (!activeNow.identityVerified) {
          activeNow.identityVerified = true;
          activeNow.lastIdentity = pageUuid;
          if (COLLECTOR_LOG_ENABLED) {
            hilog.info(0x0000, 'Collector', '%{public}s',
            '身份校验通过 请求章=' + activeNow.expectedUuid + ' 页面章=' + pageUuid);
          }
        }
        let scanBody = body;
        if (scanBody.indexOf('HEAD:') === 0) {
          const headReady = scanBody.indexOf('HEAD:1') === 0;
          const nl = scanBody.indexOf('\n');
          scanBody = nl >= 0 ? scanBody.substring(nl + 1) : '';
          if (!headReady && activeNow.headWaits < 6) {
            activeNow.headWaits++;
            return;
          }
        }
        const scanned = parseScannedUrls(scanBody);
        // 取证：首帧轮询打印扫描到的总数与最前面几张；
        // 额外打印**未经清洗的原始片段**，用来判断杂字符是站点 DOM 自带
        // 还是我们链路（runJavaScript 序列化/拼接）引入的。
        if (!firstScanLogged) {
          firstScanLogged = true;
          logRawScan(text, scanned);
          logBatchHead('首帧扫描 共' + scanned.length + '张', scanned);
        }

        if (scanned.length > activeNow.reported) {
          const tail: string[] = [];
          for (let i = activeNow.reported; i < scanned.length; i++) {
            tail.push(wrapResolution(scanned[i]));
          }
          activeNow.reported = scanned.length;
          // 新增页 = 进度产物：停滞计时刷新
          activeNow.lastProgressAt = Date.now();
          activeNow.onBatch(tail);
        }
      } catch (error) {
        // 轮询异常不整章报废，保留已收集页，由超时/完成收口
      }
    };

    // 停滞看门狗：45s 无新增进度即收口；180s 总上限兜底。
    // 关键：只有页面身份已确认时才「保留已加载页」；身份不符一律按失败收口、绝不交付页面数据。
    session.watchdog = setInterval((): void => {
      const active = this.session;
      if (active === null || active.key !== key) {
        return;
      }
      const now = Date.now();
      // 身份一直未确认（导航失败 / 被重定向）：到点重新导航一次做有界重试，仍不符再失败收口
      if (!active.identityVerified && !active.identityRetried &&
        now - active.startedAt >= COLLECT_IDENTITY_RETRY_MS) {
        active.identityRetried = true;
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '身份未确认，重新导航重试 请求章=' + active.expectedUuid);
        }
        try {
          controller.loadUrl(this.pcUrl(comicId, chapterUuid));
        } catch (error) {
        }
        return;
      }
      if (now - active.lastProgressAt >= COLLECT_IDLE_TIMEOUT_MS) {
        if (!active.identityVerified) {
          if (COLLECTOR_LOG_ENABLED) {
            hilog.info(0x0000, 'Collector', '%{public}s',
            '收图停滞：页面身份未确认（请求章=' + active.expectedUuid + '，页面章=' +
            (active.lastIdentity.length > 0 ? active.lastIdentity : '(无法识别)') +
            '），按失败收口，未写盘');
          }
          this.failSession('网页收图失败（页面身份不符），未写入任何页面');
          return;
        }
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '收图停滞：' + COLLECT_IDLE_TIMEOUT_MS + 'ms 无新增进度（已收 ' + active.reported +
          ' 张），按停滞收口');
        }
        this.failSession('网页收图停滞（45 秒无新增进度），已保留已加载页面');
        return;
      }
      if (now - active.startedAt >= COLLECT_TOTAL_TIMEOUT_MS) {
        if (!active.identityVerified) {
          if (COLLECTOR_LOG_ENABLED) {
            hilog.info(0x0000, 'Collector', '%{public}s',
            '收图超时：页面身份未确认（请求章=' + active.expectedUuid + '），按失败收口，未写盘');
          }
          this.failSession('网页收图失败（页面身份不符），未写入任何页面');
          return;
        }
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '收图总时长触顶：' + COLLECT_TOTAL_TIMEOUT_MS + 'ms（已收 ' + active.reported + ' 张）');
        }
        this.failSession('网页收图超时，已保留已加载页面');
      }
    }, COLLECT_WATCH_INTERVAL_MS);

    setTimeout(() => {
      poll();
      session.poller = setInterval(() => {
        poll();
      }, rhythm.intervalMs);
    }, rhythm.initialDelayMs);

    try {
      controller.loadUrl(this.pcUrl(comicId, chapterUuid));
    } catch (error) {
      const value = error as Error;
      this.failSession(value.message !== undefined && value.message.length > 0 ?
        value.message : '网页收图加载失败');
    }
  }

  /**
   * 一次性收图（供下载器等不需要渐进加载的场景）。
   * 内部复用增量收图：最终以 loadChapter / 轮询完成收口，失败时保留已有页。
   */
  async load(comicId: string, chapterUuid: string): Promise<ChapterData> {
    return new Promise<ChapterData>((resolve: (data: ChapterData) => void,
      reject: (error: Error) => void) => {
      const imgUrls: string[] = [];
      this.loadStream(comicId, chapterUuid, {
        onBatch: (batch: string[]): void => {
          for (let i = 0; i < batch.length; i++) {
            imgUrls.push(batch[i]);
          }
        },
        onDone: (total: number): void => {
          if (imgUrls.length === 0) {
            reject(new Error('章节没有可下载的图片'));
            return;
          }
          resolve({
            title: '',
            uuid: chapterUuid,
            nextChapterUrl: '',
            previousChapterUrl: '',
            imgUrls: imgUrls
          });
        },
        onError: (message: string): void => {
          if (imgUrls.length === 0) {
            reject(new Error(message));
            return;
          }
          resolve({
            title: '',
            uuid: chapterUuid,
            nextChapterUrl: '',
            previousChapterUrl: '',
            imgUrls: imgUrls
          });
        }
      }).catch((error: Error) => {
        reject(error);
      });
    });
  }

  cancel(): void {
    const session = this.session;
    if (session === null) {
      return;
    }
    clearInterval(session.watchdog);
    clearInterval(session.poller);
    this.session = null;
    session.onError('网页收图已取消');
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

/** 「进入阅读器前预载页数」默认值与可选取值。 */
export const DEFAULT_READER_PREFETCH_COUNT: number = 20;
export const READER_PREFETCH_OPTIONS: number[] = [10, 20, 30, 50];

export async function readerPrefetchCount(): Promise<number> {
  const saved = await settingsStore.getInt(KEY_READER_PREFETCH_COUNT, DEFAULT_READER_PREFETCH_COUNT);
  return READER_PREFETCH_OPTIONS.indexOf(saved) >= 0 ? saved : DEFAULT_READER_PREFETCH_COUNT;
}

/**
 * 离线优先：若该章已完整下载（存在 .done），直接返回本地沙箱 URI，不发起任何网络请求。
 * 下载流程会显式传 allowLocal=false，避免「下载→查本地→返回本地」的短路。
 */
export async function loadLocalChapterImages(comicId: string, chapterUuid: string): Promise<string[]> {
  const record = downloadStore.findDownloadedChapter(comicId, chapterUuid);
  if (record === null) {
    return [];
  }
  const offline = downloadStore.loadOfflineChapter(record.directory);
  if (offline === null || !offline.completed || offline.imagePaths.length === 0) {
    // 未完整下载：不短路，走网络图源
    return [];
  }
  const out: string[] = [];
  for (let i = 0; i < offline.imagePaths.length; i++) {
    out.push(localImageUri(offline.imagePaths[i]));
  }
  return out;
}

/** 章节图源统一入口：离线优先 → API / 网页收图，统一 wrapResolution（本地路径除外）。 */
export async function loadChapterImages(comicId: string, chapterUuid: string,
  allowLocal: boolean = true): Promise<string[]> {
  if (allowLocal) {
    const local = await loadLocalChapterImages(comicId, chapterUuid);
    if (local.length > 0) {
      return local;
    }
  }

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