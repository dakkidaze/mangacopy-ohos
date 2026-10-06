import 'package:flutter_test/flutter_test.dart';
import 'package:copymanga_flutter/api/models.dart';

void main() {
  test('MangaSummary.fromJson parses wrapped list item', () {
    final s = MangaSummary.fromJson({
      'type': 1,
      'comic': {
        'path_word': 'x',
        'name': 'N',
        'cover': 'c',
        'author': [
          {'name': 'A'},
        ],
      },
    });
    expect([s.id, s.title, s.cover, s.author], ['x', 'N', 'c', 'A']);
  });

  test('MangaSummary.fromJson parses flat item', () {
    final s = MangaSummary.fromJson({
      'path_word': 'p',
      'name': 'T',
      'cover': 'cv',
      'author': [
        {'name': 'Au'},
      ],
    });
    expect([s.id, s.title, s.author], ['p', 'T', 'Au']);
  });

  test('Chapter.fromJson parses uuid/name/index/size', () {
    final c = Chapter.fromJson({
      'uuid': 'u',
      'name': '第01話',
      'index': 2,
      'size': 3,
    });
    expect([c.id, c.name, c.index, c.size], ['u', '第01話', 2, 3]);
  });

  test('MangaDetail.fromJson parses uuid/status/genres', () {
    final d = MangaDetail.fromJson({
      'comic': {
        'path_word': 'x',
        'name': 'N',
        'cover': 'c',
        'author': [
          {'name': 'A'},
        ],
        'uuid': 'UU',
        'brief': 'B',
        'status': {'display': '連載中'},
        'theme': [
          {'name': '愛情'},
          {'name': '奇幻'},
        ],
      },
    });
    expect(d.uuid, 'UU');
    expect(d.status, '連載中');
    expect(d.genres, ['愛情', '奇幻']);
    expect(d.author, 'A');
  });

  test('Comment.fromJson parses user_name/comment/create_at', () {
    final c = Comment.fromJson({
      'id': 9,
      'user_name': 'u',
      'comment': 'c',
      'create_at': 't',
    });
    expect([c.id, c.user, c.content, c.createdAt], ['9', 'u', 'c', 't']);
  });
}
