/** 隐藏收图 Web 的宿主组件：1×1、透明、不吃触摸、不影响可见 UI。 */
import { webview } from '@kit.ArkWeb';
import { hiddenCollector } from './HiddenCollector';

@ComponentV2
export struct HiddenCollectorHost {
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    hiddenCollector.attach(this.controller);
  }

  build() {
    Stack() {
      Web({ src: '', controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onlineImageAccess(true)
        .width(1)
        .height(1)
        .opacity(0.01)
        // 不参与命中测试：不吃触摸、不抢焦点、不干扰可见网页壳
        .hitTestBehavior(HitTestMode.None)
        .onControllerAttached(() => {
          hiddenCollector.onControllerAttached();
        })
        .onPageEnd(() => {
          hiddenCollector.onPageEnd();
        })
        // JS 弹窗自动确认（不弹系统对话框，避免把隐藏收图卡住）：
        // 本机 SDK `ets/component/web.d.ts` 里 onAlert/onConfirm/onPrompt 的签名是
        // Callback<OnAlertEvent|OnConfirmEvent|OnPromptEvent, boolean>，
        // 返回 true = 应用接管弹窗，必须用 JsResult 回执：alert/confirm 走 handleConfirm()，
        // prompt 走 handlePromptConfirm('')（空输入）。
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
    }
    .width(1)
    .height(1)
    .opacity(0.01)
    .hitTestBehavior(HitTestMode.None)
  }
}
