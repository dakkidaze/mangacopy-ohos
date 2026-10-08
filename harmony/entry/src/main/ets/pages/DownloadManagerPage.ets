/**
 * 下载管理页：进行中 / 等待中 / 失败任务的实时视图。
 *
 * 数据源只有 DownloadStore 的内存任务表（snapshotTasks），全程不碰磁盘扫描：
 *  - 行内数值：@Param 直连 ChapterDownloadState（@ObservedV2 + @Trace），自动刷新、零轮询；
 *    排队中的章跑起来时状态在 @Trace 上翻成 Downloading，行组件自动换组，无需手动搬移；
 *  - 列表增删：页面可见期间约 1.5s 一次纯内存重扫，aboutToDisappear 统一清 timer
 *    （照阅读器时间胶囊 timer 的做法）。
 *
 * 头部与空态在本文件里复刻下载页同款：DownloadPageHeader / DownloadEmptyState 未导出，
 * 而 DownloadsPage.ets 属于本 lane 的禁改文件，不能去加 export。
 */
import {
  ChapterDownloadState,
  ChapterDownloadStatus,
  downloadStore
} from './DownloadStore';
import { themeBackground, themeState } from './ThemeColors';

/** 列表增删的重扫周期（纯内存遍历）。行内数值不靠它刷新——那是 @Trace 的活。 */
const TASK_SCAN_INTERVAL_MS: number = 1500;

/** 头部：与下载页 DownloadPageHeader 同款同参数（标题 / 副标题 / 返回 / 刷新）。 */
@ComponentV2
struct ManagerPageHeader {
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
      .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
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
      .accessibilityText('立即重扫任务列表')
      .onClick(() => this.onRefresh())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
  }
}

/** 空态：与下载页 DownloadEmptyState 同款，只换主文案。 */
@ComponentV2
struct ManagerEmptyState {
  @Param text: string = '没有进行中的下载';

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
    .layoutWeight(1)
    .padding(24)
  }
}

/**
 * 进行中任务行：名字 + 页数进度 + 单章取消。
 * 数值全部读 @Param 任务对象的 @Trace 字段（completed/total），下载推进即重绘，不参与轮询。
 */
@ComponentV2
struct RunningTaskRow {
  @Param task: ChapterDownloadState = new ChapterDownloadState();
  @Event onCancel: (task: ChapterDownloadState) => void =
    (_task: ChapterDownloadState): void => {};

  private titleText(): string {
    return this.task.comicName.length > 0 ? this.task.comicName : '未命名漫画';
  }

  private chapterText(): string {
    return this.task.chapterName.length > 0 ? this.task.chapterName : '未命名章节';
  }

  /** 页数进度：total 还没拿到（页清单请求在途）时给「准备中」，别显示 0/0。 */
  private progressText(): string {
    if (this.task.total <= 0) {
      return '准备中…';
    }
    return this.task.completed + '/' + this.task.total + ' 页 · ' + this.task.progressPercent() + '%';
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 5 }) {
        Text(this.titleText())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.chapterText())
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.progressText())
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .width('100%')
        Progress({ value: this.task.progressPercent(), total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color($r('app.color.primary'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive,
            themeState().themeRevision))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([$r('app.color.primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor($r('app.color.accent_soft'))
      .accessibilityText('取消本章下载')
      .onClick(() => this.onCancel(this.task))
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(16)
  }
}

/** 排队任务行：名字 + 「排队中 · 第 N 位」+ 出队取消。名字与位置都随重扫/队列推进更新。 */
@ComponentV2
struct QueuedTaskRow {
  @Param task: ChapterDownloadState = new ChapterDownloadState();
  /** 队列位次（1 起）：由 scan 每拍重算并写进签名，位次变了这行才会重建。 */
  @Param queueIndex: number = 0;
  @Event onCancel: (task: ChapterDownloadState) => void =
    (_task: ChapterDownloadState): void => {};

  private titleText(): string {
    return this.task.comicName.length > 0 ? this.task.comicName : '未命名漫画';
  }

  private chapterText(): string {
    return this.task.chapterName.length > 0 ? this.task.chapterName : '未命名章节';
  }

  private queueText(): string {
    return this.queueIndex > 0 ? '排队中 · 第 ' + this.queueIndex + ' 位' : '排队中';
  }

  build() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.clock'))
        .fontSize(22)
        .fontColor([$r('app.color.secondary_text')])
        .width(30)
      Column({ space: 4 }) {
        Text(this.titleText())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.chapterText())
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.queueText())
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([$r('app.color.primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor($r('app.color.accent_soft'))
      .accessibilityText('取消排队，把本章移出等待队列')
      .onClick(() => this.onCancel(this.task))
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .backgroundColor(themeBackground('surface_variant', themeState().amoledActive,
      themeState().themeRevision))
    .borderRadius(16)
  }
}

/** 失败任务行：错误文案 + 重试 + 移除。 */
@ComponentV2
struct FailedTaskRow {
  @Param task: ChapterDownloadState = new ChapterDownloadState();
  @Event onRetry: (task: ChapterDownloadState) => void =
    (_task: ChapterDownloadState): void => {};
  @Event onRemove: (task: ChapterDownloadState) => void =
    (_task: ChapterDownloadState): void => {};

  private titleText(): string {
    return this.task.comicName.length > 0 ? this.task.comicName : '未命名漫画';
  }

  private chapterText(): string {
    return this.task.chapterName.length > 0 ? this.task.chapterName : '未命名章节';
  }

  private errorText(): string {
    return this.task.errorText.length > 0 ? this.task.errorText : '下载失败';
  }

  build() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(24)
        .fontColor([$r('app.color.accent')])
        .width(30)
      Column({ space: 4 }) {
        Text(this.titleText())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.chapterText())
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.errorText())
          .fontSize(11)
          .fontColor($r('app.color.accent'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 8 }) {
        // 存下来的 request 能自持重跑 downloadChapter 时才给重试；没有就只留「移除」
        if (this.task.request !== null) {
          Button('重试')
            .type(ButtonType.Normal)
            .stateEffect(true)
            .height(30)
            .fontSize(12)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.accent_soft'))
            .borderRadius(10)
            .padding({ left: 10, right: 10 })
            .onClick(() => this.onRetry(this.task))
        }
        Button('移除')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(30)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive,
            themeState().themeRevision))
          .borderRadius(10)
          .padding({ left: 10, right: 10 })
          .onClick(() => this.onRemove(this.task))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    .borderRadius(16)
  }
}

@ComponentV2
export struct DownloadManagerPage {
  @Event onBack: () => void = () => {};

  /** 进行中组、等待中组与失败组：只在「成员或状态变了」时整体替换（见 scan 的签名比对）。 */
  @Local running: ChapterDownloadState[] = [];
  @Local queued: ChapterDownloadState[] = [];
  @Local failed: ChapterDownloadState[] = [];
  /** 上次快照的成员签名：签名没变就不写 @Local，避免每 1.5s 白重绘一遍列表。 */
  private signature: string = '';
  /** 队列位次缓存（scan 时算好）：给「等待中」行显示第几位；位次变化会进签名触发重建。 */
  private queuePositions: Map<string, number> = new Map<string, number>();
  private scanTimer: number = -1;

  aboutToAppear(): void {
    this.scan();
    this.scanTimer = setInterval((): void => {
      this.scan();
    }, TASK_SCAN_INTERVAL_MS);
  }

  aboutToDisappear(): void {
    if (this.scanTimer >= 0) {
      clearInterval(this.scanTimer);
    }
    this.scanTimer = -1;
  }

  /** 任务键：与 DownloadStore 的 taskKey 同口径（comicId:chapterId），拿不到就退回名字拼接。 */
  private taskKey(task: ChapterDownloadState): string {
    const request = task.request;
    if (request !== null) {
      return request.comicId + ':' + request.chapterId;
    }
    return task.comicName + ':' + task.chapterName;
  }

  /**
   * 纯内存重扫：snapshotTasks 只读枚举（不打磁盘、不改状态），按 status 分三组。
   * 成员签名没变就直接返回——不重写 @Local，也就不会重建行组件。
   * 队列位次也进签名：前面的任务被取消后，后面每行的「第 N 位」都要跟着改。
   * force 给「用户刚点了按钮」用：签名归零后可能与空签名相等，必须强写一次数组，
   * 否则刚被取消/移除的最后一行会赖着不走。
   */
  private scan(force: boolean = false): void {
    let snapshot: ChapterDownloadState[] = [];
    try {
      snapshot = downloadStore.snapshotTasks();
    } catch (error) {
      return;
    }
    const nextRunning: ChapterDownloadState[] = [];
    const nextQueued: ChapterDownloadState[] = [];
    const nextFailed: ChapterDownloadState[] = [];
    const nextPositions: Map<string, number> = new Map<string, number>();
    let signature = '';
    for (let i = 0; i < snapshot.length; i++) {
      const task = snapshot[i];
      if (task.status === ChapterDownloadStatus.Downloading) {
        nextRunning.push(task);
        signature += 'r' + this.taskKey(task) + ';';
      } else if (task.status === ChapterDownloadStatus.Queued) {
        const position = downloadStore.queuePosition(task);
        nextPositions.set(this.taskKey(task), position);
        nextQueued.push(task);
        signature += 'q' + this.taskKey(task) + '#' + position + ';';
      } else if (task.status === ChapterDownloadStatus.Failed) {
        nextFailed.push(task);
        signature += 'f' + this.taskKey(task) + ';';
      }
    }
    if (!force && signature === this.signature) {
      return;
    }
    this.signature = signature;
    this.queuePositions = nextPositions;
    this.running = nextRunning;
    this.queued = nextQueued;
    this.failed = nextFailed;
  }

  /** 行内取队列位次：scan 每拍重算，位次变化已通过签名强制重建该行。 */
  private positionOf(task: ChapterDownloadState): number {
    const value = this.queuePositions.get(this.taskKey(task));
    return value === undefined ? 0 : value;
  }

  /** 手动刷新（头部按钮 / 各行操作之后）：强制重取一次快照，不等下一拍。 */
  private manualRefresh(): void {
    this.scan(true);
  }

  private subtitleText(): string {
    if (this.running.length === 0 && this.queued.length === 0 && this.failed.length === 0) {
      return '暂无进行中的任务';
    }
    const parts: string[] = [];
    if (this.running.length > 0) {
      parts.push('进行中 ' + this.running.length);
    }
    if (this.queued.length > 0) {
      parts.push('等待中 ' + this.queued.length);
    }
    if (this.failed.length > 0) {
      parts.push('失败 ' + this.failed.length);
    }
    return parts.join(' · ');
  }

  private cancelTask(task: ChapterDownloadState): void {
    const request = task.request;
    if (request === null) {
      return;
    }
    // 走既有单章取消：在跑的收口、排队的出队，状态当场变 Cancelled，立刻重扫把这行撤出
    downloadStore.cancel(request.comicId, request.chapterId);
    this.manualRefresh();
  }

  private cancelAllTasks(): void {
    const count = downloadStore.cancelAll();
    this.manualRefresh();
    this.showToast(count > 0 ? '已取消 ' + count + ' 个任务（含排队）' : '没有进行中的任务');
  }

  /**
   * 重试：存下来的 request 自己就能重跑 downloadChapter（与详情页同一条路径）。
   * 开跑是同步置 Downloading 的，所以随后立刻重扫，这行会从失败组挪进进行中组。
   * 不 await：下载继续在模块级 store 里跑，与本页生命周期无关。
   */
  private retryTask(task: ChapterDownloadState): void {
    const request = task.request;
    if (request === null) {
      return;
    }
    downloadStore.downloadChapter(request)
      .catch((_error: Object): void => {});
    this.manualRefresh();
  }

  /** 移除：只打 dismissed 标记（snapshot 过滤），任务对象留在表里，详情页引用不失效。 */
  private removeTask(task: ChapterDownloadState): void {
    downloadStore.dismissFailed(task);
    this.manualRefresh();
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  @Builder
  sectionHeader(title: string, withCancelAll: boolean) {
    Row() {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.secondary_text'))
        .letterSpacing(1)
      Blank()
      if (withCancelAll) {
        Button('全部取消')
          .type(ButtonType.Normal)
          .stateEffect(true)
          .height(28)
          .fontSize(11)
          .fontColor($r('app.color.accent'))
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .onClick(() => this.cancelAllTasks())
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6 })
  }

  build() {
    Column() {
      ManagerPageHeader({
        title: '下载管理',
        subtitle: this.subtitleText(),
        onBack: (): void => this.onBack(),
        onRefresh: (): void => this.manualRefresh()
      })

      if (this.running.length === 0 && this.queued.length === 0 && this.failed.length === 0) {
        ManagerEmptyState({ text: '没有进行中的下载' })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            if (this.running.length > 0) {
              this.sectionHeader('进行中 ' + this.running.length,
                this.running.length + this.queued.length > 0)
              Column({ space: 9 }) {
                ForEach(this.running, (task: ChapterDownloadState) => {
                  RunningTaskRow({
                    task: task,
                    onCancel: (target: ChapterDownloadState): void => this.cancelTask(target)
                  })
                }, (task: ChapterDownloadState): string => this.taskKey(task) + ':running')
              }
              .width('100%')
            }

            if (this.queued.length > 0) {
              // 「全部取消」只出现在第一个可见组上：有进行中挂在进行中组，否则挂在等待中组
              this.sectionHeader('等待中 ' + this.queued.length, this.running.length === 0)
              Column({ space: 9 }) {
                ForEach(this.queued, (task: ChapterDownloadState) => {
                  QueuedTaskRow({
                    task: task,
                    queueIndex: this.positionOf(task),
                    onCancel: (target: ChapterDownloadState): void => this.cancelTask(target)
                  })
                }, (task: ChapterDownloadState): string => this.taskKey(task) + ':queued')
              }
              .width('100%')
            }

            if (this.failed.length > 0) {
              this.sectionHeader('失败 ' + this.failed.length, false)
              Column({ space: 9 }) {
                ForEach(this.failed, (task: ChapterDownloadState) => {
                  FailedTaskRow({
                    task: task,
                    onRetry: (target: ChapterDownloadState): void => this.retryTask(target),
                    onRemove: (target: ChapterDownloadState): void => this.removeTask(target)
                  })
                }, (task: ChapterDownloadState): string => this.taskKey(task) + ':failed')
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 48 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive,
      themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
