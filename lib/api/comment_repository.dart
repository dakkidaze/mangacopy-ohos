import 'api_domain_manager.dart';
import 'copy_api_client.dart';
import 'copy_manga_api_source.dart';
import 'models.dart';

/// 吐槽（评论）仓库：本版本 API 的唯一用途。
///
/// - 章末吐槽：直接 `roasts?chapter_id=`（chapter uuid 来自 WebView 章节 URL）。
/// - 总评：先用 path_word 取详情拿 comic uuid，再 `comments?comic_id=`。
/// - 使用前经 [ensureReady] 选域（`network4` 引导 + 探测），结果缓存。
class CommentRepository {
  CommentRepository({ApiDomainManager? domains, CopyApiClient? client})
    : domains = domains ?? ApiDomainManager() {
    this.client = client ?? CopyApiClient(domains: this.domains);
    source = CopyMangaApiSource(this.client);
  }

  final ApiDomainManager domains;
  late final CopyApiClient client;
  late final CopyMangaApiSource source;

  bool _ready = false;

  /// 幂等：首次调用时选域。
  Future<void> ensureReady() async {
    if (_ready) return;
    final boot = await domains.bootstrapFromNetwork4(domains.active);
    if (boot != null && boot.isNotEmpty) domains.active = boot;
    await domains.probeBest();
    _ready = true;
  }

  Future<List<Comment>> chapterComments(String chapterId) async {
    if (chapterId.isEmpty) return const [];
    await ensureReady();
    return source.chapterComments(chapterId);
  }

  Future<List<Comment>> comicComments(String comicPathWord) async {
    if (comicPathWord.isEmpty) return const [];
    await ensureReady();
    final d = await source.detail(comicPathWord);
    if (d == null || d.uuid.isEmpty) return const [];
    return source.comicComments(d.uuid);
  }
}
