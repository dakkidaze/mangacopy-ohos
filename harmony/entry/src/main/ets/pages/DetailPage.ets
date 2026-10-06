/** 原生漫画详情页：详情与章节分别加载，阅读和下载暂以明确提示承接。 */
import { Chapter, MangaDetail } from '../model/Models';
import { BrowseLoadState, describeBrowseError, getBrowseSource } from './BrowseSupport';
import { CommentPanel, CommentPanelTab } from './CommentPanel';
import {
  ChapterDownloadRequest,
  ChapterDownloadState,
  ChapterDownloadStatus,
  downloadStore
} from './DownloadStore';

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
  @Event onOpenComments: () => void = () => {};

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
      .height(40)
      .padding({ left: 15, right: 15 })
      .backgroundColor($r('app.color.accent_soft'))
      .borderRadius(14)
      .onClick(() => this.onOpenComments())

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
  @Param downloadState: ChapterDownloadState = new ChapterDownloadState();
  @Event onRead: (chapter: Chapter) => void = (_chapter: Chapter) => {};
  @Event onComments: (chapter: Chapter) => void = (_chapter: Chapter) => {};
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
        Column() {
          Text('•')
            .fontSize(16)
            .fontColor($r('app.color.primary'))
            .textAlign(TextAlign.Center)
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width(34)
        .height(34)
        .backgroundColor($r('app.color.surface_variant'))
        .borderRadius(11)
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
          } else if (this.downloadState.status === ChapterDownloadStatus.Completed) {
            Text('已下载 · ' + (this.chapter.size > 0 ? this.chapter.size + ' 页' : '本地可用'))
              .fontSize(11)
              .fontColor($r('app.color.primary'))
          } else if (this.downloadState.status === ChapterDownloadStatus.Failed) {
            Text('下载失败，点下载按钮重试')
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
      .onClick(() => this.onRead(this.chapter))

      Row({ space: 6 }) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.message'))
            .fontSize(19)
            .fontColor([$r('app.color.primary')])
        }
        .width(36)
        .height(36)
        .backgroundColor($r('app.color.surface_variant'))
        .accessibilityText('查看本章吐槽')
        .onClick(() => this.onComments(this.chapter))

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
        .accessibilityText(this.downloadState.status === ChapterDownloadStatus.Downloading ? '取消下载' :
          this.downloadState.status === ChapterDownloadStatus.Completed ? '已下载' : '下载本章')
        .onClick(() => this.onDownload(this.chapter))
      }
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
  @Local commentPanelVisible: boolean = false;
  @Local commentChapterId: string = '';
  @Local commentComicId: string = '';
  @Local commentInitialTab: CommentPanelTab = CommentPanelTab.Chapter;

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

  private downloadRequest(chapter: Chapter): ChapterDownloadRequest {
    const comicName = this.detail !== null && this.detail.title.length > 0 ? this.detail.title : this.mangaId;
    return {
      comicName: comicName,
      comicId: this.mangaId,
      chapterName: chapter.name.length > 0 ? chapter.name : '章节_' + chapter.id.substring(0, 8),
      chapterId: chapter.id
    };
  }

  private async handleChapterDownload(chapter: Chapter): Promise<void> {
    if (this.detail === null || this.detail.title.length === 0) {
      this.showToast('漫画信息加载完成后才能下载');
      return;
    }
    const request = this.downloadRequest(chapter);
    const state = downloadStore.taskFor(request);
    if (state.status === ChapterDownloadStatus.Downloading) {
      downloadStore.cancel(request.comicId, request.chapterId);
      this.showToast('已取消下载');
      return;
    }
    if (state.status === ChapterDownloadStatus.Completed) {
      this.showToast('该章节已下载');
      return;
    }
    const result = await downloadStore.downloadChapter(request, (_progress): void => {});
    if (result.status === ChapterDownloadStatus.Completed) {
      this.showToast('章节下载完成');
    } else if (result.status === ChapterDownloadStatus.Failed) {
      this.showToast('下载失败：' + result.errorText);
    }
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
    this.commentPanelVisible = true;
  }

  private openChapterComments(chapter: Chapter): void {
    this.commentChapterId = chapter.id;
    this.commentComicId = this.detail === null ? '' : this.detail.uuid;
    this.commentInitialTab = CommentPanelTab.Chapter;
    this.commentPanelVisible = true;
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
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
              },
              onOpenComments: (): void => this.openComicComments()
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
                  downloadState: downloadStore.taskFor(this.downloadRequest(chapter)),
                  onRead: (_chapter: Chapter): void => {
                    this.showToast('阅读器开发中');
                  },
                  onComments: (selected: Chapter): void => {
                    this.openChapterComments(selected);
                  },
                  onDownload: (selected: Chapter): void => {
                    this.handleChapterDownload(selected);
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

      if (this.commentPanelVisible) {
        CommentPanel({
          visible: this.commentPanelVisible,
          chapterId: this.commentChapterId,
          comicId: this.commentComicId,
          initialTab: this.commentInitialTab,
          onClose: (): void => {
            this.commentPanelVisible = false;
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
