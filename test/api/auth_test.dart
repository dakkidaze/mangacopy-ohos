import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:copymanga_flutter/api/api_domain_manager.dart';
import 'package:copymanga_flutter/api/auth_store.dart';
import 'package:copymanga_flutter/api/copy_api_client.dart';
import 'package:copymanga_flutter/api/copy_manga_api_source.dart';

http.Response _resp(String body, [int status = 200]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('login 存 token，后续请求带 Authorization', () async {
    final seen = <http.BaseRequest>[];
    final client = CopyApiClient(
      domains: ApiDomainManager(),
      client: MockClient((req) async {
        seen.add(req);
        if (req.url.path.endsWith('/api/v3/login')) {
          return _resp(jsonEncode({'code': 200, 'results': {'token': 'T'}}));
        }
        return _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'list': [
                {
                  'comic': {
                    'path_word': 'x',
                    'name': 'N',
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
      }),
    );
    final s = CopyMangaApiSource(client, auth: AuthStore());
    expect(await s.login('u', 'p'), isTrue);
    expect(client.token, 'T');

    final favs = await s.favorites();
    expect(favs.single.title, 'N');
    expect(seen.last.headers['Authorization'], 'Token T');
  });

  test('login 在业务失败（210）时返回 false', () async {
    final client = CopyApiClient(
      domains: ApiDomainManager(),
      client: MockClient(
        (req) async => _resp(jsonEncode({'code': 210, 'message': '账号或密码错误'})),
      ),
    );
    final s = CopyMangaApiSource(client);
    expect(await s.login('u', 'bad'), isFalse);
  });

  test('history 解析 results.list', () async {
    final client = CopyApiClient(
      domains: ApiDomainManager(),
      client: MockClient(
        (req) async => _resp(
          jsonEncode({
            'code': 200,
            'results': {
              'list': [
                {'path_word': 'h1', 'name': 'H', 'cover': 'c', 'author': []},
              ],
            },
          }),
        ),
      ),
    );
    final s = CopyMangaApiSource(client);
    final h = await s.history();
    expect(h.single.id, 'h1');
  });
}
