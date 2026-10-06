import 'dart:io' show Platform;
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings.dart';

/// 统一管理状态栏 / 全面屏模式，避免各页各自 setEnabledSystemUIMode 互相踩。
class AppSystemUi {
  AppSystemUi._();

  /// 刘海机常见 Home 指示条高度（pt）；仅在系统 inset 读不到时使用。
  static const double iosHomeIndicatorFallback = 34.0;

  /// 会话内缓存：曾成功读到的底 inset，避免个别帧短暂为 0 时跳动。
  static double? _cachedHomeIndicatorPt;

  /// Home 指示条高度（逻辑像素 pt）。
  ///
  /// 数据与 iOS `UIWindow.safeAreaInsets.bottom`、Android 系统手势区
  /// 同源，经 Flutter 暴露为 [MediaQuery.viewPadding.bottom] /
  /// [FlutterView.padding]。
  ///
  /// - 系统值 `> 0`：直接采用并缓存
  /// - 系统值 `== 0`：无 Home 条（如带实体键机型），返回 0
  /// - 读不到，但顶 inset 像刘海机（`top > 20`）：回退 [iosHomeIndicatorFallback]
  /// - 完全无窗口信息且为 iOS：回退 34
  static double homeIndicatorHeight(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    var bottom = mq?.viewPadding.bottom;
    var top = mq?.viewPadding.top;

    if (bottom == null || top == null) {
      final view = _primaryView();
      if (view != null) {
        final dpr = view.devicePixelRatio;
        bottom ??= view.padding.bottom / dpr;
        top ??= view.padding.top / dpr;
      }
    }

    if (bottom != null && bottom > 0) {
      _cachedHomeIndicatorPt = bottom;
      return bottom;
    }

    // 系统明确为 0：再核对原生 view；仍为 0 则无 Home 条
    if (bottom == 0) {
      final view = _primaryView();
      if (view != null) {
        final raw = view.padding.bottom / view.devicePixelRatio;
        if (raw > 0) {
          _cachedHomeIndicatorPt = raw;
          return raw;
        }
      }
      // 顶安全区像刘海/灵动岛，底却为 0 → 多半尚未就绪，用缓存或 34
      if (Platform.isIOS && (top ?? 0) > 20) {
        return _cachedHomeIndicatorPt ?? iosHomeIndicatorFallback;
      }
      return 0;
    }

    // MediaQuery / View 都还没有
    if (Platform.isIOS) {
      return _cachedHomeIndicatorPt ?? iosHomeIndicatorFallback;
    }
    return _cachedHomeIndicatorPt ?? 0;
  }

  static FlutterView? _primaryView() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isEmpty ? null : views.first;
  }

  /// 浏览页：iOS 必须用 edgeToEdge（manual 会在刘海机留上下黑边）。
  static void applyBrowser({required bool statusBarHidden}) {
    final dark = AppSettings.darkMode.value;
    if (Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(
        statusBarHidden
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      );
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          // iOS：light = 深色字（浅色底），dark = 浅色字（深色底）
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        ),
      );
      return;
    }
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: statusBarHidden
          ? [SystemUiOverlay.bottom]
          : SystemUiOverlay.values,
    );
    // Android 手势条区域底色跟明暗，避免白网页下露出黑导航底
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: dark ? Colors.black : Colors.white,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
    );
  }

  /// 阅读器：沉浸式隐藏系统栏。
  static void applyReader() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 离开阅读器后按设置恢复浏览页模式（勿再写死 manual）。
  static void restoreBrowserFromSettings() {
    applyBrowser(statusBarHidden: AppSettings.hideStatusBar.value);
  }
}
