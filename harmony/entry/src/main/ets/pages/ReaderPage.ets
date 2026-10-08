import { COLLECTOR_LOG_ENABLED } from '../services/Log';
/**
 * 原生阅读器：横向翻页 + 渐进加载 + 断点续读。
 * 图片数据统一遵守「章节图源」设置：API 一次给全；网页收图边收边读。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { matrix4 } from '@kit.ArkUI';
import { KeyCode, KeyEvent as InputKeyEvent, inputConsumer } from '@kit.InputKit';
import { statistics } from '@kit.NetworkKit';
import { netStatus } from './NetStatus';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  KEY_CHAPTER_END_COMMENTS,
  KEY_HIDE_STATUS_BAR,
  KEY_READ_DIRECTION,
  KEY_READ_MODE,
  KEY_SHOW_PAGE_NUM,
  KEY_VOL_TURN,
  settingsStore
} from '../services/SettingsStore';
import { Comment } from '../model/Models';
import { BrowseLoadState, describeBrowseError, getBrowseSource } from './BrowseSupport';
import {
  hiddenCollector,
  KEY_READER_PREFETCH_COUNT,
  loadChapterImages,
  loadLocalChapterImages,
  logCollectorBatch,
  READER_PREFETCH_OPTIONS,
  readerPrefetchCount,
  reportChapterViewOnce
} from './HiddenCollector';
import { themeBackground, themeState } from './ThemeColors';

export enum ReaderLoadState {
  Loading = 0,
  Content = 1,
  Empty = 2,
  Error = 3
}

/** 阅读模式：h = 横向翻页，v = 纵向翻页，w = 条漫连续滚动。 */
const READ_MODE_H: string = 'h';
const READ_MODE_V: string = 'v';
const READ_MODE_W: string = 'w';

/** 条漫未知宽高比时的兜底高度倍数（宽 × 1.4）。 */
const WEBTOON_FALLBACK_ASPECT: number = 1.4;

/** 缩放：与 Flutter 版 ZoomableReaderImage 对齐的上下限。 */
const ZOOM_MIN_SCALE: number = 1.0;
const ZOOM_MAX_SCALE: number = 4.0;
/** 轻点容差（vp）：超过就当成滑动，不触发点击分区。 */
const TAP_SLOP_VP: number = 18;
/** 双击时间窗（ms）：对齐 Flutter kReaderDoubleTapTimeout。 */
const DOUBLE_TAP_WINDOW_MS: number = 280;
/** 双击两次落点的位移上限（vp）＝ 2 × 轻点容差，对齐 Flutter 的 slop * 2。 */
const DOUBLE_TAP_SLOP_VP: number = TAP_SLOP_VP * 2;
/** 双击目标倍率：对齐 Flutter kReaderDoubleTapScale。 */
const DOUBLE_TAP_SCALE: number = 2.0;
/**
 * 双击放大过渡（ms）：接进全局动效体系的 280ms 档 + Friction 手感（与页面转场同一档）。
 * 复位走更短的 220ms，沿用顶栏「呼出讲究、收起干脆」的节奏。
 */
const ZOOM_ANIMATE_IN_MS: number = 280;
const ZOOM_ANIMATE_OUT_MS: number = 220;
/** 过渡的点帧间隔（ms）：约 60fps；ArkTS 没有 requestAnimationFrame，用定时器点帧。 */
const ZOOM_ANIMATE_TICK_MS: number = 16;
/** 缩放过渡曲线控制点：Curve.Friction 的 cubic-bezier 近似（与 Index 页转场注释同一口径）。 */
const ZOOM_EASE_X1: number = 0.2;
const ZOOM_EASE_Y1: number = 0;
const ZOOM_EASE_X2: number = 0.2;
const ZOOM_EASE_Y2: number = 1;
/** 平移诊断限流：每 N 个 move 事件，或累计位移超过 M vp 才打一次。 */
const PAN_DIAG_EVENT_INTERVAL: number = 12;
const PAN_DIAG_DISTANCE_VP: number = 240;

/** 判定「已放大」的阈值，留一点余量避免 1.0 附近抖动。 */
const ZOOMED_THRESHOLD: number = 1.05;
/** 条漫断点恢复重试上限：item 高度要等宽高比撑开，多给几次机会。 */
const WEBTOON_RESTORE_MAX_ATTEMPTS: number = 6;

const PAGE_PROGRESS_PREFIX: string = 'page_';
/** 到头后二次动作确认窗口，与 Flutter ChapterEdgeFsm 保持一致。 */
const CHAPTER_EDGE_CONFIRM_MS: number = 2500;
/**
 * 到头确认阈值（原先是固定 48vp，现换成 Flutter EdgeSwipeGeometry 同一套几何口径）：
 * 主轴位移 ≥ 视口主轴 × 此比例 **或** 平均速度 ≥ CHAPTER_EDGE_MIN_VELOCITY（两者 OR）。
 */
const CHAPTER_EDGE_MIN_DISTANCE_FRACTION: number = 0.12;
/** 到头确认的平均速度下限（vp/s），与位移条件 OR：短而快或长而慢都算数。 */
const CHAPTER_EDGE_MIN_VELOCITY: number = 480;
/** 斜滑过滤：交叉轴位移 > 主轴 × 此倍数 → 这一划作废（对齐 kChapterEdgeMaxCrossAxisRatio）。 */
const CHAPTER_EDGE_MAX_CROSS_RATIO: number = 0.85;
/** overscroll 辅助证据的最小绝对值（vp）：只作附加证据，不是唯一入口。 */
const CHAPTER_EDGE_AUX_OVERSCROLL_VP: number = 6;
/** 主轴起步门槛（vp）：比它还小直接当成没滑（对齐 Flutter resolve 里的 primary < 0.5）。 */
const CHAPTER_EDGE_MIN_PRIMARY_VP: number = 0.5;
/** 80% 预取只把下一章前几张放进图片缓存，避免和当前章争抢太多解码内存。 */
const NEXT_CHAPTER_PREWARM_COUNT: number = 3;
/** 80% 预取触发比例：与 Flutter `_page >= _count * 4 / 5` 等价。 */
const CHAPTER_PREFETCH_RATIO: number = 0.8;
/** 章末吐槽虚拟页在数据源里的固定 key（不参与换扩展名重试/手动重载逻辑）。 */
const COMMENT_ITEM_KEY: string = '__chapter_comment__';
/**
 * 分页 Swiper 的缓存窗口，直接喂给 `.cachedCount()`。
 * preloadItems 官方硬要求「预载下标必须落在 cachedCount 缓存范围内」（LazyForEach 范围外的节点会被销毁），
 * 预载与缓存共用这一个常量，改一处两边同时对齐。官方推荐一屏一页的连续滑动场景取 1 或 2。
 */
const SWIPER_CACHED_COUNT: number = 2;
/** preloadItems 单批下标个数：官方说明「调用后会一次性加载所有指定子节点」，分批才能把构建摊到空闲帧。 */
const PRELOAD_BATCH_SIZE: number = 1;

// （P2）右上角时间胶囊的刷新节奏：域名/网速/时间都从这里出（「更多信息」行已并入胶囊后删除）。
/** 时间胶囊刷新间隔（ms）：分钟级时间足够新鲜，也给吞吐估算留出几秒采样窗口。 */
const CAPSULE_REFRESH_MS: number = 4000;
/**
 * 顶栏块高度兜底（vp）＝ 返回按钮 44 + 上下 padding 12×2 = 68。
 * 只是"还没量到"时的初值：真实高度由顶栏 Column 的 onAreaChange 覆盖，避免点击守卫写死魔数。
 */
const TOOLBAR_BLOCK_FALLBACK_VP: number = 68;
/** 跳页输入框的组件 id：打开对话框时用 focusControl.requestFocus 拉起键盘。 */
const JUMP_INPUT_ID: string = 'jumpPageInput';
/** 跳页浮层上屏后的**延时聚焦**兜底（ms）：等挂载 + 焦点链重建完成再请求一次。 */
const JUMP_FOCUS_RETRY_MS: number = 120;
/**
 * 音量键去重窗口（ms）：inputConsumer 与 onKeyEvent 可能对同一次物理按压各回调一次，
 * 80ms 内的第二次直接丢弃，保证「按一下只翻一页」。
 */
const VOLUME_DEDUP_MS: number = 80;

/**
 * 系统返回拦截（壳层 Index.onBackPress 调用）：仅当阅读器停在"章末吐槽页"时消费返回事件，
 * 先退回本章最后一张图；其余情况返回 false，由壳层执行正常的退出阅读器。
 * 对齐 Flutter：章末吐槽是阅读器内部的一页，返回不该把整个阅读器一起退掉。
 */
let readerCommentBackHandler: (() => boolean) | null = null;
export function setReaderCommentBackHandler(handler: (() => boolean) | null): void {
  readerCommentBackHandler = handler;
}
export function handleReaderSystemBack(): boolean {
  const handler = readerCommentBackHandler;
  if (handler === null) {
    return false;
  }
  return handler();
}

/**
 * 阅读器原地切章所需的最小章节信息。
 * chapterSequence 必须按阅读顺序排列：index - 1 是上一章，index + 1 是下一章。
 */
export class ReaderChapterRef {
  readonly id: string;
  readonly name: string;
  readonly size: number;

  constructor(id: string, name: string, size: number) {
    this.id = id;
    this.name = name;
    this.size = size;
  }
}

/** 预载门：只等「目标页 N、N+1、N+2」解码完成；超时/失败都要放人。 */
const GATE_TIMEOUT_MS: number = 9000;
/** 预载页报错后的宽限时长：短暂等待后放行进内容态。 */
const GATE_ERROR_GRACE_MS: number = 800;

/** 取证日志：URL 截断到 160 字符。 */
function truncateUrl(url: string): string {
  return url.length > 160 ? url.substring(0, 160) + '…' : url;
}

/** 信息栏用的短速率标签：1234567 → `1.2MB/s`。 */
function formatBytesPerSecond(bytesPerSecond: number): string {
  if (bytesPerSecond >= 1048576) {
    return (bytesPerSecond / 1048576).toFixed(1) + 'MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return (bytesPerSecond / 1024).toFixed(0) + 'KB/s';
  }
  return Math.round(bytesPerSecond).toString() + 'B/s';
}

/** 三次贝塞尔的标量求值：B(t) = 3·(1−t)²·t·p1 + 3·(1−t)·t²·p2 + t³。 */
function bezierCoord(p1: number, p2: number, t: number): number {
  const inv = 1 - t;
  return 3 * inv * inv * t * p1 + 3 * inv * t * t * p2 + t * t * t;
}

/**
 * 给定控制点 (x1,y1)/(x2,y2)，把线性进度 x 换算成曲线进度 y。
 * 用二分法解 Bx(t) = x：控制点横坐标都在 [0,1] 时 Bx 单调，16 次二分足够精确，
 * 也不用担心导数为 0 时牛顿迭代跑飞。缩放过渡每帧都走这里，开销可忽略。
 */
function bezierEase(x1: number, y1: number, x2: number, y2: number, x: number): number {
  if (x <= 0) {
    return 0;
  }
  if (x >= 1) {
    return 1;
  }
  let low = 0;
  let high = 1;
  for (let i = 0; i < 16; i++) {
    const mid = (low + high) / 2;
    if (bezierCoord(x1, x2, mid) < x) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return bezierCoord(y1, y2, (low + high) / 2);
}

/** 缩放过渡的统一缓动（见 ZOOM_EASE_* 常量）。 */
function zoomEase(linear: number): number {
  return bezierEase(ZOOM_EASE_X1, ZOOM_EASE_Y1, ZOOM_EASE_X2, ZOOM_EASE_Y2, linear);
}

@ComponentV2
struct ReaderStatePanel {
  @Param state: ReaderLoadState = ReaderLoadState.Loading;
  @Param errorText: string = '';
  @Event onRetry: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      if (this.state === ReaderLoadState.Loading) {
        LoadingProgress()
          .width(42)
          .height(42)
          .color($r('app.color.primary'))
        Text('正在准备图片…')
          .fontSize(15)
          .fontColor($r('app.color.secondary_text'))
      } else if (this.state === ReaderLoadState.Error) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(38)
          .fontColor([$r('app.color.accent')])
        Text('图片加载失败')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.errorText)
          .fontSize(13)
          .lineHeight(19)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
        Button('重试')
          .type(ButtonType.Normal)
          .height(42)
          .padding({ left: 26, right: 26 })
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .borderRadius(14)
          .onClick(() => this.onRetry())
      } else {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(38)
          .fontColor([$r('app.color.secondary_text')])
        Text('这一章没有可显示的图片')
          .fontSize(16)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(24)
    // 不透明底色：等待期间盖住下面的预载层（预载层保持与正式显示同尺寸，避免解码尺寸被改变）
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
  }
}

/** 章末吐槽页里的单条评论卡片：样式与 CommentPanel 的 CommentRow 同源（同一套色板/圆角/字号）。 */
@ComponentV2
struct ReaderCommentRow {
  @Param item: Comment = new Comment('', '', '', '');

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(this.item.user.length > 0 ? this.item.user.substring(0, 1) : '匿')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.primary'))
          .borderRadius(16)
        Column({ space: 2 }) {
          Text(this.item.user.length > 0 ? this.item.user : '匿名用户')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.item.createdAt.length > 0) {
            Text(this.item.createdAt)
              .fontSize(10)
              .fontColor($r('app.color.secondary_text'))
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Text(this.item.content.length > 0 ? this.item.content : '（无内容）')
        .fontSize(14)
        .lineHeight(21)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(16)
  }
}

@ComponentV2
export struct ReaderPage {
  @Param comicId: string = '';
  @Param chapterId: string = '';
  @Param chapterName: string = '';
  @Param chapterSize: number = 0;
  /**
   * 外壳提供的完整章节序列，按「上一章 → 下一章」的阅读顺序排列。
   * 空数组保持旧调用兼容，但没有相邻章可切，也不会触发 80% 预取。
   */
  @Param chapterSequence: ReaderChapterRef[] = [];
  /** 离线模式：只用本地已下载图片，任何情况下都不走网络图源。 */
  @Param offlineOnly: boolean = false;
  @Local offlineOnlyLocal: boolean = false;
  @Event onExit: () => void = () => {};
  @Event onRetry: () => void = () => {};

  @Local loadState: ReaderLoadState = ReaderLoadState.Loading;
  /** @Param 是入口快照；原地切章后由这组三个本地值驱动标题、请求与进度 key。 */
  @Local activeChapterId: string = '';
  @Local activeChapterName: string = '';
  @Local activeChapterSize: number = 0;
  @Local errorText: string = '';
  @Local urls: string[] = [];
  @Local currentIndex: number = 0;
  /**
   * 最后一张"图片页"的位置（不含章末吐槽页）：仅在被 readingIndex() 回退时使用。
   * "读到哪"只有一个来源——readingIndex()；进度保存/吐槽页返回/切章落盘全部从它取。
   */
  private lastImageIndex: number = 0;
  /** 章末吐槽虚拟页及其独立加载状态。 */
  @Local chapterEndCommentsEnabled: boolean = false;
  @Local commentState: BrowseLoadState = BrowseLoadState.Idle;
  /** 章末吐槽页内容淡入的透明度（1=常态；落地时先压到 0 再动画回 1）。 */
  @Local commentPageOpacity: number = 1;
  @Local comments: Comment[] = [];
  @Local commentErrorText: string = '';
  /**
   * 吐槽被跳过的原因（如「无网络，不加载吐槽」）；空串＝未跳过。
   * 由加载入口按网络可达性写入，UI 占位只读它，不在 build 里做异步网络判断。
   */
  @Local commentsSkipReason: string = '';
  /** API 下一章预热图；以极低透明度全尺寸挂载，确保真正发起取图/解码。 */
  @Local prewarmUrls: string[] = [];
  /** 切章期间去重，避免第二个边界动作发起并行加载。 */
  @Local switchingChapter: boolean = false;
  /** 顶栏可见性：三模式统一，默认隐藏（对齐 Flutter _barsVisible 初值 false）。 */
  @Local toolbarVisible: boolean = false;
  /** 首次进入时的浮出提示文案；为空表示不显示。 */
  @Local introHint: string = '';
  /** 常显页码胶囊：点击弹跳页输入。 */
  @Local jumpVisible: boolean = false;
  @Local jumpText: string = '';
  @Local collecting: boolean = false;
  @Local collectionNote: string = '';
  /** 阅读模式：与设置项 KEY_READ_MODE 同源；默认横向，取到设置后覆盖。 */
  @Local readMode: string = READ_MODE_H;
  /** 条漫内容宽度（vp）：item 占位高度 = 宽度 / 宽高比。 */
  @Local contentWidth: number = 0;

  // ---- P2 开关组（阅读器内直读 key，不改 SettingsStore / 设置页）----
  /** 页码角标：控制右下角常显胶囊；顶栏里的页码不受它影响。默认开（保持现状）。 */
  @Local showPageNumEnabled: boolean = true;
  /**
   * 阅读方向（KEY_READ_DIRECTION）：true = 左开本（默认），false = 右开本。
   * 左开本时横向 Swiper 走 `.direction(Direction.Rtl)`：划左→右 = 下一页、翻页动画镜像；
   * 点击分区也随之对调。纵向/条漫不读它（恒为纵向语义）。
   */
  @Local readLeftMode: boolean = true;
  /** 音量键翻页：默认关。 */
  @Local volTurnEnabled: boolean = false;
  /**
   * 「隐藏状态栏」（KEY_HIDE_STATUS_BAR，默认 false）：只有系统状态栏被藏起来时，
   * 右上角时间胶囊才有存在的意义（否则和系统时钟重复）。阅读器只读这个 key，
   * 真正调系统 API 的是壳层 Index。
   */
  @Local hideStatusBarEnabled: boolean = false;
  /**
   * 右上角时间胶囊文案（**两行**）：第一行 `HH:MM [网络类型]`，第二行 `[图源域名] · [全机↓速率]`。
   * 各段「可取则取、取不到省略」，只有时就是单行；域名与网速原属已删除的「更多信息」行，现并入胶囊。
   * 空串不渲染。
   */
  @Local capsuleText: string = '';

  /** 时间胶囊刷新定时器；「隐藏状态栏」开着时存在。 */
  private capsuleTimer: number = -1;
  /** 胶囊刷新防重入：上一拍还没算完就不叠下一拍。 */
  private capsuleBusy: boolean = false;
  /** 顶栏块实测高度（vp）：由顶栏 Column 的 onAreaChange 记录，点击守卫用它判「点在顶栏内」。 */
  private toolbarBlockHeight: number = TOOLBAR_BLOCK_FALLBACK_VP;
  /** 右下页码胶囊实测矩形（组件坐标系）：由胶囊 Text 的 onAreaChange 记录；胶囊未渲染时为 null。 */
  private pageCapsuleRect: ReaderRect | null = null;
  /** 跳页浮层的延时聚焦定时器：浮层关闭/页面销毁时撤掉，避免对已卸载的输入框发请求。 */
  private jumpFocusTimer: number = -1;
  /**
   * 吞吐采样（statistics.getAllRxBytes）取不到时的停用闩。
   * ⚠️ 与网络状态探测无关：那只影响「全机↓速率」这一段省略（网络类型已交给独立模块 NetStatus）。
   */
  private netStatsUnavailable: boolean = false;
  /** 上一次全机下行字节数与时刻，用于算差分速率；-1 表示还没采过样。 */
  private rxLastBytes: number = -1;
  private rxLastAt: number = 0;
  /** inputConsumer 注册态：注册期间系统音量调节会被一并拦截（见回报）。 */
  private volUpRegistered: boolean = false;
  private volDownRegistered: boolean = false;
  /** 去重与按压沿判定：同一次按压只翻一页（按住不放不连翻）。 */
  private lastVolumeEventAt: number = 0;
  private volUpHeld: boolean = false;
  private volDownHeld: boolean = false;

  @Local zoomScale: number = 1.0;
  @Local zoomOffsetX: number = 0;
  @Local zoomOffsetY: number = 0;
  /** 捏合进行中：双指按下即置位，锁死翻页（横向/纵向）+ 条漫滚动。 */
  @Local pinching: boolean = false;
  /** 手势期间的边界快照：避免每帧重算内容尺寸（见 clampOffset）。 */
  private boundsSnapshot: ReaderRect = { left: 0, top: 0, width: 0, height: 0 };
  private boundsValid: boolean = false;
  /** 平移诊断限流计数器。 */
  private panEventCount: number = 0;
  private panAccumulated: number = 0;
  /** 触发 transform 重算的计数器：改了 scale/offset 后自增。 */
  @Local zoomRevision: number = 0;
  /**
   * 缩放过渡（双击放大 / 复位）由 JS 自己逐帧驱动（ArkTS 没有 requestAnimationFrame，
   * 用 16ms 定时器点帧即可）：`.transform(matrix)` 的矩阵值不参与属性动画插值，
   * 改走 scale+translate 又要动整条渲染链路（捏合、边界都挂在它上面），风险更大。
   * 自己当动画器的好处是「状态量 = 画面真实值」——捏合随时从当前帧接手，不会被半路的动画拽回去。
   * gen 每次开新动画或被手势/翻页取消时自增，旧帧回调据此作废。
   */
  private zoomAnimGen: number = 0;
  private zoomAnimTimer: number = -1;
  /** 兜底定时器：到点直接落终值，绝不把画面卡在半路。 */
  private zoomAnimGuard: number = -1;
  /** 视口尺寸（vp），用于限制平移边界。 */
  @Local viewportWidth: number = 0;
  @Local viewportHeight: number = 0;

  /** 两指起始距离与中点，捏合期间不变。 */
  private pinchStartDistance: number = 0;
  private pinchStartFocalX: number = 0;
  private pinchStartFocalY: number = 0;
  private pinchStartScale: number = 1;
  private pinchStartOffsetX: number = 0;
  private pinchStartOffsetY: number = 0;
  /** 单指平移起点（放大后拖动画面）。 */
  private panLastX: number = 0;
  private panLastY: number = 0;
  private panPointerId: number = -1;
  /** 轻点判定：按下点与手指 id。 */
  private tapDownX: number = 0;
  private tapDownY: number = 0;
  private tapPointerId: number = -1;
  private tapMoved: boolean = false;
  /**
   * 双击判定：上一次轻点的时间与落点（doubleTapAt = 0 表示窗口已关）。
   * 单击动作刻意**延后**到窗口结束才执行，窗口内出现第二击就由双击接管 ——
   * 这样连击绝不会被吃成翻页/切栏（对齐 Flutter zoomable_reader_image 的 Future.delayed）。
   */
  private doubleTapAt: number = 0;
  private doubleTapX: number = 0;
  private doubleTapY: number = 0;
  /** 单击延迟执行定时器（见 handleTapCandidate）。 */
  private singleTapTimer: number = -1;
  /**
   * 容器（分页 Swiper / 条漫盒子）在**窗口坐标系**里的原点：条漫的轻点判定挂在 ListItem 上，
   * 它的 x/y 是 item 局部坐标（随滚动漂移），减掉原点才能换算回视口坐标去比中央矩形。
   */
  private viewportWindowX: number = 0;
  private viewportWindowY: number = 0;
  /** 条漫专用轻点状态：见 onWebtoonItemTouch 注释。 */
  private webtoonTapId: number = -1;
  private webtoonTapX: number = 0;
  private webtoonTapY: number = 0;
  private webtoonTapMoved: boolean = false;
  /** 本次轻点是否已由条漫 item 层处理：容器层据此避免重复处理（一次点击切换两次会让顶栏切不掉）。 */
  private webtoonTapConsumed: boolean = false;
  /** 条漫首次进入的浮出提示：只做一次。 */
  /** 首次进入的浮出提示：只做一次；三模式共用。 */
  private introDone: boolean = false;
  private introTimer: number = -1;
  /** 切进条漫后的定位重试计时器（item 高度未就绪时 Scroller 会静默 no-op）。 */
  private webtoonRestoreTimer: number = -1;

  /** 异步装载代数：切章后旧章的 API / 收图 / 评论回调全部静默丢弃。 */
  private chapterGeneration: number = 0;
  private commentRevision: number = 0;
  private commentFadeTimer: number = -1;
  /** 从下一章向前切时，Flutter 语义是落在新章末张图片，而不是吐槽页。 */
  private enterChapterAtEnd: boolean = false;
  private currentChapterLocal: boolean = false;
  /** 到头二次确认状态。direction: -1 上一章，0 未武装，1 下一章。 */
  private edgeDirection: number = 0;
  private edgeArmedAt: number = 0;
  /** 本次手势的按下时刻：到头确认的平均速度 = 主轴位移 ÷ (now - edgeDownAt)。 */
  private edgeDownAt: number = 0;
  /** 武装提示的自动解除定时器。 */
  private edgeTimer: number = -1;
  /** 80% 预取每章只发起一次。 */
  private prefetchRequested: boolean = false;
  /** 当前章节图源设置（webview / api）。收图源不参与预取，避免提前启动隐藏收图。 */
  private chapterSourceIsWeb: boolean = false;
  /** 每个 touch session 只消费一次越界动作。 */
  private edgeGestureConsumed: boolean = false;
  private edgeTouchStartX: number = 0;
  private edgeTouchStartY: number = 0;
  private edgeGestureStartIndex: number = 0;
  /** 条漫/吐槽内部列表是否真正位于物理边缘。 */
  private webtoonAtStart: boolean = true;
  private webtoonAtEnd: boolean = false;
  private commentListAtEnd: boolean = true;
  private commentScroller: ListScroller = new ListScroller();
  /** 章节 URL 预取任务与结果；同一章只请求一次，切入时直接复用。 */
  private chapterPrefetches: Map<string, Promise<string[]>> = new Map<string, Promise<string[]>>();
  private prefetchedChapterUrls: Map<string, string[]> = new Map<string, string[]>();

  /** 条漫宽高比（width / height）缓存：按 URL 记，回收后重建仍能用，避免高度塌陷回跳。 */
  private aspectRatios: Map<string, number> = new Map<string, number>();
  /** 图片原始宽高缓存（横/纵 Contain 矩形计算用）。 */
  private imageSizes: Map<string, ReaderSize> = new Map<string, ReaderSize>();
  /** 改了 aspectRatios 后自增，让条漫 item 重新取高度。 */
  @Local aspectRevision: number = 0;
  private swiperController: SwiperController = new SwiperController();
  private listScroller: ListScroller = new ListScroller();
  private dataSource: ReaderPageSource = new ReaderPageSource([]);
  private prefetchTarget: number = 20;
  private restoreTarget: number = 0;
  private restorePending: boolean = false;
  private restoreAttempts: number = 0;
  /**
   * 条漫断点恢复窗口内，用户是否已经自己滑过（只要手指滑出轻点容差就置位）。
   * 置位后再有 onScrollIndex 报「不在目标页」就放弃拉回 —— 断点不该把正在读的人拽走。
   */
  private webtoonUserScrolled: boolean = false;
  private readerReady: boolean = false;
  private usingWebCollector: boolean = false;
  /**
   * 本次 loadImages 的 URL 列表是否已是"页数终态"（本地/API/预取缓存：页数不会再变）。
   * 网页收图路径为 false（边收边长，页数未定），据此决定预载门是否可以对短章按实际页数放行。
   */
  private urlsFinal: boolean = false;
  private firstContentLogged: boolean = false;
  /** 换扩展名重试后的 URL（.webp ↔ .jpg），按页下标保存。 */
  private fallbackUrls: Map<number, string> = new Map<number, string>();
  private retriedPages: Set<number> = new Set<number>();
  /** 已解码完成的页下标（0-based），供预载门判定。 */
  private loadedPages: Set<number> = new Set<number>();
  /** 触发重新渲染：改了 fallbackUrls 后自增，让 LazyForEach 里的 Image 换 src 重载。 */
  @Local retryRevision: number = 0;
  /**
   * 手动重载：页下标 → 该页第几次手动重载。
   * 既用于判断是否显示"点击重载"，也作为绕开失败缓存的变化量。
   */
  @Local manualRetries: Map<number, number> = new Map<number, number>();
  /** 已确认失败的页下标：换扩展名自动重试也失败后才置位。 */
  @Local failedPages: Set<number> = new Set<number>();
  /** 正在手动重载中的页下标：给进行中反馈。 */
  @Local reloadingPages: Set<number> = new Set<number>();
  /** 手动重载计数变化后自增，确保 UI 重新取 manualRetries / failedPages。 */
  @Local manualRetryRevision: number = 0;
  private gateArmed: boolean = false;
  private gateTimer: number = -1;
  private gateErrorTimer: number = -1;
  /** 门态 Swiper 的定位页：必须等于目标页 N，否则它只会解码 0~2 页，断点续读永远等不到 N/N+1/N+2。 */
  @Local gateIndex: number = 0;
  /**
   * 邻页预载代次（纯私有，不驱动 UI）：新一轮预载开始时自增，
   * 上一条链在下一批之前看到代次不对就自己停手，快速连翻时不会多条链叠着加载。
   */
  private preloadGeneration: number = 0;
  /** preloadItems 只在**第一次**失败时打一条日志，之后静默，避免每翻一页刷屏。 */
  private preloadFailedLogged: boolean = false;

  aboutToAppear(): void {
    this.offlineOnlyLocal = this.offlineOnly;
    this.activeChapterId = this.chapterId;
    this.activeChapterName = this.chapterName;
    this.activeChapterSize = this.chapterSize;
    // 系统返回：吐槽页优先消费（退回最后一张图），其余交给壳层正常退出阅读器
    setReaderCommentBackHandler((): boolean => this.leaveCommentPage());
    this.loadImages(false);
  }

  aboutToDisappear(): void {
    // 系统返回拦截器随页面销毁解绑
    setReaderCommentBackHandler(null);
    // 待判定的轻点回调随页面销毁撤掉，不对已卸载的组件发状态
    this.clearPendingTap();
    // 缩放过渡同理：撤掉 vsync 回调与兜底定时器，别对已卸载页面写 zoom 状态
    this.stopZoomAnimation();
    // 先让旧回调失效，再取消收图；cancel 会同步回调 onError，不能污染已退出页面。
    this.chapterGeneration++;
    this.commentRevision++;
    this.saveProgressFor(this.activeChapterId, this.readingIndex(), this.urls.length, this.collecting);
    // 退出阅读器：停止收图与轮询，避免隐藏 Web 继续耗时
    if (this.usingWebCollector) {
      hiddenCollector.cancel();
    }
    if (this.introTimer >= 0) {
      clearTimeout(this.introTimer);
      this.introTimer = -1;
    }
    if (this.webtoonRestoreTimer >= 0) {
      clearTimeout(this.webtoonRestoreTimer);
      this.webtoonRestoreTimer = -1;
    }
    if (this.edgeTimer >= 0) {
      clearTimeout(this.edgeTimer);
      this.edgeTimer = -1;
    }
    if (this.commentFadeTimer >= 0) {
      clearTimeout(this.commentFadeTimer);
      this.commentFadeTimer = -1;
    }
    if (this.capsuleTimer >= 0) {
      clearInterval(this.capsuleTimer);
      this.capsuleTimer = -1;
    }
    if (this.jumpFocusTimer >= 0) {
      clearTimeout(this.jumpFocusTimer);
      this.jumpFocusTimer = -1;
    }
    // 退出阅读器必须把音量键还给系统，否则音量调节一直被拦着
    this.unregisterVolumeKeys();
    this.clearGate();
  }

  private progressKey(chapterId: string = this.activeChapterId): string {
    return PAGE_PROGRESS_PREFIX + chapterId;
  }

  private showCommentPage(): boolean {
    return this.chapterEndCommentsEnabled && this.activeChapterId.length > 0 &&
      this.loadState === ReaderLoadState.Content;
  }

  private readerPageCount(): number {
    return this.urls.length + (this.showCommentPage() ? 1 : 0);
  }

  private onCommentPage(): boolean {
    return this.showCommentPage() && this.currentIndex >= this.urls.length;
  }

  /**
   * 唯一的"阅读位置"读口（章末吐槽页不算阅读位置）：进度保存、吐槽页返回、切章落盘都从这里取，
   * 保证"当前读到哪"只有一个来源。currentIndex 可以指向吐槽页；lastImageIndex 记录最后一张图片页。
   */
  private readingIndex(): number {
    const last = this.urls.length - 1;
    if (last < 0) {
      return 0;
    }
    if (this.currentIndex >= 0 && this.currentIndex < this.urls.length) {
      return this.currentIndex;
    }
    return this.lastImageIndex >= 0 && this.lastImageIndex <= last ? this.lastImageIndex : last;
  }

  private activeSequenceIndex(): number {
    for (let i = 0; i < this.chapterSequence.length; i++) {
      if (this.chapterSequence[i].id === this.activeChapterId) {
        return i;
      }
    }
    return -1;
  }

  private adjacentChapter(goNext: boolean): ReaderChapterRef | null {
    const index = this.activeSequenceIndex();
    if (index < 0) {
      return null;
    }
    const adjacent = index + (goNext ? 1 : -1);
    if (adjacent < 0 || adjacent >= this.chapterSequence.length) {
      return null;
    }
    return this.chapterSequence[adjacent];
  }

  /**
   * 丢掉还在双击窗里等判定的单击（切章 / 切模式 / 退出都要走）：
   * 窗口过期后才回调的分区动作会打到新内容上，索性整体作废。
   */
  private clearPendingTap(): void {
    if (this.singleTapTimer >= 0) {
      clearTimeout(this.singleTapTimer);
      this.singleTapTimer = -1;
    }
    this.doubleTapAt = 0;
  }

  /** 解除"到头二次确认"武装（切章/换模式/换页/窗口超时都要走这里，定时器一并撤掉）。 */
  private resetEdgeGuard(): void {
    this.edgeDirection = 0;
    this.edgeArmedAt = 0;
    this.edgeGestureConsumed = false;
    if (this.edgeTimer >= 0) {
      clearTimeout(this.edgeTimer);
      this.edgeTimer = -1;
    }
  }

  /** 阅读模式只认 h/v/w，其它值（含旧数据）退回横向。 */
  private validReadMode(value: string): string {
    if (value === READ_MODE_V || value === READ_MODE_W) {
      return value;
    }
    return READ_MODE_H;
  }

  /** 阅读方向只认 left / right，其它值（含旧数据缺失）退回默认的左开本。 */
  private validReadDirection(value: string): string {
    return value === 'right' ? 'right' : 'left';
  }

  private isWebtoon(): boolean {
    return this.readMode === READ_MODE_W;
  }

  /** 模式标签，供工具栏按钮显示。 */
  private modeLabel(): string {
    if (this.readMode === READ_MODE_V) {
      return '纵向';
    }
    if (this.readMode === READ_MODE_W) {
      return '条漫';
    }
    return '横向';
  }

  /**
   * 阅读器内快速切模式：横向 → 纵向 → 条漫 → 横向。
   * 保持阅读位置（切完回到原下标），并写回 KEY_READ_MODE，让设置页看到的是同一个值。
   */
  private cycleReadMode(): void {
    const keep = this.currentIndex;
    const next = this.readMode === READ_MODE_H ?
      READ_MODE_V : this.readMode === READ_MODE_V ? READ_MODE_W : READ_MODE_H;
    this.applyReadMode(next, keep);
  }

  private applyReadMode(next: string, keepIndex: number): void {
    const wasWebtoon = this.isWebtoon();
    this.readMode = this.validReadMode(next);
    this.resetEdgeGuard();
    // 切模式不带放大态进新容器
    this.resetZoom();
    // 换容器＝新一轮断点恢复：用户在旧容器里的滑动不再算"已经读起来了"
    this.clearPendingTap();
    this.webtoonUserScrolled = false;
    // 条漫进出都要重跑一次定位：Swiper 与 List 是两套滚动容器
    this.restoreTarget = keepIndex < 0 ? 0 : keepIndex;
    this.currentIndex = this.restoreTarget;
    this.restorePending = true;
    this.restoreAttempts = 0;
    if (this.currentIndex !== this.restoreTarget) {
      this.currentIndex = this.restoreTarget;
    }
    settingsStore.putString(KEY_READ_MODE, this.readMode).then(() => {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '阅读模式切换：' + this.modeLabel());
      }
    }).catch((error: Error) => {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '阅读模式持久化失败 ' + error.message);
      }
    });
    if (wasWebtoon !== this.isWebtoon()) {
      this.aspectRatios.clear();
    }
    // 切进条漫：补一轮定时定位重试（Scroller 首帧可能静默 no-op）
    if (this.isWebtoon() && !wasWebtoon) {
      this.armWebtoonRestore();
    }
  }

  private async loadImages(enterAtEnd: boolean = this.enterChapterAtEnd): Promise<void> {
    const generation = ++this.chapterGeneration;
    const chapterId = this.activeChapterId;
    this.enterChapterAtEnd = enterAtEnd;

    // 原地切章/重试前先结束旧章隐藏收图；旧回调会因 generation 不匹配而被丢弃。
    if (this.usingWebCollector) {
      hiddenCollector.cancel();
    }
    this.loadState = ReaderLoadState.Loading;
    this.errorText = '';
    this.urls = [];
    this.dataSource = new ReaderPageSource([]);
    this.currentIndex = 0;
    this.collecting = false;
    this.collectionNote = '';
    this.restorePending = false;
    this.restoreAttempts = 0;
    this.readerReady = false;
    this.currentChapterLocal = false;
    // 每次取图重置为"未终态"：随后按本次实际路径（本地/API/预取 vs 网页收图）赋值
    this.urlsFinal = false;
    this.prewarmUrls = [];
    this.webtoonAtStart = true;
    this.webtoonAtEnd = false;
    this.commentListAtEnd = true;
    this.resetEdgeGuard();
    this.resetZoom();
    // 切章：旧章待判定的轻点、以及"用户已滑过"标记都作废
    this.clearPendingTap();
    this.webtoonUserScrolled = false;
    this.clearGate();
    this.commentRevision++;
    this.commentState = BrowseLoadState.Idle;
    this.comments = [];
    this.commentErrorText = '';
    this.commentsSkipReason = '';
    // 每次重新取图：清掉上一轮的解码记录与换扩展名重试记录
    this.loadedPages.clear();
    this.fallbackUrls.clear();
    this.retriedPages.clear();
    this.retryRevision++;
    // 手动重载状态同样清空：换章/重试后不该残留"加载失败"提示
    this.manualRetries.clear();
    this.failedPages.clear();
    this.reloadingPages.clear();
    this.manualRetryRevision++;
    this.firstContentLogged = false;
    // 换章后重新武装：80% 预取按新章重新判定
    this.prefetchRequested = false;

    this.prefetchTarget = await readerPrefetchCount();
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    const saved = await settingsStore.getInt(this.progressKey(chapterId), 0);
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    this.restoreTarget = enterAtEnd ? Math.max(0, this.activeChapterSize - 1) : saved;
    this.readMode = await this.validReadMode(await settingsStore.readMode());
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    // 章末吐槽开关：按要求在阅读器内直读设置 key（KEY_CHAPTER_END_COMMENTS），不改 SettingsStore
    this.chapterEndCommentsEnabled = await settingsStore.getBool(KEY_CHAPTER_END_COMMENTS, true);
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    // P2 开关组：页码角标 / 阅读方向 / 音量键翻页 / 隐藏状态栏（时间胶囊的前提），同源直读 key。
    // 默认值与设置页读取处保持一致（showPageNum=true、readDirection='left'、volTurn=false、hideStatusBar=false）。
    const p2Flags = await Promise.all([
      settingsStore.getBool(KEY_SHOW_PAGE_NUM, true),
      settingsStore.getString(KEY_READ_DIRECTION, 'left'),
      settingsStore.getBool(KEY_VOL_TURN, false),
      settingsStore.getBool(KEY_HIDE_STATUS_BAR, false)
    ]);
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    this.showPageNumEnabled = p2Flags[0] as boolean;
    // 阅读方向：'left' = 左开本（默认）。读完即可生效——Swiper 的 .direction 直接绑在这个布尔上。
    this.readLeftMode = this.validReadDirection(p2Flags[1] as string) === 'left';
    this.volTurnEnabled = p2Flags[2] as boolean;
    this.hideStatusBarEnabled = p2Flags[3] as boolean;
    // 两个“活着”的开关要立即生效：音量键注册/注销、时间胶囊计时器开/关
    this.applyVolumeKeyInterest();
    this.syncCapsuleTimer();
    const source = await settingsStore.chapterSource();
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    this.usingWebCollector = source === 'webview';
    // 图源设置是全局的：本地章节也会记住它，供 80% 预取判断"能不能直接请求下一章 URL 列表"
    this.chapterSourceIsWeb = source === 'webview';

    // 离线优先：已完整下载的章节直接用本地图，不发任何网络请求
    const local = await loadLocalChapterImages(this.comicId, chapterId);
    if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
      return;
    }
    if (local.length > 0) {
      if (this.offlineOnlyLocal) {
        // 离线模式：只用本地图，不补报历史（保证飞行模式零请求）
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s', '云端观看历史：离线模式跳过 ' + chapterId);
        }
      } else {
        // 离线/本地分支也要补报云端观看历史（否则离线读章不会进历史）
        reportChapterViewOnce(this.comicId, chapterId);
      }
      this.usingWebCollector = false;
      this.currentChapterLocal = true;
      this.urls = local;
      this.dataSource = new ReaderPageSource(local);
      this.restoreTarget = enterAtEnd ? local.length - 1 : this.clampRestore(this.restoreTarget, local.length);
      this.currentIndex = this.restoreTarget;
      this.restorePending = this.restoreTarget > 0;
      // 本地图：页数已终态，短章（< 预取门限）也要能放行
      this.urlsFinal = true;
      // 离线也要过同一道预载门：本地图同样要等 N/N+1/N+2 解码完成
      this.maybeEnterContent();
      return;
    }

    if (this.usingWebCollector) {
      // 离线模式：本地没有完整章节时不允许走网络图源（保证飞行模式零请求）
      if (this.offlineOnlyLocal) {
        this.loadState = ReaderLoadState.Error;
        this.errorText = '本地没有这一章的完整图片，无法离线阅读';
        this.switchingChapter = false;
        return;
      }
      // 网页路径也要进云端观看历史：异步补一次带 token 的章节内容请求，不阻塞首屏
      reportChapterViewOnce(this.comicId, chapterId);
      // 收图中：页数未定，预载门保持"等收满"语义，不加短章放行
      this.urlsFinal = false;
      this.startWebCollector(generation, chapterId);
      return;
    }

    if (this.offlineOnlyLocal) {
      this.loadState = ReaderLoadState.Error;
      this.errorText = '本地没有这一章的完整图片，无法离线阅读';
      this.switchingChapter = false;
      return;
    }

    try {
      let images: string[] = [];
      const cached = this.prefetchedChapterUrls.get(chapterId);
      if (cached !== undefined) {
        images = cached;
      } else {
        const pending = this.chapterPrefetches.get(chapterId);
        images = pending !== undefined ? await pending : await loadChapterImages(this.comicId, chapterId);
      }
      if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
        return;
      }
      this.urls = images;
      this.dataSource = new ReaderPageSource(images);
      if (images.length === 0) {
        this.loadState = ReaderLoadState.Empty;
        this.switchingChapter = false;
        return;
      }
      this.restoreTarget = enterAtEnd ? images.length - 1 : this.clampRestore(this.restoreTarget, images.length);
      this.currentIndex = this.restoreTarget;
      this.restorePending = this.restoreTarget > 0;
      // API / 预取缓存：URL 一次给全，页数已终态，短章（< 预取门限）也要能放行
      this.urlsFinal = true;
      // API 图源：URL 一次给全，但同样要等首屏三页解码完成才进
      this.maybeEnterContent();
    } catch (error) {
      if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
        return;
      }
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '图片加载失败';
      this.loadState = ReaderLoadState.Error;
      this.switchingChapter = false;
    }
  }

  private async startWebCollector(generation: number, chapterId: string): Promise<void> {
    this.collecting = true;
    this.loadState = ReaderLoadState.Loading;
    try {
      await hiddenCollector.loadStream(this.comicId, chapterId, {
        onBatch: (batch: string[]): void => {
          if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
            return;
          }
          this.appendUrls(batch);
        },
        onDone: (total: number): void => {
          if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
            return;
          }
          this.collecting = false;
          // 收图跑到终点：即使不足 N 张也要放行（短章节/提前收尾），否则会一直停在加载态
          this.enterContent();
          if (this.urls.length === 0) {
            this.loadState = ReaderLoadState.Empty;
            this.switchingChapter = false;
          } else {
            this.collectionNote = this.sizeMismatchNote(this.urls.length);
          }
        },
        onError: (message: string): void => {
          if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
            return;
          }
          this.collecting = false;
          if (this.urls.length === 0) {
            this.errorText = message;
            this.loadState = ReaderLoadState.Error;
            this.switchingChapter = false;
          } else {
            // 已收到的页保留可用（含超时/取消），只在底部给轻量提示
            this.enterContent();
            this.collectionNote = message + '，已加载页面仍可阅读';
          }
        }
      }, this.urls.length);
    } catch (error) {
      if (generation !== this.chapterGeneration || chapterId !== this.activeChapterId) {
        return;
      }
      this.collecting = false;
      const value = error as Error;
      if (this.urls.length === 0) {
        this.errorText = value.message !== undefined && value.message.length > 0 ?
          value.message : '图片加载失败';
        this.loadState = ReaderLoadState.Error;
        this.switchingChapter = false;
      }
    }
  }

  private appendUrls(batch: string[]): void {
    if (batch.length === 0) {
      return;
    }
    // 取证：每次有新项，打印已收数量与新增项的前 3 个 URL
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(
      0x0000,
      'Collector',
      '%{public}s',
      '已收 ' + (this.urls.length + batch.length) + ' 新增' + batch.length
    );
    }
    logCollectorBatch(batch);
    for (let i = 0; i < batch.length; i++) {
      this.urls.push(batch[i]);
      // 逐项 notifyDataAdd：避免整列表重建导致跳回第一页
      this.dataSource.append(this.urls[this.urls.length - 1], this.urls.length - 1);
    }
    // 进内容态的门槛：≥N 张；若断点续读目标更靠后，则等到目标页已收到再进（其余情况由 onDone/onError 放行），
    // 再叠加「N/N+1/N+2 已解码」的预载门
    this.maybeEnterContent();
  }

  private clearGate(): void {
    if (this.gateTimer >= 0) {
      clearTimeout(this.gateTimer);
      this.gateTimer = -1;
    }
    if (this.gateErrorTimer >= 0) {
      clearTimeout(this.gateErrorTimer);
      this.gateErrorTimer = -1;
    }
    this.gateArmed = false;
  }

  /** 进入内容态（幂等）：收图不足整章也放行；恢复目标越界时由 clampRestore 兜底到第 0 页。 */
  private enterContent(): void {
    if (this.loadState === ReaderLoadState.Content || this.urls.length === 0) {
      return;
    }
    this.restoreTarget = this.clampRestore(this.restoreTarget, this.urls.length);
    this.currentIndex = this.restoreTarget;
    this.restorePending = this.restoreTarget > 0;
    this.loadState = ReaderLoadState.Content;
    // 进内容态后才有"章末吐槽页"：把虚拟页追加到数据源（横/纵多一页 Swiper，条漫多一个末尾 item）
    this.dataSource.setTail(this.showCommentPage());
    this.collectionNote = '';
    this.clearGate();
    this.switchingChapter = false;
    this.logFirstPages();
    this.maybePrefetchNext();
  }

  /**
   * 80% 预取下一章（P8c）。
   *
   * 规则（对齐 Flutter `_maybePrefetch`）：
   *  - 每章只发起一次（prefetchRequested 在 loadImages 里复位）；
   *  - 没有相邻下一章、或还没读到约 80% 就直接返回；
   *  - **网页收图源不预取**：`loadChapterImages` 对 webview 源会直接驱动隐藏收图，
   *    提前调用等于把隐藏 WebView 在用户还没到下一章时就拉起来；
   *  - 离线模式不预取（保证飞行模式零请求）。
   * 成功后把 URL 列表塞进 `prefetchedChapterUrls`（切章时 `loadImages` 直接命中，
   * 不再发请求），并把前 NEXT_CHAPTER_PREWARM_COUNT 张以极低透明度挂载预热解码。
   */
  private maybePrefetchNext(): void {
    if (this.prefetchRequested) {
      return;
    }
    if (this.loadState !== ReaderLoadState.Content || this.urls.length === 0) {
      return;
    }
    const next = this.adjacentChapter(true);
    if (next === null) {
      return;
    }
    const total = this.urls.length;
    const position = this.currentIndex + 1;
    if (position < total * CHAPTER_PREFETCH_RATIO) {
      return;
    }
    this.prefetchRequested = true;
    if (this.offlineOnlyLocal) {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '80% 预取跳过（离线模式） 下一章=' + next.id);
      }
      return;
    }
    if (this.chapterSourceIsWeb) {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '80% 预取跳过（网页收图源不提前启动隐藏收图） 下一章=' + next.id);
      }
      return;
    }
    const generation = this.chapterGeneration;
    const target = next;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '80% 预取触发 位置=' + position + '/' + total + ' 下一章=' + target.id + ' ' + target.name);
    }
    let task = this.chapterPrefetches.get(target.id);
    if (task === undefined) {
      task = loadChapterImages(this.comicId, target.id);
      this.chapterPrefetches.set(target.id, task);
      const request = task;
      request.then((images: string[]): void => {
        this.prefetchedChapterUrls.set(target.id, images);
      }).catch((_error: Object): void => {
        // 失败就丢掉缓存的任务，切章时按正常路径重试
        this.chapterPrefetches.delete(target.id);
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '80% 预取失败 下一章=' + target.id);
        }
      });
    }
    task.then((images: string[]): void => {
      if (generation !== this.chapterGeneration) {
        // 已经切走（或退出阅读器）：不再挂预热层，避免旧章图占着解码内存
        return;
      }
      const warm: string[] = [];
      const count = Math.min(NEXT_CHAPTER_PREWARM_COUNT, images.length);
      for (let i = 0; i < count; i++) {
        warm.push(images[i]);
      }
      this.prewarmUrls = warm;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '80% 预取完成 下一章=' + target.id + ' 共' + images.length + '张 预热' + warm.length + '张');
      }
    }).catch((_error: Object): void => {
    });
  }

  /**
   * 邻页预载（`SwiperController.preloadItems`，API 18+）：把 center ± [1..SWIPER_CACHED_COUNT]
   * **分批**交给框架提前构建/布局，减少真正翻到那页时的节点构建耗时（丢帧主要就发生在 cachedCount 窗口内）。
   *
   * 官方口径（ts-container-swiper → preloadItems，本地 SDK swiper.d.ts @since 18）：
   *  - 调用后会**一次性**加载所有传入下标 → 这里一批 PRELOAD_BATCH_SIZE 个、逐批 await，不一把梭；
   *  - 下标必须落在 cachedCount 缓存范围内，缓存范围外的节点 LazyForEach 会销毁，故上界用数据源实际条数裁；
   *  - 必须在 Swiper 创建之后调用，**首次预载放 onAppear**；
   *  - @throws 401 参数非法（含越界下标、空数组）、@throws 100004 控制器未绑定组件
   *    → 全程 try/catch，失败无害、绝不上抛，翻页照旧由 cachedCount 兜底。
   *
   * 只预载、不改状态：不写 currentIndex、不发 onData* 通知、不碰页内容，
   * 因此不违反「Swiper 结合 LazyForEach 时不能在 onChange 事件里触发子页面 UI 的刷新」。
   *
   * @param center 以哪一页为基准：onAppear/onAnimationEnd 用落位页，onAnimationStart 用目标页。
   */
  private async preloadNeighborPages(center: number): Promise<void> {
    const total = this.dataSource.totalCount();
    if (total <= 0 || center < 0 || center >= total) {
      return;
    }
    const generation = ++this.preloadGeneration;
    // 由近及远、前进方向优先（绝大多数翻页朝"下一页"），越界下标直接丢掉。
    // 章末吐槽虚拟页（下标 ≥ urls.length）**刻意不预载**：它有自己的懒加载口径
    // （commentPageBody.onAppear 才拉评论、"进入吐槽页时才拉取"），预载会把评论提前发出去 —— 该行为保持原样。
    const order: number[] = [];
    for (let offset = 1; offset <= SWIPER_CACHED_COUNT; offset++) {
      const next = center + offset;
      if (next < total && next < this.urls.length) {
        order.push(next);
      }
      const prev = center - offset;
      if (prev >= 0 && prev < this.urls.length) {
        order.push(prev);
      }
    }
    for (let start = 0; start < order.length; start += PRELOAD_BATCH_SIZE) {
      if (generation !== this.preloadGeneration) {
        // 已有新一轮预载接管：旧链自己停手
        return;
      }
      // 每批下发前**重算**上界：收图/切章会让数据源条数变，过期下标会被判 invalid index（401）
      const live = this.dataSource.totalCount();
      const batch = order.slice(start, start + PRELOAD_BATCH_SIZE)
        .filter((value: number): boolean => value < live);
      if (batch.length === 0) {
        continue;
      }
      try {
        await this.swiperController.preloadItems(batch);
      } catch (error) {
        if (!this.preloadFailedLogged) {
          this.preloadFailedLogged = true;
          const detail = error as BusinessError;
          if (COLLECTOR_LOG_ENABLED) {
            hilog.info(0x0000, 'Collector', '%{public}s',
            '邻页预载 preloadItems 失败（不影响翻页，cachedCount 仍兜底） code=' + detail.code +
            ' message=' + detail.message);
          }
        }
        return;
      }
    }
  }

  /**
   * 预载门：只有 N、N+1、N+2（存在即可）都解码完成才真正进内容态；否则继续停在加载态。
   * 网页收图路径下 N+1/N+2 可能还没被收集到，也算“没到位”，会继续等；等到收完自然满足。
   */
  private maybeEnterContent(): void {
    if (this.loadState === ReaderLoadState.Content || this.urls.length === 0) {
      return;
    }

    const wanted = Math.max(this.prefetchTarget, this.restoreTarget + 1);
    if (this.urls.length < wanted) {
      if (!this.urlsFinal) {
        // 收图中：N+1/N+2 可能还没收到，继续等（现状语义不变）
        return;
      }
      // 终态短章（本地/API/预取缓存）：页数不会再涨，门限夹到实际页数，否则永远满足不了
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '短章过门：共' + this.urls.length + '页 < 门限' + wanted + '，按现有页数开门');
      }
    }

    const target = this.clampRestore(this.restoreTarget, this.urls.length);
    const need: number[] = [];
    for (let offset = 0; offset < 3; offset++) {
      const index = target + offset;
      if (index < this.urls.length) {
        need.push(index);
      }
    }

    let ready = true;
    for (let i = 0; i < need.length; i++) {
      if (!this.loadedPages.has(need[i])) {
        ready = false;
        break;
      }
    }

    if (!ready) {
      // 门态 Swiper 要定位到目标页，保证 N/N+1/N+2 真的会被渲染并解码（否则断点续读必吃超时）
      if (this.gateIndex !== target) {
        this.gateIndex = target;
      }
      this.armGate();
      return;
    }

    this.enterContent();
  }

  /** 装载兜底：门一旦开启，最多等 GATE_TIMEOUT_MS 就必须放人，绝不死等。 */
  private armGate(): void {
    if (this.gateArmed) {
      return;
    }
    this.gateArmed = true;
    this.gateTimer = setTimeout(() => {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '预载门超时：放行进内容态');
      }
      this.collectionNote = '首屏仍在加载，已进入阅读，可稍等或重试';
      this.enterContent();
    }, GATE_TIMEOUT_MS);
  }

  /** 预载页报错：短暂宽限后放行，并在底部给轻提示。 */
  private noteGateError(index: number): void {
    if (this.loadState === ReaderLoadState.Content) {
      return;
    }
    this.armGate();
    if (this.gateErrorTimer >= 0) {
      return;
    }
    this.gateErrorTimer = setTimeout(() => {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '预载门：第' + (index + 1) + '页加载失败，宽限后放行');
      }
      this.collectionNote = '部分图片加载失败，已进入阅读，可重试或切换源站';
      this.enterContent();
    }, GATE_ERROR_GRACE_MS);
  }

  private clampRestore(saved: number, total: number): number {
    if (total <= 0 || saved <= 0) {
      return 0;
    }
    return saved < total ? saved : 0;
  }

  private sizeMismatchNote(actual: number): string {
    if (this.activeChapterSize <= 0 || actual === this.activeChapterSize) {
      return '';
    }
    return '本章实际收图 ' + actual + ' 页，与章节页数 ' + this.activeChapterSize + ' 不一致';
  }

  private async saveProgressFor(chapterId: string, index: number, total: number,
    stillCollecting: boolean): Promise<void> {
    if (chapterId.length === 0 || total <= 0) {
      return;
    }
    try {
      if (index >= total - 1 && !stillCollecting) {
        await settingsStore.remove(this.progressKey(chapterId));
      } else {
        await settingsStore.putInt(this.progressKey(chapterId), index);
      }
    } catch (error) {
    }
  }

  private async saveProgress(index: number): Promise<void> {
    // 同步捕获章 id/页数，避免 await 之后原地切章把进度写到新章。
    const chapterId = this.activeChapterId;
    const total = this.urls.length;
    const collecting = this.collecting;
    await this.saveProgressFor(chapterId, index, total, collecting);
  }

  private restoreProgressOnce(): void {
    if (!this.restorePending) {
      return;
    }
    if (this.urls.length === 0 || this.loadState !== ReaderLoadState.Content) {
      return;
    }
    if (this.isWebtoon()) {
      this.restoreAttempts++;
      if (this.listScrollToIndex(this.restoreTarget)) {
        this.currentIndex = this.restoreTarget;
      }
      // 条漫 item 高度要先靠宽高比撑起来才跳得准；前几次失败很正常，
      // 由 onAreaChange / onScrollIndex 继续重试，超过上限才放弃。
      if (this.restoreAttempts >= WEBTOON_RESTORE_MAX_ATTEMPTS) {
        this.restorePending = false;
      }
      return;
    }
    this.swiperController.changeIndex(this.restoreTarget, true);
    this.currentIndex = this.restoreTarget;
    this.restoreAttempts++;
    // 兜底：连续多次仍未生效就放弃恢复，避免卡在空白页
    if (this.restoreAttempts >= 3) {
      this.restorePending = false;
    }
  }

  /**
   * 切进条漫后补几次定位：item 高度要靠宽高比撑起来才跳得准，Scroller 首帧可能静默 no-op，
   * onScrollIndex 又会先报一次 0，所以用定时轮询直到确认到位或次数用尽。
   */
  private armWebtoonRestore(): void {
    if (this.webtoonRestoreTimer >= 0) {
      clearTimeout(this.webtoonRestoreTimer);
      this.webtoonRestoreTimer = -1;
    }
    let ticks = 0;
    const tick = (): void => {
      this.webtoonRestoreTimer = -1;
      if (!this.restorePending || !this.isWebtoon()) {
        return;
      }
      this.restoreProgressOnce();
      ticks++;
      if (this.restorePending && ticks < WEBTOON_RESTORE_MAX_ATTEMPTS) {
        this.webtoonRestoreTimer = setTimeout(tick, 180);
      }
    };
    this.webtoonRestoreTimer = setTimeout(tick, 120);
  }

  /** 条漫定位：优先走 Scroller；容器还没挂上时返回 false 交给调用方重试。 */
  private listScrollToIndex(index: number): boolean {
    let target = index;
    if (target < 0) {
      target = 0;
    }
    // 上限含章末吐槽虚拟页（readerPageCount = 图片数 + 吐槽页）
    const last = this.readerPageCount() - 1;
    if (target > last) {
      target = last;
    }
    if (target < 0) {
      return false;
    }
    try {
      this.listScroller.scrollToIndex(target, false, ScrollAlign.START);
      return true;
    } catch (error) {
      // 容器尚未绑定（首帧/切模式瞬间）：忽略，由 onAreaChange / onScrollIndex 重试
      return false;
    }
  }

  /** 读取当前应显示的 URL：优先用换扩展名重试后的地址；读 retryRevision 以建立刷新依赖。 */
  private currentUrl(index: number, url: string): string {
    if (this.retryRevision < 0) {
      return url;
    }
    const swapped = this.fallbackUrls.get(index);
    return swapped !== undefined && swapped.length > 0 ? swapped : url;
  }

  /**
   * 手动重载用的 URL：在 currentUrl 之上附加一个变化的查询参数来绕开失败缓存。
   *
   * 只改 src 字符串而不改节点时，ArkUI 很可能直接命中上一次的失败结果、
   * 连 onError 都不再回调，表现为"点了没反应"。这里同时做两件事：
   *   1. 给 URL 追加 `_r=N`（N 随点击次数递增），让每次重载都是新请求；
   *   2. 由调用方自增 manualRetryRevision 触发重建，LazyForEach 的 key 变化
   *      会真正重建该节点，而不是复用旧 Image。
   * 风险：第三方 CDN 对未知查询参数是否友好未验证；但重载本身是"已失败"的兜底
   * 路径，即使 CDN 拒绝该参数，最坏也只是继续失败并可再次点击。
   */
  private reloadUrl(index: number, url: string): string {
    if (this.manualRetryRevision < 0) {
      return url;
    }
    const base = this.currentUrl(index, url);
    const n = this.manualRetries.get(index);
    const count = n === undefined ? 0 : n;
    if (count <= 0) {
      return base;
    }
    return base + (base.indexOf('?') >= 0 ? '&' : '?') + '_r=' + count.toString();
  }

  private isPageFailed(index: number): boolean {
    return this.failedPages.has(index);
  }

  private isPageReloading(index: number): boolean {
    return this.reloadingPages.has(index);
  }

  /** 点击失败页 → 手动重载一次。失败仍可再次点击（计数递增，URL 变化）。 */
  private reloadPage(index: number): void {
    if (this.urls.length === 0 || index < 0 || index >= this.urls.length) {
      return;
    }
    if (this.isPageReloading(index)) {
      return;
    }
    const prev = this.manualRetries.get(index);
    const next = (prev === undefined ? 0 : prev) + 1;
    this.manualRetries.set(index, next);
    // 换扩展名重试的机会还给这一页：手动重载后若仍失败会重新置位 failedPages
    this.retriedPages.delete(index);
    this.fallbackUrls.delete(index);
    this.reloadingPages.add(index);
    this.failedPages.delete(index);
    // 同步进数据源：key 变了才会真正重建该 Image 节点，绕开失败缓存
    this.dataSource.setReloadCount(index, next);
    this.manualRetryRevision++;
    this.retryRevision++;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '手动重载 第' + (index + 1) + '页');
    }
    // 安全网：极端情况下收不到 onComplete/onError 也要撤掉进行中状态，允许再点
    setTimeout(() => {
      if (this.reloadingPages.has(index)) {
        this.reloadingPages.delete(index);
        this.manualRetryRevision++;
      }
    }, 15000);
  }

  /** 重载成功：清掉失败与进行中标记。 */
  private onReloadSucceeded(index: number): void {
    this.failedPages.delete(index);
    if (this.reloadingPages.has(index)) {
      this.reloadingPages.delete(index);
    }
    this.loadedPages.add(index);
    this.manualRetryRevision++;
  }

  /** 重载仍失败：恢复失败态，允许再次点击。 */
  private onReloadFailed(index: number): void {
    this.failedPages.add(index);
    if (this.reloadingPages.has(index)) {
      this.reloadingPages.delete(index);
    }
    this.manualRetryRevision++;
  }

  /** .webp ↔ .jpg（.jpeg → .webp）；无法互换时返回空串。 */
  private swapImageExtension(url: string): string {
    const q = url.indexOf('?');
    const base = q >= 0 ? url.substring(0, q) : url;
    const lower = base.toLowerCase();
    let swappedBase = '';
    if (lower.endsWith('.webp')) {
      swappedBase = base.substring(0, base.length - 5) + '.jpg';
    } else if (lower.endsWith('.jpg')) {
      swappedBase = base.substring(0, base.length - 4) + '.webp';
    } else if (lower.endsWith('.jpeg')) {
      swappedBase = base.substring(0, base.length - 5) + '.webp';
    } else {
      return '';
    }
    return swappedBase + (q >= 0 ? url.substring(q) : '');
  }

  /** 图片 onError 的一次性补救：换成另一扩展名再试；已试过或无法互换则返回 false。 */
  private retryWithSwappedExtension(index: number, url: string): boolean {
    if (this.retriedPages.has(index)) {
      return false;
    }
    const swapped = this.swapImageExtension(url);
    if (swapped.length === 0) {
      return false;
    }
    this.retriedPages.add(index);
    this.fallbackUrls.set(index, swapped);
    this.retryRevision++;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(
      0x0000,
      'Collector',
      '%{public}s',
      '换扩展名重试 第' + (index + 1) + '页 → ' + truncateUrl(swapped)
    );
    }
    return true;
  }

  /** 取证：阅读器首次进入内容态时打印它持有的前两张 URL（对照收图顺序）。 */
  private logFirstPages(): void {
    if (this.firstContentLogged) {
      return;
    }
    this.firstContentLogged = true;
    const head: string[] = [];
    const count = Math.min(2, this.urls.length);
    for (let i = 0; i < count; i++) {
      head.push(this.urls[i].length > 160 ? this.urls[i].substring(0, 160) + '…' : this.urls[i]);
    }
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(
      0x0000,
      'Collector',
      '%{public}s',
      '阅读器内容态 共' + this.urls.length + '张 前' + count + '=' + head.join(' | ')
    );
    }
  }

  /** 记录新学到的宽高比；只在首次学到或变化明显时触发重建（一帧内多张图只重建一次）。 */
  private learnAspect(url: string, width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    const ratio = width / height;
    const old = this.aspectRatios.get(url);
    if (old !== undefined && Math.abs(old - ratio) < 0.001) {
      return;
    }
    this.aspectRatios.set(url, ratio);
    this.aspectRevision++;
  }

  /**
   * 条漫 item 高度：已知宽高比时按「内容宽 / 比例」锁定；未知时给一个保守兜底。
   *
   * 不锁的话占位高度接近 0，item 被回收重建会先塌成零高再弹回真实高度，列表总高随之抖动，
   * 表现为「滑着滑着闪一下往回跳一段」。比例缓存在加载/回收/换扩展名重下期间都不清除。
   */
  private webtoonItemHeight(index: number, url: string): number {
    if (this.aspectRevision < 0) {
      return 0;
    }
    const ratio = this.aspectRatios.get(url);
    const width = this.contentWidth > 0 ? this.contentWidth : 360;
    if (ratio !== undefined && ratio > 0) {
      return width / ratio;
    }
    // 兜底：常见条漫单页比例约 1:1.4，先占住位置，学到真实比例后替换
    return width * WEBTOON_FALLBACK_ASPECT;
  }

  // ---- 双指缩放 / 放大平移 / 手势仲裁 ----

  /** 当前是否已放大：捏合中或已放大都算「锁翻页」。 */
  /**
   * 顶栏是否可见。
   *
   * 三模式统一为「默认隐藏 + 单击呼出/收起」，对齐 Flutter 基准
   * （_barsVisible 初值 false、点击才切换）。之前横/纵默认常显，
   * 条漫默认隐藏，两套行为不一致；现在统一由单一状态驱动。
   */
  private toolbarShown(): boolean {
    return this.toolbarVisible;
  }

  private toggleToolbar(): void {
    this.toolbarVisible = !this.toolbarVisible;
    // 切换时补一拍：收起顶栏时右上角胶囊别显示上一拍的旧时间/旧网速
    if (this.hideStatusBarEnabled) {
      this.refreshCapsule();
    }
    // 用户手动操作过就不再显示提示，也不再被自动收起打断
    this.clearIntroHint();
  }

  /**
   * 顶栏显隐过渡（自带动画，toggleToolbar 里不包 animateTo）。
   *
   * 出现＝淡入 + 从上方 8vp 滑入（translate y = -8 起步、回到 0），200ms Curve.Friction 减速；
   * 消失＝150ms Curve.EaseIn 加速淡出，比出现更短更利落，符合「呼出讲究、收起干脆」的节奏。
   */
  private toolbarTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: -8 }))
        .animation({ duration: 200, curve: Curve.Friction }),
      TransitionEffect.OPACITY
        .animation({ duration: 150, curve: Curve.EaseIn })
    );
  }

  /** 跳页浮层遮罩：200ms 淡入 / 150ms 淡出，只走 OPACITY，不缩放整屏。 */
  private jumpScrimTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .animation({ duration: 200, curve: Curve.Friction }),
      TransitionEffect.OPACITY
        .animation({ duration: 150, curve: Curve.EaseIn })
    );
  }

  /**
   * 跳页面板：出现＝0.95 轻缩放 + 淡入，200ms Curve.Friction；
   * 退出＝缩回 0.95 并淡出，150ms Curve.EaseIn。
   * 与遮罩分开挂 transition，面板自己的缩放不会连带把遮罩也推歪。
   */
  private jumpPanelTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
        .animation({ duration: 200, curve: Curve.Friction }),
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
        .animation({ duration: 150, curve: Curve.EaseIn })
    );
  }

  /** 清掉「点屏幕可再次呼出」提示并撤掉自动收起的定时器。 */
  private clearIntroHint(): void {
    if (this.introTimer >= 0) {
      clearTimeout(this.introTimer);
      this.introTimer = -1;
    }
    if (this.introHint.length > 0) {
      this.introHint = '';
    }
  }

  /**
   * 条漫专用轻点识别。
   *
   * 不复用 onReaderTouch 的 tapPointerId 路径：List 是滚动容器，单指按下后
   * 一旦被判成滚动手势（哪怕只是轻微滑动），后续 Up 事件会被判给滚动，
   * 组件层拿到的 touches 已为空或 pointerId 对不上，tapPointerId 提前被清掉，
   * 于是轻点永远不触发 —— 表现为"点不出来"。
   *
   * 这里直接在 ListItem 上做独立判定：记下按下点与 pointerId，抬起时位移在容差内即触发；
   * 命中后与分页共用 handleTapCandidate（双击窗 + 分区守卫），只差一步坐标换算 ——
   * item 的 x/y 随滚动漂移，先用 window 坐标减掉容器原点换回视口坐标。
   */
  private onWebtoonItemTouch(event: TouchEvent, _index: number): void {
    const changed = event.changedTouches;
    if (event.type === TouchType.Down) {
      if (changed.length === 0) {
        return;
      }
      this.webtoonTapId = changed[0].id;
      this.webtoonTapX = changed[0].x;
      this.webtoonTapY = changed[0].y;
      this.webtoonTapMoved = false;
      this.webtoonTapConsumed = false;
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.webtoonTapId < 0 || changed.length === 0 || changed[0].id !== this.webtoonTapId) {
        return;
      }
      const dx = changed[0].x - this.webtoonTapX;
      const dy = changed[0].y - this.webtoonTapY;
      if (Math.abs(dx) > TAP_SLOP_VP || Math.abs(dy) > TAP_SLOP_VP) {
        if (!this.webtoonTapMoved) {
          this.webtoonTapMoved = true;
          // 用户主动滑起来了：断点恢复不再往回拽（见 onScrollIndex 的 restorePending 分支）
          this.webtoonUserScrolled = true;
        }
      }
      return;
    }
    if (event.type === TouchType.Up) {
      if (this.webtoonTapId < 0 || changed.length === 0 || changed[0].id !== this.webtoonTapId) {
        return;
      }
      const moved = this.webtoonTapMoved;
      this.webtoonTapId = -1;
      this.webtoonTapMoved = false;
      if (moved) {
        return;
      }
      // 本次轻点由 item 层处理完毕：标记给容器层，避免同一次点击被处理两遍（否则顶栏切换两次=切不掉）
      this.webtoonTapConsumed = true;
      this.handleTapCandidate(this.viewportX(changed[0]), this.viewportY(changed[0]));
      return;
    }
    if (event.type === TouchType.Cancel) {
      this.webtoonTapId = -1;
      this.webtoonTapMoved = false;
    }
  }

  /** 当前是否已放大：捏合中或已放大都算「锁翻页」。 */
  private zoomLocked(): boolean {
    return this.pinching || this.zoomScale > ZOOMED_THRESHOLD;
  }

  /**
   * 落点是否在右下页码胶囊里（跳页双修之一：点胶囊只弹跳页，不顺带翻页）。
   *
   * 矩形**不写魔数**：胶囊 Text 的 onAreaChange 把实测 position/size 记进 pageCapsuleRect，
   * 这里直接命中判定。胶囊没渲染（页码开关关掉 / 非内容态）就恒不命中，行为与旧版一致。
   * 落点走的是 window 坐标减容器原点（不受 .transform 影响），而胶囊本身也不在被变换的那棵树里，
   * 所以放大态下命中同样准确；最坏也只是复位与弹跳页同时发生。
   */
  private hitPageCapsule(x: number, y: number): boolean {
    if (!this.showPageNumEnabled || this.loadState !== ReaderLoadState.Content ||
      this.urls.length === 0) {
      return false;
    }
    const rect = this.pageCapsuleRect;
    if (rect === null || rect.width <= 0 || rect.height <= 0) {
      return false;
    }
    return x >= rect.left && x <= rect.left + rect.width &&
      y >= rect.top && y <= rect.top + rect.height;
  }

  /** 轻点落点 → 视口坐标：优先 window 坐标减容器原点（不受 .transform 影响），拿不到才退回组件坐标。 */
  private viewportX(t: TouchObject): number {
    return this.touchX(t) - this.viewportWindowX;
  }

  private viewportY(t: TouchObject): number {
    return this.touchY(t) - this.viewportWindowY;
  }

  /**
   * 轻点入口（分页与条漫共用）：先开双击窗，再决定是「双击」还是「等窗口过期后的单击」。
   *
   * 单击**延后 280ms** 才执行（对齐 Flutter zoomable_reader_image 的 Future.delayed(kDoubleTapTimeout)）：
   * 窗口内出现第二击 → 取消待执行的单击、直接走双击；于是连击绝不会被吃成翻页/切栏。
   */
  private handleTapCandidate(x: number, y: number): void {
    const now = Date.now();
    if (this.doubleTapAt > 0 && now - this.doubleTapAt <= DOUBLE_TAP_WINDOW_MS) {
      const dx = x - this.doubleTapX;
      const dy = y - this.doubleTapY;
      if (Math.sqrt(dx * dx + dy * dy) <= DOUBLE_TAP_SLOP_VP) {
        // 双击成立：两次轻点的单击动作都丢掉（第一个的定时器在这里被撤掉）
        this.clearPendingTap();
        this.handleDoubleTap(x, y);
        return;
      }
    }
    const scheduledAt = now;
    const scheduledX = x;
    const scheduledY = y;
    this.doubleTapAt = now;
    this.doubleTapX = x;
    this.doubleTapY = y;
    if (this.singleTapTimer >= 0) {
      clearTimeout(this.singleTapTimer);
      this.singleTapTimer = -1;
    }
    this.singleTapTimer = setTimeout((): void => {
      this.singleTapTimer = -1;
      if (this.doubleTapAt !== scheduledAt) {
        // 已被双击（或新的轻点）接管：这次单击不再执行
        return;
      }
      this.doubleTapAt = 0;
      this.handleReaderTap(scheduledX, scheduledY);
    }, DOUBLE_TAP_WINDOW_MS);
  }

  /**
   * 双击：未放大 → 以双击点为锚放大到 2.0x；已放大 → 复位（对齐 Flutter onDoubleTap）。
   * 落点守卫与单击同口径（跳页浮层 / 顶栏块内 / 页码胶囊），所以双击不会顺带翻页或点穿控件。
   *
   * 顶栏展开时**不再**把双击吃成「只收栏」：放大是画面操作，收栏是单击的活，两者互不抢。
   * 双击期间顶栏维持原样（既不收也不放）——否则放大到一半顶栏跟着动，看着像画面跳了一下；
   * 想收栏随时点一下（单击「第一点收栏」那条路径原样保留）。
   */
  private handleDoubleTap(x: number, y: number): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '双击判定 x=' + x.toFixed(0) + ' y=' + y.toFixed(0) +
      ' zoom=' + this.zoomScale.toFixed(2) + ' mode=' + this.modeLabel() +
      ' toolbar=' + (this.toolbarShown() ? '开' : '关'));
    }
    if (this.jumpVisible) {
      return;
    }
    if (this.toolbarShown() && y <= this.toolbarBlockHeight) {
      return;
    }
    if (this.hitPageCapsule(x, y)) {
      return;
    }
    if (this.isPageFailed(this.currentIndex)) {
      this.reloadPage(this.currentIndex);
      return;
    }
    if (this.zoomScale > ZOOMED_THRESHOLD) {
      this.animateZoomTo(ZOOM_MIN_SCALE, 0, 0, ZOOM_ANIMATE_OUT_MS, '双击复位');
      return;
    }
    this.doubleTapZoomAt(x, y);
  }

  /**
   * 以双击点为锚放大到 2.0x：让手指下那个内容点缩放后仍停在原处。
   *
   * 渲染模型见 zoomTransform：它给矩阵补上 (s−1)·a 之后，屏幕上实际是 p = offset + s·u
   * （u 是内容坐标，offset 就是本函数写进 zoomOffset 的值）。把 u = (x, y)、p = (x, y) 代入，
   * 解得 offset = (1−s)·(x, y) —— 这就是锚点式；s = 2 时它天然落在
   * 「不露空白」区间 [视口 − s·视口, 0] 内，因此只留一道越界兜底。
   */
  private doubleTapZoomAt(x: number, y: number): void {
    const s = DOUBLE_TAP_SCALE;
    const vw = this.viewportWidth > 0 ? this.viewportWidth : 1;
    const vh = this.viewportHeight > 0 ? this.viewportHeight : 1;
    let offsetX = (1 - s) * x;
    let offsetY = (1 - s) * y;
    // 不露空白兜底：内容盒（与视口同尺寸）缩放后必须盖住视口
    const minX = vw - s * vw;
    const minY = vh - s * vh;
    if (offsetX > 0) {
      offsetX = 0;
    }
    if (offsetX < minX) {
      offsetX = minX;
    }
    if (offsetY > 0) {
      offsetY = 0;
    }
    if (offsetY < minY) {
      offsetY = minY;
    }
    this.animateZoomTo(s, offsetX, offsetY, ZOOM_ANIMATE_IN_MS, '双击放大');
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '双击放大 s=' + s.toFixed(1) + ' 锚点=(' + x.toFixed(0) + ',' + y.toFixed(0) +
      ') offset=(' + offsetX.toFixed(1) + ',' + offsetY.toFixed(1) +
      ') 动画=' + ZOOM_ANIMATE_IN_MS + 'ms');
    }
  }

  /**
   * 取消进行中的缩放过渡：状态量每帧都等于画面真实值，所以取消本身不产生跳变。
   * 手势接管（捏合按下）、翻页清理（resetZoom）、页面销毁时都要先走这里。
   */
  private stopZoomAnimation(): void {
    this.zoomAnimGen++;
    if (this.zoomAnimTimer >= 0) {
      clearTimeout(this.zoomAnimTimer);
      this.zoomAnimTimer = -1;
    }
    if (this.zoomAnimGuard >= 0) {
      clearTimeout(this.zoomAnimGuard);
      this.zoomAnimGuard = -1;
    }
  }

  /**
   * 把缩放状态平滑过渡到目标值（双击放大 / 双击复位 / 放大后轻点复位共用）。
   *
   * 为什么不用 animateTo：`.transform(matrix)` 的矩阵值不参与属性动画插值，改走 scale+translate
   * 又要动整条渲染链路（捏合、边界都挂在它上面），风险更大。这里用 16ms 定时器自己逐帧驱动，
   * 好处是状态量始终 = 画面真实值，捏合随时可以从当前帧无缝接手。
   *
   * 锚点不漂：屏幕上 p = offset + s·u，要让内容点 u* 钉在原处，每帧必须满足 offset = (1−s)·u*。
   * 所以先从两端解出 u*（哪一端是 1x 就解不出——offset 恒为 0——取另一端的），
   * 再让 scale 与 offset 按同一条曲线推进：两端精确落位，中段始终是绕 u* 的纯缩放。
   */
  private animateZoomTo(targetScale: number, targetX: number, targetY: number, durationMs: number,
    tag: string): void {
    const startScale = this.zoomScale;
    const startX = this.zoomOffsetX;
    const startY = this.zoomOffsetY;
    this.stopZoomAnimation();
    if (Math.abs(targetScale - startScale) < 1e-4 && Math.abs(targetX - startX) < 1e-3 &&
      Math.abs(targetY - startY) < 1e-3) {
      return;
    }
    const anchored0 = Math.abs(1 - startScale) > 1e-4;
    const anchored1 = Math.abs(1 - targetScale) > 1e-4;
    let anchor0X = anchored0 ? startX / (1 - startScale) : 0;
    let anchor1X = anchored1 ? targetX / (1 - targetScale) : 0;
    let anchor0Y = anchored0 ? startY / (1 - startScale) : 0;
    let anchor1Y = anchored1 ? targetY / (1 - targetScale) : 0;
    if (!anchored0) {
      anchor0X = anchor1X;
      anchor0Y = anchor1Y;
    }
    if (!anchored1) {
      anchor1X = anchor0X;
      anchor1Y = anchor0Y;
    }
    const gen = this.zoomAnimGen;
    const startedAt = Date.now();
    this.invalidateBounds();
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '缩放过渡 ' + tag + ' s=' + startScale.toFixed(2) + '→' + targetScale.toFixed(2) +
      ' offset=(' + startX.toFixed(1) + ',' + startY.toFixed(1) + ')→(' +
      targetX.toFixed(1) + ',' + targetY.toFixed(1) + ') 锚点=(' +
      anchor0X.toFixed(1) + ',' + anchor0Y.toFixed(1) + ')→(' +
      anchor1X.toFixed(1) + ',' + anchor1Y.toFixed(1) + ') 时长=' + durationMs + 'ms');
    }
    const finish = (): void => {
      this.zoomScale = targetScale;
      this.zoomOffsetX = targetX;
      this.zoomOffsetY = targetY;
      this.zoomRevision++;
    };
    const frame = (): void => {
      if (gen !== this.zoomAnimGen) {
        return;
      }
      const linear = durationMs <= 0 ? 1 : (Date.now() - startedAt) / durationMs;
      if (linear >= 1) {
        this.zoomAnimTimer = -1;
        if (this.zoomAnimGuard >= 0) {
          clearTimeout(this.zoomAnimGuard);
          this.zoomAnimGuard = -1;
        }
        finish();
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '缩放过渡结束 ' + tag + ' s=' + targetScale.toFixed(2));
        }
        return;
      }
      const t = zoomEase(linear);
      const s = startScale + (targetScale - startScale) * t;
      const ax = anchor0X + (anchor1X - anchor0X) * t;
      const ay = anchor0Y + (anchor1Y - anchor0Y) * t;
      this.zoomScale = s;
      this.zoomOffsetX = (1 - s) * ax;
      this.zoomOffsetY = (1 - s) * ay;
      this.zoomRevision++;
      this.zoomAnimTimer = setTimeout(frame, ZOOM_ANIMATE_TICK_MS);
    };
    this.zoomAnimTimer = setTimeout(frame, ZOOM_ANIMATE_TICK_MS);
    // 兜底：帧链万一断了，到点直接落终值，绝不把画面卡在半路
    this.zoomAnimGuard = setTimeout((): void => {
      this.zoomAnimGuard = -1;
      if (gen !== this.zoomAnimGen) {
        return;
      }
      this.zoomAnimTimer = -1;
      finish();
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '缩放过渡兜底落位 ' + tag);
      }
    }, durationMs + 160);
  }

  /** 中央切栏矩形（对齐 Flutter classifyReaderTap）：视口正中 38% 宽 × 32% 高。 */
  private inMenuRect(x: number, y: number, w: number, h: number): boolean {
    const halfWidth = w * 0.38 / 2;
    const halfHeight = h * 0.32 / 2;
    return Math.abs(x - w * 0.5) < halfWidth && Math.abs(y - h * 0.5) < halfHeight;
  }

  /**
   * 分区判定，逐分支对齐 Flutter classifyReaderTap：
   *  - 横向：左/中/右三分区（中带整条都是切栏，不设中央矩形）；
   *  - 纵向：上/下 1/3 翻页，**中 1/3 只有中央矩形切栏、两侧无操作**（防误触）；
   *  - 条漫：只有中央矩形切栏，其余点击既不切栏也不翻页（Flutter enablePageTurn=false 同口径）。
   */
  private applyTapZone(x: number, y: number): void {
    const w = this.viewportWidth > 0 ? this.viewportWidth : 1;
    const h = this.viewportHeight > 0 ? this.viewportHeight : 1;
    if (this.isWebtoon()) {
      if (this.inMenuRect(x, y, w, h)) {
        this.toggleToolbar();
      }
      return;
    }
    if (this.readMode === READ_MODE_V) {
      const fracY = y / h;
      if (fracY <= 1 / 3) {
        this.goPrevious();
        return;
      }
      if (fracY >= 2 / 3) {
        this.goNext();
        return;
      }
      // 中 1/3：仅中央矩形生效，左右两侧这块区域无任何操作
      if (this.inMenuRect(x, y, w, h)) {
        this.toggleToolbar();
      }
      return;
    }
    // 横向：左开本 → 左 1/3 = 下一页、右 1/3 = 上一页；右开本相反。
    // （与 Swiper 的 .direction(Rtl) 镜像配对：左开本下"下一页"从左侧进，点击与滑动方向一致。）
    const leftMode = this.readLeftMode;
    const fracX = x / w;
    if (fracX <= 1 / 3) {
      if (leftMode) {
        this.goNext();
      } else {
        this.goPrevious();
      }
    } else if (fracX >= 2 / 3) {
      if (leftMode) {
        this.goPrevious();
      } else {
        this.goNext();
      }
    } else {
      this.toggleToolbar();
    }
  }

  /**
   * 单击落点 → 分区/切栏/复位（由 handleTapCandidate 在双击窗过期后调用）。
   * 顶栏展开期间任何分区点击都**只收栏**：不翻页、不切栏。
   */
  private handleReaderTap(x: number, y: number): void {
    // 取证（排查"点两侧不翻页/点中间不切栏"）：记录坐标、视口、模式与状态
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '点击判定 x=' + x.toFixed(0) + ' y=' + y.toFixed(0) +
      ' 视口=' + this.viewportWidth.toFixed(0) + 'x' + this.viewportHeight.toFixed(0) +
      ' mode=' + this.modeLabel() + ' zoom=' + this.zoomScale.toFixed(2) +
      ' webtoon=' + (this.isWebtoon() ? '1' : '0') +
      ' failed=' + (this.isPageFailed(this.currentIndex) ? '1' : '0') +
      ' dir=' + (this.readLeftMode ? '左开本' : '右开本'));
    }
    // ---- 落点守卫（排在失败重载/缩放复位/分区之前：点控件不该顺带翻页）----
    // ① 跳页浮层打开中：遮罩自己的 onClick 负责关闭，期间任何点击都不落分区
    if (this.jumpVisible) {
      return;
    }
    // ② 顶栏展开且落点在顶栏块内：交给顶栏自己的按钮与空白，不翻页、也不把顶栏收掉
    if (this.toolbarShown() && y <= this.toolbarBlockHeight) {
      return;
    }
    // ③ 落点在右下页码胶囊矩形内：交给胶囊自己的 onClick（弹跳页）
    if (this.hitPageCapsule(x, y)) {
      return;
    }
    // ④ 顶栏展开：这一击只收栏（原先左/右 1/3 会顺手翻页，中间带会切栏，这里统一收口）
    if (this.toolbarShown()) {
      this.toggleToolbar();
      return;
    }
    // 优先级 0：当前页加载失败时，轻点即重载，不与三分翻页区打架。
    // 失败页本来也没有可翻看的图内容，抢走这次点击不会造成误操作。
    if (this.isPageFailed(this.currentIndex)) {
      this.reloadPage(this.currentIndex);
      return;
    }
    // 放大态下轻点是「还原画面」，不翻页
    if (this.zoomScale > ZOOMED_THRESHOLD) {
      this.animateZoomTo(ZOOM_MIN_SCALE, 0, 0, ZOOM_ANIMATE_OUT_MS, '轻点复位');
      return;
    }
    // 章末吐槽页（横/纵）内部有自己的列表与按钮：轻点只呼出/收起顶栏，不走翻页分区。
    // 条漫的吐槽页仍按条漫规则走下面的中央矩形判定。
    if (this.onCommentPage() && !this.isWebtoon()) {
      this.toggleToolbar();
      return;
    }
    this.applyTapZone(x, y);
  }

  /**
   * 平移边界：**按内容实际尺寸**算，而不是视口。
   *
   * 之前用 [-(s-1)×视口, 0]，与内容无关，于是三模式都错位：
   *  - 横/纵：图片是 objectFit(Contain)，实际渲染矩形 ≠ 视口（有 letterbox）。
   *    视口比图片大的那个轴上，可达范围被高估 → 能拖出空白；
   *    图片比视口大的轴上被低估 → 拖不到边。
   *  - 条漫：内容比视口高几十倍，边界小到深处内容根本拖不进来。
   *
   * 统一模型：设内容在缩放前占据 [0,cw]×[0,ch]（内容坐标系，含条漫的滚动偏移折算），
   * 缩放后为 [offset, offset + s·c]。要能拖到任意部分且不露空白：
   *   当 s·c ≥ 视口：offset ∈ [视口 - s·c, 0]   （内容比视口大，可平移）
   *   当 s·c <  视口：内容比视口小，居中钉死      （避免拖出异常空白）
   */
  /**
   * 平移边界：**按内容实际尺寸**算，而不是视口。
   *
   * 手势期间（捏合或放大拖动中）边界复用**手势开始时算好的快照**：
   * 条漫的 webtoonContentHeight() 要逐 item 求高，上百页时每帧全量求和会掉帧，
   * 而"慢 + 走不远"的观感有一半来自这里。手势结束/复位时快照失效重算。
   */
  private clampOffset(): void {
    // 简化后（平移停用）：边界只按视口算，够"捏合时把画面框在合理范围内"用。
    this.applyBounds(this.contentBounds(), this.viewportWidth, this.viewportHeight);
  }

  private applyBounds(content: ReaderRect, vw: number, vh: number): void {
    const scaledW = content.width * this.zoomScale;
    const scaledH = content.height * this.zoomScale;

    if (scaledW <= vw) {
      // 内容不足视口宽：居中，不平移（避免拖出异常空白）
      this.zoomOffsetX = (vw - scaledW) / 2 - content.left * this.zoomScale;
    } else {
      const minX = vw - scaledW - content.left * this.zoomScale;
      const maxX = -content.left * this.zoomScale;
      if (this.zoomOffsetX > maxX) {
        this.zoomOffsetX = maxX;
      }
      if (this.zoomOffsetX < minX) {
        this.zoomOffsetX = minX;
      }
    }

    if (scaledH <= vh) {
      this.zoomOffsetY = (vh - scaledH) / 2 - content.top * this.zoomScale;
    } else {
      const minY = vh - scaledH - content.top * this.zoomScale;
      const maxY = -content.top * this.zoomScale;
      if (this.zoomOffsetY > maxY) {
        this.zoomOffsetY = maxY;
      }
      if (this.zoomOffsetY < minY) {
        this.zoomOffsetY = minY;
      }
    }
  }

  /** 手势开始/缩放复位时让边界快照失效，下次重新按最新内容尺寸计算。 */
  private invalidateBounds(): void {
    this.boundsValid = false;
  }

  /**
   * 内容在「变换盒子坐标系」里的矩形（缩放前）。
   *
   * ⚠️ 简化版（单指平移已停用）：一律返回"与视口同尺寸"的盒子。
   * 之前的内容感知版本（横/纵取 objectFit(Contain) 后的图片矩形、条漫取整条列表在滚动位置下的等效矩形）
   * 是为"放大后拖到四边四角"服务的；它与 `.transform()` 的锚点语义纠缠，五轮尝试均未在真机成立，
   * 现随平移一并停用。保留同名函数以免大改调用方；若将来重启此功能，恢复内容感知实现即可。
   */
  private contentBounds(): ReaderRect {
    const vw = this.viewportWidth > 0 ? this.viewportWidth : 0;
    const vh = this.viewportHeight > 0 ? this.viewportHeight : 0;
    return { left: 0, top: 0, width: vw, height: vh };
  }

  /** 当前页图片的原始宽高（横/纵用）。 */
  private currentImageSize(): ReaderSize {
    const url = this.urls.length > 0 && this.currentIndex < this.urls.length ?
      this.currentUrl(this.currentIndex, this.urls[this.currentIndex]) : '';
    const known = this.imageSizes.get(url);
    if (known !== undefined) {
      return known;
    }
    // 尚未解码到尺寸：用已缓存的宽高比反推一个保守矩形，等 onComplete 后精化
    const ratio = this.aspectRatios.get(url);
    if (ratio !== undefined && ratio > 0 && this.contentWidth > 0) {
      return { width: this.contentWidth, height: this.contentWidth / ratio };
    }
    return { width: 0, height: 0 };
  }

  /** 条漫内容总高：所有 item 高度之和（按已缓存比例估算），含章末吐槽页的一屏高度。 */
  private webtoonContentHeight(): number {
    let total = 0;
    for (let i = 0; i < this.urls.length; i++) {
      total += this.webtoonItemHeight(i, this.urls[i]);
    }
    if (this.showCommentPage() && this.viewportHeight > 0) {
      // 吐槽虚拟页高度锁定为一屏（见 webtoonList 里的 item 分支），必须计入"物理尽头"
      total += this.viewportHeight;
    }
    return total;
  }

  /** 条漫当前滚动偏移（vp，内容坐标）。 */
  private webtoonScrollOffset(): number {
    try {
      const offset = this.listScroller.currentOffset();
      return offset !== undefined && offset !== null ? offset.yOffset : 0;
    } catch (error) {
      // 控制器尚未绑定：按 0 处理，边界会偏保守但不至于锁死
      return 0;
    }
  }

  private applyZoom(scale: number, offsetX: number, offsetY: number): void {
    // 捏合是实时直连：先把还在跑的双击/复位过渡掐掉，避免它继续改状态把手指按住的画面拽走
    this.stopZoomAnimation();
    let s = scale;
    if (s < ZOOM_MIN_SCALE) {
      s = ZOOM_MIN_SCALE;
    }
    if (s > ZOOM_MAX_SCALE) {
      s = ZOOM_MAX_SCALE;
    }
    const prevScale = this.zoomScale;
    const prevX = this.zoomOffsetX;
    const prevY = this.zoomOffsetY;
    this.zoomScale = s;
    this.zoomOffsetX = offsetX;
    this.zoomOffsetY = offsetY;
    if (s <= ZOOMED_THRESHOLD) {
      // 回到 1x：偏移必须归零，否则会留下「看起来没缩放但画面偏了」的状态
      this.zoomScale = ZOOM_MIN_SCALE;
      this.zoomOffsetX = 0;
      this.zoomOffsetY = 0;
    } else {
      this.clampOffset();
    }
    if (prevScale !== this.zoomScale || prevX !== this.zoomOffsetX || prevY !== this.zoomOffsetY) {
      this.zoomRevision++;
    }
  }

  // ---- 平移诊断（限流，绝不刷屏）----

  /**
   * 平移诊断：**限流**输出，默认每 12 个 move 事件或累计位移超过 240vp 才打一次，
   * 手势结束/guard 复位时也会打一次收尾。用于真机定位"拖不动/拖不到边"。
   */
  private notePanDiagnostics(dx: number, dy: number): void {
    this.panEventCount++;
    this.panAccumulated += Math.abs(dx) + Math.abs(dy);
    const reachedEvent = this.panEventCount >= PAN_DIAG_EVENT_INTERVAL;
    const reachedDistance = this.panAccumulated >= PAN_DIAG_DISTANCE_VP;
    if (!reachedEvent && !reachedDistance) {
      return;
    }
    this.panEventCount = 0;
    this.panAccumulated = 0;
    this.emitPanDiagnostics(dx, dy);
  }

  /** 打一条平移诊断日志（含 clamp 边界与内容尺寸来源）。 */
  private emitPanDiagnostics(dx: number, dy: number): void {
    const content = this.contentBounds();
    const vw = this.viewportWidth;
    const vh = this.viewportHeight;
    const scaledW = content.width * this.zoomScale;
    const scaledH = content.height * this.zoomScale;
    const source = this.isWebtoon() ?
      ('webtoon 总高=' + this.webtoonContentHeight().toFixed(0) +
        ' 滚动偏移=' + this.webtoonScrollOffset().toFixed(0)) :
      ('imageSize=' + this.currentImageSize().width.toFixed(0) + 'x' +
        this.currentImageSize().height.toFixed(0));
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(
      0x0000,
      'Collector',
      '%{public}s',
      '平移诊断 mode=' + this.modeLabel() + ' s=' + this.zoomScale.toFixed(2) +
      ' 位移=(' + dx.toFixed(1) + ',' + dy.toFixed(1) + ')' +
      ' offset=(' + this.zoomOffsetX.toFixed(1) + ',' + this.zoomOffsetY.toFixed(1) + ')' +
      ' 视口=' + vw.toFixed(0) + 'x' + vh.toFixed(0) +
      ' content=(l' + content.left.toFixed(0) + ',t' + content.top.toFixed(0) +
      ',' + content.width.toFixed(0) + 'x' + content.height.toFixed(0) + ')' +
      ' scaled=' + scaledW.toFixed(0) + 'x' + scaledH.toFixed(0) +
      ' 来源=' + source
    );
    }
  }

  /** 手势结束/复位时补一条收尾诊断，并重置限流计数。 */
  private resetPanDiagnostics(): void {
    if (this.panEventCount > 0 || this.panAccumulated > 0) {
      this.emitPanDiagnostics(0, 0);
    }
    this.panEventCount = 0;
    this.panAccumulated = 0;
  }

  /**
   * 首次进入阅读器时让顶栏短暂浮出并附提示，然后自动收起。
   * 三模式统一（原只在条漫做）：既让用户知道入口在哪，又不长期遮挡画面。
   */
  private armIntroBars(): void {
    if (this.introDone) {
      return;
    }
    if (this.loadState !== ReaderLoadState.Content) {
      return;
    }
    this.introDone = true;
    this.toolbarVisible = true;
    this.introHint = '点屏幕可再次呼出';
    this.introTimer = setTimeout(() => {
      this.toolbarVisible = false;
      this.introHint = '';
      this.introTimer = -1;
    }, 2200);
  }

  /**
   * 缩放倍率换算：把手指距离的变化比例直接映射到 scale。
   *
   * 三模式必须一致。条漫此前手感偏小，是因为把「整条画布高度」带进了换算
   * （视口高度被当作条漫内容总高使用），导致同样的手指幅度得到更小的倍率。
   * 这里统一成纯手指距离比例，与横/纵完全一致。
   */
  private pinchFactor(distance: number): number {
    if (this.pinchStartDistance <= 0) {
      return 1;
    }
    return distance / this.pinchStartDistance;
  }

  private applyPinch(distance: number, focalX: number, focalY: number): void {
    if (this.pinchStartDistance <= 0 || this.pinchStartScale <= 0) {
      return;
    }
    // 三模式统一：倍率 = 起始缩放 × 手指距离变化比例（与横/纵一致）
    let next = this.pinchStartScale * this.pinchFactor(distance);
    if (next < ZOOM_MIN_SCALE) {
      next = ZOOM_MIN_SCALE;
    }
    if (next > ZOOM_MAX_SCALE) {
      next = ZOOM_MAX_SCALE;
    }
    const ratio = next / this.pinchStartScale;
    const offsetX = focalX + ratio * (this.pinchStartOffsetX - this.pinchStartFocalX);
    const offsetY = focalY + ratio * (this.pinchStartOffsetY - this.pinchStartFocalY);
    this.applyZoom(next, offsetX, offsetY);
  }

  /**
   * 取手指在**窗口坐标系**里的位置。
   *
   * 关键：TouchObject.x/y 是「事件响应组件自身的坐标系」里的坐标（SDK 原文：
   * "in the component coordinate system based on the event-responsive component"）。
   * 而 onTouch 正挂在**带 transform 的那个节点**上，所以一旦 scale≠1，
   * x/y 就是被缩放过的坐标（相当于父坐标系的值除以 s）。
   *
   * 之前用 x/y 算平移增量，手指位移被等效除以 s —— 这正是"放大后拖动很慢、
   * 越放大越拖不动"的根因；而且 panLastX 每帧都用这个被缩小的增量重设基准，
   * 误差逐帧累积，内容永远追不上手指，于是边角也拖不到。
   *
   * windowX/windowY 是窗口坐标系，不受组件自身 transform 影响，与
   * zoomOffset（父坐标系平移量）同一空间，可以直接相减。
   */
  private touchX(t: TouchObject): number {
    return t.windowX !== undefined ? t.windowX : t.x;
  }

  private touchY(t: TouchObject): number {
    return t.windowY !== undefined ? t.windowY : t.y;
  }

  private pinchDistance(touches: TouchObject[]): number {
    if (touches.length < 2) {
      return 0;
    }
    const dx = this.touchX(touches[0]) - this.touchX(touches[1]);
    const dy = this.touchY(touches[0]) - this.touchY(touches[1]);
    return Math.sqrt(dx * dx + dy * dy);
  }

  private pinchFocal(touches: TouchObject[]): number[] {
    if (touches.length < 2) {
      return [0, 0];
    }
    return [
      (this.touchX(touches[0]) + this.touchX(touches[1])) / 2,
      (this.touchY(touches[0]) + this.touchY(touches[1])) / 2
    ];
  }

  /**
   * 手势仲裁总入口：三种模式共用同一套指针处理。
   * - 双指按下立刻置 pinching，锁翻页 / 锁条漫滚动，并作废还在双击窗里的候选轻点；
   * - 退出捏合后只要还处于放大态，依旧锁翻页（把拖动留给平移）；
   * - 单指轻点（未移动、非多指）进 handleTapCandidate：280ms 双击窗内第二击＝缩放/复位，
   *   窗口过期才落分区 —— 连击不会被吃成翻页。
   */
  private onReaderTouch(event: TouchEvent): void {
    const touches = event.touches;
    if (event.type === TouchType.Down) {
      if (touches.length >= 2) {
        // 双指按下立刻锁翻页：避免捏合起步那一下被 Swiper/List 抢走
        this.pinching = true;
        // 缩放从此听手指的：双击过渡让位（状态停在当前帧，接手不跳）
        this.stopZoomAnimation();
        this.tapPointerId = -1;
        this.panPointerId = -1;
        // 多指＝这串动作归缩放了：还在等双击窗的单击直接作废
        this.clearPendingTap();
        this.pinchStartDistance = this.pinchDistance(touches);
        const focal = this.pinchFocal(touches);
        this.pinchStartFocalX = focal[0];
        this.pinchStartFocalY = focal[1];
        this.pinchStartScale = this.zoomScale;
        this.pinchStartOffsetX = this.zoomOffsetX;
        this.pinchStartOffsetY = this.zoomOffsetY;
        // 新手势：按最新内容尺寸重算边界快照
        this.invalidateBounds();
        return;
      }
      if (touches.length === 1) {
        this.tapDownX = touches[0].x;
        this.tapDownY = touches[0].y;
        this.tapPointerId = touches[0].id;
        this.tapMoved = false;
        this.webtoonTapConsumed = false;
        // 新一次手势：越界"只认一次"的标记重新打开（武装状态本身跨手势保留）
        this.edgeGestureConsumed = false;
        // 到头确认的速度分母：本次手势的按下时刻
        this.edgeDownAt = Date.now();
        // 容器原点（窗口坐标 − 组件坐标）：条漫 item 层靠它把 windowX/Y 换算回视口坐标。
        // 只在未放大时刷新 —— 放大后组件坐标被 .transform 缩过，算出来的原点是错的。
        if (this.zoomScale <= ZOOMED_THRESHOLD) {
          this.viewportWindowX = this.touchX(touches[0]) - touches[0].x;
          this.viewportWindowY = this.touchY(touches[0]) - touches[0].y;
        }
        // ⚠️ 放大后"单指拖动=平移画面"已停用（P0 搁置，见 onReaderTouch 里的说明）：
        //    放大态单指只保留"轻点=复位缩放"，不再拖画面。
        this.panPointerId = -1;
      }
      return;
    }

    if (event.type === TouchType.Move) {
      if (touches.length >= 2) {
        if (!this.pinching) {
          this.pinching = true;
          this.pinchStartDistance = this.pinchDistance(touches);
          const focal0 = this.pinchFocal(touches);
          this.pinchStartFocalX = focal0[0];
          this.pinchStartFocalY = focal0[1];
          this.pinchStartScale = this.zoomScale;
          this.pinchStartOffsetX = this.zoomOffsetX;
          this.pinchStartOffsetY = this.zoomOffsetY;
        }
        const distance = this.pinchDistance(touches);
        const focal = this.pinchFocal(touches);
        this.applyPinch(distance, focal[0], focal[1]);
        return;
      }
      if (touches.length === 1) {
        const t = touches[0];
        if (this.tapPointerId === t.id) {
          // 兜底再记一次容器原点：有的容器只在 Move 里才补报（Down 漏掉时仍能把 item 落点换算回视口）
          if (this.zoomScale <= ZOOMED_THRESHOLD) {
            this.viewportWindowX = this.touchX(t) - t.x;
            this.viewportWindowY = this.touchY(t) - t.y;
          }
          const dx = t.x - this.tapDownX;
          const dy = t.y - this.tapDownY;
          if (Math.abs(dx) > TAP_SLOP_VP || Math.abs(dy) > TAP_SLOP_VP) {
            if (!this.tapMoved) {
              this.tapMoved = true;
              // 条漫：手指滑出轻点容差＝用户自己读起来了，断点恢复别再往回拽
              if (this.isWebtoon()) {
                this.webtoonUserScrolled = true;
              }
            }
          }
          // 到头确认：首/末页（条漫列表尽头）继续朝同一方向拖 → 先提示，再一次手势才切章
          this.detectEdgeSwipe(dx, dy);
        }
        // 平移已停用（P0 搁置）：此处不再对 offset 做任何增量应用。
        // 回顾：单指平移与 .transform 的锚点语义纠缠，五轮尝试均未在真机成立；
        // 现改为"只捏合缩放 + 轻点复位"，把复杂度与风险收回。
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed = event.changedTouches;
      if (touches.length < 2 && this.pinching) {
        // 捏合结束：保留当前缩放，解除「捏合中」标记
        this.pinching = false;
        this.pinchStartDistance = 0;
        // 平移已停用：捏合结束只清掉轻点候选（放大态下轻点=复位缩放）
        this.panPointerId = -1;
        if (this.zoomScale > ZOOMED_THRESHOLD) {
          this.tapPointerId = -1;
        }
        this.resetPanDiagnostics();
        return;
      }
      // 用 changedTouches 判定轻点：Swiper/List 这类滚动容器会把 Up 时的 touches 留着不归零，
      // 旧写法 `touches.length === 0` 会让轻点永远不触发（横/纵的点击分区曾因此整体失效）。
      if (!this.pinching && !this.webtoonTapConsumed) {
        const t = changed.length > 0 ? changed[0] : null;
        if (t !== null && this.tapPointerId === t.id && !this.tapMoved &&
          event.type === TouchType.Up) {
          // 先开双击窗：窗口内第二击＝缩放/复位，窗口过期才落分区
          this.handleTapCandidate(this.viewportX(t), this.viewportY(t));
        }
      }
      this.tapPointerId = -1;
      this.panPointerId = -1;
      this.tapMoved = false;
      this.resetPanDiagnostics();
    }
  }

  /**
   * 缩放 transform：先平移再缩放（等价于 Flutter 版的
   * Matrix4.identity()..translate(..)..scale(..)），变换轴心为组件左上角。
   *
   * 直接用列主序常量矩阵，不依赖链式调用的乘法顺序：
   *   M = T(offset) · S(scale) = [s,0,0,0, 0,s,0,0, 0,0,1,0, tx,ty,0,1]
   * 于是屏幕上一点 p = offset + scale · u（u 为内容坐标），与 clampOffset 的边界一致。
   */
  private zoomTransform(): object {
    if (this.zoomRevision < 0) {
      return matrix4.identity();
    }
    const s = this.zoomScale;
    // ArkUI 的 .transform(matrix) 绕**组件锚点**共轭生效，锚点默认＝几何中心 a=(w/2, h/2)：
    //   实际渲染 p = t' + (1−s)·a + s·u
    // 而全项目（contentBounds / applyBounds / applyPinch / 平移增量）都按左上角模型 p = offset + s·u 计算。
    // 两者差 (s−1)·a —— 这就是"越放大越拖不动、边角拖不进来"的根因。
    // 这里在矩阵里补上 (s−1)·a 把两种模型对齐；s=1 时补偿为 0，1x 行为不变。
    const tx = this.zoomOffsetX + (s - 1) * (this.viewportWidth / 2);
    const ty = this.zoomOffsetY + (s - 1) * (this.viewportHeight / 2);
    return matrix4.init([
      s, 0, 0, 0,
      0, s, 0, 0,
      0, 0, 1, 0,
      tx, ty, 0, 1
    ]);
  }

  /** 回到 1x：翻页 / 切模式时调用，避免带着放大态进下一页。 */
  private resetZoom(): void {
    // 翻页清理走「立刻归位」：先把过渡停掉，再直接落 1x —— 换页不能出现半路缩放的闪跳
    this.stopZoomAnimation();
    this.invalidateBounds();
    this.resetPanDiagnostics();
    if (this.zoomScale !== ZOOM_MIN_SCALE || this.zoomOffsetX !== 0 || this.zoomOffsetY !== 0) {
      this.zoomScale = ZOOM_MIN_SCALE;
      this.zoomOffsetX = 0;
      this.zoomOffsetY = 0;
      this.zoomRevision++;
    }
    this.pinching = false;
    this.pinchStartDistance = 0;
    this.tapPointerId = -1;
    this.panPointerId = -1;
  }

  /**
   * 条漫是否真正位于列表**顶端**（供"到头确认"判定）：
   * 下标已经是第 0 页，且容器滚动偏移也回到了顶。
   */
  private webtoonAtStartEdge(): boolean {
    if (this.currentIndex > 0) {
      return false;
    }
    return this.webtoonScrollOffset() <= 4;
  }

  /**
   * 条漫是否真正位于列表**尽头**（供"到头确认"判定）：
   * 已滑到最后一个 item（含章末吐槽虚拟页，其高度＝一屏），或滚动偏移顶到底。
   * 用物理偏移而不是"最后一张图的 start 可见"，避免还剩半张图就提示切章。
   */
  private webtoonAtEndEdge(): boolean {
    // 前置条件：第一个可见 item 必须已经是最后一张图（或吐槽页）。
    // 宽高比还没学全时总高会被算小，没有这条会把"章节中段"误判成尽头。
    if (this.urls.length > 0 && this.currentIndex < this.urls.length - 1) {
      return false;
    }
    if (this.showCommentPage() && this.currentIndex >= this.urls.length) {
      // 已经站在吐槽页上：它就是最后一个 item，必然是尽头
      return true;
    }
    const vh = this.viewportHeight;
    if (vh <= 0) {
      return this.currentIndex >= this.readerPageCount() - 1;
    }
    return this.webtoonScrollOffset() + vh >= this.webtoonContentHeight() - 4;
  }

  /**
   * 章节边界二次确认（对齐 Flutter `doubleTapToast` + ChapterEdgeGuard）：
   * 第一次越界只给提示，CHAPTER_EDGE_CONFIRM_MS 窗口内**同方向**再来一次才真正切章；
   * 方向相反则改判为"重新武装新方向"（也算第一划）。没有相邻章时提示"已经到头了~"。
   *
   * @param action 'tap' = 点击分区触发（提示"再次按下"），'swipe' = 拖动/滚动触发（提示"再次滑动"）。
   */
  private handleChapterEdge(goNext: boolean, action: string): void {
    if (this.switchingChapter) {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '章节边界 忽略（切章进行中） goNext=' + (goNext ? '1' : '0'));
      }
      return;
    }
    const now = Date.now();
    if (this.edgeDirection !== 0 && now - this.edgeArmedAt >= CHAPTER_EDGE_CONFIRM_MS) {
      // 武装已过期：本次动作按"第一划"重新处理
      this.resetEdgeGuard();
    }
    const adjacent = this.adjacentChapter(goNext);
    if (adjacent === null) {
      this.resetEdgeGuard();
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '章节边界 到头 goNext=' + (goNext ? '1' : '0') +
        ' 序列长度=' + this.chapterSequence.length);
      }
      this.showToast('已经到头了~');
      return;
    }
    const direction = goNext ? 1 : -1;
    if (this.edgeDirection === direction) {
      // 第二次同方向动作 → 切章
      this.resetEdgeGuard();
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '章节边界 确认切章 goNext=' + (goNext ? '1' : '0') + ' action=' + action);
      }
      this.switchChapter(goNext, action);
      return;
    }
    // 第一次动作（或方向相反）：武装 + 提示
    this.edgeDirection = direction;
    this.edgeArmedAt = now;
    if (this.edgeTimer >= 0) {
      clearTimeout(this.edgeTimer);
    }
    this.edgeTimer = setTimeout(() => {
      this.edgeTimer = -1;
      if (this.edgeDirection !== 0) {
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s', '章节边界 确认窗口超时，解除武装');
        }
        this.resetEdgeGuard();
      }
    }, CHAPTER_EDGE_CONFIRM_MS);
    const label = goNext ? '下一章' : '上一章';
    const verb = action === 'tap' ? '按下' : '滑动';
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '章节边界 武装 direction=' + direction + ' action=' + action + ' 目标=' + adjacent.name);
    }
    this.showToast('再次' + verb + '加载' + label);
  }

  /**
   * 原地切章：不退出阅读器，把 active* 换成相邻章后按**新章 id** 重新装载。
   * 旧章状态（预载门 / 收图 / 换扩展名重试 / 手动重载记录 / 吐槽 / 预取）由 loadImages 统一清空；
   * 进度写入新章的 page_{uuid}（saveProgress 捕获的是 activeChapterId）；
   * 顶栏标题与总数由 activeChapterName / activeChapterSize 驱动。
   *
   * @returns 是否已发起切换（用于去重）。
   */
  private switchChapter(goNext: boolean, action: string): boolean {
    const target = this.adjacentChapter(goNext);
    if (target === null) {
      this.showToast('已经到头了~');
      return false;
    }
    if (this.switchingChapter) {
      return false;
    }
    this.switchingChapter = true;
    // 先落盘**旧章**进度：loadImages 会立刻把 activeChapterId 换成新章
    this.saveProgressFor(this.activeChapterId, this.readingIndex(), this.urls.length, this.collecting);
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '原地切章 ' + (goNext ? '下一' : '上一') + '章 action=' + action +
      ' ' + this.activeChapterId + ' → ' + target.id + ' ' + target.name);
    }
    this.activeChapterId = target.id;
    this.activeChapterName = target.name;
    this.activeChapterSize = target.size;
    this.jumpVisible = false;
    // 向前（上一章）按既有语义落在新章末张图片；向后从新章第一页（或断点）开始
    this.loadImages(!goNext);
    return true;
  }

  /**
   * 到头确认的**拖动**入口：由 onReaderTouch 的单指 Move 调用。
   * 纵向＝上下端、横向＝左右端、条漫＝列表尽头；每个 touch session 只认一次
   * （edgeGestureConsumed），第二划必须等新的手势会话（下一次 Down 才重新放行）。
   *
   * 认不认这一划看几何口径（对齐 Flutter EdgeSwipeGeometry，替换原固定 48vp）：
   * 主轴位移 ≥ 视口主轴×0.12 **或** 平均速度 ≥ 480vp/s；交叉轴 ≤ 0.85×主轴；
   * overscroll ≥ 6vp 只作辅助证据。
   */
  private detectEdgeSwipe(dx: number, dy: number): void {
    if (this.edgeGestureConsumed || this.zoomLocked()) {
      return;
    }
    if (this.loadState !== ReaderLoadState.Content || this.urls.length === 0) {
      return;
    }
    // 主轴随模式走：横向取 x，纵向/条漫取 y（与 Flutter horizontalReading 同口径）
    const horizontal = !this.isWebtoon() && this.readMode !== READ_MODE_V;
    const main = horizontal ? Math.abs(dx) : Math.abs(dy);
    const cross = horizontal ? Math.abs(dy) : Math.abs(dx);
    if (main < CHAPTER_EDGE_MIN_PRIMARY_VP) {
      return;
    }
    // 斜滑无效：交叉轴位移 > 主轴 × 0.85 → 这一划不算数（不是"还差一点"，是直接作废）
    if (cross > main * CHAPTER_EDGE_MAX_CROSS_RATIO) {
      return;
    }
    let towardNext: boolean;
    if (this.isWebtoon()) {
      towardNext = dy < 0;
      if (towardNext ? !this.webtoonAtEndEdge() : !this.webtoonAtStartEdge()) {
        return;
      }
    } else if (this.readMode === READ_MODE_V) {
      towardNext = dy < 0;
      if (towardNext ? this.currentIndex < this.readerPageCount() - 1 : this.currentIndex > 0) {
        return;
      }
    } else {
      // 「继续朝同一方向拖」= 朝**下一页**方向拖：右开本是划左(dx<0)，左开本是划右(dx>0)——
      // 与 Swiper 的 RTL 镜像保持同向，否则左开本下末页向右拖会被误判成"上一章"。
      towardNext = this.readLeftMode ? dx > 0 : dx < 0;
      if (towardNext ? this.currentIndex < this.readerPageCount() - 1 : this.currentIndex > 0) {
        return;
      }
    }
    // ---- 阈值（替换原先固定 48vp）：位移 ≥ 视口主轴×0.12 **或** 平均速度 ≥ 480vp/s（OR）----
    const axisLength = horizontal ? this.viewportWidth : this.viewportHeight;
    const minDistance = (axisLength > 0 ? axisLength : 1) * CHAPTER_EDGE_MIN_DISTANCE_FRACTION;
    const elapsedMs = Math.max(1, Date.now() - this.edgeDownAt);
    const velocity = main / (elapsedMs / 1000);
    const distanceOk = main >= minDistance;
    const velocityOk = velocity >= CHAPTER_EDGE_MIN_VELOCITY;
    if (!distanceOk && !velocityOk) {
      // overscroll 只作辅助证据：横/纵没有该回调、条漫多数时候也被夹在界内，
      // 量得到就补上这一票，量不到则维持"位移或速度都没达标就不认"。
      if (this.edgeOverscroll(towardNext) < CHAPTER_EDGE_AUX_OVERSCROLL_VP) {
        return;
      }
    }
    this.edgeGestureConsumed = true;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '到头判定 采纳 主轴=' + main.toFixed(1) + 'vp 阈值=' + minDistance.toFixed(1) +
      'vp 速度=' + velocity.toFixed(0) + 'vp/s 交叉比=' +
      (main > 0 ? (cross / main).toFixed(2) : '0') + ' 用时=' + elapsedMs +
      'ms 位移判=' + (distanceOk ? '过' : '否') + ' 速度判=' + (velocityOk ? '过' : '否') +
      ' goNext=' + (towardNext ? '1' : '0'));
    }
    this.handleChapterEdge(towardNext, 'swipe');
  }

  /**
   * 越界量（vp，≥0）：到头判定的辅助证据，不是唯一入口。
   * 横/纵的 Swiper 没有 overscroll 回调，恒返回 0；条漫 EdgeEffect.None 通常也把滚动偏移夹在界内，
   * 只有容器真把偏移顶出去时才 > 0 —— 量不到就按 0 处理，绝不因为量不到就放宽位移/速度门槛。
   */
  private edgeOverscroll(towardNext: boolean): number {
    if (!this.isWebtoon() || this.viewportHeight <= 0) {
      return 0;
    }
    const offset = this.webtoonScrollOffset();
    const maxOffset = this.webtoonContentHeight() - this.viewportHeight;
    if (towardNext) {
      return offset > maxOffset ? offset - maxOffset : 0;
    }
    return offset < 0 ? -offset : 0;
  }

  // ---- P2-3 音量键翻页 ----

  /**
   * 按设置开关音量键监听。
   *
   * 主路径是 `inputConsumer.on('keyPressed', …)`：SDK 文档写明「调用成功即拦截系统对该按键的
   * 默认响应，音量调节等系统动作不再触发」，并且**只有这条路径**能在系统消费掉音量键之前拿到它。
   * 根节点的 onKeyEvent 只作为兜底（外接键盘/系统把键派发下来时才可能触发），见 handleRootKeyEvent。
   * 两条路径都可能对同一次按压各回调一次，handleVolumePress 里有去重。
   */
  private applyVolumeKeyInterest(): void {
    if (this.volTurnEnabled) {
      this.registerVolumeKeys();
    } else {
      this.unregisterVolumeKeys();
    }
  }

  private registerVolumeKeys(): void {
    if (!this.volUpRegistered) {
      try {
        inputConsumer.on('keyPressed',
          { key: KeyCode.KEYCODE_VOLUME_UP, action: 1, isRepeat: false },
          this.volUpKeyEvent);
        this.volUpRegistered = true;
      } catch (error) {
        this.volUpRegistered = false;
        const be = error as BusinessError;
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '音量键翻页：VOL_UP 注册失败 code=' + be.code + ' ' + be.message);
        }
      }
    }
    if (!this.volDownRegistered) {
      try {
        inputConsumer.on('keyPressed',
          { key: KeyCode.KEYCODE_VOLUME_DOWN, action: 1, isRepeat: false },
          this.volDownKeyEvent);
        this.volDownRegistered = true;
      } catch (error) {
        this.volDownRegistered = false;
        const be = error as BusinessError;
        if (COLLECTOR_LOG_ENABLED) {
          hilog.info(0x0000, 'Collector', '%{public}s',
          '音量键翻页：VOL_DOWN 注册失败 code=' + be.code + ' ' + be.message);
        }
      }
    }
    if (this.volUpRegistered && this.volDownRegistered) {
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '音量键翻页：inputConsumer 已注册（注册期间系统音量调节被拦截）');
      }
    }
  }

  /** 注销必须与注册用**同一个回调引用**，否则系统音量不会恢复（SDK off 的语义）。 */
  private unregisterVolumeKeys(): void {
    if (this.volUpRegistered) {
      try {
        inputConsumer.off('keyPressed', this.volUpKeyEvent);
      } catch (error) {
      }
      this.volUpRegistered = false;
    }
    if (this.volDownRegistered) {
      try {
        inputConsumer.off('keyPressed', this.volDownKeyEvent);
      } catch (error) {
      }
      this.volDownRegistered = false;
    }
    this.volUpHeld = false;
    this.volDownHeld = false;
  }

  /** inputConsumer 回调：注册成功时系统只报按下（action=1），这里直接走统一翻页入口。 */
  private volUpKeyEvent: (event: InputKeyEvent) => void = (_event: InputKeyEvent): void => {
    this.handleVolumePress(KeyCode.KEYCODE_VOLUME_UP, 'inputConsumer');
  };

  private volDownKeyEvent: (event: InputKeyEvent) => void = (_event: InputKeyEvent): void => {
    this.handleVolumePress(KeyCode.KEYCODE_VOLUME_DOWN, 'inputConsumer');
  };

  /**
   * 根节点 onKeyEvent 的兜底路径：返回 true 表示已消费（不再冒泡）。
   *
   * ⚠️ 这里的 KeyEvent 是 **ArkUI 组件事件**（全局声明，字段是 `keyCode`/`type`），
   * 和 inputConsumer 回调里的 `@ohos.multimodalInput.keyEvent.KeyEvent`（`key.code`/`action`）
   * 不是同一个类型，两者不要混用。用「按压沿」判定：按住期间的重复 Down 不再翻页，Up 复位。
   */
  private handleRootKeyEvent(event: KeyEvent): boolean {
    if (!this.volTurnEnabled) {
      return false;
    }
    const code = event.keyCode;
    if (code !== KeyCode.KEYCODE_VOLUME_UP && code !== KeyCode.KEYCODE_VOLUME_DOWN) {
      return false;
    }
    const isUp = code === KeyCode.KEYCODE_VOLUME_UP;
    if (event.type === KeyType.Up) {
      if (isUp) {
        this.volUpHeld = false;
      } else {
        this.volDownHeld = false;
      }
      return false;
    }
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (isUp) {
      if (this.volUpHeld) {
        return false;
      }
      this.volUpHeld = true;
    } else {
      if (this.volDownHeld) {
        return false;
      }
      this.volDownHeld = true;
    }
    this.handleVolumePress(code, 'onKeyEvent');
    return true;
  }

  /** 音量 → 翻页：上一页 = 音量+，下一页 = 音量−（与 Flutter VolumeKeys.enable(up: _volBack, down: _volForward) 一致）。 */
  private handleVolumePress(code: number, source: string): void {
    if (!this.volTurnEnabled || this.jumpVisible || this.loadState !== ReaderLoadState.Content) {
      return;
    }
    const now = Date.now();
    if (now - this.lastVolumeEventAt < VOLUME_DEDUP_MS) {
      // 两条路径对同一次按压各报一次：丢掉第二下，保证按一下只翻一页
      return;
    }
    this.lastVolumeEventAt = now;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '音量键翻页 source=' + source + ' code=' + code +
      ' idx=' + this.currentIndex + ' 总数=' + this.urls.length);
    }
    if (code === KeyCode.KEYCODE_VOLUME_UP) {
      this.goPrevious();
    } else {
      this.goNext();
    }
  }

  // ---- P2-4 右上角时间胶囊（域名/网速已并入；原「更多信息」行与其开关已删除）----

  /** 开/关胶囊计时器；开关关掉时顺手清空文案（UI 侧因此不会渲染）。 */
  private syncCapsuleTimer(): void {
    if (this.capsuleTimer >= 0) {
      clearInterval(this.capsuleTimer);
      this.capsuleTimer = -1;
    }
    if (!this.hideStatusBarEnabled) {
      this.capsuleText = '';
      return;
    }
    // 重新计时：吞吐基线也重置，否则第一拍会把整个间隔的流量摊成一个偏低的均值
    this.rxLastBytes = -1;
    this.rxLastAt = 0;
    // 后台先跑一发可达性探测：结果进 TTL 缓存，第一拍胶囊就不用干等 2.5s 超时
    netStatus.warmup();
    this.refreshCapsule();
    this.capsuleTimer = setInterval((): void => {
      this.refreshCapsule();
    }, CAPSULE_REFRESH_MS);
  }

  /**
   * 胶囊文案（两行、右上角右对齐）：
   * - 第一行 `HH:MM [网络类型]`：WIFI / 流量 / 无网络…，取不到就只剩时间；
   * - 第二行 `[图源域名] · [全机↓速率]`：两段都取不到就**整行不写**（整体退回单行）。
   * 各段「可取则取、取不到省略」；域名/速率沿用 currentHostLabel() / downlinkLabel()，口径不重造。
   */
  private async refreshCapsule(): Promise<void> {
    if (!this.hideStatusBarEnabled || this.capsuleBusy) {
      return;
    }
    this.capsuleBusy = true;
    try {
      const line1: string[] = [this.clockShort()];
      const net = await this.networkLabel();
      if (net.length > 0) {
        line1.push(net);
      }
      const line2: string[] = [];
      const host = this.currentHostLabel();
      if (host.length > 0) {
        line2.push(host);
      }
      const rate = await this.downlinkLabel();
      if (rate.length > 0) {
        line2.push(rate);
      }
      this.capsuleText = line2.length > 0 ?
        line1.join(' ') + '\n' + line2.join(' · ') : line1.join(' ');
    } finally {
      this.capsuleBusy = false;
    }
  }

  /** 纯时钟 `HH:MM`（时间胶囊用）。 */
  private clockShort(): string {
    const now = new Date();
    const hour = now.getHours();
    const minute = now.getMinutes();
    const hh = hour < 10 ? '0' + hour.toString() : hour.toString();
    const mm = minute < 10 ? '0' + minute.toString() : minute.toString();
    return hh + ':' + mm;
  }

  /**
   * 网络类型：交给**独立模块** `NetStatus`（`pages/NetStatus.ets`）。
   * 模块里是 ① `wifiManager.isWifiActive()` ② 境内 `generate_204` 可达性探测（TTL 缓存 + 2.5s 超时，
   * 只吃 INTERNET 权限，绕开坏掉的 GET_NETWORK_INFO），映射产出 `WIFI` / `流量` / `无网络` / 空串。
   *
   * 空串＝未知，胶囊省略该段只剩时间；**本地章节与离线阅读都不参与判定** ——
   * 这里显示的是设备的真实网络状态（修「看本地缓存却显示无网络」）。
   */
  private async networkLabel(): Promise<string> {
    return netStatus.label();
  }

  /**
   * 当前页图片 URL 的主机名：权限无关的网络信息 —— 图是从哪个域名拉的。
   * 本机/无 scheme 的路径取不到就返回空串（这一段省略）。
   */
  private currentHostLabel(): string {
    if (this.offlineOnlyLocal) {
      return '本机图片';
    }
    if (this.currentIndex < 0 || this.currentIndex >= this.urls.length) {
      return '';
    }
    const url = this.currentUrl(this.currentIndex, this.urls[this.currentIndex]);
    const scheme = url.indexOf('://');
    if (scheme < 0) {
      return '';
    }
    const rest = url.substring(scheme + 3);
    let end = rest.length;
    const slash = rest.indexOf('/');
    const quest = rest.indexOf('?');
    const hash = rest.indexOf('#');
    if (slash >= 0 && slash < end) {
      end = slash;
    }
    if (quest >= 0 && quest < end) {
      end = quest;
    }
    if (hash >= 0 && hash < end) {
      end = hash;
    }
    const host = rest.substring(0, end);
    if (host.length === 0) {
      return '';
    }
    return host.length > 32 ? host.substring(0, 32) + '…' : host;
  }

  /**
   * 下行速率估算：`statistics.getAllRxBytes()` 两次采样差分 ÷ 时间。
   *
   * 这是**设备全局**、开机以来的累计字节差分（含其它应用、所有网卡），不是本应用的网速，
   * 所以文案里标成「全机↓」。取不到（异常/不支持）就整段省略，不猜一个数出来。
   */
  private async downlinkLabel(): Promise<string> {
    if (this.netStatsUnavailable) {
      return '';
    }
    try {
      const bytes = await statistics.getAllRxBytes();
      const now = Date.now();
      let label = '';
      if (this.rxLastBytes >= 0 && this.rxLastAt > 0 && bytes >= this.rxLastBytes) {
        const seconds = (now - this.rxLastAt) / 1000;
        if (seconds >= 1) {
          label = '全机↓' + formatBytesPerSecond((bytes - this.rxLastBytes) / seconds);
        }
      }
      this.rxLastBytes = bytes;
      this.rxLastAt = now;
      return label;
    } catch (error) {
      this.netStatsUnavailable = true;
      const be = error as BusinessError;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '胶囊：吞吐采样取不到 code=' + be.code + ' ' + be.message + '（此后不再重试）');
      }
      return '';
    }
  }

  private goPrevious(): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      'goPrevious idx=' + this.currentIndex + ' 总数=' + this.urls.length);
    }
    if (this.urls.length === 0) {
      return;
    }
    if (this.isWebtoon()) {
      if (this.currentIndex <= 0 && this.webtoonAtStartEdge()) {
        this.handleChapterEdge(false, 'swipe');
        return;
      }
      this.listScrollToIndex(this.currentIndex - 1);
      return;
    }
    if (this.currentIndex <= 0) {
      // 首页继续往回翻 → 二次确认切上一章
      this.handleChapterEdge(false, 'tap');
      return;
    }
    this.swiperController.showPrevious();
  }

  private goNext(): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      'goNext idx=' + this.currentIndex + ' 总数=' + this.urls.length);
    }
    if (this.urls.length === 0) {
      return;
    }
    if (this.isWebtoon()) {
      if (this.currentIndex >= this.readerPageCount() - 1) {
        this.handleChapterEdge(true, 'swipe');
        return;
      }
      this.listScrollToIndex(this.currentIndex + 1);
      return;
    }
    if (this.currentIndex >= this.readerPageCount() - 1) {
      // 末页（含章末吐槽页）继续翻 → 二次确认切下一章
      this.handleChapterEdge(true, 'tap');
      return;
    }
    this.swiperController.showNext();
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  private pageCounter(): string {
    if (this.onCommentPage()) {
      // 页码胶囊/顶栏计数器在章末吐槽页统一显示"吐槽"（对齐 Flutter `_onCommentPage`）
      return '吐槽';
    }
    const total = this.activeChapterSize > 0 ? this.activeChapterSize : this.urls.length;
    return (this.currentIndex + 1) + ' / ' + total;
  }

  /**
   * 章末吐槽数据：进入吐槽页时才拉取（对齐 Flutter CommentPage 的懒加载语义）。
   * 回调同时受 commentRevision（同章去重）与 chapterGeneration（切章作废）保护。
   */
  private ensureCommentsLoaded(): void {
    if (!this.chapterEndCommentsEnabled || this.activeChapterId.length === 0) {
      return;
    }
    if (this.commentState !== BrowseLoadState.Idle) {
      return;
    }
    const chapterId = this.activeChapterId;
    const generation = this.chapterGeneration;
    const revision = ++this.commentRevision;
    this.commentState = BrowseLoadState.Loading;
    this.commentErrorText = '';
    this.commentsSkipReason = '';
    this.loadCommentsByReachability(chapterId, generation, revision);
  }

  /**
   * 判据从「离线入口」改为「网络可达性」：有网就加载吐槽（哪怕从「我的下载」离线入口进来），
   * 明确没网才跳过。
   *
   * 可达性走 NetStatus 的 TTL 缓存 + in-flight 合并，这里只读缓存值，不会每章裸发探测；
   * 未知（null，探测没跑完/异常）按「当作有网」保守处理——绝不把"没测出来"误判成"无网络"。
   */
  private async loadCommentsByReachability(chapterId: string, generation: number, revision: number): Promise<void> {
    const reachable = await netStatus.reachable();
    if (revision !== this.commentRevision || generation !== this.chapterGeneration) {
      return;
    }
    if (reachable === false) {
      // 明确不可达：跳过并给出占位原因，UI 只读这个字段
      this.commentState = BrowseLoadState.Empty;
      this.commentsSkipReason = '无网络，不加载吐槽';
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', '章末吐槽：无网络，跳过 ' + chapterId);
      }
      return;
    }
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '章末吐槽：开始读取 ' + chapterId);
    }
    this.fetchComments(chapterId, generation, revision);
  }

  /** 实际取评论：结果按 revision（同章去重）+ chapterGeneration（切章作废）双重校验后才落状态。 */
  private async fetchComments(chapterId: string, generation: number, revision: number): Promise<void> {
    try {
      const source = await getBrowseSource();
      const list = await source.chapterComments(chapterId);
      if (revision !== this.commentRevision || generation !== this.chapterGeneration) {
        return;
      }
      this.comments = list;
      this.commentState = list.length === 0 ? BrowseLoadState.Empty : BrowseLoadState.Content;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '章末吐槽：完成 ' + chapterId + ' 共' + list.length + '条');
      }
    } catch (error) {
      if (revision !== this.commentRevision || generation !== this.chapterGeneration) {
        return;
      }
      this.commentErrorText = describeBrowseError(error as Object);
      this.commentState = BrowseLoadState.Error;
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s',
        '章末吐槽：失败 ' + chapterId + ' ' + this.commentErrorText);
      }
    }
  }

  /** 吐槽页内"重试"按钮：回到 Idle 再走一次统一入口。 */
  private retryComments(): void {
    this.commentState = BrowseLoadState.Idle;
    this.commentErrorText = '';
    this.commentsSkipReason = '';
    this.ensureCommentsLoaded();
  }

  /**
   * 从章末吐槽页退回本章最后一张图（goToCommentPage 的逆操作）。
   * 返回 true 表示"消费"了这次返回：顶栏返回键 / 系统返回都据此决定是否真的退出阅读器。
   */
  private leaveCommentPage(): boolean {
    if (!this.onCommentPage() || this.urls.length === 0) {
      return false;
    }
    // 回到"进入吐槽页前所在的阅读页"（与进度保存共用同一来源：从哪来、回哪去）
    const target = this.readingIndex();
    this.restorePending = false;
    if (this.isWebtoon()) {
      if (this.listScrollToIndex(target)) {
        this.currentIndex = target;
      } else {
        this.restoreTarget = target;
        this.restorePending = true;
        this.restoreAttempts = 0;
      }
    } else {
      this.swiperController.changeIndex(target, true);
      this.currentIndex = target;
    }
    this.resetEdgeGuard();
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '从章末吐槽页返回阅读器');
    }
    return true;
  }

  /** 顶栏吐槽按钮：直接跳到本章的章末吐槽页（设置关闭时只给提示）。 */
  private goToCommentPage(): void {
    if (!this.showCommentPage()) {
      this.showToast(this.chapterEndCommentsEnabled ? '这一章暂时没有吐槽页' : '章末吐槽已在设置中关闭');
      return;
    }
    const target = this.urls.length;
    // 记住进入吐槽页前的阅读页：返回时回到那一页（readingIndex() 的 lastImageIndex 来源之一）
    if (this.currentIndex >= 0 && this.currentIndex < this.urls.length) {
      this.lastImageIndex = this.currentIndex;
    }
    this.restorePending = false;
    if (this.isWebtoon()) {
      if (this.listScrollToIndex(target)) {
        this.currentIndex = target;
      } else {
        // 容器还没就位：交给既有的恢复链（restoreProgressOnce）继续尝试
        this.restoreTarget = target;
        this.restorePending = true;
        this.restoreAttempts = 0;
      }
    } else {
      this.swiperController.changeIndex(target, true);
      this.currentIndex = target;
    }
    this.resetEdgeGuard();
    this.ensureCommentsLoaded();
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '跳转到章末吐槽页');
    }
  }

  /**
   * 章末吐槽**页面**（页面级，不是浮层）：横/纵作为最后一个 Swiper 页，
   * 条漫作为列表最后一个 item；数据与样式参考 CommentPanel。
   */
  /**
   * 章末吐槽页内容渐显：该页是 Swiper/List 的一页（页面转场由滑页动作承担），
   * 到位后给内容补一层 200ms 淡入，避免"突然整页出现"。
   */
  private playCommentPageEnter(): void {
    this.commentPageOpacity = 0;
    if (this.commentFadeTimer >= 0) {
      clearTimeout(this.commentFadeTimer);
    }
    this.commentFadeTimer = setTimeout(() => {
      this.commentFadeTimer = -1;
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.commentPageOpacity = 1;
      });
    }, 30);
  }

  @Builder
  private commentPageBody() {
    Column() {
      Column({ space: 4 }) {
        Text('本章吐槽')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.activeChapterName.length > 0 ? '读完啦，看看大家怎么说 · ' + this.activeChapterName :
          '读完啦，看看大家怎么说')
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.commentState === BrowseLoadState.Content) {
          Text(this.comments.length + ' 条吐槽')
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 18, right: 18, top: 26, bottom: 12 })

      if (this.commentState === BrowseLoadState.Content) {
        List({ space: 10 }) {
          ForEach(this.comments, (item: Comment, index: number) => {
            ListItem() {
              ReaderCommentRow({ item: item })
            }
          }, (item: Comment, index: number) => item.id + ':' + index.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 4, bottom: 48 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      } else if (this.commentState === BrowseLoadState.Loading) {
        Column({ space: 14 }) {
          LoadingProgress()
            .width(38)
            .height(38)
            .color($r('app.color.primary'))
          Text('正在读取吐槽…')
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else if (this.commentState === BrowseLoadState.Error) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(34)
            .fontColor([$r('app.color.accent')])
          Text('吐槽加载失败')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.commentErrorText)
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
            .textAlign(TextAlign.Center)
            .maxLines(3)
          Button('重试')
            .type(ButtonType.Normal)
            .height(40)
            .padding({ left: 24, right: 24 })
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .borderRadius(14)
            .onClick(() => this.retryComments())
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding(24)
      } else {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.doc_text'))
            .fontSize(34)
            .fontColor([$r('app.color.secondary_text')])
          Text(this.commentsSkipReason.length > 0 ? this.commentsSkipReason : '还没有吐槽')
            .fontSize(16)
            .fontColor($r('app.color.secondary_text'))
          if (this.commentsSkipReason.length === 0) {
            Text('这里暂时没有可显示的内容')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
          }
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    // 吐槽页内容渐显：页面本体是 Swiper/List 的一页（转场由滑页承担），这里给内容补一层 200ms 淡入
    .opacity(this.commentPageOpacity)
    .onAppear(() => this.ensureCommentsLoaded())
  }

  /** 打开跳页输入（常显页码胶囊的点击入口）：输入框预填当前页，直接点「跳转」＝原地不动。 */
  private openJumpDialog(): void {
    this.jumpText = this.currentPageOneBased().toString();
    this.jumpVisible = true;
    // 第①拍：此刻输入框还没挂载，这次大概率返回 false，只是尽早声明意图
    this.requestJumpFocus('打开');
    // 第②拍（延时兜底）：浮层上屏与焦点链重建晚于 onAppear，120ms 后再请求一次，
    // 覆盖「defaultFocus / onAppear 都赶在挂载时序之前」的情况；浮层已关则不发。
    if (this.jumpFocusTimer >= 0) {
      clearTimeout(this.jumpFocusTimer);
    }
    this.jumpFocusTimer = setTimeout((): void => {
      this.jumpFocusTimer = -1;
      if (this.jumpVisible) {
        this.requestJumpFocus('延时120ms');
      }
    }, JUMP_FOCUS_RETRY_MS);
  }

  /**
   * 请求跳页输入框焦点（三段式里的"那一跳"），并把结果打进 Collector 日志。
   *
   * 优先用**实例绑定**的 FocusController（`UIContext.getFocusController()`：立即生效，且避开
   * "全局 focusControl 可能指到别的 UIContext"的坑）；抛错就退回全局 `focusControl.requestFocus`
   * （下一帧生效）再试一次，两者的结论合打一行。
   *
   * 日志判读：三拍都失败（150001/150002/150003）→ 焦点链被拦，看 code 定位；
   * 有"ok"却仍无键盘 → 焦点没问题，问题在输入法/窗口侧。
   */
  private requestJumpFocus(stage: string): void {
    let detail: string;
    try {
      this.getUIContext().getFocusController().requestFocus(JUMP_INPUT_ID);
      detail = 'UIContext=ok';
    } catch (error) {
      const be = error as BusinessError;
      const ok = focusControl.requestFocus(JUMP_INPUT_ID);
      detail = 'UIContext失败 code=' + be.code + ' ' + be.message + ' → 全局=' + (ok ? '1' : '0');
    }
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s', '跳页焦点 ' + stage + ' ' + detail);
    }
  }

  /** 跳页：1-based 输入 → clamp → 两套容器各自定位，并落盘进度。 */
  private doJumpPage(): void {
    this.jumpVisible = false;
    const total = this.urls.length;
    if (total === 0) {
      return;
    }
    const n = Number.parseInt(this.jumpText, 10);
    if (Number.isNaN(n)) {
      return;
    }
    if (n < 1 || n > total) {
      // 越界轻提示：仍按边界落地，但明确告诉用户输入超了范围
      this.showToast('页码超出范围（' + this.jumpRangeLabel() + '）');
    }
    this.jumpText = '';
    this.jumpToIndex(n - 1);
  }

  /**
   * 跳到第 target 页（0-based）：跳页框与页码滑杆共用同一套落位 + 落盘逻辑。
   * 两套容器各自定位；落位后记 lastImageIndex（与 readingIndex() 单一来源配合）并立即写盘。
   */
  private jumpToIndex(target: number): void {
    const total = this.urls.length;
    if (total === 0) {
      return;
    }
    let index = target;
    if (index < 0) {
      index = 0;
    }
    if (index > total - 1) {
      index = total - 1;
    }
    this.restorePending = false;
    if (this.isWebtoon()) {
      if (this.listScrollToIndex(index)) {
        this.currentIndex = index;
      } else {
        // 容器/高度尚未就位：交给既有的恢复重试链继续尝试
        this.restoreTarget = index;
        this.restorePending = true;
        this.restoreAttempts = 0;
      }
    } else {
      this.swiperController.changeIndex(index, true);
      this.currentIndex = index;
    }
    if (this.currentIndex >= 0 && this.currentIndex < this.urls.length) {
      // 跳页目标也是"阅读位置"：记入 lastImageIndex（与 readingIndex() 单一来源配合）
      this.lastImageIndex = this.currentIndex;
    }
    this.saveProgress(index);
  }

  /**
   * 当前页（1-based，恒落在图片页范围）：滑杆显示值与跳页框预填值都取它。
   * 停在章末吐槽页时回落到最后一张图 —— 滑杆的 max 就是图片数，不含吐槽页。
   */
  private currentPageOneBased(): number {
    const total = this.urls.length;
    if (total <= 0) {
      return 1;
    }
    const value = this.currentIndex + 1;
    if (value < 1) {
      return 1;
    }
    return value > total ? total : value;
  }

  /** 跳页范围文案（placeholder 与越界提示共用）：`1 - 图片数`。 */
  private jumpRangeLabel(): string {
    const total = this.urls.length;
    return '1 - ' + (total > 0 ? total : 1).toString();
  }

  /**
   * 页码滑杆拖动 → 跳页：与胶囊跳页同逻辑（同一个 jumpToIndex，落位 + 落盘）。
   * 拖动过程中每拍都落位，手感与 Flutter Slider.onChanged → _jumpTo 一致；不做二次确认。
   */
  private onSliderChange(value: number): void {
    if (this.urls.length === 0) {
      return;
    }
    const target = Math.round(value) - 1;
    if (target === this.currentIndex) {
      return;
    }
    this.jumpToIndex(target);
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'Collector', '%{public}s',
      '滑杆跳页 → 第' + (target + 1).toString() + '页 共' + this.urls.length + '页');
    }
  }

  /** 横/纵分页：一次一页，点击分区翻页（条漫不走这里）。 */
  @Builder
  private buildPagedSwiper() {
    Swiper(this.swiperController) {
      LazyForEach(this.dataSource, (item: ReaderPageItem) => {
        Stack({ alignContent: Alignment.Center }) {
          if (item.isComment === true) {
            // 章末吐槽虚拟页：数据源的最后一页（Swiper 天然多一页可翻）
            this.commentPageBody()
          } else {
          Image(this.reloadUrl(item.index, item.url))
            // 不再挂 alt：加载期透出下面的 page_background（主题色，亮/暗/AMOLED 自动对应），
            // 避免"闪一下占位图"。失败可发现性由下方 isPageFailed 的重试胶囊负责。
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .onComplete((event?: ReaderImageSize) => {
              if (event !== undefined && event !== null && event.width > 0 && event.height > 0) {
                this.imageSizes.set(this.currentUrl(item.index, item.url),
                  { width: event.width, height: event.height });
              }
              this.onReloadSucceeded(item.index);
            })
            // 取证：区分「URL 本身坏」与「首帧加载失败」
            .onError((error: ImageError) => {
              // 换扩展名重试一次：网页收图有 .png.c1500x.webp 404，而同图 .c1500x.jpg 可用
              if (this.retryWithSwappedExtension(item.index, item.url)) {
                return;
              }
              if (error === undefined || error === null) {
                if (COLLECTOR_LOG_ENABLED) {
                  hilog.info(
                  0x0000,
                  'Collector',
                  '%{public}s',
                  '图片加载失败 第' + item.page + '页 url=' + truncateUrl(item.url)
                );
                }
              } else {
                const code = error.error !== undefined && error.error !== null ?
                  String(error.error.code) : '无错误码';
                const message = error.message !== undefined && error.message.length > 0 ?
                  error.message : '无错误信息';
                if (COLLECTOR_LOG_ENABLED) {
                  hilog.info(
                  0x0000,
                  'Collector',
                  '%{public}s',
                  '图片加载失败 第' + item.page + '页 code=' + code +
                  ' message=' + message + ' url=' + truncateUrl(item.url)
                );
                }
              }
              this.onReloadFailed(item.index);
            })

          // 失败态：轻量提示 + 点击重载。不铺满、不遮图内容（居中偏下的小胶囊）
          if (this.isPageFailed(item.index)) {
            Column({ space: 6 }) {
              if (this.isPageReloading(item.index)) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color($r('app.color.primary'))
                Text('正在重载…')
                  .fontSize(12)
                  .fontColor($r('app.color.secondary_text'))
              } else {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(18)
                  .fontColor([$r('app.color.primary')])
                Text('加载失败，点击重载')
                  .fontSize(12)
                  .fontColor($r('app.color.primary_text'))
              }
            }
            .justifyContent(FlexAlign.Center)
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor($r('app.color.nav_surface'))
            .borderRadius(16)
            .onClick(() => this.reloadPage(item.index))
          }
          }
        }
        .width('100%')
        .height('100%')
        // direction 会继承 Swiper 的 RTL：**页内容本身显式锁回 Ltr**，
        // 否则吐槽页的 HorizontalAlign.Start / 内部 Row 会被整体镜像（漫画图是 Center + Contain，无感）。
        // 这里只管子树布局，不影响 Swiper 的手势与翻页动画镜像。
        .direction(Direction.Ltr)
        // ⚠️ 变换**不**挂在这里（每页）：挂在 Swiper 的 item 上会吃掉 Swiper 的横向拖动识别
        //    （表现为 1× 也滑不动页）。现统一挂到分页容器上（见本 Builder 末尾的 .transform）。
      }, (item: ReaderPageItem) => item.key + ':' + this.dataSource.reloadCount(item.index).toString())
    }
    .index(this.currentIndex)
    // 缓存窗口＝当前页 ±SWIPER_CACHED_COUNT（官方一屏一页的连续滑动推荐 1~2）。
    // 与 preloadItems 的下标范围**共用**同一个常量：预载下标必须落在缓存范围内，否则 LazyForEach 会把节点销毁。
    .cachedCount(SWIPER_CACHED_COUNT)
    .indicator(false)
    .loop(false)
    .vertical(this.readMode === READ_MODE_V)
    // 阅读方向：**只在横向**开 RTL（左开本）。Swiper 的手势/翻页动画/循环与指示器会整体镜像，
    // showNext/showPrevious 的语义不变（仍是"数据序的下一页/上一页"），index 也不倒序。
    // 纵向与条漫恒为 Ltr（条漫根本不走这个 Builder）。
    .direction(this.readLeftMode && this.readMode === READ_MODE_H ? Direction.Rtl : Direction.Ltr)
    // 捏合中 / 已放大时禁止翻页：把拖动手势完整交给缩放平移
    .disableSwipe(this.zoomLocked())
    // 翻页动效＝**官方默认弹簧** interpolatingSpring(-1, 1, 328, 34)（ts-container-swiper「curve 默认值」）。
    // 弹簧类曲线不受 duration 控制（写了 duration 也无效），所以这里**刻意不写** .curve/.duration：
    // 之前覆盖成 .duration(200) + .curve(Curve.EaseOut) 是固定时长曲线，跟手阶段与离手速度都吃不到，
    // 观感发闷、每页都一样快，正是"翻页动效有点卡"的来源。删掉覆盖即回到默认弹簧（跟手 + 继承手速 + 自然时长）。
    // 顺带避免为显式弹簧引入 curves.interpolatingSpring，零依赖优先。
    .effectMode(EdgeEffect.None)
    // 首次预载：官方明确 preloadItems 必须在 Swiper 创建之后调用、首次放 onAppear
    .onAppear(() => {
      this.preloadNeighborPages(this.currentIndex);
    })
    // 离手起播的那段时间动画跑在渲染线程，主线程正好空闲 —— 官方最佳实践的"提前加载数据"时机，
    // 用目标页做基准把即将进入 cachedCount 窗口的邻页先建好。跟手拖动阶段不触发本回调（缓存窗口本身已在跟）。
    .onAnimationStart((_index: number, targetIndex: number, _extraInfo: SwiperAnimationEvent) => {
      this.preloadNeighborPages(targetIndex);
    })
    .onChange((index: number) => {
      // ⚠️ 官方禁令：Swiper 结合 LazyForEach 时，不能在 onChange 里触发**子页面** UI 的刷新。
      // 审查结论：本回调只写 currentIndex（顶栏页码胶囊/点击分区/进度等读它），
      // 页内容（LazyForEach 的 Image Stack）读的是 item.index / item.url / failedPages / retryRevision，
      // 没有任何一处读 currentIndex → 换页不会重建页节点；下方各步也都是私有字段或异步落盘。
      if (COLLECTOR_LOG_ENABLED) {
        hilog.info(0x0000, 'Collector', '%{public}s', 'Swiper onChange → ' + index);
      }
      const changed = index !== this.currentIndex;
      this.currentIndex = index;
      if (index >= 0 && index < this.urls.length) {
        // 记录最后一张图片页：停在吐槽页时 readingIndex() 用它回退（进度/返回共用同一来源）
        this.lastImageIndex = index;
      }
      // 换页就还原缩放：放大态不能带进下一页（1x 时是纯私有字段写，不产生 UI 更新）
      this.resetZoom();
      if (changed) {
        // 离开边界/换了页：解除"到头二次确认"武装（对齐 Flutter pageChanged → reset）
        this.resetEdgeGuard();
      }
      if (this.restorePending && index !== this.restoreTarget) {
        this.restorePending = false;
      }
      // 异步落盘，不占本帧；不写任何 @Local
      this.saveProgress(this.readingIndex());
      if (index >= this.urls.length) {
        // 已滑到章末吐槽页：此时才拉取评论。
        // 通常这里已是空转（吐槽页 item 在 cachedCount 窗口里时 commentPageBody.onAppear 就先拉过了），
        // 保留它只是兜底；即便真的首次触发，也只影响吐槽页这一个子树，不碰漫画页。
        this.ensureCommentsLoaded();
        this.playCommentPageEnter();
      }
      // 80% 预取：同步段只置 prefetchRequested 私有位，真正取图/挂预热层在异步回调里，不在本帧
      this.maybePrefetchNext();
      // 预载不在 onChange 做（见上方禁令）：换页后的邻页预载由 onAnimationStart / onAnimationEnd 承接
    })
    .onAnimationEnd((_index: number, _extraInfo: SwiperAnimationEvent) => {
      // 首帧/首次动画结束后恢复断点，不依赖定时器
      this.restoreProgressOnce();
      // 落位后补一轮邻页预载：此刻缓存窗口＝最终页 ±SWIPER_CACHED_COUNT，图片页下标全部落在窗口内，
      // 下一次翻页要的页已经建好（onAnimationStart 阶段窗口还挂在旧页上，最远那一格会被裁掉）。
      this.preloadNeighborPages(this.currentIndex);
    })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width as number;
      const h = newArea.height as number;
      if (w > 0 && h > 0) {
        if (w !== this.viewportWidth) {
          this.viewportWidth = w;
        }
        if (h !== this.viewportHeight) {
          this.viewportHeight = h;
        }
        if (w !== this.contentWidth) {
          this.contentWidth = w;
        }
      }
      this.restoreProgressOnce();
      // 首次进入时让顶栏短暂浮出，提升入口可发现性（三模式统一）
      this.armIntroBars();
    })
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    // 手势仲裁：缩放层在最上，未放大时把单指滑动透传给 Swiper
    .onTouch((event: TouchEvent) => this.onReaderTouch(event))
    // 变换挂在**容器**上（与条漫一致）。A/B 已证实：滑动失败与 transform 无关（去掉同样失败）。
    .transform(this.zoomTransform())
    // ⚠️ 这里**不要**加 .clip(true)：变换容器上的 clip 会按未变换边界裁掉放大后的内容（见分页页 Stack 处注释）。
  }

  /**
   * 条漫的缩放容器：把 transform 限制在**视口尺寸**的盒子里再应用到整条 List。
   *
   * 之前 transform 直接挂在 List 上：List 的内容高度是视口的十几到几十倍
   * （20 张 × 1200vp ≈ 24000vp vs 视口 800vp），缩放轴心在内容原点，
   * 而 clampOffset 只按**视口**算允许范围（[-(s-1)*视口, 0]），
   * 远小于把当前可视区域钉住所需的偏移 → 内容被强行拉回、可见放大倍率明显变小，
   * 观感就是"条漫缩放没横/纵给力"。
   *
   * 这里改用一个与视口同高的 Stack 承载 List 并施加 transform：
   * 变换盒子与 clampOffset 的尺寸基准一致，倍率与横/纵完全对齐。
   */
  @Builder
  private buildWebtoon() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.webtoonList();
    }
    .width('100%')
    .height('100%')
    // 显式铺主题背景：条漫的 Image 不带 alt（去占位图闪动），加载期要靠这层底色透出亮/暗/AMOLED 背景
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    // ⚠️ 这里**不要**加 .clip(true)：会把放大后超出视口的内容裁掉（同分页页 Stack 处的注释）
    .onTouch((event: TouchEvent) => this.onReaderTouch(event))
    .transform(this.zoomTransform())
  }

  /** 条漫：连续纵向滚动，item 高度按缓存宽高比锁定（见 webtoonItemHeight）。 */
  @Builder
  private webtoonList() {
    List({ scroller: this.listScroller }) {
      LazyForEach(this.dataSource, (item: ReaderPageItem) => {
        ListItem() {
          if (item.isComment === true) {
            // 章末吐槽虚拟页：列表最后一个 item，高度锁定为一屏（保证"物理尽头"可判定）
            Stack({ alignContent: Alignment.TopStart }) {
              this.commentPageBody()
            }
            .width('100%')
            .height(this.viewportHeight > 0 ? this.viewportHeight : '100%')
          } else {
          Stack({ alignContent: Alignment.Center }) {
            Image(this.reloadUrl(item.index, item.url))
              // 同分页：去掉 alt，加载期透出主题 page_background，不闪占位图
              .width('100%')
              .height(this.webtoonItemHeight(item.index, item.url))
              .objectFit(ImageFit.Fill)
              // 条漫禁用点击分区翻页：连续滚动里点一下很容易被误判成翻页
              .onComplete((event?: ReaderImageSize) => {
                // 学到真实宽高比后锁定：加载/回收/重下期间高度都不再变化
                if (event !== undefined && event !== null && event.width > 0 && event.height > 0) {
                  this.learnAspect(item.url, event.width, event.height);
                  this.imageSizes.set(item.url, { width: event.width, height: event.height });
                }
                this.onReloadSucceeded(item.index);
              })
              .onError((error: ImageError) => {
                if (this.retryWithSwappedExtension(item.index, item.url)) {
                  return;
                }
                const message = (error !== undefined && error !== null &&
                  error.message !== undefined && error.message.length > 0) ?
                  error.message : '无错误信息';
                if (COLLECTOR_LOG_ENABLED) {
                  hilog.info(
                  0x0000,
                  'Collector',
                  '%{public}s',
                  '图片加载失败 第' + item.page + '页 message=' + message +
                  ' url=' + truncateUrl(item.url)
                );
                }
                this.onReloadFailed(item.index);
              })

            // 条漫同样支持手动重载：点击该 item 的提示胶囊即可
            if (this.isPageFailed(item.index)) {
              Column({ space: 6 }) {
                if (this.isPageReloading(item.index)) {
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .color($r('app.color.primary'))
                  Text('正在重载…')
                    .fontSize(12)
                    .fontColor($r('app.color.secondary_text'))
                } else {
                  SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                    .fontSize(18)
                    .fontColor([$r('app.color.primary')])
                  Text('加载失败，点击重载')
                    .fontSize(12)
                    .fontColor($r('app.color.primary_text'))
                }
              }
              .justifyContent(FlexAlign.Center)
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .backgroundColor($r('app.color.nav_surface'))
              .borderRadius(16)
              .onClick(() => this.reloadPage(item.index))
            }
          }
          .width('100%')
          }
        }
        .width('100%')
        // 条漫轻点走独立判定：List 会吃掉通用手势路径的 Up 事件
        .onTouch((event: TouchEvent) => this.onWebtoonItemTouch(event, item.index))
      }, (item: ReaderPageItem) => item.key + ':' + this.dataSource.reloadCount(item.index).toString())
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    // 条漫整章长图解码后单张可达 20–40MB，缓存窗口刻意压到 3
    .cachedCount(3)
    .edgeEffect(EdgeEffect.None)
    .scrollBar(BarState.Off)
    .onScrollIndex((start: number, _end: number, _center: number) => {
      if (start >= 0 && start !== this.currentIndex) {
        this.currentIndex = start;
        if (start < this.urls.length) {
          // 记录最后一张图片页（同 Swiper onChange）
          this.lastImageIndex = start;
        }
        // 换到别的 item：解除"到头二次确认"武装（对齐 Flutter pageChanged → reset）
        this.resetEdgeGuard();
        // 恢复中：只有真的到达目标页才算完成；绝不能在恢复途中把中间位置写盘
        // （否则进条漫的首次落位 0 会把断点冲成 0，恢复任务也会被误判结束）
        if (this.restorePending) {
          if (start === this.restoreTarget) {
            this.restorePending = false;
          } else if (this.webtoonUserScrolled) {
            // 用户已经自己滑起来了：不再把人拉回断点（断点只负责"没人动过"的首次落位），
            // 就地按当前位置落盘并结束恢复任务。挂载那次 start=0 不会走到这里 ——
            // 那会儿还没有任何手指滑出轻点容差，webtoonUserScrolled 仍是 false。
            this.restorePending = false;
            this.restoreAttempts = 0;
            if (COLLECTOR_LOG_ENABLED) {
              hilog.info(0x0000, 'Collector', '%{public}s',
              '条漫断点 放弃拉回 start=' + start + ' 目标=' + this.restoreTarget +
              ' 改记进度页=' + (this.readingIndex() + 1));
            }
            this.saveProgress(this.readingIndex());
          }
        } else {
          this.saveProgress(this.readingIndex());
        }
        if (start >= this.urls.length) {
          // 已滑到章末吐槽页：此时才拉取评论
          this.ensureCommentsLoaded();
          this.playCommentPageEnter();
        }
        this.maybePrefetchNext();
      }
    })
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w = newArea.width as number;
      const h = newArea.height as number;
      if (w > 0 && h > 0) {
        if (w !== this.viewportWidth) {
          this.viewportWidth = w;
        }
        if (h !== this.viewportHeight) {
          this.viewportHeight = h;
        }
        if (w !== this.contentWidth) {
          this.contentWidth = w;
        }
      }
      this.restoreProgressOnce();
      // 首次进入时让顶栏短暂浮出，提升入口可发现性（三模式统一）
      this.armIntroBars();
    })
    // 手势仲裁：捏合中 / 已放大时锁滚动，避免和纵向滚动打架
    .enableScrollInteraction(!this.zoomLocked())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 下一章预热层（80% 预取的"前几页"）：全尺寸 + 极低透明度挂载，
      // 让 ArkUI 真正发起取图与解码（不能用 opacity(0)/visibility，那会跳过解码）。
      // 放在最底层：上面各层都有不透明底色，实际看不见；也不参与命中测试。
      if (this.prewarmUrls.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          ForEach(this.prewarmUrls, (url: string, index: number) => {
            Image(url)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
          }, (url: string, index: number) => url + ':' + index.toString())
        }
        .width('100%')
        .height('100%')
        .opacity(0.01)
        .hitTestBehavior(HitTestMode.None)
      }

      // 预载层：与正式显示完全同尺寸/同 objectFit 的 Image，仅用于触发解码并回报 onComplete / onError；
      // 不使用极小尺寸、visibility 或 opacity(0) 之类会改变解码/缓存行为的做法。
      if (this.loadState !== ReaderLoadState.Content && this.urls.length > 0) {
        Swiper() {
          LazyForEach(this.dataSource, (item: ReaderPageItem) => {
            Stack({ alignContent: Alignment.Center }) {
              Image(this.currentUrl(item.index, item.url))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .onComplete(() => {
                  this.loadedPages.add(item.index);
                  this.maybeEnterContent();
                })
                .onError(() => {
                  // 预载门阶段也尝试换扩展名一次，避免把「.webp 404」误判成首帧不可用
                  if (this.retryWithSwappedExtension(item.index, item.url)) {
                    return;
                  }
                  this.noteGateError(item.index);
                })
            }
            .width('100%')
            .height('100%')
          }, (item: ReaderPageItem) => item.key)
        }
        .index(this.gateIndex)
        .cachedCount(3)
        .indicator(false)
        .loop(false)
        .vertical(false)
        .duration(0)
        .width('100%')
        .height('100%')
        .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
      }

      if (this.loadState === ReaderLoadState.Content) {
        if (this.isWebtoon()) {
          this.buildWebtoon();
        } else {
          this.buildPagedSwiper();
        }

        if (this.collecting || this.collectionNote.length > 0) {
          Row({ space: 8 }) {
            if (this.collecting) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.primary'))
            }
            Text(this.collecting ? '仍在加载更多…' : this.collectionNote)
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
          }
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(16)
          .margin({ left: 16, bottom: 16 })
          .hitTestBehavior(HitTestMode.None)
        }

        if (this.toolbarShown()) {
          // 父容器是 Stack({ alignContent: Alignment.TopStart })：同级子节点按 TopStart 叠放。
          // 旧实现把顶栏 Row 与其下的信息行都当成 Stack 的直接子节点 —— 两块都从 y=0 开始铺开，
          // 信息行因此压在顶栏正文（"第XX话"字样）上面，这就是盖字的根因。
          // 修复：用 Column 把「顶栏 + 信息行」收进同一个布局流，顶栏在上、信息行在下顺序排布，
          // 两块各带同色底、无缝拼接，谁也不覆盖谁。
          // 验收点：顶栏展开时左侧章节名（第XX话）完整可见，信息行不压任何文字、只往下长。
          Column() {
            Row({ space: 10 }) {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(21)
                  .fontColor([$r('app.color.primary_text')])
              }
              .width(44)
              .height(44)
              .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
              // 吐槽页上的返回先退回最后一张图；否则正常退出阅读器
              .onClick(() => {
                if (!this.leaveCommentPage()) {
                  this.onExit();
                }
              })

              Column({ space: 2 }) {
                Text(this.activeChapterName.length > 0 ? this.activeChapterName : '章节')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.primary_text'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.pageCounter())
                  .fontSize(12)
                  .fontColor($r('app.color.secondary_text'))
                // 条漫首次浮出时附一条提示，说明顶栏是可呼出的
                if (this.introHint.length > 0) {
                  Text(this.introHint)
                    .fontSize(11)
                    .fontColor($r('app.color.secondary_text'))
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              // 阅读模式快捷切换：横向 → 纵向 → 条漫，切完立即生效并写回设置
              Button({ type: ButtonType.Normal, stateEffect: true }) {
                Row({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.more'))
                    .fontSize(16)
                    .fontColor([$r('app.color.primary')])
                  Text(this.modeLabel())
                    .fontSize(13)
                    .fontColor($r('app.color.primary'))
                }
                .padding({ left: 10, right: 10 })
              }
              .height(36)
              .borderRadius(18)
              .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
              .onClick(() => this.cycleReadMode())

              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.message'))
                  .fontSize(19)
                  .fontColor([$r('app.color.primary')])
              }
              .width(44)
              .height(44)
              .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
              // 吐槽按钮在吐槽页上变为"返回阅读器"
              .onClick(() => {
                if (!this.leaveCommentPage()) {
                  this.goToCommentPage();
                }
              })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))

            // 第二行：上一章 | 页码滑杆 | 下一章（对齐 Flutter 底栏的同一排）
            Row({ space: 8 }) {
              Button('上一章')
                .type(ButtonType.Normal)
                .stateEffect(true)
                .height(32)
                .padding({ left: 12, right: 12 })
                .borderRadius(16)
                .fontSize(13)
                .fontColor($r('app.color.primary'))
                .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
                // 直接切章、无二次确认；没有相邻章时 switchChapter 内部提示「已经到头了~」
                .onClick(() => this.switchChapter(false, 'toolbar'))

              if (this.urls.length > 1) {
                Slider({
                  // 1-based 当前页；翻页/跳页后由 currentPageOneBased() 自动同步回来
                  value: this.currentPageOneBased(),
                  min: 1,
                  // max = 图片数（不含章末吐槽页）
                  max: this.urls.length,
                  // ArkUI 的 Slider 没有 divisions 属性：step=1 就是 count-1 个整数间隔，
                  // 量化结果与 Flutter `divisions: count - 1` 一致
                  step: 1
                })
                  .layoutWeight(1)
                  .blockColor($r('app.color.primary'))
                  .selectedColor($r('app.color.primary'))
                  .trackColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
                  // 拖动即跳页（与胶囊跳页同逻辑：jumpToIndex 落位 + 落盘进度）
                  .onChange((value: number, _mode: SliderChangeMode) => this.onSliderChange(value))
              } else {
                // 单页章没有可滑的量（min ≥ max 会让 Slider 自己退回 0..100），这里只占位
                Row() {}
                  .layoutWeight(1)
              }

              Button('下一章')
                .type(ButtonType.Normal)
                .stateEffect(true)
                .height(32)
                .padding({ left: 12, right: 12 })
                .borderRadius(16)
                .fontSize(13)
                .fontColor($r('app.color.primary'))
                .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
                .onClick(() => this.switchChapter(true, 'toolbar'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 14, right: 14, top: 4, bottom: 12 })
            .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          }
          .width('100%')
          // 顶栏块**实测**高度：handleReaderTap 的「点在顶栏内」守卫读它，不必在代码里写死 68
          .onAreaChange((_oldArea: Area, newArea: Area) => {
            const height = newArea.height as number;
            if (height > 0 && height !== this.toolbarBlockHeight) {
              this.toolbarBlockHeight = height;
            }
          })
          // 顶栏显隐动画：进 200ms 淡入下滑、出 150ms 淡出，由 if 的挂载/卸载触发，
          // translate 只改绘制不改布局 → onAreaChange 记到的 toolbarBlockHeight 不会被动画污染。
          .transition(this.toolbarTransition())
        }
      }

      // P2-5 右上角时间胶囊：只在「隐藏状态栏」开着时出现（系统状态栏可见时和系统时钟重复），
      // 顶栏展开即藏起，顶栏收起才浮出来（互斥由布局层保证）。
      // 文案两行：`HH:MM WIFI/流量` ／ `域名 · 速率`，取不到的段省略、只有时间时保持单行。
      // 配色统一到右下角页码胶囊那套语言：nav_surface 底 + primary_text 字 + 圆角 12 + 同款内边距；
      // 只把字号降一号（11 vs 12）以示主次；不叠 opacity。
      // 位置：右上角右对齐 + top 16 让开前摄/挖孔带（根容器只 expandSafeArea 底部，顶部本就不出安全区）。
      // HitTestMode.None：整块不吃点击，下面的点击分区照常收到，呼出/收起顶栏不受影响。
      if (!this.toolbarShown() && this.hideStatusBarEnabled && this.capsuleText.length > 0) {
        Column() {
          Text(this.capsuleText)
            .fontSize(11)
            .lineHeight(15)
            // 两行都要右对齐：胶囊盒宽 = 两行中较宽那行，靠 textAlign 才不会第二行左挂
            .textAlign(TextAlign.End)
            .fontColor($r('app.color.primary_text'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
            .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 12, top: 16 })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.loadState !== ReaderLoadState.Content) {
        ReaderStatePanel({
          state: this.loadState,
          errorText: this.errorText,
          onRetry: (): void => {
            this.loadImages();
          }
        })
      }

      // 常显页码胶囊（独立于顶栏、始终可见）：点击弹出跳页输入。
      // 外层用全屏 Column 定位到右下角，并设 HitTestMode.Transparent 让未命中的点击继续透给翻页分区。
      // P2-1 页码显示开关：关掉时只藏这颗胶囊，顶栏里的页码计数不受影响。
      if (this.loadState === ReaderLoadState.Content && this.urls.length > 0 && this.showPageNumEnabled) {
        Column() {
          Text(this.pageCounter())
            .fontSize(12)
            .fontColor($r('app.color.primary_text'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(themeBackground('nav_surface', themeState().amoledActive, themeState().themeRevision))
            .borderRadius(12)
            .onClick(() => this.openJumpDialog())
            // 胶囊矩形**实测**记录：外层是全屏 Column（与 Swiper 同原点、同尺寸），
            // position 就是胶囊在组件坐标系里的落点 → handleReaderTap 的「点在胶囊内」守卫直接用，
            // 不用把 12/24/宽高写成魔数。胶囊消失时清空，避免命中一块不存在的区域。
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              const pos = newArea.position;
              this.pageCapsuleRect = {
                left: pos.x as number,
                top: pos.y as number,
                width: newArea.width as number,
                height: newArea.height as number
              };
            })
            .onDisAppear(() => {
              this.pageCapsuleRect = null;
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 12, bottom: 24 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 跳页输入浮层
      if (this.jumpVisible) {
        Column() {
          Column({ space: 12 }) {
            Text('跳转到第几页（共 ' + (this.urls.length > 0 ? this.urls.length : 0) + ' 页）')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
            TextInput({ text: this.jumpText, placeholder: this.jumpRangeLabel() })
              .type(InputType.Number)
              // 键盘随对话框弹出：三段式聚焦（统一走 requestJumpFocus，结论进 Collector 日志）——
              // ① openJumpDialog 立刻请求（多半早于挂载）；② 挂载后 onAppear；③ 120ms 后延时补一次。
              // 前提是根节点在浮层期间保持 focusable(true)，否则整条链会被「不可聚焦祖先」打断。
              .id(JUMP_INPUT_ID)
              .defaultFocus(true)
              .onAppear((): void => {
                this.requestJumpFocus('onAppear');
              })
              .height(42)
              .fontColor($r('app.color.primary_text'))
              .onChange((value: string): void => {
                this.jumpText = value;
              })
              .onSubmit(() => this.doJumpPage())
            Row({ space: 12 }) {
              Button('取消')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
                .fontColor($r('app.color.primary_text'))
                .onClick(() => {
                  this.jumpVisible = false;
                })
              Button('跳转')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.on_primary'))
                .onClick(() => this.doJumpPage())
            }
            .width('100%')
          }
          .width('80%')
          .padding(16)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(16)
          .onClick(() => {
            // 吞掉面板内的点击，避免冒泡到遮罩把浮层关掉
          })
          // 面板自有动画：0.95 缩放 + 淡入 200ms Friction，退出 150ms EaseIn
          .transition(this.jumpPanelTransition())
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.jumpVisible = false;
        })
        // 遮罩自有动画：只淡入淡出，200ms 进 / 150ms 出，与面板同步收放
        .transition(this.jumpScrimTransition())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    // P2-3 音量键翻页的兜底路径：onKeyEvent 要先有焦点才会收到按键，而音量键通常在派发到应用之前
    // 就被系统消费掉了 —— 真正拦得住的是 inputConsumer（见 applyVolumeKeyInterest）。
    // 开关打开时才让根节点参与焦点（与默认 false 一致的写法，关闭时零影响）；
    // 跳页浮层打开时同时撤掉焦点能力，避免和 TextInput 抢焦点。
    // 焦点能力：音量键兜底路径需要根节点参与焦点；**跳页浮层打开时也必须保持可聚焦**。
    // 之前写成 `volTurnEnabled && !jumpVisible` —— 浮层一开根节点就是 focusable(false)，
    // 会成为输入框的「不可聚焦祖先」（FocusController 抛 150002 / 静默返回 false），
    // defaultFocus 与 requestFocus 一起失效，这正是"点了不翻页但键盘死活不弹"的根因。
    .focusable(this.volTurnEnabled || this.jumpVisible)
    // 默认焦点只在音量键场景给根节点；浮层打开时不与输入框抢默认焦点
    .defaultFocus(this.volTurnEnabled && !this.jumpVisible)
    .onKeyEvent((event: KeyEvent): boolean => this.handleRootKeyEvent(event))
  }
}

/** Image.onComplete 回调载荷：只取需要的宽高。 */
interface ReaderImageSize {
  width: number;
  height: number;
  componentWidth: number;
  componentHeight: number;
  loadingStatus: number;
  contentWidth: number;
  contentHeight: number;
  contentOffsetX: number;
  contentOffsetY: number;
}

/** 图片原始宽高（横/纵 Contain 矩形计算用）。 */
interface ReaderSize {
  width: number;
  height: number;
}

/** 内容矩形（变换盒子坐标系，缩放前）。 */
interface ReaderRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

interface ReaderPageItem {
  url: string;
  key: string;
  page: number;
  /** 0-based 页下标，供预载门使用。 */
  index: number;
  /** 章末吐槽虚拟页标记：index 固定为 -1，不参与重试/进度逻辑。 */
  isComment?: boolean;
}

class ReaderPageSource implements IDataSource {
  private items: ReaderPageItem[] = [];
  private listeners: DataChangeListener[] = [];
  /**
   * 手动重载计数：参与 LazyForEach 的 key。
   * key 变了才会真正重建该 Image 节点——只换 src 会复用旧节点并命中失败缓存。
   */
  private reloadCounts: Map<number, number> = new Map<number, number>();

  /**
   * 章末吐槽虚拟页是否已插在末尾。
   * 由 ReaderPage.enterContent() 单次翻开：横/纵因此多一页可翻，条漫因此多一个末尾 item。
   */
  private tailEnabled: boolean = false;

  constructor(urls: string[]) {
    this.items = [];
    for (let i = 0; i < urls.length; i++) {
      this.items.push({ url: urls[i], key: urls[i] + ':' + i.toString(), page: i + 1, index: i });
    }
  }

  append(url: string, index: number): void {
    // 有吐槽尾巴时，新图片要插到尾巴**之前**（否则尾巴被顶到中间，页码全错）
    const insertAt = this.tailEnabled ? this.items.length - 1 : this.items.length;
    this.items.splice(insertAt, 0,
      { url: url, key: url + ':' + index.toString(), page: index + 1, index: index });
    // 逐项 onDataAdd：保持当前页不动
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(insertAt);
    }
  }

  /**
   * 插入/移除章末吐槽虚拟页（始终是最后一项）。
   *
   * ⚠️ 只会在"进内容态"那一帧被 ReaderPage.enterContent() 调用一次：此刻正式的
   * Swiper/List 还没创建（它读的是调用之后的 totalCount()），仍在树上的只有预载门
   * 那个临时 Swiper。所以这里**刻意不发 onData*** 通知——发了会让门态 Swiper 临时
   * 多渲染一个 url='' 的空图；若将来要在容器存活期间翻尾巴，再补通知即可。
   */
  setTail(enabled: boolean): void {
    if (this.tailEnabled === enabled) {
      return;
    }
    this.tailEnabled = enabled;
    if (enabled) {
      this.items.push({ url: '', key: COMMENT_ITEM_KEY, page: -1, index: -1, isComment: true });
      return;
    }
    const last = this.items.length - 1;
    if (last >= 0 && this.items[last].isComment === true) {
      this.items.splice(last, 1);
    }
  }

  /** 记录某页的手动重载次数，并增量刷新该项。 */
  setReloadCount(index: number, count: number): void {
    this.reloadCounts.set(index, count);
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index);
    }
  }

  /** 取某页当前的手动重载次数（key 用）。 */
  reloadCount(index: number): number {
    const n = this.reloadCounts.get(index);
    return n === undefined ? 0 : n;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): ReaderPageItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const kept: DataChangeListener[] = [];
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] !== listener) {
        kept.push(this.listeners[i]);
      }
    }
    this.listeners = kept;
  }
}
