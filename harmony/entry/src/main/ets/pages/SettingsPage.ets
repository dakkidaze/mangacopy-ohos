/**
 * 应用设置：所有偏好读写都经 SettingsStore，键名与移植规格 C 保持一致。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiDomainManager } from '../services/ApiDomainManager';
import {
  KEY_BROWSE_SOURCE,
  KEY_CHAPTER_END_COMMENTS,
  KEY_CHAPTER_SOURCE,
  KEY_DARK_MODE,
  KEY_HIDE_STATUS_BAR,
  KEY_IMAGE_CACHE_LIMIT_MB,
  KEY_R2L,
  KEY_READ_MODE,
  KEY_SHOW_PAGE_NUM,
  KEY_SOURCE_PROFILE,
  KEY_VOL_TURN,
  settingsStore
} from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';

function abilityContext(): common.UIAbilityContext | undefined {
  return AppStorage.get<common.UIAbilityContext>('abilityContext');
}

@ComponentV2
export struct SettingsPage {
  @Event onBack: () => void = () => {};
  @Event onOpenDebug: () => void = () => {};

  @Local loaded: boolean = false;
  @Local darkMode: boolean = false;
  @Local hideStatusBar: boolean = false;
  @Local readMode: string = 'h';
  @Local r2l: boolean = true;
  @Local showPageNum: boolean = true;
  @Local volTurn: boolean = false;
  @Local sourceProfile: string = 'fast';
  @Local browseSource: string = 'webview';
  @Local chapterSource: string = 'webview';
  @Local chapterEndComments: boolean = true;
  @Local imageCacheLimitMb: number = 1024;

  @Local webDomain: string = '读取中…';
  @Local apiDomain: string = '尚未测速';
  @Local manualMode: boolean = false;
  @Local showDomainChoices: boolean = false;
  @Local probing: boolean = false;
  @Local probeNote: string = '';
  @Local cacheNote: string = '缓存统计与清理将在缓存模块接入后可用';

  private apiDomains: ApiDomainManager = new ApiDomainManager();

  aboutToAppear(): void {
    this.loadSettings();
  }

  private async loadSettings(): Promise<void> {
    try {
      this.darkMode = await settingsStore.getBool(KEY_DARK_MODE, false);
      this.hideStatusBar = await settingsStore.getBool(KEY_HIDE_STATUS_BAR, false);
      this.readMode = this.validReadMode(await settingsStore.getString(KEY_READ_MODE, 'h'));
      this.r2l = await settingsStore.getBool(KEY_R2L, true);
      this.showPageNum = await settingsStore.getBool(KEY_SHOW_PAGE_NUM, true);
      this.volTurn = await settingsStore.getBool(KEY_VOL_TURN, false);
      this.sourceProfile = this.validSourceProfile(
        await settingsStore.getString(KEY_SOURCE_PROFILE, 'fast'));
      this.browseSource = this.validBinarySource(
        await settingsStore.getString(KEY_BROWSE_SOURCE, 'webview'));
      this.chapterSource = this.validBinarySource(
        await settingsStore.getString(KEY_CHAPTER_SOURCE, 'webview'));
      this.chapterEndComments = await settingsStore.getBool(KEY_CHAPTER_END_COMMENTS, true);
      this.imageCacheLimitMb = await settingsStore.getInt(KEY_IMAGE_CACHE_LIMIT_MB, 1024);
      await UrlManager.bootstrap();
      this.webDomain = UrlManager.activeUrl;
      this.manualMode = UrlManager.manualMode;
      this.apiDomain = this.apiDomains.active;
    } catch (error) {
      this.showToast('部分设置读取失败');
    } finally {
      this.loaded = true;
    }
  }

  private validReadMode(value: string): string {
    return ['h', 'v', 'w'].indexOf(value) >= 0 ? value : 'h';
  }

  private validSourceProfile(value: string): string {
    return ['conservative', 'normal', 'fast', 'turbo'].indexOf(value) >= 0 ? value : 'fast';
  }

  private validBinarySource(value: string): string {
    return ['webview', 'api'].indexOf(value) >= 0 ? value : 'webview';
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  private applyTheme(dark: boolean): void {
    const ctx = abilityContext();
    if (ctx === undefined) {
      return;
    }
    const mode = dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      ctx.getApplicationContext().setColorMode(mode);
    } catch (error) {
      this.showToast('主题切换失败');
    }
  }

  private async applyStatusBar(hidden: boolean): Promise<void> {
    const ctx = abilityContext();
    if (ctx === undefined) {
      return;
    }
    try {
      const mainWindow = await window.getLastWindow(ctx);
      await mainWindow.setWindowSystemBarEnable(hidden ? ['navigation'] : ['status', 'navigation']);
    } catch (error) {
      const be = error as BusinessError;
      this.showToast('状态栏设置失败：' + be.message);
    }
  }

  private async setDarkMode(value: boolean): Promise<void> {
    this.darkMode = value;
    await settingsStore.putBool(KEY_DARK_MODE, value);
    this.applyTheme(value);
  }

  private async setHideStatusBar(value: boolean): Promise<void> {
    this.hideStatusBar = value;
    await settingsStore.putBool(KEY_HIDE_STATUS_BAR, value);
    await this.applyStatusBar(value);
  }

  private async selectReadMode(value: string): Promise<void> {
    this.readMode = value;
    await settingsStore.putString(KEY_READ_MODE, value);
  }

  private async selectSourceProfile(value: string): Promise<void> {
    this.sourceProfile = value;
    await settingsStore.putString(KEY_SOURCE_PROFILE, value);
  }

  private async selectBrowseSource(value: string): Promise<void> {
    this.browseSource = value;
    await settingsStore.putString(KEY_BROWSE_SOURCE, value);
  }

  private async selectChapterSource(value: string): Promise<void> {
    this.chapterSource = value;
    await settingsStore.putString(KEY_CHAPTER_SOURCE, value);
  }

  private async setManualDomain(url: string): Promise<void> {
    await UrlManager.setManualUrl(url);
    this.webDomain = UrlManager.activeUrl;
    this.manualMode = true;
    this.showDomainChoices = false;
    this.probeNote = '已锁定 Web 域；恢复自动前不会自动切换';
    this.showToast('已手动指定源站');
  }

  private async restoreAutomaticDomain(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    this.probeNote = '正在恢复自动选源…';
    try {
      this.webDomain = await UrlManager.clearManualUrl();
      this.manualMode = false;
      this.probeNote = UrlManager.lastProbeNote;
      this.showToast('已恢复自动选源');
    } catch (error) {
      this.probeNote = '恢复失败，请稍后重试';
    } finally {
      this.probing = false;
    }
  }

  private async reprobeDomains(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    this.probeNote = '正在检查 Web 与 API 线路…';
    try {
      const seeded = await this.apiDomains.bootstrapFromNetwork4('https://api.copy202601.com');
      if (seeded.length > 0 && this.apiDomains.candidates.indexOf(seeded) < 0) {
        this.apiDomains.candidates.unshift(seeded);
      }
      this.apiDomain = await this.apiDomains.probeBest();
      this.webDomain = await UrlManager.probe();
      this.manualMode = UrlManager.manualMode;
      this.probeNote = UrlManager.lastProbeNote.length > 0 ? UrlManager.lastProbeNote : '测速完成';
    } catch (error) {
      this.probeNote = '测速失败，请检查网络后重试';
    } finally {
      this.probing = false;
    }
  }

  private cacheLimitLabel(value: number): string {
    return value === 0 ? '不限' : value + ' MB';
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
        Column({ space: 2 }) {
          Text('设置')
            .fontSize(25)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.loaded ? '阅读与连接偏好' : '正在读取偏好…')
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 10 }) {
          this.sectionHeader('01', '外观', '主题与系统界面')
          Column() {
            this.switchRow('夜间模式', '开启时固定深色；关闭时跟随系统', this.darkMode, (value: boolean): void => {
              this.setDarkMode(value);
            })
            this.rule()
            this.switchRow('隐藏状态栏', '立即应用，导航栏保持可用', this.hideStatusBar, (value: boolean): void => {
              this.setHideStatusBar(value);
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('02', '阅读', '阅读器接入后沿用这些偏好')
          Column({ space: 12 }) {
            this.fieldLabel('阅读模式', this.readMode === 'h' ? '横向' : this.readMode === 'v' ? '纵向' : '条漫')
            Row({ space: 8 }) {
              this.optionChip('横向', 'h', this.readMode, (): void => { this.selectReadMode('h'); })
              this.optionChip('纵向', 'v', this.readMode, (): void => { this.selectReadMode('v'); })
              this.optionChip('条漫', 'w', this.readMode, (): void => { this.selectReadMode('w'); })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 14 })
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          Column() {
            this.switchRow('右开本', '仅横向模式生效', this.r2l, (value: boolean): void => {
              this.r2l = value;
              settingsStore.putBool(KEY_R2L, value);
            })
            this.rule()
            this.switchRow('页码角标', '在阅读页显示当前位置', this.showPageNum, (value: boolean): void => {
              this.showPageNum = value;
              settingsStore.putBool(KEY_SHOW_PAGE_NUM, value);
            })
            this.rule()
            this.switchRow('音量键翻页', '阅读器实现后直接生效', this.volTurn, (value: boolean): void => {
              this.volTurn = value;
              settingsStore.putBool(KEY_VOL_TURN, value);
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('03', '收图速度', '网络不稳时可选择更保守的档位')
          Column({ space: 12 }) {
            this.fieldLabel('隐藏页滚动速度', this.sourceProfileLabel())
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.wideOptionChip('保守', 'conservative', this.sourceProfile,
                (): void => { this.selectSourceProfile('conservative'); })
              this.wideOptionChip('普通', 'normal', this.sourceProfile,
                (): void => { this.selectSourceProfile('normal'); })
              this.wideOptionChip('快速', 'fast', this.sourceProfile,
                (): void => { this.selectSourceProfile('fast'); })
              this.wideOptionChip('极速', 'turbo', this.sourceProfile,
                (): void => { this.selectSourceProfile('turbo'); })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('04', '浏览方式', '选择列表与详情的呈现方式')
          Column({ space: 10 }) {
            this.choiceCard('网页版', '保留源站页面与站内功能', 'webview', this.browseSource,
              (): void => { this.selectBrowseSource('webview'); })
            this.choiceCard('原生界面', '直接呈现列表与详情，不进入网页阅读器', 'api', this.browseSource,
              (): void => { this.selectBrowseSource('api'); })
            Text('切换后在下次进入对应页面时生效')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
              .padding({ left: 4, top: 2 })
          }
          .width('100%')

          this.sectionHeader('05', '章节图源', '决定章节图片的获取方式')
          Column({ space: 10 }) {
            this.choiceCard('网页收图', '兼容性较好，部分章节加载较慢', 'webview', this.chapterSource,
              (): void => { this.selectChapterSource('webview'); })
            this.choiceCard('API 取图', '速度更快，依赖官方接口', 'api', this.chapterSource,
              (): void => { this.selectChapterSource('api'); })
          }
          .width('100%')

          this.sectionHeader('06', '章末吐槽', '控制阅读流程中的吐槽页')
          Column() {
            this.switchRow('显示章末吐槽页', '关闭后不在每章末尾追加', this.chapterEndComments, (value: boolean): void => {
              this.chapterEndComments = value;
              settingsStore.putBool(KEY_CHAPTER_END_COMMENTS, value);
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('07', '源站', this.manualMode ? '手动模式' : '自动模式 · 失效或明显过慢才切换')
          Column({ space: 12 }) {
            this.domainLine('WEB', this.webDomain, this.manualMode ? '已锁定' : '自动')
            this.rule()
            this.domainLine('API', this.apiDomain, '自动')
            if (this.probeNote.length > 0) {
              Text(this.probeNote)
                .fontSize(12)
                .lineHeight(18)
                .fontColor($r('app.color.secondary_text'))
                .width('100%')
            }
            Row({ space: 8 }) {
              Button(this.showDomainChoices ? '收起域名' : '手动指定')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.accent_soft'))
                .enabled(!this.probing)
                .onClick(() => {
                  this.showDomainChoices = !this.showDomainChoices;
                })
              Button('恢复自动')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .fontColor($r('app.color.primary_text'))
                .backgroundColor($r('app.color.surface_variant'))
                .enabled(this.manualMode && !this.probing)
                .onClick(() => this.restoreAutomaticDomain())
              Button(this.probing ? '测速中…' : '重新测速')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .fontColor($r('app.color.on_primary'))
                .backgroundColor($r('app.color.primary'))
                .enabled(!this.probing)
                .onClick(() => this.reprobeDomains())
            }
            .width('100%')

            if (this.showDomainChoices) {
              Column({ space: 8 }) {
                ForEach(UrlManager.candidates, (url: string) => {
                  Row({ space: 10 }) {
                    Text(url === this.webDomain ? '●' : '○')
                      .fontSize(15)
                      .fontColor(url === this.webDomain ? $r('app.color.accent') :
                        $r('app.color.secondary_text'))
                    Text(url.replace('https://', ''))
                      .fontSize(14)
                      .fontColor($r('app.color.primary_text'))
                      .layoutWeight(1)
                    Text(url === this.webDomain ? '当前' : '选择')
                      .fontSize(12)
                      .fontColor($r('app.color.secondary_text'))
                  }
                  .width('100%')
                  .height(44)
                  .padding({ left: 12, right: 12 })
                  .borderRadius(12)
                  .backgroundColor($r('app.color.surface_variant'))
                  .onClick(() => this.setManualDomain(url))
                }, (url: string) => url)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('08', '存储', '图片缓存不包含离线下载')
          Column({ space: 12 }) {
            this.fieldLabel('图片缓存上限', this.cacheLimitLabel(this.imageCacheLimitMb))
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.cacheChip(256)
              this.cacheChip(512)
              this.cacheChip(1024)
              this.cacheChip(2048)
              this.cacheChip(0)
            }
            .width('100%')
            this.rule()
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text('清理缓存')
                  .fontSize(15)
                  .fontColor($r('app.color.primary_text'))
                Text(this.cacheNote)
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor($r('app.color.secondary_text'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Button('清理')
                .type(ButtonType.Normal)
                .height(38)
                .fontSize(13)
                .fontColor($r('app.color.primary'))
                .backgroundColor($r('app.color.accent_soft'))
                .onClick(() => {
                  this.cacheNote = '缓存模块尚未接入，未删除任何文件';
                  this.showToast('清理缓存功能建设中');
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)

          this.sectionHeader('09', '调试', '保留数据层联调入口')
          Row({ space: 12 }) {
            Text('⌘')
              .fontSize(20)
              .fontColor($r('app.color.accent'))
              .width(42)
              .height(42)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.accent_soft'))
              .borderRadius(13)
            Column({ space: 3 }) {
              Text('进入原调试页')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary_text'))
              Text('域名、列表、搜索、登录与日志')
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
          .padding(16)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(20)
          .onClick(() => this.onOpenDebug())
          .margin({ bottom: 30 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  private sourceProfileLabel(): string {
    if (this.sourceProfile === 'conservative') {
      return '保守';
    }
    if (this.sourceProfile === 'normal') {
      return '普通';
    }
    if (this.sourceProfile === 'turbo') {
      return '极速';
    }
    return '快速';
  }

  @Builder
  sectionHeader(index: string, title: string, subtitle: string) {
    Row({ space: 10 }) {
      Text(index)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .width(28)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(subtitle)
          .fontSize(11)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 14, bottom: 2 })
  }

  @Builder
  switchRow(title: string, subtitle: string, value: boolean, onChange: (value: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_text'))
        Text(subtitle)
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor($r('app.color.primary'))
        .onChange((checked: boolean) => onChange(checked))
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 14, bottom: 14 })
  }

  @Builder
  rule() {
    Divider()
      .strokeWidth(1)
      .color($r('app.color.divider'))
      .margin({ left: 16, right: 16 })
  }

  @Builder
  fieldLabel(title: string, value: string) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.accent'))
    }
    .width('100%')
  }

  @Builder
  optionChip(label: string, value: string, selected: string, onTap: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(40)
      .fontSize(13)
      .fontWeight(value === selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(value === selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(value === selected ? $r('app.color.primary') : $r('app.color.surface_variant'))
      .borderRadius(12)
      .onClick(() => onTap())
  }

  @Builder
  wideOptionChip(label: string, value: string, selected: string, onTap: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .width('48.5%')
      .height(40)
      .margin({ bottom: 8 })
      .fontSize(13)
      .fontWeight(value === selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(value === selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(value === selected ? $r('app.color.primary') : $r('app.color.surface_variant'))
      .borderRadius(12)
      .onClick(() => onTap())
  }

  @Builder
  choiceCard(title: string, subtitle: string, value: string, selected: string, onTap: () => void) {
    Row({ space: 12 }) {
      Text(value === selected ? '●' : '○')
        .fontSize(18)
        .fontColor(value === selected ? $r('app.color.accent') : $r('app.color.secondary_text'))
      Column({ space: 4 }) {
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
      Text(value === selected ? '已选' : '')
        .fontSize(11)
        .fontColor($r('app.color.accent'))
    }
    .width('100%')
    .padding(15)
    .backgroundColor(value === selected ? $r('app.color.accent_soft') : $r('app.color.surface'))
    .border({ width: 1, color: value === selected ? $r('app.color.accent') : $r('app.color.divider') })
    .borderRadius(18)
    .onClick(() => onTap())
  }

  @Builder
  domainLine(kind: string, domain: string, state: string) {
    Row({ space: 10 }) {
      Text(kind)
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .width(42)
        .height(24)
        .textAlign(TextAlign.Center)
        .backgroundColor(kind === 'WEB' ? $r('app.color.primary') : $r('app.color.accent'))
        .borderRadius(8)
      Text(domain.replace('https://', ''))
        .fontSize(13)
        .fontColor($r('app.color.primary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(state)
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
    }
    .width('100%')
  }

  @Builder
  cacheChip(value: number) {
    Button(this.cacheLimitLabel(value))
      .type(ButtonType.Normal)
      .width(value === 0 ? '100%' : '48.5%')
      .height(38)
      .margin({ bottom: 8 })
      .fontSize(12)
      .fontWeight(value === this.imageCacheLimitMb ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(value === this.imageCacheLimitMb ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(value === this.imageCacheLimitMb ? $r('app.color.primary') :
        $r('app.color.surface_variant'))
      .borderRadius(11)
      .onClick(() => {
        this.imageCacheLimitMb = value;
        settingsStore.putInt(KEY_IMAGE_CACHE_LIMIT_MB, value);
      })
  }
}
