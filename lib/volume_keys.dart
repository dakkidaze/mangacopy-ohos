import 'package:flutter/services.dart';

/// 音量键翻页平台通道（Android 拦截物理键；iOS 监听系统音量变化）。
/// 阅读器进入时 enable 并注册回调，退出时 disable。
class VolumeKeys {
  static const _channel = MethodChannel('cm/volkeys');
  static void Function()? onUp;
  static void Function()? onDown;
  static bool _handlerSet = false;

  static Future<void> enable({
    required void Function() up,
    required void Function() down,
  }) async {
    onUp = up;
    onDown = down;
    if (!_handlerSet) {
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'volUp':
            onUp?.call();
          case 'volDown':
            onDown?.call();
        }
      });
      _handlerSet = true;
    }
    try {
      await _channel.invokeMethod('setEnabled', true);
    } on MissingPluginException {
      // 测试/无原生实现时忽略
    }
  }

  static Future<void> disable() async {
    onUp = null;
    onDown = null;
    try {
      await _channel.invokeMethod('setEnabled', false);
    } on MissingPluginException {
      // 测试/无原生实现时忽略
    }
  }
}
