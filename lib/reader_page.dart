import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chapter_data.dart';
import 'chapter_edge_fsm.dart';
import 'chapter_edge_guard.dart';
import 'comment_page.dart';
import 'comment_sheet.dart';
import 'downloader.dart';
import 'frame_safe_rebuild.dart';
import 'image_cache_store.dart';
import 'image_intrinsic_size.dart';
import 'reader_gesture_config.dart';
import 'reader_gesture_debug.dart';
import 'reader_reading_direction.dart';
import 'reader_tap_zones.dart';
import 'retry_image.dart';
import 'settings.dart';
import 'system_ui.dart';
import 'volume_keys.dart';
import 'webtoon_aspect_cache.dart';
import 'webtoon_reading_progress.dart';
import 'zoomable_reader_image.dart';
import 'zoomable_webtoon_view.dart';

/// 全屏漫画阅读器：横/纵/条漫三模式、点击分区翻页、原地切章、断点续读、80% 预取、
/// 翻页到头再翻/再按切章、音量键翻页、页码跳转、时间/网络信息栏。
/// 对应原生版 ViewMangaActivity。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.dataNotifier,
    required this.loadingText,
    this.onRequestChapter,
    this.onPrefetch,
    this.onClose,
  });

  final ValueNotifier<ChapterData> dataNotifier;
  final ValueNotifier<String?> loadingText;

  /// [goNext] 为相邻切章方向；离线本地切换可不传。
  /// 诊断字段仅 debug 构建由阅读器传入，BrowserPage 可忽略。
  final void Function(
    String mobileUrl, {
    bool? goNext,
    int? chapterRequestId,
    String? readerInstanceId,
    String? inputSource,
    String? triggeringGestureSessionId,
  })?
  onRequestChapter;
  final void Function(String mobileUrl)? onPrefetch;

  /// 嵌在 BrowserPage Stack 时由外层关闭；走 Navigator.push 时可空（系统返回）
  final VoidCallback? onClose;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  late ChapterData _data;

  // 全生命周期单例：切章/切模式复用同一个控制器。
  // 若每章新建并 dispose 旧的，旧控制器在 PageView 下一帧解绑前仍被引用，会触发
  // "used after being disposed" 崩溃。
  final PageController _pageController = PageController();
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();

  int _page = 1; // 1-based
  bool _barsVisible = false;
  String _readMode = AppSettings.readMode;
  bool _r2l = AppSettings.r2l;
  bool _prefetchRequested = false;
  bool _downloading = false;
  String _downloadProgress = '';

  // 翻页到头再翻/再按切章（对应原生版 isEndL/isEndR + doubleTapToast）
  final _edgeGuard = ChapterEdgeGuard();
  final _edgeGate = EdgeGestureGate();
  final _edgeFsm = ChapterEdgeFsm();
  Timer? _edgeArmedTimer;

  /// 横/纵模式下当前页已放大：锁定 PageView，把拖动手势留给缩放平移
  bool _pageZoomed = false;

  /// 双指按下时立刻锁翻页，避免捏合起步被 PageView 抢走（体感「不灵敏」）
  /// value 为该 pointer 最近一次 down/move/up 时间；超时未更新视为幽灵 id。
  final Map<int, DateTime> _activePointers = {};
  bool _multiTouch = false;
  static const _pointerStaleMs = 1000;

  // 正式路径：独立 swipe 几何累计（不依赖 OverscrollNotification）
  Offset? _gestureStartPos;
  Offset _gestureTotalDelta = Offset.zero;
  DateTime? _gestureStartAt;
  String? _gestureSessionId;
  bool _gestureCancelled = false;
  bool _gestureSawMultiTouch = false;
  int _gestureStartPage = 1;
  final Set<String> _edgeAuxConsumedSessions = {};

  // gestureSessionId 序列号：与 ReaderGestureDiagnostics 解耦，release 包中同样有效。
  // ReaderGestureDiagnostics.currentGestureSessionId() 仅在 kDebugMode=true 时返回
  // 非 null 值；在 release 包中始终为 null，导致 ChapterEdgeFsm 的
  // sameGestureSessionAsArm 去重完全失效（Android APK bug 根因）。
  static int _gestureSeq = 0;
  static String _newGestureSessionId() => 'gs-${++_gestureSeq}';

  // 信息栏时钟
  Timer? _clockTimer;
  String _clockText = '';

  // 切章代数：丢弃过期的断点恢复/跳页回调，防止快速连切时旧章恢复落到新章上
  int _chapterGen = 0;

  /// 本章打开后用户是否已经手动滑动过。
  /// 断点续读要 await SharedPreferences，慢机上可能几百毫秒；期间用户已经开始读了，
  /// 此时再 _jumpTo(saved) 会把人凭空甩走一大段。已交互就放弃跳转，只保留提示。
  bool _userScrolledThisChapter = false;

  /// 条漫宽高比更新的重建调度，见 [_onWebtoonImageSize]。
  final _webtoonRebuild = FrameSafeRebuild();

  final _diag = ReaderGestureDiagnostics.instance;
  late final String _readerInstanceId;
  String _chapterDiagToken = 'none';
  bool _lastPhysicsLocked = false;

  bool get _useFormalEdge => useFormalReaderGestureRouting;

  int get _count => _data.imgUrls.length;
  bool get _isWebtoon => _readMode == 'w';

  /// 是否在阅读序列末尾追加一张「吐槽」虚拟页。
  bool get _showCommentPage =>
      AppSettings.chapterEndComments && _data.uuid.isNotEmpty && !_data.isLoading;

  /// 阅读序列总页数（图片页 + 可能的吐槽页）。
  int get _pageCount => _count + (_showCommentPage ? 1 : 0);

  /// 当前是否停在吐槽页。
  bool get _onCommentPage => _showCommentPage && _page > _count;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readerInstanceId = ReaderGestureDiagnostics.newReaderInstanceId();
    _chapterDiagToken = ReaderGestureDiagnostics.newChapterDiagToken();
    if (ReaderGestureDiagnostics.enabled) {
      _diag.attachReader(_readerInstanceId);
    }
    _data = widget.dataNotifier.value;
    widget.dataNotifier.addListener(_onChapterChanged);
    _itemPositionsListener.itemPositions.addListener(_onWebtoonScroll);
    AppSystemUi.applyReader();
    if (AppSettings.volTurn) {
      VolumeKeys.enable(up: _volBack, down: _volForward);
    }
    _initChapter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _diag.markInitialized(_readerInstanceId);
      _syncDiagnosticsContext();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_useFormalEdge) {
        _applyFsmResult(
          _edgeFsm.handle(event: ChapterEdgeFsmEvent.appPaused),
          scrollStyle: true,
          inputSource: 'appPaused',
        );
      } else {
        _edgeGuard.clear();
      }
    }
  }

  void _newChapterDiagToken() {
    if (!ReaderGestureDiagnostics.enabled) return;
    _chapterDiagToken = ReaderGestureDiagnostics.newChapterDiagToken();
    _diag.onChapterDiagTokenChanged(_readerInstanceId, _chapterDiagToken);
  }

  void _syncDiagnosticsContext() {
    if (!ReaderGestureDiagnostics.enabled || !mounted) return;
    final mq = MediaQuery.of(context);
    final lockPage = _pageZoomed || _multiTouch;
    final physicsType = lockPage
        ? 'NeverScrollableScrollPhysics'
        : 'PageScrollPhysics';
    _diag.bindReaderContext(
      readerInstanceId: _readerInstanceId,
      readMode: _readMode,
      r2l: _r2l,
      reverse: _readMode == 'h' && _r2l,
      chapterDiagToken: _chapterDiagToken,
      pageIndex: _page,
      pageCount: _count,
      hasPreviousChapter: _data.previousChapterUrl != null,
      hasNextChapter: _data.nextChapterUrl != null,
      pageZoomed: _pageZoomed,
      multiTouch: _multiTouch,
      physicsType: physicsType,
      pageControllerHasClients: _pageController.hasClients,
      pageControllerPage: _pageController.hasClients
          ? _pageController.page
          : null,
      edgeGuard: _edgeGuard,
      logicalSize: mq.size,
      devicePixelRatio: mq.devicePixelRatio,
    );
    final locked = lockPage;
    if (locked != _lastPhysicsLocked) {
      if (locked) {
        _diag.onPhysicsLocked(
          _readerInstanceId,
          reason: _multiTouch ? 'multiTouch' : 'pageZoomed',
        );
      } else {
        _diag.onPhysicsUnlocked(_readerInstanceId, reason: 'lockReleased');
      }
      _lastPhysicsLocked = locked;
    }
  }

  void _volBack() {
    if (_page <= 1) {
      _tryAdjacentChapter(false, inputSource: 'volumeKey');
      return;
    }
    if (_isWebtoon) {
      _jumpTo(_page - 1);
    } else {
      _turnPage(-1);
    }
  }

  void _volForward() {
    if (_page >= _pageCount) {
      _tryAdjacentChapter(true, inputSource: 'volumeKey');
      return;
    }
    if (_isWebtoon) {
      _jumpTo(_page + 1);
    } else {
      _turnPage(1);
    }
  }

  void _turnPage(int delta) {
    _diag.onProgrammaticPageTurn(
      _readerInstanceId,
      source: 'turnPage',
      delta: delta,
    );
    final target = (_page + delta).clamp(1, _pageCount);
    if (target != _page && _pageController.hasClients) {
      _pageController.animateToPage(
        target - 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  /// 点击分区翻页（仅横/纵）；到首/末页时二次确认切章（对齐原生 PagesManager）。
  /// 条漫禁用点击翻页，避免滑动误触。
  void _navigateTap(bool goNext) {
    if (_barsVisible) {
      _toggleBars();
      return;
    }
    if (_isWebtoon) return;
    if (goNext) {
      if (_page < _count) {
        _turnPage(1);
        _edgeGuard.clearSide(true);
        if (_useFormalEdge) {
          _edgeFsm.handle(event: ChapterEdgeFsmEvent.leftBoundary);
        }
      } else {
        _tryAdjacentChapter(true, inputSource: 'tapZone');
      }
    } else {
      if (_page > 1) {
        _turnPage(-1);
        _edgeGuard.clearSide(false);
        if (_useFormalEdge) {
          _edgeFsm.handle(event: ChapterEdgeFsmEvent.leftBoundary);
        }
      } else {
        _tryAdjacentChapter(false, inputSource: 'tapZone');
      }
    }
  }

  void _tryAdjacentChapter(bool goNext, {required String inputSource}) {
    final hasAdjacent =
        (goNext ? _data.nextChapterUrl : _data.previousChapterUrl) != null;
    if (_useFormalEdge) {
      _applyFsmResult(
        _edgeFsm.handle(
          event: ChapterEdgeFsmEvent.manualEdgeAction,
          goNext: goNext,
          hasAdjacent: hasAdjacent,
        ),
        scrollStyle: false,
        inputSource: inputSource,
      );
      return;
    }
    _applyEdgeOutcome(
      _edgeGuard.onEdge(goNext, hasAdjacent: hasAdjacent),
      goNext: goNext,
      scrollStyle: false,
      inputSource: inputSource,
    );
  }

  void _applyFsmResult(
    ChapterEdgeFsmResult result, {
    required bool scrollStyle,
    required String inputSource,
  }) {
    _diag.onEdgeStateChanged(
      _readerInstanceId,
      state: result.state.name,
      action: result.action.name,
      goNext: result.goNext,
      rejectReason: result.rejectReason,
      chapterRequestId: result.chapterRequestId,
    );

    switch (result.action) {
      case ChapterEdgeFsmAction.none:
        break;
      case ChapterEdgeFsmAction.deduplicated:
        _diag.onChapterSwitchDeduplicated(
          _readerInstanceId,
          reason: result.rejectReason,
          chapterRequestId: result.chapterRequestId,
        );
      case ChapterEdgeFsmAction.showAtEnd:
        _toast('已经到头了~');
      case ChapterEdgeFsmAction.showConfirmHint:
        _scheduleEdgeArmedTimeout();
        if (scrollStyle) {
          _toast(result.goNext ? '再次滑动加载下一章' : '再次滑动加载上一章');
        } else {
          _toast(result.goNext ? '再次按下加载下一章' : '再次按下加载上一章');
        }
      case ChapterEdgeFsmAction.requestChapterSwitch:
        _edgeArmedTimer?.cancel();
        final reqId =
            result.chapterRequestId ??
            ReaderGestureDiagnostics.newChapterRequestId();
        _diag.onEdgeGuardOutcome(
          _readerInstanceId,
          outcome: ChapterEdgeOutcome.openChapter,
          goNext: result.goNext,
          scrollStyle: scrollStyle,
          inputSource: inputSource,
          chapterRequestId: reqId,
        );
        _diag.onAdjacentOpenRequested(
          _readerInstanceId,
          goNext: result.goNext,
          inputSource: inputSource,
          chapterRequestId: reqId,
        );
        _edgeFsm.markWaitingForChapter();
        _edgeFsm.handle(event: ChapterEdgeFsmEvent.chapterRequestStarted);
        _openAdjacent(
          result.goNext,
          inputSource: inputSource,
          chapterRequestId: reqId,
        );
    }
  }

  void _scheduleEdgeArmedTimeout() {
    _edgeArmedTimer?.cancel();
    _edgeArmedTimer = Timer(kChapterEdgeConfirmWindow, () {
      if (!mounted) return;
      _applyFsmResult(
        _edgeFsm.checkTimeout(),
        scrollStyle: true,
        inputSource: 'edgeTimeout',
      );
    });
  }

  void _applyEdgeOutcome(
    ChapterEdgeOutcome outcome, {
    required bool goNext,
    required bool scrollStyle,
    required String inputSource,
  }) {
    int? openChapterRequestId;
    if (outcome == ChapterEdgeOutcome.openChapter) {
      openChapterRequestId = ReaderGestureDiagnostics.newChapterRequestId();
    }
    _diag.onEdgeGuardOutcome(
      _readerInstanceId,
      outcome: outcome,
      goNext: goNext,
      scrollStyle: scrollStyle,
      inputSource: inputSource,
      chapterRequestId: openChapterRequestId,
    );
    switch (outcome) {
      case ChapterEdgeOutcome.atEnd:
        _toast('已经到头了~');
      case ChapterEdgeOutcome.confirmNeeded:
        if (scrollStyle) {
          _toast(goNext ? '再次滑动加载下一章' : '再次滑动加载上一章');
        } else {
          _toast(goNext ? '再次按下加载下一章' : '再次按下加载上一章');
        }
      case ChapterEdgeOutcome.openChapter:
        _diag.onAdjacentOpenRequested(
          _readerInstanceId,
          goNext: goNext,
          inputSource: inputSource,
          chapterRequestId: openChapterRequestId,
        );
        _openAdjacent(
          goNext,
          inputSource: inputSource,
          chapterRequestId: openChapterRequestId,
        );
    }
  }

  void _onChapterChanged() {
    if (!mounted) return;
    _saveProgress();
    setState(() {
      _data = widget.dataNotifier.value;
      _page = 1;
      _prefetchRequested = false;
      _downloading = false;
      _pageZoomed = false;
    });
    _edgeGuard.clear();
    if (_useFormalEdge) {
      _edgeFsm.handle(event: ChapterEdgeFsmEvent.chapterRequestSucceeded);
      _edgeFsm.clear();
    }
    _edgeArmedTimer?.cancel();
    _resetPointerTracking();
    _newChapterDiagToken();
    _initChapter();
  }

  Future<void> _initChapter() async {
    final gen = ++_chapterGen;
    _userScrolledThisChapter = false;
    final data = _data;
    final count = data.imgUrls.length;
    if (count <= 0) return;
    if (data.initialPage == -2) {
      // 从下一章返回：直接落在末页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && gen == _chapterGen) _jumpTo(count);
      });
    } else {
      // 控制器是复用的，先显式回到第 1 页，避免停留在上一章的页码/越界偏移
      _jumpTo(1);
      await _restoreProgress(data, gen);
    }
    if (mounted && gen == _chapterGen) _preloadAround(_page - 1);
  }

  // ---- 断点续读（方案 B：看完清零 + 恢复提示）----

  Future<void> _restoreProgress(ChapterData data, int gen) async {
    final key = 'progress_${data.chapterKey}';
    final count = data.imgUrls.length;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || gen != _chapterGen) return;
    final saved = prefs.getInt(key) ?? 0;
    if (saved < 2 || saved >= count) return;
    if (_userScrolledThisChapter) {
      // 用户已经自己读起来了，跳走会很突兀；只告诉他断点在哪。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('上次读到第 $saved 页'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    _jumpTo(saved);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已跳转至上次阅读的第 $saved 页'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveProgress() async {
    // 同步捕获当前章节信息：原地切章时 _data/_page 会立刻被换成新章，
    // 若在 await 之后再读取，进度会写到错误的章节上
    final key = 'progress_${_data.chapterKey}';
    final page = _page;
    final count = _count;
    final prefs = await SharedPreferences.getInstance();
    if (page >= count - 1) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, page);
    }
  }

  // ---- 翻页与跳转 ----

  void _jumpTo(int page) {
    if (_count <= 0) return;
    final p = page.clamp(1, _pageCount);
    if (_isWebtoon) {
      if (_itemScrollController.isAttached) {
        _itemScrollController.jumpTo(index: p - 1);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _itemScrollController.isAttached) {
            _itemScrollController.jumpTo(index: p - 1);
          }
        });
      }
    } else {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(p - 1);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageController.hasClients) {
            _pageController.jumpToPage(p - 1);
          }
        });
      }
    }
    setState(() => _page = p);
  }

  void _onPageChanged(int index) {
    final from = _page;
    setState(() {
      _page = index + 1;
      _pageZoomed = false;
    });
    _diag.onPageChanged(_readerInstanceId, fromPage: from, toPage: _page);
    _edgeGuard.clear();
    if (_useFormalEdge) {
      _applyFsmResult(
        _edgeFsm.handle(event: ChapterEdgeFsmEvent.pageChanged),
        scrollStyle: true,
        inputSource: 'pageChanged',
      );
    }
    _maybePrefetch();
    _preloadAround(index);
  }

  void _onPageZoomChanged(bool zoomed) {
    if (_pageZoomed == zoomed) return;
    setState(() => _pageZoomed = zoomed);
    if (zoomed && _useFormalEdge) {
      _applyFsmResult(
        _edgeFsm.handle(event: ChapterEdgeFsmEvent.imageScaleStarted),
        scrollStyle: true,
        inputSource: 'imageScale',
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncDiagnosticsContext(),
    );
  }

  void _onLocksPageViewChanged(bool locks) {
    // zoomed 已由 onZoomChanged 锁页；此处只镜像双指即时锁。
    if (locks && !_pageZoomed && !_multiTouch) {
      setState(() => _multiTouch = true);
    } else if (!locks && _multiTouch && !_pageZoomed) {
      setState(() => _multiTouch = false);
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncDiagnosticsContext(),
    );
  }

  void _onWebtoonScroll() {
    if (!_isWebtoon || !mounted) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final newPage = WebtoonReadingProgress.resolveCurrentPage(
      itemCount: _pageCount,
      positions: positions.map(
        (item) => WebtoonViewportItem(
          index: item.index,
          leadingEdge: item.itemLeadingEdge,
          trailingEdge: item.itemTrailingEdge,
        ),
      ),
    );
    if (newPage != _page) {
      setState(() => _page = newPage);
      _edgeGuard.clear();
      if (_useFormalEdge) {
        _edgeFsm.handle(event: ChapterEdgeFsmEvent.pageChanged);
      }
      _maybePrefetch();
      _preloadAround(newPage - 1);
    }
  }

  /// 预载当前页之后 3 张。
  ///
  /// 原本是 5 张：条漫长图解码后单张可达 20–40MB，预载窗口太大会把内存
  /// ImageCache 撑爆，反而把视口附近的图挤出去、触发高度塌陷回跳。
  void _preloadAround(int index) {
    if (_data.isLocal) return;
    for (var i = index + 1; i <= index + 3 && i < _count; i++) {
      precacheImage(
        CachedNetworkImageProvider(
          wrapResolution(_data.imgUrls[i]),
          cacheManager: AppImageCache.manager,
        ),
        context,
        onError: (e, s) {},
      );
    }
    AppImageCache.maybeTrim();
  }

  /// 阅读至 80% 时静默预取下一章
  void _maybePrefetch() {
    final next = _data.nextChapterUrl;
    if (next == null || _prefetchRequested || _data.isLocal) return;
    if (_count > 0 && _page >= _count * 4 / 5) {
      _prefetchRequested = true;
      widget.onPrefetch?.call(next);
    }
  }

  void _openAdjacent(
    bool goNext, {
    required String inputSource,
    int? chapterRequestId,
  }) {
    final url = goNext ? _data.nextChapterUrl : _data.previousChapterUrl;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已经到头了~'), duration: Duration(seconds: 1)),
      );
      return;
    }
    final reqId =
        chapterRequestId ?? ReaderGestureDiagnostics.newChapterRequestId();
    widget.onRequestChapter?.call(
      url,
      goNext: goNext,
      chapterRequestId: reqId,
      readerInstanceId: _readerInstanceId,
      inputSource: inputSource,
      triggeringGestureSessionId: _diag.currentGestureSessionId(
        _readerInstanceId,
      ),
    );
  }

  /// 翻页到头继续翻 → 提示一次 → 再翻切章（对应原生版 doubleTapToast 逻辑）
  bool _handleOverscroll(OverscrollNotification n) {
    // overscroll 符号在滚动轴空间（已含 reverse），经统一映射得到逻辑意图。
    final scrollIntent = ReaderReadingDirection.resolveFromOverscroll(
      overscroll: n.overscroll,
      atFirstPage: _page <= 1,
      atLastPage: _page >= _count && _count > 0,
    );
    final towardEnd =
        scrollIntent == ReadingNavIntent.towardNextChapter ||
        scrollIntent == ReadingNavIntent.towardNextPage;
    final atEdge = _atChapterEdge(towardEnd);
    String rejectReason = 'none';
    bool accepted = false;
    if (n.overscroll.abs() < kChapterEdgeAuxOverscrollMinAbs) {
      rejectReason = 'overscrollBelowMinAbs';
    } else if (!atEdge) {
      rejectReason = 'notAtChapterEdge';
    } else if (scrollIntent != ReadingNavIntent.towardNextChapter &&
        scrollIntent != ReadingNavIntent.towardPreviousChapter) {
      rejectReason = 'notChapterEdgeIntent';
    } else {
      accepted = tryAcceptEdgeOverscroll(
        overscroll: n.overscroll,
        atChapterEdge: _atChapterEdge,
        gate: _edgeGate,
      );
      if (!accepted) rejectReason = 'edgeGateConsumed';
    }
    _diag.onOverscroll(
      _readerInstanceId,
      overscroll: n.overscroll,
      towardEnd: towardEnd,
      atChapterEdge: atEdge,
      accepted: accepted,
      rejectReason: rejectReason,
    );
    if (!accepted) return false;

    if (_useFormalEdge) {
      // Overscroll 仅作辅助信号；与主路径共用 gestureSessionId 去重。
      final sessionId =
          _gestureSessionId ?? _diag.currentGestureSessionId(_readerInstanceId);
      if (sessionId != null && _edgeAuxConsumedSessions.contains(sessionId)) {
        _diag.onChapterSwitchDeduplicated(
          _readerInstanceId,
          reason: 'auxOverscrollSameSession',
          chapterRequestId: null,
        );
        return false;
      }
      if (sessionId != null) _edgeAuxConsumedSessions.add(sessionId);
      final goNext = scrollIntent == ReadingNavIntent.towardNextChapter;
      final hasAdjacent =
          (goNext ? _data.nextChapterUrl : _data.previousChapterUrl) != null;
      _diag.onEdgeSwipeAccepted(
        _readerInstanceId,
        source: 'auxOverscroll',
        goNext: goNext,
        gestureSessionId: sessionId,
        physicalDeltaDx: 0,
        physicalDeltaDy: 0,
        resolvedLogicalIntent: scrollIntent.name,
        r2l: _r2l,
        reverse: _readMode == 'h' && _r2l,
        currentPageIndex: _page - 1,
        pageCount: _count,
        atFirstPage: _page <= 1,
        atLastPage: _page >= _pageCount && _pageCount > 0,
        edgeStateBefore: _edgeFsm.state.name,
      );
      _applyFsmResult(
        _edgeFsm.handle(
          event: ChapterEdgeFsmEvent.auxOverscroll,
          goNext: goNext,
          intent: scrollIntent,
          hasAdjacent: hasAdjacent,
          gestureSessionId: sessionId,
          fromAuxOverscroll: true,
        ),
        scrollStyle: true,
        inputSource: 'touchSwipe',
      );
      return false;
    }

    _handleChapterEdgeScroll(towardEnd);
    return false;
  }

  /// 条漫在列表尽头继续滑时可能无 OverscrollNotification；
  /// 仅在「手指仍在拖、且已顶住边界」时用 ScrollUpdate 补检测，避免滑到末页瞬间误提示。
  bool _handleScrollNotification(ScrollNotification n) {
    if (n.depth == 0) {
      // 只认手指拖拽：程序化 jumpTo / 惯性滚动不算「用户已经在读了」
      if ((n is ScrollStartNotification && n.dragDetails != null) ||
          (n is ScrollUpdateNotification && n.dragDetails != null)) {
        _userScrolledThisChapter = true;
      }
      if (n is ScrollStartNotification) {
        _diag.onScrollStart(_readerInstanceId, n, pageIndex: _page);
      } else if (n is ScrollEndNotification) {
        _diag.onScrollEnd(_readerInstanceId, n, pageIndex: _page);
      } else if (n is ScrollUpdateNotification) {
        _diag.onScrollUpdate(_readerInstanceId);
      }
    }
    if (n is OverscrollNotification) return _handleOverscroll(n);
    if (!_isWebtoon || n is! ScrollUpdateNotification || n.depth != 0) {
      return false;
    }
    // 惯性滑入边界时 dragDetails == null，不能当成「再滑一次」
    if (n.dragDetails == null) return false;
    final delta = n.scrollDelta;
    if (delta == null || delta.abs() < 2) return false;
    final m = n.metrics;

    if (delta > 0 && m.pixels >= m.maxScrollExtent - 2) {
      if (!_atChapterEdge(true) || !_edgeGate.allow()) return false;
      _handleChapterEdgeScroll(true);
    } else if (delta < 0 && m.pixels <= m.minScrollExtent + 2) {
      if (!_atChapterEdge(false) || !_edgeGate.allow()) return false;
      _handleChapterEdgeScroll(false);
    }
    return false;
  }

  void _handleChapterEdgeScroll(bool towardEnd) {
    final hasAdjacent =
        (towardEnd ? _data.nextChapterUrl : _data.previousChapterUrl) != null;
    if (_useFormalEdge) {
      // 条漫的 ScrollUpdate 是某些 Android 上 OverscrollNotification 缺失时
      // 的兜底信号。它必须与 Overscroll 共用同一个 FSM：若首划由兜底路径
      // 提示、二划由 Overscroll 到达，分属 Guard/FSM 会让二划被重新当成首划。
      final intent = towardEnd
          ? ReadingNavIntent.towardNextChapter
          : ReadingNavIntent.towardPreviousChapter;
      final sessionId = _gestureSessionId;
      if (sessionId != null) _edgeAuxConsumedSessions.add(sessionId);
      _applyFsmResult(
        _edgeFsm.handle(
          event: ChapterEdgeFsmEvent.auxOverscroll,
          goNext: towardEnd,
          intent: intent,
          hasAdjacent: hasAdjacent,
          gestureSessionId: sessionId,
          fromAuxOverscroll: true,
        ),
        scrollStyle: true,
        inputSource: 'touchSwipe',
      );
      return;
    }
    _applyEdgeOutcome(
      _edgeGuard.onEdge(towardEnd, hasAdjacent: hasAdjacent),
      goNext: towardEnd,
      scrollStyle: true,
      inputSource: 'touchSwipe',
    );
  }

  /// 横/纵：页码到头即可；条漫：必须最后一页底部（或首页顶部）真正进入视口。
  bool _atChapterEdge(bool towardEnd) {
    if (!_isWebtoon) {
      return towardEnd ? _page >= _pageCount : _page <= 1;
    }
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return towardEnd ? _page >= _pageCount : _page <= 1;
    }
    if (towardEnd) {
      return positions.any(
        (p) => p.index == _pageCount - 1 && p.itemTrailingEdge <= 1.02,
      );
    }
    return positions.any((p) => p.index == 0 && p.itemLeadingEdge >= -0.02);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  // ---- 页码跳转弹窗（对应原生版 showPageInputDialog）----

  Future<void> _showPageInputDialog() async {
    final controller = TextEditingController(text: _page.toString());
    final target = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('跳转到页码'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: '1 - $_count'),
          onSubmitted: (v) => Navigator.pop(c, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, int.tryParse(controller.text)),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (target != null) _jumpTo(target);
  }

  // ---- 下载 ----

  Future<void> _downloadChapter() async {
    if (_downloading || _data.isLocal) return;
    setState(() {
      _downloading = true;
      _downloadProgress = '0/$_count';
    });
    try {
      final ok = await Downloader.downloadImages(
        _data.title,
        '章节_${_data.uuid.length >= 8 ? _data.uuid.substring(0, 8) : _data.uuid}',
        _data.imgUrls,
        (done, total) {
          if (mounted) setState(() => _downloadProgress = '$done/$total');
        },
        chapterUuid: _data.uuid,
        comicId: _data.comicId,
        displayName: _data.title,
      );
      if (mounted) _toast(ok ? '本章下载完成' : '下载完成，部分图片失败');
    } catch (e) {
      if (mounted) _toast('下载失败：$e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ---- 模式切换 ----

  void _cycleReadMode() {
    final currentPage = _page;
    final next = switch (_readMode) {
      'h' => 'v',
      'v' => 'w',
      _ => 'h',
    };
    AppSettings.setReadMode(next);
    setState(() {
      _readMode = next;
      _pageZoomed = false;
    });
    _resetPointerTracking();
    if (_useFormalEdge) {
      _edgeFsm.handle(event: ChapterEdgeFsmEvent.readingModeChanged);
    } else {
      _edgeGuard.clear();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(currentPage));
  }

  String get _modeLabel => switch (_readMode) {
    'v' => '纵向',
    'w' => '条漫',
    _ => '横向',
  };

  // ---- 信息栏时钟（对应原生版 TimeThread）----

  Future<void> _updateClock() async {
    final now = DateTime.now();
    const weeks = ['一', '二', '三', '四', '五', '六', '日'];
    var net = '';
    try {
      final results = await Connectivity().checkConnectivity();
      net = switch (results.firstOrNull) {
        ConnectivityResult.wifi => ' WIFI',
        ConnectivityResult.mobile => ' 移动数据',
        ConnectivityResult.ethernet => ' 以太网',
        ConnectivityResult.vpn => ' VPN',
        ConnectivityResult.bluetooth => ' 蓝牙',
        ConnectivityResult.none => ' 无网络',
        _ => '',
      };
    } catch (_) {}
    if (mounted) {
      setState(() {
        _clockText =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}'
            ' 周${weeks[now.weekday - 1]}$net';
      });
    }
  }

  void _toggleBars() {
    setState(() => _barsVisible = !_barsVisible);
    if (_barsVisible) {
      _updateClock();
      _clockTimer?.cancel();
      _clockTimer = Timer.periodic(
        const Duration(seconds: 22),
        (_) => _updateClock(),
      );
    } else {
      _clockTimer?.cancel();
    }
  }

  /// 吐槽面板：先收起工具栏，避免弹出面板后底下还压着两层悬浮 UI。
  void _openCommentSheet() {
    if (_barsVisible) _toggleBars();
    unawaited(
      showCommentSheet(
        context,
        chapterId: _data.uuid,
        comicId: _data.comicId,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edgeArmedTimer?.cancel();
    if (_useFormalEdge) {
      _edgeFsm.handle(event: ChapterEdgeFsmEvent.disposed);
    }
    if (ReaderGestureDiagnostics.enabled) {
      _diag.detachReader(_readerInstanceId);
    }
    _saveProgress();
    widget.dataNotifier.removeListener(_onChapterChanged);
    _itemPositionsListener.itemPositions.removeListener(_onWebtoonScroll);
    // 必须走 AppSystemUi：iOS 写回 manual 会再次出现上下黑边
    AppSystemUi.restoreBrowserFromSettings();
    VolumeKeys.disable();
    _clockTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // ---- 图片控件（在线/离线通用）----

  Widget _buildImage(int index, {BoxFit fit = BoxFit.contain}) {
    final src = _data.imgUrls[index];
    if (_data.isLocal) {
      return Image.file(
        File(src),
        fit: fit,
        errorBuilder: (c, e, s) =>
            const Icon(Icons.broken_image, color: Colors.white38),
      );
    }
    return RetryNetworkImage(url: wrapResolution(src), fit: fit);
  }

  /// 条漫单个 item：高度由缓存的宽高比锁定，图片加载/回收/重下载期间都不变。
  ///
  /// 不加这层 AspectRatio 时，占位符（一个 loading 圈）高度接近 0，item 在被回收
  /// 后重建会先塌成零高再弹回真实高度；列表总高度随之抖动，SPL 重新对齐锚点，
  /// 表现就是「滑着滑着闪一下往回跳一段」。
  /// 章节末尾的「吐槽」虚拟页（只放章末吐槽，不展示全本总评）。
  Widget _buildCommentPage() =>
      CommentPage(chapterId: _data.uuid, comicId: '');

  Widget _buildWebtoonImage(int index) {
    final src = _data.imgUrls[index];
    final url = _data.isLocal ? src : wrapResolution(src);
    final ImageProvider provider = _data.isLocal
        ? FileImage(File(src))
        : CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager);
    final Widget image = _data.isLocal
        ? Image.file(
            File(src),
            fit: BoxFit.fitWidth,
            errorBuilder: (c, e, s) =>
                const Icon(Icons.broken_image, color: Colors.white38),
          )
        : RetryNetworkImage(url: url, fit: BoxFit.fitWidth);

    // 尺寸探测对在线/离线走同一套：离线章节同样需要锁定高度。
    final child = ImageIntrinsicSizeListener(
      provider: provider,
      onSize: (size) => _onWebtoonImageSize(url, size),
      child: image,
    );

    // 比例未知时**不能**套 AspectRatio：它给子控件的是紧约束，配 BoxFit.fitWidth
    // 会把比兜底比例更长的图裁掉下半截。未知时退回自然高度（即改动前的行为），
    // 学到真实比例后才锁定——这不削弱修复效果：回跳来自被回收后**重建**的 item，
    // 而它们必然已经显示过一次、比例已知。
    final ratio = WebtoonAspectCache.get(url);
    if (ratio == null) return child;
    return AspectRatio(aspectRatio: ratio, child: child);
  }

  /// 记录新学到的宽高比并请求重建。
  ///
  /// 这个回调**可能在 build 期间同步触发**：图片已在 ImageCache 里时
  /// `ImageStream.addListener` 会立刻回调，而监听是在 `initState`（即 itemBuilder
  /// 内）挂上的。此时直接 setState 会抛 "setState() called during build"。
  /// `_preloadAround` 主动 precache 后几张，这条同步路径几乎必然被走到。
  void _onWebtoonImageSize(String url, Size size) {
    if (!WebtoonAspectCache.put(url, size.width, size.height)) return;
    if (!mounted) return;
    // 一帧内可能有多张图同时报尺寸，合并成一次重建。
    _webtoonRebuild.request(() {
      if (mounted) setState(() {});
    });
  }

  Widget _buildViewer() {
    if (_count <= 0) {
      if (_data.isLoading) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在加载…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        );
      }
      return const Center(
        child: Text('本章无图片', style: TextStyle(color: Colors.white54)),
      );
    }
    if (_isWebtoon) {
      return Listener(
        onPointerDown: _onEdgePointerDown,
        onPointerMove: _onEdgePointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ZoomableWebtoonView(
            onZoomChanged: _onPageZoomChanged,
            child: ScrollablePositionedList.builder(
              itemCount: _pageCount,
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              // 必须 AlwaysScrollable：章节只有一页且不满一屏时
              // minScrollExtent == maxScrollExtent，默认 ScrollPhysics 的
              // shouldAcceptUserOffset 返回 false，Android 的 ClampingScrollPhysics
              // 会直接吞掉拖拽——既不发 ScrollUpdate 也不发 Overscroll，
              // 条漫切章的两条兜底通知全断。iOS 的 BouncingScrollPhysics 恒返回
              // true，所以这个 bug 只在 Android 上出现。
              physics: const AlwaysScrollableScrollPhysics(),
              itemBuilder: (context, index) => index == _count
                  ? _buildCommentPage()
                  : _buildWebtoonImage(index),
            ),
          ),
        ),
      );
    }
    final lockPage = _pageZoomed || _multiTouch;
    return Listener(
      onPointerDown: _onEdgePointerDown,
      onPointerMove: _onEdgePointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: PageView.builder(
          controller: _pageController,
          // 放大中 / 双指捏合中禁止翻页，把滑动交给 InteractiveViewer
          physics: lockPage
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          scrollDirection: _readMode == 'v' ? Axis.vertical : Axis.horizontal,
          reverse: _readMode == 'h' && _r2l,
          itemCount: _pageCount,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) => index == _count
              ? _buildCommentPage()
              : ZoomableReaderImage(
                  isHorizontal: _readMode == 'h',
                  r2l: _r2l,
                  onPageTurn: _navigateTap,
                  onMenu: _toggleBars,
                  onZoomChanged: _onPageZoomChanged,
                  onLocksPageViewChanged: _onLocksPageViewChanged,
                  child: _buildImage(index),
                ),
        ),
      ),
    );
  }

  void _onEdgePointerDown(PointerDownEvent e) {
    final now = DateTime.now();
    // 只剔除超时未更新的幽灵 id；保留仍在窗口内的其它指，避免慢速双指捏合被误清
    final before = _activePointers.length;
    _activePointers.removeWhere(
      (_, t) => now.difference(t).inMilliseconds > _pointerStaleMs,
    );
    final clearedStale = before != _activePointers.length;
    if (clearedStale && _activePointers.length < 2 && _multiTouch) {
      _multiTouch = false;
    }
    _activePointers[e.pointer] = now;
    _diag.onPointerDown(
      _readerInstanceId,
      e,
      activePointerCount: _activePointers.length,
    );
    // 每次按下都重新武装，避免漏收 pointerUp 导致 gate 永久哑火
    _edgeGate.beginGesture();

    if (_activePointers.length == 1) {
      _gestureStartPos = e.position;
      _gestureTotalDelta = Offset.zero;
      _gestureStartAt = now;
      _gestureCancelled = false;
      _gestureSawMultiTouch = false;
      _gestureStartPage = _page;
      // 自主生成 session ID，不依赖仅 debug 可用的 _diag 模块。
      // 修复 release APK 中 gestureSessionId 始终为 null 导致 FSM 去重失效的 bug。
      _gestureSessionId = _newGestureSessionId();
      // Debug 模式下同步给诊断系统，保持日志一致性（release 中 no-op）。
      if (ReaderGestureDiagnostics.enabled) {
        _diag.onGestureSessionIdAssigned(_readerInstanceId, _gestureSessionId!);
      }
    } else if (_activePointers.length >= 2) {
      _gestureSawMultiTouch = true;
    }

    if (_activePointers.length >= 2 && !_multiTouch) {
      setState(() => _multiTouch = true);
      if (_useFormalEdge) {
        _edgeFsm.handle(event: ChapterEdgeFsmEvent.imageScaleStarted);
      }
    } else if (clearedStale && !_multiTouch) {
      setState(() {});
    }
    _syncDiagnosticsContext();
  }

  void _onEdgePointerMove(PointerMoveEvent e) {
    _activePointers[e.pointer] = DateTime.now();
    _diag.onPointerMove(_readerInstanceId, e);
    if (_gestureStartPos != null && _activePointers.length == 1) {
      _gestureTotalDelta = e.position - _gestureStartPos!;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _onPointerLeave(e);
    _diag.onPointerUp(
      _readerInstanceId,
      e,
      activePointerCount: _activePointers.length,
    );
    if (_activePointers.isEmpty) {
      _finalizeIndependentEdgeSwipe(cancelled: _gestureCancelled);
    }
    _syncDiagnosticsContext();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _gestureCancelled = true;
    _onPointerLeave(e);
    _diag.onPointerCancel(
      _readerInstanceId,
      e,
      activePointerCount: _activePointers.length,
    );
    if (_activePointers.isEmpty) {
      if (_useFormalEdge) {
        _applyFsmResult(
          _edgeFsm.handle(event: ChapterEdgeFsmEvent.gestureCancelled),
          scrollStyle: true,
          inputSource: 'pointerCancel',
        );
      }
      _resetGestureAccumulators();
    }
    _syncDiagnosticsContext();
  }

  void _finalizeIndependentEdgeSwipe({required bool cancelled}) {
    if (!_useFormalEdge || _isWebtoon) {
      _resetGestureAccumulators();
      return;
    }
    if (cancelled ||
        _gestureSawMultiTouch ||
        _pageZoomed ||
        _gestureStartAt == null) {
      _resetGestureAccumulators();
      return;
    }

    final durationMs = DateTime.now()
        .difference(_gestureStartAt!)
        .inMilliseconds;
    final dx = _gestureTotalDelta.dx;
    final dy = _gestureTotalDelta.dy;
    final horizontal = _readMode == 'h';
    final sessionId = _gestureSessionId;

    // 若本 session 已通过 aux overscroll 处理，主路径跳过
    if (sessionId != null && _edgeAuxConsumedSessions.contains(sessionId)) {
      _diag.onEdgeSwipeRejected(
        _readerInstanceId,
        reason: 'alreadyHandledByAuxOverscroll',
        gestureSessionId: sessionId,
      );
      _resetGestureAccumulators();
      return;
    }

    final atFirst = _gestureStartPage <= 1;
    final atLast = _gestureStartPage >= _count && _count > 0;
    final edgeStateBefore = _edgeFsm.state.name;
    final geometry = EdgeSwipeGeometry.evaluate(
      totalDx: dx,
      totalDy: dy,
      durationMs: durationMs,
      viewport: MediaQuery.sizeOf(context),
      horizontalReading: horizontal,
      r2l: _r2l,
      atFirstPage: atFirst,
      atLastPage: atLast,
    );
    final physical = ReaderReadingDirection.physicalSwipe(
      totalDx: dx,
      totalDy: dy,
      horizontalReading: horizontal,
    );

    if (!geometry.accepted) {
      _diag.onEdgeSwipeRejected(
        _readerInstanceId,
        reason: geometry.rejectReason,
        gestureSessionId: sessionId,
        physicalSwipeDirection: ReaderReadingDirection.physicalLabel(physical),
        physicalDeltaDx: dx,
        physicalDeltaDy: dy,
        resolvedLogicalIntent: geometry.intent.name,
        r2l: _r2l,
        reverse: horizontal && _r2l,
        currentPageIndex: _gestureStartPage - 1,
        pageCount: _count,
        atFirstPage: atFirst,
        atLastPage: atLast,
        edgeStateBefore: edgeStateBefore,
      );
      _resetGestureAccumulators();
      return;
    }

    final goNext = geometry.intent == ReadingNavIntent.towardNextChapter;
    final hasAdjacent =
        (goNext ? _data.nextChapterUrl : _data.previousChapterUrl) != null;

    if (sessionId != null) _edgeAuxConsumedSessions.add(sessionId);
    _diag.onEdgeSwipeAccepted(
      _readerInstanceId,
      source: 'independentSwipe',
      goNext: goNext,
      gestureSessionId: sessionId,
      physicalSwipeDirection: ReaderReadingDirection.physicalLabel(physical),
      physicalDeltaDx: dx,
      physicalDeltaDy: dy,
      resolvedLogicalIntent: geometry.intent.name,
      r2l: _r2l,
      reverse: horizontal && _r2l,
      currentPageIndex: _gestureStartPage - 1,
      pageCount: _count,
      atFirstPage: atFirst,
      atLastPage: atLast,
      edgeStateBefore: edgeStateBefore,
    );
    _applyFsmResult(
      _edgeFsm.handle(
        event: ChapterEdgeFsmEvent.independentSwipeCompleted,
        goNext: goNext,
        intent: geometry.intent,
        hasAdjacent: hasAdjacent,
        gestureSessionId: sessionId,
      ),
      scrollStyle: true,
      inputSource: 'touchSwipe',
    );
    _resetGestureAccumulators();
  }

  void _resetGestureAccumulators() {
    _gestureStartPos = null;
    _gestureTotalDelta = Offset.zero;
    _gestureStartAt = null;
    _gestureSessionId = null;
    _gestureCancelled = false;
    _gestureSawMultiTouch = false;
    _gestureStartPage = _page;
    if (_edgeAuxConsumedSessions.length > 64) {
      _edgeAuxConsumedSessions.clear();
    }
  }

  void _onPointerLeave(PointerEvent e) {
    _activePointers.remove(e.pointer);
    if (_activePointers.isEmpty) {
      if (_multiTouch) setState(() => _multiTouch = false);
      return;
    }
    if (_activePointers.length < 2 && _multiTouch) {
      setState(() => _multiTouch = false);
    }
  }

  void _resetPointerTracking() {
    _activePointers.clear();
    if (_multiTouch) {
      _multiTouch = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncDiagnosticsContext();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildViewer(),
          // 横/纵点击分区在 ZoomableReaderImage 内；条漫无缩放层，叠层只开中央菜单
          if (_isWebtoon)
            ReaderTapZones(
              isHorizontal: false,
              r2l: _r2l,
              enablePageTurn: false,
              onPageTurn: _navigateTap,
              onMenu: _toggleBars,
            ),
          if (AppSettings.showPageNum && _count > 0)
            Positioned(
              right: 8,
              bottom: 8,
              child: GestureDetector(
                onTap: _showPageInputDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _onCommentPage ? '吐槽' : '$_page/$_count',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            ),
          if (_downloading)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '下载中 $_downloadProgress',
                  style: const TextStyle(
                    color: Colors.lightGreenAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          if (_barsVisible) _buildBottomBar(),
          ValueListenableBuilder<String?>(
            valueListenable: widget.loadingText,
            builder: (context, text, child) {
              if (text == null) return const SizedBox.shrink();
              return Container(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(text),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: '退出阅读',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 22,
                      ),
                      onPressed: widget.onClose,
                    ),
                  Expanded(
                    child: Text(
                      _data.title,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _clockText,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: _data.previousChapterUrl == null
                        ? null
                        : () => _openAdjacent(false, inputSource: 'toolbar'),
                    child: const Text('上一章'),
                  ),
                  Expanded(
                    child: _count <= 0
                        ? const SizedBox.shrink()
                        : Slider(
                            value: _page.toDouble().clamp(1, _count.toDouble()),
                            min: 1,
                            max: _count.toDouble(),
                            divisions: _count > 1 ? _count - 1 : null,
                            onChanged: (v) => _jumpTo(v.round()),
                          ),
                  ),
                  TextButton(
                    onPressed: _data.nextChapterUrl == null
                        ? null
                        : () => _openAdjacent(true, inputSource: 'toolbar'),
                    child: const Text('下一章'),
                  ),
                ],
              ),
              // 窄屏下 4 个 TextButton.icon 会溢出（OVERFLOWED BY ~21px），改紧凑工具钮
              Row(
                children: [
                  Expanded(
                    child: _ReaderToolBtn(
                      icon: Icons.chrome_reader_mode,
                      label: _modeLabel,
                      onPressed: _cycleReadMode,
                    ),
                  ),
                  Expanded(
                    child: _ReaderToolBtn(
                      icon: Icons.swap_horiz,
                      label: _r2l ? '右开' : '左开',
                      onPressed: _readMode != 'h'
                          ? null
                          : () {
                              final p = _page;
                              AppSettings.setR2l(!_r2l);
                              setState(() => _r2l = !_r2l);
                              WidgetsBinding.instance.addPostFrameCallback(
                                (_) => _jumpTo(p),
                              );
                            },
                    ),
                  ),
                  Expanded(
                    child: _ReaderToolBtn(
                      icon: AppSettings.volTurn
                          ? Icons.volume_up
                          : Icons.volume_off,
                      label: '音量',
                      onPressed: () async {
                        await AppSettings.setVolTurn(!AppSettings.volTurn);
                        if (AppSettings.volTurn) {
                          VolumeKeys.enable(up: _volBack, down: _volForward);
                        } else {
                          VolumeKeys.disable();
                        }
                        setState(() {});
                      },
                    ),
                  ),
                  if (!_data.isLocal)
                    Expanded(
                      child: _ReaderToolBtn(
                        icon: Icons.download,
                        label: '下载',
                        onPressed: _downloading ? null : _downloadChapter,
                      ),
                    ),
                  Expanded(
                    child: _ReaderToolBtn(
                      icon: Icons.mode_comment,
                      label: '吐槽',
                      onPressed: _openCommentSheet,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读器底栏紧凑工具钮，避免窄屏 TextButton.icon 横向溢出
class _ReaderToolBtn extends StatelessWidget {
  const _ReaderToolBtn({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = enabled ? Colors.white : Colors.white38;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
