/**
 * 浏览页共用的数据入口、分页控制器和网格组件。
 * 仅组合既有数据层，不在此重写网络或持久化逻辑。
 */
import { ApiDomainManager } from '../services/ApiDomainManager';
import { ApiClient, ApiException } from '../services/ApiClient';
import { CopyApiSource } from '../services/CopyApiSource';
import { MangaSummary } from '../model/Models';

export const BROWSE_PAGE_SIZE: number = 21;

const browseDomains: ApiDomainManager = new ApiDomainManager();
const browseClient: ApiClient = new ApiClient(browseDomains);
const sharedBrowseSource: CopyApiSource = new CopyApiSource(browseClient);
let browseReady: boolean = false;
let browsePreparing: Promise<void> | undefined = undefined;

async function prepareBrowseApi(): Promise<void> {
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
  private revision: number = 0;

  constructor(loader: MangaPageLoader = emptyPageLoader) {
    this.loader = loader;
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
      this.hasMore = items.length >= BROWSE_PAGE_SIZE;
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
      this.hasMore = items.length >= BROWSE_PAGE_SIZE;
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

@ComponentV2
struct MangaGridCard {
  @Param item: MangaSummary = new MangaSummary('', '', '', '');
  @Event onOpen: (id: string) => void = (_id: string) => {};

  build() {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.surface_variant'))
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
    .height(294)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(18)
    .shadow({ radius: 8, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 3 })
    .onClick(() => this.onOpen(this.item.id))
  }
}

@ComponentV2
struct BrowseStatePanel {
  @Param state: BrowseLoadState = BrowseLoadState.Idle;
  @Param errorText: string = '';
  @Param idleText: string = '准备加载';
  @Event onRetry: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      if (this.state === BrowseLoadState.Loading) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color($r('app.color.primary'))
        Text('正在加载…')
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
      } else if (this.state === BrowseLoadState.Error) {
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
      } else if (this.state === BrowseLoadState.Empty) {
        Text('○')
          .fontSize(32)
          .fontColor($r('app.color.secondary_text'))
        Text('没有找到漫画')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text('可以换个关键词或筛选条件再试')
          .fontSize(13)
          .fontColor($r('app.color.secondary_text'))
      } else {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(32)
          .fontColor([$r('app.color.secondary_text')])
        Text(this.idleText)
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(24)
  }
}

@ComponentV2
struct PagingFooter {
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
  @Param bottomPadding: number = 48;
  @Param idleText: string = '准备加载';
  @Event onOpen: (id: string) => void = (_id: string) => {};

  build() {
    if (this.controller.itemCount === 0 && this.controller.state !== BrowseLoadState.Content) {
      BrowseStatePanel({
        state: this.controller.state,
        errorText: this.controller.errorText,
        idleText: this.idleText,
        onRetry: (): void => { this.controller.loadFirst(); }
      })
    } else {
      Refresh({ refreshing: this.controller.refreshing }) {
        Grid() {
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
          .columnEnd(1)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(12)
        .rowsGap(14)
        .cachedCount(6)
        .padding({ left: 16, right: 16, top: 10, bottom: this.bottomPadding })
        .width('100%')
        .height('100%')
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
