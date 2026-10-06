import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:copymanga_flutter/api/api_chapter_loader.dart';
import 'package:copymanga_flutter/api/api_domain_manager.dart';
import 'package:copymanga_flutter/api/copy_api_client.dart';

http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('合成切章 URL 往返', () {
    final u = ApiChapterLoader.buildChapterUrl('pw', 'uuid-1');
    expect(u, 'apichapter:pw:uuid-1');
    final p = ApiChapterLoader.parseChapterUrl(u);
    expect(p?.comicId, 'pw');
    expect(p?.uuid, 'uuid-1');
    expect(ApiChapterLoader.parseChapterUrl('https://x/comicContent/a/b'), isNull);
  });

  test('load 组装 ChapterData（标题/相邻章）', () async {
    final loader = ApiChapterLoader(
      domains: ApiDomainManager(),
      client: CopyApiClient(
        domains: ApiDomainManager(),
        client: MockClient((req) async {
          final p = req.url.path;
          if (p.endsWith('/api/v3/system/network4')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (p.endsWith('/api/v3/recs')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (p.contains('/group/default/chapters')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'list': [
                    {'uuid': 'u1', 'name': '第01話', 'index': 0},
                    {'uuid': 'u2', 'name': '第02話', 'index': 1},
                    {'uuid': 'u3', 'name': '第03話', 'index': 2},
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
                    ],
                  },
                },
              }),
            );
          }
          return _resp(jsonEncode({'code': 404}), 404);
        }),
      ),
    );

    final d = await loader.load('pw', 'u2');
    expect(d.title, '第02話');
    expect(d.uuid, 'u2');
    expect(d.imgUrls, ['https://img/1.jpg']);
    expect(d.comicId, 'pw');
    expect(d.previousChapterUrl, ApiChapterLoader.buildChapterUrl('pw', 'u1'));
    expect(d.nextChapterUrl, ApiChapterLoader.buildChapterUrl('pw', 'u3'));
  });

  test('load 首章无上一章', () async {
    final loader = ApiChapterLoader(
      domains: ApiDomainManager(),
      client: CopyApiClient(
        domains: ApiDomainManager(),
        client: MockClient((req) async {
          final p = req.url.path;
          if (p.endsWith('/api/v3/system/network4') || p.endsWith('/api/v3/recs')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (p.contains('/group/default/chapters')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'list': [
                    {'uuid': 'u1', 'name': '第01話'},
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
                    ],
                  },
                },
              }),
            );
          }
          return _resp(jsonEncode({'code': 404}), 404);
        }),
      ),
    );
    final d = await loader.load('pw', 'u1');
    expect(d.previousChapterUrl, isNull);
    expect(d.nextChapterUrl, isNull);
  });
}
