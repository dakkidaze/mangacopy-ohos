/// 拷贝漫画 API 通用请求头（网页身份，实测有效）。
///
/// 身份约定（"网页身份自洽"）：
/// - **API 客户端用移动 UA**，与可见 WebView 一致（手机上的网页会话）；
/// - **桌面 UA 只给隐藏收图 WebView 用**（PC 版章节页，绕开网页端"仅前 5 页"）。
library;

import 'dart:async';
import 'dart:math';

/// 官方 App 版本头；上游更新时最易变（见上游跟踪脚本）。
const String kApiVersion = '2025.11.21';

/// 可见 WebView / API 客户端使用的**移动** UA。
const String kMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/// 隐藏收图 WebView 使用的**桌面** UA（PC 版章节页）。
const String kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 默认请求头（网页身份：移动 UA + 浏览器式 XHR 头）。
Map<String, String> apiHeaders({String platform = '1', String webp = '0'}) => {
  'User-Agent': kMobileUserAgent,
  'Accept': 'application/json, text/plain, */*',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  'Version': kApiVersion,
  'Region': '0',
  'Webp': webp,
  'platform': platform,
  'Origin': 'https://www.mangacopy.com',
  'Referer': 'https://www.mangacopy.com/h5/',
  'X-Requested-With': 'XMLHttpRequest',
};

/// 章节图片域名/后缀判定：热辣系域用 `/chapter/` 且 `Webp:1`，其余用 `/chapter2/`。
final RegExp kHotDomainRe = RegExp(
  r'manga2025|hotmanga|fgjf|elfgj|relamanhua',
  caseSensitive: false,
);

bool isHotDomain(String domain) => kHotDomainRe.hasMatch(domain);

/// 轻量请求节流：限制并发 + 最小间隔 + 抖动，避免"非人"的匀速猛打。
class ApiThrottle {
  ApiThrottle({
    this.maxConcurrent = 2,
    this.minInterval = const Duration(milliseconds: 300),
    this.jitter = Duration.zero,
  });

  final int maxConcurrent;
  final Duration minInterval;
  final Duration jitter;

  int _running = 0;
  DateTime? _lastStart;
  final Random _rnd = Random();
  Future<T> run<T>(Future<T> Function() task) async {
    while (_running >= maxConcurrent) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    final last = _lastStart;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      final wait = minInterval - elapsed;
      if (wait > Duration.zero) await Future.delayed(wait);
    }
    _running++;
    try {
      if (jitter > Duration.zero) {
        final j = Duration(
          milliseconds: _rnd.nextInt(max(1, jitter.inMilliseconds + 1)),
        );
        if (j > Duration.zero) await Future.delayed(j);
      }
      return await task();
    } finally {
      _lastStart = DateTime.now();
      _running--;
    }
  }
}
