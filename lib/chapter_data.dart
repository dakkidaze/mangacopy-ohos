/// h.js 收图结果的解析，对应原生版 MainActivity.callViewManga 的协议：
/// 第 0 行 "标题 uuid"，第 1 行下一章手机版 URL（无则 "null"），
/// 第 2 行上一章，其余每行一个图片 URL。
class ChapterData {
  final String title;
  final String uuid;
  final String? nextChapterUrl;
  final String? previousChapterUrl;
  final List<String> imgUrls;

  /// 离线阅读时 imgUrls 为本地文件路径
  final bool isLocal;

  /// 初始页：0 = 自动（恢复断点或第 1 页），-2 = 最后一页（从下一章返回时）
  final int initialPage;

  /// 漫画 path_word（供总评接口）。由浏览页在打开章节时填入；未知时为空串。
  final String comicId;

  /// 是否为"壳"（图片尚未就绪）。阅读器据此显示「加载中」而非「本章无图片」。
  final bool isLoading;

  ChapterData({
    required this.title,
    this.uuid = '',
    required this.nextChapterUrl,
    required this.previousChapterUrl,
    required this.imgUrls,
    this.isLocal = false,
    this.initialPage = 0,
    this.comicId = '',
    this.isLoading = false,
  });

  ChapterData copyWith({String? comicId, bool? isLoading}) => ChapterData(
    title: title,
    uuid: uuid,
    nextChapterUrl: nextChapterUrl,
    previousChapterUrl: previousChapterUrl,
    imgUrls: imgUrls,
    isLocal: isLocal,
    initialPage: initialPage,
    comicId: comicId ?? this.comicId,
    isLoading: isLoading ?? this.isLoading,
  );

  static ChapterData? parse(String raw) {
    final lines = raw.split('\n');
    if (lines.length < 3) return null;
    final head = lines[0];
    final sp = head.lastIndexOf(' ');
    final title = sp > 0 ? head.substring(0, sp) : head;
    final uuid = sp > 0 ? head.substring(sp + 1) : '';
    String? nullable(String s) => s == 'null' ? null : s;
    return ChapterData(
      title: title,
      uuid: uuid,
      nextChapterUrl: nullable(lines[1]),
      previousChapterUrl: nullable(lines[2]),
      imgUrls: lines.sublist(3).where((l) => l.trim().isNotEmpty).toList(),
    );
  }

  /// 章节唯一键，供断点续读
  String get chapterKey => uuid.isNotEmpty
      ? uuid
      : (imgUrls.isEmpty
            ? title.hashCode.toString()
            : imgUrls.first.hashCode.toString());
}

/// 图片分辨率提升：c800x. → c1500x.（对应原生版 Resolution.kt）
String wrapResolution(String url) =>
    url.replaceAll(RegExp(r'c\d+x\.'), 'c1500x.');
