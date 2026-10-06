/**
 * 可复用吐槽面板。
 * chapterId 与 comicId 可单独提供；两者同时提供时显示双 Tab，并分别维护加载状态。
 */
import { Comment } from '../model/Models';
import { BrowseLoadState, BrowseStatePanel, describeBrowseError, getBrowseSource } from './BrowseSupport';

export enum CommentPanelTab {
  Chapter = 'chapter',
  Comic = 'comic'
}

@ObservedV2
class CommentFeedState {
  @Trace state: BrowseLoadState = BrowseLoadState.Idle;
  @Trace comments: Comment[] = [];
  @Trace errorText: string = '';
  private revision: number = 0;

  async loadChapter(chapterId: string): Promise<void> {
    if (chapterId.length === 0) {
      this.comments = [];
      this.state = BrowseLoadState.Empty;
      return;
    }
    const ticket = ++this.revision;
    this.state = BrowseLoadState.Loading;
    this.errorText = '';
    try {
      const source = await getBrowseSource();
      const comments = await source.chapterComments(chapterId);
      if (ticket !== this.revision) {
        return;
      }
      this.comments = comments;
      this.state = comments.length === 0 ? BrowseLoadState.Empty : BrowseLoadState.Content;
    } catch (error) {
      if (ticket !== this.revision) {
        return;
      }
      this.errorText = describeBrowseError(error as Object);
      this.state = BrowseLoadState.Error;
    }
  }

  async loadComic(comicId: string): Promise<void> {
    if (comicId.length === 0) {
      this.comments = [];
      this.state = BrowseLoadState.Empty;
      return;
    }
    const ticket = ++this.revision;
    this.state = BrowseLoadState.Loading;
    this.errorText = '';
    try {
      const source = await getBrowseSource();
      const comments = await source.comicComments(comicId);
      if (ticket !== this.revision) {
        return;
      }
      this.comments = comments;
      this.state = comments.length === 0 ? BrowseLoadState.Empty : BrowseLoadState.Content;
    } catch (error) {
      if (ticket !== this.revision) {
        return;
      }
      this.errorText = describeBrowseError(error as Object);
      this.state = BrowseLoadState.Error;
    }
  }
}

@ComponentV2
struct CommentTabButton {
  @Param label: string = '';
  @Param value: CommentPanelTab = CommentPanelTab.Chapter;
  @Param selected: CommentPanelTab = CommentPanelTab.Chapter;
  @Event onSelect: (value: CommentPanelTab) => void = (_value: CommentPanelTab) => {};

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(38)
      .fontSize(13)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.secondary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') : $r('app.color.nav_item_clear'))
      .borderRadius(19)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
struct CommentRow {
  @Param item: Comment = new Comment('', '', '', '');

  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(this.item.user.length > 0 ? this.item.user.substring(0, 1) : '匿')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.primary'))
          .borderRadius(16)
        Column({ space: 2 }) {
          Text(this.item.user.length > 0 ? this.item.user : '匿名用户')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.item.createdAt.length > 0) {
            Text(this.item.createdAt)
              .fontSize(10)
              .fontColor($r('app.color.secondary_text'))
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Text(this.item.content.length > 0 ? this.item.content : '（无内容）')
        .fontSize(14)
        .lineHeight(21)
        .fontColor($r('app.color.primary_text'))
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface_variant'))
    .borderRadius(16)
  }
}

@ComponentV2
struct CommentFeedView {
  @Require @Param feed: CommentFeedState = new CommentFeedState();
  @Event onRetry: () => void = () => {};

  build() {
    if (this.feed.state === BrowseLoadState.Content) {
      List({ space: 10 }) {
        ForEach(this.feed.comments, (item: Comment, index: number) => {
          ListItem() {
            CommentRow({ item: item })
          }
        }, (item: Comment, index: number) => item.id + ':' + index.toString())
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 48 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    } else {
      BrowseStatePanel({
        state: this.feed.state,
        errorText: this.feed.errorText,
        idleText: '准备读取吐槽',
        loadingText: '正在读取吐槽…',
        emptyTitle: '还没有吐槽',
        emptyDescription: '这里暂时没有可显示的内容',
        onRetry: (): void => this.onRetry()
      })
    }
  }
}

@ComponentV2
export struct CommentPanel {
  @Param visible: boolean = false;
  @Param chapterId: string = '';
  @Param comicId: string = '';
  @Param initialTab: CommentPanelTab = CommentPanelTab.Chapter;
  @Event onClose: () => void = () => {};

  @Local activeTab: CommentPanelTab = CommentPanelTab.Chapter;
  @Local chapterFeed: CommentFeedState = new CommentFeedState();
  @Local comicFeed: CommentFeedState = new CommentFeedState();

  aboutToAppear(): void {
    if (this.initialTab === CommentPanelTab.Comic && this.comicId.length > 0) {
      this.activeTab = CommentPanelTab.Comic;
    } else if (this.chapterId.length > 0) {
      this.activeTab = CommentPanelTab.Chapter;
    } else {
      this.activeTab = CommentPanelTab.Comic;
    }
    this.loadActiveFeed();
  }

  private hasBothTabs(): boolean {
    return this.chapterId.length > 0 && this.comicId.length > 0;
  }

  private panelTitle(): string {
    return this.activeTab === CommentPanelTab.Chapter ? '本章吐槽' : '漫画总评';
  }

  private selectTab(tab: CommentPanelTab): void {
    this.activeTab = tab;
    this.loadActiveFeed();
  }

  private loadActiveFeed(): void {
    if (this.activeTab === CommentPanelTab.Chapter) {
      if (this.chapterFeed.state === BrowseLoadState.Idle) {
        this.chapterFeed.loadChapter(this.chapterId);
      }
    } else if (this.comicFeed.state === BrowseLoadState.Idle) {
      this.comicFeed.loadComic(this.comicId);
    }
  }

  private retryActiveFeed(): void {
    if (this.activeTab === CommentPanelTab.Chapter) {
      this.chapterFeed.loadChapter(this.chapterId);
    } else {
      this.comicFeed.loadComic(this.comicId);
    }
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.scrim'))
          .onClick(() => this.onClose())

        Column() {
          Row()
            .width(42)
            .height(5)
            .backgroundColor($r('app.color.divider'))
            .borderRadius(3)
            .margin({ top: 9, bottom: 8 })

          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.panelTitle())
                .fontSize(21)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Text(this.activeTab === CommentPanelTab.Chapter ? '当前章节的讨论' : '这部漫画的总评')
                .fontSize(11)
                .fontColor($r('app.color.secondary_text'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(19)
                .fontColor([$r('app.color.primary_text')])
            }
            .width(38)
            .height(38)
            .backgroundColor($r('app.color.surface_variant'))
            .onClick(() => this.onClose())
          }
          .width('100%')
          .padding({ left: 18, right: 14, bottom: 10 })

          if (this.hasBothTabs()) {
            Row({ space: 4 }) {
              CommentTabButton({
                label: '章末吐槽',
                value: CommentPanelTab.Chapter,
                selected: this.activeTab,
                onSelect: (value: CommentPanelTab): void => this.selectTab(value)
              })
              CommentTabButton({
                label: '总评',
                value: CommentPanelTab.Comic,
                selected: this.activeTab,
                onSelect: (value: CommentPanelTab): void => this.selectTab(value)
              })
            }
            .width('calc(100% - 32vp)')
            .height(46)
            .padding(4)
            .backgroundColor($r('app.color.surface_variant'))
            .borderRadius(23)
            .margin({ left: 16, right: 16, bottom: 4 })
          }

          if (this.activeTab === CommentPanelTab.Chapter) {
            CommentFeedView({
              feed: this.chapterFeed,
              onRetry: (): void => this.retryActiveFeed()
            })
          } else {
            CommentFeedView({
              feed: this.comicFeed,
              onRetry: (): void => this.retryActiveFeed()
            })
          }
        }
        .width('100%')
        .height('78%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius({ topLeft: 28, topRight: 28 })
        .shadow({ radius: 24, color: $r('app.color.panel_shadow'), offsetX: 0, offsetY: -6 })
        .onClick(() => {})
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else {
      Column()
        .width(0)
        .height(0)
    }
  }
}
