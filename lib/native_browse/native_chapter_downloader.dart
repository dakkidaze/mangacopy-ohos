import 'dart:async';

import '../api/api_chapter_loader.dart';
import '../downloader.dart';
import '../settings.dart';
import 'webview_chapter_loader.dart';

/// 原生界面：下载某一章（先按设置的图源取图，再交给 [Downloader] 落盘）。
///
/// 与阅读器内下载共用同一套下载逻辑；`meta.json` 会写入真实 uuid/comicId，
/// 使离线阅读也能取吐槽。
class NativeChapterDownloader {
  NativeChapterDownloader._();

  static final ApiChapterLoader _apiLoader = ApiChapterLoader();

  /// 取图并下载；[onProgress] 回报 (已完成, 总数)。
  /// 返回是否全部成功。
  static Future<bool> download({
    required String comicId,
    required String chapterUuid,
    required String comicName,
    required String chapterName,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final List<String> urls;
    if (AppSettings.chapterSource == 'webview') {
      final data = await WebViewChapterLoader.instance.load(
        comicId,
        chapterUuid,
      );
      urls = data.imgUrls;
    } else {
      final data = await _apiLoader.load(comicId, chapterUuid);
      urls = data.imgUrls;
    }
    if (urls.isEmpty) return false;

    final folder = '章节_${chapterUuid.length >= 8 ? chapterUuid.substring(0, 8) : chapterUuid}';
    return Downloader.downloadImages(
      comicName,
      folder,
      urls,
      (done, total) => onProgress?.call(done, total),
      chapterUuid: chapterUuid,
      comicId: comicId,
      displayName: chapterName,
      isCancelled: isCancelled,
    );
  }
}
