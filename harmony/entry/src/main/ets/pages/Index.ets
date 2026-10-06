/**
 * Index.ets — 调试页（P1 验收用）。
 * 真机验证：域名探测、热门/最新列表、搜索、登录（原始错误码）、可滚动日志。
 * 工程约定：V1 装饰器；全局上下文经 AppStorage（'abilityContext'）。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MangaSummary } from '../model/Models';
import { ApiDomainManager } from '../services/ApiDomainManager';
import { ApiClient, ApiException } from '../services/ApiClient';
import { CopyApiSource } from '../services/CopyApiSource';
import { UrlManager } from '../services/UrlManager';
import { authStore } from '../services/AuthStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'DebugPage';

@Entry
@Component
struct Index {
  @State logText: string = '调试页就绪';
  @State apiDomainText: string = '（未探测）';
  @State webDomainText: string = '（未探测）';
  @State popularText: string = '（未加载）';
  @State latestText: string = '（未加载）';
  @State searchInput: string = '';
  @State searchText: string = '（未搜索）';
  @State userInput: string = '';
  @State passInput: string = '';
  @State loginText: string = '（未登录）';
  @State busy: boolean = false;

  private domains: ApiDomainManager = new ApiDomainManager();
  private client: ApiClient = new ApiClient(this.domains);
  private source: CopyApiSource = new CopyApiSource(this.client);

  private appendLog(line: string): void {
    const stamp = new Date().toISOString().substring(11, 23);
    this.logText = '[' + stamp + '] ' + line + '\n' + this.logText;
    hilog.info(DOMAIN, TAG, line);
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

      // 恢复登录态
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
      Text('MangaCopyOHOS 调试页')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 10 }) {
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

          Column({ space: 6 }) {
            Text('搜索').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 8 }) {
              TextInput({ text: this.searchInput, placeholder: '输入关键词' })
                .layoutWeight(1)
                .onChange((value: string) => {
                  this.searchInput = value;
                })
              Button('搜索').onClick(() => {
                this.doSearch();
              })
            }
            Text(this.searchText).fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(8)
          .backgroundColor($r('app.color.surface'))

          Column({ space: 6 }) {
            Text('登录').fontSize(15).fontWeight(FontWeight.Medium)
            TextInput({ text: this.userInput, placeholder: '账号' })
              .width('100%')
              .onChange((value: string) => {
                this.userInput = value;
              })
            TextInput({ text: this.passInput, placeholder: '密码' })
              .type(InputType.Password)
              .width('100%')
              .onChange((value: string) => {
                this.passInput = value;
              })
            Button('登录').width('100%').onClick(() => {
              this.doLogin();
            })
            Text(this.loginText).fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(8)
          .backgroundColor($r('app.color.surface'))

          Column({ space: 6 }) {
            Text('日志').fontSize(15).fontWeight(FontWeight.Medium)
            Text(this.logText)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor($r('app.color.primary_text'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(8)
          .backgroundColor($r('app.color.surface_variant'))
          .margin({ bottom: 24 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .padding({ left: 12, right: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  @Builder
  sectionCard(title: string, content: string, buttonLabel: string, onTap: () => void) {
    Column({ space: 6 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium)
      Text(content).fontSize(13).fontColor($r('app.color.secondary_text'))
      Button(buttonLabel).width('100%').onClick(() => onTap())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor($r('app.color.surface'))
  }
}

/** 登录态 Cookie 条目（与 AuthStore 共用）。 */
export interface CookieEntryLite {
  key: string;
  value: string;
}
