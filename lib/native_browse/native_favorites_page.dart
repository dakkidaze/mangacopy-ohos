import 'dart:async';

import 'package:flutter/material.dart';

import '../api/manga_source.dart';
import '../api/models.dart';
import 'browse_detail_page.dart';
import 'browse_paging.dart';
import 'browse_source.dart';
import 'native_account_page.dart';
import 'widgets.dart';

/// 原生收藏页：登录后才取书架，未登录给「去登录」。
///
/// 内容按网格排布，和历史页的列表行区分开。
class NativeFavoritesPage extends StatefulWidget {
  const NativeFavoritesPage({super.key, this.source});

  /// 测试注入；为空时走 [BrowseSource.instance]。
  final MangaSource? source;

  /// 入口：压入路由。
  static Future<void> open(BuildContext context, {MangaSource? source}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => NativeFavoritesPage(source: source),
        ),
      );

  @override
  State<NativeFavoritesPage> createState() => _NativeFavoritesPageState();
}

class _NativeFavoritesPageState extends State<NativeFavoritesPage> {
  final ScrollController _scroll = ScrollController();

  MangaSource? _source;
  Object? _sourceError;

  late BrowsePagingController<MangaSummary> _paging;

  static const double _preloadExtent = 240;

  @override
  void initState() {
    super.initState();
    // 收藏接口按 30 条一页，和全站列表的 21 条不同。
    _paging = BrowsePagingController<MangaSummary>(
      fetcher: _fetch,
      pageSize: 30,
    )..addListener(_onPagingChanged);
    _scroll.addListener(_onScroll);
    _resolveSource();
  }

  void _resolveSource() {
    final injected = widget.source;
    if (injected != null) {
      _source = injected;
      NativeSession.instance.sync(injected);
      _refreshIfLoggedIn();
      return;
    }
    unawaited(
      BrowseSource.instance().then((v) {
        if (!mounted) return;
        setState(() {
          _source = v.source;
          NativeSession.instance.sync(v.source);
        });
        _refreshIfLoggedIn();
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _sourceError = e);
      }),
    );
  }

  /// 已登录才取数：未登录时留在占位页，避免打一次必然失败的请求。
  void _refreshIfLoggedIn() {
    if (NativeSession.instance.loggedIn) unawaited(_paging.refresh());
  }

  void _onPagingChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter > _preloadExtent) return;
    unawaited(_paging.loadMore());
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _paging
      ..removeListener(_onPagingChanged)
      ..dispose();
    super.dispose();
  }

  Future<List<MangaSummary>> _fetch(int offset) {
    final s = _source;
    if (s == null) return Future<List<MangaSummary>>.value(const <MangaSummary>[]);
    return s.favorites(offset: offset);
  }

  /// 从登录页返回后调用：登录成功就补一次刷新。
  void _onBackFromLogin() {
    if (!NativeSession.instance.loggedIn) return;
    unawaited(_paging.refresh());
  }

  Future<void> _openDetail(MangaSummary item) => BrowseDetailPage.open(
        context,
        comicId: item.id,
        source: _source,
        summary: item,
      );

  /// 列数：窄屏 2 列，宽屏按宽度递增，最多 5 列。
  static int columnsFor(double width) {
    if (width >= 1000) return 5;
    if (width >= 760) return 4;
    if (width >= 520) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的收藏')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final s = _source;
    if (s == null) return _sourceState(context);
    return ListenableBuilder(
      listenable: NativeSession.instance,
      builder: (context, _) {
        if (!NativeSession.instance.loggedIn) {
          return NativeLoginRequiredView(
            text: '请先登录',
            hint: '登录后才能查看收藏',
            onRefresh: _onBackFromLogin,
          );
        }
        return BrowseStateView(
          status: _paging.status,
          error: _paging.error,
          onRetry: _paging.refresh,
          emptyIcon: Icons.bookmark_added_outlined,
          emptyText: '还没有收藏',
          child: RefreshIndicator(
            onRefresh: _paging.refresh,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = columnsFor(constraints.maxWidth);
                return CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                      sliver: SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => Padding(
                            padding: const EdgeInsets.all(4),
                            child: MangaGridCard(
                              key: ValueKey<String>('fav-${_paging.items[i].id}'),
                              index: i,
                              animated: i < CardEntrance.maxStagger,
                              title: _paging.items[i].title,
                              author: _paging.items[i].author,
                              cover: _paging.items[i].cover,
                              onTap: () => unawaited(_openDetail(_paging.items[i])),
                            ),
                          ),
                          childCount: _paging.items.length,
                        ),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          childAspectRatio: 3 / 4.9,
                          crossAxisSpacing: 0,
                          mainAxisSpacing: 0,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: BrowsePagingFooter(controller: _paging),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
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
