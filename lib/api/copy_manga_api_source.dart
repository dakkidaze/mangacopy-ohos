import 'dart:convert';
import 'dart:math';

import 'api_headers.dart';
import 'auth_store.dart';
import 'copy_api_client.dart';
import 'manga_source.dart';
import 'models.dart';

/// 拷贝漫画 API 图源实现。
///
/// 读操作（Task 6）、读吐槽（Task 7）、登录/收藏/历史（Task 8）。
class CopyMangaApiSource implements MangaSource {
  CopyMangaApiSource(this.client, {this.defaultGroup = 'default', this.auth});

  final CopyApiClient client;
  final String defaultGroup;

  /// 可选的令牌持久化；为 null 时登录态仅在内存。
  final AuthStore? auth;

  static const String _kPos = '3200102';

  List<MangaSummary> _list(dynamic results) {
    final list = results is Map ? results['list'] : results;
    if (list is! List) return const [];
    return list.map(MangaSummary.fromJson).toList();
  }

  @override
  Future<List<MangaSummary>> popular({int? offset}) async {
    final r = await client.getJson(
      '/api/v3/recs',
      query: {'pos': _kPos, 'limit': '21', 'offset': '${offset ?? 0}'},
    );
    return _list(r);
  }

  @override
  Future<List<MangaSummary>> latest({int? offset}) async {
    final r = await client.getJson(
      '/api/v3/update/newest',
      query: {'limit': '21', 'offset': '${offset ?? 0}'},
    );
    return _list(r);
  }

  @override
  Future<List<MangaSummary>> search(String query, {int? offset}) async {
    final r = await client.getJson(
      '/api/v3/search/comic',
      query: {
        'limit': '21',
        'offset': '${offset ?? 0}',
        'q': query,
        '_update': 'true',
      },
    );
    return _list(r);
  }

  @override
  Future<MangaSummary?> searchById(String id) async {
    final d = await detail(id);
    if (d == null) return null;
    return MangaSummary(
      id: d.id,
      title: d.title,
      cover: d.cover,
      author: d.author,
    );
  }

  @override
  Future<List<MangaSummary>> filter({
    String? ordering,
    String? region,
    String? theme,
    String? freeType,
    int? offset,
  }) async {
    final r = await client.getJson(
      '/api/v3/comics',
      query: {
        'limit': '21',
        'offset': '${offset ?? 0}',
        'ordering': ordering ?? '-datetime_updated',
        'top': region ?? '',
        'theme': theme ?? '',
        'free_type': freeType ?? '',
        '_update': 'true',
      },
    );
    return _list(r);
  }

  @override
  Future<MangaDetail?> detail(String id) async {
    final r = await client.getJson('/api/v3/comic2/$id');
    if (r is! Map || r['comic'] == null) return null;
    return MangaDetail.fromJson(r['comic']);
  }

  @override
  Future<List<Chapter>> chapters(String id, {String? group}) async {
    final g = group ?? defaultGroup;
    final r = await client.getJson(
      '/api/v3/comic/$id/group/$g/chapters',
      query: {'limit': '500', 'offset': '0', '_update': 'true'},
    );
    final list = r is Map ? r['list'] : r;
    if (list is! List) return const [];
    return list.map(Chapter.fromJson).toList();
  }

  @override
  Future<List<String>> pages(String id, String chapterId) async {
    // 章节端点随域名分裂：热辣域用 chapter，其余用 chapter2（见 spec §6.3）。
    final seg = isHotDomain(client.domains.active) ? 'chapter' : 'chapter2';
    final r = await client.getJson('/api/v3/comic/$id/$seg/$chapterId');
    final chapter = r is Map ? (r['chapter'] ?? r) : r;
    final contents = chapter is Map ? chapter['contents'] : null;
    if (contents is! List) return const [];
    return contents
        .map((e) => e is Map ? (e['url'] ?? e['image'] ?? e['src'] ?? '').toString() : '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  // ---- Task 7/8 实现 ----

  // ---- 读吐槽（Task 7）----

  /// 章末吐槽：`GET /api/v3/roasts?chapter_id=`（注意必须用 `chapter_id`，
  /// 传 `comic_id` 会返回 210）。
  @override
  Future<List<Comment>> chapterComments(String chapterId) async {
    final r = await client.getJson(
      '/api/v3/roasts',
      query: {'chapter_id': chapterId, 'limit': '100'},
      comments: true,
    );
    return _comments(r);
  }

  /// 漫画总评：`GET /api/v3/comments?comic_id=`。
  @override
  Future<List<Comment>> comicComments(String comicUuid) async {
    final r = await client.getJson(
      '/api/v3/comments',
      query: {'comic_id': comicUuid, 'limit': '20', 'offset': '0'},
      comments: true,
    );
    return _comments(r);
  }

  List<Comment> _comments(dynamic results) {
    final list = results is Map ? results['list'] : results;
    if (list is! List) return const [];
    return list.map(Comment.fromJson).toList();
  }

  // ---- 登录/收藏/历史（Task 8）----

  /// 账号密码登录：`POST /api/v3/login`。
  ///
  /// 网页登录的"加密"实为 H5 里的 `base64(password + "-" + salt)` + `salt` 字段
  /// （已在真机/接口实测确认，非 RSA/AES）。成功后写 token，并自动保留 Cookie 会话。
  @override
  Future<bool> login(String user, String pass) async {
    try {
      final salt = (1000 + Random().nextInt(9000)).toString();
      final enc = base64.encode(utf8.encode('$pass-$salt'));
      final r = await client.postForm('/api/v3/login', {
        'username': user,
        'password': enc,
        'salt': salt,
      });
      final token = r is Map
          ? (r['token'] ?? r['access_token'] ?? '').toString()
          : '';
      if (token.isNotEmpty) {
        client.setToken(token);
      }
      // 整个会话（token + Cookie）落盘，避免重启掉登录。
      await auth?.saveSession(client.token, client.cookies);
      return token.isNotEmpty || client.hasSession;
    } on CopyApiException {
      return false;
    }
  }

  @override
  Future<List<MangaSummary>> favorites({int? offset}) async {
    final r = await client.getJson(
      '/api/v3/member/collect/comics',
      query: {
        'limit': '30',
        'offset': '${offset ?? 0}',
        'free_type': '1',
        'ordering': '-datetime_modifier',
      },
    );
    return _list(r);
  }

  @override
  Future<List<MangaSummary>> history({int? offset}) async {
    final r = await client.getJson(
      '/api/kb/web/browses',
      query: {'limit': '30', 'offset': '${offset ?? 0}', 'free_type': '1'},
    );
    return _list(r);
  }
}
