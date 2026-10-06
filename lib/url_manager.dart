import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 多域名测速与缓存，对应原生版 UrlManager.kt。
///
/// - 手动模式（manual_url）优先，测速不改 activeUrl。
/// - 自动模式：首次测速选最快并缓存；之后**忠诚**已选源，仅在失效或明显过慢时切换。
/// - 过慢判定：当前源在有效结果中排倒数 2 名，且相对最快慢 ≥1s **或** ≥2 倍。
/// - 测速校验页面正文，防止过期域名停靠页赢得测速。
class UrlManager {
  static const candidates = [
    'https://www.copy3000.com',
    'https://www.2026copy.com',
    'https://www.copy4000.com',
    'https://www.mangacopy.com',
  ];

  /// 相对最快延迟达到该毫秒数，才可能因「过慢」换源（还需满足倒数 2 名）。
  static const slowAbsoluteMs = 1000;

  /// 相对最快达到该倍数，才可能因「过慢」换源（还需满足倒数 2 名）。
  static const slowRatio = 2;

  static List<String> get allowedPrefixes => [
    ...candidates,
    ...candidates.map((u) => u.replaceFirst('://www.', '://')),
  ];

  static String activeUrl = candidates[0];
  static bool manualMode = false;

  /// 启动时若所有源都不可用则为 true（引导离线阅读）
  static bool allSourcesDown = false;

  static String get comicDetailUrl => '$activeUrl/comic';

  /// 是否已有可用的缓存/手动源（有则启动不必等网络）
  static bool hasCachedUrl = false;

  /// 最近一次 probe 的说明（设置页「重新测速」展示）
  static String lastProbeNote = '';

  /// 手机版章节 URL 转 PC 版（供隐藏 WebView 收图）
  static String toPcUrl(String mobileUrl) {
    if (!mobileUrl.contains('/comicContent/')) return '';
    final rest = mobileUrl.split('comicContent/')[1];
    final slug = rest.split('/')[0];
    final uuid = mobileUrl.substring(mobileUrl.lastIndexOf('/') + 1);
    return '$comicDetailUrl/$slug/chapter/$uuid';
  }

  /// 详情页/章节页 URL 统一转 PC 版
  static String toHiddenUrl(String url) {
    if (url.contains('/details/comic/')) {
      final after = url.substring(
        url.indexOf('/details/comic/') + '/details/comic'.length,
      );
      return '$comicDetailUrl$after';
    }
    if (url.contains('/comicContent/')) return toPcUrl(url);
    return '';
  }

  /// 任意源的章节 URL 换到当前源（下载列表里存的 URL 可能来自旧源）
  static String rehost(String url) {
    for (final p in allowedPrefixes) {
      if (url.startsWith(p)) {
        return activeUrl + url.substring(p.length);
      }
    }
    return url;
  }

  /// 校验域名确实是拷贝漫画站点并测量耗时；无效返回 null
  static Future<int?> _validate(String url) async {
    final sw = Stopwatch()..start();
    try {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final body = resp.body;
      final isCopyManga =
          body.contains('拷貝漫畫') ||
          body.contains('拷贝漫画') ||
          body.contains('copymanga');
      return isCopyManga ? sw.elapsedMilliseconds : null;
    } catch (_) {
      return null;
    }
  }

  /// 仅读本地缓存，不访问网络。对应原生版 UrlManager.init + hasCachedUrl。
  /// 返回是否已有缓存/手动源（有则主页可立刻加载，测速放到后台）。
  static Future<bool> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final manual = prefs.getString('manual_url');
    if (manual != null && candidates.contains(manual)) {
      manualMode = true;
      activeUrl = manual;
      hasCachedUrl = true;
      return true;
    }
    final cached = prefs.getString('active_url');
    if (cached != null && candidates.contains(cached)) {
      activeUrl = cached;
      hasCachedUrl = true;
      return true;
    }
    hasCachedUrl = false;
    return false;
  }

  /// 手动指定源站
  static Future<void> setManualUrl(String url) async {
    manualMode = true;
    activeUrl = url;
    hasCachedUrl = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('manual_url', url);
  }

  /// 恢复自动选源并立即测速
  static Future<String> clearManualUrl() async {
    manualMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('manual_url');
    return probe();
  }

  /// 当前源是否因「过慢」应换掉。
  /// [validSorted] 按耗时升序；[preferredIdx] 为当前源在其中的下标。
  static bool shouldSwitchForSlow(
    List<MapEntry<String, int>> validSorted,
    int preferredIdx,
  ) {
    if (validSorted.length < 2) return false;
    // 倒数 2 名：下标 >= length - 2
    if (preferredIdx < validSorted.length - 2) return false;

    final currentMs = validSorted[preferredIdx].value;
    final bestMs = validSorted.first.value;
    if (bestMs <= 0) return false;

    // 绝对延时超过 4 秒，强制换源
    if (currentMs > 4000) return true;

    final slowerByMs = currentMs - bestMs;
    final thriceOrMore = currentMs >= bestMs * slowRatio;
    return slowerByMs >= slowAbsoluteMs && thriceOrMore;
  }

  /// 并发校验全部候选。
  /// 手动模式：不改 activeUrl。
  /// 自动模式：首次选最快；之后保持已选源，仅失效或明显过慢时换到最快。
  static Future<String> probe() async {
    final results = await Future.wait(
      candidates.map((url) async => MapEntry(url, await _validate(url))),
    );
    final valid =
        results
            .where((e) => e.value != null)
            .map((e) => MapEntry(e.key, e.value!))
            .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    allSourcesDown = valid.isEmpty;

    if (manualMode) {
      lastProbeNote = valid.isEmpty
          ? '全部源不可用；手动模式仍使用 $activeUrl'
          : '最快 ${valid.first.key}（${valid.first.value}ms）；手动模式仍使用 $activeUrl';
      return activeUrl;
    }

    if (valid.isEmpty) {
      lastProbeNote = '全部源不可用';
      return activeUrl;
    }

    final best = valid.first;
    final prefs = await SharedPreferences.getInstance();

    // 首次无缓存：选最快
    if (!hasCachedUrl) {
      activeUrl = best.key;
      hasCachedUrl = true;
      await prefs.setString('active_url', activeUrl);
      lastProbeNote = '首次选源：${best.key}（${best.value}ms）';
      return activeUrl;
    }

    final preferredIdx = valid.indexWhere((e) => e.key == activeUrl);

    // 当前源失效 → 换最快
    if (preferredIdx < 0) {
      final prev = activeUrl;
      activeUrl = best.key;
      await prefs.setString('active_url', activeUrl);
      lastProbeNote = '原源站失效（$prev），已切换至 ${best.key}（${best.value}ms）';
      return activeUrl;
    }

    // 有效但过慢（倒数 2 + 慢 2.5s 且 3 倍）→ 换最快
    if (shouldSwitchForSlow(valid, preferredIdx)) {
      final prev = activeUrl;
      final prevMs = valid[preferredIdx].value;
      activeUrl = best.key;
      await prefs.setString('active_url', activeUrl);
      lastProbeNote =
          '原源站过慢（$prev ${prevMs}ms），已切换至 ${best.key}（${best.value}ms）';
      return activeUrl;
    }

    // 忠诚保持
    final curMs = valid[preferredIdx].value;
    lastProbeNote = curMs == best.value
        ? '保持当前源站 $activeUrl（${curMs}ms，仍为最快）'
        : '保持当前源站 $activeUrl（${curMs}ms；最快 ${best.key} ${best.value}ms）';
    await prefs.setString('active_url', activeUrl);
    return activeUrl;
  }
}
