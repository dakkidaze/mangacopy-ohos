import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:copymanga_flutter/api/api_domain_manager.dart';

void main() {
  test('probeBest 选可用的候选（跳过 5xx）', () async {
    final m = ApiDomainManager(
      client: MockClient((req) async {
        if (req.url.host == 'good.example') {
          return http.Response(jsonEncode({'code': 200, 'results': {}}), 200);
        }
        return http.Response('', 500);
      }),
    );
    m.candidates = ['https://bad.example', 'https://good.example'];
    expect(
      await m.probeBest(timeout: const Duration(seconds: 1)),
      'https://good.example',
    );
  });

  test('probeBest 处理 body code!=200（不是成功）', () async {
    final m = ApiDomainManager(
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({'code': 210, 'message': 'x'}),
          200,
        ),
      ),
    );
    m.candidates = ['https://a.example'];
    expect(await m.probeBest(timeout: const Duration(seconds: 1)), m.active);
  });

  test('bootstrapFromNetwork4 解析 results.api 首个字符串', () async {
    final m = ApiDomainManager(
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({
            'code': 200,
            'results': {
              'api': [
                ['api.copy202601.com'],
                ['api.copy202601.com'],
              ],
            },
          }),
          200,
        ),
      ),
    );
    expect(
      await m.bootstrapFromNetwork4('https://seed.example'),
      'https://api.copy202601.com',
    );
  });

  test('customDomain 优先于候选', () async {
    final m = ApiDomainManager(
      client: MockClient(
        (req) async => http.Response(
          jsonEncode({'code': 200, 'results': {}}),
          200,
        ),
      ),
    );
    m.candidates = ['https://cand.example'];
    m.customDomain = 'mine.example';
    expect(
      await m.probeBest(timeout: const Duration(seconds: 1)),
      'https://mine.example',
    );
  });

  test('supportsComments 判定', () {
    final m = ApiDomainManager();
    expect(m.supportsComments('https://api.copy202601.com'), isTrue);
    expect(m.supportsComments('api.copy4000.com'), isTrue);
    expect(m.supportsComments('https://api.manga2025.com'), isFalse);
  });
}
