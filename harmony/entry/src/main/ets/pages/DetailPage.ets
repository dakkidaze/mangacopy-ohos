/** 原生漫画详情页：详情与章节分别加载，阅读和下载暂以明确提示承接。 */
import { Chapter, MangaDetail } from '../model/Models';
import {
  BrowseLoadState,
  browseSession,
  BrowseSessionState,
  describeBrowseError,
  fadeSwapTransition,
  getBrowseSource,
  reloadBrowseSession
} from './BrowseSupport';
import { CommentPanel, CommentPanelTab } from './CommentPanel';
import { ReaderChapterRef } from './ReaderPage';
import {
  ChapterDownloadRequest,
  ChapterDownloadState,
  ChapterDownloadStatus,
  downloadStore
} from './DownloadStore';
import { themeBackground, themeState } from './ThemeColors';

function emptyDetail(): MangaDetail {
  return new MangaDetail('', '', '', '', '', '', '', '', []);
}

/** 详情长列表首次布局完成前 Scroller 可能静默忽略定位，短间隔重试直到位置生效。 */
const DETAIL_SCROLL_RESTORE_MAX_ATTEMPTS: number = 10;
const DETAIL_SCROLL_RESTORE_DELAY_MS: number = 80;

/**
 * 详情页存活期会话：阅读器只是盖住详情页，返回时复用；离开详情流程时由 Index 清空。
 * valid 用来区分“同一本漫画正在首次加载”和“已有可恢复快照”。
 */
export class DetailSessionState {
  mangaId: string = '';
  valid: boolean = false;
  detail: MangaDetail | null = null;
  chapters: Chapter[] = [];
  ascending: boolean = true;
  scrollOffset: number = 0;
  descriptionExpanded: boolean = false;
  /** 章节多选：进阅读器再回来时保留选择模式与勾选（离开详情流程时随 reset 清空）。 */
  selecting: boolean = false;
  selectedIds: Set<string> = new Set<string>();
  detailState: BrowseLoadState = BrowseLoadState.Loading;
  chapterState: BrowseLoadState = BrowseLoadState.Loading;
  detailError: string = '';
  chapterError: string = '';
  collected: boolean = false;
  scroller: Scroller = new Scroller();

  matches(mangaId: string): boolean {
    return this.valid && mangaId.length > 0 && this.mangaId === mangaId;
  }

  reset(mangaId: string = ''): void {
    this.mangaId = mangaId;
    this.valid = false;
    this.detail = null;
    this.chapters = [];
    this.ascending = true;
    this.scrollOffset = 0;
    this.descriptionExpanded = false;
    this.selecting = false;
    this.selectedIds = new Set<string>();
    this.detailState = BrowseLoadState.Loading;
    this.chapterState = BrowseLoadState.Loading;
    this.detailError = '';
    this.chapterError = '';
    this.collected = false;
    // 换新 Scroller，让旧详情页卸载时无法把旧漫画的位置写回新会话。
    this.scroller = new Scroller();
  }
}

/** Set 不可变拷贝：@Trace 的 selectedIds 每次都要整体替换才触发通知。 */
function copyIdSet(source: Set<string>): Set<string> {
  const next = new Set<string>();
  source.forEach((id: string): void => {
    next.add(id);
  });
  return next;
}

export const detailSession: DetailSessionState = new DetailSessionState();

/**
 * 详情页返回拦截（壳层 Index.onBackPress 调用）：详情页内部状态（如下载选择模式）先消费返回，
 * 避免"选着章节突然被退出详情"。返回 true 表示已消费。
 */
let detailBackHandler: (() => boolean) | null = null;
export function setDetailBackHandler(handler: (() => boolean) | null): void {
  detailBackHandler = handler;
}
export function handleDetailBack(): boolean {
  const handler = detailBackHandler;
  if (handler === null) {
    return false;
  }
  return handler();
}

export function resetDetailSession(): void {
  detailSession.reset();
}

@ComponentV2
struct DetailStatePanel {
  @Param state: BrowseLoadState = BrowseLoadState.Loading;
  @Param label: string = '';
  @Param errorText: string = '';
  @Event onRetry: () => void = () => {};

  build() {
    Column({ space: 10 }) {
      if (this.state === BrowseLoadState.Loading) {
        LoadingProgress()
          .width(30)
          .height(30)
          .color($r('app.color.primary'))
        Text('正在加载' + this.label + '…')
          .fontSize(13)
          .fontColor($r('app.color.secondary_text'))
      } else if (this.state === BrowseLoadState.Error) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(28)
          .fontColor([$r('app.color.accent')])
        Text(this.label + '加载失败')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.errorText)
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
        Button('重试')
          .type(ButtonType.Normal)
          .height(36)
          .fontSize(12)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .borderRadius(12)
          .onClick(() => this.onRetry())
      } else {
        Text('暂无' + this.label)
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(150)
    .padding(18)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(20)
  }
}

@ComponentV2
struct GenreTag {
  @Param label: string = '';

  build() {
    Text(this.label)
      .fontSize(11)
      .fontColor($r('app.color.primary'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 7, bottom: 7 })
      .backgroundColor($r('app.color.accent_soft'))
      .borderRadius(10)
  }
}

@ComponentV2
struct DetailOverview {
  @Param detail: MangaDetail = emptyDetail();
  @Param expanded: boolean = false;
  @Param collected: boolean = false;
  @Param collectBusy: boolean = false;
  @Event onToggleDescription: () => void = () => {};
  @Event onOpenComments: () => void = () => {};
  @Event onToggleCollect: () => void = () => {};

  build() {
    Column({ space: 16 }) {
      Row({ space: 16 }) {
        Image(this.detail.cover)
          .alt($r('app.media.app_icon'))
          .width(112)
          .height(154)
          .objectFit(ImageFit.Cover)
          .borderRadius(16)
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))

        Column({ space: 9 }) {
          Text(this.detail.title.length > 0 ? this.detail.title : '未命名漫画')
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.detail.author.length > 0 ? this.detail.author : '作者未标注')
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 8 }) {
            Text(this.detail.region.length > 0 ? this.detail.region : '地区未知')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
              .borderRadius(9)
            Text(this.detail.status.length > 0 ? this.detail.status : '状态未知')
              .fontSize(11)
              .fontColor($r('app.color.accent'))
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.accent_soft'))
              .borderRadius(9)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.detail.genres.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.detail.genres, (genre: string, index: number) => {
            GenreTag({ label: genre })
          }, (genre: string, index: number) => genre + ':' + index.toString())
        }
        .width('100%')
      }

      Row({ space: 10 }) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 7 }) {
            // 收藏忙态的转圈消失改淡出：两支图标固定 18×18 原地叠放，宽度不随状态跳
            Stack({ alignContent: Alignment.Center }) {
              if (this.collectBusy) {
                LoadingProgress()
                  .width(17)
                  .height(17)
                  .color($r('app.color.primary'))
                  .transition(fadeSwapTransition())
              } else {
                SymbolGlyph(this.collected ?
                  $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
                  .fontSize(18)
                  .fontColor([$r('app.color.primary')])
                  .transition(fadeSwapTransition())
              }
            }
            .width(18)
            .height(18)
            Text(this.collectBusy ? '处理中…' : this.collected ? '已收藏' : '收藏')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary'))
          }
        }
        .layoutWeight(1)
        .height(40)
        .backgroundColor(this.collected ? $r('app.color.nav_selected') : $r('app.color.accent_soft'))
        .borderRadius(14)
        .enabled(!this.collectBusy)
        .onClick(() => this.onToggleCollect())

        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.message'))
              .fontSize(18)
              .fontColor([$r('app.color.primary')])
            Text('查看吐槽')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary'))
          }
        }
        .layoutWeight(1)
        .height(40)
        .backgroundColor($r('app.color.accent_soft'))
        .borderRadius(14)
        .onClick(() => this.onOpenComments())
      }
      .width('100%')

      Column({ space: 6 }) {
        Text('简介')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .width('100%')
        Text(this.detail.description.length > 0 ? this.detail.description : '暂无简介')
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(this.expanded ? 30 : 4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.detail.description.length > 70) {
          Button(this.expanded ? '收起' : '展开')
            .type(ButtonType.Normal)
            .height(32)
            .fontSize(12)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.nav_item_clear'))
            .onClick(() => this.onToggleDescription())
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(22)
  }
}

/**
 * 章节多选集合：每次改动整体替换 Set 字段触发 @Trace 通知。
 * DetailPage 负责改，ChapterRow 在 build 里读 selectedIds / downloadedIds 自己订阅刷新。
 * downloadedIds 是「已下载」缓存：锁定勾选与计数都用它，避免每次 build 都打磁盘。
 */
@ObservedV2
class ChapterSelectionModel {
  @Trace selectedIds: Set<string> = new Set<string>();
  @Trace downloadedIds: Set<string> = new Set<string>();
}

/**
 * 批次状态（「下载所选」）：**已从详情页退役，单一数据源是 DownloadStore 的队列**——
 * 入队 enqueueChapters()、执行 runQueue()、进度读 downloadStore.batchView、
 * 取消 cancelBatch()。详情页不再自持任何批次字段，组件卸载后进度照样在 store 里推进。
 */
@ComponentV2
struct ChapterRow {
  @Param chapter: Chapter = new Chapter('', '', 0, 0);
  @Param downloadState: ChapterDownloadState = new ChapterDownloadState();
  @Param selection: ChapterSelectionModel = new ChapterSelectionModel();
  /** 选择模式：右侧控件在「下载按钮 / 复选框」之间切换；默认下载按钮。 */
  @Param selecting: boolean = false;
  @Event onRead: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  @Event onComments: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  @Event onToggleSelect: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  /** 点击下载按钮：**单章直下**（下载中点按＝取消、已下载提示、失败重试），与选择模式无关。 */
  @Event onDownload: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  /** TouchDown 即时按压（对齐卡片手感 0.95 / 160ms）：Up 与 Cancel 都要复位，别卡在缩小态。 */
  @Local pressed: boolean = false;

  private chapterTitle(): string {
    if (this.chapter.name.length > 0) {
      return this.chapter.name;
    }
    return this.chapter.index > 0 ? '第 ' + this.chapter.index + ' 话' : '未命名章节';
  }

  private isSelected(): boolean {
    return this.selection.selectedIds.has(this.chapter.id);
  }

  /** 已下载（缓存 + 实时状态）：选择模式里渲染成「锁定勾选」。 */
  private isDownloaded(): boolean {
    return this.selection.downloadedIds.has(this.chapter.id) ||
      this.downloadState.status === ChapterDownloadStatus.Completed;
  }

  build() {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(this.chapterTitle())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.downloadState.status === ChapterDownloadStatus.Downloading) {
            Text('下载 ' + this.downloadState.completed + '/' + this.downloadState.total + ' · ' +
              this.downloadState.progressPercent() + '%')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
          } else if (this.downloadState.status === ChapterDownloadStatus.Queued) {
            // 队列位置在管理页展示（那里有 1.5s 重扫）；详情页没有轮询，
            // 这里只给稳定的「排队中」，避免长时间显示过期位次
            Text('排队中 · 稍后自动开始')
              .fontSize(11)
              .fontColor($r('app.color.primary'))
          } else if (this.downloadState.status === ChapterDownloadStatus.Completed) {
            Text('已下载 · ' + (this.chapter.size > 0 ? this.chapter.size + ' 页' : '本地可用'))
              .fontSize(11)
              .fontColor($r('app.color.primary'))
          } else if (this.downloadState.status === ChapterDownloadStatus.Failed) {
            Text(this.selecting ? '下载失败，勾选后重试' : '下载失败，点下载按钮重试')
              .fontSize(11)
              .fontColor($r('app.color.accent'))
          } else if (this.chapter.size > 0) {
            Text(this.chapter.size + ' 页')
              .fontSize(11)
              .fontColor($r('app.color.secondary_text'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .height(54)
      // 按压反馈：只挂在「点开阅读」这块上（下载/评论/勾选有自己的按钮反馈），
      // 幅度对齐卡片 —— 0.95 / 160ms FastOutSlowIn，落手与回弹同一段曲线
      .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
      .animation({ duration: 160, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick(() => this.onRead(this.chapter))

      // Row 默认即 VerticalAlign.Center；alignItems 不是 Row 的构造参数（写进 options 会编译失败）
      Row({ space: 6 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(19)
            .fontColor([$r('app.color.primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        .accessibilityText('查看本章吐槽')
        .onClick(() => this.onComments(this.chapter))

        if (this.selecting) {
          if (this.isDownloaded()) {
            // 已下载：锁定勾选 —— 视觉＝选中态，但降透明度 + 禁用态，点按不改变状态（无 onClick）
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor([$r('app.color.on_primary')])
            }
            .width(26)
            .height(26)
            .borderRadius(8)
            .backgroundColor($r('app.color.primary'))
            .enabled(false)
            .opacity(0.55)
            .accessibilityText('本章已下载，固定勾选且不可取消')
          } else {
            // 可勾选：缩小版复选框（26）。只负责勾选，不参与整行的「打开阅读」。
            Stack({ alignContent: Alignment.Center }) {
              if (this.isSelected()) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(13)
                  .fontColor([$r('app.color.on_primary')])
              }
            }
            .width(26)
            .height(26)
            .borderRadius(8)
            .backgroundColor(this.isSelected() ? $r('app.color.primary') : $r('app.color.field_background'))
            .border({
              width: this.isSelected() ? 0 : 1.5,
              color: this.isSelected() ? $r('app.color.nav_item_clear') : $r('app.color.divider')
            })
            .accessibilityText(this.isSelected() ? '已选中本章，点按取消选择' : '未选中本章，点按选择本章')
            .onClick(() => this.onToggleSelect(this.chapter))
          }
        } else {
          // 默认：下载按钮，点击＝**直接下载这一话**（进多选改由章节头部「多选下载」负责）。
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            if (this.downloadState.status === ChapterDownloadStatus.Downloading) {
              Stack({ alignContent: Alignment.Center }) {
                Progress({ value: this.downloadState.progressPercent(), total: 100, type: ProgressType.Ring })
                  .width(24)
                  .height(24)
                  .color($r('app.color.primary'))
                  .style({ strokeWidth: 2, enableSmoothEffect: true })
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(12)
                  .fontColor([$r('app.color.primary')])
              }
            } else if (this.downloadState.status === ChapterDownloadStatus.Completed) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([$r('app.color.primary')])
            } else if (this.downloadState.status === ChapterDownloadStatus.Queued) {
              SymbolGlyph($r('sys.symbol.clock'))
                .fontSize(17)
                .fontColor([$r('app.color.primary')])
            } else {
              SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                .fontSize(19)
                .fontColor([this.downloadState.status === ChapterDownloadStatus.Failed ?
                  $r('app.color.accent') : $r('app.color.primary')])
            }
          }
          .width(36)
          .height(36)
          .backgroundColor(this.downloadState.status === ChapterDownloadStatus.Completed ?
            $r('app.color.nav_selected') : $r('app.color.accent_soft'))
          .accessibilityText(this.downloadState.status === ChapterDownloadStatus.Downloading ? '下载中，点按取消下载' :
            this.downloadState.status === ChapterDownloadStatus.Completed ? '已下载本章' :
              this.downloadState.status === ChapterDownloadStatus.Failed ? '下载失败，点按重试' :
                this.downloadState.status === ChapterDownloadStatus.Queued ? '排队中，点按取消排队' : '下载这一话')
          .onClick(() => this.onDownload(this.chapter))
        }
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 5, bottom: 5 })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(15)
  }
}

@ComponentV2
export struct DetailPage {
  @Param mangaId: string = '';
  /** 与壳共享的吐槽浮层可见性：系统返回键据此先关面板而不是退出详情页。 */
  @Param commentVisible: boolean = false;
  @Event commentVisibleChange: (visible: boolean) => void = (_visible: boolean) => {};
  @Event onBack: () => void = () => {};
  @Event onOpenReader: (chapterId: string, chapterName: string, chapterSize: number,
    sequence: ReaderChapterRef[]) => void =
    (_chapterId: string, _chapterName: string, _chapterSize: number,
      _sequence: ReaderChapterRef[]) => {};

  @Local detailState: BrowseLoadState = BrowseLoadState.Loading;
  @Local chapterState: BrowseLoadState = BrowseLoadState.Loading;
  @Local detail: MangaDetail | null = null;
  @Local chapters: Chapter[] = [];
  @Local visibleChapters: Chapter[] = [];
  @Local detailError: string = '';
  @Local chapterError: string = '';
  @Local descriptionExpanded: boolean = false;
  @Local ascending: boolean = true;
  /** 选择模式：默认关；点章行下载按钮进入，点「取消」或启动批次后退出。 */
  @Local selecting: boolean = false;
  /** 本页发起的批次是否被用户点了「取消下载」（只影响结束时的汇总文案，进度仍由 store 出）。 */
  private batchCancelled: boolean = false;
  /** 浮层可见性由壳托管（@Param），保证系统返回键能先关面板。 */
  private get commentPanelVisible(): boolean {
    return this.commentVisible;
  }

  private setCommentPanelVisible(visible: boolean): void {
    this.commentVisibleChange(visible);
  }
  @Local commentChapterId: string = '';
  @Local commentComicId: string = '';
  @Local commentInitialTab: CommentPanelTab = CommentPanelTab.Chapter;
  @Local session: BrowseSessionState = browseSession;
  @Local collected: boolean = false;
  @Local collectBusy: boolean = false;
  /** 勾选集合：身份稳定，ChapterRow 通过 @Trace 订阅；详情页 build 读它算计数与浮条。 */
  private selection: ChapterSelectionModel = new ChapterSelectionModel();

  private pageScroller: Scroller = detailSession.scroller;
  private pendingScrollOffset: number = 0;
  private restoreAttempts: number = 0;
  private restoreTimer: number = -1;

  aboutToAppear(): void {
    // 返回键：先退选择模式（如有），再交还壳层退出详情
    setDetailBackHandler((): boolean => this.handleInternalBack());
    if (this.restoreDetailSession()) {
      // 已有同一本漫画的快照时不刷新现有内容；仅补做当时尚未完成、且没有数据的半边请求。
      if (this.detail === null && this.detailState === BrowseLoadState.Loading) {
        this.loadDetail();
      }
      if (this.chapters.length === 0 && this.chapterState === BrowseLoadState.Loading) {
        this.loadChapters();
      }
      return;
    }

    // 不同漫画（或全新详情流程）直接丢弃旧快照，从初始态加载。
    detailSession.reset(this.mangaId);
    this.pageScroller = detailSession.scroller;
    this.detailState = BrowseLoadState.Loading;
    this.chapterState = BrowseLoadState.Loading;
    this.detail = null;
    this.chapters = [];
    this.visibleChapters = [];
    this.detailError = '';
    this.chapterError = '';
    this.descriptionExpanded = false;
    this.ascending = true;
    this.collected = false;
    this.selecting = false;
    this.selection.selectedIds = new Set<string>();
    this.selection.downloadedIds = new Set<string>();
    this.pendingScrollOffset = 0;
    this.restoreAttempts = 0;
    this.loadDetail();
    this.loadChapters();
  }

  aboutToDisappear(): void {
    setDetailBackHandler(null);
    this.clearRestoreTimer();
    this.saveDetailSession();
  }

  private restoreDetailSession(): boolean {
    if (!detailSession.matches(this.mangaId)) {
      return false;
    }
    this.pageScroller = detailSession.scroller;
    this.detail = detailSession.detail;
    this.chapters = detailSession.chapters;
    this.ascending = detailSession.ascending;
    this.descriptionExpanded = detailSession.descriptionExpanded;
    this.detailState = this.detail !== null ? BrowseLoadState.Content : detailSession.detailState;
    this.chapterState = this.chapters.length > 0 ? BrowseLoadState.Content : detailSession.chapterState;
    this.detailError = detailSession.detailError;
    this.chapterError = detailSession.chapterError;
    this.collected = detailSession.collected;
    this.collectBusy = false;
    this.selecting = detailSession.selecting;
    this.selection.selectedIds = copyIdSet(detailSession.selectedIds);
    if (this.selecting) {
      // 回到选择模式（如从阅读器返回）：锁态按当前磁盘状态重建，不沿用旧快照
      this.refreshDownloadedIds();
    }
    this.syncChapterOrder();
    this.pendingScrollOffset = detailSession.scrollOffset;
    this.restoreAttempts = 0;
    this.scheduleScrollRestore();
    return true;
  }

  private saveDetailSession(): void {
    // 回到父级页面时 Index 会先 reset；旧组件随后的卸载回调不得复活旧快照。
    if (this.pageScroller !== detailSession.scroller || detailSession.mangaId !== this.mangaId) {
      return;
    }
    detailSession.detail = this.detail;
    detailSession.chapters = this.chapters;
    detailSession.ascending = this.ascending;
    detailSession.descriptionExpanded = this.descriptionExpanded;
    detailSession.detailState = this.detailState;
    detailSession.chapterState = this.chapterState;
    detailSession.detailError = this.detailError;
    detailSession.chapterError = this.chapterError;
    detailSession.collected = this.collected;
    detailSession.selecting = this.selecting;
    detailSession.selectedIds = copyIdSet(this.selection.selectedIds);
    if (this.pendingScrollOffset > 0) {
      // 恢复尚未完成就再次进入阅读器时，继续保留原目标，不能用当前临时位置覆盖。
      detailSession.scrollOffset = this.pendingScrollOffset;
    } else {
      try {
        const offset = this.pageScroller.currentOffset();
        detailSession.scrollOffset = Math.max(0, offset.yOffset);
      } catch (error) {
        // 布局已解绑时保留上一次记录。
      }
    }
    detailSession.valid = true;
  }

  private scheduleScrollRestore(): void {
    if (this.pendingScrollOffset <= 0) {
      return;
    }
    this.clearRestoreTimer();
    this.restoreTimer = setTimeout(() => this.restoreScrollStep(), DETAIL_SCROLL_RESTORE_DELAY_MS);
  }

  private clearRestoreTimer(): void {
    if (this.restoreTimer >= 0) {
      clearTimeout(this.restoreTimer);
      this.restoreTimer = -1;
    }
  }

  private restoreScrollStep(): void {
    this.restoreTimer = -1;
    if (this.pendingScrollOffset <= 0 || this.restoreAttempts >= DETAIL_SCROLL_RESTORE_MAX_ATTEMPTS) {
      this.pendingScrollOffset = 0;
      return;
    }
    this.restoreAttempts++;
    try {
      this.pageScroller.scrollTo({
        xOffset: 0,
        yOffset: this.pendingScrollOffset,
        animation: false
      });
      const current = this.pageScroller.currentOffset();
      if (Math.abs(current.yOffset - this.pendingScrollOffset) < 4) {
        this.pendingScrollOffset = 0;
        return;
      }
    } catch (error) {
      // 长章节列表尚未完成布局，下一轮继续尝试。
    }
    this.restoreTimer = setTimeout(() => this.restoreScrollStep(), DETAIL_SCROLL_RESTORE_DELAY_MS);
  }

  private async loadDetail(): Promise<void> {
    this.detailState = BrowseLoadState.Loading;
    this.detailError = '';
    try {
      // 新鲜网络详情会覆盖本地离线缓存里的 collected（缓存恒为 false）
      await reloadBrowseSession();
      const source = await getBrowseSource();
      const detail = await source.detail(this.mangaId);
      this.detail = detail;
      // 收藏态不在详情响应里：按 H5 的做法单独查 comic2/{path_word}/query（仅在登录时；字段是 path_word）
      if (detail === null) {
        this.collected = false;
      } else if (this.session.loggedIn) {
        try {
          this.collected = await source.collectionState(detail.id);
        } catch (error) {
          // 查询失败保留现值，避免把已收藏误显示成未收藏
        }
      } else {
        this.collected = false;
      }
      this.detailState = detail === null ? BrowseLoadState.Empty : BrowseLoadState.Content;
    } catch (error) {
      this.detailError = describeBrowseError(error as Object);
      this.detailState = BrowseLoadState.Error;
    }
  }

  private async loadChapters(): Promise<void> {
    this.chapterState = BrowseLoadState.Loading;
    this.chapterError = '';
    try {
      const source = await getBrowseSource();
      const chapters = await source.chapters(this.mangaId, 'default');
      this.chapters = chapters;
      this.syncChapterOrder();
      this.chapterState = chapters.length === 0 ? BrowseLoadState.Empty : BrowseLoadState.Content;
    } catch (error) {
      this.chapterError = describeBrowseError(error as Object);
      this.chapterState = BrowseLoadState.Error;
    }
  }

  private syncChapterOrder(): void {
    const ordered: Chapter[] = [];
    if (this.ascending) {
      for (let i = 0; i < this.chapters.length; i++) {
        ordered.push(this.chapters[i]);
      }
    } else {
      for (let i = this.chapters.length - 1; i >= 0; i--) {
        ordered.push(this.chapters[i]);
      }
    }
    this.visibleChapters = ordered;
  }

  private downloadRequest(chapter: Chapter): ChapterDownloadRequest {
    const comicName = this.detail !== null && this.detail.title.length > 0 ? this.detail.title : this.mangaId;
    const request: ChapterDownloadRequest = {
      comicName: comicName,
      comicId: this.mangaId,
      chapterName: chapter.name.length > 0 ? chapter.name : '章节_' + chapter.id.substring(0, 8),
      chapterId: chapter.id
    };
    // 落盘顺序序号：取数据源自带的官方 index（与 UI 正/倒序无关）。
    // index <= 0 视为未提供，读取侧会退回自然序。
    if (chapter.index > 0) {
      request.orderIndex = chapter.index;
    }
    return request;
  }

  private async handleChapterDownload(chapter: Chapter, silent: boolean = false): Promise<ChapterDownloadStatus> {
    if (this.detail === null || this.detail.title.length === 0) {
      if (!silent) {
        this.showToast('漫画信息加载完成后才能下载');
      }
      return ChapterDownloadStatus.Idle;
    }
    const request = this.downloadRequest(chapter);
    const state = downloadStore.taskFor(request);
    if (state.status === ChapterDownloadStatus.Downloading) {
      if (!silent) {
        downloadStore.cancel(request.comicId, request.chapterId);
        this.showToast('已取消下载');
      }
      return state.status;
    }
    if (state.status === ChapterDownloadStatus.Queued) {
      // 排队中的章：点按＝出队（与「下载中点按＝取消」同一手感），不抢跑
      if (!silent) {
        downloadStore.cancel(request.comicId, request.chapterId);
        this.showToast('已取消排队');
      }
      return state.status;
    }
    if (state.status === ChapterDownloadStatus.Completed) {
      if (!silent) {
        this.showToast('该章节已下载');
      }
      return state.status;
    }
    const result = await downloadStore.downloadChapter(request, (_progress): void => {});
    if (result.status === ChapterDownloadStatus.Completed) {
      // 补进「已下载」缓存：选择模式开着时，锁态与计数立刻跟上
      this.markDownloaded(chapter.id);
    }
    if (!silent) {
      if (result.status === ChapterDownloadStatus.Completed) {
        this.showToast('章节下载完成');
      } else if (result.status === ChapterDownloadStatus.Failed) {
        this.showToast('下载失败：' + result.errorText);
      }
    }
    return result.status;
  }

  /**
   * 当前勾选数量：以完整章节列表为准（正/倒序只改展示顺序，不改勾选集合）。
   * **已下载的锁定勾选不计入**——它们是状态展示、入队必被跳过，计入会让
   * 「下载所选 (N)」大于实际排队数。缓存查表，不在 build 里打磁盘。
   */
  private selectedCount(): number {
    let count = 0;
    const ids = this.selection.selectedIds;
    const downloaded = this.selection.downloadedIds;
    for (let i = 0; i < this.chapters.length; i++) {
      const id = this.chapters[i].id;
      if (ids.has(id) && !downloaded.has(id)) {
        count++;
      }
    }
    return count;
  }

  /** 锁定判定：已下载缓存 ∪ 实时任务状态（缓存只在进/回选择模式时刷新）。 */
  private isDownloadedChapter(chapter: Chapter): boolean {
    return this.selection.downloadedIds.has(chapter.id) ||
      downloadStore.taskFor(this.downloadRequest(chapter)).status === ChapterDownloadStatus.Completed;
  }

  /** 扫一遍下载状态，重建「已下载」缓存（整趟一次磁盘遍历，供锁定勾选与计数复用）。 */
  private refreshDownloadedIds(): void {
    const next = new Set<string>();
    for (let i = 0; i < this.chapters.length; i++) {
      const chapter = this.chapters[i];
      if (downloadStore.taskFor(this.downloadRequest(chapter)).status === ChapterDownloadStatus.Completed) {
        next.add(chapter.id);
      }
    }
    this.selection.downloadedIds = next;
  }

  /** 单章落库完成时增量补缓存（批次跑着、选择模式也开着的并发场景）。 */
  private markDownloaded(chapterId: string): void {
    if (this.selection.downloadedIds.has(chapterId)) {
      return;
    }
    const next = copyIdSet(this.selection.downloadedIds);
    next.add(chapterId);
    this.selection.downloadedIds = next;
  }

  private toggleChapterSelection(chapter: Chapter): void {
    // 锁定勾选不可取消：已下载章直接忽略点击
    if (this.isDownloadedChapter(chapter)) {
      return;
    }
    const next = new Set<string>();
    this.selection.selectedIds.forEach((id: string): void => {
      next.add(id);
    });
    if (next.has(chapter.id)) {
      next.delete(chapter.id);
    } else {
      next.add(chapter.id);
    }
    this.selection.selectedIds = next;
  }

  private clearChapterSelection(): void {
    this.selection.selectedIds = new Set<string>();
  }

  /** 全选未下载：已下载 / 正在下载的章节不勾；已全部勾上则清空（等价取消全选）。 */
  private selectUndownloadedChapters(): void {
    const source = this.displayChapters();
    const next = new Set<string>();
    this.selection.selectedIds.forEach((id: string): void => {
      next.add(id);
    });
    let added = 0;
    for (let i = 0; i < source.length; i++) {
      const chapter = source[i];
      if (next.has(chapter.id)) {
        continue;
      }
      const status = downloadStore.taskFor(this.downloadRequest(chapter)).status;
      if (status === ChapterDownloadStatus.Completed || status === ChapterDownloadStatus.Downloading ||
        status === ChapterDownloadStatus.Queued) {
        continue;
      }
      next.add(chapter.id);
      added++;
    }
    this.selection.selectedIds = added > 0 ? next : new Set<string>();
  }

  private displayChapters(): Chapter[] {
    return this.visibleChapters.length > 0 ? this.visibleChapters : this.chapters;
  }

  /** 「下载所选」：按当前显示顺序整批入队；已下载 / 在跑 / 已排队的章节跳过并去掉勾选。 */
  private startSelectedDownload(): void {
    if (downloadStore.batchView.running) {
      this.showToast('批次进行中，本批结束后可继续');
      return;
    }
    if (this.detail === null || this.detail.title.length === 0) {
      this.showToast('漫画信息加载完成后才能下载');
      return;
    }
    const source = this.displayChapters();
    const requests: ChapterDownloadRequest[] = [];
    const kept = new Set<string>();
    this.selection.selectedIds.forEach((id: string): void => {
      kept.add(id);
    });
    let skipped = 0;
    for (let i = 0; i < source.length; i++) {
      const chapter = source[i];
      if (!this.selection.selectedIds.has(chapter.id)) {
        continue;
      }
      const status = downloadStore.taskFor(this.downloadRequest(chapter)).status;
      if (status === ChapterDownloadStatus.Completed || status === ChapterDownloadStatus.Downloading ||
        status === ChapterDownloadStatus.Queued) {
        kept.delete(chapter.id);
        skipped++;
        continue;
      }
      requests.push(this.downloadRequest(chapter));
    }
    const enqueued = downloadStore.enqueueChapters(requests);
    if (enqueued === 0) {
      // 没有真正入队：留在选择模式，让用户改选
      this.selection.selectedIds = kept;
      this.showToast(skipped > 0 ? '所选章节已下载或已在队列中，无需重复入队' : '请先勾选章节');
      return;
    }
    // 启动批次 → 退出选择模式、清空勾选（复选框恢复为下载按钮）
    this.selecting = false;
    this.selection.selectedIds = new Set<string>();
    this.batchCancelled = false;
    this.watchBatch(enqueued, skipped);
  }

  /**
   * 等批次跑完再收个尾：runQueue 返回的是「整队排空」的 Promise（单飞），
   * 进度与当前章名全程读 downloadStore.batchView，这里只负责结束时的汇总提示。
   * 不 await 到调用栈上——下载在 store 里继续，进阅读器（组件卸载）也不受影响。
   */
  private watchBatch(total: number, skipped: number): void {
    downloadStore.runQueue().then((): void => {
      // 完成章补进「已下载」缓存：再进选择模式时锁勾选与计数立刻正确
      this.refreshDownloadedIds();
      const done = downloadStore.batchView.done;
      const rest = Math.max(0, total - done);
      let summary: string;
      if (this.batchCancelled) {
        summary = '已取消：完成 ' + done + '/' + total + ' 章';
      } else if (rest > 0) {
        summary = '下载完成 ' + done + ' 章，' + rest + ' 章未完成（可在下载管理重试）';
      } else if (skipped > 0) {
        summary = '下载完成 ' + done + ' 章，跳过已下载 ' + skipped + ' 章';
      } else {
        summary = '下载完成：' + done + ' 章';
      }
      // 组件已卸载（进了阅读器）时 showToast 内部会自己失败，不影响批次收尾
      this.showToast(summary);
    }).catch((_error: Object): void => {
      // 执行器内部不外抛，这里只兜底
    });
  }

  /**
   * 进入选择模式（由章节头部的「多选下载」按钮进入）：**不预选任何章** ——
   * 勾选交给用户点复选框或「全选未下载」。其余行为（复选框、下载所选、取消、
   * 开跑即退出、返回先退模式、会话保存）全部沿用。
   */
  private enterSelectMode(): void {
    if (this.chapters.length === 0) {
      this.showToast('章节列表加载完成后才能下载');
      return;
    }
    this.selection.selectedIds = new Set<string>();
    // 重建「已下载」缓存：决定哪些章显示锁定勾选、哪些计入 N
    this.refreshDownloadedIds();
    this.selecting = true;
  }

  /** 显式退出选择模式：同时清空勾选，避免下次进入残留。 */
  /** 详情页内部返回消费：选择模式先退出；其余交给壳层（退出详情）。 */
  private handleInternalBack(): boolean {
    if (this.selecting) {
      this.exitSelectMode();
      return true;
    }
    return false;
  }

  private exitSelectMode(): void {
    this.selecting = false;
    this.selection.selectedIds = new Set<string>();
  }

  /**
   * 批次取消：走 store 的 cancelBatch() —— 本批在跑的章收口、还在排队的整串出队，
   * 执行器随即因队列排空而结束，watchBatch 收尾时按「已取消」给汇总。
   */
  private cancelSelectedDownload(): void {
    if (!downloadStore.batchView.running) {
      return;
    }
    this.batchCancelled = true;
    downloadStore.cancelBatch();
  }

  private toggleChapterOrder(): void {
    this.ascending = !this.ascending;
    this.syncChapterOrder();
  }

  private openComicComments(): void {
    if (this.detail === null || this.detail.uuid.length === 0) {
      this.showToast('暂无可用的漫画标识');
      return;
    }
    this.commentChapterId = '';
    this.commentComicId = this.detail.uuid;
    this.commentInitialTab = CommentPanelTab.Comic;
    this.setCommentPanelVisible(true);
  }

  private async toggleCollect(): Promise<void> {
    if (this.collectBusy) {
      return;
    }
    if (!this.session.loggedIn) {
      this.showToast('请先登录');
      return;
    }
    const detail = this.detail;
    if (detail === null || detail.uuid.length === 0) {
      this.showToast('暂无可用的漫画标识');
      return;
    }

    const nextCollected = !this.collected;
    this.collectBusy = true;
    this.collected = nextCollected;
    try {
      const source = await getBrowseSource();
      // 收藏接口必须用 uuid，不是 path_word
      await source.collect(detail.uuid, nextCollected);
      this.showToast(nextCollected ? '已收藏' : '已取消收藏');
    } catch (error) {
      // 回滚按钮态
      this.collected = !nextCollected;
      this.showToast('操作失败：' + describeBrowseError(error as Object));
    } finally {
      this.collectBusy = false;
    }
  }

  private openChapterReader(chapter: Chapter): void {
    if (this.mangaId.length === 0 || chapter.id.length === 0) {
      this.showToast('章节信息不完整');
      return;
    }
    const chapterName = chapter.name.length > 0 ? chapter.name : '第 ' + chapter.index + ' 话';
    // 阅读器"原地切章 / 到头确认 / 80% 预取"需要**按阅读顺序**（index 升序）的章节序列，
    // 与当前展示的正/倒序无关；这里以 chapters 的 index 排序后组装。
    const ordered: Chapter[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      ordered.push(this.chapters[i]);
    }
    ordered.sort((a: Chapter, b: Chapter): number => a.index - b.index);
    const refs: ReaderChapterRef[] = [];
    for (let i = 0; i < ordered.length; i++) {
      const c = ordered[i];
      refs.push(new ReaderChapterRef(c.id, c.name.length > 0 ? c.name : '第 ' + c.index + ' 话', c.size));
    }
    // 路由切换前先抓一次精确位置；aboutToDisappear 仍会再兜底保存。
    this.saveDetailSession();
    this.onOpenReader(chapter.id, chapterName, chapter.size, refs);
  }

  private openChapterComments(chapter: Chapter): void {
    this.commentChapterId = chapter.id;
    this.commentComicId = this.detail === null ? '' : this.detail.uuid;
    this.commentInitialTab = CommentPanelTab.Chapter;
    this.setCommentPanelVisible(true);
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  /** 让浮条避开系统导航条（与壳里 BottomBar 同一套 inset 取法）。 */
  private safeBottom(): number {
    const inset = AppStorage.get<number>('navIndicatorVp');
    return inset === undefined ? 12 : Math.max(12, inset);
  }

  /** 选择模式浮条：已选计数 + 清空 / 取消（显式退出）+ 全宽「下载所选 (N)」。 */
  @Builder
  selectBar() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('已选 ' + this.selectedCount() + ' 章')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(downloadStore.batchView.running ?
            '批次进行中 ' + downloadStore.batchView.done + '/' + downloadStore.batchView.total + '，本批结束后可继续' :
            '已下载章固定勾选，不计入数量')
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('清空')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(32)
          .padding({ left: 12, right: 12 })
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(12)
          .onClick(() => this.clearChapterSelection())
        Button('取消')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(32)
          .padding({ left: 12, right: 12 })
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive,
            themeState().themeRevision))
          .borderRadius(12)
          .accessibilityText('退出选择模式并清空勾选')
          .onClick(() => this.exitSelectMode())
      }
      .width('100%')

      Button('下载所选 (' + this.selectedCount() + ')')
        .type(ButtonType.Normal)
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .backgroundColor($r('app.color.primary'))
        .borderRadius(14)
        .enabled(!downloadStore.batchView.running && this.selectedCount() > 0)
        // 未满足条件时压暗，避免看起来可点却没反应
        .opacity(!downloadStore.batchView.running && this.selectedCount() > 0 ? 1 : 0.45)
        .accessibilityText('下载已勾选的章节并退出选择模式')
        .onClick(() => this.startSelectedDownload())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .margin({ left: 16, right: 16, bottom: this.safeBottom() })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(20)
    .shadow({ radius: 16, color: $r('app.color.panel_shadow'), offsetX: 0, offsetY: -4 })
  }

  /** 批次进行中浮条：进度 + 取消下载（单行，进度本身看行内徽标）。 */
  @Builder
  batchBar() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('下载中 ' + downloadStore.batchView.done + '/' + downloadStore.batchView.total)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(downloadStore.batchView.currentChapterName)
          .fontSize(11)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('取消下载')
        .type(ButtonType.Normal)
        .stateEffect(true)
        .height(40)
        .padding({ left: 16, right: 16 })
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.accent_soft'))
        .borderRadius(14)
        .onClick(() => this.cancelSelectedDownload())
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .margin({ left: 16, right: 16, bottom: this.safeBottom() })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(20)
    .shadow({ radius: 16, color: $r('app.color.panel_shadow'), offsetX: 0, offsetY: -4 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      Row({ space: 10 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(21)
            .fontColor([$r('app.color.primary_text')])
        }
        .width(40)
        .height(40)
        .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        .onClick(() => this.onBack())
        Column({ space: 2 }) {
          Text('漫画详情')
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.detail === null || this.detail.title.length === 0 ? this.mangaId : this.detail.title)
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      Scroll(this.pageScroller) {
        Column({ space: 14 }) {
          // 占位 ↔ 内容：Stack 原地叠放 + 交叉溶解。占位退场时不再留在流式布局里，
          // 下方「章节」标题行不会被顶一下再弹回（容器高度按两者最大值取）。
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.detailState === BrowseLoadState.Content && this.detail !== null) {
              DetailOverview({
                detail: this.detail as MangaDetail,
                expanded: this.descriptionExpanded,
                collected: this.collected,
                collectBusy: this.collectBusy,
                onToggleDescription: (): void => {
                  this.descriptionExpanded = !this.descriptionExpanded;
                },
                onOpenComments: (): void => this.openComicComments(),
                onToggleCollect: (): void => {
                  this.toggleCollect();
                }
              })
              .transition(fadeSwapTransition())
            } else {
              DetailStatePanel({
                state: this.detailState,
                label: '详情',
                errorText: this.detailError,
                onRetry: (): void => {
                  this.loadDetail();
                }
              })
              .transition(fadeSwapTransition())
            }
          }
          .width('100%')

          Row() {
            Column({ space: 3 }) {
              Text('章节')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Text(this.chapterState === BrowseLoadState.Content ? this.visibleChapters.length + ' 章' : '独立加载')
                .fontSize(11)
                .fontColor($r('app.color.secondary_text'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.selecting) {
              // 选择模式才出现的「全选未下载」；此时头部左侧仍保留同位的胶囊（下面的「多选下载」隐藏）
              Button('全选未下载')
                .type(ButtonType.Normal)
                .height(36)
                .padding({ left: 13, right: 13 })
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.accent_soft'))
                .borderRadius(18)
                .margin({ right: 8 })
                .enabled(this.chapterState === BrowseLoadState.Content && this.chapters.length > 0 &&
                  !downloadStore.batchView.running)
                .accessibilityText('勾选全部未下载章节')
                .onClick(() => this.selectUndownloadedChapters())
            } else {
              // 章节多选入口：正序/倒序左侧的同款胶囊；点击进入选择模式（**不预选任何章**）
              Button('多选下载')
                .type(ButtonType.Normal)
                .height(36)
                .padding({ left: 13, right: 13 })
                .fontSize(12)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.accent_soft'))
                .borderRadius(18)
                .margin({ right: 8 })
                .enabled(this.chapterState === BrowseLoadState.Content)
                .accessibilityText('进入章节多选模式，不预选章节')
                .onClick(() => this.enterSelectMode())
            }
            Button(this.ascending ? '正序' : '倒序')
              .type(ButtonType.Normal)
              .height(36)
              .padding({ left: 15, right: 15 })
              .fontSize(12)
              .fontColor($r('app.color.primary'))
              .backgroundColor($r('app.color.accent_soft'))
              .borderRadius(18)
              .enabled(this.chapterState === BrowseLoadState.Content)
              .onClick(() => this.toggleChapterOrder())
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 6 })

          // 章节占位 ↔ 章节列表：同样原地叠放 + 交叉溶解，占位退场不挤动下方内容
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.chapterState === BrowseLoadState.Content) {
              Column({ space: 8 }) {
                ForEach(this.visibleChapters, (chapter: Chapter, index: number) => {
                  ChapterRow({
                    chapter: chapter,
                    downloadState: downloadStore.taskFor(this.downloadRequest(chapter)),
                    selection: this.selection,
                    selecting: this.selecting,
                    onRead: (selected: Chapter): void => {
                      this.openChapterReader(selected);
                    },
                    onComments: (selected: Chapter): void => {
                      this.openChapterComments(selected);
                    },
                    onToggleSelect: (target: Chapter): void => {
                      this.toggleChapterSelection(target);
                    },
                    onDownload: (target: Chapter): void => {
                      // 章行下载按钮＝**单章直下**（含 下载中/已下载/失败 状态，下载中点按即取消）；
                      // 进多选模式改由章节头部的「多选下载」按钮负责。
                      this.handleChapterDownload(target).catch((error: Error): void => {
                        this.showToast('下载失败：' + error.message);
                      });
                    }
                  })
                }, (chapter: Chapter, index: number) => chapter.id + ':' + index.toString())
              }
              .width('100%')
              .transition(fadeSwapTransition())
            } else {
              DetailStatePanel({
                state: this.chapterState,
                label: '章节',
                errorText: this.chapterError,
                onRetry: (): void => {
                  this.loadChapters();
                }
              })
              .transition(fadeSwapTransition())
            }
          }
          .width('100%')
        }
        .width('100%')
        // 底部浮条出现时多留一段（选择条是两行更高），避免最后一章被盖住
        .padding({
          left: 16,
          right: 16,
          bottom: this.selecting ? 156 : (downloadStore.batchView.running ? 118 : 48)
        })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))

      if (this.selecting) {
        this.selectBar()
      } else if (downloadStore.batchView.running) {
        this.batchBar()
      }

      // 面板常驻挂载：退场动画要由面板内部的条件渲染跑完，包一层 if 会在关闭时整棵销毁、动画没机会播。
      CommentPanel({
        visible: this.commentPanelVisible,
        chapterId: this.commentChapterId,
        comicId: this.commentComicId,
        initialTab: this.commentInitialTab,
        onClose: (): void => {
          this.setCommentPanelVisible(false);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
