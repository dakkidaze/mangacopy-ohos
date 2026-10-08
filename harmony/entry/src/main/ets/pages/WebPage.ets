import { COLLECTOR_LOG_ENABLED } from '../services/Log';
/** 可见的移动版网页壳：负责 H5 浏览；章节点击被拦下后交给原生阅读器（不含隐藏收图）。 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { kMobileUserAgent } from '../services/ApiHeaders';
import { Chapter } from '../model/Models';
import { CopyApiSource } from '../services/CopyApiSource';
import { settingsStore } from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { navBarBackground, navBlurStyle, themeBackground, themeState } from './ThemeColors';
import { describeBrowseError, getBrowseSource } from './BrowseSupport';
import { ReaderChapterRef } from './ReaderPage';
import { ChapterHandoffState } from '../services/ChapterHandoffState';

/** FAB 长按判定阈值：按住这么久且手指没挪动，才算长按。 */
const FAB_LONG_PRESS_MS: number = 600;
/** FAB 手势位移门槛（vp）：超过即从「点 / 长按」切成「拖动」。 */
const FAB_MOVE_SLOP: number = 6;
/** 退出阅读器后的静默窗口（毫秒）：这段时间内不接管任何章节，避免"返回又进阅读器"。 */
const READER_CLOSED_QUIET_MS: number = 8000;
/**
 * 打开闸门的自愈超时：异步握手（取图源 + 取章节列表）卡住时，
 * 闸门滞留会让用户"一直正在加载、退不出去"。超过这个时长强制复位。
 */
const CHAPTER_OPENING_TIMEOUT_MS: number = 15000;
/**
 * 章节分组尝试顺序：`default` 拿不到或没命中目标 uuid 时依次退到下一个。
 * 空串 = 交给 CopyApiSource 自己的 defaultGroup。
 */
const CHAPTER_GROUPS: string[] = ['default', '', '全部', 'main'];
/** SPA 路由变化的轮询间隔（毫秒）：SPA 内部 push 不触发 onLoadIntercept，只能轮询地址。 */
const SPA_URL_POLL_MS: number = 400;
/**
 * 预置站点的「线路已初始化」标记，掐掉 /init?from= 回跳。
 *
 * 站点源码依据（/tmp/opencode/h5_index.js，/v2h5 那个 router 的 beforeEach）：
 *   "init"===e.name && "init"!==t.name && sessionStorage.setItem("init",!0)
 *   sessionStorage.getItem("init") || "init"===t.name ||
 *     a({name:"init", query:{from:encodeURIComponent(t.fullPath)}})
 * 即：sessionStorage.init 为空时，任何进入都会被重定向到 /init?from=<当前地址>；
 * init 页选完线路后 $router.replace(decodeURIComponent(from)) 把你送回原地址。
 * 我们整页 loadUrl 恢复详情页会重建上下文，一旦 init 标记缺失就会走这条回跳，
 * 把用户送回章节页 → 再次被接管 → 循环。
 *
 * 站点写入的是布尔 true（!0），会话存储会自动转成字符串 "true"；
 * 判定只做真值检查，所以这里写 "1"（非空即真）同样有效。
 *
 * 注意：/h5 那个 router 本身没有 beforeEach（已核实），但两个 router 共用同一份
 * sessionStorage，且站点存在跨域/跨 base 跳转，预置它对两条路径都无害。
 */
const INIT_GATE_SCRIPT: string =
  'javascript:(function(){try{sessionStorage.setItem("init","1");}catch(e){}})();';

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
  'toggleStatusBar',
  'onChapterBlocked',
  'onReaderDetected'
  , 'chapterClick', 'chapterGesture'
];

/** 握手链路日志：统一走 Collector tag，真机上 `hilog | grep Collector` 一次看全。 */
function handoffLog(message: string): void {
  if (COLLECTOR_LOG_ENABLED) {
    hilog.info(0x0000, 'Collector', '%{public}s', '网页章节接管：' + message);
  }
}

/** 入参只留前 120 字符，避免整段 h.js 结果刷屏。 */
function shortPayload(payload: string): string {
  return payload.length > 120 ? payload.substring(0, 120) + '…' : payload;
}

/**
 * 加载目标归一化：无协议头的裸域名补 https://，防止 chromium 报 invalidUrl。
 * 归一化后仍为空则回落候选首项。两种修正都记 Collector 日志，真机可查。
 */
function normalizeLoadTarget(raw: string, origin: string): string {
  const fixed = UrlManager.normalizeUrl(raw);
  if (fixed.length > 0) {
    if (fixed !== raw) {
      handoffLog('网页地址归一化：原始=' + raw + ' 修正=' + fixed + ' 来源=' + origin);
    }
    return fixed;
  }
  const fallback = UrlManager.candidates[0];
  handoffLog('网页地址无效（原始=' + raw + '），回落候选 ' + fallback + ' 来源=' + origin);
  return fallback;
}

/** 在章节列表里按 uuid 精确找。 */
function findChapter(chapters: Chapter[], uuid: string): Chapter | null {
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].id === uuid) {
      return chapters[i];
    }
  }
  return null;
}

/** 在章节列表里按名字找，命中不了再退回「第 N 话」的构造名。 */
function findChapterByName(chapters: Chapter[], name: string): Chapter | null {
  const wanted = normalizeChapterName(name);
  if (wanted.length === 0) {
    return null;
  }
  for (let i = 0; i < chapters.length; i++) {
    if (normalizeChapterName(chapters[i].name) === wanted) {
      return chapters[i];
    }
  }
  // 列表条目可能没带名字（只有 index），再比一次构造名「第 N 话」
  for (let i = 0; i < chapters.length; i++) {
    const fallback = '第 ' + chapters[i].index + ' 话';
    if (normalizeChapterName(fallback) === wanted) {
      return chapters[i];
    }
  }
  return null;
}

/**
 * 章节名归一化：全半角、空白、大小写、話/话 统一。
 * 站点条目形如「第01話」，点击文本可能是「第01话」「第 01 話」等变体。
 */
function normalizeChapterName(name: string): string {
  let text = name.trim();
  if (text.length === 0) {
    return '';
  }
  text = text.replace(/[！-～]/g, (c: string): string => {
    // 全角 ASCII（！U+FF01 ～ ～U+FF5E）→ 半角
    return String.fromCharCode(c.charCodeAt(0) - 0xFEE0);
  });
  text = text.replace(/　/g, ' '); // 全角空格
  text = text.replace(/\s+/g, ''); // 去掉所有空白
  text = text.replace(/話/g, '话');
  text = text.replace(/[Volvol．.]/g, '');
  text = text.toLowerCase();
  // 前导零宽容（任意数字段）：「第01话」与「第1话」、「Vol.01」与「Vol.1」视为同一章
  text = text.replace(/\d+/g, (digits: string): string => stripLeadingZeros(digits));
  return text;
}

/** 去掉前导零，全 0 保留一位（"000" → "0"）。 */
function stripLeadingZeros(digits: string): string {
  let i = 0;
  while (i < digits.length - 1 && digits[i] === '0') {
    i++;
  }
  return digits.substring(i);
}

/** 按阅读顺序（index 升序）组装阅读器切章序列，与详情页 openChapterReader 同口径。 */
function buildSequence(chapters: Chapter[]): ReaderChapterRef[] {
  const ordered: Chapter[] = [];
  for (let i = 0; i < chapters.length; i++) {
    ordered.push(chapters[i]);
  }
  ordered.sort((a: Chapter, b: Chapter): number => a.index - b.index);
  const refs: ReaderChapterRef[] = [];
  for (let i = 0; i < ordered.length; i++) {
    const c = ordered[i];
    refs.push(new ReaderChapterRef(c.id, c.name.length > 0 ? c.name : '第 ' + c.index + ' 话', c.size));
  }
  return refs;
}

class ComicChapterId {
  comicId: string = '';
  uuid: string = '';
}

/**
 * 从 URL 里解出 (comic 的 path_word, 章节 uuid)。
 * 形制依据 UrlManager.toPcUrl 与 h.js 的 toMobileUrl——两者都按 `/comicContent/{slug}/{uuid}` 读写，
 * 以及 UrlManager.comicDetailUrl 的 `/comic/{slug}/chapter/{uuid}`：
 * - 手机版章节页：`/comicContent/{pathWord}/{uuid}`；
 * - PC 版章节页：`/comic/{pathWord}/chapter/{uuid}`。
 * 详情页 `/details/comic/{pathWord}` 不含 chapter 段，解不出 uuid 时返回 null（调用方据此按正常浏览放过）。
 * 查询串与 hash 统一剥掉；PC 分支额外校验第 2 段必须是 chapter，避免把别的路径误认成章节。
 */
function parseChapterIds(url: string): ComicChapterId | null {
  if (url.length === 0) {
    return null;
  }
  const cleaned = stripQuery(url);
  const mobileMarker = '/comicContent/';
  const mobileIdx = cleaned.indexOf(mobileMarker);
  if (mobileIdx >= 0) {
    const segments = cleaned.substring(mobileIdx + mobileMarker.length).split('/');
    if (segments.length >= 2 && segments[0].length > 0 && segments[1].length > 0) {
      return idPair(segments[0], segments[1]);
    }
    return null;
  }
  const pcMarker = '/comic/';
  const pcIdx = cleaned.indexOf(pcMarker);
  if (pcIdx >= 0) {
    const segments = cleaned.substring(pcIdx + pcMarker.length).split('/');
    // PC 章节页形如 /comic/{pathWord}/chapter/{uuid}，第 2 段必须是 chapter
    if (segments.length >= 3 && segments[0].length > 0 && segments[1] === 'chapter' && segments[2].length > 0) {
      return idPair(segments[0], segments[2]);
    }
    return null;
  }
  return null;
}

function idPair(comicId: string, uuid: string): ComicChapterId | null {
  if (comicId.length === 0 || uuid.length === 0) {
    return null;
  }
  const pair = new ComicChapterId();
  pair.comicId = comicId;
  pair.uuid = uuid;
  return pair;
}

function stripQuery(url: string): string {
  const hashIdx = url.indexOf('#');
  let text = hashIdx >= 0 ? url.substring(0, hashIdx) : url;
  const queryIdx = text.indexOf('?');
  if (queryIdx >= 0) {
    text = text.substring(0, queryIdx);
  }
  return text;
}

/**
 * 取当前页面所属漫画的 path_word。
 * 详情路由实测为 `/details/{type}/{pathWord}`（type 段不止 comic，所以按 `/details/` 后跳一段取），
 * 兼容旧写法 `/details/comic/{pathWord}`；手机版章节页走 parseChapterIds 拿 pathWord。
 */
function comicSlugOf(url: string): string {
  const cleaned = stripQuery(url);
  const detailMarker = '/details/';
  const detailIdx = cleaned.indexOf(detailMarker);
  if (detailIdx >= 0) {
    const segments = cleaned.substring(detailIdx + detailMarker.length).split('/');
    // {type}/{pathWord}：type 可能是 comic 之外的类型，统一跳一段
    return segments.length >= 2 && segments[1].length > 0 ? segments[1] : '';
  }
  const ids = parseChapterIds(url);
  return ids === null ? '' : ids.comicId;
}

class VisibleWebBridge {
  onChapterPicked: (value: string, origin: string, hint: string) => void =
    (_value: string, _origin: string, _hint: string) => {};
  onHideFab: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onEnterProfile: () => void = () => {};
  onTitle: (value: string) => void = (_value: string) => {};
  onReaderDetectedCallback: () => void = () => {};
  onChapterClickCallback: (url: string, name: string, documentUrl: string, gestureId: string) => void =
    (_url: string, _name: string, _documentUrl: string, _gestureId: string) => {};
  onChapterGestureCallback: (documentUrl: string, gestureId: string) => void =
    (_documentUrl: string, _gestureId: string) => {};

  chapterClick(url: string, name: string, documentUrl: string, gestureId: string): void {
    this.onChapterClickCallback(url, name, documentUrl, gestureId);
  }

  chapterGesture(documentUrl: string, gestureId: string): void {
    this.onChapterGestureCallback(documentUrl, gestureId);
  }

  /**
   * 章节入口：只有能解出 (comic, uuid) 的 URL 才交给原生阅读器。
   * 详情页 URL（`/details/comic/…`）不在这里处理——那是正常浏览，不能弹任何提示。
   * 网页阅读器始终不放行：被拦下的导航由 shell 侧的 loadPreparedUrl 负责回落。
   */
  loadComic(url: string): void {
    if (parseChapterIds(url) !== null) {
      this.onChapterPicked(url, 'gm.loadComic', '');
    }
  }

  hideFab(): void {
    this.onHideFab();
  }

  enterProfile(): void {
    this.onEnterProfile();
  }

  openSettings(): void {
    this.onOpenSettings();
  }

  /**
   * h.js 收图结果的入口：首行是「章节名 章节uuid」，其后是相邻章 URL 与图片列表。
   * 这里同样只把第一节交给原生阅读器（隐藏收图页另有自己的桥，互不干扰）。
   */
  loadChapter(result: string): void {
    const firstLine = result.split('\n')[0];
    this.onChapterPicked(firstLine, 'gm.loadChapter', '');
  }

  setTitle(title: string): void {
    this.onTitle(title);
  }

  setFab(_json: string): void {
  }

  setLoadingDialog(_visible: boolean): void {
  }

  setLoadingDialogProgress(_index: number, _count: number): void {
  }

  toggleStatusBar(): void {
  }

  onReaderDetected(): void {
    this.onReaderDetectedCallback();
  }

  /**
   * guard.js 用文本特征拦下的章节点击：站点详情页的章节行不是 `<a href>`，
   * 拿不到 uuid，只能把「命中的章节文本」带出来，由 App 侧按名字反查。
   */
  onChapterBlocked(text: string): void {
    this.onChapterPicked('', 'guard.blocked', text);
  }
}

class WebReturnContext {
  originatingUrl: string = '';
  comicDetails: string = '';
  needsRestore: boolean = false;
}

@ComponentV2
struct WebHeader {
  @Param showBack: boolean = true;
  @Param title: string = '网页版';
  @Param pageUrl: string = '';
  @Param loading: boolean = false;
  @Param refreshEnabled: boolean = false;
  @Event onBack: () => void = () => {};
  @Event onRefresh: () => void = () => {};

  build() {
    Row({ space: 10 }) {
      if (this.showBack) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(21)
            .fontColor([$r('app.color.primary_text')])
        }
        .width(44)
        .height(44)
        .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => this.onBack())
      }

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.pageUrl.length > 0 ? this.pageUrl.replace('https://', '') : '正在选择源站…')
          .fontSize(10)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        if (this.loading) {
          LoadingProgress()
            .width(19)
            .height(19)
            .color($r('app.color.primary'))
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(19)
            .fontColor([$r('app.color.primary')])
        }
      }
      .width(44)
      .height(44)
      .backgroundColor($r('app.color.accent_soft'))
      .enabled(this.refreshEnabled)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => this.onRefresh())
    }
    .width('100%')
    .height(64)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    // 注意：这里必须是 Default（自身+子节点响应，阻塞兄弟节点）。
    // 用 Block 会「阻塞子节点」→ header 里的返回/刷新按钮全部点不动（已实测踩过）。
    .hitTestBehavior(HitTestMode.Default)
    .zIndex(20)
    .onTouch((event: TouchEvent) => {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'WebShell', 'header touch: %{public}d', event.type as number);
      }
    })
  }
}

@ComponentV2
export struct WebPage {
  @Require @Param controller: webview.WebviewController = new webview.WebviewController();
  @Param showBack: boolean = true;
  /**
   * 网页页当前是否在前台（外壳按路由给）。
   * webAsRoot 下 WebPage 常驻不卸载，其它路由（设置/阅读器/下载）在 Stack 上层叠加——
   * 此时它虽还挂着但已不可见，页面里残留的守卫/轮询仍会报同一章，靠这个标志吞掉。
   */
  @Param active: boolean = true;

  /**
   * 监听 active：从"被阅读器盖住"回到前台 = 阅读器已关闭。
   * 这时才恢复网页——接管瞬间不动网页是避免死循环的关键（见 suppressWebReader 注释）。
   */
  @Monitor('active')
  onActiveChanged(_monitor: IMonitor): void {
    this.handoff.setActive(this.active);
    if (!this.active) {
      this.cancelOpeningDeadline();
      this.clearPendingGesture();
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
      return;
    }
    if (!this.active || this.returnContext === null) {
      return;
    }
    this.onReaderClosed();
  }

  @Event onExit: () => void = () => {};
  @Event onOpenSettings: () => void = () => {};
  @Event onOpenDownloads: () => void = () => {};
  @Event onOpenAccount: () => void = () => {};
  /**
   * 章节点击落地到原生阅读器：与详情页 onOpenReader 同口径，
   * 多带一个 comicId——网页侧才知道当前页属于哪本漫画，外壳据此喂给 ReaderPage。
   */
  @Event onOpenReader: (comicId: string, chapterId: string, chapterName: string, chapterSize: number,
    sequence: ReaderChapterRef[]) => void =
    (_comicId: string, _chapterId: string, _chapterName: string, _chapterSize: number,
      _sequence: ReaderChapterRef[]) => {};
  /** 章节握不上时的降级出口：打开该漫画的原生详情页（path_word 即 comicId）。 */
  @Event onOpenDetail: (comicId: string) => void = (_comicId: string) => {};


  @Local title: string = '网页版';
  @Local pageUrl: string = '';
  @Local loading: boolean = true;
  @Local progress: number = 0;
  @Local failed: boolean = false;
  @Local errorText: string = '';
  @Local fabVisible: boolean = true;
  @Local fabReady: boolean = false;
  @Local fabX: number = -1;
  @Local fabY: number = -1;
  @Local viewportWidth: number = 0;
  @Local viewportHeight: number = 0;

  private controllerAttached: boolean = false;
  private gmScript: string = '';
  private interfaceScript: string = '';
  private guardScript: string = '';
  private readerRecoveryQuietUntil: number = 0;
  private refreshTicket: number = 0;
  private pendingRefreshTicket: number = 0;
  private refreshInFlight: boolean = false;
  private bridge: VisibleWebBridge = new VisibleWebBridge();
  private handoff: ChapterHandoffState = new ChapterHandoffState();
  private pendingGestureId: string = '';
  private pendingGestureDocumentUrl: string = '';
  private pendingGestureAt: number = 0;
  private fabStartX: number = 0;
  private fabStartY: number = 0;
  private fabTouchStartX: number = 0;
  private fabTouchStartY: number = 0;
  private fabTracking: boolean = false;
  private fabMoved: boolean = false;
  /** FAB 长按计时器：按住即起，移动或抬手即清。 */
  private fabLongPressTimer: number = -1;
  /** 本次按住是否已因长按打开过设置——抬手时据此吞掉随后的单击。 */
  private fabLongPressFired: boolean = false;
  private chapterOpening: boolean = false;
  /**
   * SPA 路由轮询：站点的「開始閱讀」类入口是 `<div>`/按钮，没有 `<a href>`，
   * i.js 的 installChapterTap 只查 `closest('a[href]')` 拦不住；SPA 内部 push 又不会触发
   * onLoadIntercept。只能靠 `controller.getUrl()` 轮询地址来兜住这类跳转。
   * 只在页面加载完成后跑，且在阅读器打开期间暂停（避免把网页回首页误判成新章节）。
   */
  private spaUrlTimer: number = -1;
  private spaLastUrl: string = '';
  /** 最近一次「非章节」浏览位：接管后没有回退历史时用它回落，避免掉到首页。 */
  private lastBrowseUrl: string = '';
  /** 进入原生阅读器那一刻的网页地址（退出时要按它决定恢复到哪）。 */
  private readerEntryUrl: string = '';
  /** 退出阅读器时是否需要恢复网页（进入时停在章节页才需要）。 */
  private pendingRestore: boolean = false;
  /**
   * 打开闸门的自愈时间戳：`chapterOpening` 置 true 后若超过这个时长还没收口，
   * 说明某条链路卡死（用户会遇到"一直正在加载"），强制复位放后续请求进来。
   */
  private chapterOpeningSince: number = 0;
  private openingTimer: number = -1;
  private openingTimerRid: number = 0;
  /**
   * 已交给阅读器的章节 URL（整串，含源站）。站点可能把我们送回同一个章节页
   * （详情/路由恢复等），这条 URL 再见时一律跳过，直到用户点了别的章节。
   */
  /** 退出阅读器后的静默窗口：这段时间内不接管，避免"返回又进阅读器"。 */
  private returnContext: WebReturnContext | null = null;
  @Local fabPressed: boolean = false;

  aboutToAppear(): void {
    this.handoff.setMounted(true);
    this.handoff.setActive(this.active);
    this.loadScripts();
    this.loadFabPosition();
    this.prepareHome();
    this.startSpaUrlWatch();
  }

  aboutToDisappear(): void {
    this.handoff.setMounted(false);
    this.cancelOpeningDeadline();
    this.clearPendingGesture();
    this.chapterOpening = false;
    this.chapterOpeningSince = 0;
    this.stopSpaUrlWatch();
    this.cancelFabLongPress();
  }

  private loadScripts(): void {
    const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (context === undefined) {
      this.errorText = '应用上下文尚未准备好';
      this.failed = true;
      return;
    }
    try {
      const decoder = util.TextDecoder.create('utf-8');
      this.gmScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/gm_shim.js'));
      this.interfaceScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/i.js'));
      this.guardScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/guard.js'));
    } catch (error) {
      this.errorText = '页面脚本读取失败';
      this.failed = true;
    }
  }

  private async prepareHome(): Promise<void> {
    try {
      const cached = await UrlManager.bootstrap();
      this.pageUrl = normalizeLoadTarget(UrlManager.activeUrl, 'prepareHome.cache');
      if (!cached) {
        // 首次无缓存：同步测速选源，再进页（现状保持）
        await UrlManager.probe();
        this.pageUrl = normalizeLoadTarget(UrlManager.activeUrl, 'prepareHome.probe');
      } else {
        // 有缓存先进 + 后台测速：fire-and-forget，只更新 sticky/落盘与提示（lastProbeNote），
        // 不打断当前页、不自动重载，也不 await。
        UrlManager.probe().catch((_error: Object): void => {});
      }
      this.loadPreparedUrl();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '源站准备失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private async loadFabPosition(): Promise<void> {
    try {
      const savedX = await settingsStore.getString('fab_dx', '');
      const savedY = await settingsStore.getString('fab_dy', '');
      if (savedX.length > 0 && savedY.length > 0) {
        const x = Number(savedX);
        const y = Number(savedY);
        if (!Number.isNaN(x) && !Number.isNaN(y)) {
          this.fabX = x;
          this.fabY = y;
        }
      }
    } catch (error) {
    }
    this.placeFabWithinBounds();
  }

  private placeFabWithinBounds(): void {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) {
      return;
    }
    const size = 48;
    const minX = 12;
    const maxX = Math.max(minX, this.viewportWidth - size - 12);
    const minY = 72;
    const safeBottom = Math.max(80, this.navigationInset() + 52);
    const maxY = Math.max(minY, this.viewportHeight - size - safeBottom);
    if (this.fabX < 0 || this.fabY < 0) {
      this.fabX = maxX;
      this.fabY = maxY;
    } else {
      this.fabX = Math.max(minX, Math.min(maxX, this.fabX));
      this.fabY = Math.max(minY, Math.min(maxY, this.fabY));
    }
    this.fabReady = true;
  }

  private navigationInset(): number {
    const inset = AppStorage.get<number>('navIndicatorVp');
    return inset === undefined ? 8 : Math.max(8, inset);
  }

  private async saveFabPosition(): Promise<void> {
    try {
      await settingsStore.putString('fab_dx', this.fabX.toString());
      await settingsStore.putString('fab_dy', this.fabY.toString());
    } catch (error) {
    }
  }

  private touchPoint(event: TouchEvent): TouchObject | null {
    if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    if (event.touches.length > 0) {
      return event.touches[0];
    }
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    return null;
  }

  private handleFabTouch(event: TouchEvent): void {
    const point = this.touchPoint(event);
    if (event.type === TouchType.Down && point !== null) {
      this.fabTouchStartX = point.windowX;
      this.fabTouchStartY = point.windowY;
      this.fabStartX = this.fabX;
      this.fabStartY = this.fabY;
      this.fabTracking = true;
      this.fabMoved = false;
      this.fabPressed = true;
      this.startFabLongPress();
      event.stopPropagation();
      return;
    }
    if (event.type === TouchType.Move && this.fabTracking && point !== null) {
      const dx = point.windowX - this.fabTouchStartX;
      const dy = point.windowY - this.fabTouchStartY;
      if (Math.sqrt(dx * dx + dy * dy) >= FAB_MOVE_SLOP) {
        this.fabMoved = true;
      }
      if (this.fabMoved) {
        // 手指一动就作废长按：拖动与长按互斥，不必等 600ms 到了再去取消
        this.cancelFabLongPress();
        this.fabX = this.fabStartX + dx;
        this.fabY = this.fabStartY + dy;
        this.placeFabWithinBounds();
      }
      event.stopPropagation();
      return;
    }
    if (event.type === TouchType.Up) {
      if (!this.fabTracking) {
        this.fabPressed = false;
        return;
      }
      if (point !== null) {
        const dx = point.windowX - this.fabTouchStartX;
        const dy = point.windowY - this.fabTouchStartY;
        if (Math.sqrt(dx * dx + dy * dy) >= FAB_MOVE_SLOP) {
          this.fabMoved = true;
          this.cancelFabLongPress();
          this.fabX = this.fabStartX + dx;
          this.fabY = this.fabStartY + dy;
          this.placeFabWithinBounds();
        }
      }
      const moved = this.fabMoved;
      // 长按已落地：这一次抬手只收尾，不再走单击分支，避免松手时顺带打开下载
      const longPressed = this.fabLongPressFired;
      this.resetFabGesture();
      event.stopPropagation();
      if (moved) {
        this.saveFabPosition();
      } else if (!longPressed) {
        // 单击 = 打开「我的下载」（对齐 Flutter 网页版 FAB 语义）
        this.onOpenDownloads();
      }
      return;
    }
    if (event.type === TouchType.Cancel) {
      this.resetFabGesture();
      event.stopPropagation();
    }
  }

  /** 按住 FAB 起 600ms：到点且手指全程没移动，则打开设置并给一次轻提示。 */
  private startFabLongPress(): void {
    this.cancelFabLongPress();
    this.fabLongPressFired = false;
    this.fabLongPressTimer = setTimeout((): void => {
      this.fabLongPressTimer = -1;
      this.fabLongPressFired = true;
      this.fabPressed = false;
      this.showToast('设置');
      this.onOpenSettings();
    }, FAB_LONG_PRESS_MS);
  }

  private cancelFabLongPress(): void {
    if (this.fabLongPressTimer >= 0) {
      clearTimeout(this.fabLongPressTimer);
      this.fabLongPressTimer = -1;
    }
  }

  /** 一次按压收尾（抬手 / 被系统接管）：清计时与 pressed，保留 longPressFired 给调用方读。 */
  private resetFabGesture(): void {
    this.cancelFabLongPress();
    this.fabTracking = false;
    this.fabMoved = false;
    this.fabPressed = false;
    // longPressFired 交给下一次 Down 复位，让 Up 分支还能读到本次按压的结果
  }

  /** SPA 地址轮询的启动与停止：只在页面就绪后跑，卸载时务必停掉。 */
  private startSpaUrlWatch(): void {
    this.stopSpaUrlWatch();
    this.spaUrlTimer = setInterval((): void => {
      this.pollSpaUrl();
    }, SPA_URL_POLL_MS);
  }

  private stopSpaUrlWatch(): void {
    if (this.spaUrlTimer >= 0) {
      clearInterval(this.spaUrlTimer);
      this.spaUrlTimer = -1;
    }
  }

  private startOpeningDeadline(rid: number): void {
    this.cancelOpeningDeadline();
    this.openingTimerRid = rid;
    this.openingTimer = setTimeout((): void => {
      if (this.openingTimerRid !== rid || !this.handoff.owns(rid)) return;
      this.openingTimer = -1;
      this.openingTimerRid = 0;
      this.handoff.invalidate();
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
      this.showToast('打开章节超时，请重试');
    }, 15000);
  }

  private cancelOpeningDeadline(rid: number = 0): void {
    if (rid > 0 && this.openingTimerRid !== rid) return;
    if (this.openingTimer >= 0) clearTimeout(this.openingTimer);
    this.openingTimer = -1;
    this.openingTimerRid = 0;
  }

  /**
   * 一次地址采样。只关心「从非章节页跳到章节页」这一件事：
   * 网页阅读器一旦渲染出来就会被守卫打回首页，趁它还在时先把章节交给原生阅读器。
   */
  private pollSpaUrl(): void {
    if (this.handoff.expire(Date.now())) {
      this.cancelOpeningDeadline();
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
    }
    if (!this.controllerAttached || this.loading || this.chapterOpening || !this.active) {
      return;
    }
    let current = '';
    try {
      current = this.controller.getUrl();
    } catch (error) {
      return;
    }
    if (current.length === 0 || current === 'about:blank' || current === this.spaLastUrl) {
      return;
    }
    const previous = this.spaLastUrl;
    this.spaLastUrl = current;
    // lastBrowseUrl 跟随 SPA 现读地址（非章节即更新）：
    // 只靠 onPageEnd 更新会停在首页——SPA push 根本不触发 onPageEnd，
    // 于是接管后的回落目标永远是主页，这正是死循环的一环。
    if (parseChapterIds(current) === null) {
      if (current !== this.lastBrowseUrl) {
        handoffLog('浏览位更新（SPA 现读）=' + current + ' 上一页=' + previous);
      }
      this.lastBrowseUrl = current;
      return;
    }
    // 网页页已经不在前台（阅读器/详情页盖在上面）时不再接管：
    // 那说明这次地址变化是我们自己回退网页造成的，不是用户点的新章节
    if (!this.active) {
      handoffLog('SPA 轮询跳过：网页页不在前台 url=' + current);
      return;
    }
    handoffLog('SPA 路由进入章节页 url=' + current + ' 上一页=' + previous);
    this.handleChapterPick(current, 'spaPoll', '');
  }

  private configureBridge(): void {
    this.bridge.onChapterPicked = (value: string, origin: string, hint: string): void => {
      this.handleChapterPick(value, origin, hint);
    };
    this.bridge.onChapterClickCallback = (url: string, name: string, documentUrl: string,
      gestureId: string): void => {
      this.handleChapterPick(url, 'chapter.click', name, gestureId, documentUrl);
    };
    this.bridge.onChapterGestureCallback = (documentUrl: string, gestureId: string): void => {
      if (this.active && gestureId.length > 0) {
        this.pendingGestureId = gestureId;
        this.pendingGestureDocumentUrl = documentUrl;
        this.pendingGestureAt = Date.now();
      }
    };
    this.bridge.onHideFab = (): void => {
      if (this.showBack) {
        this.fabVisible = false;
      } else {
        this.fabVisible = true;
      }
    };
    this.bridge.onOpenSettings = (): void => {
      this.onOpenSettings();
    };
    // 网页壳里「站点个人中心」留在 H5：i.js 的 /personal 分支仍会注入 ⚙ App扩展设置逃生口，
    // 桥接侧不做任何跳转（原生账号页只由原生模式「更多 → 账号」到达）
    this.bridge.onEnterProfile = (): void => {
    };
    this.bridge.onTitle = (value: string): void => {
      if (value.trim().length > 0) {
        this.title = value;
      }
    };
    this.bridge.onReaderDetectedCallback = (): void => {
      this.handleReaderDetected();
  };  }

  private clearPendingGesture(): void {
    this.pendingGestureId = '';
    this.pendingGestureDocumentUrl = '';
    this.pendingGestureAt = 0;
  }

  /**
   * 「章节 → 原生阅读器」的唯一入口。来源都汇到这里：
   * 1. GM.loadComic(`/comicContent/{pathWord}/{uuid}`) —— installChapterTap 拦下的 `<a href>` 点击；
   * 2. GM.loadChapter(result) —— h.js 收尾回报，取首节的「章节名 uuid」；
   * 3. GM.onChapterBlocked(text) —— guard.js 文本特征拦下的非链接章节行，只有章节名；
   * 4. onLoadIntercept + SPA 地址轮询 —— 「開始閱讀」类无 href 入口的兜底。
   *
   * 3 与 1/2/4 走不同分支：前者没有 uuid，只能拿当前页 slug + 章节名去列表反查。
   */
  private handleChapterPick(payload: string, origin: string, hint: string, gestureId: string = '',
    entryUrl: string = ''): void {
    const now = Date.now();
    if (this.handoff.expire(now)) {
      this.cancelOpeningDeadline();
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
    }
    if (!this.active) {
      return;
    }
    let sourceSnapshot = entryUrl;
    let intentId = gestureId;
    if (intentId.length === 0 && this.pendingGestureId.length > 0 &&
      now - this.pendingGestureAt <= 5000) {
      intentId = this.pendingGestureId;
      sourceSnapshot = this.pendingGestureDocumentUrl;
    }
    this.clearPendingGesture();
    if (intentId.length === 0) {
      return;
    }
    if (sourceSnapshot.length === 0) {
      sourceSnapshot = this.currentWebUrl();
    }
    const requestId = this.handoff.begin(intentId, now);
    if (requestId === 0) {
      return;
    }
    this.startOpeningDeadline(requestId);
    handoffLog('收到章节请求 来源=' + origin + ' 入参=' + shortPayload(payload) +
      ' 章节名=' + (hint.length > 0 ? hint : '(无)'));
    // 无 uuid 的名字分支：当前页 slug（详情页可解析）+ 章节名 → 反查 uuid
    if (hint.length > 0 && parseChapterIds(payload) === null) {
      const slug = comicSlugOf(sourceSnapshot);
      if (slug.length === 0) {
        handoffLog('失败[名字分支]：当前页拿不到 pathWord 来源=' + origin +
          ' 当前页=' + sourceSnapshot);
        this.handoff.finish(requestId);
        this.showToast('名字分支拿不到 pathWord');
        return;
      }
      handoffLog('名字分支 comic=' + slug + ' 章节名=' + hint + ' 来源=' + origin);
      this.openNativeReaderByName(slug, hint, origin, sourceSnapshot, requestId, sourceSnapshot);
      return;
    }
    const raw = payload.length === 0 ? sourceSnapshot : this.locateChapter(payload);
    const fallbackId = comicSlugOf(raw.length > 0 ? raw : sourceSnapshot);
    if (raw.length === 0) {
      handoffLog('失败[解析前]：拿不到可解析的地址 来源=' + origin + ' 当前页=' + sourceSnapshot);
      this.handoff.finish(requestId);
      this.showToast('解析前拿不到地址');
      return;
    }
    const ids = parseChapterIds(raw);
    if (ids === null) {
      handoffLog('失败[解析]：地址里没有 pathWord/uuid 来源=' + origin + ' url=' + raw);
      this.handoff.finish(requestId);
      this.showToast('地址不含章节 uuid');
      return;
    }
    handoffLog('解析成功 comic=' + ids.comicId + ' uuid=' + ids.uuid + ' 来源=' + origin);
    this.openNativeReader(ids.comicId, ids.uuid, origin, raw, requestId, sourceSnapshot);
  }

  /** 失败汇总：日志一律记 Collector tag；能定位到漫画就降级开原生详情页，否则只提示。 */
  private reportChapterFailure(message: string, comicId: string = '', rid: number = 0,
    entryUrl: string = ''): void {
    if (rid > 0 && !this.handoff.owns(rid)) return;
    handoffLog('结局=失败：' + message);
    if (comicId.length > 0) {
      this.degradeToDetail(comicId, message, rid, entryUrl);
      return;
    }
    this.showToast(message);
  }

  /**
   * 降级出口：打开该漫画的原生详情页。
   * 详情页自带完整章节列表与重试入口，比只弹一句提示有用得多。
   */
  private degradeToDetail(comicId: string, reason: string, rid: number = 0, entryUrl: string = ''): void {
    if (rid > 0 && !this.handoff.owns(rid)) return;
    if (comicId.length === 0) {
      handoffLog('降级失败：连 pathWord 都拿不到，仅提示 原因=' + reason);
      this.showToast('无法打开该章节，可到详情页重试');
      return;
    }
    handoffLog('降级 → 原生详情页 comic=' + comicId + ' 原因=' + reason);
    if (rid > 0) {
      this.commitReturnContext(comicId, entryUrl);
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
      this.cancelOpeningDeadline(rid);
      this.handoff.finish(rid);
    }
    this.showToast('已打开该漫画详情页，请从中选择章节');
    this.onOpenDetail(comicId);
  }

  /**
   * 把任意形态的入参收敛成一条可解析的 URL：
   * 已经是 URL 就原样用；否则按 `章节名 uuid` 拼出手机版章节 URL。
   * 兜底地址同样现读：SPA push 后 this.pageUrl 可能还没更新。
   */
  private locateChapter(payload: string): string {
    const text = payload.trim();
    if (text.length === 0) {
      return this.currentWebUrl();
    }
    if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) {
      return text;
    }
    const separator = text.lastIndexOf(' ');
    if (separator < 0) {
      return '';
    }
    // 前缀方式：'第 N 话 xxxx-xxxx-xxxx' → /comicContent/{当前 pathWord}/{uuid}
    const chapterUuid = text.substring(separator + 1).trim();
    if (chapterUuid.length === 0) {
      return '';
    }
    const slug = comicSlugOf(this.currentWebUrl());
    if (slug.length === 0) {
      return '';
    }
    return normalizeLoadTarget(UrlManager.activeUrl + '/comicContent/' + slug + '/' + chapterUuid, 'locateChapter');
  }

  /**
   * 取章节列表 → 定位目标 uuid → 按 index 升序组装序列 → 交给原生阅读器。
   * 与详情页同一数据口径（`getBrowseSource` + `source.chapters`）。
   * 每一步都打 Collector 日志，便于一眼区分失败环节。
   *
   * 分组口径：详情页能出章节不代表这里也能——`default` 拿不到或没命中目标 uuid 时，
   * 依次退到空串（图源自带的 defaultGroup）与其他常见分组，全都不行才降级。
   */
  private async openNativeReader(comicId: string, chapterUuid: string, origin: string,
    url: string = '', rid: number = 0, entryUrl: string = ''): Promise<void> {
    if (!this.handoff.owns(rid)) {
      return;
    }
    this.chapterOpening = true;
    this.chapterOpeningSince = Date.now();
    this.showToast('正在打开章节…');
    const startedAt = Date.now();
    try {
      const source = await this.acquireSource(comicId, startedAt);
      if (!this.handoff.owns(rid)) {
        return;
      }
      for (let g = 0; g < CHAPTER_GROUPS.length; g++) {
        const group = CHAPTER_GROUPS[g];
        const label = group.length > 0 ? group : '(图源默认)';
        let chapters: Chapter[] = [];
        try {
          handoffLog('取章节列表 comic=' + comicId + ' 分组=' + label);
          chapters = await source.chapters(comicId, group);
          if (!this.handoff.owns(rid)) {
            return;
          }
        } catch (error) {
          if (!this.handoff.owns(rid)) {
            return;
          }
          handoffLog('取章节列表失败 分组=' + label + ' 原因=' + describeBrowseError(error as Object));
          continue;
        }
        if (!this.handoff.owns(rid)) {
          return;
        }
        handoffLog('章节列表返回 ' + chapters.length + ' 条 分组=' + label);
        const target = findChapter(chapters, chapterUuid);
        if (target === null) {
          handoffLog('目标 uuid 未命中 分组=' + label + ' uuid=' + chapterUuid +
            ' 首条=' + (chapters.length > 0 ? chapters[0].id : '(空)'));
          continue;
        }
        if (!this.handoff.owns(rid)) {
          return;
        }
        this.launchReader(comicId, target, chapters, label, origin, startedAt, rid, entryUrl);
        return;
      }
      if (!this.handoff.owns(rid)) {
        return;
      }
      handoffLog('结局=降级：所有分组都没命中，转原生详情页 comic=' + comicId + ' uuid=' + chapterUuid);
      this.degradeToDetail(comicId, '所有分组都未命中 uuid', rid, entryUrl);
    } catch (error) {
      if (!this.handoff.owns(rid)) {
        return;
      }
      handoffLog('结局=失败[异常]：' + describeBrowseError(error as Object) +
        ' comic=' + comicId + ' uuid=' + chapterUuid);
      this.reportChapterFailure('无法打开该章节，可到详情页重试', comicId, rid, entryUrl);
    } finally {
      if (this.handoff.owns(rid)) {
        this.chapterOpening = false;
        this.chapterOpeningSince = 0;
        this.cancelOpeningDeadline(rid);
        this.handoff.finish(rid);
      }
    }
  }

  /**
   * 名字分支：详情页里被文本特征拦下的章节行，只有章节名没有 uuid。
   * 取该漫画章节列表 → 按名字（宽容匹配）反查 uuid → 直接开阅读器；匹配失败才降级。
   */
  private async openNativeReaderByName(comicId: string, chapterName: string, origin: string,
    url: string = '', rid: number = 0, entryUrl: string = ''): Promise<void> {
    if (!this.handoff.owns(rid)) {
      return;
    }
    this.chapterOpening = true;
    this.chapterOpeningSince = Date.now();
    this.showToast('正在打开章节…');
    const startedAt = Date.now();
    try {
      const source = await this.acquireSource(comicId, startedAt);
      if (!this.handoff.owns(rid)) {
        return;
      }
      for (let g = 0; g < CHAPTER_GROUPS.length; g++) {
        const group = CHAPTER_GROUPS[g];
        const label = group.length > 0 ? group : '(图源默认)';
        let chapters: Chapter[] = [];
        try {
          handoffLog('按名取章节列表 comic=' + comicId + ' 分组=' + label);
          chapters = await source.chapters(comicId, group);
          if (!this.handoff.owns(rid)) {
            return;
          }
        } catch (error) {
          if (!this.handoff.owns(rid)) {
            return;
          }
          handoffLog('按名取章节列表失败 分组=' + label + ' 原因=' + describeBrowseError(error as Object));
          continue;
        }
        if (!this.handoff.owns(rid)) {
          return;
        }
        handoffLog('按名章节列表返回 ' + chapters.length + ' 条 分组=' + label);
        const target = findChapterByName(chapters, chapterName);
        if (target === null) {
          handoffLog('按名未命中 分组=' + label + ' 章节名=' + chapterName +
            ' 首条名=' + (chapters.length > 0 ? chapters[0].name : '(空)'));
          continue;
        }
        if (!this.handoff.owns(rid)) {
          return;
        }
        // 命中后按 uuid 记账，让随后 guard/spaPoll 报同一章时被去重吞掉
        handoffLog('按名命中 uuid=' + target.id + ' 章节名=' + chapterName);
        this.launchReader(comicId, target, chapters, label, origin + '+byName', startedAt, rid, entryUrl);
        return;
      }
      if (!this.handoff.owns(rid)) {
        return;
      }
      handoffLog('结局=降级：按名所有分组都未命中 comic=' + comicId + ' 章节名=' + chapterName);
      this.degradeToDetail(comicId, '按章节名未命中', rid, entryUrl);
    } catch (error) {
      if (!this.handoff.owns(rid)) {
        return;
      }
      handoffLog('结局=失败[异常·按名]：' + describeBrowseError(error as Object) +
        ' comic=' + comicId + ' 章节名=' + chapterName);
      this.reportChapterFailure('无法打开该章节，可到详情页重试', comicId, rid, entryUrl);
    } finally {
      if (this.handoff.owns(rid)) {
        this.chapterOpening = false;
        this.chapterOpeningSince = 0;
        this.cancelOpeningDeadline(rid);
        this.handoff.finish(rid);
      }
    }
  }

  /** 取图源（带日志），两条分支共用。 */
  /**
    * 章节接管准入与握手滞留自愈。
   */
  private canTakeChapter(origin: string, url: string = ''): boolean {
    if (!this.active) {
      handoffLog('闸门拦截：网页页不在前台 来源=' + origin);
      return false;
    }
    const now = Date.now();
    if (this.chapterOpening) {
      const held = now - this.chapterOpeningSince;
      if (held < CHAPTER_OPENING_TIMEOUT_MS) {
        handoffLog('闸门拦截：已有握手在跑（已持有 ' + held + 'ms） 来源=' + origin);
        return false;
      }
      // 闸门滞留超时：判定为卡死，强制复位并放这次请求进来
      handoffLog('闸门自愈：握手滞留 ' + held + 'ms 超过阈值，强制复位 来源=' + origin);
      this.chapterOpening = false;
      this.chapterOpeningSince = 0;
    }
    return true;
  }

  private async acquireSource(comicId: string, startedAt: number): Promise<CopyApiSource> {
    handoffLog('取图源中 comic=' + comicId);
    const source = await getBrowseSource();
    handoffLog('取图源完成 用时=' + (Date.now() - startedAt) + 'ms');
    return source;
  }

  /** 组装序列并交给原生阅读器，两条分支共用。 */
  private launchReader(comicId: string, target: Chapter, chapters: Chapter[], label: string,
    origin: string, startedAt: number, rid: number, entryUrl: string): void {
    if (!this.handoff.owns(rid)) return;
    const refs = buildSequence(chapters);
    const chapterName = target.name.length > 0 ? target.name : '第 ' + target.index + ' 话';
    handoffLog('握手成功 → openReader comic=' + comicId + ' chapter=' + chapterName +
      ' uuid=' + target.id + ' 页数=' + target.size + ' 序列=' + refs.length +
      ' 分组=' + label + ' 来源=' + origin + ' 总用时=' + (Date.now() - startedAt) + 'ms');
    this.commitReturnContext(comicId, entryUrl);
    this.chapterOpening = false;
    this.chapterOpeningSince = 0;
    this.cancelOpeningDeadline(rid);
    this.handoff.finish(rid);
    this.onOpenReader(comicId, target.id, chapterName, target.size, refs);
  }

  private commitReturnContext(comicId: string, entryUrl: string): void {
    const context = new WebReturnContext();
    context.originatingUrl = entryUrl;
    context.comicDetails = UrlManager.activeUrl + '/h5/details/comic/' + comicId;
    context.needsRestore = parseChapterIds(entryUrl) !== null || parseChapterIds(this.currentWebUrl()) !== null;
    this.returnContext = context;
    this.readerEntryUrl = entryUrl;
    this.pendingRestore = context.needsRestore;
  }

  /**
   * 接管后**不再导航网页**——这是死循环的根因，详见 detailUrlFor 的注释。
   * 进阅读器由原生层盖住即可（网页在下面不再继续渲染阅读器）。
   * 网页侧的处理推迟到「退出阅读器」那一刻（见 onReaderClosed）。
   *
   * 备注：早期版本在这里 history.back()，真机实测会把 SPA 从路由渲染中途拽断
   * （Request aborted / Cannot read properties of undefined），SPA 状态损坏后掉回主页；
   * 后来改成 loadUrl 到 /h5/index，又因为站点通配路由会自行回到章节页而形成循环。
   * 现在彻底不在接管瞬间动网页。
   */
  /**
   * 退出原生阅读器后由外壳回调：这时才动网页。
   * 若进入时停在章节页，用整页 loadUrl（走归一化）恢复到该漫画的详情页，
   * 并同步更新 lastBrowseUrl —— 详情页不是章节页，不会被站点的路由恢复逻辑改写。
   */
  private onReaderClosed(): void {
    const context = this.returnContext;
    if (context === null) return;
    if (!context.needsRestore) {
      this.returnContext = null;
      this.pendingRestore = false;
      return;
    }
    const detail = context.comicDetails;
    handoffLog('退出阅读器 → 恢复详情页 目标=' + detail + '（进入时=' + context.originatingUrl + '）');
    this.lastBrowseUrl = detail;
    this.spaLastUrl = detail;
    this.loadUrlQuiet(detail);
  }

  /**
   * 由章节 URL 反推详情页：`/comicContent/{pathWord}/{uuid}` → `/h5/details/{type}/{pathWord}`。
   * 站点路由表（/tmp/opencode/h5_index.js）里详情路由是 `/details/:type/:pathWord`，
   * type 对漫画取 `comic`。
   *
   * **为什么必须是详情页而不是首页**：站点 `/h5` 路由有 `{path:"*",redirect:"/index"}` 兜底，
   * 且 history 模式下刷新/重载会重新走路由解析；实测把网页 loadUrl 到 `/h5/index` 后，
   * H5 会自行回到章节页 → onLoadIntercept 再命中 → 再开阅读器 → **无限循环**。
   * 详情页是具体路由，不会被通配改写，因此选它做恢复目标。
   */
  private detailUrlFor(chapterUrl: string): string {
    const ids = parseChapterIds(chapterUrl);
    if (ids === null) {
      return '';
    }
    return UrlManager.activeUrl + '/h5/details/comic/' + ids.comicId;
  }

  /** 选回落目标（保留兼容：非阅读器链路仍可用）。 */
  private pickReturnTarget(): string {
    if (this.lastBrowseUrl.length > 0 && parseChapterIds(this.lastBrowseUrl) === null) {
      return this.lastBrowseUrl;
    }
    if (UrlManager.activeUrl.length > 0) {
      return UrlManager.activeUrl + '/h5/index';
    }
    return '';
  }

  /** 只加载、不改其它状态（回落用）。加载前先归一化，裸域名在这里也会被补全协议头。 */
  private loadUrlQuiet(url: string): void {
    const target = normalizeLoadTarget(url, 'loadUrlQuiet');
    this.pageUrl = target;
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    // 先补 init 标记再导航：站点一旦走 /init?from= 回跳就来不及了
    // （sessionStorage 同源重载不丢，但首次进入时可能还没写过）
    try {
      this.controller.runJavaScript(INIT_GATE_SCRIPT);
    } catch (error) {
      // 注入失败不阻塞导航
    }
    try {
      this.controller.loadUrl(target);
    } catch (error) {
      this.loading = false;
    }
  }

  private onControllerAttached(): void {
    this.controllerAttached = true;
    this.configureBridge();
    try {
      this.controller.registerJavaScriptProxy(this.bridge, 'GM', GM_METHODS);
      this.controller.setCustomUserAgent(kMobileUserAgent);
      this.loadPreparedUrl();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '网页组件初始化失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private loadPreparedUrl(): void {
    if (!this.controllerAttached || this.pageUrl.length === 0) {
      return;
    }
    const target = normalizeLoadTarget(this.pageUrl, 'loadPreparedUrl');
    this.pageUrl = target;
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    try {
      this.controller.loadUrl(target);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '网页加载失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private refreshPage(): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'WebShell', 'refresh tapped');
    }
    if (!this.controllerAttached) {
      hilog.error(0x0000, 'WebShell', 'refresh result: failed, controller not attached');
      return;
    }
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    this.refreshInFlight = true;
    const ticket = ++this.refreshTicket;
    this.pendingRefreshTicket = ticket;
    try {
      this.controller.refresh();
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'WebShell', 'refresh dispatched: controller.refresh');
      }
      setTimeout(() => {
        if (this.pendingRefreshTicket === ticket) {
          this.fallbackRefresh(ticket, 'controller.refresh 未触发页面加载');
        }
      }, 700);
    } catch (error) {
      const value = error as Error;
      const message = value.message !== undefined && value.message.length > 0 ? value.message : 'refresh failed';
      this.fallbackRefresh(ticket, message);
    }
  }

  private fallbackRefresh(ticket: number, reason: string): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.warn(0x0000, 'WebShell', 'refresh fallback: %{public}s', reason);
    }
    const target = normalizeLoadTarget(this.pageUrl, 'fallbackRefresh');
    this.pageUrl = target;
    this.pendingRefreshTicket = -ticket;
    try {
      this.controller.loadUrl(target);
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'WebShell', 'refresh fallback dispatched: loadUrl');
      }
      setTimeout(() => {
        if (this.refreshInFlight && this.pendingRefreshTicket === -ticket) {
          this.pendingRefreshTicket = 0;
          this.refreshInFlight = false;
          this.loading = false;
          this.failed = true;
          this.errorText = '刷新未触发页面加载';
          hilog.error(0x0000, 'WebShell', 'refresh result: failed, no page lifecycle after fallback');
        }
      }, 3000);
    } catch (fallbackError) {
      const fallback = fallbackError as Error;
      const message = fallback.message !== undefined && fallback.message.length > 0 ?
        fallback.message : 'loadUrl failed';
      this.pendingRefreshTicket = 0;
      this.refreshInFlight = false;
      hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', message);
      this.errorText = '刷新失败：' + message;
      this.failed = true;
      this.loading = false;
    }
  }

  /**
   * guard.js 的 DOM 特征兜底：网页阅读器已经渲染出来了。
   * 当前页能解析出章节 → 拉起原生阅读器；解析不出 → 只打回首页并记日志说明原因。
   * 命中时也要先回首页：网页若留在阅读页，退出原生阅读器后守卫会再次触发、把阅读器弹回来。
   *
   * 关键：地址必须**现读**。SPA 内部 push 不会触发 onPageEnd，`this.pageUrl` 仍停在上一页
   * （上一轮真机就是这么漏掉的——守卫拿详情页地址去解析，自然解不出章节）。
   */
  private async handleReaderDetected(): Promise<void> {
    const now = Date.now();
    const live = this.currentWebUrl();
    const ids = parseChapterIds(live);
    handoffLog('守卫触发 现读地址=' + live + ' 缓存地址=' + this.pageUrl + ' 前台=' + this.active);
    // 网页页不在前台（阅读器已盖在上面）：只读地址、不接管。
    // 上一轮真机就是这里把同一章又开了一次——spaPoll 已开阅读器，守卫随后补一刀。
    if (!this.active) {
      handoffLog('守卫跳过：网页页不在前台 url=' + live);
      return;
    }
    if (now < this.readerRecoveryQuietUntil) {
      return;
    }
    this.readerRecoveryQuietUntil = now + 3000;
    if (ids === null) {
      handoffLog('守卫兜底：现读地址解不出章节，仅回首页 url=' + live);
      this.returnToWebHome();
      return;
    }
    handoffLog('守卫章节消息转交统一入口 url=' + live);
    this.handleChapterPick(live, 'guard', '');
  }

  /** 现读网页地址：优先 controller.getUrl()，拿不到时退回缓存的 pageUrl。 */
  private currentWebUrl(): string {
    let live = '';
    try {
      live = this.controller.getUrl();
    } catch (error) {
      live = '';
    }
    if (live.length === 0 || live === 'about:blank') {
      return this.pageUrl;
    }
    return live;
  }

  /** 网页阅读器残留页 → 打回首页。加载前归一化，防裸域名进 loadUrl。 */
  private returnToWebHome(): void {
    const target = normalizeLoadTarget(UrlManager.activeUrl + '/h5/index', 'returnToWebHome');
    this.pageUrl = target;
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    try {
      this.controller.loadUrl(target);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '返回网页首页失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private async injectScripts(): Promise<void> {
    if (this.gmScript.length === 0 || this.interfaceScript.length === 0 || this.guardScript.length === 0) {
      return;
    }
    try {
      await this.controller.runJavaScript(this.gmScript);
      await this.controller.runJavaScript(this.interfaceScript);
      // i.js 的首次 hideFab 针对旧版上下文下载按钮；根模式仍需保留设置逃生入口。
      if (!this.showBack) {
        this.fabVisible = true;
      }
      await this.controller.runJavaScript(this.guardScript);
      // 预置站点的"线路已初始化"标记，掐掉 /init?from= 回跳（详见 INIT_GATE_SCRIPT 注释）
      await this.controller.runJavaScript(INIT_GATE_SCRIPT);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        '页面脚本注入失败：' + value.message : '页面脚本注入失败';
      this.failed = true;
    }
  }

  private handleBack(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return;
      }
    } catch (error) {
    }
    this.onExit();
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row()
          .width('100%')
          .height(64)

        Stack({ alignContent: Alignment.Top }) {
        Web({ src: '', controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onlineImageAccess(true)
          // JS 弹窗自动确认（默认会弹系统对话框，方向相反）：alert/confirm 直接确认，prompt 回空输入。
          // 依据本机 SDK `ets/component/web.d.ts` 的 WebAttribute：
          //   onAlert(callback: Callback<OnAlertEvent, boolean>)
          //   onConfirm(callback: Callback<OnConfirmEvent, boolean>)
          //   onPrompt(callback: Callback<OnPromptEvent, boolean>)
          // 返回 true = 应用接管弹窗，需用 JsResult 回执（handleConfirm / handlePromptConfirm）。
          .onAlert((event: OnAlertEvent): boolean => {
            event.result.handleConfirm();
            return true;
          })
          .onConfirm((event: OnConfirmEvent): boolean => {
            event.result.handleConfirm();
            return true;
          })
          .onPrompt((event: OnPromptEvent): boolean => {
            event.result.handlePromptConfirm('');
            return true;
          })
          .onControllerAttached(() => {
            this.onControllerAttached();
          })
          .onConsole((event: OnConsoleEvent) => {
            if (COLLECTOR_LOG_ENABLED) {
              hilog.info(0x0000, 'WebShell', 'H5: %{public}s', event.message.getMessage());
            }
            return false;
          })
          .onPageBegin((_event: OnPageBeginEvent) => {
            this.loading = true;
            this.failed = false;
            this.errorText = '';
            if (this.refreshInFlight) {
              this.pendingRefreshTicket = 0;
              if (COLLECTOR_LOG_ENABLED) {
                hilog.info(0x0000, 'WebShell', 'refresh result: ok, page begin');
              }
            }
          })
          .onProgressChange((event: OnProgressChangeEvent) => {
            this.progress = event.newProgress;
            this.loading = event.newProgress < 100;
          })
          .onTitleReceive((event: OnTitleReceiveEvent) => {
            if (event.title.trim().length > 0) {
              this.title = event.title;
            }
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            const requestUrl = event.data.getRequestUrl();
            if (event.data.isMainFrame() && requestUrl.indexOf('/comicContent/') >= 0) {
              // 兜底拦截：JS 守卫万一没吃住这次导航，这里仍然拦住网页阅读器并交给原生阅读器
              handoffLog('onLoadIntercept 命中章节 url=' + requestUrl);
              this.handleChapterPick(requestUrl, 'loadIntercept', '');
              return true;
            }
            return false;
          })
          .onPageEnd((event: OnPageEndEvent) => {
            this.loading = false;
            if (this.refreshInFlight) {
              this.pendingRefreshTicket = 0;
              this.refreshInFlight = false;
              if (COLLECTOR_LOG_ENABLED) {
                hilog.info(0x0000, 'WebShell', 'refresh result: ok, page end');
              }
            }
            if (!this.showBack) {
              this.fabVisible = true;
            }
            if (event.url.length > 0 && event.url !== 'about:blank' && !this.failed) {
              this.pageUrl = event.url;
              const returnContext = this.returnContext;
              if (returnContext !== null && event.url.replace(/\/+$/, '') ===
                returnContext.comicDetails.replace(/\/+$/, '')) {
                this.returnContext = null;
                this.pendingRestore = false;
              }
              // 与轮询共用同一份"已知地址"，避免把刚加载完的这一页又当成新跳转
              this.spaLastUrl = event.url;
              // 记住非章节浏览位：接管后要退回来（章节页不算，退回去会再次触发守卫）
              if (parseChapterIds(event.url) === null) {
                this.lastBrowseUrl = event.url;
              }
              this.injectScripts();
            }
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              this.loading = false;
              this.failed = true;
              this.errorText = event.error.getErrorInfo();
              if (this.refreshInFlight) {
                this.pendingRefreshTicket = 0;
                this.refreshInFlight = false;
                hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', this.errorText);
              }
            }
          })
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              this.loading = false;
              this.failed = true;
              this.errorText = '网页请求失败（HTTP ' + event.response.getResponseCode() + '）';
              if (this.refreshInFlight) {
                this.pendingRefreshTicket = 0;
                this.refreshInFlight = false;
                hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', this.errorText);
              }
            }
          })
          .width('100%')
          .height('100%')

        if (this.loading) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color($r('app.color.primary'))
            .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        }

        if (this.failed) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(34)
              .fontColor([$r('app.color.accent')])
            Text('网页加载失败')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
            Text(this.errorText)
              .fontSize(12)
              .lineHeight(18)
              .fontColor($r('app.color.secondary_text'))
              .textAlign(TextAlign.Center)
              .maxLines(3)
            Button('重新加载')
              .type(ButtonType.Normal)
              .height(40)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor($r('app.color.primary'))
              .borderRadius(13)
              .onClick(() => this.loadPreparedUrl())
          }
          .justifyContent(FlexAlign.Center)
          .width('calc(100% - 32vp)')
          .padding(22)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(22)
          .margin({ top: 80 })
          .shadow({ radius: 12, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 4 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .zIndex(0)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
      .zIndex(0)

      WebHeader({
        showBack: this.showBack,
        title: this.title,
        pageUrl: this.pageUrl,
        loading: this.loading,
        refreshEnabled: this.controllerAttached,
        onBack: (): void => this.handleBack(),
        onRefresh: (): void => this.refreshPage()
      })

      if (!this.showBack && this.fabVisible && this.fabReady) {
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_down_circle'))
            .fontSize(23)
            .fontColor([$r('app.color.primary')])
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .width(48)
        .height(48)
        .backgroundColor(navBarBackground(themeState().isDark, themeState().amoledActive,
          themeState().themeRevision))
        .backgroundBlurStyle(navBlurStyle(themeState().isDark))
        .borderRadius(24)
        .shadow({ radius: 14, color: $r('app.color.nav_shadow'), offsetX: 0, offsetY: 5 })
        .position({ x: this.fabX, y: this.fabY })
        .zIndex(8)
        .scale({ x: this.fabPressed ? 0.95 : 1, y: this.fabPressed ? 0.95 : 1 })
        .animation({ duration: 100, curve: Curve.EaseOut })
        .accessibilityText('我的下载：点击打开，长按打开设置，可拖动')
        .onTouch((event: TouchEvent) => {
          this.handleFabTouch(event);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = newArea.width as number;
      const height = newArea.height as number;
      if (width > 0 && height > 0) {
        this.viewportWidth = width;
        this.viewportHeight = height;
        this.placeFabWithinBounds();
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
