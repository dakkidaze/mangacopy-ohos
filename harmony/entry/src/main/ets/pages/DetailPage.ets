/** 原生漫画详情页：详情与章节分别加载，阅读和下载暂以明确提示承接。 */
import { Chapter, MangaDetail } from '../model/Models';
import { BrowseLoadState, describeBrowseError, getBrowseSource } from './BrowseSupport';

function emptyDetail(): MangaDetail {
  return new MangaDetail('', '', '', '', '', '', '', '', []);
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
    .backgroundColor($r('app.color.surface'))
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
  @Event onToggleDescription: () => void = () => {};

  build() {
    Column({ space: 16 }) {
      Row({ space: 16 }) {
        Image(this.detail.cover)
          .alt($r('app.media.app_icon'))
          .width(112)
          .height(154)
          .objectFit(ImageFit.Cover)
          .borderRadius(16)
          .backgroundColor($r('app.color.surface_variant'))

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
              .backgroundColor($r('app.color.surface_variant'))
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
    .backgroundColor($r('app.color.surface'))
    .borderRadius(22)
  }
}

@ComponentV2
struct ChapterRow {
  @Param chapter: Chapter = new Chapter('', '', 0, 0);
  @Event onRead: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  @Event onDownload: (chapter: Chapter) => void = (_chapter: Chapter) => {};

  private chapterTitle(): string {
    if (this.chapter.name.length > 0) {
      return this.chapter.name;
    }
    return this.chapter.index > 0 ? '第 ' + this.chapter.index + ' 话' : '未命名章节';
  }

  build() {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.chapter.index > 0 ? this.chapter.index.toString() : '·')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary'))
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.surface_variant'))
          .borderRadius(11)
        Column({ space: 3 }) {
          Text(this.chapterTitle())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.chapter.size > 0) {
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
      .onClick(() => this.onRead(this.chapter))

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.arrow_down_circle'))
          .fontSize(21)
          .fontColor([$r('app.color.primary')])
      }
      .width(38)
      .height(38)
      .backgroundColor($r('app.color.accent_soft'))
      .onClick(() => this.onDownload(this.chapter))
    }
    .width('100%')
    .padding({ left: 12, right: 10, top: 5, bottom: 5 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(15)
  }
}

@ComponentV2
export struct DetailPage {
  @Param mangaId: string = '';
  @Event onBack: () => void = () => {};

  @Local detailState: BrowseLoadState = BrowseLoadState.Loading;
  @Local chapterState: BrowseLoadState = BrowseLoadState.Loading;
  @Local detail: MangaDetail | null = null;
  @Local chapters: Chapter[] = [];
  @Local visibleChapters: Chapter[] = [];
  @Local detailError: string = '';
  @Local chapterError: string = '';
  @Local descriptionExpanded: boolean = false;
  @Local ascending: boolean = true;

  aboutToAppear(): void {
    this.loadDetail();
    this.loadChapters();
  }

  private async loadDetail(): Promise<void> {
    this.detailState = BrowseLoadState.Loading;
    this.detailError = '';
    try {
      const source = await getBrowseSource();
      const detail = await source.detail(this.mangaId);
      this.detail = detail;
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

  private toggleChapterOrder(): void {
    this.ascending = !this.ascending;
    this.syncChapterOrder();
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
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

      Scroll() {
        Column({ space: 14 }) {
          if (this.detailState === BrowseLoadState.Content && this.detail !== null) {
            DetailOverview({
              detail: this.detail as MangaDetail,
              expanded: this.descriptionExpanded,
              onToggleDescription: (): void => {
                this.descriptionExpanded = !this.descriptionExpanded;
              }
            })
          } else {
            DetailStatePanel({
              state: this.detailState,
              label: '详情',
              errorText: this.detailError,
              onRetry: (): void => {
                this.loadDetail();
              }
            })
          }

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

          if (this.chapterState === BrowseLoadState.Content) {
            Column({ space: 8 }) {
              ForEach(this.visibleChapters, (chapter: Chapter, index: number) => {
                ChapterRow({
                  chapter: chapter,
                  onRead: (_chapter: Chapter): void => {
                    this.showToast('阅读器开发中');
                  },
                  onDownload: (_chapter: Chapter): void => {
                    this.showToast('下载功能开发中');
                  }
                })
              }, (chapter: Chapter, index: number) => chapter.id + ':' + index.toString())
            }
            .width('100%')
          } else {
            DetailStatePanel({
              state: this.chapterState,
              label: '章节',
              errorText: this.chapterError,
              onRetry: (): void => {
                this.loadChapters();
              }
            })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 48 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
