import 'models.dart';

/// 图源抽象接口。
///
/// 抽象方法不能带默认值，故可选参数为可空；实现方填空。
/// v1 只实现 API 源（[CopyMangaApiSource]）；v2 的 WebView 源将实现同一接口，
/// 从而不改上层。
abstract class MangaSource {
  Future<List<MangaSummary>> popular({int? offset});

  Future<List<MangaSummary>> latest({int? offset});

  Future<List<MangaSummary>> search(String query, {int? offset});

  /// 通过作品 path_word 直接取详情（搜索类型之一）。
  Future<MangaSummary?> searchById(String id);

  Future<List<MangaSummary>> filter({
    String? ordering,
    String? region,
    String? theme,
    String? freeType,
    int? offset,
  });

  Future<MangaDetail?> detail(String id);

  Future<List<Chapter>> chapters(String id, {String? group});

  /// 章节图片 URL 列表。
  Future<List<String>> pages(String id, String chapterId);

  /// 章末吐槽。
  Future<List<Comment>> chapterComments(String chapterId);

  /// 漫画总评。
  Future<List<Comment>> comicComments(String comicUuid);

  Future<bool> login(String user, String pass);

  Future<List<MangaSummary>> favorites({int? offset});

  Future<List<MangaSummary>> history({int? offset});
}
