/** 原生账号页：登录、会话状态与退出。 */
import { ApiException } from '../services/ApiClient';
import {
  browseSession,
  BrowseSessionState,
  clearBrowseSession,
  getBrowseSource,
  reloadBrowseSession,
  syncBrowseSession
} from './BrowseSupport';
import { themeBackground, themeState } from './ThemeColors';

@ComponentV2
export struct AccountPage {
  @Event onBack: () => void = () => {};
  @Event onOpenFavorites: () => void = () => {};
  @Event onOpenHistory: () => void = () => {};

  @Local session: BrowseSessionState = browseSession;
  @Local username: string = '';
  @Local password: string = '';
  @Local busy: boolean = false;
  @Local errorText: string = '';

  aboutToAppear(): void {
    this.prepareSession();
  }

  private async prepareSession(): Promise<void> {
    try {
      await getBrowseSource();
      await reloadBrowseSession();
    } catch (error) {
      this.errorText = '会话读取失败：' + this.describeLoginError(error as Object);
    }
  }

  private describeLoginError(error: Object): string {
    if (error instanceof ApiException) {
      const apiError = error as ApiException;
      return apiError.code + ' ' + (apiError.message.length > 0 ? apiError.message : '接口未返回错误说明');
    }
    const commonError = error as Error;
    return commonError.message !== undefined && commonError.message.length > 0 ?
      commonError.message : '网络请求失败';
  }

  private async login(): Promise<void> {
    const user = this.username.trim();
    if (user.length === 0 || this.password.length === 0 || this.busy) {
      if (user.length === 0 || this.password.length === 0) {
        this.errorText = '请填写账号和密码';
      }
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const source = await getBrowseSource();
      const ok = await source.login(user, this.password);
      if (!ok) {
        this.errorText = '登录未成功，接口返回 false';
        return;
      }
      syncBrowseSession(user);
      if (!this.session.hasToken) {
        this.errorText = '登录响应未包含 token，暂不能读取收藏和历史';
        return;
      }
      this.password = '';
      this.showToast('登录成功');
    } catch (error) {
      this.errorText = this.describeLoginError(error as Object);
    } finally {
      this.busy = false;
    }
  }

  private async logout(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      await clearBrowseSession();
      this.password = '';
      this.showToast('已退出登录');
    } catch (error) {
      this.errorText = '退出失败：' + this.describeLoginError(error as Object);
    } finally {
      this.busy = false;
    }
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
        .backgroundColor(themeBackground('surface_variant', themeState().amoledActive, themeState().themeRevision))
        .onClick(() => this.onBack())
        Column({ space: 2 }) {
          Text('账号')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text(this.session.loggedIn ? '会话已连接' : '登录后同步收藏与历史')
            .fontSize(12)
            .fontColor($r('app.color.secondary_text'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          if (!this.session.ready) {
            Column({ space: 12 }) {
              LoadingProgress()
                .width(34)
                .height(34)
                .color($r('app.color.primary'))
              Text('正在读取登录状态…')
                .fontSize(13)
                .fontColor($r('app.color.secondary_text'))
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .height(220)
          } else if (!this.session.loggedIn) {
            Column({ space: 16 }) {
              Column({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
                  .fontSize(46)
                  .fontColor([$r('app.color.primary')])
                Text('登录拷贝漫画账号')
                  .fontSize(21)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.primary_text'))
                Text('登录后可读取服务端收藏和浏览历史')
                  .fontSize(13)
                  .fontColor($r('app.color.secondary_text'))
              }
              .width('100%')

              Column({ space: 10 }) {
                TextInput({ text: this.username, placeholder: '账号' })
                  .width('100%')
                  .height(46)
                  .fontColor($r('app.color.primary_text'))
                  .placeholderColor($r('app.color.secondary_text'))
                  .caretColor($r('app.color.primary'))
                  .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.username = value;
                  })
                TextInput({ text: this.password, placeholder: '密码' })
                  .type(InputType.Password)
                  .width('100%')
                  .height(46)
                  .fontColor($r('app.color.primary_text'))
                  .placeholderColor($r('app.color.secondary_text'))
                  .caretColor($r('app.color.primary'))
                  .backgroundColor(themeBackground('field_background', themeState().amoledActive, themeState().themeRevision))
                  .borderRadius(14)
                  .onChange((value: string) => {
                    this.password = value;
                  })
                Button(this.busy ? '正在登录…' : '登录')
                  .type(ButtonType.Normal)
                  .width('100%')
                  .height(46)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.on_primary'))
                  .backgroundColor($r('app.color.primary'))
                  .borderRadius(14)
                  .enabled(!this.busy && this.username.trim().length > 0 && this.password.length > 0)
                  .onClick(() => this.login())
              }
              .width('100%')

              if (this.errorText.length > 0) {
                Row({ space: 8 }) {
                  SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                    .fontSize(18)
                    .fontColor([$r('app.color.accent')])
                  Text(this.errorText)
                    .fontSize(13)
                    .lineHeight(19)
                    .fontColor($r('app.color.accent'))
                    .layoutWeight(1)
                }
                .width('100%')
                .padding(12)
                .backgroundColor($r('app.color.accent_soft'))
                .borderRadius(13)
              }
            }
            .width('100%')
            .padding(20)
            .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
            .borderRadius(24)
          } else {
            Column({ space: 18 }) {
              Row({ space: 14 }) {
                SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
                  .fontSize(40)
                  .fontColor([$r('app.color.on_primary')])
                  .width(58)
                  .height(58)
                Column({ space: 5 }) {
                  Text(this.session.username.length > 0 ? this.session.username : '已登录账号')
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.on_primary'))
                  Text(this.session.hasToken ? 'Token 已保存' : 'Cookie 会话已保存')
                    .fontSize(12)
                    .fontColor($r('app.color.hero_secondary'))
                  Text('Cookie ' + this.session.cookieCount + ' 条')
                    .fontSize(11)
                    .fontColor($r('app.color.hero_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')

              Row({ space: 10 }) {
                Button('查看收藏')
                  .type(ButtonType.Normal)
                  .layoutWeight(1)
                  .height(42)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.on_primary'))
                  .borderRadius(14)
                  .onClick(() => this.onOpenFavorites())
                Button('查看历史')
                  .type(ButtonType.Normal)
                  .layoutWeight(1)
                  .height(42)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.on_primary'))
                  .borderRadius(14)
                  .onClick(() => this.onOpenHistory())
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(20)
            .backgroundColor($r('app.color.primary'))
            .borderRadius(24)

            Column({ space: 10 }) {
              Text('会话信息')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_text'))
              Text('登录状态保存在本机。退出后会同时清除 Token 与 Cookie，收藏和历史页将恢复为未登录状态。')
                .fontSize(13)
                .lineHeight(20)
                .fontColor($r('app.color.secondary_text'))
              Button(this.busy ? '正在退出…' : '退出登录')
                .type(ButtonType.Normal)
                .width('100%')
                .height(42)
                .fontColor($r('app.color.accent'))
                .backgroundColor($r('app.color.accent_soft'))
                .borderRadius(14)
                .enabled(!this.busy)
                .onClick(() => this.logout())
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(18)
            .backgroundColor(themeBackground('surface', themeState().amoledActive, themeState().themeRevision))
            .borderRadius(20)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 48 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themeBackground('page_background', themeState().amoledActive, themeState().themeRevision))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
