import 'dart:async';

import 'package:flutter/material.dart';

import '../api/manga_source.dart';
import '../api/models.dart';
import 'browse_detail_page.dart';
import 'browse_paging.dart';
import 'browse_search_page.dart';
import 'browse_source.dart';
import 'widgets.dart';

/// 原生浏览首页：热门 / 最新 两个分段，网格展示，下拉刷新 + 滚动到底加载更多。
///
/// 替代 H5 的首页列表；进详情、章节、阅读都走 Dart 侧页面，不再依赖 WebView。
class BrowseHomePage extends StatefulWidget {
  const BrowseHomePage({super.key, this.source, this.initialTab = 0});

  /// 测试注入；为空时走 [BrowseSource.instance]。
  final MangaSource? source;

  /// 初始选中分段：0 热门，1 最新。
  final int initialTab;

  /// 入口：压入路由。
  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const BrowseHomePage()),
      );

  @override
  State<BrowseHomePage> createState() => _BrowseHomePageState();
}

class _BrowseHomePageState extends State<BrowseHomePage> {
  MangaSource? _source;
  Object? _sourceError;

  @override
  void initState() {
    super.initState();
    _resolveSource();
  }

  void _resolveSource() {
    final injected = widget.source;
    if (injected != null) {
      _source = injected;
      return;
    }
    unawaited(
      BrowseSource.instance().then((v) {
        if (!mounted) return;
        setState(() => _source = v.source);
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _sourceError = e);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final initial = widget.initialTab.clamp(0, BrowseTab.values.length - 1);
    return DefaultTabController(
      length: BrowseTab.values.length,
      initialIndex: initial,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('发现'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: () => unawaited(
                BrowseSearchPage.open(context, source: source),
              ),
            ),
          ],
          bottom: TabBar(
            tabs: BrowseTab.values
                .map((t) => Tab(text: t.label))
                .toList(growable: false),
          ),
        ),
        body: source == null
            ? _sourceWaitingView(context)
            : TabBarView(
                children: BrowseTab.values
                    .map((t) => BrowseGridList(tab: t, source: source))
                    .toList(growable: false),
              ),
      ),
    );
  }

  /// 图源就绪前的等待态；失败时给重试（多半是线路探测全挂）。
  Widget _sourceWaitingView(BuildContext context) {
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
                  const SizedBox(height: 6),
                  Text(
                    describeBrowseError(err),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
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

/// 首页分段。
enum BrowseTab { hot, latest }

/// 分段定义：标题 + 取哪路数据。
extension BrowseTabX on BrowseTab {
  String get label => switch (this) {
        BrowseTab.hot => '热门',
        BrowseTab.latest => '最新',
      };

  /// 对应的取数函数。
  BrowsePageFetcher<MangaSummary> fetcher(MangaSource s) => switch (this) {
        BrowseTab.hot => (offset) => s.popular(offset: offset),
        BrowseTab.latest => (offset) => s.latest(offset: offset),
      };

  /// 空态文案。
  String get emptyText => switch (this) {
        BrowseTab.hot => '暂时取不到热门漫画',
        BrowseTab.latest => '暂时没有最新更新',
      };
}

/// 网格列表：下拉刷新 + 滚动到底加载更多 + 加载/空/失败三态。
///
/// 用 [AutomaticKeepAliveClientMixin] 保住分段切换后的滚动位置。
class BrowseGridList extends StatefulWidget {
  const BrowseGridList({super.key, required this.tab, required this.source});

  final BrowseTab tab;
  final MangaSource source;

  @override
  State<BrowseGridList> createState() => _BrowseGridListState();
}

class _BrowseGridListState extends State<BrowseGridList>
    with AutomaticKeepAliveClientMixin {
  late BrowsePagingController<MangaSummary> _paging;
  final ScrollController _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  static const double _preloadExtent = 240;

  @override
  void initState() {
    super.initState();
    _paging = BrowsePagingController<MangaSummary>(
      fetcher: widget.tab.fetcher(widget.source),
    )..addListener(_onPagingChanged);
    _scroll.addListener(_onScroll);
    unawaited(_paging.refresh());
  }

  @override
  void didUpdateWidget(covariant BrowseGridList old) {
    super.didUpdateWidget(old);
    if (old.source == widget.source && old.tab == widget.tab) return;
    final prev = _paging;
    _paging = BrowsePagingController<MangaSummary>(
      fetcher: widget.tab.fetcher(widget.source),
    )..addListener(_onPagingChanged);
    prev
      ..removeListener(_onPagingChanged)
      ..dispose();
    unawaited(_paging.refresh());
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

  Future<void> _onRefresh() => _paging.refresh();

  /// 列数：窄屏 2 列，宽屏按宽度递增，最多 5 列。
  static int columnsFor(double width) {
    if (width >= 1000) return 5;
    if (width >= 760) return 4;
    if (width >= 520) return 3;
    return 2;
  }

  Future<void> _openDetail(MangaSummary item) =>
      BrowseDetailPage.open(context, comicId: item.id, source: widget.source);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final status = _paging.status;
    return BrowseStateView(
      status: status,
      error: _paging.error,
      onRetry: _onRefresh,
      emptyIcon: Icons.menu_book_outlined,
      emptyText: widget.tab.emptyText,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = columnsFor(constraints.maxWidth);
          return RefreshIndicator(
            onRefresh: _onRefresh,
            child: CustomScrollView(
              key: PageStorageKey<String>('browse-grid-${widget.tab.label}'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final item = _paging.items[i];
                        return MangaGridCard(
                          key: ValueKey<String>('browse-card-${item.id}'),
                          title: item.title,
                          author: item.author,
                          cover: item.cover,
                          // 首屏错开淡入；后续分页不再有动画。
                          animated: i < CardEntrance.maxStagger,
                          index: i,
                          onTap: () => unawaited(_openDetail(item)),
                        );
                      },
                      childCount: _paging.items.length,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.62,
                    ),
                  ),
                ),
                // 分页尾部：加载中 / 到底 / 失败重试。
                SliverToBoxAdapter(
                  child: BrowsePagingFooter(controller: _paging),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],
            ),
          );
        },
      ),
    );
  }
}
