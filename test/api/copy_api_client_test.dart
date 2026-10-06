import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:copymanga_flutter/api/api_domain_manager.dart';
import 'package:copymanga_flutter/api/copy_api_client.dart';

/// UTF-8 响应（中文不会因 latin1 默认编码而报错）。
http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

CopyApiClient _clientReturning(
  String body, {
  int status = 200,
  List<http.Request>? sink,
}) {
  return CopyApiClient(
    domains: ApiDomainManager(),
    client: MockClient((req) async {
      sink?.add(req);
      return _resp(body, status);
    }),
  );
}

void main() {
  test('code 200 返回 results', () async {
    final c = _clientReturning(jsonEncode({'code': 200, 'results': {'ok': 1}}));
    expect(await c.getJson('/api/v3/recs'), {'ok': 1});
  });

  test('code 210 抛 CopyApiException（HTTP 仍 200）', () async {
    final c = _clientReturning(
      jsonEncode({'code': 210, 'message': '吐槽對象不能爲空'}),
    );
    expect(
      () => c.getJson('/api/v3/roasts', query: {'comic_id': 'x'}),
      throwsA(
        isA<CopyApiException>()
            .having((e) => e.code, 'code', 210)
            .having((e) => e.message, 'message', contains('吐槽')),
      ),
    );
  });

  test('HTTP 非 2xx 抛异常且不重试', () async {
    var hits = 0;
    final c = CopyApiClient(
      domains: ApiDomainManager(),
      client: MockClient((req) async {
        hits++;
        return _resp('nope', 404);
      }),
    );
    await expectLater(c.getJson('/api/v3/recs'), throwsA(isA<CopyApiException>()));
    expect(hits, 1);
  });

  test('请求头包含 Version/Region/platform', () async {
    final sink = <http.Request>[];
    final c = _clientReturning(
      jsonEncode({'code': 200, 'results': {}}),
      sink: sink,
    );
    await c.getJson('/api/v3/recs');
    expect(sink.single.headers['Version'], '2025.11.21');
    expect(sink.single.headers['Region'], '0');
    expect(sink.single.headers['platform'], '1');
  });

  test('登录后请求带 Authorization: Token', () async {
    final sink = <http.Request>[];
    final c = _clientReturning(
      jsonEncode({'code': 200, 'results': {}}),
      sink: sink,
    );
    c.setToken('T');
    await c.getJson('/api/v3/recs');
    expect(sink.single.headers['Authorization'], 'Token T');
  });

  test('评论请求路由到支持评论的域（active 不支持时）', () async {
    final sink = <http.Request>[];
    final domains = ApiDomainManager();
    domains.active = 'https://api.manga2025.com'; // 不支持评论
    final c = CopyApiClient(
      domains: domains,
      client: MockClient((req) async {
        sink.add(req);
        return _resp(jsonEncode({'code': 200, 'results': {}}));
      }),
    );
    await c.getJson('/api/v3/roasts', comments: true);
    expect(sink.single.url.host, isNot('api.manga2025.com'));
    expect(
      ApiDomainManager.commentCapableHosts.contains(sink.single.url.host),
      isTrue,
    );
  });
}
