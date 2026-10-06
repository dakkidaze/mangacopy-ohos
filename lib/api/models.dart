/// 拷贝漫画 API 数据模型。
///
/// 字段名对应 `/api/v3` 实测返回；列表项可能是扁平的，也可能包一层 `comic`，
/// 这里统一兼容。
library;

dynamic _unwrapComic(dynamic raw) {
  if (raw is Map && raw['comic'] is Map) return raw['comic'];
  return raw;
}

String _authorName(dynamic v) {
  if (v is List) v = v.isEmpty ? null : v.first;
  if (v is Map) return (v['name'] ?? '').toString();
  return (v ?? '').toString();
}

String _display(dynamic v) {
  if (v is Map) return (v['display'] ?? '').toString();
  return (v ?? '').toString();
}

/// 列表项：热门/最新/搜索/筛选/收藏/历史。
class MangaSummary {
  final String id; // path_word
  final String title; // name
  final String cover;
  final String author;

  const MangaSummary({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
  });

  factory MangaSummary.fromJson(dynamic raw) {
    final m = _unwrapComic(raw) as Map;
    return MangaSummary(
      id: (m['path_word'] ?? '').toString(),
      title: (m['name'] ?? '').toString(),
      cover: (m['cover'] ?? '').toString(),
      author: _authorName(m['author']),
    );
  }
}

/// 章节项。
class Chapter {
  final String id; // uuid
  final String name;
  final int index;
  final int size;

  const Chapter({
    required this.id,
    required this.name,
    this.index = 0,
    this.size = 0,
  });

  factory Chapter.fromJson(dynamic raw) {
    final m = raw as Map;
    return Chapter(
      id: (m['uuid'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      index: int.tryParse('${m['index'] ?? 0}') ?? 0,
      size: int.tryParse('${m['size'] ?? 0}') ?? 0,
    );
  }
}

/// 漫画详情。
class MangaDetail {
  final String id; // path_word
  final String title;
  final String cover;
  final String author;
  final String description;
  final String status;
  final String uuid; // 供总评接口使用
  final String region;
  final List<String> genres;

  const MangaDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    this.description = '',
    this.status = '',
    this.uuid = '',
    this.region = '',
    this.genres = const [],
  });

  factory MangaDetail.fromJson(dynamic raw) {
    final m = _unwrapComic(raw) as Map;
    final theme = m['theme'];
    final genres = theme is List
        ? theme
              .map((e) => e is Map ? (e['name'] ?? '') : e)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    return MangaDetail(
      id: (m['path_word'] ?? '').toString(),
      title: (m['name'] ?? '').toString(),
      cover: (m['cover'] ?? '').toString(),
      author: _authorName(m['author']),
      description: (m['brief'] ?? m['description'] ?? '').toString(),
      status: _display(m['status']),
      uuid: (m['uuid'] ?? '').toString(),
      region: _display(m['region']),
      genres: genres,
    );
  }
}

/// 吐槽/评论。
class Comment {
  final String id;
  final String user;
  final String content;
  final String createdAt;

  const Comment({
    required this.id,
    required this.user,
    required this.content,
    required this.createdAt,
  });

  factory Comment.fromJson(dynamic raw) {
    final m = raw as Map;
    return Comment(
      id: (m['id'] ?? '').toString(),
      user: (m['user_name'] ?? '').toString(),
      content: (m['comment'] ?? '').toString(),
      createdAt: (m['create_at'] ?? '').toString(),
    );
  }
}
