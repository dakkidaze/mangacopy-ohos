/**
 * 应用唯一入口：内部枚举路由 + Stack 条件挂载。
 * P3–P7 可直接替换发现占位或对应建设中页面，不需要引入 Navigation/router。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { KEY_DARK_MODE, KEY_HIDE_STATUS_BAR, settingsStore } from '../services/SettingsStore';
import { AccountPage } from './AccountPage';
import { DebugPage } from './DebugPage';
import { DetailPage } from './DetailPage';
import { DiscoverPage } from './DiscoverPage';
import { DownloadChaptersPage, DownloadsPage } from './DownloadsPage';
import { FavoritesPage, HistoryPage } from './LibraryPages';
import { SearchPage } from './SearchPage';
import { SettingsPage } from './SettingsPage';
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
  Debug = 7,
  Search = 8,
  Detail = 9,
  DownloadChapters = 10
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
  private webController: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.applyPersistedChrome();
  }

  onBackPress(): boolean {
    if (this.route === AppRoute.Detail) {
      this.route = this.detailReturnRoute;
      return true;
    }
    if (this.route === AppRoute.DownloadChapters) {
      this.route = AppRoute.Downloads;
      return true;
    }
    if (this.route === AppRoute.Search) {
      this.route = AppRoute.Shell;
      this.tab = ShellTab.Discover;
      return true;
    }
    if (this.route === AppRoute.Web) {
      if (this.webAsRoot) {
        return false;
      }
      return this.handleWebBack();
    }
    if (this.route === AppRoute.Debug) {
      this.route = AppRoute.Settings;
      return true;
    }
    if (this.route === AppRoute.Settings && this.webAsRoot) {
      this.route = AppRoute.Web;
      return true;
    }
    if (this.webAsRoot && (this.route === AppRoute.Account || this.route === AppRoute.Favorites ||
      this.route === AppRoute.History)) {
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
      const dark = await settingsStore.getBool(KEY_DARK_MODE, false);
      const hidden = await settingsStore.getBool(KEY_HIDE_STATUS_BAR, false);
      const browseSource = await settingsStore.browseSource();
      const colorMode = dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
        ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      this.webAsRoot = browseSource === 'webview';
      this.route = this.webAsRoot ? AppRoute.Web : AppRoute.Shell;
      try {
        ctx.getApplicationContext().setColorMode(colorMode);
        const mainWindow = await window.getLastWindow(ctx);
        await mainWindow.setWindowSystemBarEnable(hidden ? ['navigation'] : ['status', 'navigation']);
        let insetVp = 8;
        try {
          const avoid = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          const measuredVp = mainWindow.getUIContext().px2vp(avoid.bottomRect.height);
          insetVp = measuredVp > 0 ? measuredVp : 8;
        } catch (error) {
          insetVp = 8;
        }
        AppStorage.setOrCreate<number>('navIndicatorVp', insetVp);
        this.navIndicatorVp = insetVp;
      } catch (error) {
      }
    } catch (error) {
      this.webAsRoot = false;
      this.route = AppRoute.Shell;
    }
  }

  private openRoute(route: AppRoute): void {
    this.route = route;
  }

  private openDetail(id: string, returnRoute: AppRoute): void {
    if (id.length === 0) {
      return;
    }
    this.selectedMangaId = id;
    this.detailReturnRoute = returnRoute;
    this.route = AppRoute.Detail;
  }

  private backFromSearch(): void {
    this.route = AppRoute.Shell;
    this.tab = ShellTab.Discover;
  }

  private backFromDetail(): void {
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
    this.route = AppRoute.Settings;
  }

  private backFromSettings(): void {
    if (this.webAsRoot) {
      this.route = AppRoute.Web;
      return;
    }
    this.closePage();
  }

  private backFromAccount(): void {
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

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

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
      }

      if (this.route === AppRoute.Shell) {
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.tab === ShellTab.Discover) {
            DiscoverPage({
              bottomInset: 48,
              onSearch: (): void => this.openRoute(AppRoute.Search),
              onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Shell)
            })
          } else {
            MorePage({
              bottomInset: 48,
              onOpen: (route: AppRoute): void => this.openRoute(route)
            })
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
      }

      if (this.route === AppRoute.Search) {
        SearchPage({
          onBack: (): void => this.backFromSearch(),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Search)
        })
      }

      if (this.route === AppRoute.Detail) {
        DetailPage({
          mangaId: this.selectedMangaId,
          onBack: (): void => this.backFromDetail()
        })
      }

      if (this.route === AppRoute.Account) {
        AccountPage({
          onBack: (): void => this.backFromAccount(),
          onOpenFavorites: (): void => this.openRoute(AppRoute.Favorites),
          onOpenHistory: (): void => this.openRoute(AppRoute.History)
        })
      }

      if (this.route === AppRoute.Favorites) {
        FavoritesPage({
          onBack: (): void => this.backFromAccount(),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.Favorites)
        })
      }

      if (this.route === AppRoute.History) {
        HistoryPage({
          onBack: (): void => this.backFromAccount(),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account),
          onOpenDetail: (id: string): void => this.openDetail(id, AppRoute.History)
        })
      }

      if (this.route === AppRoute.Downloads) {
        DownloadsPage({
          onBack: (): void => this.closePage(),
          onOpenComic: (directory: string, name: string): void => this.openDownloadComic(directory, name)
        })
      }

      if (this.route === AppRoute.DownloadChapters) {
        DownloadChaptersPage({
          comicDirectory: this.selectedDownloadDirectory,
          comicName: this.selectedDownloadName,
          onBack: (): void => this.openRoute(AppRoute.Downloads)
        })
      }

      if (this.route === AppRoute.Settings) {
        SettingsPage({
          onBack: (): void => this.backFromSettings(),
          onOpenDebug: (): void => this.openRoute(AppRoute.Debug)
        })
      }

      if (this.route === AppRoute.Debug) {
        DebugPage({
          onBack: (): void => this.openRoute(AppRoute.Settings)
        })
      }

      if (this.route === AppRoute.Web) {
        WebPage({
          controller: this.webController,
          showBack: !this.webAsRoot,
          onExit: (): void => this.closePage(),
          onOpenSettings: (): void => this.openSettingsFromWeb(),
          onOpenAccount: (): void => this.openRoute(AppRoute.Account)
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}

@ComponentV2
struct MorePage {
  @Param bottomInset: number = 78;
  @Event onOpen: (route: AppRoute) => void = (_route: AppRoute) => {};

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
      .padding({ left: 20, right: 20, top: 22, bottom: 14 })

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
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
          .onClick(() => this.onOpen(AppRoute.Account))

          this.groupLabel('我的内容')
          Column() {
            this.menuRow('♡', '收藏', '保存的漫画', AppRoute.Favorites)
            this.rule()
            this.menuRow('↺', '历史', '最近浏览记录', AppRoute.History)
            this.rule()
            this.menuRow('↓', '我的下载', '离线漫画与章节', AppRoute.Downloads)
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)

          this.groupLabel('应用')
          Column() {
            this.menuRow('⚙', '设置', '外观、阅读、图源与源站', AppRoute.Settings)
            this.rule()
            this.menuRow('◎', '网页版', '打开移动版源站页面', AppRoute.Web)
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.bottomInset })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
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
      .backgroundColor($r('app.color.nav_surface'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
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
