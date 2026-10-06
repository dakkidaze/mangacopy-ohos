/**
 * 最小可读的原生阅读器：横向翻页 + 断点续读。
 * 图片数据统一走 loadChapterImages()，自动遵守「章节图源」设置。
 */
import { settingsStore } from '../services/SettingsStore';
import { loadChapterImages } from './HiddenCollector';

export enum ReaderLoadState {
  Loading = 0,
  Content = 1,
  Empty = 2,
  Error = 3
}

const PAGE_PROGRESS_PREFIX: string = 'page_';

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
  }
}

@ComponentV2
export struct ReaderPage {
  @Param comicId: string = '';
  @Param chapterId: string = '';
  @Param chapterName: string = '';
  @Event onExit: () => void = () => {};

  @Local loadState: ReaderLoadState = ReaderLoadState.Loading;
  @Local errorText: string = '';
  @Local urls: string[] = [];
  @Local currentIndex: number = 0;
  @Local toolbarVisible: boolean = true;

  private swiperController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.loadImages();
  }

  private progressKey(): string {
    return PAGE_PROGRESS_PREFIX + this.chapterId;
  }

  private async loadImages(): Promise<void> {
    this.loadState = ReaderLoadState.Loading;
    this.errorText = '';
    try {
      const images = await loadChapterImages(this.comicId, this.chapterId);
      this.urls = images;
      if (images.length === 0) {
        this.loadState = ReaderLoadState.Empty;
        return;
      }
      const saved = await settingsStore.getInt(this.progressKey(), 0);
      const restored = saved > 0 && saved < images.length ? saved : 0;
      this.currentIndex = restored;
      this.loadState = ReaderLoadState.Content;
      if (restored > 0) {
        setTimeout(() => {
          this.swiperController.changeIndex(restored, true);
        }, 60);
      }
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '图片加载失败';
      this.loadState = ReaderLoadState.Error;
    }
  }

  private async saveProgress(index: number): Promise<void> {
    const total = this.urls.length;
    if (total <= 0) {
      return;
    }
    try {
      if (index >= total - 1) {
        await settingsStore.remove(this.progressKey());
      } else {
        await settingsStore.putInt(this.progressKey(), index);
      }
    } catch (error) {
    }
  }

  private goPrevious(): void {
    if (this.currentIndex <= 0) {
      return;
    }
    this.swiperController.showPrevious();
  }

  private goNext(): void {
    if (this.currentIndex >= this.urls.length - 1) {
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

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loadState === ReaderLoadState.Content) {
        Swiper(this.swiperController) {
          LazyForEach(new ReaderPageSource(this.urls), (item: ReaderPageItem) => {
            Stack({ alignContent: Alignment.Center }) {
              Image(item.url)
                .alt($r('app.media.app_icon'))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
            }
            .width('100%')
            .height('100%')
          }, (item: ReaderPageItem) => item.key)
        }
        .index(this.currentIndex)
        .cachedCount(2)
        .indicator(false)
        .loop(false)
        .vertical(false)
        .duration(200)
        .curve(Curve.EaseOut)
        .effectMode(EdgeEffect.None)
        .onChange((index: number) => {
          this.currentIndex = index;
          this.saveProgress(index);
        })
        .height('100%')
        .backgroundColor($r('app.color.page_background'))

        // 点击分区：左 1/3 上一页、右 1/3 下一页、中间切换工具栏
        Row() {
          Column() {
          }
          .width('33.33%')
          .height('100%')
          .onClick(() => this.goPrevious())

          Column() {
          }
          .width('33.34%')
          .height('100%')
          .onClick(() => {
            this.toolbarVisible = !this.toolbarVisible;
          })

          Column() {
          }
          .width('33.33%')
          .height('100%')
          .onClick(() => this.goNext())
        }
        .width('100%')
        .height('100%')
        // 透明层只用于接收点击；不阻塞图片区域之外的工具栏按钮
        .hitTestBehavior(HitTestMode.Transparent)

        if (this.toolbarVisible) {
          Row({ space: 10 }) {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(21)
                .fontColor([$r('app.color.primary_text')])
            }
            .width(44)
            .height(44)
            .backgroundColor($r('app.color.nav_surface'))
            .onClick(() => this.onExit())

            Column({ space: 2 }) {
              Text(this.chapterName.length > 0 ? this.chapterName : '章节')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text((this.currentIndex + 1) + ' / ' + this.urls.length)
                .fontSize(12)
                .fontColor($r('app.color.secondary_text'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.message'))
                .fontSize(19)
                .fontColor([$r('app.color.primary')])
            }
            .width(44)
            .height(44)
            .backgroundColor($r('app.color.nav_surface'))
            .onClick(() => this.showToast('吐槽面板开发中'))
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.surface'))
        }
      } else {
        ReaderStatePanel({
          state: this.loadState,
          errorText: this.errorText,
          onRetry: (): void => {
            this.loadImages();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

interface ReaderPageItem {
  url: string;
  key: string;
}

class ReaderPageSource implements IDataSource {
  private items: ReaderPageItem[] = [];
  private listeners: DataChangeListener[] = [];

  constructor(urls: string[]) {
    this.items = [];
    for (let i = 0; i < urls.length; i++) {
      this.items.push({ url: urls[i], key: urls[i] + ':' + i.toString() });
    }
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
