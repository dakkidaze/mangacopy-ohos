import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:copymanga_flutter/api/api_domain_manager.dart';
import 'package:copymanga_flutter/api/comment_repository.dart';
import 'package:copymanga_flutter/api/copy_api_client.dart';

http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('chapterComments 走 roasts 且用 chapter_id', () async {
    final seen = <Uri>[];
    final repo = CommentRepository(
      domains: ApiDomainManager(),
      client: CopyApiClient(
        domains: ApiDomainManager(),
        client: MockClient((req) async {
          seen.add(req.url);
          if (req.url.path.endsWith('/api/v3/system/network4')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'api': [
                    ['api.copy202601.com'],
                  ],
                },
              }),
            );
          }
          if (req.url.path.endsWith('/api/v3/recs')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (req.url.path.endsWith('/api/v3/roasts')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'list': [
                    {'id': 1, 'user_name': 'u', 'comment': 'c', 'create_at': 't'},
                  ],
                },
              }),
            );
          }
          return _resp(jsonEncode({'code': 404}), 404);
        }),
      ),
    );
    final l = await repo.chapterComments('CID');
    expect(l.single.content, 'c');
    final roasts = seen.where((u) => u.path.endsWith('/roasts')).toList();
    expect(roasts.single.queryParameters['chapter_id'], 'CID');
    expect(ApiDomainManager.commentCapableHosts.contains(roasts.single.host), isTrue);
  });

  test('comicComments 先取详情拿 uuid 再请求 comments?comic_id=uuid', () async {
    final seen = <Uri>[];
    final repo = CommentRepository(
      domains: ApiDomainManager(),
      client: CopyApiClient(
        domains: ApiDomainManager(),
        client: MockClient((req) async {
          seen.add(req.url);
          final p = req.url.path;
          if (p.endsWith('/api/v3/system/network4')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (p.endsWith('/api/v3/recs')) {
            return _resp(jsonEncode({'code': 200, 'results': {}}));
          }
          if (p.contains('/api/v3/comic2/')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'comic': {'path_word': 'pw', 'name': 'N', 'uuid': 'CUUID'},
                },
              }),
            );
          }
          if (p.endsWith('/api/v3/comments')) {
            return _resp(
              jsonEncode({
                'code': 200,
                'results': {
                  'list': [
                    {'id': 2, 'user_name': 'v', 'comment': 'd', 'create_at': 't2'},
                  ],
                },
              }),
            );
          }
          return _resp(jsonEncode({'code': 404}), 404);
        }),
      ),
    );
    final l = await repo.comicComments('pw');
    expect(l.single.content, 'd');
    final comments = seen.where((u) => u.path.endsWith('/comments')).toList();
    expect(comments.single.queryParameters['comic_id'], 'CUUID');
  });
}
