import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_chapter_loader.dart';
import '../chapter_data.dart';
import '../reader_page.dart';
import '../settings.dart';
import 'webview_chapter_loader.dart';

/// 原生浏览模式下打开章节阅读器。
///
/// **按设置选择图源**（`AppSettings.chapterSource`）：
/// - `'webview'`：隐藏 Headless WebView 以 PC UA 收图（网页收图）；
/// - `'api'`：走 `/api/v3` 取图。
class NativeReaderLauncher {
  NativeReaderLauncher._();

  static final ApiChapterLoader _apiLoader = ApiChapterLoader();

  /// 打开 [chapterUuid] 的阅读器。
  static Future<void> open(
    BuildContext context, {
    required String comicId,
    required String chapterUuid,
  }) async {
    final notifier = ValueNotifier<ChapterData>(
      ChapterData(
        title: '加载中…',
        uuid: chapterUuid,
        nextChapterUrl: null,
        previousChapterUrl: null,
        imgUrls: const [],
        isLoading: true,
        comicId: comicId,
      ),
    );
    final loading = ValueNotifier<String?>(null);

    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            dataNotifier: notifier,
            loadingText: loading,
            onRequestChapter:
                (
                  String url, {
                  bool? goNext,
                  int? chapterRequestId,
                  String? readerInstanceId,
                  String? inputSource,
                  String? triggeringGestureSessionId,
                }) {
                  final ids = _idsFromUrl(url);
                  if (ids != null) {
                    unawaited(_load(notifier, loading, ids.comicId, ids.uuid));
                  }
                },
            onClose: null,
          ),
        ),
      ),
    );

    unawaited(_load(notifier, loading, comicId, chapterUuid));
  }

  /// 从合成 URL / 手机版 URL / PC 版 URL 里解析 (comicId, chapterUuid)。
  static ({String comicId, String uuid})? _idsFromUrl(String url) {
    final synth = ApiChapterLoader.parseChapterUrl(url);
    if (synth != null) return synth;
    const mobileMarker = '/comicContent/';
    if (url.contains(mobileMarker)) {
      final segs = url
          .substring(url.indexOf(mobileMarker) + mobileMarker.length)
          .split('/');
      if (segs.length >= 2 && segs[0].isNotEmpty) {
        return (comicId: segs[0], uuid: segs[1].split('?').first);
      }
    }
    const pcMarker = '/comic/';
    final i = url.indexOf(pcMarker);
    if (i >= 0) {
      final segs = url.substring(i + pcMarker.length).split('/');
      if (segs.length >= 3 && segs[0].isNotEmpty) {
        return (comicId: segs[0], uuid: segs[2].split('?').first);
      }
    }
    return null;
  }

  static Future<void> _load(
    ValueNotifier<ChapterData> notifier,
    ValueNotifier<String?> loading,
    String comicId,
    String uuid,
  ) async {
    final useWebView = AppSettings.chapterSource == 'webview';
    loading.value = useWebView ? '正在收集图片…' : '正在通过 API 取图…';
    try {
      final data = useWebView
          ? await WebViewChapterLoader.instance.load(comicId, uuid)
          : await _apiLoader.load(comicId, uuid);
      loading.value = null;
      notifier.value = data;
    } catch (_) {
      loading.value = null;
      notifier.value = ChapterData(
        title: '加载失败',
        uuid: uuid,
        nextChapterUrl: null,
        previousChapterUrl: null,
        imgUrls: const [],
        isLoading: false,
        comicId: comicId,
      );
    }
  }
}
