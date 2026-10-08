import { COLLECTOR_LOG_ENABLED } from '../services/Log';
/**
 * 数据层调试页。
 * 保留 P1 的域名探测、热门、最新、搜索、登录与日志能力，统一使用状态管理 V2。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MangaSummary } from '../model/Models';
import { ApiDomainManager } from '../services/ApiDomainManager';
import { ApiClient, ApiException } from '../services/ApiClient';
import { CopyApiSource } from '../services/CopyApiSource';
import { UrlManager } from '../services/UrlManager';
import { authStore } from '../services/AuthStore';
import { themeBackground, themeState } from './ThemeColors';

const DOMAIN: number = 0x0000;
const TAG: string = 'DebugPage';

@ComponentV2
export struct DebugPage {
  @Event onBack: () => void = () => {};

  @Local logText: string = '调试页就绪';
  @Local apiDomainText: string = '（未探测）';
  @Local webDomainText: string = '（未探测）';
  @Local popularText: string = '（未加载）';
  @Local latestText: string = '（未加载）';
  @Local searchInput: string = '';
  @Local searchText: string = '（未搜索）';
  @Local userInput: string = '';
  @Local passInput: string = '';
  @Local loginText: string = '（未登录）';
  @Local busy: boolean = false;

  private domains: ApiDomainManager = new ApiDomainManager();
  private client: ApiClient = new ApiClient(this.domains);
  private source: CopyApiSource = new CopyApiSource(this.client);

  private appendLog(line: string): void {
    const stamp = new Date().toISOString().substring(11, 23);
    this.logText = '[' + stamp + '] ' + line + '\n' + this.logText;
    if (COLLECTOR_LOG_ENABLED) {
      hilog.info(DOMAIN, TAG, line);
    }
  }

  private describeError(error: Object): string {
    if (error instanceof ApiException) {
      const e = error as ApiException;
      return 'code=' + e.code + ' message=' + e.message;
    }
    const be = error as BusinessError<string>;
    const msg = be.message !== undefined ? be.message : String(error);
    const code = be.code !== undefined ? String(be.code) : '?';
    return 'code=' + code + ' message=' + msg;
  }

  private async probeDomains(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      this.appendLog('network4 引导…');
      const seeded = await this.domains.bootstrapFromNetwork4('https://api.copy202601.com');
      if (seeded.length > 0) {
        this.appendLog('network4 → ' + seeded);
      } else {
        this.appendLog('network4 无结果，使用候选列表');
      }
      const api = await this.domains.probeBest();
      this.apiDomainText = api;
      this.appendLog('API 域选定：' + api);

      const cached = await UrlManager.bootstrap();
      this.appendLog(cached ? 'Web 域有缓存：' + UrlManager.activeUrl : 'Web 域无缓存，开始测速');
      const web = await UrlManager.probe();
      this.webDomainText = web;
      this.appendLog('Web 域：' + web + '；' + UrlManager.lastProbeNote);

      await authStore.load();
      if (authStore.hasSavedSession()) {
        this.client.restoreCookies(new Map<string, string>(authStore.getCookieEntries().map(
          (e: CookieEntryLite) => [e.key, e.value] as [string, string])));
        if (authStore.getToken().length > 0) {
          this.client.setToken(authStore.getToken());
        }
        this.appendLog('已恢复登录态（token=' + (authStore.getToken().length > 0 ? '有' : '无') +
          '，cookies=' + authStore.getCookieEntries().length + '条）');
      }
    } catch (error) {
      this.appendLog('探测失败：' + this.describeError(error as Object));
    } finally {
      this.busy = false;
    }
  }

  private async loadPopular(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const list = await this.source.popular(0);
      this.popularText = this.describeList(list);
      this.appendLog('热门：' + list.length + ' 条');
    } catch (error) {
      const desc = this.describeError(error as Object);
      this.popularText = '失败：' + desc;
      this.appendLog('热门失败：' + desc);
    } finally {
      this.busy = false;
    }
  }

  private async loadLatest(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const list = await this.source.latest(0);
      this.latestText = this.describeList(list);
      this.appendLog('最新：' + list.length + ' 条');
    } catch (error) {
      const desc = this.describeError(error as Object);
      this.latestText = '失败：' + desc;
      this.appendLog('最新失败：' + desc);
    } finally {
      this.busy = false;
    }
  }

  private async doSearch(): Promise<void> {
    if (this.busy || this.searchInput.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const list = await this.source.search(this.searchInput, 0);
      this.searchText = this.describeList(list);
      this.appendLog('搜索「' + this.searchInput + '」：' + list.length + ' 条');
    } catch (error) {
      const desc = this.describeError(error as Object);
      this.searchText = '失败：' + desc;
      this.appendLog('搜索失败：' + desc);
    } finally {
      this.busy = false;
    }
  }

  private async doLogin(): Promise<void> {
    if (this.busy || this.userInput.length === 0 || this.passInput.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const ok = await this.source.login(this.userInput, this.passInput);
      this.loginText = ok ? '登录成功（token=' + (this.client.hasSession() ? '有会话' : '无') + '）' : '登录返回 false';
      this.appendLog('登录：' + this.loginText);
    } catch (error) {
      const desc = this.describeError(error as Object);
      this.loginText = '失败：' + desc;
      this.appendLog('登录失败：' + desc);
    } finally {
      this.busy = false;
    }
  }

  private describeList(list: MangaSummary[]): string {
    if (list.length === 0) {
      return '0 条';
    }
    const head: string[] = [];
    for (let i = 0; i < Math.min(3, list.length); i++) {
      head.push(list[i].title + '（' + list[i].author + '）');
    }
    return list.length + ' 条：' + head.join('、');
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
          Text('数据层调试')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text('接口响应与原始错误信息')
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          this.sectionCard('域名探测', this.apiDomainText + '\nWeb: ' + this.webDomainText,
            this.busy ? '探测中…' : '探测域名', (): void => {
              this.probeDomains();
            })

          this.sectionCard('热门（第一页）', this.popularText, '拉取热门', (): void => {
            this.loadPopular();
          })

          this.sectionCard('最新（第一页）', this.latestText, '拉取最新', (): void => {
            this.loadLatest();
          })

          Column({ space: 8 }) {
            Text('搜索').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary_text'))
            Row({ space: 8 }) {
              TextInput({ text: this.searchInput, placeholder: '输入关键词' })
                .layoutWeight(1)
                .height(42)
                .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
                .onChange((value: string) => {
                  this.searchInput = value;
                })
              Button('搜索')
                .height(42)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.on_primary'))
                .onClick(() => this.doSearch())
            }
            Text(this.searchText).fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(18)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))

          Column({ space: 8 }) {
            Text('登录').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary_text'))
            TextInput({ text: this.userInput, placeholder: '账号' })
              .width('100%')
              .height(42)
              .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
              .onChange((value: string) => {
                this.userInput = value;
              })
            TextInput({ text: this.passInput, placeholder: '密码' })
              .type(InputType.Password)
              .width('100%')
              .height(42)
              .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
              .onChange((value: string) => {
                this.passInput = value;
              })
            Button('登录')
              .width('100%')
              .height(42)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.on_primary'))
              .onClick(() => this.doLogin())
            Text(this.loginText).fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(18)
          .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))

          Column({ space: 8 }) {
            Row() {
              Text('日志')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary_text'))
              Blank()
              Text('最新在前')
                .fontSize(11)
                .fontColor($r('app.color.secondary_text'))
            }
            .width('100%')
            Text(this.logText)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor($r('app.color.primary_text'))
              .lineHeight(18)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .borderRadius(18)
          .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
          .margin({ bottom: 28 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
  }

  @Builder
  sectionCard(title: string, content: string, buttonLabel: string, onTap: () => void) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary_text'))
      Text(content)
        .fontSize(13)
        .lineHeight(19)
        .fontColor($r('app.color.secondary_text'))
      Button(buttonLabel)
        .width('100%')
        .height(40)
        .enabled(!this.busy)
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.on_primary'))
        .onClick(() => onTap())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .borderRadius(18)
    .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
  }
}

/** 登录态 Cookie 条目（与 AuthStore 共用）。 */
export interface CookieEntryLite {
  key: string;
  value: string;
}
