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

CopyMangaApiSource _source(List<Uri> seen) {
  final domains = ApiDomainManager();
  final client = CopyApiClient(
    domains: domains,
    client: MockClient((req) async {
      seen.add(req.url);
      return _resp(
        jsonEncode({
          'code': 200,
          'results': {
            'total': 1,
            'list': [
              {
                'id': 91372,
                'user_name': '绯红战车',
                'comment': '好看',
                'create_at': '2026-10-02 09:12:10',
              },
            ],
          },
        }),
      );
    }),
  );
  return CopyMangaApiSource(client);
}

void main() {
  test('chapterComments 用 chapter_id（不是 comic_id）且路由到可评论域', () async {
    final seen = <Uri>[];
    final l = await _source(seen).chapterComments('CID');
    expect(seen.single.queryParameters['chapter_id'], 'CID');
    expect(seen.single.queryParameters.containsKey('comic_id'), isFalse);
    expect(
      ApiDomainManager.commentCapableHosts.contains(seen.single.host),
      isTrue,
    );
    expect(l.single.user, '绯红战车');
    expect(l.single.content, '好看');
  });

  test('comicComments 用 comic_id', () async {
    final seen = <Uri>[];
    final l = await _source(seen).comicComments('CUU');
    expect(seen.single.queryParameters['comic_id'], 'CUU');
    expect(l.single.createdAt, '2026-10-02 09:12:10');
  });
}
