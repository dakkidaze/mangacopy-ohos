import 'dart:async';

import 'package:flutter/material.dart';

import '../api/manga_source.dart';
import '../api/models.dart';
import 'browse_detail_page.dart';
import 'browse_paging.dart';
import 'browse_source.dart';
import 'widgets.dart';

/// 原生搜索页：搜索框 + 结果列表 + 筛选（排序 / 地区 / 收费状态）。
///
/// 无关键词时「筛选」直接列全站漫画；有关键词时优先走搜索接口，
/// 一旦选了筛选条件就改用筛选接口（站点搜索接口不支持这几个参数）。
class BrowseSearchPage extends StatefulWidget {
  const BrowseSearchPage({super.key, this.source, this.initialQuery = ''});

  final MangaSource? source;

  /// 从别处带进来的初始关键词。
  final String initialQuery;

  /// 入口：压入路由。
  static Future<void> open(BuildContext context, {MangaSource? source}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BrowseSearchPage(source: source),
        ),
      );

  @override
  State<BrowseSearchPage> createState() => _BrowseSearchPageState();
}

class _BrowseSearchPageState extends State<BrowseSearchPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  MangaSource? _source;
  Object? _sourceError;

  late BrowsePagingController<MangaSummary> _paging;

  /// 已提交并生效的关键词（空串表示只按筛选浏览）。
  String _query = '';

  /// 是否展开筛选面板。
  bool _filtersOpen = false;

  /// 筛选条件：全为 null 即「全部」。
  String? _ordering;
  String? _region;
  String? _freeType;

  static const double _preloadExtent = 240;

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialQuery;
    _query = widget.initialQuery.trim();
    _paging = BrowsePagingController<MangaSummary>(fetcher: _fetch)
      ..addListener(_onPagingChanged);
    _scroll.addListener(_onScroll);
    _resolveSource();
  }

  void _resolveSource() {
    final injected = widget.source;
    if (injected != null) {
      _source = injected;
      // 无关键词也要刷新：此时是「按筛选浏览全站」。
      unawaited(_paging.refresh());
      return;
    }
    unawaited(
      BrowseSource.instance().then((v) {
        if (!mounted) return;
        setState(() => _source = v.source);
        unawaited(_paging.refresh());
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _sourceError = e);
      }),
    );
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
    _input.dispose();
    _focus.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _paging
      ..removeListener(_onPagingChanged)
      ..dispose();
    super.dispose();
  }

  bool get _hasFilters => _ordering != null || _region != null || _freeType != null;

  /// 当前取数：有筛选条件或没关键词 → 筛选接口；否则搜索接口。
  Future<List<MangaSummary>> _fetch(int offset) {
    final s = _source;
    if (s == null) return Future<List<MangaSummary>>.value(const <MangaSummary>[]);
    if (_query.isEmpty || _hasFilters) {
      return s.filter(
        ordering: _ordering,
        region: _region,
        freeType: _freeType,
        offset: offset,
      );
    }
    return s.search(_query, offset: offset);
  }

  void _submit(String value) {
    final q = value.trim();
    if (q == _query) {
      _focus.unfocus();
      return;
    }
    setState(() {
      _query = q;
      // 换关键词时清掉筛选，避免结果对不上。
      _ordering = null;
      _region = null;
      _freeType = null;
      _filtersOpen = false;
    });
    _focus.unfocus();
    unawaited(_paging.refresh());
  }

  void _clear() {
    _input.clear();
    _submit('');
  }

  void _setOrdering(String? v) => _apply(() => _ordering = v);
  void _setRegion(String? v) => _apply(() => _region = v);
  void _setFreeType(String? v) => _apply(() => _freeType = v);

  void _apply(void Function() set) {
    setState(set);
    unawaited(_paging.refresh());
  }

  void _resetFilters() {
    setState(() {
      _ordering = null;
      _region = null;
      _freeType = null;
    });
    unawaited(_paging.refresh());
  }

  Future<void> _openDetail(MangaSummary item) => BrowseDetailPage.open(
        context,
        comicId: item.id,
        source: _source,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _SearchField(
          controller: _input,
          focusNode: _focus,
          onSubmitted: _submit,
          onClear: _clear,
        ),
        actions: [
          IconButton(
            tooltip: _filtersOpen ? '收起筛选' : '筛选',
            icon: Badge(
              isLabelVisible: _hasFilters,
              child: Icon(_filtersOpen ? Icons.filter_alt : Icons.filter_alt_outlined),
            ),
            onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
          ),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _filtersOpen
                ? _FilterPanel(
                    ordering: _ordering,
                    region: _region,
                    freeType: _freeType,
                    onOrdering: _setOrdering,
                    onRegion: _setRegion,
                    onFreeType: _setFreeType,
                    onReset: _resetFilters,
                  )
                : const SizedBox.shrink(),
          ),
          if (_filtersOpen)
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_source == null) {
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
    return BrowseStateView(
      status: _paging.status,
      error: _paging.error,
      onRetry: _paging.refresh,
      emptyIcon: _query.isEmpty ? Icons.explore_outlined : Icons.search_off,
      emptyText: _query.isEmpty
          ? '没有符合条件的漫画\n换个筛选条件试试'
          : '没有找到「$_query」\n换个关键词或放宽筛选条件',
      child: RefreshIndicator(
        onRefresh: _paging.refresh,
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          itemCount: _paging.items.length + 1,
          itemBuilder: (context, i) {
            if (i == _paging.items.length) {
              return BrowsePagingFooter(controller: _paging);
            }
            final item = _paging.items[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: MangaListRow(
                key: ValueKey<String>('search-row-${item.id}'),
                title: item.title,
                author: item.author,
                cover: item.cover,
                onTap: () => unawaited(_openDetail(item)),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 顶部搜索框：回车提交 + 一键清空。
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        onSubmitted: onSubmitted,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          hintText: '搜索漫画名或作者',
          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          contentPadding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          prefixIcon: const Icon(Icons.search, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 38,
            minHeight: 36,
          ),
          suffixIcon: IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 32,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// 筛选面板：三组单选标签 + 重置。
class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.ordering,
    required this.region,
    required this.freeType,
    required this.onOrdering,
    required this.onRegion,
    required this.onFreeType,
    required this.onReset,
  });

  final String? ordering;
  final String? region;
  final String? freeType;
  final ValueChanged<String?> onOrdering;
  final ValueChanged<String?> onRegion;
  final ValueChanged<String?> onFreeType;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BrowseOptionChips<String>(
          label: '排序',
          options: BrowseFilterOptions.ordering,
          selected: ordering,
          onChanged: onOrdering,
        ),
        BrowseOptionChips<String>(
          label: '地区',
          options: BrowseFilterOptions.region,
          selected: region,
          onChanged: onRegion,
        ),
        BrowseOptionChips<String>(
          label: '收费',
          options: BrowseFilterOptions.freeType,
          selected: freeType,
          onChanged: onFreeType,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 12, 8),
            child: TextButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('重置筛选'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 筛选候选值：值为 null 表示「全部」（接口侧不传该参数）。
///
/// 取值来自站点 /api/v3/comics 实际接受的枚举：
/// `ordering` 为排序字段，前缀 `-` 表示倒序；`top` 为地区/完结分类；
/// `free_type` 为收费类型（1 免费、2 付费、3 等）。
class BrowseFilterOptions {
  const BrowseFilterOptions._();

  static const List<BrowseOption<String>> ordering = [
    BrowseOption<String>('全部', null),
    BrowseOption<String>('最近更新', '-datetime_updated'),
    BrowseOption<String>('最早更新', 'datetime_updated'),
    BrowseOption<String>('最热门', '-popular'),
    BrowseOption<String>('最少热度', 'popular'),
  ];

  static const List<BrowseOption<String>> region = [
    BrowseOption<String>('全部', null),
    BrowseOption<String>('日漫', 'japan'),
    BrowseOption<String>('韩漫', 'korea'),
    BrowseOption<String>('美漫', 'america'),
    BrowseOption<String>('国漫', 'cn'),
    BrowseOption<String>('已完结', 'finish'),
  ];

  static const List<BrowseOption<String>> freeType = [
    BrowseOption<String>('全部', null),
    BrowseOption<String>('免费', '1'),
    BrowseOption<String>('付费', '2'),
    BrowseOption<String>('等就免费', '3'),
  ];
}
