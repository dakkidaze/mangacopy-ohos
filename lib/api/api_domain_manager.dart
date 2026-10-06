import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_headers.dart';

/// API 域名管理：候选列表 + 用户自定义 + `network4` 引导 + 自动探测。
///
/// 实测域名强依赖网络出口（本地经代理与直连可用域几乎不重叠），因此不写死默认，
/// 由 [probeBest] / [bootstrapFromNetwork4] 在运行时决定 [active]。
class ApiDomainManager {
  ApiDomainManager({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 引导/评论优先的候选域（顺序即优先级，用作探测并列时的次序）。
  List<String> candidates = const [
    'https://api.copy202601.com',
    'https://api.copy4000.com',
    'https://api.mangacopy.com',
    'https://mapi.copy20.com',
  ];

  /// 支持评论（roasts/comments）的域 host。
  static const Set<String> commentCapableHosts = {
    'api.copy202601.com',
    'api.copy4000.com',
    'api.mangacopy.com',
    'mapi.copy20.com',
  };

  /// 用户自定义域（非空时优先）。
  String? customDomain;

  /// 当前生效域。
  String active = 'https://api.copy202601.com';

  static String normalize(String domain) =>
      domain.startsWith('http') ? domain : 'https://$domain';

  bool supportsComments(String domain) {
    try {
      return commentCapableHosts.contains(Uri.parse(normalize(domain)).host);
    } catch (_) {
      return false;
    }
  }

  /// 拉官方当前线路：`GET {seed}/api/v3/system/network4` → `results.api` 里第一个字符串。
  Future<String?> bootstrapFromNetwork4(
    String seed, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final res = await _client
          .get(
            Uri.parse('${normalize(seed)}/api/v3/system/network4'),
            headers: apiHeaders(),
          )
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body);
      final host = _firstString((body is Map ? body['results'] : null)?['api']);
      if (host == null || host.isEmpty) return null;
      return normalize(host);
    } catch (_) {
      return null;
    }
  }

  static String? _firstString(dynamic v) {
    if (v is String) return v;
    if (v is List) {
      for (final e in v) {
        final s = _firstString(e);
        if (s != null) return s;
      }
    }
    return null;
  }

  /// 并发探测候选（自定义域优先），返回最快可用域并写入 [active]。
  ///
  /// 全部失败时返回 [active] 原值（调用方据此走"全不可用"逻辑）。
  Future<String> probeBest({Duration timeout = const Duration(seconds: 5)}) async {
    // 用户显式设置的自定义域优先：可用即用（避免与候选按毫秒竞速导致结果不确定）。
    final custom = customDomain;
    if (custom != null && custom.isNotEmpty) {
      final cd = normalize(custom);
      if ((await _probe(cd, timeout)).ok) {
        active = cd;
        return active;
      }
    }

    final list = <String>[];
    for (final d in candidates) {
      final n = normalize(d);
      if (n.isNotEmpty && !list.contains(n)) list.add(n);
    }

    final probed = await Future.wait(
      list.map((d) => _probe(d, timeout)),
    );
    String? best;
    var bestMs = 1 << 30;
    for (final p in probed) {
      if (!p.ok) continue;
      if (p.elapsedMs < bestMs || (p.elapsedMs == bestMs && (best == null || list.indexOf(p.domain) < list.indexOf(best)))) {
        best = p.domain;
        bestMs = p.elapsedMs;
      }
    }
    if (best != null) active = best;
    return active;
  }

  Future<_Probe> _probe(String domain, Duration timeout) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .get(
            Uri.parse('$domain/api/v3/recs?pos=3200102&limit=1&offset=0'),
            headers: apiHeaders(),
          )
          .timeout(timeout);
      sw.stop();
      var ok = res.statusCode == 200;
      if (ok) {
        try {
          ok = (json.decode(res.body) as Map)['code'] == 200;
        } catch (_) {
          ok = false;
        }
      }
      return _Probe(domain, ok, sw.elapsedMilliseconds);
    } catch (_) {
      sw.stop();
      return _Probe(domain, false, sw.elapsedMilliseconds);
    }
  }
}

class _Probe {
  final String domain;
  final bool ok;
  final int elapsedMs;
  _Probe(this.domain, this.ok, this.elapsedMs);
}
