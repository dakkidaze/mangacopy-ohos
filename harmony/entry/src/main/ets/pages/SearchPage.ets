/** 原生搜索与筛选页。 */
import { MangaSummary } from '../model/Models';
import { getBrowseSource, MangaGridView, MangaPagingController } from './BrowseSupport';
import { themeBackground, themeState } from './ThemeColors';

/** 回车与搜索按钮的等价重复提交判定窗口（毫秒）。 */
const SEARCH_SUBMIT_DEDUPE_MS: number = 400;
/** 恢复滚动位置的尝试上限：网格首次布局完成前滚动容器可能尚未绑定。 */
const SEARCH_SCROLL_RESTORE_MAX_ATTEMPTS: number = 5;

/**
 * 搜索会话：把搜索词、筛选条件、结果列表与滚动位置提到页面之外。
 * 壳层路由用 if 切页，详情覆盖搜索时页面会卸载，重新挂载后从这里恢复；
 * 真正离开搜索回到壳层时由 Index 显式 reset，下一次进入得到全新页面。
 * 只作状态容器，不参与渲染，因此不需要可观测装饰。
 */
export class SearchSessionState {
  query: string = '';
  ordering: string = '';
  region: string = '';
  freeType: string = '';
  filtersVisible: boolean = false;
  scrollOffset: number = 0;
  controller: MangaPagingController = new MangaPagingController();
  scroller: Scroller = new Scroller();

  reset(): void {
    this.query = '';
    this.ordering = '';
    this.region = '';
    this.freeType = '';
    this.filtersVisible = false;
    this.scrollOffset = 0;
    // 换新实例同时丢弃结果、分页状态与旧滚动容器，并隔离仍在返回途中的旧请求。
    this.controller = new MangaPagingController();
    this.scroller = new Scroller();
  }
}

export const searchSession: SearchSessionState = new SearchSessionState();

export function resetSearchSession(): void {
  searchSession.reset();
}

@ComponentV2
struct SearchFilterChip {
  @Param label: string = '';
  @Param value: string = '';
  @Param selected: string = '';
  @Event onSelect: (value: string) => void = (_value: string) => {};

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .height(34)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8, bottom: 8 })
      .fontSize(12)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') :
        themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
      .borderRadius(17)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
export struct SearchPage {
  @Event onBack: () => void = () => {};
  @Event onOpenDetail: (id: string) => void = (_id: string) => {};

  @Local query: string = '';
  @Local ordering: string = '';
  @Local region: string = '';
  @Local freeType: string = '';
  @Local filtersVisible: boolean = false;
  @Local controller: MangaPagingController = searchSession.controller;

  private gridScroller: Scroller = searchSession.scroller;
  /** 待恢复的滚动位置；0 表示无需恢复。 */
  private pendingScrollOffset: number = 0;
  private restoreAttempts: number = 0;
  private restoreTimer: number = -1;
  /** 上一次提交的签名与时间戳，用于回车/按钮两种入口的等价去重。 */
  private lastSubmitSignature: string = '';
  private lastSubmitAt: number = 0;

  aboutToAppear(): void {
    // 详情覆盖后返回时接回同一会话；回壳层后的新会话则自然恢复为空值。
    this.query = searchSession.query;
    this.ordering = searchSession.ordering;
    this.region = searchSession.region;
    this.freeType = searchSession.freeType;
    this.filtersVisible = searchSession.filtersVisible;
    this.controller = searchSession.controller;
    this.gridScroller = searchSession.scroller;
    this.pendingScrollOffset = searchSession.scrollOffset;
    this.restoreAttempts = 0;
    this.scheduleScrollRestore();
  }

  aboutToDisappear(): void {
    this.clearRestoreTimer();
    this.saveScrollOffset();
  }

  private hasFilter(): boolean {
    return this.ordering.length > 0 || this.region.length > 0 || this.freeType.length > 0;
  }

  private saveScrollOffset(): void {
    // 回壳层时会先换掉会话实例；旧组件随后卸载时不得把旧偏移写回新会话。
    if (this.gridScroller !== searchSession.scroller) {
      return;
    }
    try {
      const offset = this.gridScroller.currentOffset();
      if (offset.yOffset > 0) {
        searchSession.scrollOffset = offset.yOffset;
      }
    } catch (error) {
      // 容器未绑定时读不到偏移，保留上一次记录即可
    }
  }

  /**
   * 网格首帧尚未完成布局时滚动容器可能未绑定，这里做几次短间隔重试，
   * 读到已到达目标（或超过上限）即结束，不会一直挂着定时器。
   */
  private scheduleScrollRestore(): void {
    if (this.pendingScrollOffset <= 0) {
      return;
    }
    this.clearRestoreTimer();
    this.restoreTimer = setTimeout(() => this.restoreScrollStep(), 60);
  }

  private clearRestoreTimer(): void {
    if (this.restoreTimer >= 0) {
      clearTimeout(this.restoreTimer);
      this.restoreTimer = -1;
    }
  }

  private restoreScrollStep(): void {
    this.restoreTimer = -1;
    if (this.pendingScrollOffset <= 0 || this.restoreAttempts >= SEARCH_SCROLL_RESTORE_MAX_ATTEMPTS) {
      this.pendingScrollOffset = 0;
      return;
    }
    this.restoreAttempts++;
    try {
      this.gridScroller.scrollTo({
        xOffset: 0,
        yOffset: this.pendingScrollOffset,
        animation: false
      });
      const current = this.gridScroller.currentOffset();
      if (Math.abs(current.yOffset - this.pendingScrollOffset) < 4) {
        this.pendingScrollOffset = 0;
        return;
      }
    } catch (error) {
      // 容器尚未绑定：下一轮再试
    }
    this.restoreTimer = setTimeout(() => this.restoreScrollStep(), 60);
  }

  /** 回车与搜索按钮共用的唯一入口：签名相同且间隔极短时忽略，避免一次输入搜两遍。 */
  private submitSearch(): void {
    const signature = this.query.trim() + '|' + this.ordering + '|' + this.region + '|' + this.freeType;
    const now = Date.now();
    if (signature === this.lastSubmitSignature && now - this.lastSubmitAt < SEARCH_SUBMIT_DEDUPE_MS) {
      return;
    }
    this.lastSubmitSignature = signature;
    this.lastSubmitAt = now;
    this.runSearch();
  }

  private runSearch(): void {
    const query = this.query.trim();
    const ordering = this.ordering;
    const region = this.region;
    const freeType = this.freeType;
    // 显式动作：覆盖会话里的搜索态（含滚动位置），之后返回仍然恢复这次的新结果
    searchSession.query = this.query;
    searchSession.ordering = ordering;
    searchSession.region = region;
    searchSession.freeType = freeType;
    searchSession.scrollOffset = 0;
    this.pendingScrollOffset = 0;
    const filtered = ordering.length > 0 || region.length > 0 || freeType.length > 0 || query.length === 0;
    this.controller.setLoader(async (offset: number): Promise<MangaSummary[]> => {
      const source = await getBrowseSource();
      if (filtered) {
        return source.filter(ordering, region, '', freeType, offset);
      }
      return source.search(query, offset);
    });
    this.controller.loadFirst();
  }

  private selectOrdering(value: string): void {
    this.ordering = value;
    this.submitSearch();
  }

  private selectRegion(value: string): void {
    this.region = value;
    this.submitSearch();
  }

  private selectFreeType(value: string): void {
    this.freeType = value;
    this.submitSearch();
  }

  private resetFilters(): void {
    this.ordering = '';
    this.region = '';
    this.freeType = '';
    this.submitSearch();
  }

  private toggleFilters(): void {
    this.filtersVisible = !this.filtersVisible;
    searchSession.filtersVisible = this.filtersVisible;
  }

  build() {
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

        TextInput({ text: this.query, placeholder: '输入漫画名或关键词' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.primary_text'))
          .placeholderColor($r('app.color.secondary_text'))
          .caretColor($r('app.color.primary'))
          .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(14)
          // 软键盘右下角显示「搜索」，回车即走与搜索按钮完全相同的提交路径
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.query = value;
          })
          .onSubmit(() => this.submitSearch())

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(20)
            .fontColor([$r('app.color.on_primary')])
        }
        .width(42)
        .height(42)
        .backgroundColor($r('app.color.primary'))
        .onClick(() => this.submitSearch())
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 8 })

      Row() {
        Text(this.hasFilter() ? '正在使用筛选条件' : '排序、地区与收费')
          .fontSize(12)
          .fontColor(this.hasFilter() ? $r('app.color.accent') : $r('app.color.secondary_text'))
        Blank()
        Button(this.filtersVisible ? '收起筛选' : '筛选')
          .type(ButtonType.Normal)
          .height(34)
          .padding({ left: 14, right: 14 })
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(17)
          .onClick(() => {
            this.toggleFilters();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 8 })

      if (this.filtersVisible) {
        Scroll() {
          Column({ space: 6 }) {
            Row() {
              Text('筛选条件')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Blank()
              Button('重置')
                .type(ButtonType.Normal)
                .height(30)
                .fontSize(11)
                .fontColor($r('app.color.accent'))
                .backgroundColor($r('app.color.nav_item_clear'))
                .onClick(() => this.resetFilters())
            }
            .width('100%')

            Text('排序')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              SearchFilterChip({ label: '全部', value: '', selected: this.ordering,
                onSelect: (value: string): void => this.selectOrdering(value) })
              SearchFilterChip({ label: '最近更新', value: '-datetime_updated', selected: this.ordering,
                onSelect: (value: string): void => this.selectOrdering(value) })
              SearchFilterChip({ label: '较早更新', value: 'datetime_updated', selected: this.ordering,
                onSelect: (value: string): void => this.selectOrdering(value) })
              SearchFilterChip({ label: '最受欢迎', value: '-popular', selected: this.ordering,
                onSelect: (value: string): void => this.selectOrdering(value) })
              SearchFilterChip({ label: '较少人气', value: 'popular', selected: this.ordering,
                onSelect: (value: string): void => this.selectOrdering(value) })
            }
            .width('100%')

            Text('地区')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              SearchFilterChip({ label: '全部', value: '', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
              SearchFilterChip({ label: '日本', value: 'japan', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
              SearchFilterChip({ label: '韩国', value: 'korea', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
              SearchFilterChip({ label: '欧美', value: 'america', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
              SearchFilterChip({ label: '国漫', value: 'cn', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
              SearchFilterChip({ label: '已完结', value: 'finish', selected: this.region,
                onSelect: (value: string): void => this.selectRegion(value) })
            }
            .width('100%')

            Text('收费')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              SearchFilterChip({ label: '全部', value: '', selected: this.freeType,
                onSelect: (value: string): void => this.selectFreeType(value) })
              SearchFilterChip({ label: '免费', value: '1', selected: this.freeType,
                onSelect: (value: string): void => this.selectFreeType(value) })
              SearchFilterChip({ label: '付费', value: '2', selected: this.freeType,
                onSelect: (value: string): void => this.selectFreeType(value) })
              SearchFilterChip({ label: '等就免费', value: '3', selected: this.freeType,
                onSelect: (value: string): void => this.selectFreeType(value) })
            }
            .width('100%')

            if (this.hasFilter() && this.query.trim().length > 0) {
              Text('当前按筛选条件浏览；关键词不会参与筛选请求。')
                .fontSize(11)
                .fontColor($r('app.color.secondary_text'))
                .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
        }
        .width('calc(100% - 32vp)')
        .height(238)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
        .borderRadius(20)
        .margin({ left: 16, right: 16, bottom: 8 })
      }

      MangaGridView({
        controller: this.controller,
        scroller: this.gridScroller,
        bottomPadding: 48,
        idleText: '输入关键词，或打开筛选浏览漫画',
        onOpen: (id: string): void => this.onOpenDetail(id),
        onScrolled: (offset: number): void => {
          // reset 后旧网格可能还有最后一帧回调，不能污染下一次搜索的全新会话。
          if (this.gridScroller === searchSession.scroller) {
            searchSession.scrollOffset = offset;
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
