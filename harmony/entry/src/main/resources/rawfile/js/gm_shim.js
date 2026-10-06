// GM 垫片：把原生 Android 版的 @JavascriptInterface GM 对象
// 映射到 flutter_inappwebview 的 callHandler，i.js / h.js 无需改动即可复用。
// callHandler 在 flutterInAppWebViewPlatformReady 事件前不可用，因此先排队缓存调用。
if (typeof window.GM === "undefined") {
    (function () {
        var ready = false;
        var queue = [];
        window.addEventListener("flutterInAppWebViewPlatformReady", function () {
            ready = true;
            while (queue.length) {
                var c = queue.shift();
                window.flutter_inappwebview.callHandler.apply(null, c);
            }
        });
        function call() {
            var args = Array.prototype.slice.call(arguments);
            if (ready || (window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
                window.flutter_inappwebview.callHandler.apply(null, args);
            } else {
                queue.push(args);
            }
        }
        window.GM = {
            loadComic: function (url) { call('loadComic', url); },
            hideFab: function () { call('hideFab'); },
            enterProfile: function () { call('enterProfile'); },
            openSettings: function () { call('openSettings'); },
            loadChapter: function (result) { call('loadChapter', result); },
            setTitle: function (t) { call('setTitle', t); },
            setFab: function (json) { call('setFab', json); },
            setLoadingDialog: function (d) { call('setLoadingDialog', d); },
            setLoadingDialogProgress: function (i, c) { call('setLoadingDialogProgress', i, c); },
            toggleStatusBar: function () { call('toggleStatusBar'); }
        };
    })();
}
