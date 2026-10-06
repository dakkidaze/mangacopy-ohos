/**
 * 应用唯一入口：内部枚举路由 + Stack 条件挂载。
 * P3–P7 可直接替换发现占位或对应建设中页面，不需要引入 Navigation/router。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { KEY_DARK_MODE, KEY_HIDE_STATUS_BAR, settingsStore } from '../services/SettingsStore';
import { DebugPage } from './DebugPage';
import { SettingsPage } from './SettingsPage';

export enum AppRoute {
  Shell = 0,
  Account = 1,
  Favorites = 2,
  History = 3,
  Downloads = 4,
  Settings = 5,
  Web = 6,
  Debug = 7,
  Search = 8,
  Detail = 9
}

enum ShellTab {
  Discover = 0,
  More = 1
}

@Entry
@ComponentV2
struct Index {
  @Local route: AppRoute = AppRoute.Shell;
  @Local tab: ShellTab = ShellTab.Discover;
  @Local navIndicatorVp: number = 8;

  aboutToAppear(): void {
    this.applyPersistedChrome();
  }

  onBackPress(): boolean {
    if (this.route !== AppRoute.Shell) {
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
      return;
    }
    const dark = await settingsStore.getBool(KEY_DARK_MODE, false);
    const hidden = await settingsStore.getBool(KEY_HIDE_STATUS_BAR, false);
    const colorMode = dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
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
  }

  private openRoute(route: AppRoute): void {
    this.route = route;
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

      if (this.route === AppRoute.Shell) {
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.tab === ShellTab.Discover) {
            DiscoverPlaceholder({
              bottomInset: 70 + Math.max(8, this.navIndicatorVp),
              onSearch: (): void => this.openRoute(AppRoute.Search)
            })
          } else {
            MorePage({
              bottomInset: 70 + Math.max(8, this.navIndicatorVp),
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

      if (this.route === AppRoute.Settings) {
        SettingsPage({
          onBack: (): void => this.closePage(),
          onOpenDebug: (): void => this.openRoute(AppRoute.Debug)
        })
      }

      if (this.route === AppRoute.Debug) {
        DebugPage({
          onBack: (): void => this.openRoute(AppRoute.Settings)
        })
      }

      if (this.route === AppRoute.Account || this.route === AppRoute.Favorites ||
        this.route === AppRoute.History || this.route === AppRoute.Downloads ||
        this.route === AppRoute.Web || this.route === AppRoute.Search || this.route === AppRoute.Detail) {
        ConstructionPage({
          route: this.route,
          onBack: (): void => this.closePage()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}

@ComponentV2
struct DiscoverPlaceholder {
  @Param bottomInset: number = 78;
  @Event onSearch: () => void = () => {};

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('MANGACOPY')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent'))
            .letterSpacing(2.2)
          Text('发现')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('⌕')
          .type(ButtonType.Circle)
          .width(44)
          .height(44)
          .fontSize(24)
          .fontColor($r('app.color.primary_text'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => this.onSearch())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 22, bottom: 14 })

      Scroll() {
        Column({ space: 18 }) {
          Stack({ alignContent: Alignment.BottomStart }) {
            Column() {
              Row() {
                Blank()
                Text('漫')
                  .fontSize(80)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.hero_mark'))
                  .opacity(0.34)
                  .margin({ right: 8, top: -10 })
              }
              .width('100%')
              .layoutWeight(1)
            }
            .width('100%')
            .height('100%')

            Column({ space: 8 }) {
              Text('原生发现页')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.on_primary'))
              Text('热门、最新与搜索将在下一阶段接入。')
                .fontSize(14)
                .lineHeight(21)
                .fontColor($r('app.color.hero_secondary'))
              Row({ space: 6 }) {
                Text('P3')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.primary'))
                  .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                  .backgroundColor($r('app.color.on_primary'))
                  .borderRadius(9)
                Text('页面挂载点已准备')
                  .fontSize(12)
                  .fontColor($r('app.color.hero_secondary'))
              }
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 20, right: 20, bottom: 20 })
          }
          .width('100%')
          .height(208)
          .backgroundColor($r('app.color.primary'))
          .borderRadius(28)

          Column({ space: 10 }) {
            Row() {
              Text('即将提供')
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Blank()
              Text('原生浏览')
                .fontSize(11)
                .fontColor($r('app.color.accent'))
            }
            .width('100%')
            Row({ space: 10 }) {
              this.previewTile('热', '热门漫画', '按热度浏览')
              this.previewTile('新', '最近更新', '追更更直接')
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(22)

          Column({ space: 7 }) {
            Text('现在可以做什么')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.primary_text'))
            Text('前往「更多」查看账号、收藏、历史、下载入口，或先调整阅读、图源与源站设置。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(17)
          .backgroundColor($r('app.color.surface_variant'))
          .borderRadius(20)
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
  }

  @Builder
  previewTile(mark: string, title: string, subtitle: string) {
    Column({ space: 7 }) {
      Text(mark)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.accent_soft'))
        .borderRadius(11)
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Text(subtitle)
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .padding(13)
    .backgroundColor($r('app.color.surface_variant'))
    .borderRadius(16)
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
            this.menuRow('◎', '网页版', '网页入口将在后续接入', AppRoute.Web)
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
    .padding({ left: 12, right: 12, top: 6, bottom: this.safeBottom() + 8 })
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

@ComponentV2
struct ConstructionPage {
  @Param route: AppRoute = AppRoute.Account;
  @Event onBack: () => void = () => {};

  private title(): string {
    if (this.route === AppRoute.Account) {
      return '账号';
    }
    if (this.route === AppRoute.Favorites) {
      return '收藏';
    }
    if (this.route === AppRoute.History) {
      return '历史';
    }
    if (this.route === AppRoute.Downloads) {
      return '我的下载';
    }
    if (this.route === AppRoute.Web) {
      return '网页版';
    }
    if (this.route === AppRoute.Search) {
      return '搜索';
    }
    return '漫画详情';
  }

  private nextPhase(): string {
    if (this.route === AppRoute.Account || this.route === AppRoute.Favorites || this.route === AppRoute.History) {
      return '账号与书架能力将在后续阶段接入';
    }
    if (this.route === AppRoute.Downloads) {
      return '下载管理将在后续阶段接入';
    }
    if (this.route === AppRoute.Web) {
      return '网页浏览能力尚未接入，这里不会打开阅读器';
    }
    return '原生发现与详情页将在下一阶段接入';
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Button('‹')
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .fontSize(28)
          .fontColor($r('app.color.primary_text'))
          .backgroundColor($r('app.color.surface_variant'))
          .onClick(() => this.onBack())
        Text(this.title())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 12 })

      Column({ space: 14 }) {
        Text('…')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .width(62)
          .height(62)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.primary'))
          .borderRadius(20)
        Text('建设中')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.nextPhase())
          .fontSize(14)
          .lineHeight(21)
          .fontColor($r('app.color.secondary_text'))
          .textAlign(TextAlign.Center)
          .width('76%')
        Button('返回更多')
          .type(ButtonType.Normal)
          .height(42)
          .padding({ left: 24, right: 24 })
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .borderRadius(14)
          .margin({ top: 8 })
          .onClick(() => this.onBack())
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .layoutWeight(1)
      .margin({ bottom: 64 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
