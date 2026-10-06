import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_domain_manager.dart';
import 'api_headers.dart';

/// 业务错误：HTTP 200 但 body `code != 200`（如 `210 吐槽對象不能爲空`），
/// 或 HTTP 非 2xx。
class CopyApiException implements Exception {
  final int code;
  final String message;
  CopyApiException(this.code, this.message);

  @override
  String toString() => 'CopyApiException($code: $message)';
}

/// 拷贝漫画 API 客户端：统一请求头、`code` 判定、评论域路由、重试、Token。
class CopyApiClient {
  CopyApiClient({required this.domains, http.Client? client, String? token})
    : _client = client ?? http.Client(),
      _token = token;

  final ApiDomainManager domains;
  final http.Client _client;
  String? _token;

  /// 轻量节流：限制并发/最小间隔/抖动，降低"非人"特征与触发限速的概率。
  final ApiThrottle _throttle = ApiThrottle();

  /// 简单 Cookie 罐：网页登录态是 Cookie 会话，收藏/历史依赖它。
  final Map<String, String> _cookies = {};

  String? get token => _token;

  void setToken(String? t) => _token = t;

  bool get hasSession => _cookies.isNotEmpty || (_token?.isNotEmpty ?? false);

  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  /// 启动时恢复已持久化的 Cookie 会话。
  void restoreCookies(Map<String, String> c) {
    _cookies
      ..clear()
      ..addAll(c);
  }

  void clearSession() {
    _cookies.clear();
    _token = null;
  }

  /// 依据当前域是否为热辣域决定 `Webp` 头。
  Map<String, String> _headers() {
    final h = apiHeaders(webp: isHotDomain(domains.active) ? '1' : '0');
    if (_token != null && _token!.isNotEmpty) {
      h['Authorization'] = 'Token $_token';
    }
    if (_cookies.isNotEmpty) {
      h['Cookie'] = _cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    return h;
  }

  /// 吸收响应里的 Set-Cookie（登录后维持会话）。
  void _absorbCookies(http.Response res) {
    List<String> raw;
    try {
      raw = res.headersSplitValues['set-cookie'] ?? const [];
    } catch (_) {
      raw = const [];
    }
    if (raw.isEmpty && res.headers['set-cookie'] != null) {
      raw = [res.headers['set-cookie']!];
    }
    for (final line in raw) {
      final first = line.split(';').first.trim();
      final i = first.indexOf('=');
      if (i > 0) {
        _cookies[first.substring(0, i).trim()] = first
            .substring(i + 1)
            .trim();
      }
    }
  }

  /// 评论请求需路由到支持评论的域。
  String _base({required bool comments}) {
    if (!comments) return domains.active;
    if (domains.supportsComments(domains.active)) return domains.active;
    for (final d in domains.candidates) {
      if (domains.supportsComments(d)) return d;
    }
    return domains.active;
  }

  Uri _uri(String base, String path, Map<String, String>? query) {
    final u = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    bool comments = false,
    int retries = 2,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final base = _base(comments: comments);
    Object? lastErr;
    for (var i = 0; i <= retries; i++) {
      try {
        final res = await _throttle.run(
          () => _client
              .get(_uri(base, path, query), headers: _headers())
              .timeout(timeout),
        );
        _absorbCookies(res);
        return _parse(res);
      } on CopyApiException {
        rethrow;
      } catch (e) {
        lastErr = e; // 网络类错误：重试
      }
    }
    throw CopyApiException(-1, 'network error: $lastErr');
  }

  Future<dynamic> postForm(
    String path,
    Map<String, String> body, {
    int retries = 2,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Object? lastErr;
    for (var i = 0; i <= retries; i++) {
      try {
        final res = await _throttle.run(
          () => _client
              .post(
                _uri(domains.active, path, null),
                headers: _headers(),
                body: body,
              )
              .timeout(timeout),
        );
        _absorbCookies(res);
        return _parse(res);
      } on CopyApiException {
        rethrow;
      } catch (e) {
        lastErr = e;
      }
    }
    throw CopyApiException(-1, 'network error: $lastErr');
  }

  dynamic _parse(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CopyApiException(res.statusCode, 'HTTP ${res.statusCode}');
    }
    // 显式 UTF-8 解码：服务端 JSON 含中文，且 content-type 未必带 charset。
    final body = json.decode(utf8.decode(res.bodyBytes));
    final code = body is Map ? body['code'] : null;
    if (code == 200) return body['results'];
    throw CopyApiException(
      code is int ? code : -1,
      '${(body is Map ? body['message'] : '') ?? ''}',
    );
  }
}
