/**
 * 应用设置：所有偏好读写都经 SettingsStore，键名与移植规格 C 保持一致。
 */
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiDomainManager } from '../services/ApiDomainManager';
import { applyStatusBarVisibility } from '../services/SystemBars';
import {
  KEY_AMOLED_BLACK,
  KEY_BROWSE_SOURCE,
  KEY_CHAPTER_END_COMMENTS,
  KEY_CHAPTER_SOURCE,
  KEY_HIDE_STATUS_BAR,
  KEY_IMAGE_CACHE_LIMIT_MB,
  KEY_READ_DIRECTION,
  KEY_READ_MODE,
  KEY_SHOW_PAGE_NUM,
  KEY_SOURCE_PROFILE,
  KEY_THEME_MODE,
  KEY_VOL_TURN,
  settingsStore
} from '../services/SettingsStore';
import { UrlManager } from '../services/UrlManager';
import {
  clearAppCache,
  clearDownloads,
  collectStorageStats,
  formatBytes
} from './CacheTools';
import { KEY_READER_PREFETCH_COUNT, READER_PREFETCH_OPTIONS } from './HiddenCollector';
import {
  applyThemeMode,
  THEME_DARK,
  THEME_LIGHT,
  THEME_SYSTEM,
  themeBackground,
  themeState,
  validThemeMode
} from './ThemeColors';

function abilityContext(): common.UIAbilityContext | undefined {
  return AppStorage.get<common.UIAbilityContext>('abilityContext');
}

@ComponentV2
struct SettingsSectionHeader {
  @Param index: string = '';
  @Param title: string = '';
  @Param subtitle: string = '';

  build() {
    Row({ space: 10 }) {
      Text(this.index)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .width(28)
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Text(this.subtitle)
          .fontSize(11)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 14, bottom: 2 })
  }
}

@ComponentV2
struct SettingsRule {
  build() {
    Divider()
      .strokeWidth(1)
      .color($r('app.color.divider'))
      .margin({ left: 16, right: 16 })
  }
}

@ComponentV2
struct SettingsSwitchRow {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param value: boolean = false;
  @Event onChange: (value: boolean) => void = (_value: boolean) => {};

  build() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_text'))
        Text(this.subtitle)
          .fontSize(12)
          .lineHeight(18)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor($r('app.color.primary'))
        .onChange((checked: boolean) => this.onChange(checked))
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 14, bottom: 14 })
  }
}

@ComponentV2
struct SettingsValueHeader {
  @Param title: string = '';
  @Param value: string = '';

  build() {
    Row() {
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Blank()
      Text(this.value)
        .fontSize(12)
        .fontColor($r('app.color.accent'))
    }
    .width('100%')
  }
}

@ComponentV2
struct SettingsSegmentOption {
  @Param label: string = '';
  @Param value: string = '';
  @Param selected: string = '';
  @Param itemWidth: string = '48.5%';
  @Event onSelect: (value: string) => void = (_value: string) => {};

  build() {
    Button(this.label)
      .type(ButtonType.Normal)
      .width(this.itemWidth)
      .height(40)
      .margin({ bottom: 8 })
      .fontSize(13)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') :
        themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
      .borderRadius(12)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
struct SettingsChoiceOption {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param value: string = '';
  @Param selected: string = '';
  @Event onSelect: (value: string) => void = (_value: string) => {};

  build() {
    Row({ space: 12 }) {
      Text(this.value === this.selected ? '●' : '○')
        .fontSize(18)
        .fontColor(this.value === this.selected ? $r('app.color.accent') : $r('app.color.secondary_text'))
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_text'))
        Text(this.subtitle)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.value === this.selected ? '已选' : '')
        .fontSize(11)
        .fontColor($r('app.color.accent'))
    }
    .width('100%')
    .padding(15)
    .backgroundColor(this.value === this.selected ? $r('app.color.accent_soft') : $r('app.color.surface'))
    .border({
      width: 1,
      color: this.value === this.selected ? $r('app.color.accent') : $r('app.color.divider')
    })
    .borderRadius(18)
    .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
struct SettingsChapterSourceOption {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param value: string = '';
  @Param selected: string = '';
  @Event onSelect: (value: string) => void = (_value: string) => {};

  build() {
    Row({ space: 12 }) {
      Text(this.value === this.selected ? '●' : '○')
        .fontSize(18)
        .fontColor(this.value === this.selected ? $r('app.color.accent') : $r('app.color.secondary_text'))
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_text'))
        Text(this.subtitle)
          .fontSize(12)
          .fontColor($r('app.color.secondary_text'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.value === this.selected ? '已选' : '')
        .fontSize(11)
        .fontColor($r('app.color.accent'))
    }
    .width('100%')
    .padding(15)
    .backgroundColor(this.value === this.selected ? $r('app.color.accent_soft') : $r('app.color.surface'))
    .border({
      width: 1,
      color: this.value === this.selected ? $r('app.color.accent') : $r('app.color.divider')
    })
    .borderRadius(18)
    .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
struct SettingsDomainLine {
  @Param kind: string = '';
  @Param domain: string = '';
  @Param state: string = '';

  build() {
    Row({ space: 10 }) {
      Text(this.kind)
        .fontSize(10)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_primary'))
        .width(42)
        .height(24)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.kind === 'WEB' ? $r('app.color.primary') : $r('app.color.accent'))
        .borderRadius(8)
      Text(this.domain.replace('https://', ''))
        .fontSize(13)
        .fontColor($r('app.color.primary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(this.state)
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
    }
    .width('100%')
  }
}

@ComponentV2
struct SettingsPrefetchOption {
  @Param value: number = 20;
  @Param selected: number = 20;
  @Event onSelect: (value: number) => void = (_value: number) => {};

  build() {
    Button(this.value + ' 页')
      .type(ButtonType.Normal)
      .width('48.5%')
      .height(38)
      .margin({ bottom: 8 })
      .fontSize(12)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') :
        themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
      .borderRadius(11)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
struct SettingsCacheOption {
  @Param value: number = 0;
  @Param selected: number = 1024;
  @Param fullWidth: boolean = false;
  @Event onSelect: (value: number) => void = (_value: number) => {};

  private label(): string {
    return this.value === 0 ? '不限' : this.value + ' MB';
  }

  build() {
    Button(this.label())
      .type(ButtonType.Normal)
      .width(this.fullWidth ? '100%' : '48.5%')
      .height(38)
      .margin({ bottom: 8 })
      .fontSize(12)
      .fontWeight(this.value === this.selected ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.value === this.selected ? $r('app.color.on_primary') : $r('app.color.primary_text'))
      .backgroundColor(this.value === this.selected ? $r('app.color.primary') :
        themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
      .borderRadius(11)
      .onClick(() => this.onSelect(this.value))
  }
}

@ComponentV2
export struct SettingsPage {
  @Event onBack: () => void = () => {};
  @Event onOpenDebug: () => void = () => {};

  @Local loaded: boolean = false;
  @Local themeMode: string = THEME_SYSTEM;
  @Local amoledBlack: boolean = false;
  @Local hideStatusBar: boolean = false;
  @Local readMode: string = 'h';
  /** 阅读方向：'left' = 左开本（默认），'right' = 右开本。仅阅读模式为横向时显示该行。 */
  @Local readDirection: string = 'left';
  @Local showPageNum: boolean = true;
  @Local volTurn: boolean = false;
  @Local sourceProfile: string = 'fast';
  @Local readerPrefetch: number = 20;
  @Local browseSource: string = 'api';
  @Local chapterSource: string = 'api';
  @Local chapterEndComments: boolean = true;
  @Local imageCacheLimitMb: number = 1024;

  @Local webDomain: string = '读取中…';
  @Local apiDomain: string = '尚未测速';
  @Local manualMode: boolean = false;
  @Local showDomainChoices: boolean = false;
  @Local probing: boolean = false;
  @Local probeNote: string = '';
  /** 缓存统计与清理：storageLabel 即行右侧的「已用 X MB」。 */
  @Local storageLabel: string = '统计中…';
  @Local storageSummary: string = '正在统计下载与缓存占用…';
  @Local storagePanelOpen: boolean = false;
  @Local statsBusy: boolean = false;
  @Local clearing: boolean = false;
  @Local storageActionNote: string = '';
  @Local downloadBytes: number = 0;
  @Local cacheBytes: number = 0;
  @Local comicCount: number = 0;
  @Local chapterCount: number = 0;
  @Local pendingChapterCount: number = 0;

  private apiDomains: ApiDomainManager = new ApiDomainManager();

  aboutToAppear(): void {
    this.loadSettings();
    // 统计要递归扫描目录：让首帧先渲染再扫，避免打开设置页时卡一下
    setTimeout(() => this.refreshStorageStats(), 80);
  }

  private async loadSettings(): Promise<void> {
    try {
      // 旧布尔 darkMode 由 themeMode() 内部迁移：true → dark，false/缺失 → system
      this.themeMode = validThemeMode(await settingsStore.themeMode());
      this.amoledBlack = await settingsStore.amoledBlack();
      this.hideStatusBar = await settingsStore.getBool(KEY_HIDE_STATUS_BAR, false);
      this.readMode = this.validReadMode(await settingsStore.getString(KEY_READ_MODE, 'h'));
      this.readDirection = this.validReadDirection(
        await settingsStore.getString(KEY_READ_DIRECTION, 'left'));
      this.showPageNum = await settingsStore.getBool(KEY_SHOW_PAGE_NUM, true);
      this.volTurn = await settingsStore.getBool(KEY_VOL_TURN, false);
      this.sourceProfile = this.validSourceProfile(
        await settingsStore.getString(KEY_SOURCE_PROFILE, 'fast'));
      this.browseSource = this.validBinarySource(
        await settingsStore.getString(KEY_BROWSE_SOURCE, 'api'));
      this.chapterSource = this.validBinarySource(
        await settingsStore.getString(KEY_CHAPTER_SOURCE, 'api'));
      this.readerPrefetch = await settingsStore.getInt(KEY_READER_PREFETCH_COUNT, 20);
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

  /** 阅读方向只认 left / right，其它值（含旧数据缺失）退回默认的左开本。 */
  private validReadDirection(value: string): string {
    return value === 'right' ? 'right' : 'left';
  }

  private validSourceProfile(value: string): string {
    return ['conservative', 'normal', 'fast', 'turbo'].indexOf(value) >= 0 ? value : 'fast';
  }

  private validBinarySource(value: string): string {
    return ['webview', 'api'].indexOf(value) >= 0 ? value : 'api';
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (error) {
    }
  }

  /** 主题模式切换：写库 + 立即应用（setColorMode 走 applyThemeMode，无需重启）。 */
  private async setThemeMode(value: string): Promise<void> {
    this.themeMode = validThemeMode(value);
    await settingsStore.putString(KEY_THEME_MODE, this.themeMode);
    applyThemeMode(this.themeMode, this.amoledBlack);
  }

  /** AMOLED 纯黑：只影响背景类 token，文字/强调色沿用 dark 那套。 */
  private async setAmoledBlack(value: boolean): Promise<void> {
    this.amoledBlack = value;
    await settingsStore.putBool(KEY_AMOLED_BLACK, value);
    applyThemeMode(this.themeMode, value);
  }

  /** 当前是否处于深色（跟随系统档位由 ThemeState 判定）。 */
  private get themeIsDark(): boolean {
    return themeState().isDark;
  }

  private themeModeLabel(): string {
    if (this.themeMode === THEME_DARK) {
      return '深色';
    }
    if (this.themeMode === THEME_LIGHT) {
      return '亮色';
    }
    // 跟随系统：把系统当前实际是亮还是暗一并显示出来，
    // 否则"系统本来就是深色、选跟随系统仍是深色"会被误认为开关没生效
    return themeState().systemDark ? '跟随系统 · 当前深色' : '跟随系统 · 当前亮色';
  }

  private async applyStatusBar(hidden: boolean): Promise<void> {
    const ctx = abilityContext();
    if (ctx === undefined) {
      return;
    }
    try {
      // 与冷启动同一份共享实现（旧整组接口运行中调用会把小白条弄没——本轮实测根因）
      await applyStatusBarVisibility(ctx, hidden);
    } catch (error) {
      const be = error as BusinessError;
      this.showToast('状态栏设置失败：' + be.message);
    }
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

  /** 阅读方向（左开本/右开本）：写库即生效，阅读器读到后立刻换 Swiper 的 RTL 与点击分区。 */
  private async selectReadDirection(value: string): Promise<void> {
    this.readDirection = this.validReadDirection(value);
    await settingsStore.putString(KEY_READ_DIRECTION, this.readDirection);
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

  private async selectReaderPrefetch(value: number): Promise<void> {
    this.readerPrefetch = value;
    await settingsStore.putInt(KEY_READER_PREFETCH_COUNT, value);
  }

  private async selectCacheLimit(value: number): Promise<void> {
    this.imageCacheLimitMb = value;
    await settingsStore.putInt(KEY_IMAGE_CACHE_LIMIT_MB, value);
  }

  /** 只读统计：下载占用复用 DownloadStore 的目录信息，缓存占用来自 context.cacheDir。 */
  private async refreshStorageStats(): Promise<void> {
    if (this.statsBusy || this.clearing) {
      return;
    }
    this.statsBusy = true;
    try {
      const stats = await collectStorageStats();
      this.downloadBytes = stats.downloadBytes;
      this.cacheBytes = stats.cacheBytes;
      this.comicCount = stats.comicCount;
      this.chapterCount = stats.chapterCount;
      this.pendingChapterCount = stats.pendingChapterCount;
      if (stats.ready) {
        this.storageLabel = '已用 ' + formatBytes(stats.downloadBytes + stats.cacheBytes);
        let summary = '离线下载 ' + formatBytes(stats.downloadBytes) +
          ' · 应用缓存 ' + formatBytes(stats.cacheBytes);
        if (stats.pendingChapterCount > 0) {
          summary += ' · ' + stats.pendingChapterCount + ' 章未完成将保留';
        }
        this.storageSummary = summary;
      } else {
        this.storageLabel = '统计失败';
        this.storageSummary = stats.errorText;
      }
    } catch (error) {
      this.storageLabel = '统计失败';
      this.storageSummary = '统计失败，请稍后重试';
    } finally {
      this.statsBusy = false;
    }
  }

  private toggleStoragePanel(): void {
    if (this.clearing) {
      return;
    }
    this.storagePanelOpen = !this.storagePanelOpen;
    if (this.storagePanelOpen) {
      this.refreshStorageStats();
    } else {
      this.storageActionNote = '';
    }
  }

  /**
   * 二段式确认的第一段：点选项按钮 → 系统弹窗二次确认。
   * 取消、点遮罩、弹窗异常都当作「未确认」，不执行任何删除。
   */
  private async confirmStorageAction(downloads: boolean): Promise<void> {
    if (this.clearing || this.statsBusy) {
      return;
    }
    let message = '';
    if (downloads) {
      message = '将删除全部已下载完成的章节（约 ' + formatBytes(this.downloadBytes) +
        '，共 ' + this.chapterCount + ' 章），删除后不可恢复。';
      if (this.pendingChapterCount > 0) {
        message += '进行中/未完成的 ' + this.pendingChapterCount + ' 章会保留。';
      }
    } else {
      message = '将清理约 ' + formatBytes(this.cacheBytes) +
        ' 应用缓存（含 ArkWeb 网页缓存），只影响可重新下载的数据，不影响离线下载与设置。';
    }
    try {
      const response = await this.getUIContext().getPromptAction().showDialog({
        title: downloads ? '清空离线下载？' : '清理应用缓存？',
        message: message,
        buttons: [
          { text: '取消', color: $r('app.color.secondary_text') },
          { text: downloads ? '确认清空' : '确认清理', color: $r('app.color.accent') }
        ],
        backgroundColor: themeBackground('surface', themeState().amoledActive, themeState().themeRevision),
        backgroundBlurStyle: BlurStyle.NONE
      });
      if (response.index !== 1) {
        this.storageActionNote = '已取消，未删除任何文件';
        return;
      }
    } catch (error) {
      this.storageActionNote = '确认弹窗不可用，未执行清理';
      return;
    }
    if (downloads) {
      await this.runClearDownloads();
    } else {
      await this.runClearCache();
    }
  }

  private async runClearCache(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    this.storageActionNote = '正在清理应用缓存…';
    try {
      const result = await clearAppCache();
      this.storageActionNote = result.note;
      this.showToast(result.ok ? '已清理应用缓存' : '清理未完成');
    } catch (error) {
      this.storageActionNote = '清理失败：未知错误';
      this.showToast('清理缓存失败');
    } finally {
      this.clearing = false;
      await this.refreshStorageStats();
    }
  }

  private async runClearDownloads(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    this.storageActionNote = '正在清理离线下载…';
    try {
      const result = await clearDownloads();
      this.storageActionNote = result.note;
      this.showToast(result.ok ? '已清理离线下载' : '清理未完成');
    } catch (error) {
      this.storageActionNote = '清理失败：未知错误';
      this.showToast('清理离线下载失败');
    } finally {
      this.clearing = false;
      await this.refreshStorageStats();
    }
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

  build() {
    Column() {
      Row({ space: 10 }) {
        Button('‹')
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .fontSize(28)
          .fontColor($r('app.color.primary_text'))
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
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
          SettingsSectionHeader({ index: '01', title: '外观', subtitle: '主题与系统界面' })
          Column({ space: 12 }) {
            SettingsValueHeader({
              title: '主题模式',
              value: this.themeModeLabel()
            })
            Text('跟随系统 / 亮色 / 深色，切换后立即生效，无需重启')
              .fontSize(11)
              .lineHeight(16)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              SettingsSegmentOption({
                label: '跟随系统', value: THEME_SYSTEM, selected: this.themeMode, itemWidth: '31.5%',
                onSelect: (value: string): void => {
                  this.setThemeMode(value);
                }
              })
              SettingsSegmentOption({
                label: '亮色', value: THEME_LIGHT, selected: this.themeMode, itemWidth: '31.5%',
                onSelect: (value: string): void => {
                  this.setThemeMode(value);
                }
              })
              SettingsSegmentOption({
                label: '深色', value: THEME_DARK, selected: this.themeMode, itemWidth: '31.5%',
                onSelect: (value: string): void => {
                  this.setThemeMode(value);
                }
              })
            }
            .width('100%')

            // AMOLED 只在深色下有意义：亮色/跟随系统(亮)时隐藏，避免误导
            if (this.themeIsDark) {
              SettingsRule()
              SettingsSwitchRow({
                title: 'AMOLED 纯黑',
                subtitle: '深色下把背景改为纯黑，更省电',
                value: this.amoledBlack,
                onChange: (value: boolean): void => {
                  this.setAmoledBlack(value);
                }
              })
            }
          }
          .width('100%')
          .padding(15)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          Column() {
            SettingsSwitchRow({
              title: '隐藏状态栏',
              subtitle: '立即应用，导航栏保持可用',
              value: this.hideStatusBar,
              onChange: (value: boolean): void => {
                this.setHideStatusBar(value);
              }
            })
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({ index: '02', title: '阅读', subtitle: '阅读器接入后沿用这些偏好' })
          Column({ space: 12 }) {
            SettingsValueHeader({
              title: '阅读模式',
              value: this.readMode === 'h' ? '横向' : this.readMode === 'v' ? '纵向' : '条漫'
            })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              SettingsSegmentOption({
                label: '横向', value: 'h', selected: this.readMode, itemWidth: '31.5%',
                onSelect: (value: string): void => { this.selectReadMode(value); }
              })
              SettingsSegmentOption({
                label: '纵向', value: 'v', selected: this.readMode, itemWidth: '31.5%',
                onSelect: (value: string): void => { this.selectReadMode(value); }
              })
              SettingsSegmentOption({
                label: '条漫', value: 'w', selected: this.readMode, itemWidth: '31.5%',
                onSelect: (value: string): void => { this.selectReadMode(value); }
              })
            }
            .width('100%')
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          // 阅读方向：只在「横向翻页」下有意义，其它模式整行隐藏（不占位、不误导）。
          if (this.readMode === 'h') {
            Column({ space: 12 }) {
              SettingsValueHeader({
                title: '阅读方向',
                value: this.readDirection === 'left' ? '左开本' : '右开本'
              })
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                SettingsSegmentOption({
                  label: '左开本', value: 'left', selected: this.readDirection, itemWidth: '48.5%',
                  onSelect: (value: string): void => { this.selectReadDirection(value); }
                })
                SettingsSegmentOption({
                  label: '右开本', value: 'right', selected: this.readDirection, itemWidth: '48.5%',
                  onSelect: (value: string): void => { this.selectReadDirection(value); }
                })
              }
              .width('100%')
              Text('左开本：点左半边、向右划 = 下一页（翻页动画一并镜像）；右开本相反。纵向与条漫不受影响。')
                .fontSize(11)
                .lineHeight(17)
                .fontColor($r('app.color.secondary_text'))
                .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 14 })
            .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
            .borderRadius(20)
          }

          Column({ space: 12 }) {
            SettingsValueHeader({
              title: '进入阅读器前预载页数',
              value: this.readerPrefetch + ' 页'
            })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              ForEach(READER_PREFETCH_OPTIONS, (value: number) => {
                SettingsPrefetchOption({
                  value: value,
                  selected: this.readerPrefetch,
                  onSelect: (selected: number): void => { this.selectReaderPrefetch(selected); }
                })
              }, (value: number) => value.toString())
            }
            .width('100%')
            Text('只影响「网页收图」何时进入阅读器：收集到该页数就先进去，之后继续加载；API 取图不受影响。')
              .fontSize(11)
              .lineHeight(17)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 14 })
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          Column() {
            SettingsSwitchRow({
              title: '页码角标',
              subtitle: '在阅读页显示当前位置',
              value: this.showPageNum,
              onChange: (value: boolean): void => {
                this.showPageNum = value;
                settingsStore.putBool(KEY_SHOW_PAGE_NUM, value);
              }
            })
            SettingsRule()
            SettingsSwitchRow({
              title: '音量键翻页',
              subtitle: '音量 +/− 键翻页',
              value: this.volTurn,
              onChange: (value: boolean): void => {
                this.volTurn = value;
                settingsStore.putBool(KEY_VOL_TURN, value);
              }
            })
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({ index: '03', title: '收图速度', subtitle: '网络不稳时可选择更保守的档位' })
          Column({ space: 12 }) {
            SettingsValueHeader({
              title: '隐藏页滚动速度',
              value: this.sourceProfile === 'conservative' ? '保守' :
                this.sourceProfile === 'normal' ? '普通' : this.sourceProfile === 'turbo' ? '极速' : '快速'
            })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              SettingsSegmentOption({
                label: '保守', value: 'conservative', selected: this.sourceProfile,
                onSelect: (value: string): void => { this.selectSourceProfile(value); }
              })
              SettingsSegmentOption({
                label: '普通', value: 'normal', selected: this.sourceProfile,
                onSelect: (value: string): void => { this.selectSourceProfile(value); }
              })
              SettingsSegmentOption({
                label: '快速', value: 'fast', selected: this.sourceProfile,
                onSelect: (value: string): void => { this.selectSourceProfile(value); }
              })
              SettingsSegmentOption({
                label: '极速', value: 'turbo', selected: this.sourceProfile,
                onSelect: (value: string): void => { this.selectSourceProfile(value); }
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({ index: '04', title: '浏览方式', subtitle: '选择列表与详情的呈现方式' })
          Column({ space: 10 }) {
            SettingsChoiceOption({
              title: '网页版',
              subtitle: '保留源站页面与站内功能',
              value: 'webview',
              selected: this.browseSource,
              onSelect: (value: string): void => { this.selectBrowseSource(value); }
            })
            SettingsChoiceOption({
              title: '原生界面',
              subtitle: '直接呈现列表与详情，不进入网页阅读器',
              value: 'api',
              selected: this.browseSource,
              onSelect: (value: string): void => { this.selectBrowseSource(value); }
            })
            Text('切换后在下次进入对应页面时生效')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
              .padding({ left: 4, top: 2 })
          }
          .width('100%')

          SettingsSectionHeader({ index: '05', title: '章节图源', subtitle: '决定章节图片的获取方式' })
          Column({ space: 10 }) {
            SettingsChoiceOption({
              title: '网页收图',
              subtitle: '模拟浏览器滚动收集，较慢但兜底',
              value: 'webview',
              selected: this.chapterSource,
              onSelect: (value: string): void => { this.selectChapterSource(value); }
            })
            SettingsChoiceOption({
              title: 'API 取图',
              subtitle: '依赖官方接口，可拿全章',
              value: 'api',
              selected: this.chapterSource,
              onSelect: (value: string): void => { this.selectChapterSource(value); }
            })
          }
          .width('100%')

          SettingsSectionHeader({ index: '06', title: '章末吐槽', subtitle: '控制阅读流程中的吐槽页' })
          Column() {
            SettingsSwitchRow({
              title: '显示章末吐槽页',
              subtitle: '关闭后不在每章末尾追加',
              value: this.chapterEndComments,
              onChange: (value: boolean): void => {
                this.chapterEndComments = value;
                settingsStore.putBool(KEY_CHAPTER_END_COMMENTS, value);
              }
            })
          }
          .width('100%')
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({
            index: '07',
            title: '源站',
            subtitle: this.manualMode ? '手动模式' : '自动模式 · 失效或明显过慢才切换'
          })
          Column({ space: 12 }) {
            SettingsDomainLine({
              kind: 'WEB',
              domain: this.webDomain,
              state: this.manualMode ? '已锁定' : '自动'
            })
            SettingsRule()
            SettingsDomainLine({ kind: 'API', domain: this.apiDomain, state: '自动' })
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
                .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
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
                  .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
                  .onClick(() => this.setManualDomain(url))
                }, (url: string) => url)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({ index: '08', title: '存储', subtitle: '图片缓存不包含离线下载' })
          Column({ space: 12 }) {
            SettingsValueHeader({
              title: '图片缓存上限',
              value: this.imageCacheLimitMb === 0 ? '不限' : this.imageCacheLimitMb + ' MB'
            })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              SettingsCacheOption({
                value: 256, selected: this.imageCacheLimitMb,
                onSelect: (value: number): void => { this.selectCacheLimit(value); }
              })
              SettingsCacheOption({
                value: 512, selected: this.imageCacheLimitMb,
                onSelect: (value: number): void => { this.selectCacheLimit(value); }
              })
              SettingsCacheOption({
                value: 1024, selected: this.imageCacheLimitMb,
                onSelect: (value: number): void => { this.selectCacheLimit(value); }
              })
              SettingsCacheOption({
                value: 2048, selected: this.imageCacheLimitMb,
                onSelect: (value: number): void => { this.selectCacheLimit(value); }
              })
              SettingsCacheOption({
                value: 0, selected: this.imageCacheLimitMb, fullWidth: true,
                onSelect: (value: number): void => { this.selectCacheLimit(value); }
              })
            }
            .width('100%')
            SettingsRule()
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Row() {
                  Text('缓存统计与清理')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.primary_text'))
                  Blank()
                  Text(this.storageLabel)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.accent'))
                }
                .width('100%')
                Text(this.storageSummary)
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor($r('app.color.secondary_text'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(this.storagePanelOpen ? '收起' : '清理')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary'))
                .padding({ left: 13, right: 13, top: 9, bottom: 9 })
                .backgroundColor($r('app.color.accent_soft'))
                .borderRadius(10)
            }
            .width('100%')
            .onClick(() => this.toggleStoragePanel())

            if (this.storagePanelOpen) {
              SettingsRule()
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Row() {
                    Text('应用缓存（含 ArkWeb）')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.primary_text'))
                    Blank()
                    Text(formatBytes(this.cacheBytes))
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.accent'))
                  }
                  .width('100%')
                  Text('网页缓存等运行时数据，可重新下载；不含离线下载')
                    .fontSize(11)
                    .lineHeight(16)
                    .fontColor($r('app.color.secondary_text'))
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button('清理缓存')
                  .type(ButtonType.Normal)
                  .height(34)
                  .fontSize(12)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.accent_soft'))
                  .borderRadius(10)
                  .enabled(!this.clearing)
                  .onClick(() => {
                    this.confirmStorageAction(false);
                  })
              }
              .width('100%')
              .padding({ top: 12, bottom: 6 })

              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Row() {
                    Text('离线下载')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.primary_text'))
                    Blank()
                    Text(formatBytes(this.downloadBytes))
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.accent'))
                  }
                  .width('100%')
                  Text(this.chapterCount > 0 ?
                    this.comicCount + ' 部 / ' + this.chapterCount + ' 章' +
                    (this.pendingChapterCount > 0 ?
                      '；' + this.pendingChapterCount + ' 章进行中或未完成会保留' : '') :
                    '暂无离线下载')
                    .fontSize(11)
                    .lineHeight(16)
                    .fontColor($r('app.color.secondary_text'))
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button('清空下载')
                  .type(ButtonType.Normal)
                  .height(34)
                  .fontSize(12)
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor($r('app.color.accent'))
                  .borderRadius(10)
                  .enabled(!this.clearing)
                  .onClick(() => {
                    this.confirmStorageAction(true);
                  })
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })

              if (this.storageActionNote.length > 0) {
                Text(this.storageActionNote)
                  .fontSize(11)
                  .lineHeight(16)
                  .fontColor($r('app.color.secondary_text'))
                  .width('100%')
                  .padding({ top: 4 })
              }
              Text('两项清理都要在弹窗里再确认一次；「清空下载」只会删除已下载完成的章节。')
                .fontSize(11)
                .lineHeight(16)
                .fontColor($r('app.color.secondary_text'))
                .width('100%')
                .padding({ top: 4 })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)

          SettingsSectionHeader({ index: '09', title: '调试', subtitle: '保留数据层联调入口' })
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
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
          .borderRadius(20)
          .onClick(() => this.onOpenDebug())
          .margin({ bottom: 30 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
  }
}
