import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 登录态的持久化：token（`Authorization: Token`）与网页会话 Cookie。
///
/// 网页登录通常只给 Cookie，不给 token，所以两者都要落盘，否则重启即掉登录。
class AuthStore {
  static const String _kToken = 'api_token';
  static const String _kCookies = 'api_cookies';

  String? _token;
  String? get token => _token;

  Map<String, String> _cookies = {};
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  bool get hasSavedSession =>
      (_token != null && _token!.isNotEmpty) || _cookies.isNotEmpty;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _token = p.getString(_kToken);
    final raw = p.getString(_kCookies);
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw);
        if (m is Map) {
          _cookies = m.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {
        _cookies = {};
      }
    }
  }

  Future<void> save(String? t) async {
    _token = t;
    final p = await SharedPreferences.getInstance();
    if (t == null || t.isEmpty) {
      await p.remove(_kToken);
    } else {
      await p.setString(_kToken, t);
    }
  }

  /// 保存/清除整个会话（token + Cookie）。
  Future<void> saveSession(String? token, Map<String, String> cookies) async {
    _token = token;
    _cookies = Map.of(cookies);
    final p = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await p.remove(_kToken);
    } else {
      await p.setString(_kToken, token);
    }
    if (_cookies.isEmpty) {
      await p.remove(_kCookies);
    } else {
      await p.setString(_kCookies, jsonEncode(_cookies));
    }
  }
}
