import 'package:flutter/foundation.dart';

/// 每页条数：站点列表接口按 21 条一页，`offset` 直接累加。
const int kBrowsePageSize = 21;

/// 首屏加载状态。
enum BrowseStatus {
  /// 正在加载（首屏或下拉刷新）。
  loading,

  /// 加载成功但一条都没有。
  empty,

  /// 加载失败，可重试。
  error,

  /// 有内容。
  ready,
}

/// 分页取数：传入 offset，返回该页数据。
typedef BrowsePageFetcher<T> = Future<List<T>> Function(int offset);

/// 列表分页控制器：管理首屏三态 + 滚动加载更多。
///
/// 只做状态与数据，不含任何 Widget，便于单测。
class BrowsePagingController<T> extends ChangeNotifier {
  BrowsePagingController({required this.fetcher, this.pageSize = kBrowsePageSize});

  final BrowsePageFetcher<T> fetcher;
  final int pageSize;

  /// 已加载的数据。
  final List<T> items = <T>[];

  BrowseStatus _status = BrowseStatus.loading;

  BrowseStatus get status => _status;

  Object? _error;

  /// 最近一次失败原因，供界面展示。
  Object? get error => _error;

  bool _loadingMore = false;

  /// 是否正在加载下一页。
  bool get loadingMore => _loadingMore;

  bool _loadMoreFailed = false;

  /// 加载下一页是否失败（保留已加载数据，底部给重试入口）。
  bool get loadMoreFailed => _loadMoreFailed;

  bool _hasMore = true;

  /// 是否还有下一页：本页不足 [pageSize] 条即认为到底。
  bool get hasMore => _hasMore;

  bool _busy = false;

  /// 重新加载第一页（下拉刷新 / 首屏 / 失败重试）。
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    _status = BrowseStatus.loading;
    _error = null;
    _loadMoreFailed = false;
    _hasMore = true;
    notifyListeners();
    try {
      final list = await fetcher(0);
      items
        ..clear()
        ..addAll(list);
      _hasMore = list.length >= pageSize;
      _status = items.isEmpty ? BrowseStatus.empty : BrowseStatus.ready;
    } catch (e) {
      _error = e;
      _status = BrowseStatus.error;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 加载下一页；不满足条件时直接返回（避免重复触发）。
  Future<void> loadMore() async {
    if (_busy || _loadingMore || !_hasMore || _status != BrowseStatus.ready) {
      return;
    }
    _loadingMore = true;
    _loadMoreFailed = false;
    notifyListeners();
    try {
      final list = await fetcher(items.length);
      items.addAll(list);
      _hasMore = list.length >= pageSize;
      _loadMoreFailed = false;
    } catch (e) {
      _error = e;
      _loadMoreFailed = true;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 底部「加载失败，点击重试」用。
  Future<void> retryLoadMore() => loadMore();
}

/// 错误文案：只保留用户看得懂的一句。
String describeBrowseError(Object? e) {
  if (e == null) return '加载失败';
  final s = e.toString().trim();
  final cut = s.length > 80 ? '${s.substring(0, 80)}…' : s;
  return cut.isEmpty ? '加载失败' : cut;
}
