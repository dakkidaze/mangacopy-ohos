import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:copymanga_flutter/api/api_domain_manager.dart';
import 'package:copymanga_flutter/api/copy_api_client.dart';
import 'package:copymanga_flutter/api/copy_manga_api_source.dart';

http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

CopyMangaApiSource _source(List<String> requestedPaths, {String? activeHost}) {
  final domains = ApiDomainManager();
  if (activeHost != null) domains.active = activeHost;
  final client = CopyApiClient(
    domains: domains,
    client: MockClient((req) async {
      requestedPaths.add(req.url.path);
      final p = req.url.path;
      if (p.endsWith('/api/v3/recs')) {
        return _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'list': [
                {
                  'comic': {
                    'path_word': 'x',
                    'name': '笨蛋天使與廢柴人類',
                    'cover': 'c',
                    'author': [
                      {'name': 'A'},
                    ],
                  },
                },
              ],
            },
          }),
        );
      }
      if (p.endsWith('/api/v3/comic2/bdtsyfcrl')) {
        return _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'comic': {
                'path_word': 'bdtsyfcrl',
                'name': '笨蛋天使與廢柴人類',
                'uuid': 'CUU',
                'author': [
                  {'name': 'A'},
                ],
              },
            },
          }),
        );
      }
      if (p.contains('/group/default/chapters')) {
        return _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'list': [
                {'uuid': 'u1', 'name': '第01話', 'index': 0, 'size': 3},
                {'uuid': 'u2', 'name': '第02話', 'index': 1, 'size': 4},
              ],
            },
          }),
        );
      }
      if (p.contains('/chapter')) {
        return _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'chapter': {
                'contents': [
                  {'url': 'https://img/1.jpg'},
                  {'url': 'https://img/2.jpg'},
                ],
              },
            },
          }),
        );
      }
      return _resp(jsonEncode({'code': 404, 'message': 'nf'}), 404);
    }),
  );
  return CopyMangaApiSource(client);
}

void main() {
  test('popular 解析 results.list（wrapped comic）', () async {
    final s = _source([]);
    final l = await s.popular();
    expect(l.single.title, '笨蛋天使與廢柴人類');
    expect(l.single.id, 'x');
    expect(l.single.author, 'A');
  });

  test('detail 解析 results.comic 含 uuid', () async {
    final s = _source([]);
    final d = await s.detail('bdtsyfcrl');
    expect(d, isNotNull);
    expect(d!.uuid, 'CUU');
    expect(d.title, '笨蛋天使與廢柴人類');
  });

  test('chapters 解析 uuid/name/index', () async {
    final s = _source([]);
    final c = await s.chapters('bdtsyfcrl');
    expect(c.map((e) => e.id), ['u1', 'u2']);
    expect(c.first.name, '第01話');
  });

  test('pages 解析 results.chapter.contents[].url', () async {
    final s = _source([]);
    final p = await s.pages('bdtsyfcrl', 'u1');
    expect(p, ['https://img/1.jpg', 'https://img/2.jpg']);
  });

  test('pages 热辣域用 /chapter/，普通域用 /chapter2/', () async {
    final normal = <String>[];
    await _source(normal).pages('bdtsyfcrl', 'u1');
    expect(normal.single, contains('/chapter2/'));

    final hot = <String>[];
    await _source(
      hot,
      activeHost: 'https://api.manga2025.com',
    ).pages('bdtsyfcrl', 'u1');
    expect(hot.single, contains('/chapter/'));
    expect(hot.single, isNot(contains('/chapter2/')));
  });
}
