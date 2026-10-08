/** 下载管理：顶部封面卡片网格（对齐发现页卡片语言），点进去仍是原来的章节两级目录。 */
import {
  downloadStore,
  DownloadedChapterInfo,
  DownloadedComicInfo
} from './DownloadStore';
import { localImageUri } from './HiddenCollector';
import {
  GRID_SIDE_PADDING,
  gridColumnsForWidth,
  gridColumnsTemplate
} from './BrowseSupport';
import { imageCacheTrim } from '../services/ImageCacheTrim';
import { themeBackground, themeState } from './ThemeColors';
import { ReaderChapterRef } from './ReaderPage';

/**
 * 本次进页面已经尝试补拉封面的作品目录。
 * 离线时接口必失败，靠它避免每次重绘都打一遍；点刷新会清空，把重试机会还给用户。
 */
const coverRequested: Set<string> = new Set<string>();

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return (bytes / 1024 / 1024 / 1024).toFixed(2) + ' GB';
  }
  if (bytes >= 1024 * 1024) {
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return bytes + ' B';
}

/** Set 不可变拷贝：@Trace 的 selectedKeys 每次都要整体替换成新集合才触发通知。 */
function copyKeySet(source: Set<string>): Set<string> {
  const next = new Set<string>();
  source.forEach((key: string): void => {
    next.add(key);
  });
  return next;
}

/**
 * 章节批量删除的勾选模型：身份稳定，行组件通过 @Param + @Trace 直接订阅自己那行的勾选态
 * （不必等 ForEach 重建），页面 build 读它算计数、浮条与头部胶囊。
 */
@ObservedV2
class ChapterSelectionModel {
  @Trace selecting: boolean = false;
  @Trace selectedKeys: Set<string> = new Set<string>();
}

@ComponentV2
struct DownloadPageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 头部动作胶囊文案：空串＝不渲染（「我的下载」不传，保持原样）。 */
  @Param actionText: string = '';
  @Event onBack: () => void = () => {};
  @Event onRefresh: () => void = () => {};
  /** 头部动作点击：章节页用来进「批量删除」选择模式。 */
  @Event onAction: () => void = () => {};

  build() {
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
        Text(this.title)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          // 右侧可能多了动作胶囊：标题单行截断，长名字不再把头部撑成两三行
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.actionText.length > 0) {
        // 头部动作胶囊：样式对齐详情页章节头部的「多选下载」胶囊（34 高 / 12 号字 / accent_soft）
        Button(this.actionText)
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(34)
          .padding({ left: 13, right: 13 })
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(17)
          .margin({ right: 8 })
          .accessibilityText(this.actionText + '，进入章节选择模式')
          .onClick(() => this.onAction())
      }
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(19)
          .fontColor([$r('app.color.primary')])
      }
      .width(38)
      .height(38)
      .backgroundColor($r('app.color.accent_soft'))
      .onClick(() => this.onRefresh())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
  }
}

@ComponentV2
struct DownloadEmptyState {
  @Param text: string = '还没有下载任何章节';

  build() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.arrow_down_circle'))
        .fontSize(42)
        .fontColor([$r('app.color.secondary_text')])
      Text(this.text)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
      Text('在漫画详情页选择章节即可开始下载')
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
        .textAlign(TextAlign.Center)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(24)
  }
}

/**
 * 下载列表数据源：交给 LazyForEach，只有滚到的格子才会建卡片与解码封面
 * （同发现页 MangaListDataSource 的做法）。
 */
class DownloadedComicSource implements IDataSource {
  private items: DownloadedComicInfo[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): DownloadedComicInfo {
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

  replace(items: DownloadedComicInfo[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

/**
 * 下载项封面卡片：尺寸 / 圆角 / 阴影 / 文字层级全部对齐发现页的 MangaGridCard
 * （封面 228、正文 66、整卡 294、radius 18），只是把「作者」行换成本地统计。
 */
@ComponentV2
struct DownloadComicCard {
  @Param item: DownloadedComicInfo = {
    name: '', comicId: '', directory: '', chapterCount: 0, completedCount: 0, pageCount: 0, bytes: 0
  };
  @Event onOpen: (item: DownloadedComicInfo) => void = (_item: DownloadedComicInfo) => {};
  @Event onDelete: (item: DownloadedComicInfo) => void = (_item: DownloadedComicInfo) => {};
  /** 当前封面来源：本地文件 → 元数据里的 URL → 空串（走主题占位）。 */
  @Local cover: string = '';
  /** TouchDown 即时按压：不等 onClick；Up / Cancel（手指被滚动抢走）都要复位，别卡在缩小态。 */
  @Local pressed: boolean = false;

  aboutToAppear(): void {
    this.cover = this.resolveCover();
    // 补拉封面放在这里而不是 build()：@Entry 组件的 build 只能是单一容器根、不能带前置语句；
    // 刷新会走 onDataReloaded 重建卡片，从而再次走到这里（配合 coverRequested 去重）。
    this.requestCover();
  }

  /**
   * 封面来源优先级：
   *  1. 作品目录里的封面字节（离线可用，下载时顺手缓存）；
   *  2. 元数据里的封面 URL（吃系统缓存，在线即可显示）；
   *  3. 都没有 → 空串，由底下那层主题底色 + 首字占位兜住。
   */
  private resolveCover(): string {
    const local = downloadStore.comicCoverPath(this.item.directory);
    if (local.length > 0) {
      return localImageUri(local);
    }
    return downloadStore.coverUrl(this.item.directory);
  }

  /**
   * 没有本地封面字节时补拉一次（先存 URL，再把图片落到作品目录）。
   *
   * 调用点在卡片 aboutToAppear（build 里不能写前置语句）：刷新 → onDataReloaded
   * 重建卡片 → 再次调用；配合 coverRequested 去重，既不重复打接口（幂等：有本地封面直接返回），
   * 也让「刷新=再试一次」成立。
   */
  private requestCover(): void {
    if (this.cover.startsWith('file://') || this.item.comicId.length === 0) {
      return;
    }
    if (coverRequested.has(this.item.directory)) {
      return;
    }
    coverRequested.add(this.item.directory);
    downloadStore.ensureComicCover(this.item.directory, this.item.comicId)
      .then((): void => {
        // 只在「本地字节真的落盘」时换源：避免 URL → file:// 白闪一下
        const local = downloadStore.comicCoverPath(this.item.directory);
        if (local.length > 0) {
          this.cover = localImageUri(local);
        }
      })
      .catch((_error: Object): void => {});
  }

  private titleText(): string {
    return this.item.name.length > 0 ? this.item.name : '未命名漫画';
  }

  /** 占位首字：没有封面时透主题底色 + 作品名首字，不引第三方图也不闪。 */
  private monogram(): string {
    const name = this.item.name.trim();
    return name.length > 0 ? name.substring(0, 1) : '漫';
  }

  private metaText(): string {
    const done = this.item.completedCount < this.item.chapterCount ?
      this.item.completedCount + '/' + this.item.chapterCount : String(this.item.chapterCount);
    return done + ' 章 · ' + this.item.pageCount + ' 页 · ' + formatBytes(this.item.bytes);
  }

  build() {
    // 外层 Stack 只负责把删除按钮叠在封面右上角：按钮与内层卡片是兄弟节点，
    // 点删除不会冒泡成「打开作品」。
    Stack({ alignContent: Alignment.TopEnd }) {
      // 内层 Stack 才是卡片内容区：按压缩放与按压叠层都挂在它身上，
      // 与删除按钮的兄弟关系不受影响。
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))

            Text(this.monogram())
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.secondary_text'))

            if (this.cover.length > 0) {
              Image(this.cover)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .borderRadius({ topLeft: 18, topRight: 18 })
            }
          }
          .width('100%')
          .height(228)

          Column({ space: 5 }) {
            Text(this.titleText())
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.metaText())
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

        // 按压叠层：贴住卡片内容区、圆角对齐 18；只借既有文字色，不新增色值——
        // 亮色主题压一层黑（微暗），暗色主题抬一层白（微亮）
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(18)
          .backgroundColor($r('app.color.primary_text'))
          .opacity(this.pressed ? 0.06 : 0)
          // 与缩放同参数：有的版本 animation 不跨节点下推，少了这条叠层会跳一下
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
      .onClick(() => this.onOpen(this.item))

      Button('删除')
        .type(ButtonType.Normal)
        .height(30)
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
        .borderRadius(15)
        .padding({ left: 11, right: 11 })
        .shadow({ radius: 6, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 2 })
        .margin({ top: 10, right: 10 })
        .onClick(() => this.onDelete(this.item))
    }
    .width('100%')
  }
}

@ComponentV2
struct DownloadChapterRow {
  @Param item: DownloadedChapterInfo = {
    name: '', uuid: '', comicId: '', directory: '', completed: false, pageCount: 0, bytes: 0
  };
  /** 选择模式与勾选集合：build 里直接读 @Trace 字段，勾选态变化自己刷自己。 */
  @Param selection: ChapterSelectionModel = new ChapterSelectionModel();
  @Event onOpen: (item: DownloadedChapterInfo) => void = (_item: DownloadedChapterInfo) => {};
  @Event onDelete: (item: DownloadedChapterInfo) => void = (_item: DownloadedChapterInfo) => {};
  /** 勾选切换：选择模式下点行与点勾选圈都走这里。 */
  @Event onToggleSelect: (item: DownloadedChapterInfo) => void = (_item: DownloadedChapterInfo) => {};
  /** TouchDown 即时按压（对齐卡片手感 0.95 / 160ms）：Up 与 Cancel 都要复位，别卡在缩小态。 */
  @Local pressed: boolean = false;

  private selecting(): boolean {
    return this.selection.selecting;
  }

  private selected(): boolean {
    return this.selection.selectedKeys.has(this.item.directory);
  }

  build() {
    Row({ space: 12 }) {
      // 状态图标 + 正文合成一个按压/点击块：右侧控件（删除 / 勾选圈）是它的兄弟节点，
      // 点右侧不会冒泡成「点行」，按压缩放也只收这一块。
      Row({ space: 12 }) {
        SymbolGlyph(this.item.completed ? $r('sys.symbol.checkmark_circle_fill') :
          $r('sys.symbol.exclamationmark_circle'))
          .fontSize(24)
          .fontColor([this.item.completed ? $r('app.color.primary') : $r('app.color.accent')])
          .width(36)
        Column({ space: 5 }) {
          Text(this.item.name)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text((this.item.completed ? '下载完成' : '未完成') + ' · ' + this.item.pageCount + ' 页 · ' +
            formatBytes(this.item.bytes))
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      // 按压反馈：只挂在这一块上（删除按钮与勾选圈有自己的按压），
      // 幅度对齐卡片 —— 0.95 / 160ms FastOutSlowIn
      .scale({ x: this.pressed ? 0.95 : 1, y: this.pressed ? 0.95 : 1 })
      .animation({ duration: 160, curve: Curve.FastOutSlowIn })
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.pressed = true;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressed = false;
        }
      })
      .onClick((): void => {
        // 选择模式点行＝勾选/取消；默认点行＝打开阅读器（行为不变）
        if (this.selecting()) {
          this.onToggleSelect(this.item);
        } else {
          this.onOpen(this.item);
        }
      })

      if (this.selecting()) {
        // 勾选圈（26 圆）：选中＝主题色实心 + 白勾，未选＝空心描边；全部借既有色值
        Stack({ alignContent: Alignment.Center }) {
          if (this.selected()) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(13)
              .fontColor([$r('app.color.on_primary')])
          }
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor(this.selected() ? $r('app.color.primary') : Color.Transparent)
        .border({
          width: this.selected() ? 0 : 2,
          color: this.selected() ? $r('app.color.nav_item_clear') : $r('app.color.divider')
        })
        .accessibilityText(this.selected() ? '已选中本章，点按取消选择' : '未选中本章，点按选择本章')
        .onClick(() => this.onToggleSelect(this.item))
      } else {
        Button('删除')
          .type(ButtonType.Normal)
          .height(34)
          .fontSize(11)
          .fontColor($r('app.color.accent'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(11)
          .onClick(() => this.onDelete(this.item))
      }
    }
    .width('100%')
    .padding(12)
    // 选中的行给一层主题强调底色：批量删除前一眼能扫出勾了哪些
    .backgroundColor(this.selecting() && this.selected() ? $r('app.color.accent_soft') :
      themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(16)
  }
}

@ComponentV2
export struct DownloadsPage {
  @Event onBack: () => void = () => {};
  @Event onOpenComic: (directory: string, name: string) => void = (_directory: string, _name: string) => {};

  @Local loading: boolean = true;
  @Local comics: DownloadedComicInfo[] = [];
  @Local totalBytes: number = 0;
  @Local errorText: string = '';
  /** 网格列数（2/3/4/5 随可用宽度自适应），与发现/收藏网格同一套阈值。 */
  @Local columns: number = 2;
  /** 稳定持有的懒加载数据源：整个页面生命周期内只建一次。 */
  private dataSource: DownloadedComicSource = new DownloadedComicSource();

  aboutToAppear(): void {
    this.reload();
    // 触发点之一（非 Index）：ImageCacheTrim 内部 45 秒最小间隔 + 单飞
    imageCacheTrim.maybeTrim();
  }

  /** 按实测容器宽度更新列数：列数不变时不写 @Local，切列只重排一次、不逐帧抖动。 */
  private applyColumns(width: number): void {
    if (!(width > 0)) {
      return;
    }
    const columns = gridColumnsForWidth(width - GRID_SIDE_PADDING);
    if (columns !== this.columns) {
      this.columns = columns;
    }
  }

  private reload(): void {
    this.loading = true;
    this.errorText = '';
    // 刷新 = 再给封面一次补拉机会（上次离线进过页，联网后点这里就能补上）
    coverRequested.clear();
    try {
      const items = downloadStore.listDownloadedComics();
      this.comics = items;
      this.dataSource.replace(items);
      this.totalBytes = downloadStore.totalBytes();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined ? value.message : '读取下载目录失败';
    } finally {
      this.loading = false;
    }
  }

  private deleteComic(item: DownloadedComicInfo): void {
    try {
      downloadStore.deleteComic(item.directory);
      this.reload();
      this.showToast('已删除《' + item.name + '》');
    } catch (error) {
      this.showToast('删除失败');
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  build() {
    Column() {
      DownloadPageHeader({
        title: '我的下载',
        subtitle: this.loading ? '正在统计…' : '占用 ' + formatBytes(this.totalBytes),
        onBack: (): void => this.onBack(),
        onRefresh: (): void => this.reload()
      })

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(34)
            .height(34)
            .color($r('app.color.primary'))
          Text('正在读取下载目录…')
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .layoutWeight(1)
      } else if (this.errorText.length > 0) {
        Column({ space: 12 }) {
          Text('下载目录读取失败')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.errorText)
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
          Button('重试')
            .type(ButtonType.Normal)
            .height(40)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .borderRadius(13)
            .onClick(() => this.reload())
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .layoutWeight(1)
      } else if (this.comics.length === 0) {
        DownloadEmptyState()
      } else {
        Grid() {
          LazyForEach(this.dataSource, (item: DownloadedComicInfo, index: number) => {
            GridItem() {
              DownloadComicCard({
                item: item,
                onOpen: (selected: DownloadedComicInfo): void => {
                  this.onOpenComic(selected.directory, selected.name);
                },
                onDelete: (selected: DownloadedComicInfo): void => this.deleteComic(selected)
              })
            }
          }, (item: DownloadedComicInfo, index: number) => item.directory + ':' + index.toString())
        }
        .columnsTemplate(gridColumnsTemplate(this.columns))
        .columnsGap(12)
        .rowsGap(14)
        .cachedCount(6)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8, bottom: 48 })
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    // 容器实测宽度 → 列数（阈值 520/760/1000）；加载/空态也量得到，网格出现即为正确列数
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.applyColumns(newArea.width as number);
    })
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

/* ==================== 章节列表（离线） ==================== */

@ComponentV2
export struct DownloadChaptersPage {
  @Param comicDirectory: string = '';
  @Param comicName: string = '';
  @Event onBack: () => void = () => {};
  /** 离线打开阅读器：comicId + chapterUuid + 章节名 + 本地页数 + 已下载章节序列（均不通网络）。 */
  @Event onOpenOfflineReader: (comicId: string, chapterUuid: string, chapterName: string,
    localPageCount: number, sequence: ReaderChapterRef[]) => void =
    (_comicId: string, _chapterUuid: string, _chapterName: string, _localPageCount: number,
      _sequence: ReaderChapterRef[]) => {};

  @Local chapters: DownloadedChapterInfo[] = [];
  @Local totalBytes: number = 0;
  /** 勾选模型：身份稳定，DownloadChapterRow 通过 @Trace 订阅；本页 build 读它算计数与浮条。 */
  private selection: ChapterSelectionModel = new ChapterSelectionModel();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.chapters = downloadStore.listDownloadedChapters(this.comicDirectory);
    this.totalBytes = 0;
    for (let i = 0; i < this.chapters.length; i++) {
      this.totalBytes += this.chapters[i].bytes;
    }
    // 选择模式里点了「刷新」：把已经不在列表里的目录从勾选集合里摘掉，计数不虚高
    if (this.selection.selecting) {
      const alive = new Set<string>();
      for (let i = 0; i < this.chapters.length; i++) {
        alive.add(this.chapters[i].directory);
      }
      const next = new Set<string>();
      this.selection.selectedKeys.forEach((key: string): void => {
        if (alive.has(key)) {
          next.add(key);
        }
      });
      this.selection.selectedKeys = next;
    }
  }

  private deleteChapter(item: DownloadedChapterInfo): void {
    try {
      downloadStore.deleteChapter(this.comicDirectory, item.directory);
      this.reload();
      this.showToast('已删除章节');
    } catch (error) {
      this.showToast('删除失败');
    }
  }

  /* ==================== 批量删除：选择模式 ==================== */

  /** 进入选择模式：不预选任何章，勾选交给点行 / 「全选」。 */
  private enterSelectMode(): void {
    if (this.chapters.length === 0) {
      return;
    }
    this.selection.selectedKeys = new Set<string>();
    this.selection.selecting = true;
  }

  private exitSelectMode(): void {
    this.selection.selecting = false;
    this.selection.selectedKeys = new Set<string>();
  }

  private selectedCount(): number {
    return this.selection.selectedKeys.size;
  }

  private allSelected(): boolean {
    return this.chapters.length > 0 &&
      this.selection.selectedKeys.size === this.chapters.length;
  }

  /** 点行 / 点勾选圈：整份替换成新 Set，@Trace 通知行组件重绘。 */
  private toggleSelect(item: DownloadedChapterInfo): void {
    const next = copyKeySet(this.selection.selectedKeys);
    if (next.has(item.directory)) {
      next.delete(item.directory);
    } else {
      next.add(item.directory);
    }
    this.selection.selectedKeys = next;
  }

  /** 全选 ↔ 取消全选：已全选就清空，否则勾上全部章节。 */
  private toggleAllSelect(): void {
    if (this.allSelected()) {
      this.selection.selectedKeys = new Set<string>();
      return;
    }
    const next = new Set<string>();
    for (let i = 0; i < this.chapters.length; i++) {
      next.add(this.chapters[i].directory);
    }
    this.selection.selectedKeys = next;
  }

  /**
   * 批量删除：二次确认弹窗 → 逐章调 store.deleteChapter（索引维护与空目录判定都在里面）
   * → 退出选择模式 + reload() + toast。全删光时空态由 chapters.length === 0 自然接管。
   */
  private async deleteSelectedChapters(): Promise<void> {
    const targets: DownloadedChapterInfo[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      const chapter = this.chapters[i];
      if (this.selection.selectedKeys.has(chapter.directory)) {
        targets.push(chapter);
      }
    }
    if (targets.length === 0) {
      return;
    }
    try {
      const response = await this.getUIContext().getPromptAction().showDialog({
        title: '删除所选章节？',
        message: '将删除选中的 ' + targets.length + ' 章，删除后不可恢复。',
        buttons: [
          { text: '取消', color: $r('app.color.secondary_text') },
          { text: '确认删除', color: $r('app.color.accent') }
        ],
        backgroundColor: themeBackground('surface', themeState().amoledActive, themeState().themeRevision),
        backgroundBlurStyle: BlurStyle.NONE
      });
      if (response.index !== 1) {
        return;
      }
    } catch (error) {
      this.showToast('确认弹窗不可用，未删除任何章节');
      return;
    }
    let removed = 0;
    for (let i = 0; i < targets.length; i++) {
      try {
        downloadStore.deleteChapter(this.comicDirectory, targets[i].directory);
        removed++;
      } catch (error) {
      }
    }
    this.exitSelectMode();
    this.reload();
    this.showToast(removed > 0 ? '已删除 ' + removed + ' 章' : '删除失败');
  }

  /** 让浮条避开系统导航条（与详情页浮条同一套 inset 取法）。 */
  private safeBottom(): number {
    const inset = AppStorage.get<number>('navIndicatorVp');
    return inset === undefined ? 12 : Math.max(12, inset);
  }

  /**
   * 选择模式底部浮条：已选计数 + 全选 / 取消全选 + 退出选择模式，
   * 下面是全宽「删除选中的 N 章」。结构与配色对齐详情页 selectBar（本页自包含实现）。
   */
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
          Text('点行即可勾选或取消')
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.allSelected() ? '取消全选' : '全选')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(32)
          .padding({ left: 11, right: 11 })
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(12)
          .enabled(this.chapters.length > 0)
          .accessibilityText(this.allSelected() ? '取消全选章节' : '勾选全部章节')
          .onClick(() => this.toggleAllSelect())
        Button('退出选择模式')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(32)
          .padding({ left: 11, right: 11 })
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive,
            themeState().themeRevision))
          .borderRadius(12)
          .accessibilityText('退出选择模式并清空勾选')
          .onClick(() => this.exitSelectMode())
      }
      .width('100%')

      Button('删除选中的 ' + this.selectedCount() + ' 章')
        .type(ButtonType.Normal)
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .backgroundColor($r('app.color.primary'))
        .borderRadius(14)
        .enabled(this.selectedCount() > 0)
        // 一章没勾时压暗，避免看起来可点却没反应
        .opacity(this.selectedCount() > 0 ? 1 : 0.45)
        .accessibilityText('删除已勾选的章节，会先二次确认')
        .onClick(() => {
          this.deleteSelectedChapters().catch((_error: Object): void => {});
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .margin({ left: 16, right: 16, bottom: this.safeBottom() })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(20)
    .shadow({ radius: 16, color: $r('app.color.panel_shadow'), offsetX: 0, offsetY: -4 })
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  /** 离线章节可能没写 comicId：从已下载列表里回退取本章/本漫画的 comicId（纯本地读取）。 */
  private chapterComicId(): string {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].comicId.length > 0) {
        return this.chapters[i].comicId;
      }
    }
    return '';
  }

  /** 已下载完成章节的阅读序列（仅 completed，按列表顺序），供离线阅读器原地切章。 */
  private offlineChapterSequence(): ReaderChapterRef[] {
    const sequence: ReaderChapterRef[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      const chapter = this.chapters[i];
      if (chapter.completed) {
        sequence.push(new ReaderChapterRef(chapter.uuid, chapter.name, chapter.pageCount));
      }
    }
    return sequence;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        DownloadPageHeader({
          title: this.comicName,
          subtitle: this.chapters.length + ' 章 · ' + formatBytes(this.totalBytes),
          // 选择模式里头部让位给底部浮条（退出在浮条上），空态不给入口
          actionText: !this.selection.selecting && this.chapters.length > 0 ? '批量删除' : '',
          onBack: (): void => this.onBack(),
          onRefresh: (): void => this.reload(),
          onAction: (): void => this.enterSelectMode()
        })

        if (this.chapters.length === 0) {
          DownloadEmptyState({ text: '这部漫画还没有下载章节' })
        } else {
          List({ space: 9 }) {
            ForEach(this.chapters, (item: DownloadedChapterInfo) => {
              ListItem() {
                DownloadChapterRow({
                  item: item,
                  selection: this.selection,
                  onOpen: (selected: DownloadedChapterInfo): void => {
                    const offline = downloadStore.loadOfflineChapter(selected.directory);
                    if (offline === null || !offline.completed) {
                      this.showToast('章节尚未下载完成');
                      return;
                    }
                    // 离线打开：本地沙箱图，不做任何网络请求（飞行模式可用）；
                    // 带上仅完成章节的阅读序列，原地切章与到头确认按该序列工作
                    this.onOpenOfflineReader(
                      offline.comicId.length > 0 ? offline.comicId : this.chapterComicId(),
                      offline.uuid,
                      offline.name,
                      offline.imagePaths.length,
                      this.offlineChapterSequence()
                    );
                  },
                  onDelete: (selected: DownloadedChapterInfo): void => this.deleteChapter(selected),
                  onToggleSelect: (selected: DownloadedChapterInfo): void => this.toggleSelect(selected)
                })
              }
            }, (item: DownloadedChapterInfo) => item.directory)
          }
          .width('100%')
          .layoutWeight(1)
          // 选择模式多留一段底部空间，别让浮条盖住最后一章
          .padding({ left: 16, right: 16, top: 8, bottom: this.selection.selecting ? 152 : 48 })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))

      if (this.selection.selecting) {
        this.selectBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
