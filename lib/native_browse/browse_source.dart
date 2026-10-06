import '../api/api_domain_manager.dart';
import '../api/auth_store.dart';
import '../api/copy_api_client.dart';
import '../api/copy_manga_api_source.dart';
import '../api/manga_source.dart';

/// 原生浏览界面共用的图源。
///
/// 懒创建：真正打开浏览页才建 `http.Client`；选域（network4 引导 + 探测）
/// 只做一次，之后的列表/详情/章节请求都复用同一实例。
class BrowseSource {
  BrowseSource._(this.source, this.domains);

  /// 供浏览界面使用的图源实例。
  final MangaSource source;

  /// 域名管理器，供调试或后续替换使用。
  final ApiDomainManager domains;

  static BrowseSource? _instance;
  static Future<void>? _preparing;

  /// 已有实例直接返回；否则先选域再返回。
  ///
  /// 选域失败不抛错，沿用默认域（后续请求会带着它试一次）。
  static Future<BrowseSource> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final inflight = _preparing;
    if (inflight != null) {
      await inflight;
      return _instance!;
    }
    final future = _prepare();
    _preparing = future;
    try {
      await future;
    } finally {
      _preparing = null;
    }
    return _instance!;
  }

  /// 测试注入：替换全局实例（传入 null 恢复自动创建）。
  static void setForTest(BrowseSource? value) => _instance = value;

  static Future<void> _prepare() async {
    final domains = ApiDomainManager();
    await _bootstrap(domains);
    // 接入 AuthStore：首次启动载入已保存的 token，登录后自动落盘。
    final auth = AuthStore();
    await auth.load();
    final client = CopyApiClient(domains: domains, token: auth.token)
      ..restoreCookies(auth.cookies);
    _instance = BrowseSource._(CopyMangaApiSource(client, auth: auth), domains);
  }

  static Future<void> _bootstrap(ApiDomainManager domains) async {
    try {
      final boot = await domains.bootstrapFromNetwork4(domains.active);
      if (boot != null && boot.isNotEmpty) domains.active = boot;
    } catch (_) {
      // 引导失败不致命，继续用默认域。
    }
    try {
      await domains.probeBest();
    } catch (_) {
      // 同上。
    }
  }
}
