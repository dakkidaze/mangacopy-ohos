/**
 * 浏览页共用的数据入口、分页控制器和网格组件。
 * 仅组合既有数据层，不在此重写网络或持久化逻辑。
 */
import { ApiDomainManager } from '../services/ApiDomainManager';
import { ApiClient, ApiException } from '../services/ApiClient';
import { CopyApiSource } from '../services/CopyApiSource';
import { authStore, CookieEntry } from '../services/AuthStore';
import { MangaSummary } from '../model/Models';
import { imageCacheTrim } from '../services/ImageCacheTrim';
import { themeBackground, themeState } from './ThemeColors';

export const BROWSE_PAGE_SIZE: number = 21;

/** 网格左右各 16vp 的内边距：量到的容器宽要减掉它，阈值比的是"可用宽度"。 */
export const GRID_SIDE_PADDING: number = 32;

/**
 * 网格列数自适应（对齐 Flutter 侧口径：2/3/4/5 列，阈值 520/760/1000）。
 * 入参是网格的可用宽度（vp，已减去左右内边距）；非正数按 0 处理 → 2 列。
 */
export function gridColumnsForWidth(width: number): number {
  const value = width > 0 ? width : 0;
  if (value < 520) {
    return 2;
  }
  if (value < 760) {
    return 3;
  }
  if (value < 1000) {
    return 4;
  }
  return 5;
}

/** 列数 → columnsTemplate（每列 1fr，如三列即三个 1fr）：模板由列数生成，页面里不写死固定列数。 */
export function gridColumnsTemplate(count: number): string {
  const columns = count < 2 ? 2 : count;
  let template = '1fr';
  for (let i = 1; i < columns; i++) {
    template += ' 1fr';
  }
  return template;
}

const browseDomains: ApiDomainManager = new ApiDomainManager();
const browseClient: ApiClient = new ApiClient(browseDomains);
const sharedBrowseSource: CopyApiSource = new CopyApiSource(browseClient);
let browseReady: boolean = false;
let browsePreparing: Promise<void> | undefined = undefined;

@ObservedV2
export class BrowseSessionState {
  @Trace ready: boolean = false;
  @Trace loggedIn: boolean = false;
  @Trace hasToken: boolean = false;
  @Trace cookieCount: number = 0;
  @Trace username: string = '';

  sync(username: string = ''): void {
    this.ready = true;
    this.hasToken = authStore.getToken().length > 0;
    this.loggedIn = this.hasToken;
    this.cookieCount = authStore.getCookieEntries().length;
    this.username = this.loggedIn ? username : '';
  }
}

export const browseSession: BrowseSessionState = new BrowseSessionState();

function restoreClientSession(): void {
  const cookies = new Map<string, string>();
  const entries: CookieEntry[] = authStore.getCookieEntries();
  for (let i = 0; i < entries.length; i++) {
    cookies.set(entries[i].key, entries[i].value);
  }
  browseClient.restoreCookies(cookies);
  browseClient.setToken(authStore.getToken());
  browseSession.sync();
}

export function syncBrowseSession(username: string = ''): void {
  browseSession.sync(username);
}

export async function reloadBrowseSession(): Promise<void> {
  await authStore.load();
  restoreClientSession();
}

export async function clearBrowseSession(): Promise<void> {
  await authStore.clear();
  browseClient.clearSession();
  browseSession.sync();
}

async function prepareBrowseApi(): Promise<void> {
  await authStore.load();
  restoreClientSession();
  const seeded = await browseDomains.bootstrapFromNetwork4('https://api.copy202601.com');
  if (seeded.length > 0 && browseDomains.candidates.indexOf(seeded) < 0) {
    browseDomains.candidates.unshift(seeded);
  }
  await browseDomains.probeBest();
}

/** 懒探测一次 API 域；并发页面共用同一个准备任务。 */
export async function getBrowseSource(): Promise<CopyApiSource> {
  if (browseReady) {
    return sharedBrowseSource;
  }
  if (browsePreparing === undefined) {
    browsePreparing = prepareBrowseApi();
  }
  try {
    await browsePreparing;
    browseReady = true;
  } finally {
    browsePreparing = undefined;
  }
  return sharedBrowseSource;
}

export function describeBrowseError(error: Object): string {
  if (error instanceof ApiException) {
    const apiError = error as ApiException;
    if (apiError.message.length > 0) {
      return apiError.message + '（' + apiError.code + '）';
    }
    return '接口错误（' + apiError.code + '）';
  }
  const value = error as Error;
  return value.message !== undefined && value.message.length > 0 ? value.message : '网络请求失败';
}

export class MangaListDataSource implements IDataSource {
  private items: MangaSummary[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): MangaSummary {
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

  replace(items: MangaSummary[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  append(items: MangaSummary[]): void {
    const start = this.items.length;
    for (let i = 0; i < items.length; i++) {
      this.items.push(items[i]);
    }
    for (let index = start; index < this.items.length; index++) {
      for (let listener = 0; listener < this.listeners.length; listener++) {
        this.listeners[listener].onDataAdd(index);
      }
    }
  }
}

export type MangaPageLoader = (offset: number) => Promise<MangaSummary[]>;

async function emptyPageLoader(_offset: number): Promise<MangaSummary[]> {
  return [];
}

export enum BrowseLoadState {
  Idle = 0,
  Loading = 1,
  Content = 2,
  Empty = 3,
  Error = 4
}

@ObservedV2
export class MangaPagingController {
  @Trace state: BrowseLoadState = BrowseLoadState.Idle;
  @Trace itemCount: number = 0;
  @Trace refreshing: boolean = false;
  @Trace loadingMore: boolean = false;
  @Trace hasMore: boolean = true;
  @Trace errorText: string = '';
  @Trace footerText: string = '';

  readonly dataSource: MangaListDataSource = new MangaListDataSource();
  private loader: MangaPageLoader = emptyPageLoader;
  private pageSize: number = BROWSE_PAGE_SIZE;
  private revision: number = 0;

  constructor(loader: MangaPageLoader = emptyPageLoader, pageSize: number = BROWSE_PAGE_SIZE) {
    this.loader = loader;
    this.pageSize = pageSize;
  }

  setLoader(loader: MangaPageLoader): void {
    this.revision++;
    this.loader = loader;
    this.dataSource.replace([]);
    this.itemCount = 0;
    this.state = BrowseLoadState.Idle;
    this.refreshing = false;
    this.loadingMore = false;
    this.hasMore = true;
    this.errorText = '';
    this.footerText = '';
  }

  async loadFirst(): Promise<void> {
    await this.replacePage(false);
  }

  async refresh(): Promise<void> {
    await this.replacePage(true);
  }

  private async replacePage(fromRefresh: boolean): Promise<void> {
    const ticket = ++this.revision;
    this.refreshing = fromRefresh;
    this.loadingMore = false;
    this.errorText = '';
    this.footerText = '';
    if (this.itemCount === 0) {
      this.state = BrowseLoadState.Loading;
    }
    try {
      const items = await this.loader(0);
      if (ticket !== this.revision) {
        return;
      }
      this.dataSource.replace(items);
      this.itemCount = items.length;
      this.hasMore = items.length >= this.pageSize;
      this.state = items.length === 0 ? BrowseLoadState.Empty : BrowseLoadState.Content;
      this.footerText = this.hasMore ? '' : '没有更多了';
    } catch (error) {
      if (ticket !== this.revision) {
        return;
      }
      this.errorText = describeBrowseError(error as Object);
      if (this.itemCount === 0) {
        this.state = BrowseLoadState.Error;
      } else {
        this.state = BrowseLoadState.Content;
        this.footerText = '刷新失败，点此重试';
      }
    } finally {
      if (ticket === this.revision) {
        this.refreshing = false;
      }
    }
  }

  async loadMore(): Promise<void> {
    if (this.loadingMore || this.refreshing || !this.hasMore || this.state !== BrowseLoadState.Content) {
      return;
    }
    const ticket = this.revision;
    this.loadingMore = true;
    this.footerText = '';
    try {
      const items = await this.loader(this.itemCount);
      if (ticket !== this.revision) {
        return;
      }
      this.dataSource.append(items);
      this.itemCount += items.length;
      this.hasMore = items.length >= this.pageSize;
      this.footerText = this.hasMore ? '' : '没有更多了';
    } catch (error) {
      if (ticket !== this.revision) {
        return;
      }
      this.footerText = '加载失败，点此重试';
    } finally {
      if (ticket === this.revision) {
        this.loadingMore = false;
      }
    }
  }
}

/**
 * 「占位/加载 ↔ 内容」交叉溶解：进场 200ms 淡入、退场 160ms 淡出。
 * 转场自带动画，不包 animateTo；配套的容器一律用 Stack 原地叠放，
 * 让退场的一支不占据流式布局位置（否则占位还在流里，内容会被顶一下再弹回）。
 */
export function fadeSwapTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }),
    TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseIn })
  );
}

/**
 * 封面「准一镜」转场的动效口径。
 *
 * 这是 geometryTransition（真共享元素一镜到底）不可用时的替代方案。真实结论与依据：
 * 官方「共享元素转场（一镜到底）」文档写明，geometryTransition 的跨页共享只在
 * **NavDestination 之间**由系统承接，并且要求**关闭系统默认转场**、把跳转放进
 * animateTo 闭包。本项目是手写壳（单 @Entry + AppRoute 枚举 + Stack 条件挂载），
 * 没有 NavDestination，且页面级 .transition(pushTransition()) 自带缩放淡入——
 * 这条路线在当前结构下不成立；硬改成 Navigation 是大改，不在本次试点范围内。
 * 因此退而求其次：让详情页封面**从卡片封面的视觉起点**淡入 + 轻微放大到位，
 * 观感上接住"封面长大成详情页"的那一下，而不是凭空淡入。
 *
 * 时长与全局路由转场同拍（进入 280ms Friction），曲线同源；
 * 起始缩放 0.88 与页面级 0.94 拉开层次：页面整体轻微放大，封面额外多收一点，
 * 形成"内容从卡片里长出来"的层次差；退场 180ms EaseIn，与全局"退场更短更快"一致。
 */
export const COVER_FALLBACK_IN_DURATION: number = 280;
export const COVER_FALLBACK_OUT_DURATION: number = 180;
export const COVER_FALLBACK_IN_SCALE: number = 0.88;

/**
 * 详情页封面的「准一镜」进场转场：淡入 + 从 0.88 放大到位。
 * 退场侧 IDENTITY —— 详情页封面常驻在树上，退场交给页面级转场，不额外叠一层淡出。
 */
export function coverFallbackTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({
        x: COVER_FALLBACK_IN_SCALE,
        y: COVER_FALLBACK_IN_SCALE
      }))
      .animation({ duration: COVER_FALLBACK_IN_DURATION, curve: Curve.Friction }),
    TransitionEffect.IDENTITY
  );
}

/**
 * 封面图源快照：网格卡点击时写入，详情页首帧读取。
 *
 * 详情页的详情数据是异步加载的，转场那一帧大封面还没数据（只有占位底色）。
 * 这里把封面 URL 递过去，让详情页在**占位期间就能显示同图**，
 * 配合 coverFallbackTransition 的淡入放大，观感上把"占位 → 真封面"的白闪也一并吃掉。
 */
export class CoverShareState {
  mangaId: string = '';
  url: string = '';

  set(mangaId: string, url: string): void {
    this.mangaId = mangaId;
    this.url = url;
  }

  /**
   * 取同源封面 URL（只读，不失效）。
   *
   * 与真共享转场不同，这里**不需要** consume-once：详情页可能反复重挂（阅读器返回等），
   * 每次重挂都希望能立刻显示已有封面而不闪占位。同源校验（mangaId 相等）已经足以
   * 保证不会串到别的漫画上；换漫画时自然取到空串。
   */
  urlFor(mangaId: string): string {
    return mangaId.length > 0 && this.mangaId === mangaId ? this.url : '';
  }
}

export const coverShare: CoverShareState = new CoverShareState();

@ComponentV2
struct MangaGridCard {
  @Param item: MangaSummary = new MangaSummary('', '', '', '');
  @Event onOpen: (id: string) => void = (_id: string) => {};
  /** TouchDown 即时按压：不等 onClick；Up / Cancel（手指被滚动抢走）都要复位，别卡在缩小态。 */
  @Local pressed: boolean = false;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
          Image(this.item.cover)
            .alt($r('app.media.app_icon'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius({ topLeft: 18, topRight: 18 })
        }
        .width('100%')
        .height(228)

        Column({ space: 5 }) {
          Text(this.item.title.length > 0 ? this.item.title : '未命名漫画')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.item.author.length > 0 ? this.item.author : '作者未标注')
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .height(66)
        .padding({ left: 12, right: 12, top: 9, bottom: 8 })
      }
      .width('100%')
      .height('100%')

      // 按压叠层：只借既有文字色，不新增色值——亮色主题是压一层黑（微暗），暗色主题是抬一层白（微亮）
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(18)
        .backgroundColor($r('app.color.primary_text'))
        .opacity(this.pressed ? 0.06 : 0)
        // 与根节点同参数：有的版本 animation 不跨节点下推，少了这条叠层会"跳一下"
        .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height(294)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(18)
    .shadow({ radius: 8, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 3 })
    // 按下轻缩放 0.95：160ms FastOutSlowIn，落手与回弹同一段曲线
    .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      // 把封面 URL 递给详情页：那边首帧就能显示同图，配合淡入放大接住转场（见 coverShare 注释）
      coverShare.set(this.item.id, this.item.cover);
      this.onOpen(this.item.id);
    })
  }
}

@ComponentV2
export struct BrowseStatePanel {
  @Param state: BrowseLoadState = BrowseLoadState.Idle;
  @Param errorText: string = '';
  @Param idleText: string = '准备加载';
  @Param loadingText: string = '正在加载…';
  @Param emptyTitle: string = '没有找到漫画';
  @Param emptyDescription: string = '可以换个关键词或筛选条件再试';
  @Event onRetry: () => void = () => {};

  build() {
    // 面板内部也是 if/else 换状态（加载 → 报错/空/idle）：Stack 原地叠放 + 交叉溶解，
    // 退场的一支淡出时不再占据流式位置，容器高度取两者最大值，居中的内容不会被顶一下再弹回。
    Stack({ alignContent: Alignment.Center }) {
      if (this.state === BrowseLoadState.Loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.primary'))
          Text(this.loadingText)
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
        }
        .transition(fadeSwapTransition())
      } else if (this.state === BrowseLoadState.Error) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(34)
            .fontColor([$r('app.color.accent')])
          Text('加载失败')
            .fontSize(18)
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
            .height(40)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .borderRadius(13)
            .onClick(() => this.onRetry())
        }
        .transition(fadeSwapTransition())
      } else if (this.state === BrowseLoadState.Empty) {
        Column({ space: 12 }) {
          Text('○')
            .fontSize(32)
            .fontColor($r('app.color.secondary_text'))
          Text(this.emptyTitle)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.emptyDescription)
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
        }
        .transition(fadeSwapTransition())
      } else {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(32)
            .fontColor([$r('app.color.secondary_text')])
          Text(this.idleText)
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
        }
        .transition(fadeSwapTransition())
      }
    }
    .width('100%')
    .height('100%')
    .padding(24)
  }
}

@ComponentV2
export struct PagingFooter {
  @Param loading: boolean = false;
  @Param hasMore: boolean = true;
  @Param message: string = '';
  @Event onRetry: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      if (this.loading) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.primary'))
        Text('正在加载更多…')
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      } else if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(this.loading || this.message.length > 0 || !this.hasMore ? 42 : 12)
    .onClick(() => {
      if (!this.loading && this.hasMore && this.message.length > 0) {
        this.onRetry();
      }
    })
  }
}

@ComponentV2
export struct MangaGridView {
  @Require @Param controller: MangaPagingController = new MangaPagingController();
  /** 外部持有的滚动控制器：需要跨页保留滚动位置的页面可传入自己的实例。 */
  @Param scroller: Scroller = new Scroller();
  @Param bottomPadding: number = 48;
  @Param idleText: string = '准备加载';
  @Event onOpen: (id: string) => void = (_id: string) => {};
  @Event onScrolled: (offset: number) => void = (_offset: number) => {};

  /** 网格列数（2/3/4/5 随可用宽度自适应）；初值 2 与手机首帧一致，量宽后再调整。 */
  @Local columns: number = 2;

  aboutToAppear(): void {
    // 触发点之一（非 Index）：ImageCacheTrim 内部有 45 秒最小间隔 + 单飞，这里的调用是 O(1)
    imageCacheTrim.maybeTrim();
  }

  /** 按实测容器宽度更新列数：只有列数真的变了才写 @Local，切列只重排一次、不逐帧抖动。 */
  private applyColumns(width: number): void {
    if (!(width > 0)) {
      return;
    }
    const columns = gridColumnsForWidth(width - GRID_SIDE_PADDING);
    if (columns !== this.columns) {
      this.columns = columns;
    }
  }

  build() {
    // 占位面板 ↔ 网格：Stack 原地叠放 + 交叉溶解。退场的一支不再留在流式布局里，
    // 容器尺寸也固定成 100%，换态时不会把外层 Column 顶一下再弹回。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.controller.itemCount === 0 && this.controller.state !== BrowseLoadState.Content) {
        BrowseStatePanel({
          state: this.controller.state,
          errorText: this.controller.errorText,
          idleText: this.idleText,
          onRetry: (): void => { this.controller.loadFirst(); }
        })
        .transition(fadeSwapTransition())
      } else {
        Refresh({ refreshing: this.controller.refreshing }) {
          Grid(this.scroller) {
            LazyForEach(this.controller.dataSource, (item: MangaSummary, index: number) => {
              GridItem() {
                MangaGridCard({
                  item: item,
                  onOpen: (id: string): void => this.onOpen(id)
                })
              }
            }, (item: MangaSummary, index: number) => item.id + ':' + index.toString())

            GridItem() {
              PagingFooter({
                loading: this.controller.loadingMore,
                hasMore: this.controller.hasMore,
                message: this.controller.footerText,
                onRetry: (): void => { this.controller.loadMore(); }
              })
            }
            .columnStart(0)
            .columnEnd(this.columns - 1)
          }
          .columnsTemplate(gridColumnsTemplate(this.columns))
          .columnsGap(12)
          .rowsGap(14)
          .cachedCount(6)
          .padding({ left: 16, right: 16, top: 10, bottom: this.bottomPadding })
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.Spring)
          .onDidScroll((): void => {
            // 只关心"当前落在哪"，逐帧位移量在这里没用，交由 Scroller 读偏移
            try {
              this.onScrolled(this.scroller.currentOffset().yOffset);
            } catch (error) {
              // 容器尚未绑定时拿不到偏移，忽略这一帧
            }
          })
          .onReachEnd(() => this.controller.loadMore())
        }
        .width('100%')
        .height('100%')
        .pullToRefresh(true)
        .onRefreshing(() => this.controller.refresh())
        .transition(fadeSwapTransition())
      }
    }
    .width('100%')
    .height('100%')
    // 容器实测宽度 → 列数（2/3/4/5，阈值 520/760/1000）。占位态也量得到，
    // 所以网格出现时已经是正确列数；列数变化本身只触发一次重排。
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.applyColumns(newArea.width as number);
    })
  }
}
