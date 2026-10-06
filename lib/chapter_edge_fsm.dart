import 'package:flutter/foundation.dart';

import 'reader_gesture_config.dart';
import 'reader_reading_direction.dart';

/// 章节边界二次确认状态。
enum ChapterEdgeFsmState {
  idle,
  armedPrevious,
  armedNext,
  switchingPrevious,
  switchingNext,
  waitingForChapter,
  failed,
  disposed,
}

/// 边界 FSM 事件。
enum ChapterEdgeFsmEvent {
  independentSwipeCompleted,
  pageChanged,
  reachedFirstPage,
  reachedLastPage,
  leftBoundary,
  gestureCancelled,
  timeout,
  chapterRequestStarted,
  chapterRequestSucceeded,
  chapterRequestFailed,
  appPaused,
  readingModeChanged,
  imageScaleStarted,
  disposed,
  manualEdgeAction,
  auxOverscroll,
}

/// 对外动作。
enum ChapterEdgeFsmAction {
  none,
  showConfirmHint,
  requestChapterSwitch,
  showAtEnd,
  deduplicated,
}

/// 一次状态机步进结果。
class ChapterEdgeFsmResult {
  const ChapterEdgeFsmResult({
    required this.action,
    required this.state,
    this.goNext = false,
    this.chapterRequestId,
    this.rejectReason = 'none',
  });

  final ChapterEdgeFsmAction action;
  final ChapterEdgeFsmState state;
  final bool goNext;
  final int? chapterRequestId;
  final String rejectReason;
}

/// 独立、纯 Dart、可测试的章节边界状态机。
///
/// 主输入：完成的独立 swipe（[ChapterEdgeFsmEvent.independentSwipeCompleted]）。
/// 辅助：overscroll（[ChapterEdgeFsmEvent.auxOverscroll]），不得作为唯一入口时
/// 若同 session 已通过主路径处理则去重。
class ChapterEdgeFsm {
  ChapterEdgeFsm({
    Duration confirmWindow = kChapterEdgeConfirmWindow,
    int Function()? nowMs,
    int Function()? nextRequestId,
  }) : _confirmWindow = confirmWindow,
       _nowMs = nowMs ?? _defaultNowMs,
       _nextRequestId = nextRequestId ?? _defaultRequestId;

  static int _requestSeq = 0;
  static int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;
  static int _defaultRequestId() => ++_requestSeq;

  @visibleForTesting
  static void resetRequestIdSeqForTest() => _requestSeq = 0;

  final Duration _confirmWindow;
  final int Function() _nowMs;
  final int Function() _nextRequestId;

  ChapterEdgeFsmState _state = ChapterEdgeFsmState.idle;
  String? _armedGestureSessionId;
  int? _armedAtMs;
  int? _activeChapterRequestId;
  int _operationToken = 0;
  final Set<String> _consumedGestureSessions = {};

  ChapterEdgeFsmState get state => _state;
  int? get activeChapterRequestId => _activeChapterRequestId;
  int get operationToken => _operationToken;

  bool get currentlyHintingNext => _state == ChapterEdgeFsmState.armedNext;
  bool get currentlyHintingPrevious =>
      _state == ChapterEdgeFsmState.armedPrevious;

  Map<String, Object?> debugSnapshot() => {
    'state': _state.name,
    'currentlyHintingNext': currentlyHintingNext,
    'currentlyHintingPrevious': currentlyHintingPrevious,
    'activeChapterRequestId': _activeChapterRequestId,
    'operationToken': _operationToken,
  };

  ChapterEdgeFsmResult handle({
    required ChapterEdgeFsmEvent event,
    bool goNext = false,
    String? gestureSessionId,
    ReadingNavIntent? intent,
    bool hasAdjacent = true,
    int? chapterRequestId,
    bool fromAuxOverscroll = false,
  }) {
    if (_state == ChapterEdgeFsmState.disposed) {
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.none,
        state: _state,
        rejectReason: 'disposed',
      );
    }

    switch (event) {
      case ChapterEdgeFsmEvent.disposed:
        _state = ChapterEdgeFsmState.disposed;
        _clearArmed();
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
        );

      case ChapterEdgeFsmEvent.appPaused:
      case ChapterEdgeFsmEvent.readingModeChanged:
      case ChapterEdgeFsmEvent.imageScaleStarted:
      case ChapterEdgeFsmEvent.gestureCancelled:
      case ChapterEdgeFsmEvent.pageChanged:
      case ChapterEdgeFsmEvent.leftBoundary:
        return _resetIdle(reason: event.name);

      case ChapterEdgeFsmEvent.timeout:
        if (_state == ChapterEdgeFsmState.armedNext ||
            _state == ChapterEdgeFsmState.armedPrevious) {
          return _resetIdle(reason: 'timeout');
        }
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
          rejectReason: 'timeoutIgnored',
        );

      case ChapterEdgeFsmEvent.reachedFirstPage:
      case ChapterEdgeFsmEvent.reachedLastPage:
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
        );

      case ChapterEdgeFsmEvent.chapterRequestStarted:
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
        );

      case ChapterEdgeFsmEvent.chapterRequestSucceeded:
        _activeChapterRequestId = null;
        _clearArmed();
        _state = ChapterEdgeFsmState.idle;
        _operationToken++;
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
        );

      case ChapterEdgeFsmEvent.chapterRequestFailed:
        if (chapterRequestId != null &&
            _activeChapterRequestId != null &&
            chapterRequestId != _activeChapterRequestId) {
          return ChapterEdgeFsmResult(
            action: ChapterEdgeFsmAction.deduplicated,
            state: _state,
            rejectReason: 'staleChapterRequestId',
            chapterRequestId: chapterRequestId,
          );
        }
        _activeChapterRequestId = null;
        _clearArmed();
        _state = ChapterEdgeFsmState.idle;
        return ChapterEdgeFsmResult(
          action: ChapterEdgeFsmAction.none,
          state: _state,
          rejectReason: 'chapterRequestFailedRecovered',
        );

      case ChapterEdgeFsmEvent.manualEdgeAction:
        return _onConfirmableAction(
          goNext: goNext,
          hasAdjacent: hasAdjacent,
          gestureSessionId: null,
          allowSameSession: true,
        );

      case ChapterEdgeFsmEvent.auxOverscroll:
      case ChapterEdgeFsmEvent.independentSwipeCompleted:
        final resolvedGoNext = intent != null
            ? (intent == ReadingNavIntent.towardNextChapter)
            : goNext;
        if (intent != null &&
            intent != ReadingNavIntent.towardNextChapter &&
            intent != ReadingNavIntent.towardPreviousChapter) {
          return ChapterEdgeFsmResult(
            action: ChapterEdgeFsmAction.none,
            state: _state,
            rejectReason: 'intentNotChapterEdge',
          );
        }
        return _onConfirmableAction(
          goNext: resolvedGoNext,
          hasAdjacent: hasAdjacent,
          gestureSessionId: gestureSessionId,
          allowSameSession: false,
          fromAux:
              fromAuxOverscroll || event == ChapterEdgeFsmEvent.auxOverscroll,
        );
    }
  }

  /// 供外部定时器：若 armed 超时则复位。
  ChapterEdgeFsmResult checkTimeout() {
    if (_state != ChapterEdgeFsmState.armedNext &&
        _state != ChapterEdgeFsmState.armedPrevious) {
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.none,
        state: _state,
      );
    }
    final armedAt = _armedAtMs;
    if (armedAt == null) return _resetIdle(reason: 'armedWithoutTimestamp');
    if (_nowMs() - armedAt >= _confirmWindow.inMilliseconds) {
      return handle(event: ChapterEdgeFsmEvent.timeout);
    }
    return ChapterEdgeFsmResult(
      action: ChapterEdgeFsmAction.none,
      state: _state,
    );
  }

  bool isStaleRequest(int chapterRequestId) {
    return _activeChapterRequestId != null &&
        chapterRequestId != _activeChapterRequestId;
  }

  ChapterEdgeFsmResult _onConfirmableAction({
    required bool goNext,
    required bool hasAdjacent,
    required String? gestureSessionId,
    required bool allowSameSession,
    bool fromAux = false,
  }) {
    if (_state == ChapterEdgeFsmState.switchingNext ||
        _state == ChapterEdgeFsmState.switchingPrevious ||
        _state == ChapterEdgeFsmState.waitingForChapter) {
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.deduplicated,
        state: _state,
        goNext: goNext,
        rejectReason: 'switchingInProgress',
        chapterRequestId: _activeChapterRequestId,
      );
    }

    if (!hasAdjacent) {
      _clearArmed();
      _state = ChapterEdgeFsmState.idle;
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.showAtEnd,
        state: _state,
        goNext: goNext,
        rejectReason: 'noAdjacent',
      );
    }

    if (gestureSessionId != null &&
        _consumedGestureSessions.contains(gestureSessionId) &&
        !allowSameSession) {
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.deduplicated,
        state: _state,
        goNext: goNext,
        rejectReason: 'sameGestureSessionId',
      );
    }

    // 先处理超时
    if (_state == ChapterEdgeFsmState.armedNext ||
        _state == ChapterEdgeFsmState.armedPrevious) {
      final armedAt = _armedAtMs;
      if (armedAt != null &&
          _nowMs() - armedAt >= _confirmWindow.inMilliseconds) {
        _clearArmed();
        _state = ChapterEdgeFsmState.idle;
      }
    }

    // 方向相反：重新武装为新方向（算第一划）
    if (_state == ChapterEdgeFsmState.armedNext && !goNext) {
      return _arm(goNext: false, gestureSessionId: gestureSessionId);
    }
    if (_state == ChapterEdgeFsmState.armedPrevious && goNext) {
      return _arm(goNext: true, gestureSessionId: gestureSessionId);
    }

    final armedSameDirection =
        (goNext && _state == ChapterEdgeFsmState.armedNext) ||
        (!goNext && _state == ChapterEdgeFsmState.armedPrevious);

    if (!armedSameDirection) {
      return _arm(goNext: goNext, gestureSessionId: gestureSessionId);
    }

    // 第二划：必须新 gestureSessionId（手动动作除外）
    if (!allowSameSession &&
        gestureSessionId != null &&
        gestureSessionId == _armedGestureSessionId) {
      return ChapterEdgeFsmResult(
        action: ChapterEdgeFsmAction.deduplicated,
        state: _state,
        goNext: goNext,
        rejectReason: 'sameGestureSessionAsArm',
      );
    }

    if (gestureSessionId != null) {
      _consumedGestureSessions.add(gestureSessionId);
    }

    final reqId = _nextRequestId();
    _activeChapterRequestId = reqId;
    _operationToken++;
    _state = goNext
        ? ChapterEdgeFsmState.switchingNext
        : ChapterEdgeFsmState.switchingPrevious;
    _armedGestureSessionId = null;
    _armedAtMs = null;

    return ChapterEdgeFsmResult(
      action: ChapterEdgeFsmAction.requestChapterSwitch,
      state: _state,
      goNext: goNext,
      chapterRequestId: reqId,
      rejectReason: fromAux ? 'auxOverscrollSecondSwipe' : 'none',
    );
  }

  ChapterEdgeFsmResult _arm({
    required bool goNext,
    required String? gestureSessionId,
  }) {
    if (gestureSessionId != null) {
      _consumedGestureSessions.add(gestureSessionId);
    }
    _armedGestureSessionId = gestureSessionId;
    _armedAtMs = _nowMs();
    _state = goNext
        ? ChapterEdgeFsmState.armedNext
        : ChapterEdgeFsmState.armedPrevious;
    return ChapterEdgeFsmResult(
      action: ChapterEdgeFsmAction.showConfirmHint,
      state: _state,
      goNext: goNext,
    );
  }

  ChapterEdgeFsmResult _resetIdle({required String reason}) {
    _clearArmed();
    _state = ChapterEdgeFsmState.idle;
    return ChapterEdgeFsmResult(
      action: ChapterEdgeFsmAction.none,
      state: _state,
      rejectReason: reason,
    );
  }

  void _clearArmed() {
    _armedGestureSessionId = null;
    _armedAtMs = null;
    if (_consumedGestureSessions.length > 32) {
      _consumedGestureSessions.clear();
    }
  }

  void markWaitingForChapter() {
    if (_state == ChapterEdgeFsmState.switchingNext ||
        _state == ChapterEdgeFsmState.switchingPrevious) {
      _state = ChapterEdgeFsmState.waitingForChapter;
    }
  }

  void clear() => _resetIdle(reason: 'clear');
}
