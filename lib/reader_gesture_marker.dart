import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reader_gesture_debug.dart';

/// Debug-only：接收测试脚本 marker（MethodChannel / broadcast），不改变手势行为。
class ReaderGestureMarkerBridge {
  ReaderGestureMarkerBridge._();

  static const _channel = MethodChannel('cm/reader_gesture');
  static bool _initialized = false;

  static void init() {
    if (!kDebugMode || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'testActionMarker') return null;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      ReaderGestureDiagnostics.instance.onTestActionMarker(
        phase: args['phase'] as String? ?? 'unknown',
        testRunId: args['testRunId'] as String?,
        scenarioId: args['scenarioId'] as String?,
        actionId: args['actionId'] as String?,
        actionPhase: args['actionPhase'] as String?,
        timestamp: args['timestamp'] as String?,
      );
      return null;
    });
  }

  @visibleForTesting
  static Future<void> injectForTest(Map<String, dynamic> args) async {
    ReaderGestureDiagnostics.instance.onTestActionMarker(
      phase: args['phase'] as String? ?? 'unknown',
      testRunId: args['testRunId'] as String?,
      scenarioId: args['scenarioId'] as String?,
      actionId: args['actionId'] as String?,
      actionPhase: args['actionPhase'] as String?,
      timestamp: args['timestamp'] as String?,
    );
  }
}
