/** 原生搜索与筛选页。 */
import { MangaSummary } from '../model/Models';
import { getBrowseSource, MangaGridView, MangaPagingController } from './BrowseSupport';

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
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') : $r('app.color.surface_variant'))
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
  @Local controller: MangaPagingController = new MangaPagingController();

  private hasFilter(): boolean {
    return this.ordering.length > 0 || this.region.length > 0 || this.freeType.length > 0;
  }

  private runSearch(): void {
    const query = this.query.trim();
    const ordering = this.ordering;
    const region = this.region;
    const freeType = this.freeType;
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
    this.runSearch();
  }

  private selectRegion(value: string): void {
    this.region = value;
    this.runSearch();
  }

  private selectFreeType(value: string): void {
    this.freeType = value;
    this.runSearch();
  }

  private resetFilters(): void {
    this.ordering = '';
    this.region = '';
    this.freeType = '';
    this.runSearch();
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
        .backgroundColor($r('app.color.surface_variant'))
        .onClick(() => this.onBack())

        TextInput({ text: this.query, placeholder: '输入漫画名或关键词' })
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.primary_text'))
          .placeholderColor($r('app.color.secondary_text'))
          .caretColor($r('app.color.primary'))
          .backgroundColor($r('app.color.field_background'))
          .borderRadius(14)
          .onChange((value: string) => {
            this.query = value;
          })

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(20)
            .fontColor([$r('app.color.on_primary')])
        }
        .width(42)
        .height(42)
        .backgroundColor($r('app.color.primary'))
        .onClick(() => this.runSearch())
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
            this.filtersVisible = !this.filtersVisible;
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
        .backgroundColor($r('app.color.surface'))
        .borderRadius(20)
        .margin({ left: 16, right: 16, bottom: 8 })
      }

      MangaGridView({
        controller: this.controller,
        bottomPadding: 48,
        idleText: '输入关键词，或打开筛选浏览漫画',
        onOpen: (id: string): void => this.onOpenDetail(id)
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
