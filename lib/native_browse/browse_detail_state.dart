import 'package:flutter/foundation.dart';

import '../api/manga_source.dart';
import '../api/models.dart';

/// 详情页的两块数据各自独立的状态：详情与章节。
///
/// 拆开是为了「章节加载失败」不要连坐已经显示出来的详情头图与简介。
/// 两者都是 [ValueNotifier]，界面用 [ValueListenableBuilder] 局部刷新。

/// 详情状态。
class DetailState {
  const DetailState({
    this.detail,
    this.error,
    this.loading = false,
    this.loadedOnce = false,
  });

  final MangaDetail? detail;
  final Object? error;
  final bool loading;

  /// 至少成功返回过一次（或已确认失败），用于区分首屏骨架与刷新。
  final bool loadedOnce;

  DetailState copyWith({
    MangaDetail? detail,
    Object? error,
    bool clearError = false,
    bool? loading,
    bool? loadedOnce,
  }) =>
      DetailState(
        detail: detail ?? this.detail,
        error: clearError ? null : (error ?? this.error),
        loading: loading ?? this.loading,
        loadedOnce: loadedOnce ?? this.loadedOnce,
      );
}

/// 详情加载器：一次请求，失败保留上一份数据（如果有）。
class DetailLoader extends ValueNotifier<DetailState> {
  DetailLoader({required this.comicId}) : super(const DetailState());

  final String comicId;

  MangaSource? _source;
  bool _busy = false;

  bool get loading => value.loading;
  Object? get error => value.error;
  MangaDetail? get detail => value.detail;

  void attach(MangaSource source) => _source = source;

  Future<void> load() async {
    final s = _source;
    if (s == null || _busy) return;
    _busy = true;
    value = value.copyWith(loading: true, clearError: true);
    try {
      final d = await s.detail(comicId);
      _busy = false;
      value = DetailState(detail: d, loadedOnce: true);
    } catch (e) {
      _busy = false;
      value = value.copyWith(error: e, loading: false, loadedOnce: true);
    }
  }
}

/// 章节状态。
class ChapterState {
  const ChapterState({
    this.chapters = const <Chapter>[],
    this.error,
    this.loading = false,
  });

  final List<Chapter> chapters;
  final Object? error;
  final bool loading;
}

/// 章节加载器：一次取全量（站点单页 500 条足够），失败只影响章节区。
class ChapterLoader extends ValueNotifier<ChapterState> {
  ChapterLoader({required this.comicId, this.group})
    : super(const ChapterState());

  final String comicId;
  final String? group;

  MangaSource? _source;
  bool _busy = false;

  bool get loading => value.loading;
  Object? get error => value.error;
  List<Chapter> get chapters => value.chapters;

  void attach(MangaSource source) => _source = source;

  Future<void> load() async {
    final s = _source;
    if (s == null || _busy) return;
    _busy = true;
    value = ChapterState(chapters: value.chapters, loading: true);
    try {
      final list = await s.chapters(comicId, group: group);
      _busy = false;
      value = ChapterState(chapters: list);
    } catch (e) {
      _busy = false;
      value = ChapterState(chapters: value.chapters, error: e);
    }
  }
}
