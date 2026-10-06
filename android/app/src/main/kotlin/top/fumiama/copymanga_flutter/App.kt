package top.fumiama.copymanga_flutter

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.webkit.WebView

/// 对齐原生 App.kt：主线程下一帧预热 WebView 进程，减轻进主页后的白屏等待。
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Handler(Looper.getMainLooper()).post {
            try {
                WebView(applicationContext).destroy()
            } catch (_: Throwable) {
            }
        }
    }
}
