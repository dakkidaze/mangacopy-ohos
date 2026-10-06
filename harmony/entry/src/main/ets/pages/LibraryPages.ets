/** 收藏与历史页：共享登录态及分页控制器，分别采用网格与列表呈现。 */
import { MangaSummary } from '../model/Models';
import {
  BrowseLoadState,
  browseSession,
  BrowseSessionState,
  BrowseStatePanel,
  getBrowseSource,
  MangaGridView,
  MangaPagingController,
  PagingFooter,
  reloadBrowseSession
} from './BrowseSupport';

const MEMBER_PAGE_SIZE: number = 30;

async function loadFavorites(offset: number): Promise<MangaSummary[]> {
  const source = await getBrowseSource();
  return source.favorites(offset);
}

async function loadHistory(offset: number): Promise<MangaSummary[]> {
  const source = await getBrowseSource();
  return source.history(offset);
}

@ComponentV2
struct LibraryHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param symbol: Resource = $r('sys.symbol.heart');
  @Event onBack: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(21)
          .fontColor([$r('app.color.primary_text')])
      }
      .width(40)
      .height(40)
      .backgroundColor($r('app.color.surface_variant'))
      .onClick(() => this.onBack())

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.subtitle)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph(this.symbol)
        .fontSize(24)
        .fontColor([$r('app.color.accent')])
    }
    .width('100%')
    .padding({ left: 16, right: 18, top: 14, bottom: 10 })
  }
}

@ComponentV2
struct LoginRequiredPanel {
  @Param description: string = '';
  @Event onOpenAccount: () => void = () => {};

  build() {
    Column({ space: 13 }) {
      SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
        .fontSize(40)
        .fontColor([$r('app.color.primary')])
      Text('请先登录')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.primary_text'))
      Text(this.description)
        .fontSize(13)
        .lineHeight(20)
        .fontColor($r('app.color.secondary_text'))
        .textAlign(TextAlign.Center)
      Button('前往账号页')
        .type(ButtonType.Normal)
        .height(42)
        .padding({ left: 22, right: 22 })
        .fontColor($r('app.color.on_primary'))
        .backgroundColor($r('app.color.primary'))
        .borderRadius(14)
        .onClick(() => this.onOpenAccount())
    }
    .justifyContent(FlexAlign.Center)
    .width('calc(100% - 32vp)')
    .height(230)
    .padding(20)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
    .margin({ left: 16, right: 16, top: 24 })
  }
}

@ComponentV2
export struct FavoritesPage {
  @Event onBack: () => void = () => {};
  @Event onOpenAccount: () => void = () => {};
  @Event onOpenDetail: (id: string) => void = (_id: string) => {};

  @Local session: BrowseSessionState = browseSession;
  @Local controller: MangaPagingController = new MangaPagingController(loadFavorites, MEMBER_PAGE_SIZE);
  @Local prepareError: string = '';

  aboutToAppear(): void {
    this.prepare();
  }

  private async prepare(): Promise<void> {
    this.prepareError = '';
    try {
      await getBrowseSource();
      await reloadBrowseSession();
      if (this.session.loggedIn && this.controller.itemCount === 0) {
        this.controller.loadFirst();
      }
    } catch (error) {
      const value = error as Error;
      this.prepareError = value.message !== undefined ? value.message : '初始化失败';
    }
  }

  build() {
    Column() {
      LibraryHeader({
        title: '收藏',
        subtitle: this.session.loggedIn ? '你的漫画书架' : '登录后读取服务端收藏',
        symbol: $r('sys.symbol.heart'),
        onBack: (): void => this.onBack()
      })

      if (this.prepareError.length > 0 && this.controller.state === BrowseLoadState.Idle) {
        BrowseStatePanel({
          state: BrowseLoadState.Error,
          errorText: this.prepareError,
          idleText: '',
          onRetry: (): void => { this.prepare(); }
        })
      } else if (!this.session.ready) {
        BrowseStatePanel({
          state: BrowseLoadState.Loading,
          errorText: '',
          idleText: '',
          onRetry: (): void => { this.prepare(); }
        })
      } else if (!this.session.loggedIn) {
        LoginRequiredPanel({
          description: '收藏保存在服务端，登录后才能读取。',
          onOpenAccount: (): void => this.onOpenAccount()
        })
      } else {
        MangaGridView({
          controller: this.controller,
          bottomPadding: 48,
          idleText: '准备读取收藏',
          onOpen: (id: string): void => this.onOpenDetail(id)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@ComponentV2
struct HistoryRow {
  @Param item: MangaSummary = new MangaSummary('', '', '', '');
  @Event onOpen: (id: string) => void = (_id: string) => {};

  build() {
    Row({ space: 13 }) {
      Image(this.item.cover)
        .alt($r('app.media.app_icon'))
        .width(66)
        .height(88)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.surface_variant'))
        .borderRadius(12)

      Column({ space: 7 }) {
        Text(this.item.title.length > 0 ? this.item.title : '未命名漫画')
          .fontSize(16)
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
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(12)
            .fontColor([$r('app.color.secondary_text')])
          Text('最近浏览')
            .fontSize(11)
            .fontColor($r('app.color.secondary_text'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(17)
        .fontColor([$r('app.color.secondary_text')])
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .onClick(() => this.onOpen(this.item.id))
  }
}

@ComponentV2
struct HistoryListView {
  @Require @Param controller: MangaPagingController = new MangaPagingController();
  @Event onOpen: (id: string) => void = (_id: string) => {};

  build() {
    if (this.controller.itemCount === 0 && this.controller.state !== BrowseLoadState.Content) {
      BrowseStatePanel({
        state: this.controller.state,
        errorText: this.controller.errorText,
        idleText: '准备读取历史',
        onRetry: (): void => { this.controller.loadFirst(); }
      })
    } else {
      Refresh({ refreshing: this.controller.refreshing }) {
        List({ space: 10 }) {
          LazyForEach(this.controller.dataSource, (item: MangaSummary, index: number) => {
            ListItem() {
              HistoryRow({
                item: item,
                onOpen: (id: string): void => this.onOpen(id)
              })
            }
          }, (item: MangaSummary, index: number) => item.id + ':' + index.toString())
          ListItem() {
            PagingFooter({
              loading: this.controller.loadingMore,
              hasMore: this.controller.hasMore,
              message: this.controller.footerText,
              onRetry: (): void => { this.controller.loadMore(); }
            })
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 48 })
        .cachedCount(8)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => this.controller.loadMore())
      }
      .width('100%')
      .height('100%')
      .pullToRefresh(true)
      .onRefreshing(() => this.controller.refresh())
    }
  }
}

@ComponentV2
export struct HistoryPage {
  @Event onBack: () => void = () => {};
  @Event onOpenAccount: () => void = () => {};
  @Event onOpenDetail: (id: string) => void = (_id: string) => {};

  @Local session: BrowseSessionState = browseSession;
  @Local controller: MangaPagingController = new MangaPagingController(loadHistory, MEMBER_PAGE_SIZE);
  @Local prepareError: string = '';

  aboutToAppear(): void {
    this.prepare();
  }

  private async prepare(): Promise<void> {
    this.prepareError = '';
    try {
      await getBrowseSource();
      await reloadBrowseSession();
      if (this.session.loggedIn && this.controller.itemCount === 0) {
        this.controller.loadFirst();
      }
    } catch (error) {
      const value = error as Error;
      this.prepareError = value.message !== undefined ? value.message : '初始化失败';
    }
  }

  build() {
    Column() {
      LibraryHeader({
        title: '历史',
        subtitle: this.session.loggedIn ? '最近浏览的漫画' : '登录后读取服务端历史',
        symbol: $r('sys.symbol.clock'),
        onBack: (): void => this.onBack()
      })

      if (this.prepareError.length > 0 && this.controller.state === BrowseLoadState.Idle) {
        BrowseStatePanel({
          state: BrowseLoadState.Error,
          errorText: this.prepareError,
          idleText: '',
          onRetry: (): void => { this.prepare(); }
        })
      } else if (!this.session.ready) {
        BrowseStatePanel({
          state: BrowseLoadState.Loading,
          errorText: '',
          idleText: '',
          onRetry: (): void => { this.prepare(); }
        })
      } else if (!this.session.loggedIn) {
        LoginRequiredPanel({
          description: '浏览历史保存在服务端，登录后才能读取。',
          onOpenAccount: (): void => this.onOpenAccount()
        })
      } else {
        HistoryListView({
          controller: this.controller,
          onOpen: (id: string): void => this.onOpenDetail(id)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
