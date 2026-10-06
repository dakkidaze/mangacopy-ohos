import 'dart:async';

import 'package:flutter/material.dart';

import '../api/copy_api_client.dart';
import '../api/copy_manga_api_source.dart';
import '../api/manga_source.dart';
import 'browse_source.dart';
import 'widgets.dart';

/// 登录态记录。
///
/// [MangaSource] 接口没有暴露「是否已登录」，而 [BrowseSource] 建的图源也没带
/// 持久化（[AuthStore] 为 null），所以登录态只活在内存里：这里记住最近一次
/// 登录结果，退出时清掉；启动时按图源里的 token 回填。
///
/// 判断依据只认 token（token 只有登录成功才会写入），不看 Cookie 罐——
/// 普通浏览请求也可能带回站点 Cookie，用它会误判成已登录。
class NativeSession extends ChangeNotifier {
  NativeSession._();

  static final NativeSession instance = NativeSession._();

  bool _loggedIn = false;

  /// 是否已登录。
  bool get loggedIn => _loggedIn;

  /// 登录成功的账号名，仅用于界面展示。
  String? _userName;

  String? get userName => _userName;

  /// 登录成功后调用。
  void markLoggedIn(String? user) {
    _loggedIn = true;
    _userName = user;
    notifyListeners();
  }

  /// 退出登录后调用。
  void markLoggedOut() {
    _loggedIn = false;
    _userName = null;
    notifyListeners();
  }

  /// 按图源当前 token 回填登录态，返回是否登录。
  ///
  /// 只在 token 非空时置为已登录；清过 session 的图源不会误判。
  bool sync(MangaSource? source) {
    final token = clientOf(source)?.token;
    if (token != null && token.isNotEmpty && !_loggedIn) {
      _loggedIn = true;
      notifyListeners();
    }
    return _loggedIn;
  }

  /// 取图源底层的 API 客户端（非 API 图源时为 null）。
  static CopyApiClient? clientOf(MangaSource? source) =>
      source is CopyMangaApiSource ? source.client : null;

  /// 退出登录：清掉 token 与 Cookie 罐，并重置界面状态。
  void signOut(MangaSource? source) {
    clientOf(source)?.clearSession();
    markLoggedOut();
  }
}

/// 未登录占位：一句提示 + 去登录按钮。
///
/// 收藏 / 历史页共用，避免两处各写一遍。
class NativeLoginRequiredView extends StatelessWidget {
  const NativeLoginRequiredView({
    super.key,
    this.text = '请先登录',
    this.hint = '登录后才能查看这里的内容',
    this.onRefresh,
  });

  final String text;
  final String hint;

  /// 登录页返回后调用，用于重新判断登录态。
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 44,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                await NativeAccountPage.open(context);
                onRefresh?.call();
              },
              icon: const Icon(Icons.login, size: 18),
              label: const Text('去登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 原生账号页：未登录显示登录表单，已登录显示状态 + 退出登录。
class NativeAccountPage extends StatefulWidget {
  const NativeAccountPage({super.key, this.source});

  /// 测试注入；为空时走 [BrowseSource.instance]。
  final MangaSource? source;

  /// 入口：压入路由。返回时表示用户已从该页退出。
  static Future<void> open(BuildContext context, {MangaSource? source}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => NativeAccountPage(source: source),
        ),
      );

  @override
  State<NativeAccountPage> createState() => _NativeAccountPageState();
}

class _NativeAccountPageState extends State<NativeAccountPage> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();

  MangaSource? _source;
  Object? _sourceError;

  bool _submitting = false;
  bool _obscure = true;

  /// 登录失败提示；为 null 时不显示。
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolveSource();
  }

  void _resolveSource() {
    final injected = widget.source;
    if (injected != null) {
      _source = injected;
      NativeSession.instance.sync(injected);
      return;
    }
    unawaited(
      BrowseSource.instance().then((v) {
        if (!mounted) return;
        setState(() {
          _source = v.source;
          NativeSession.instance.sync(v.source);
        });
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _sourceError = e);
      }),
    );
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final s = _source;
    if (s == null || _submitting) return;
    final user = _user.text.trim();
    final pass = _pass.text;
    if (user.isEmpty) {
      setState(() => _error = '请输入账号');
      return;
    }
    if (pass.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    String? message;
    try {
      final ok = await s.login(user, pass);
      if (ok) {
        NativeSession.instance.markLoggedIn(user);
      } else {
        message = '账号或密码错误';
      }
    } catch (e) {
      // 网络类错误：登录接口本身把业务错误吞成了 false，抛出来的都是连不上。
      message = '登录失败，请检查网络后重试';
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = message;
    });
    if (message == null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('登录成功')));
    }
  }

  Future<void> _signOut() async {
    final s = _source;
    if (s == null) return;
    final ok = await _confirmSignOut();
    if (!ok || !mounted) return;
    NativeSession.instance.signOut(s);
    _pass.clear();
    setState(() => _error = null);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已退出登录')));
  }

  Future<bool> _confirmSignOut() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新登录才能查看收藏和浏览历史。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final s = _source;
    if (s == null) return _sourceState(context);
    return ListenableBuilder(
      listenable: NativeSession.instance,
      builder: (context, _) => NativeSession.instance.loggedIn
          ? _SignedInPanel(onSignOut: _signOut)
          : _LoginPanel(
              user: _user,
              pass: _pass,
              obscure: _obscure,
              submitting: _submitting,
              error: _error,
              onToggleObscure: () => setState(() => _obscure = !_obscure),
              onSubmit: _submit,
            ),
    );
  }

  /// 图源还没就绪：选域中 / 选域失败可重试。
  Widget _sourceState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final err = _sourceError;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: err == null
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('正在选择线路…'),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 40, color: scheme.error),
                  const SizedBox(height: 12),
                  const Text('线路不可用'),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      setState(() => _sourceError = null);
                      _resolveSource();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 登录表单：账号 + 密码 + 登录按钮。
class _LoginPanel extends StatelessWidget {
  const _LoginPanel({
    required this.user,
    required this.pass,
    required this.obscure,
    required this.submitting,
    required this.error,
    required this.onToggleObscure,
    required this.onSubmit,
  });

  final TextEditingController user;
  final TextEditingController pass;
  final bool obscure;
  final bool submitting;
  final String? error;
  final VoidCallback onToggleObscure;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: CardEntrance(
            index: 0,
            child: Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.person_outline,
                            size: 22,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '登录拷贝漫画',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '登录后可以查看收藏和浏览历史',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: user,
                      enabled: !submitting,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '账号',
                        hintText: '用户名',
                        prefixIcon: Icon(Icons.account_circle_outlined),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pass,
                      enabled: !submitting,
                      obscureText: obscure,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => unawaited(onSubmit()),
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: obscure ? '显示密码' : '隐藏密码',
                          icon: Icon(
                            obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 20,
                          ),
                          onPressed: onToggleObscure,
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: error == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 16,
                                    color: scheme.error,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      error!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: submitting ? null : () => unawaited(onSubmit()),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: submitting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          : const Text('登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 已登录：状态卡 + 退出登录。
class _SignedInPanel extends StatelessWidget {
  const _SignedInPanel({required this.onSignOut});

  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = NativeSession.instance.userName;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: CardEntrance(
            index: 0,
            child: Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check,
                            size: 22,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '已登录',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (name != null && name.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '登录状态已保存在本机，关闭应用后无需重新登录。',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(onSignOut()),
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('退出登录'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        minimumSize: const Size.fromHeight(44),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
