import { COLLECTOR_LOG_ENABLED } from '../services/Log';
/**
 * 应用唯一入口：内部枚举路由 + Stack 条件挂载。
 * P3–P7 可直接替换发现占位或对应建设中页面，不需要引入 Navigation/router。
 */
import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { KEY_BROWSE_SOURCE, KEY_HIDE_STATUS_BAR, settingsStore } from '../services/SettingsStore';
import { applyStatusBarVisibility } from '../services/SystemBars';
import { AccountPage } from './AccountPage';
import { DetailPage, handleDetailBack, resetDetailSession } from './DetailPage';
import { DiscoverPage } from './DiscoverPage';
import { DownloadChaptersPage, DownloadsPage } from './DownloadsPage';
import { DownloadManagerPage } from './DownloadManagerPage';
import { HiddenCollectorHost } from './HiddenCollectorHost';
import { FavoritesPage, HistoryPage } from './LibraryPages';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ReaderPage, ReaderChapterRef, handleReaderSystemBack } from './ReaderPage';
import { resetSearchSession, SearchPage } from './SearchPage';
import { SettingsPage } from './SettingsPage';
import {
  applyThemeMode,
  navBarBackground,
  navBlurStyle,
  syncSystemDark,
  themeBackground,
  themeState
} from './ThemeColors';
import { WebPage } from './WebPage';

export enum AppRoute {
  Startup = -1,
  Shell = 0,
  Account = 1,
  Favorites = 2,
  History = 3,
  Downloads = 4,
  Settings = 5,
  Web = 6,
  Search = 8,
  Detail = 9,
  DownloadChapters = 10,
  Reader = 11,
  DownloadManager = 12
}

enum ShellTab {
  Discover = 0,
  More = 1
}

@Entry
@ComponentV2
struct Index {
  @Local route: AppRoute = AppRoute.Startup;
  @Local tab: ShellTab = ShellTab.Discover;
  @Local navIndicatorVp: number = 8;
  @Local selectedMangaId: string = '';
  @Local detailReturnRoute: AppRoute = AppRoute.Shell;
  @Local selectedDownloadDirectory: string = '';
  @Local selectedDownloadName: string = '';
  @Local webAsRoot: boolean = false;
  @Local readerChapterId: string = '';
  @Local readerChapterName: string = '';
  @Local readerChapterSize: number = 0;
  @Local readerSource: string = 'detail';
  /** 阅读器原地切章所需的章节序列（按 index 升序）；离线入口不提供时留空。 */
  @Local readerChapterSequence: ReaderChapterRef[] = [];
  private readerReturnRoute: AppRoute = AppRoute.Detail;
  @Local settingsDraft: string = 'api';
  @Local settingsSessionId: number = 0;
  @Local settingsClosing: boolean = false;
  @Local settingsSaveFailed: boolean = false;
  private envCallbackId: number = -1;
  private webController: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    // 新的根页面实例不继承模块级页面缓存；内部覆盖/返回不会重建 Index，因此不受影响
    resetSearchSession();
    resetDetailSession();
    // 跟随系统档位需要知道系统当前亮/暗：读一次当前配置，并订阅后续变化
    this.applyCurrentColorMode();
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx !== undefined) {
        this.envCallbackId = ctx.getApplicationContext().on('environment', {
          onConfigurationUpdated: (config: Configuration): void => {
            syncSystemDark(config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
          },
          onMemoryLevel: (_level: number): void => {
          }
        });
      }
    } catch (error) {
      // 订阅失败不影响主流程，最多是切换系统主题后 AMOLED 判定慢一拍
    }
    this.applyPersistedChrome();
  }

  aboutToDisappear(): void {
    this.settingsSessionId++;
    if (this.envCallbackId < 0) {
      return;
    }
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx !== undefined) {
        ctx.getApplicationContext().off('environment', this.envCallbackId);
      }
    } catch (error) {
      // 解绑失败无副作用
    }
    this.envCallbackId = -1;
  }

  /** 读当前界面的色模式，喂给「跟随系统」判定。启动时强制同步一次真实系统值。 */
  private applyCurrentColorMode(): void {
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx === undefined) {
        return;
      }
      const mode = ctx.config?.colorMode;
      syncSystemDark(mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK, true);
    } catch (error) {
      // 读不到就保持默认（systemDark=false），跟随系统档位退化为亮色
    }
  }

  /** 详情页里的吐槽浮层是否打开。打开时系统返回键应先关浮层，而不是退出详情页。 */
  @Local detailCommentVisible: boolean = false;

  onBackPress(): boolean {
    if (this.route === AppRoute.Reader) {
      // 章末吐槽页上的返回：先退回本章最后一张图，不直接退出阅读器
      if (handleReaderSystemBack()) {
        return true;
      }
      // 按来源返回（详情进入回详情；网页/下载进入回各自来源）——与工具栏返回同一口径
      this.backFromReader();
      return true;
    }
    if (this.route === AppRoute.Detail) {
      // 吐槽面板是详情页内的浮层，不是独立路由：先关面板，保留在详情页
      if (this.detailCommentVisible) {
        this.detailCommentVisible = false;
        return true;
      }
      // 详情页内部状态（如下载选择模式）：先退模式，再退出详情
      if (handleDetailBack()) {
        return true;
      }
      this.backFromDetail();
      return true;
    }
    if (this.route === AppRoute.DownloadChapters) {
      this.route = AppRoute.Downloads;
      return true;
    }
    if (this.route === AppRoute.Search) {
      this.backFromSearch();
      return true;
    }
    if (this.route === AppRoute.Web) {
      if (this.webAsRoot) {
        try {
          if (this.webController.accessBackward()) {
            this.webController.backward();
          }
        } catch (error) {
        }
        return true;
      }
      return this.handleWebBack();
    }
    if (this.route === AppRoute.Settings) {
      // 系统返回键退出设置：与顶栏返回同一口径，走 backFromSettings（含浏览方式待生效值的应用）
      this.backFromSettings();
      return true;
    }
    if (this.webAsRoot && (this.route === AppRoute.Account || this.route === AppRoute.Favorites ||
      this.route === AppRoute.History || this.route === AppRoute.Downloads ||
      this.route === AppRoute.DownloadManager)) {
      this.route = AppRoute.Web;
      return true;
    }
    if (this.route !== AppRoute.Shell && this.route !== AppRoute.Startup) {
      this.route = AppRoute.Shell;
      this.tab = ShellTab.More;
      return true;
    }
    if (this.tab === ShellTab.More) {
      this.tab = ShellTab.Discover;
      return true;
    }
    return false;
  }

  private async applyPersistedChrome(): Promise<void> {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (ctx === undefined) {
      this.webAsRoot = false;
      this.route = AppRoute.Shell;
      return;
    }
    try {
      // 主题三态（system/light/dark）+ AMOLED：旧布尔值由 themeMode() 内部迁移
      const themeMode = await settingsStore.themeMode();
      const amoled = await settingsStore.amoledBlack();
      const hidden = await settingsStore.getBool(KEY_HIDE_STATUS_BAR, false);
      const browseSource = await settingsStore.browseSource();
      this.webAsRoot = browseSource === 'webview';
      this.route = this.webAsRoot ? AppRoute.Web : AppRoute.Shell;
      try {
        applyThemeMode(themeMode, amoled);
        const mainWindow = await window.getLastWindow(ctx);
        // 状态栏显隐统一走共享实现（冷启动与设置页「立即应用」同一份，防两条路径漂移——曾因此把小白条弄没）
        await applyStatusBarVisibility(ctx, hidden);
          const readNavInset = (): void => {
          let v = 8;
          try {
            const avoid = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
            const measured = mainWindow.getUIContext().px2vp(avoid.bottomRect.height);
            // 底部浮层与导航指示条的呼吸感：系统上报值偏贴（实测 ~20vp，浮栏下沿与指示条仅差 ~7–9vp），
            // 统一加下限于 26vp，避免"贴脸"（用户实测反馈 + 视觉判读）。
            v = Math.max(measured > 0 ? measured : 0, 26);
          } catch (error) {
            v = 26;
          }
          AppStorage.setOrCreate<number>('navIndicatorVp', v);
          this.navIndicatorVp = v;
        };
        readNavInset();
        // 系统栏切换后即时读取可能拿到旧值：跟随 avoidArea 变化刷新（只看导航指示条）
        try {
          mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
            if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
              readNavInset();
            }
          });
        } catch (error) {
        }
      } catch (error) {
      }
    } catch (error) {
      this.webAsRoot = false;
      this.route = AppRoute.Shell;
    }
  }

  private openRoute(route: AppRoute): void {
    if (route === AppRoute.Settings && this.route !== AppRoute.Settings) {
      this.beginSettingsSession();
    }
    this.route = route;
  }

  private beginSettingsSession(): void {
    this.settingsSessionId++;
    this.settingsDraft = this.webAsRoot ? 'webview' : 'api';
    this.settingsClosing = false;
    this.settingsSaveFailed = false;
  }

  private openDetail(id: string, returnRoute: AppRoute): void {
    if (id.length === 0) {
      return;
    }
    this.selectedMangaId = id;
    this.detailReturnRoute = returnRoute;
    this.route = AppRoute.Detail;
  }

  /**
   * 阅读器进入口：统一记录来源路由，供 backFromReader / 系统返回键回落。
   * 详情页进入 → 回详情；网页（含网页根模式）进入 → 回网页页。
   */
  private openReader(chapterId: string, chapterName: string, chapterSize: number,
    sequence: ReaderChapterRef[]): void {
    if (chapterId.length === 0) {
      return;
    }
    this.readerChapterId = chapterId;
    this.readerChapterName = chapterName;
    this.readerChapterSize = chapterSize;
    this.readerChapterSequence = sequence;
    this.readerReturnRoute = AppRoute.Detail;
    this.readerSource = 'detail';
    this.route = AppRoute.Reader;
  }

  /**
   * 网页里点章节 → 原生阅读器。
   * 唯一的差别是返回路由：网页根模式（browseSource=webview）下必须落回网页根页，
   * 普通模式下网页是从「更多」推入的，同样回到它自己那一层——两种情况都是 AppRoute.Web。
   * 走这里时 Detail 从未挂载过，若沿用 openReader 的 AppRoute.Detail 会凭空变出详情页。
   */
  private openReaderFromWeb(comicId: string, chapterId: string, chapterName: string,
    chapterSize: number, sequence: ReaderChapterRef[]): void {
    if (comicId.length === 0 || chapterId.length === 0) {
      return;
    }
    this.selectedMangaId = comicId;
    this.readerChapterId = chapterId;
    this.readerChapterName = chapterName;
    this.readerChapterSize = chapterSize;
    this.readerChapterSequence = sequence;
    this.readerReturnRoute = AppRoute.Web;
    this.readerSource = 'detail';
    this.route = AppRoute.Reader;
  }

  /**
   * 网页降级出口：打开该漫画的原生详情页。
   * 返回路由设为 Web——原生详情页在这条链路上是"网页的子页"，关掉它应当回到网页，
   * 而不是掉到 Shell 的「发现」页（那会让用户在网页模式里迷路）。
   */
  private openDetailFromWeb(comicId: string): void {
    this.openDetail(comicId, AppRoute.Web);
  }

  private backFromReader(): void {
    // 阅读器为自己的返回路由负责：详情进来回详情，网页进来回网页。
    this.route = this.readerReturnRoute;
  }

  /** 离线打开：设置 comicId 后走与详情页同一条阅读器路由；本地页数作 chapterSize 兜底。 */
  private openOfflineReader(comicId: string, chapterUuid: string, chapterName: string,
    localPageCount: number, sequence: ReaderChapterRef[]): void {
    if (comicId.length === 0 || chapterUuid.length === 0) {
      return;
    }
    this.selectedMangaId = comicId;
    this.readerChapterId = chapterUuid;
    this.readerChapterName = chapterName;
    this.readerChapterSize = localPageCount;
    this.readerReturnRoute = AppRoute.DownloadChapters;
    this.route = AppRoute.Reader;
    this.readerSource = 'offline';
    // 离线入口同样持有该漫画「已下载完成章节」的序列：原地切章（工具栏直切 + 到头确认）按序列工作
    this.readerChapterSequence = sequence;
  }

  private backFromSearch(): void {
    // 只有 Search -> Shell 才结束搜索页存活期；Search -> Detail 不经过这里，继续保留。
    resetSearchSession();
    this.route = AppRoute.Shell;
    this.tab = ShellTab.Discover;
  }

  private backFromDetail(): void {
    // 顶栏返回与系统返回统一在这里结束详情流程；Detail -> Reader 不经过这里。
    resetDetailSession();
    // 离开详情页时清掉浮层标记，避免下次进入残留"面板打开"状态
    this.detailCommentVisible = false;
    this.route = this.detailReturnRoute;
  }

  private openDownloadComic(directory: string, name: string): void {
    this.selectedDownloadDirectory = directory;
    this.selectedDownloadName = name;
    this.route = AppRoute.DownloadChapters;
  }

  private handleWebBack(): boolean {
    try {
      if (this.webController.accessBackward()) {
        this.webController.backward();
        return true;
      }
    } catch (error) {
    }
    this.closePage();
    return true;
  }

  private openSettingsFromWeb(): void {
    this.beginSettingsSession();
    this.route = AppRoute.Settings;
  }

  /**
   * 退出设置页：先应用待生效的「浏览方式」（网页壳 ↔ 原生壳），再落到对应根。
   * 设置页在**选中那一刻**就把新值通知过来了（见 SettingsPage.selectBrowseSource），
   * 所以顶栏返回与系统返回键两条路径都能覆盖到；这里负责真正切根。
   */
  private async backFromSettings(): Promise<void> {
    if (this.settingsClosing) return;
    this.settingsClosing = true;
    this.settingsSaveFailed = false;
    const session = this.settingsSessionId;
    const value = this.settingsDraft;
    try {
      await settingsStore.putString(KEY_BROWSE_SOURCE, value);
      if (session !== this.settingsSessionId) return;
      this.applyBrowseSourceChange(value === 'webview');
      if (this.webAsRoot) this.route = AppRoute.Web;
      else this.closePage();
    } catch (error) {
      if (session === this.settingsSessionId) {
        this.settingsClosing = false;
        this.settingsSaveFailed = true;
        // Brief UI feedback is rendered by SettingsPage.
      }
    }
  }

  /**
   * 重算根模式（网页壳 ↔ 原生壳）；与当前不一致时才动。
   *
   * 状态清理要点：
   * - webAsRoot 是常驻 WebPage 的挂载开关，必须先改，否则该卸载时还挂着；
   * - 返回链（detailReturnRoute / readerReturnRoute）指向旧根，一律重置，
   *   避免从新模式里的页面返回时跳回已经不在栈上的旧根；
   * - 搜索/详情会话留在原位不清（切换浏览方式不该丢用户正在看的内容）；
   * - 这里**不设 route**：切根后的落地由调用方（backFromSettings）决定，
   *   这样设置页能正常退场，而不是被瞬间替换掉。
   */
  private applyBrowseSourceChange(nextRoot: boolean): void {
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(0x0000, 'WebShell', '浏览方式切换：%{public}s → %{public}s（webAsRoot %{public}s → %{public}s）',
      this.webAsRoot ? '网页版' : '原生界面', nextRoot ? '网页版' : '原生界面',
      String(this.webAsRoot), String(nextRoot));
    }
    if (nextRoot === this.webAsRoot) {
      return;
    }
    this.webAsRoot = nextRoot;
    // 旧根已经不在栈上：所有指向它的返回链都要重指，否则会跳进空洞
    this.detailReturnRoute = nextRoot ? AppRoute.Web : AppRoute.Shell;
    this.readerReturnRoute = nextRoot ? AppRoute.Web : AppRoute.Detail;
    this.tab = ShellTab.Discover;
    this.detailCommentVisible = false;
  }

  private backFromAccount(): void {
    if (this.webAsRoot) {
      this.route = AppRoute.Web;
      return;
    }
    this.closePage();
  }

  /**
   * 下载页返回：与设置/账户同一口径——网页根模式回网页根页，普通模式回「更多」。
   * 网页根页的 FAB 现在直达下载页，这条返回路径是它的出口。
   */
  private backFromDownloads(): void {
    if (this.webAsRoot) {
      this.route = AppRoute.Web;
      return;
    }
    this.closePage();
  }

  /**
   * 下载管理页返回：与下载页同一口径（网页根回网页根，普通模式回「更多」）。
   * 该页只从「更多」进入，返回也落回「更多」，与 Downloads 的返回路径完全对齐。
   */
  private backFromDownloadManager(): void {
    if (this.webAsRoot) {
      this.route = AppRoute.Web;
      return;
    }
    this.closePage();
  }

  private closePage(): void {
    this.route = AppRoute.Shell;
    this.tab = ShellTab.More;
  }

  /**
   * 底页（启动页 / Shell / 网页根页）的路由转场。
   * 出现侧严格 IDENTITY：返回时由上层页"淡出缩走"揭开底页，底页自己不淡入，
   * 既不给底页默认附加 OPACITY，也避免两层同时淡入把揭示感冲掉。
   * 离开侧 220ms 淡出：底页与进入页同帧卸载，若底页瞬时消失，
   * 进入页 Friction 慢启动的前 ~100ms 会露出纯背景。
   * 转场自带动画，所有 handler 里都不包 animateTo。
   */
  private baseTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.IDENTITY,
      TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut })
    );
  }

  /**
   * 上下层级页（详情/阅读器/搜索/设置/网页/下载系等）的路由转场。
   * 进入＝减速：280ms Curve.Friction（≈cubic-bezier(0.2,0,0.2,1)）+ 0.94 轻缩放 + 淡入；
   * 退出＝加速且更短：180ms Curve.EaseIn + 缩到 0.96 + 淡出。
   */
  private pushTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 }))
        .animation({ duration: 280, curve: Curve.Friction }),
      TransitionEffect.OPACITY
        .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
        .animation({ duration: 180, curve: Curve.EaseIn })
    );
  }

  /**
   * 底栏「发现 ↔ 更多」同级 Tab 切换：约 120ms 极轻交叉淡入。
   * 两个 Tab 视图都是 100% 高，必须留在 Shell 那层 Stack 里同帧叠放（退场侧淡出）；
   * 一旦回到流式排布，退场视图还占着一整屏高度，新列表会被顶出视口。
   * 这是页内 Tab 切换，与上层页的路由转场（280/180/220）互不相干，不共用参数。
   * 转场自带动画，切 Tab 的 handler 里不包 animateTo。
   */
  private tabFadeTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY.animation({ duration: 100, curve: Curve.EaseIn })
    );
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      // ===== 底页（z 最低）：Shell / 网页根页 / 启动页 =====
      // 转场挂在路由挂载点上；同级的「发现 ↔ 更多」Tab 切换挂自己的极轻交叉淡入（120/100ms）。
      // 子节点按"层级由浅到深"排列：转场期间新旧两页同帧共存，下面的先画、上面的后画，
      // 推入时新页在上、返回时被退出的上层页揭开——顺序反了就会把退出动画盖掉。
      if (this.route === AppRoute.Shell) {
        // Tab 视图的承接容器：两个分支都塞在同一个 Stack 里同帧叠放，
        // 退场的一支原地淡出、不再占流式位置，底栏 BottomBar 始终排在它们之后（z 在上）。
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.tab === ShellTab.Discover) {
            DiscoverPage({
              bottomInset: 48,
              onSearch: (): void => this.openRoute(AppRoute.Search),
              onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Shell)
            })
            .transition(this.tabFadeTransition())
          } else {
            MorePage({
              bottomInset: 48,
              onOpen: (route: AppRoute): void => this.openRoute(route)
            })
            .transition(this.tabFadeTransition())
          }
          BottomBar({
            selected: this.tab,
            navIndicatorVp: this.navIndicatorVp,
            onSelect: (tab: ShellTab): void => {
              this.tab = tab;
            }
          })
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        // 网页根模式下 Shell 不可达；万一到达按上层页处理
        .transition(this.webAsRoot ? this.pushTransition() : this.baseTransition())
      }

      // 网页页：webAsRoot 下**常驻不卸载**（普通模式才按路由条件挂载）。
      // 真机实测：条件挂载时，从原生阅读器返回会让 WebPage 重建，
      // 重建时用缓存 pageUrl（仍是 /h5/index）重载 → 用户被弹回主页，而不是离开前的 H5 页面。
      // 对应 Flutter 基线的结论：可见 WebView 必须保活防跳首页。
      // 常驻后它在 Stack 最底层，其余路由（设置/阅读器/下载…）照旧叠在它上面。
      if (this.webAsRoot || this.route === AppRoute.Web) {
        WebPage({
          controller: this.webController,
          showBack: !this.webAsRoot,
          // 只有真正停在网页页时才接管章节：常驻期间被别的路由盖住时要闭嘴
          active: this.route === AppRoute.Web,
          onExit: (): void => this.closePage(),
          onOpenSettings: (): void => this.openSettingsFromWeb(),
          // 网页根页 FAB 单击 = 我的下载（设置仍由 GM openSettings / 更多页到达）
          onOpenDownloads: (): void => this.openRoute(AppRoute.Downloads),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account),
          // 网页里点章节 → 原生阅读器：返回路由落在网页这一层（见 openReaderFromWeb）
          onOpenReader: (comicId: string, chapterId: string, chapterName: string, chapterSize: number,
            sequence: ReaderChapterRef[]): void => {
            this.openReaderFromWeb(comicId, chapterId, chapterName, chapterSize, sequence);
          },
          // 章节握不上时的降级：打开该漫画的原生详情页（返回落回网页）
          onOpenDetail: (comicId: string): void => {
            this.openDetailFromWeb(comicId);
          }
        })
        // 网页根模式下它是底页；普通模式下它是从「更多」推入的上层页
        .transition(this.webAsRoot ? this.baseTransition() : this.pushTransition())
      }

      // 启动页排在底页之上：它退出时淡出，正好盖住同帧挂载的底页（否则启动页在下层会被直接切掉）
      if (this.route === AppRoute.Startup) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.primary'))
          Text('正在准备…')
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .transition(this.baseTransition())
      }

      // ===== 上层页：层级由浅到深 =====
      if (this.route === AppRoute.Search) {
        SearchPage({
          onBack: (): void => this.backFromSearch(),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Search)
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.Account) {
        AccountPage({
          onBack: (): void => this.backFromAccount(),
          onOpenFavorites: (): void => this.openRoute(AppRoute.Favorites),
          onOpenHistory: (): void => this.openRoute(AppRoute.History)
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.Favorites) {
        FavoritesPage({
          onBack: (): void => this.backFromAccount(),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Favorites)
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.History) {
        HistoryPage({
          onBack: (): void => this.backFromAccount(),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.History)
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.Downloads) {
        DownloadsPage({
          onBack: (): void => this.backFromDownloads(),
          onOpenComic: (directory: string, name: string): void => this.openDownloadComic(directory, name)
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.DownloadManager) {
        DownloadManagerPage({
          onBack: (): void => this.backFromDownloadManager()
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.DownloadChapters) {
        DownloadChaptersPage({
          comicDirectory: this.selectedDownloadDirectory,
          comicName: this.selectedDownloadName,
          onBack: (): void => this.openRoute(AppRoute.Downloads),
          onOpenOfflineReader: (comicId: string, chapterUuid: string, chapterName: string,
            localPageCount: number, sequence: ReaderChapterRef[]): void => {
            this.openOfflineReader(comicId, chapterUuid, chapterName, localPageCount, sequence);
          }
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.Settings) {
        SettingsPage({
          browseSourceDraft: this.settingsDraft,
          closing: this.settingsClosing,
          saveError: this.settingsSaveFailed,
          onBack: (): void => { this.backFromSettings(); },
          onBrowseSourceChanged: (value: string): void => {
            if (this.settingsClosing || (value !== 'api' && value !== 'webview')) return;
            this.settingsDraft = value;
          }
        })
        .transition(this.pushTransition())
      }

      if (this.route === AppRoute.Detail) {
        DetailPage({
          mangaId: this.selectedMangaId,
          commentVisible: this.detailCommentVisible,
          commentVisibleChange: (visible: boolean): void => {
            this.detailCommentVisible = visible;
          },
          onBack: (): void => this.backFromDetail(),
          onOpenReader: (chapterId: string, chapterName: string, chapterSize: number,
            sequence: ReaderChapterRef[]): void => {
            this.openReader(chapterId, chapterName, chapterSize, sequence);
          }
        })
        .transition(this.pushTransition())
      }

      // 阅读器最上层：详情进阅读器、下载章节进阅读器两条路都要压在对方之上（不动阅读器内部任何逻辑）
      if (this.route === AppRoute.Reader) {
        ReaderPage({
          comicId: this.selectedMangaId,
          chapterId: this.readerChapterId,
          chapterName: this.readerChapterName,
          chapterSize: this.readerChapterSize,
          chapterSequence: this.readerChapterSequence,
          offlineOnly: this.readerSource === 'offline',
          onExit: (): void => this.backFromReader()
        })
        .transition(this.pushTransition())
      }

      // 隐藏收图页：常驻但不可见、不吃触摸，供「网页收图」图源使用。
      HiddenCollectorHost()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
  }
}

@ComponentV2
struct MorePage {
  @Param bottomInset: number = 78;
  @Event onOpen: (route: AppRoute) => void = (_route: AppRoute) => {};
  /** 当前按压中的入口行：同一时刻只会有一根手指压着一行，多行共用这一份状态即可。 */
  @Local pressedRoute: AppRoute | null = null;

  build() {
    Column() {
      Column({ space: 3 }) {
        Text('MANGACOPY')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .letterSpacing(2.2)
        Text('更多')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      // 与发现页头部对齐（top/bottom 相同），避免切 Tab 时品牌行高低跳动
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          Row({ space: 14 }) {
            Text('人')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.on_primary'))
              .width(50)
              .height(50)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.accent'))
              .borderRadius(16)
            Column({ space: 4 }) {
              Text('账号')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Text('登录后可使用收藏与浏览历史')
                .fontSize(12)
                .fontColor($r('app.color.secondary_text'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(25)
              .fontColor($r('app.color.secondary_text'))
          }
          .width('100%')
          .padding(18)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(22)
          // 与下面的入口行同一档按压手感：0.95 / 160ms FastOutSlowIn
          .scale({
            x: this.pressedRoute === AppRoute.Account ? 0.95 : 1,
            y: this.pressedRoute === AppRoute.Account ? 0.95 : 1
          })
          .animation({ duration: 160, curve: Curve.FastOutSlowIn })
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
              this.pressedRoute = AppRoute.Account;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              if (this.pressedRoute === AppRoute.Account) {
                this.pressedRoute = null;
              }
            }
          })
          .onClick(() => this.onOpen(AppRoute.Account))

          this.groupLabel('我的内容')
          Column() {
            this.menuRow('♡', '收藏', '保存的漫画', AppRoute.Favorites)
            this.rule()
            this.menuRow('↺', '历史', '最近浏览记录', AppRoute.History)
            this.rule()
            this.menuRow('↓', '我的下载', '离线漫画与章节', AppRoute.Downloads)
            this.rule()
            this.menuRow('◷', '下载管理', '进行中与失败的任务', AppRoute.DownloadManager)
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(22)

          this.groupLabel('应用')
          Column() {
            // 「网页版」入口已移除：它不改浏览模式、又没有悬浮球，容易被误当成模式切换。
            // 模式切换统一走「设置 → 浏览方式」。
            this.menuRow('⚙', '设置', '外观、阅读、图源与源站', AppRoute.Settings)
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(22)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.bottomInset })
      }
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  groupLabel(label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.secondary_text'))
      .letterSpacing(1)
      .width('100%')
      .padding({ left: 4, top: 4 })
  }

  @Builder
  rule() {
    Divider()
      .strokeWidth(1)
      .color($r('app.color.divider'))
      .margin({ left: 66, right: 16 })
  }

  @Builder
  menuRow(icon: string, title: string, subtitle: string, route: AppRoute) {
    Row({ space: 14 }) {
      Text(icon)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary'))
        .width(38)
        .height(38)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.accent_soft'))
        .borderRadius(12)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_text'))
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(24)
        .fontColor($r('app.color.secondary_text'))
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 13, bottom: 13 })
    // 入口行按压反馈：0.95 / 160ms FastOutSlowIn，与卡片同一档手感（页面切换另有 280ms 转场）
    .scale({ x: this.pressedRoute === route ? 0.95 : 1, y: this.pressedRoute === route ? 0.95 : 1 })
    .animation({ duration: 160, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedRoute = route;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (this.pressedRoute === route) {
          this.pressedRoute = null;
        }
      }
    })
    .onClick(() => this.onOpen(route))
  }
}

@ComponentV2
struct BottomBar {
  @Param selected: ShellTab = ShellTab.Discover;
  @Param navIndicatorVp: number = 8;
  @Event onSelect: (tab: ShellTab) => void = (_tab: ShellTab) => {};

  private safeBottom(): number {
    const stored = AppStorage.get<number>('navIndicatorVp');
    const inset = stored === undefined ? this.navIndicatorVp : stored;
    return Math.max(8, inset);
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        BottomTabItem({
          symbol: $r('sys.symbol.house'),
          label: '发现',
          tab: ShellTab.Discover,
          selected: this.selected === ShellTab.Discover,
          onSelect: (tab: ShellTab): void => this.onSelect(tab)
        })
        BottomTabItem({
          symbol: $r('sys.symbol.more'),
          label: '更多',
          tab: ShellTab.More,
          selected: this.selected === ShellTab.More,
          onSelect: (tab: ShellTab): void => this.onSelect(tab)
        })
      }
      .width('100%')
      .height(56)
      .padding({ left: 6, right: 6, top: 5, bottom: 5 })
      .backgroundColor(navBarBackground(themeState().isDark, themeState().amoledActive,
        themeState().themeRevision))
      // 深色下用不透明底 + 无材质：厚毛玻璃会把底栏整体提亮，压低未选中文字的对比
      .backgroundBlurStyle(navBlurStyle(themeState().isDark))
      .borderRadius(28)
      .shadow({ radius: 18, color: $r('app.color.nav_shadow'), offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 0 })
    .margin({ bottom: -(this.safeBottom() - 20) })
  }
}

@ComponentV2
struct BottomTabItem {
  @Param symbol: Resource = $r('sys.symbol.house');
  @Param label: string = '';
  @Param tab: ShellTab = ShellTab.Discover;
  @Param selected: boolean = false;
  @Event onSelect: (tab: ShellTab) => void = (_tab: ShellTab) => {};

  build() {
    Column({ space: 2 }) {
      SymbolGlyph(this.symbol)
        .fontSize(23)
        .fontColor([this.selected ? $r('app.color.primary') : $r('app.color.secondary_text')])
      Text(this.label)
        .fontSize(11)
        .lineHeight(14)
        .fontWeight(this.selected ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.selected ? $r('app.color.primary') : $r('app.color.secondary_text'))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(46)
    .backgroundColor(this.selected ? $r('app.color.nav_selected') : $r('app.color.nav_item_clear'))
    .borderRadius(23)
    .onClick(() => this.onSelect(this.tab))
  }
}
