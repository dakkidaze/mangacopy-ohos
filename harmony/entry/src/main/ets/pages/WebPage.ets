/** 可见的移动版网页壳。仅负责 H5 浏览，不包含隐藏收图或网页阅读器。 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { kMobileUserAgent } from '../services/ApiHeaders';
import { UrlManager } from '../services/UrlManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
  'toggleStatusBar'
];

class VisibleWebBridge {
  onReaderBlocked: (value: string) => void = (_value: string) => {};
  onOpenSettings: () => void = () => {};
  onEnterProfile: () => void = () => {};
  onTitle: (value: string) => void = (_value: string) => {};

  loadComic(url: string): void {
    this.onReaderBlocked(url);
  }

  hideFab(): void {
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
}

@ComponentV2
export struct WebPage {
  @Require @Param controller: webview.WebviewController = new webview.WebviewController();
  @Event onExit: () => void = () => {};
  @Event onOpenSettings: () => void = () => {};
  @Event onOpenAccount: () => void = () => {};

  @Local title: string = '网页版';
  @Local pageUrl: string = '';
  @Local loading: boolean = true;
  @Local progress: number = 0;
  @Local failed: boolean = false;
  @Local errorText: string = '';

  private controllerAttached: boolean = false;
  private gmScript: string = '';
  private interfaceScript: string = '';
  private bridge: VisibleWebBridge = new VisibleWebBridge();

  aboutToAppear(): void {
    this.loadScripts();
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
    } catch (error) {
      this.errorText = '页面脚本读取失败';
      this.failed = true;
    }
  }

  private async prepareHome(): Promise<void> {
    try {
      const cached = await UrlManager.bootstrap();
      if (!cached) {
        await UrlManager.probe();
      }
      this.pageUrl = UrlManager.activeUrl;
      this.loadPreparedUrl();
    } catch (error) {
      const value = error as Error;
      this.errorText = value.message !== undefined && value.message.length > 0 ?
        value.message : '源站准备失败';
      this.failed = true;
      this.loading = false;
    }
  }

  private configureBridge(): void {
    this.bridge.onReaderBlocked = (_value: string): void => {
      this.showToast('阅读器开发中');
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

  private async injectScripts(): Promise<void> {
    if (this.gmScript.length === 0 || this.interfaceScript.length === 0) {
      return;
    }
    try {
      await this.controller.runJavaScript(this.gmScript);
      await this.controller.runJavaScript(this.interfaceScript);
      // 诊断用：每秒上报当前 URL（SPA 前端路由变化也能看到），日志经 onConsole 转 hilog
      await this.controller.runJavaScript(
        "if(!window.__cmUrlProbe){window.__cmUrlProbe=setInterval(function(){console.log('CMURL='+location.href);},1500);}"
      );
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
        .onClick(() => this.handleBack())

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
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(19)
            .fontColor([$r('app.color.primary')])
        }
        .width(38)
        .height(38)
        .backgroundColor($r('app.color.accent_soft'))
        .enabled(this.controllerAttached && !this.loading)
        .onClick(() => this.loadPreparedUrl())
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 8 })
      .backgroundColor($r('app.color.surface'))

      Stack({ alignContent: Alignment.Top }) {
        Web({ src: '', controller: this.controller })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onlineImageAccess(true)
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
            }
          })
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              this.loading = false;
              this.failed = true;
              this.errorText = '网页请求失败（HTTP ' + event.response.getResponseCode() + '）';
            }
          })
          .width('100%')
          .height('100%')

        if (this.loading) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.surface_variant'))
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
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .margin({ top: 80 })
          .shadow({ radius: 12, color: $r('app.color.card_shadow'), offsetX: 0, offsetY: 4 })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
