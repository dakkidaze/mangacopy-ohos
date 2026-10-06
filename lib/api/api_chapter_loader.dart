import '../chapter_data.dart';
import 'api_domain_manager.dart';
import 'copy_api_client.dart';
import 'copy_manga_api_source.dart';
import 'models.dart';

/// 设置「章节图源 = API」时，按章节经 `/api/v3` 取图。
///
/// 相邻章节用合成 URL（`apichapter:{comicId}:{uuid}`）表示，由 BrowserPage
/// 在收到切章请求时识别并同样走 API，避免与移动站 URL 混淆。
class ApiChapterLoader {
  ApiChapterLoader({ApiDomainManager? domains, CopyApiClient? client})
    : domains = domains ?? ApiDomainManager() {
    this.client = client ?? CopyApiClient(domains: this.domains);
    source = CopyMangaApiSource(this.client);
  }

  final ApiDomainManager domains;
  late final CopyApiClient client;
  late final CopyMangaApiSource source;

  bool _ready = false;
  final Map<String, List<Chapter>> _chaptersCache = {};

  static const String scheme = 'apichapter:';

  static String buildChapterUrl(String comicId, String uuid) =>
      '$scheme$comicId:$uuid';

  /// 解析合成 URL；非合成返回 null。
  static ({String comicId, String uuid})? parseChapterUrl(String url) {
    if (!url.startsWith(scheme)) return null;
    final rest = url.substring(scheme.length);
    final i = rest.indexOf(':');
    if (i <= 0 || i >= rest.length - 1) return null;
    return (comicId: rest.substring(0, i), uuid: rest.substring(i + 1));
  }

  Future<void> ensureReady() async {
    if (_ready) return;
    // 选域可能耗时，失败不致命：后续请求会带着现有 active 试一次。
    try {
      final boot = await domains.bootstrapFromNetwork4(domains.active);
      if (boot != null && boot.isNotEmpty) domains.active = boot;
      await domains.probeBest();
    } catch (_) {}
    _ready = true;
  }

  /// 取某章并组装成阅读器可消费的 [ChapterData]。
  Future<ChapterData> load(String comicId, String uuid) async {
    await ensureReady();
    final pages = await source.pages(comicId, uuid);

    var chapters = _chaptersCache[comicId];
    if (chapters == null) {
      try {
        chapters = await source.chapters(comicId);
        _chaptersCache[comicId] = chapters;
      } catch (_) {
        chapters = const [];
      }
    }

    final idx = chapters.indexWhere((c) => c.id == uuid);
    final name = idx >= 0 ? chapters[idx].name : '';
    final prevId = idx > 0 ? chapters[idx - 1].id : null;
    final nextId = (idx >= 0 && idx < chapters.length - 1)
        ? chapters[idx + 1].id
        : null;

    return ChapterData(
      title: name.isEmpty ? uuid : name,
      uuid: uuid,
      nextChapterUrl: nextId == null ? null : buildChapterUrl(comicId, nextId),
      previousChapterUrl: prevId == null
          ? null
          : buildChapterUrl(comicId, prevId),
      imgUrls: pages,
      comicId: comicId,
    );
  }
}
