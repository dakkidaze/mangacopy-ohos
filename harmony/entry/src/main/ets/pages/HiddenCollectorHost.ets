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
    }
    .width(1)
    .height(1)
    .opacity(0.01)
    .hitTestBehavior(HitTestMode.None)
  }
}
