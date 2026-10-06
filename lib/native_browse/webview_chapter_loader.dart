import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../api/api_headers.dart';
import '../chapter_data.dart';
import '../settings.dart';
import '../url_manager.dart';

/// 「网页收图」图源：用隐藏的 Headless WebView（PC UA）打开 PC 版章节页，
/// 注入 `gm_shim.js` + `h.js` 自动滚动收集图片，返回 [ChapterData]。
///
/// 对应 `AppSettings.chapterSource == 'webview'`；原生浏览界面与网页版共用同一套脚本。
class WebViewChapterLoader {
  WebViewChapterLoader._();

  static final WebViewChapterLoader instance = WebViewChapterLoader._();

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  String? _gmShim;
  String? _hJs;

  Completer<ChapterData>? _pending;
  String? _pendingKey;
  bool _handlersRegistered = false;

  /// PC 版章节页 URL：`{webHost}/comic/{pathWord}/chapter/{uuid}`。
  String _pcUrl(String comicId, String chapterId) =>
      '${UrlManager.activeUrl}/comic/$comicId/chapter/$chapterId';

  Future<void> _ensureAssets() async {
    _gmShim ??= await rootBundle.loadString('assets/js/gm_shim.js');
    if (_hJs == null) {
      final raw = await rootBundle.loadString('assets/js/h.js');
      _hJs = raw.trim();
    }
  }

  Future<InAppWebViewController?> _ensureHeadless() async {
    if (_headless == null) {
      final h = HeadlessInAppWebView(
        initialSize: const Size(1024, 768),
        initialSettings: InAppWebViewSettings(
          userAgent: kDesktopUserAgent,
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
          useWideViewPort: true,
          loadWithOverviewMode: true,
          transparentBackground: true,
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
          if (!_handlersRegistered) {
            _handlersRegistered = true;
            controller.addJavaScriptHandler(
              handlerName: 'loadChapter',
              callback: (args) {
                if (args.isEmpty) return;
                final data = ChapterData.parse(args[0] as String);
                final c = _pending;
                if (data != null && c != null && !c.isCompleted) {
                  _pending = null;
                  _pendingKey = null;
                  c.complete(data);
                }
              },
            );
          }
        },
        onLoadStop: (controller, url) => _inject(controller),
      );
      _headless = h;
      await h.run();
    }
    for (var i = 0; i < 20 && _controller == null; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return _controller;
  }

  Future<void> _inject(InAppWebViewController controller) async {
    await _ensureAssets();
    await Future.delayed(const Duration(milliseconds: 400));
    await controller.evaluateJavascript(
      source:
          "window.__CM_SOURCE_PROFILE='${AppSettings.sourceProfile}';"
          "window.__CM_ACTIVE_URL='${UrlManager.activeUrl}';",
    );
    await controller.evaluateJavascript(source: _gmShim!);
    await controller.evaluateJavascript(source: _hJs!);
  }

  /// 抓取某一章（网页收图）。失败抛异常。
  Future<ChapterData> load(
    String comicId,
    String chapterId, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final c = await _ensureHeadless();
    if (c == null) {
      throw StateError('隐藏收图 WebView 初始化失败');
    }
    final key = '$comicId/$chapterId';
    // 同一章重复请求时，复用未完成的等待
    if (_pending != null && _pendingKey == key) return _pending!.future;

    final completer = Completer<ChapterData>();
    _pending = completer;
    _pendingKey = key;

    try {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(_pcUrl(comicId, chapterId))));
      return await completer.future.timeout(timeout);
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
        _pendingKey = null;
      }
    }
  }

  /// 释放隐藏页（退出原生模式时可选调用）。
  Future<void> dispose() async {
    await _headless?.dispose();
    _headless = null;
    _controller = null;
    _handlersRegistered = false;
  }
}
