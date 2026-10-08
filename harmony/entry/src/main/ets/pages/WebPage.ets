/** 可见的移动版网页壳。仅负责 H5 浏览，不包含隐藏收图或网页阅读器。 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { kMobileUserAgent } from '../services/ApiHeaders';
import { settingsStore } from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { navBarBackground, navBlurStyle, themeBackground, themeState } from './ThemeColors';

const GM_METHODS: string[] = [
  'loadComic',
  'hideFab',
  'enterProfile',
  'openSettings',
  'loadChapter',
  'setTitle',
  'setFab',
  'setLoadingDialog',
  'setLoadingDialogProgress',
  'toggleStatusBar',
  'onChapterBlocked',
  'onReaderDetected'
];

class VisibleWebBridge {
  onReaderBlocked: (value: string) => void = (_value: string) => {};
  onHideFab: () => void = () => {};
  onOpenSettings: () => void = () => {};
  onEnterProfile: () => void = () => {};
  onTitle: (value: string) => void = (_value: string) => {};
  onReaderDetectedCallback: () => void = () => {};

  loadComic(url: string): void {
    if (url.indexOf('/comicContent/') >= 0) {
      this.onReaderBlocked(url);
    }
  }

  hideFab(): void {
    this.onHideFab();
  }

  enterProfile(): void {
    this.onEnterProfile();
  }

  openSettings(): void {
    this.onOpenSettings();
  }

  loadChapter(result: string): void {
    this.onReaderBlocked(result);
  }

  setTitle(title: string): void {
    this.onTitle(title);
  }

  setFab(_json: string): void {
  }

  setLoadingDialog(_visible: boolean): void {
  }

  setLoadingDialogProgress(_index: number, _count: number): void {
  }

  toggleStatusBar(): void {
  }

  onReaderDetected(): void {
    this.onReaderDetectedCallback();
  }

  onChapterBlocked(): void {
    this.onReaderBlocked('');
  }
}

@ComponentV2
struct WebHeader {
  @Param showBack: boolean = true;
  @Param title: string = '网页版';
  @Param pageUrl: string = '';
  @Param loading: boolean = false;
  @Param refreshEnabled: boolean = false;
  @Event onBack: () => void = () => {};
  @Event onRefresh: () => void = () => {};

  build() {
    Row({ space: 10 }) {
      if (this.showBack) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(21)
            .fontColor([$r('app.color.primary_text')])
        }
        .width(44)
        .height(44)
        .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => this.onBack())
      }

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.pageUrl.length > 0 ? this.pageUrl.replace('https://', '') : '正在选择源站…')
          .fontSize(10)
          .fontColor($r('app.color.secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        if (this.loading) {
          LoadingProgress()
            .width(19)
            .height(19)
            .color($r('app.color.primary'))
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(19)
            .fontColor([$r('app.color.primary')])
        }
      }
      .width(44)
      .height(44)
      .backgroundColor($r('app.color.accent_soft'))
      .enabled(this.refreshEnabled)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => this.onRefresh())
    }
    .width('100%')
    .height(64)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
    // 注意：这里必须是 Default（自身+子节点响应，阻塞兄弟节点）。
    // 用 Block 会「阻塞子节点」→ header 里的返回/刷新按钮全部点不动（已实测踩过）。
    .hitTestBehavior(HitTestMode.Default)
    .zIndex(20)
    .onTouch((event: TouchEvent) => {
      hilog.info(0x0000, 'WebShell', 'header touch: %{public}d', event.type as number);
    })
  }
}

@ComponentV2
export struct WebPage {
  @Require @Param controller: webview.WebviewController = new webview.WebviewController();
  @Param showBack: boolean = true;
  @Event onExit: () => void = () => {};
  @Event onOpenSettings: () => void = () => {};
  @Event onOpenDownloads: () => void = () => {};
  @Event onOpenAccount: () => void = () => {};

  @Local title: string = '网页版';
  @Local pageUrl: string = '';
  @Local loading: boolean = true;
  @Local progress: number = 0;
  @Local failed: boolean = false;
  @Local errorText: string = '';
  @Local fabVisible: boolean = true;
  @Local fabReady: boolean = false;
  @Local fabX: number = -1;
  @Local fabY: number = -1;
  @Local viewportWidth: number = 0;
  @Local viewportHeight: number = 0;

  private controllerAttached: boolean = false;
  private gmScript: string = '';
  private interfaceScript: string = '';
  private guardScript: string = '';
  private readerRecoveryQuietUntil: number = 0;
  private refreshTicket: number = 0;
  private pendingRefreshTicket: number = 0;
  private refreshInFlight: boolean = false;
  private bridge: VisibleWebBridge = new VisibleWebBridge();
  private fabStartX: number = 0;
  private fabStartY: number = 0;
  private fabTouchStartX: number = 0;
  private fabTouchStartY: number = 0;
  private fabTracking: boolean = false;
  private fabMoved: boolean = false;
  @Local fabPressed: boolean = false;

  aboutToAppear(): void {
    this.loadScripts();
    this.loadFabPosition();
    this.prepareHome();
  }

  private loadScripts(): void {
    const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (context === undefined) {
      this.errorText = '应用上下文尚未准备好';
      this.failed = true;
      return;
    }
    try {
      const decoder = util.TextDecoder.create('utf-8');
      this.gmScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/gm_shim.js'));
      this.interfaceScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/i.js'));
      this.guardScript = decoder.decodeToString(
        context.resourceManager.getRawFileContentSync('js/guard.js'));
    } catch (error) {
      this.errorText = '页面脚本读取失败';
      this.failed = true;
    }
  }

  private async prepareHome(): Promise<void> {
    try {
      const cached = await UrlManager.bootstrap();
      this.pageUrl = UrlManager.activeUrl;
      if (!cached) {
        // 首次无缓存：同步测速选源，再进页（现状保持）
        await UrlManager.probe();
        this.pageUrl = UrlManager.activeUrl;
      } else {
        // 有缓存先进 + 后台测速：fire-and-forget，只更新 sticky/落盘与提示（lastProbeNote），
        // 不打断当前页、不自动重载，也不 await。
        UrlManager.probe().catch((_error: Object): void => {});
      }
      this.loadPreparedUrl();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '源站准备失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private async loadFabPosition(): Promise<void> {
    try {
      const savedX = await settingsStore.getString('fab_dx', '');
      const savedY = await settingsStore.getString('fab_dy', '');
      if (savedX.length > 0 && savedY.length > 0) {
        const x = Number(savedX);
        const y = Number(savedY);
        if (!Number.isNaN(x) && !Number.isNaN(y)) {
          this.fabX = x;
          this.fabY = y;
        }
      }
    } catch (error) {
    }
    this.placeFabWithinBounds();
  }

  private placeFabWithinBounds(): void {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) {
      return;
    }
    const size = 48;
    const minX = 12;
    const maxX = Math.max(minX, this.viewportWidth - size - 12);
    const minY = 72;
    const safeBottom = Math.max(80, this.navigationInset() + 52);
    const maxY = Math.max(minY, this.viewportHeight - size - safeBottom);
    if (this.fabX < 0 || this.fabY < 0) {
      this.fabX = maxX;
      this.fabY = maxY;
    } else {
      this.fabX = Math.max(minX, Math.min(maxX, this.fabX));
      this.fabY = Math.max(minY, Math.min(maxY, this.fabY));
    }
    this.fabReady = true;
  }

  private navigationInset(): number {
    const inset = AppStorage.get<number>('navIndicatorVp');
    return inset === undefined ? 8 : Math.max(8, inset);
  }

  private async saveFabPosition(): Promise<void> {
    try {
      await settingsStore.putString('fab_dx', this.fabX.toString());
      await settingsStore.putString('fab_dy', this.fabY.toString());
    } catch (error) {
    }
  }

  private touchPoint(event: TouchEvent): TouchObject | null {
    if ((event.type === TouchType.Up || event.type === TouchType.Cancel) && event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    if (event.touches.length > 0) {
      return event.touches[0];
    }
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    return null;
  }

  private handleFabTouch(event: TouchEvent): void {
    const point = this.touchPoint(event);
    if (event.type === TouchType.Down && point !== null) {
      this.fabTouchStartX = point.windowX;
      this.fabTouchStartY = point.windowY;
      this.fabStartX = this.fabX;
      this.fabStartY = this.fabY;
      this.fabTracking = true;
      this.fabMoved = false;
      this.fabPressed = true;
      event.stopPropagation();
      return;
    }
    if (event.type === TouchType.Move && this.fabTracking && point !== null) {
      const dx = point.windowX - this.fabTouchStartX;
      const dy = point.windowY - this.fabTouchStartY;
      if (Math.sqrt(dx * dx + dy * dy) >= 6) {
        this.fabMoved = true;
      }
      if (this.fabMoved) {
        this.fabX = this.fabStartX + dx;
        this.fabY = this.fabStartY + dy;
        this.placeFabWithinBounds();
      }
      event.stopPropagation();
      return;
    }
    if (event.type === TouchType.Up) {
      if (!this.fabTracking) {
        this.fabPressed = false;
        return;
      }
      if (point !== null) {
        const dx = point.windowX - this.fabTouchStartX;
        const dy = point.windowY - this.fabTouchStartY;
        if (Math.sqrt(dx * dx + dy * dy) >= 6) {
          this.fabMoved = true;
          this.fabX = this.fabStartX + dx;
          this.fabY = this.fabStartY + dy;
          this.placeFabWithinBounds();
        }
      }
      const moved = this.fabMoved;
      this.fabTracking = false;
      this.fabMoved = false;
      this.fabPressed = false;
      event.stopPropagation();
      if (moved) {
        this.saveFabPosition();
      } else {
        // 单击 = 打开「我的下载」（对齐 Flutter 网页版 FAB 语义；设置仍从 GM openSettings / 更多页进）
        this.onOpenDownloads();
      }
      return;
    }
    if (event.type === TouchType.Cancel) {
      this.fabTracking = false;
      this.fabMoved = false;
      this.fabPressed = false;
      event.stopPropagation();
    }
  }

  private configureBridge(): void {
    this.bridge.onReaderBlocked = (_value: string): void => {
      this.showToast('阅读器开发中');
    };
    this.bridge.onHideFab = (): void => {
      if (this.showBack) {
        this.fabVisible = false;
      } else {
        this.fabVisible = true;
      }
    };
    this.bridge.onOpenSettings = (): void => {
      this.onOpenSettings();
    };
    this.bridge.onEnterProfile = (): void => {
      this.onOpenAccount();
    };
    this.bridge.onTitle = (value: string): void => {
      if (value.trim().length > 0) {
        this.title = value;
      }
    };
    this.bridge.onReaderDetectedCallback = (): void => {
      this.handleReaderDetected();
    };
  }

  private onControllerAttached(): void {
    this.controllerAttached = true;
    this.configureBridge();
    try {
      this.controller.registerJavaScriptProxy(this.bridge, 'GM', GM_METHODS);
      this.controller.setCustomUserAgent(kMobileUserAgent);
      this.loadPreparedUrl();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '网页组件初始化失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private loadPreparedUrl(): void {
    if (!this.controllerAttached || this.pageUrl.length === 0) {
      return;
    }
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    try {
      this.controller.loadUrl(this.pageUrl);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ? value.message : '网页加载失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private refreshPage(): void {
    hilog.info(0x0000, 'WebShell', 'refresh tapped');
    if (!this.controllerAttached) {
      hilog.error(0x0000, 'WebShell', 'refresh result: failed, controller not attached');
      return;
    }
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    this.refreshInFlight = true;
    const ticket = ++this.refreshTicket;
    this.pendingRefreshTicket = ticket;
    try {
      this.controller.refresh();
      hilog.info(0x0000, 'WebShell', 'refresh dispatched: controller.refresh');
      setTimeout(() => {
        if (this.pendingRefreshTicket === ticket) {
          this.fallbackRefresh(ticket, 'controller.refresh 未触发页面加载');
        }
      }, 700);
    } catch (error) {
      const value = error as Error;
      const message = value.message !== undefined && value.message.length > 0 ? value.message : 'refresh failed';
      this.fallbackRefresh(ticket, message);
    }
  }

  private fallbackRefresh(ticket: number, reason: string): void {
    hilog.warn(0x0000, 'WebShell', 'refresh fallback: %{public}s', reason);
    this.pendingRefreshTicket = -ticket;
    try {
      this.controller.loadUrl(this.pageUrl);
      hilog.info(0x0000, 'WebShell', 'refresh fallback dispatched: loadUrl');
      setTimeout(() => {
        if (this.refreshInFlight && this.pendingRefreshTicket === -ticket) {
          this.pendingRefreshTicket = 0;
          this.refreshInFlight = false;
          this.loading = false;
          this.failed = true;
          this.errorText = '刷新未触发页面加载';
          hilog.error(0x0000, 'WebShell', 'refresh result: failed, no page lifecycle after fallback');
        }
      }, 3000);
    } catch (fallbackError) {
      const fallback = fallbackError as Error;
      const message = fallback.message !== undefined && fallback.message.length > 0 ?
        fallback.message : 'loadUrl failed';
      this.pendingRefreshTicket = 0;
      this.refreshInFlight = false;
      hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', message);
      this.errorText = '刷新失败：' + message;
      this.failed = true;
      this.loading = false;
    }
  }

  private handleReaderDetected(): void {
    const now = Date.now();
    if (now < this.readerRecoveryQuietUntil) {
      return;
    }
    this.readerRecoveryQuietUntil = now + 3000;
    this.showToast('阅读器开发中');
    this.pageUrl = UrlManager.activeUrl + '/h5/index';
    this.failed = false;
    this.errorText = '';
    this.loading = true;
    this.progress = 0;
    try {
      this.controller.loadUrl(this.pageUrl);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '返回网页首页失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private async injectScripts(): Promise<void> {
    if (this.gmScript.length === 0 || this.interfaceScript.length === 0 || this.guardScript.length === 0) {
      return;
    }
    try {
      await this.controller.runJavaScript(this.gmScript);
      await this.controller.runJavaScript(this.interfaceScript);
      // i.js 的首次 hideFab 针对旧版上下文下载按钮；根模式仍需保留设置逃生入口。
      if (!this.showBack) {
        this.fabVisible = true;
      }
      await this.controller.runJavaScript(this.guardScript);
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        '页面脚本注入失败：' + value.message : '页面脚本注入失败';
      this.failed = true;
    }
  }

  private handleBack(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return;
      }
    } catch (error) {
    }
    this.onExit();
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row()
          .width('100%')
          .height(64)

        Stack({ alignContent: Alignment.Top }) {
        Web({ src: '', controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onlineImageAccess(true)
          // JS 弹窗自动确认（默认会弹系统对话框，方向相反）：alert/confirm 直接确认，prompt 回空输入。
          // 依据本机 SDK `ets/component/web.d.ts` 的 WebAttribute：
          //   onAlert(callback: Callback<OnAlertEvent, boolean>)
          //   onConfirm(callback: Callback<OnConfirmEvent, boolean>)
          //   onPrompt(callback: Callback<OnPromptEvent, boolean>)
          // 返回 true = 应用接管弹窗，需用 JsResult 回执（handleConfirm / handlePromptConfirm）。
          .onAlert((event: OnAlertEvent): boolean => {
            event.result.handleConfirm();
            return true;
          })
          .onConfirm((event: OnConfirmEvent): boolean => {
            event.result.handleConfirm();
            return true;
          })
          .onPrompt((event: OnPromptEvent): boolean => {
            event.result.handlePromptConfirm('');
            return true;
          })
          .onControllerAttached(() => {
            this.onControllerAttached();
          })
          .onConsole((event: OnConsoleEvent) => {
            hilog.info(0x0000, 'WebShell', 'H5: %{public}s', event.message.getMessage());
            return false;
          })
          .onPageBegin((_event: OnPageBeginEvent) => {
            this.loading = true;
            this.failed = false;
            this.errorText = '';
            if (this.refreshInFlight) {
              this.pendingRefreshTicket = 0;
              hilog.info(0x0000, 'WebShell', 'refresh result: ok, page begin');
            }
          })
          .onProgressChange((event: OnProgressChangeEvent) => {
            this.progress = event.newProgress;
            this.loading = event.newProgress < 100;
          })
          .onTitleReceive((event: OnTitleReceiveEvent) => {
            if (event.title.trim().length > 0) {
              this.title = event.title;
            }
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            const requestUrl = event.data.getRequestUrl();
            if (event.data.isMainFrame() && requestUrl.indexOf('/comicContent/') >= 0) {
              this.showToast('阅读器开发中');
              return true;
            }
            return false;
          })
          .onPageEnd((event: OnPageEndEvent) => {
            this.loading = false;
            if (this.refreshInFlight) {
              this.pendingRefreshTicket = 0;
              this.refreshInFlight = false;
              hilog.info(0x0000, 'WebShell', 'refresh result: ok, page end');
            }
            if (!this.showBack) {
              this.fabVisible = true;
            }
            if (event.url.length > 0 && event.url !== 'about:blank' && !this.failed) {
              this.pageUrl = event.url;
              this.injectScripts();
            }
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              this.loading = false;
              this.failed = true;
              this.errorText = event.error.getErrorInfo();
              if (this.refreshInFlight) {
                this.pendingRefreshTicket = 0;
                this.refreshInFlight = false;
                hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', this.errorText);
              }
            }
          })
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              this.loading = false;
              this.failed = true;
              this.errorText = '网页请求失败（HTTP ' + event.response.getResponseCode() + '）';
              if (this.refreshInFlight) {
                this.pendingRefreshTicket = 0;
                this.refreshInFlight = false;
                hilog.error(0x0000, 'WebShell', 'refresh result: failed %{public}s', this.errorText);
              }
            }
          })
          .width('100%')
          .height('100%')

        if (this.loading) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color($r('app.color.primary'))
            .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        }

        if (this.failed) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(34)
              .fontColor([$r('app.color.accent')])
            Text('网页加载失败')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
            Text(this.errorText)
              .fontSize(12)
              .lineHeight(18)
              .fontColor($r('app.color.secondary_text'))
              .textAlign(TextAlign.Center)
              .maxLines(3)
            Button('重新加载')
              .type(ButtonType.Normal)
              .height(40)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor($r('app.color.primary'))
              .borderRadius(13)
              .onClick(() => this.loadPreparedUrl())
          }
          .justifyContent(FlexAlign.Center)
          .width('calc(100% - 32vp)')
          .padding(22)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(22)
          .margin({ top: 80 })
          .shadow({ radius: 12, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 4 })
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .zIndex(0)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
      .zIndex(0)

      WebHeader({
        showBack: this.showBack,
        title: this.title,
        pageUrl: this.pageUrl,
        loading: this.loading,
        refreshEnabled: this.controllerAttached,
        onBack: (): void => this.handleBack(),
        onRefresh: (): void => this.refreshPage()
      })

      if (!this.showBack && this.fabVisible && this.fabReady) {
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_down_circle'))
            .fontSize(23)
            .fontColor([$r('app.color.primary')])
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .width(48)
        .height(48)
        .backgroundColor(navBarBackground(themeState().isDark, themeState().amoledActive,
          themeState().themeRevision))
        .backgroundBlurStyle(navBlurStyle(themeState().isDark))
        .borderRadius(24)
        .shadow({ radius: 14, color: $r('app.color.nav_shadow'), offsetX: 0, offsetY: 5 })
        .position({ x: this.fabX, y: this.fabY })
        .zIndex(8)
        .scale({ x: this.fabPressed ? 0.95 : 1, y: this.fabPressed ? 0.95 : 1 })
        .animation({ duration: 100, curve: Curve.EaseOut })
        .accessibilityText('打开我的下载，可拖动')
        .onTouch((event: TouchEvent) => {
          this.handleFabTouch(event);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const width = newArea.width as number;
      const height = newArea.height as number;
      if (width > 0 && height > 0) {
        this.viewportWidth = width;
        this.viewportHeight = height;
        this.placeFabWithinBounds();
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
