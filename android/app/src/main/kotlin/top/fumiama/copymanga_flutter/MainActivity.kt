package top.fumiama.copymanga_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var volTurnEnabled = false
    private var channel: MethodChannel? = null
    private var gestureChannel: MethodChannel? = null
    private var markerReceiver: BroadcastReceiver? = null

    private val isDebuggable: Boolean
        get() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cm/volkeys")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    volTurnEnabled = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        gestureChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cm/reader_gesture")

        if (isDebuggable) {
            markerReceiver =
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        if (intent == null) return
                        gestureChannel?.invokeMethod(
                            "testActionMarker",
                            mapOf(
                                "phase" to intent.getStringExtra("phase"),
                                "testRunId" to intent.getStringExtra("testRunId"),
                                "scenarioId" to intent.getStringExtra("scenarioId"),
                                "actionId" to intent.getStringExtra("actionId"),
                                "actionPhase" to intent.getStringExtra("actionPhase"),
                                "timestamp" to intent.getStringExtra("timestamp"),
                            ),
                        )
                    }
                }
            val filter = IntentFilter("top.fumiama.copymanga_flutter.READER_GESTURE_MARKER")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(markerReceiver, filter, RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(markerReceiver, filter)
            }
        }
    }

    override fun onDestroy() {
        markerReceiver?.let { unregisterReceiver(it) }
        markerReceiver = null
        super.onDestroy()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volTurnEnabled) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    channel?.invokeMethod("volUp", null)
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    channel?.invokeMethod("volDown", null)
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
