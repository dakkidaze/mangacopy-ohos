/** 原生发现页：热门/最新双列表、刷新与分页。 */
import { MangaSummary } from '../model/Models';
import {
  BrowseLoadState,
  getBrowseSource,
  MangaGridView,
  MangaPagingController
} from './BrowseSupport';
import { themeBackground, themeState } from './ThemeColors';

enum DiscoverFeed {
  Popular = 'popular',
  Latest = 'latest'
}

async function loadPopular(offset: number): Promise<MangaSummary[]> {
  const source = await getBrowseSource();
  return source.popular(offset);
}

async function loadLatest(offset: number): Promise<MangaSummary[]> {
  const source = await getBrowseSource();
  return source.latest(offset);
}

@ComponentV2
struct DiscoverFeedTab {
  @Param label: string = '';
  @Param value: DiscoverFeed = DiscoverFeed.Popular;
  @Param selected: DiscoverFeed = DiscoverFeed.Popular;
  @Event onSelect: (value: DiscoverFeed) => void = (_value: DiscoverFeed) => {};

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(38)
      .fontSize(14)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.secondary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') : $r('app.color.nav_item_clear'))
      .borderRadius(19)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
export struct DiscoverPage {
  @Param bottomInset: number = 48;
  @Event onSearch: () => void = () => {};
  @Event onOpenDetail: (id: string) => void = (_id: string) => {};

  @Local activeFeed: DiscoverFeed = DiscoverFeed.Popular;
  @Local popularController: MangaPagingController = new MangaPagingController(loadPopular);
  @Local latestController: MangaPagingController = new MangaPagingController(loadLatest);

  aboutToAppear(): void {
    if (this.popularController.state === BrowseLoadState.Idle) {
      this.popularController.loadFirst();
    }
  }

  private selectFeed(feed: DiscoverFeed): void {
    this.activeFeed = feed;
    if (feed === DiscoverFeed.Popular && this.popularController.state === BrowseLoadState.Idle) {
      this.popularController.loadFirst();
    }
    if (feed === DiscoverFeed.Latest && this.latestController.state === BrowseLoadState.Idle) {
      this.latestController.loadFirst();
    }
  }

  /**
   * 「热门 ↔ 最新」交叉淡入：进场 120ms 减速淡入、退场 100ms 加速淡出，与底栏 Tab 同一口径。
   * 两路网格都是 100% 高，必须放进 Stack 同帧叠放、退场侧原地淡出；
   * 若留在 Column 的流式排布里，退场网格仍占一整屏高度，新网格会被顶出视口。
   * 转场自带动画，切 Tab 的 handler 里不包 animateTo。
   */
  private feedFadeTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.animation({ duration: 100, curve: Curve.EaseIn })
    );
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('MANGACOPY')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent'))
            .letterSpacing(2.2)
          Text('发现')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(22)
            .fontColor([$r('app.color.primary_text')])
        }
        .width(44)
        .height(44)
        .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
        .shadow({ radius: 7, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 2 })
        .onClick(() => this.onSearch())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      Row({ space: 4 }) {
        DiscoverFeedTab({
          label: '热门',
          value: DiscoverFeed.Popular,
          selected: this.activeFeed,
          onSelect: (value: DiscoverFeed): void => this.selectFeed(value)
        })
        DiscoverFeedTab({
          label: '最新',
          value: DiscoverFeed.Latest,
          selected: this.activeFeed,
          onSelect: (value: DiscoverFeed): void => this.selectFeed(value)
        })
      }
      .width('calc(100% - 32vp)')
      .height(46)
      .padding(4)
      .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
      .borderRadius(23)
      .margin({ left: 16, right: 16, bottom: 4 })

      // 热门 ↔ 最新：两路网格都是 100% 高，直接挂在 Column 里做条件渲染会让
      // 退场的一支继续占着流式位置（新网格被顶到屏幕外）；改用 Stack 同帧叠放承接。
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.activeFeed === DiscoverFeed.Popular) {
          MangaGridView({
            controller: this.popularController,
            bottomPadding: this.bottomInset,
            idleText: '准备加载热门漫画',
            onOpen: (id: string): void => this.onOpenDetail(id)
          })
          .transition(this.feedFadeTransition())
        } else {
          MangaGridView({
            controller: this.latestController,
            bottomPadding: this.bottomInset,
            idleText: '准备加载最近更新',
            onOpen: (id: string): void => this.onOpenDetail(id)
          })
          .transition(this.feedFadeTransition())
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
