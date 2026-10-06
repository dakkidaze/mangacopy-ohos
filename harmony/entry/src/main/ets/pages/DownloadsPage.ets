/** 下载管理：漫画与章节两级目录，不包含离线阅读器。 */
import {
  downloadStore,
  DownloadedChapterInfo,
  DownloadedComicInfo
} from './DownloadStore';

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

@ComponentV2
struct DownloadPageHeader {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Event onBack: () => void = () => {};
  @Event onRefresh: () => void = () => {};

  build() {
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

@ComponentV2
struct DownloadComicRow {
  @Param item: DownloadedComicInfo = {
    name: '', directory: '', chapterCount: 0, completedCount: 0, pageCount: 0, bytes: 0
  };
  @Event onOpen: (item: DownloadedComicInfo) => void = (_item: DownloadedComicInfo) => {};
  @Event onDelete: (item: DownloadedComicInfo) => void = (_item: DownloadedComicInfo) => {};

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.item.completedCount.toString())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary'))
        Text('已完成')
          .fontSize(9)
          .fontColor($r('app.color.secondary_text'))
      }
      .justifyContent(FlexAlign.Center)
      .width(58)
      .height(58)
      .backgroundColor($r('app.color.accent_soft'))
      .borderRadius(16)

      Column({ space: 5 }) {
        Text(this.item.name)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.item.chapterCount + ' 章 · ' + this.item.pageCount + ' 页 · ' + formatBytes(this.item.bytes))
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => this.onOpen(this.item))

      Button('删除')
        .type(ButtonType.Normal)
        .height(36)
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.surface_variant'))
        .borderRadius(12)
        .onClick(() => this.onDelete(this.item))
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(18)
  }
}

@ComponentV2
struct DownloadChapterRow {
  @Param item: DownloadedChapterInfo = {
    name: '', uuid: '', comicId: '', directory: '', completed: false, pageCount: 0, bytes: 0
  };
  @Event onOpen: (item: DownloadedChapterInfo) => void = (_item: DownloadedChapterInfo) => {};
  @Event onDelete: (item: DownloadedChapterInfo) => void = (_item: DownloadedChapterInfo) => {};

  build() {
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
      .onClick(() => this.onOpen(this.item))
      Button('删除')
        .type(ButtonType.Normal)
        .height(34)
        .fontSize(11)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.surface_variant'))
        .borderRadius(11)
        .onClick(() => this.onDelete(this.item))
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface'))
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

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.errorText = '';
    try {
      this.comics = downloadStore.listDownloadedComics();
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
        List({ space: 10 }) {
          ForEach(this.comics, (item: DownloadedComicInfo) => {
            ListItem() {
              DownloadComicRow({
                item: item,
                onOpen: (selected: DownloadedComicInfo): void => {
                  this.onOpenComic(selected.directory, selected.name);
                },
                onDelete: (selected: DownloadedComicInfo): void => this.deleteComic(selected)
              })
            }
          }, (item: DownloadedComicInfo) => item.directory)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8, bottom: 48 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@ComponentV2
export struct DownloadChaptersPage {
  @Param comicDirectory: string = '';
  @Param comicName: string = '';
  @Event onBack: () => void = () => {};

  @Local chapters: DownloadedChapterInfo[] = [];
  @Local totalBytes: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.chapters = downloadStore.listDownloadedChapters(this.comicDirectory);
    this.totalBytes = 0;
    for (let i = 0; i < this.chapters.length; i++) {
      this.totalBytes += this.chapters[i].bytes;
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

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  build() {
    Column() {
      DownloadPageHeader({
        title: this.comicName,
        subtitle: this.chapters.length + ' 章 · ' + formatBytes(this.totalBytes),
        onBack: (): void => this.onBack(),
        onRefresh: (): void => this.reload()
      })

      if (this.chapters.length === 0) {
        DownloadEmptyState({ text: '这部漫画还没有下载章节' })
      } else {
        List({ space: 9 }) {
          ForEach(this.chapters, (item: DownloadedChapterInfo) => {
            ListItem() {
              DownloadChapterRow({
                item: item,
                onOpen: (selected: DownloadedChapterInfo): void => {
                  const offline = downloadStore.loadOfflineChapter(selected.directory);
                  if (offline === null || !offline.completed) {
                    this.showToast('章节尚未下载完成');
                  } else {
                    this.showToast('离线阅读器开发中，已保存 ' + offline.imagePaths.length + ' 页');
                  }
                },
                onDelete: (selected: DownloadedChapterInfo): void => this.deleteChapter(selected)
              })
            }
          }, (item: DownloadedChapterInfo) => item.directory)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 8, bottom: 48 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
