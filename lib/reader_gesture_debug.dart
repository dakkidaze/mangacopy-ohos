import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'build_info.dart';
import 'chapter_edge_guard.dart';
import 'reader_gesture_jsonl.dart';
import 'reader_reading_direction.dart';

/// Debug-only 阅读器手势诊断。Profile / Release 中 [enabled] 为 false，所有方法立即返回。
class ReaderGestureDiagnostics {
  ReaderGestureDiagnostics._();

  static final ReaderGestureDiagnostics instance = ReaderGestureDiagnostics._();

  static bool get enabled => kDebugMode;

  static int _readerIdSeq = 0;
  static int _chapterRequestSeq = 0;

  static String newReaderInstanceId() {
    _readerIdSeq++;
    return 'ri-$_readerIdSeq-${DateTime.now().microsecondsSinceEpoch}';
  }

  static int newChapterRequestId() => ++_chapterRequestSeq;

  static String newChapterDiagToken() {
    final r = math.Random();
    return 'ct-${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  final Map<String, _ReaderDiagState> _readers = {};
  final Map<int, _ChapterRequestContext> _chapterRequests = {};
  String? _activeReaderId;

  String? get activeReaderInstanceId => _activeReaderId;

  /// 测试运行开始时调用（脚本 broadcast 或手动），创建新 JSONL 文件。
  Future<void> startTestRun({String? testRunId}) async {
    if (!enabled) return;
    await ReaderGestureJsonlWriter.instance.startRun(testRunId: testRunId);
    _printLine(
      event: 'testRunStarted',
      extra: {
        'testRunId': ReaderGestureJsonlWriter.instance.testRunId,
        'jsonlPathHint': ReaderGestureJsonlWriter.adbRelativePath,
      },
    );
  }

  _ReaderDiagState? _stateFor(String? readerInstanceId) {
    if (!enabled) return null;
    final id = readerInstanceId ?? _activeReaderId;
    if (id == null) return null;
    return _readers[id];
  }

  void attachReader(String readerInstanceId) {
    if (!enabled) return;
    _readers[readerInstanceId] = _ReaderDiagState(readerInstanceId);
    _activeReaderId = readerInstanceId;
  }

  void detachReader(String readerInstanceId) {
    if (!enabled) return;
    final state = _readers.remove(readerInstanceId);
    state?.dispose(aborted: true);
    if (_activeReaderId == readerInstanceId) {
      _activeReaderId = _readers.keys.isEmpty ? null : _readers.keys.last;
    }
    _printLine(
      event: 'readerDetached',
      readerInstanceId: readerInstanceId,
      extra: {'remainingReaders': _readers.length},
    );
  }

  void markInitialized(String readerInstanceId) {
    final s = _stateFor(readerInstanceId);
    if (s == null || s.initialized) return;
    s.initialized = true;
    s.emit(
      'diagnosticsInitialized',
      extra: {
        'dartVersion': Platform.version,
        if (BuildInfo.flutterSdk != null) 'flutterSdk': BuildInfo.flutterSdk,
        'flutterSdkSource': BuildInfo.flutterSdkSource,
        'appVersionSource': BuildInfo.appVersionSource,
      },
    );
  }

  void bindReaderContext({
    required String readerInstanceId,
    required String readMode,
    required bool r2l,
    required bool reverse,
    required String chapterDiagToken,
    required int pageIndex,
    required int pageCount,
    required bool hasPreviousChapter,
    required bool hasNextChapter,
    required bool pageZoomed,
    required bool multiTouch,
    required String physicsType,
    required bool pageControllerHasClients,
    required double? pageControllerPage,
    required ChapterEdgeGuard edgeGuard,
    required Size logicalSize,
    required double devicePixelRatio,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    s.readMode = readMode;
    s.r2l = r2l;
    s.reverse = reverse;
    s.chapterDiagToken = chapterDiagToken;
    s.pageIndex = pageIndex;
    s.pageCount = pageCount;
    s.hasPreviousChapter = hasPreviousChapter;
    s.hasNextChapter = hasNextChapter;
    s.pageZoomed = pageZoomed;
    s.multiTouch = multiTouch;
    s.physicsType = physicsType;
    s.pageControllerHasClients = pageControllerHasClients;
    s.pageControllerPage = pageControllerPage;
    s.edgeGuard = edgeGuard;
    s.logicalSize = logicalSize;
    s.devicePixelRatio = devicePixelRatio;
  }

  void onChapterDiagTokenChanged(String readerInstanceId, String token) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    s.chapterDiagToken = token;
  }

  String? currentGestureSessionId(String readerInstanceId) =>
      _stateFor(readerInstanceId)?.activeSession?.id;

  /// reader_page 自主生成 gestureSessionId 后调用此方法同步给诊断系统，
  /// 使 debug 日志能记录到与 FSM 一致的 session ID。
  /// Release 包中 [enabled]=false，此方法立即返回，无任何副作用。
  void onGestureSessionIdAssigned(
    String readerInstanceId,
    String sessionId,
  ) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    s.emit(
      'gestureSessionIdAssigned',
      session: s.activeSession,
      extra: {'assignedSessionId': sessionId},
    );
  }

  void onPointerDown(
    String readerInstanceId,
    PointerDownEvent e, {
    required int activePointerCount,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;

    final existing = s.pointerSessions[e.pointer];
    if (existing != null) {
      existing.touch(e.pointer, e.position);
      s.emit(
        'pointerDown',
        session: existing,
        extra: {
          'pointerId': e.pointer,
          'activePointerCount': activePointerCount,
          'primaryPointer': existing.primaryPointer,
          'positionDx': e.position.dx,
          'positionDy': e.position.dy,
          'reusedSession': true,
        },
      );
      return;
    }

    GestureDiagSession session;
    if (activePointerCount <= 1) {
      session = s.startSession(primaryPointer: e.pointer);
    } else if (s.activeSession != null) {
      session = s.activeSession!;
      session.promoteToMultiTouch();
    } else {
      session = s.startSession(primaryPointer: e.pointer);
      session.promoteToMultiTouch();
    }

    session.touch(e.pointer, e.position);
    s.pointerSessions[e.pointer] = session;

    s.emit(
      'pointerDown',
      session: session,
      extra: {
        'pointerId': e.pointer,
        'pointerIds': session.pointerIds.toList(),
        'activePointerCount': activePointerCount,
        'primaryPointer': session.primaryPointer,
        'positionDx': e.position.dx,
        'positionDy': e.position.dy,
      },
    );

    if (activePointerCount >= 2) {
      s.emit(
        'secondPointerDetected',
        session: session,
        extra: {
          'pointerId': e.pointer,
          'pointerIds': session.pointerIds.toList(),
          'activePointerCount': activePointerCount,
        },
      );
    }
  }

  void onPointerMove(String readerInstanceId, PointerMoveEvent e) {
    _stateFor(
      readerInstanceId,
    )?.pointerSessions[e.pointer]?.accumulateMove(e.position);
  }

  void onPointerUp(
    String readerInstanceId,
    PointerUpEvent e, {
    required int activePointerCount,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;

    final session = s.pointerSessions.remove(e.pointer);
    if (session == null) return;

    session.releasePointer(e.pointer);
    s.emit(
      'pointerUp',
      session: session,
      extra: {
        'pointerId': e.pointer,
        'activePointerCount': activePointerCount,
        'pointerIds': session.pointerIds.toList(),
      },
    );

    if (session.pointerIds.isEmpty) {
      session.markPointerSequenceEnded();
      s.tryFinalizeSession(session, trigger: 'pointerUp');
    }
  }

  void onPointerCancel(
    String readerInstanceId,
    PointerCancelEvent e, {
    required int activePointerCount,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;

    final session = s.pointerSessions.remove(e.pointer);
    if (session == null) return;

    session.releasePointer(e.pointer);
    session.markCancelled();
    s.emit(
      'pointerCancel',
      session: session,
      extra: {
        'pointerId': e.pointer,
        'activePointerCount': activePointerCount,
        'pointerIds': session.pointerIds.toList(),
      },
    );

    if (session.pointerIds.isEmpty) {
      session.markPointerSequenceEnded();
      s.tryFinalizeSession(session, trigger: 'pointerCancel');
    }
  }

  void onScrollStart(
    String readerInstanceId,
    ScrollStartNotification n, {
    required int pageIndex,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.sessionForScroll();
    session?.markScrollStart();
    session?.startPage = pageIndex;
    s.captureMetrics(n.metrics);
    s.emit(
      'scrollStart',
      session: session,
      extra: {'depth': n.depth, 'pageIndex': pageIndex},
    );
  }

  void onScrollEnd(
    String readerInstanceId,
    ScrollEndNotification n, {
    required int pageIndex,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.sessionForScroll();
    session?.markScrollEnd();
    session?.endPage = pageIndex;
    s.captureMetrics(n.metrics);
    s.emit(
      'scrollEnd',
      session: session,
      extra: {'depth': n.depth, 'pageIndex': pageIndex},
    );
    if (session != null &&
        session.pointerSequenceEnded &&
        session.pointerIds.isEmpty &&
        session.awaitingScrollEnd) {
      session.cancelFinalizeTimer();
      s.finalizeSession(session, reason: 'scrollEnd');
    }
  }

  void onScrollUpdate(String readerInstanceId) {
    _stateFor(readerInstanceId)?.sessionForScroll()?.scrollUpdateCount++;
  }

  void onOverscroll(
    String readerInstanceId, {
    required double overscroll,
    required bool towardEnd,
    required bool atChapterEdge,
    required bool accepted,
    required String rejectReason,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.sessionForScroll();
    session?.recordOverscroll(overscroll);
    final ctx = _EdgeDiagContext(
      triggeringGestureSessionId: session?.id,
      inputSource: 'touchSwipe',
    );
    s.emit(
      'overscroll',
      session: session,
      extra: {
        'overscroll': overscroll,
        'towardEnd': towardEnd,
        'atChapterEdge': atChapterEdge,
        'accepted': accepted,
        'rejectReason': rejectReason,
        'overscrollCount': session?.overscrollCount,
        'maxAbsOverscroll': session?.maxAbsOverscroll,
        ...ctx.toFields(),
      },
    );
    if (atChapterEdge) {
      s.emit(
        'edgeCandidateObserved',
        session: session,
        extra: {
          'towardEnd': towardEnd,
          'overscroll': overscroll,
          'accepted': accepted,
          ...ctx.toFields(),
        },
      );
    }
    if (!accepted && atChapterEdge && overscroll.abs() >= 6) {
      s.emit(
        'edgeGateRejected',
        session: session,
        extra: {
          'towardEnd': towardEnd,
          'rejectReason': rejectReason,
          ...ctx.toFields(),
        },
      );
    }
  }

  void onPageChanged(
    String readerInstanceId, {
    required int fromPage,
    required int toPage,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.sessionForScroll();
    session?.pageChanged = true;
    session?.endPage = toPage;
    s.pageIndex = toPage;
    s.emit(
      'pageChanged',
      session: session,
      extra: {'fromPage': fromPage, 'toPage': toPage},
    );
  }

  void onPhysicsLocked(String readerInstanceId, {required String reason}) {
    _stateFor(
      readerInstanceId,
    )?.emit('pagePhysicsLocked', extra: {'reason': reason});
  }

  void onPhysicsUnlocked(String readerInstanceId, {required String reason}) {
    _stateFor(
      readerInstanceId,
    )?.emit('pagePhysicsUnlocked', extra: {'reason': reason});
  }

  void onEdgeGuardOutcome(
    String readerInstanceId, {
    required ChapterEdgeOutcome outcome,
    required bool goNext,
    required bool scrollStyle,
    required String inputSource,
    int? chapterRequestId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final sessionId = scrollStyle ? s.activeSession?.id : null;
    s.lastEdgeContext = _EdgeDiagContext(
      triggeringGestureSessionId: sessionId,
      inputSource: inputSource,
      chapterRequestId: chapterRequestId,
    );
    s.emit(
      'edgeGuardOutcome',
      extra: {
        'outcome': outcome.name,
        'goNext': goNext,
        'scrollStyle': scrollStyle,
        'edgeGuard': s.edgeGuard?.debugSnapshot(),
        ...s.lastEdgeContext!.toFields(),
      },
    );
  }

  void onAdjacentOpenRequested(
    String readerInstanceId, {
    required bool goNext,
    required String inputSource,
    int? chapterRequestId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final ctx =
        s.lastEdgeContext ??
        _EdgeDiagContext(
          inputSource: inputSource,
          chapterRequestId: chapterRequestId,
        );
    s.emit(
      'adjacentOpenRequested',
      extra: {
        'goNext': goNext,
        ...ctx.toFields(),
        if (chapterRequestId != null) 'chapterRequestId': chapterRequestId,
      },
    );
  }

  void onChapterLoadStarted({
    required int chapterRequestId,
    String? readerInstanceId,
    String? triggeringGestureSessionId,
    String? inputSource,
    String? previousChapterDiagToken,
  }) {
    if (!enabled) return;
    final rid = readerInstanceId ?? _activeReaderId;
    final state = _stateFor(rid);
    final prevToken =
        previousChapterDiagToken ?? state?.chapterDiagToken ?? 'unknown';
    _chapterRequests[chapterRequestId] = _ChapterRequestContext(
      chapterRequestId: chapterRequestId,
      readerInstanceId: rid,
      triggeringGestureSessionId: triggeringGestureSessionId,
      inputSource: inputSource ?? 'unknown',
      previousChapterDiagToken: prevToken,
    );
    _printLine(
      event: 'chapterLoadStarted',
      readerInstanceId: rid,
      state: state,
      extra: {
        'chapterRequestId': chapterRequestId,
        if (triggeringGestureSessionId != null)
          'triggeringGestureSessionId': triggeringGestureSessionId,
        if (inputSource != null) 'inputSource': inputSource,
        'previousChapterDiagToken': prevToken,
      },
    );
  }

  void onChapterLoadSucceeded({
    required int chapterRequestId,
    String? readerInstanceId,
    String? newChapterDiagToken,
  }) {
    if (!enabled) return;
    final rid = readerInstanceId ?? _activeReaderId;
    final ctx = _chapterRequests[chapterRequestId];
    final state = _stateFor(rid);
    final newToken = newChapterDiagToken ?? state?.chapterDiagToken;
    _printLine(
      event: 'chapterLoadSucceeded',
      readerInstanceId: rid,
      state: state,
      extra: {
        'chapterRequestId': chapterRequestId,
        if (ctx != null) ...{
          'triggeringGestureSessionId': ctx.triggeringGestureSessionId,
          'inputSource': ctx.inputSource,
          'previousChapterDiagToken': ctx.previousChapterDiagToken,
        },
        if (newToken != null) 'newChapterDiagToken': newToken,
      },
    );
    _chapterRequests.remove(chapterRequestId);
  }

  void onChapterLoadFailed({
    required int chapterRequestId,
    required String reason,
    String? readerInstanceId,
  }) {
    if (!enabled) return;
    final rid = readerInstanceId ?? _activeReaderId;
    final ctx = _chapterRequests[chapterRequestId];
    _printLine(
      event: 'chapterLoadFailed',
      readerInstanceId: rid,
      state: _stateFor(rid),
      extra: {
        'chapterRequestId': chapterRequestId,
        'reason': reason,
        if (ctx != null) ...{
          'triggeringGestureSessionId': ctx.triggeringGestureSessionId,
          'inputSource': ctx.inputSource,
          'previousChapterDiagToken': ctx.previousChapterDiagToken,
        },
      },
    );
    _chapterRequests.remove(chapterRequestId);
  }

  void onStaleChapterResultDiscarded({
    required int chapterRequestId,
    String? readerInstanceId,
    String? reason,
  }) {
    if (!enabled) return;
    final ctx = _chapterRequests[chapterRequestId];
    _printLine(
      event: 'staleChapterResultDiscarded',
      readerInstanceId: readerInstanceId ?? ctx?.readerInstanceId,
      extra: {
        'chapterRequestId': chapterRequestId,
        if (reason != null) 'reason': reason,
        if (ctx != null) ...{
          'triggeringGestureSessionId': ctx.triggeringGestureSessionId,
          'inputSource': ctx.inputSource,
          'previousChapterDiagToken': ctx.previousChapterDiagToken,
        },
      },
    );
    _chapterRequests.remove(chapterRequestId);
  }

  void onTestActionMarker({
    required String phase,
    String? testRunId,
    String? scenarioId,
    String? actionId,
    String? actionPhase,
    String? timestamp,
  }) {
    if (!enabled) return;
    final event = phase == 'started'
        ? 'testActionStarted'
        : phase == 'completed'
        ? 'testActionCompleted'
        : 'testActionMarker';
    if (phase == 'started' &&
        testRunId != null &&
        ReaderGestureJsonlWriter.instance.testRunId == null) {
      unawaited(startTestRun(testRunId: testRunId));
    }
    _printLine(
      event: event,
      extra: {
        if (testRunId != null) 'testRunId': testRunId,
        if (scenarioId != null) 'scenarioId': scenarioId,
        if (actionId != null) 'actionId': actionId,
        if (actionPhase != null) 'actionPhase': actionPhase,
        'markerTimestamp':
            timestamp ?? DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  void onInteractionStarted({
    required int pointerCount,
    required double startScale,
    String? readerInstanceId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.activeSession;
    session?.interactionStarted = true;
    session?.interactionStartScale = startScale;
    session?.maxObservedScale = startScale;
    s.emit(
      'interactionStarted',
      session: session,
      extra: {
        'pointerCount': pointerCount,
        'startScale': startScale,
        'pageScrollStarted': session?.sawScrollStart ?? false,
      },
    );
  }

  void onInteractionUpdated({
    required double scale,
    required bool panChanged,
    String? readerInstanceId,
  }) {
    final session = _stateFor(readerInstanceId)?.activeSession;
    if (session == null) return;
    session.interactionUpdateCount++;
    if (scale > session.maxObservedScale) session.maxObservedScale = scale;
    if (panChanged) session.observedPanChange = true;
  }

  void onInteractionEnded({
    required double endScale,
    String? readerInstanceId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    final session = s.activeSession;
    session?.interactionEnded = true;
    session?.interactionEndScale = endScale;
    if (endScale > (session?.maxObservedScale ?? 1)) {
      session?.maxObservedScale = endScale;
    }
    final start = session?.interactionStartScale ?? 1.0;
    final maxScale = session?.maxObservedScale ?? endScale;
    s.emit(
      'interactionEnded',
      session: session,
      extra: {
        'endScale': endScale,
        'maxObservedScale': maxScale,
        'maxScaleDelta': maxScale - start,
        'observedScaleChange': (maxScale - start).abs() > 0.02,
        'observedPanChange': session?.observedPanChange ?? false,
        'interactionUpdateCount': session?.interactionUpdateCount ?? 0,
        'pageScrollStarted': session?.sawScrollStart ?? false,
      },
    );
  }

  void onGestureOwnerChanged({
    required String owner,
    required String reason,
    String? readerInstanceId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    s.emit('gestureOwnerChanged', extra: {'owner': owner, 'reason': reason});
  }

  void onGestureModeChanged({
    required String from,
    required String to,
    String? readerInstanceId,
  }) {
    final s = _stateFor(readerInstanceId);
    if (s == null) return;
    s.emit('gestureModeChanged', extra: {'from': from, 'to': to});
    if (to == 'pageDrag') {
      s.emit('pageGestureAccepted', extra: {'from': from});
    } else if (to == 'imageScaling') {
      s.emit('imageScaleAccepted', extra: {'from': from});
    } else if (to == 'imagePanning') {
      s.emit('imagePanAccepted', extra: {'from': from});
    }
  }

  void onEdgeSwipeAccepted(
    String readerInstanceId, {
    required String source,
    required bool goNext,
    String? gestureSessionId,
    String? physicalSwipeDirection,
    double? physicalDeltaDx,
    double? physicalDeltaDy,
    String? resolvedLogicalIntent,
    bool? r2l,
    bool? reverse,
    int? currentPageIndex,
    int? pageCount,
    bool? atFirstPage,
    bool? atLastPage,
    String? edgeStateBefore,
  }) {
    _stateFor(readerInstanceId)?.emit(
      'edgeSwipeAccepted',
      extra: {
        'source': source,
        'goNext': goNext,
        if (gestureSessionId != null) 'gestureSessionId': gestureSessionId,
        if (physicalSwipeDirection != null)
          'physicalSwipeDirection': physicalSwipeDirection,
        if (physicalDeltaDx != null) 'physicalDeltaDx': physicalDeltaDx,
        if (physicalDeltaDy != null) 'physicalDeltaDy': physicalDeltaDy,
        if (resolvedLogicalIntent != null)
          'resolvedLogicalIntent': resolvedLogicalIntent,
        if (r2l != null) 'r2l': r2l,
        if (reverse != null) 'reverse': reverse,
        if (currentPageIndex != null) 'currentPageIndex': currentPageIndex,
        if (pageCount != null) 'pageCount': pageCount,
        if (atFirstPage != null) 'atFirstPage': atFirstPage,
        if (atLastPage != null) 'atLastPage': atLastPage,
        if (edgeStateBefore != null) 'edgeStateBefore': edgeStateBefore,
      },
    );
  }

  void onEdgeSwipeRejected(
    String readerInstanceId, {
    required String reason,
    String? gestureSessionId,
    String? physicalSwipeDirection,
    double? physicalDeltaDx,
    double? physicalDeltaDy,
    String? resolvedLogicalIntent,
    bool? r2l,
    bool? reverse,
    int? currentPageIndex,
    int? pageCount,
    bool? atFirstPage,
    bool? atLastPage,
    String? edgeStateBefore,
  }) {
    _stateFor(readerInstanceId)?.emit(
      'edgeSwipeRejected',
      extra: {
        'rejectionReason': reason,
        'reason': reason,
        if (gestureSessionId != null) 'gestureSessionId': gestureSessionId,
        if (physicalSwipeDirection != null)
          'physicalSwipeDirection': physicalSwipeDirection,
        if (physicalDeltaDx != null) 'physicalDeltaDx': physicalDeltaDx,
        if (physicalDeltaDy != null) 'physicalDeltaDy': physicalDeltaDy,
        if (resolvedLogicalIntent != null)
          'resolvedLogicalIntent': resolvedLogicalIntent,
        if (r2l != null) 'r2l': r2l,
        if (reverse != null) 'reverse': reverse,
        if (currentPageIndex != null) 'currentPageIndex': currentPageIndex,
        if (pageCount != null) 'pageCount': pageCount,
        if (atFirstPage != null) 'atFirstPage': atFirstPage,
        if (atLastPage != null) 'atLastPage': atLastPage,
        if (edgeStateBefore != null) 'edgeStateBefore': edgeStateBefore,
      },
    );
  }

  void onEdgeStateChanged(
    String readerInstanceId, {
    required String state,
    required String action,
    required bool goNext,
    required String rejectReason,
    int? chapterRequestId,
  }) {
    _stateFor(readerInstanceId)?.emit(
      'edgeStateChanged',
      extra: {
        'edgeState': state,
        'edgeAction': action,
        'goNext': goNext,
        'rejectReason': rejectReason,
        if (chapterRequestId != null) 'chapterRequestId': chapterRequestId,
      },
    );
  }

  void onChapterSwitchDeduplicated(
    String readerInstanceId, {
    required String reason,
    int? chapterRequestId,
  }) {
    _stateFor(readerInstanceId)?.emit(
      'chapterSwitchDeduplicated',
      extra: {
        'reason': reason,
        if (chapterRequestId != null) 'chapterRequestId': chapterRequestId,
      },
    );
  }

  void onProgrammaticPageTurn(
    String readerInstanceId, {
    required String source,
    required int delta,
  }) {
    _stateFor(readerInstanceId)?.emit(
      'programmaticPageTurn',
      extra: {'source': source, 'delta': delta, 'inputSource': source},
    );
  }

  @visibleForTesting
  static String encodeForTest(Map<String, dynamic> payload) =>
      _encodePayload(payload);

  static const _logcatSafeChars = 3600;

  static void _printLine({
    required String event,
    _ReaderDiagState? state,
    String? readerInstanceId,
    GestureDiagSession? session,
    Map<String, dynamic>? extra,
  }) {
    if (!enabled) return;
    final payload = <String, dynamic>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      if (state != null)
        'elapsedMs': DateTime.now().difference(state.boot).inMilliseconds,
      'event': event,
      'readerInstanceId': readerInstanceId ?? state?.readerInstanceId,
      'gestureSessionId': session?.id,
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'versionName': BuildInfo.versionName,
      'versionCode': BuildInfo.versionCode,
      'appVersionSource': BuildInfo.appVersionSource,
      'buildMode': _buildModeLabel(),
      if (BuildInfo.flutterSdk != null) 'flutterSdk': BuildInfo.flutterSdk,
      'flutterSdkSource': BuildInfo.flutterSdkSource,
      if (state != null) ...state.contextFields(),
      if (session != null) ...{
        'pointerIds': session.pointerIds.toList(),
        'primaryPointer': session.primaryPointer,
        'activePointerCount': session.pointerIds.length,
      },
      if (extra != null) ...extra,
      if (ReaderGestureJsonlWriter.instance.testRunId != null)
        'testRunId': ReaderGestureJsonlWriter.instance.testRunId,
    };
    ReaderGestureJsonlWriter.instance.writePayload(payload);
    _emitLogcat(payload);
  }

  static void _emitLogcat(Map<String, dynamic> payload) {
    final event = payload['event'] as String? ?? '';
    if (event == 'gestureSummary') {
      final short = <String, dynamic>{
        'event': 'gestureSummaryShort',
        'timestamp': payload['timestamp'],
        'readerInstanceId': payload['readerInstanceId'],
        'gestureSessionId': payload['gestureSessionId'],
        'pageChanged': payload['pageChanged'],
        'sawScrollStart': payload['sawScrollStart'],
        'sawScrollEnd': payload['sawScrollEnd'],
        'scrollUpdateCount': payload['scrollUpdateCount'],
        'interactionStarted': payload['interactionStarted'],
        'durationMs': payload['durationMs'],
        'totalDx': payload['totalDx'],
        'totalDy': payload['totalDy'],
        'endReason': payload['endReason'],
        'overscrollCount': payload['overscrollCount'],
        'edgeIntent': payload['edgeIntent'],
        'fullInJsonl': true,
      };
      debugPrint('[ReaderGesture] ${_encodePayload(short)}');
      return;
    }
    final encoded = _encodePayload(payload);
    if (encoded.length <= _logcatSafeChars) {
      debugPrint('[ReaderGesture] $encoded');
      return;
    }
    _emitChunked(payload, encoded);
  }

  static void _emitChunked(Map<String, dynamic> payload, String encoded) {
    const chunkSize = 3000;
    final total = (encoded.length + chunkSize - 1) ~/ chunkSize;
    for (var i = 0; i < total; i++) {
      final part = encoded.substring(
        i * chunkSize,
        math.min((i + 1) * chunkSize, encoded.length),
      );
      final chunkPayload = <String, dynamic>{
        'event': 'eventChunk',
        'readerInstanceId': payload['readerInstanceId'],
        'gestureSessionId': payload['gestureSessionId'],
        'originalEvent': payload['event'],
        'chunkIndex': i,
        'chunkCount': total,
        'chunk': part,
      };
      debugPrint('[ReaderGesture] ${_encodePayload(chunkPayload)}');
    }
  }

  static String _buildModeLabel() {
    if (kDebugMode) return 'debug';
    if (kProfileMode) return 'profile';
    return 'release';
  }

  static String _encodePayload(Map<String, dynamic> payload) {
    return jsonEncode(payload, toEncodable: _sanitizeJsonValue);
  }

  static Object? _sanitizeJsonValue(Object? value) {
    if (value is double) {
      if (value.isNaN || value.isInfinite) return null;
      if (value == 0.0 && value.isNegative) return 0.0;
      return value;
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _sanitizeJsonValue(v)));
    }
    if (value is List) {
      return value.map(_sanitizeJsonValue).toList();
    }
    return value;
  }
}

class _ChapterRequestContext {
  _ChapterRequestContext({
    required this.chapterRequestId,
    this.readerInstanceId,
    this.triggeringGestureSessionId,
    this.inputSource,
    this.previousChapterDiagToken,
  });

  final int chapterRequestId;
  final String? readerInstanceId;
  final String? triggeringGestureSessionId;
  final String? inputSource;
  final String? previousChapterDiagToken;
}

class _EdgeDiagContext {
  _EdgeDiagContext({
    this.triggeringGestureSessionId,
    this.inputSource = 'unknown',
    this.chapterRequestId,
  });

  final String? triggeringGestureSessionId;
  final String inputSource;
  final int? chapterRequestId;

  Map<String, dynamic> toFields() => {
    if (triggeringGestureSessionId != null)
      'triggeringGestureSessionId': triggeringGestureSessionId,
    'inputSource': inputSource,
    if (chapterRequestId != null) 'chapterRequestId': chapterRequestId,
  };
}

class _ReaderDiagState {
  _ReaderDiagState(this.readerInstanceId);

  final String readerInstanceId;
  final DateTime boot = DateTime.now();
  bool initialized = false;

  int sessionCounter = 0;
  GestureDiagSession? activeSession;
  final Map<int, GestureDiagSession> pointerSessions = {};
  final Set<String> pendingFinalizeSessionIds = {};

  String readMode = 'h';
  bool r2l = false;
  bool reverse = false;
  String chapterDiagToken = 'none';
  int pageIndex = 1;
  int pageCount = 0;
  bool hasPreviousChapter = false;
  bool hasNextChapter = false;
  bool pageZoomed = false;
  bool multiTouch = false;
  String physicsType = 'PageScrollPhysics';
  double? pageControllerPage;
  bool pageControllerHasClients = false;
  ChapterEdgeGuard? edgeGuard;
  Size? logicalSize;
  double? devicePixelRatio;

  double? lastPixels;
  double? lastMinExtent;
  double? lastMaxExtent;
  AxisDirection? lastAxisDirection;

  _EdgeDiagContext? lastEdgeContext;
  bool detached = false;

  Map<String, dynamic> contextFields() => {
    'readMode': readMode,
    'r2l': r2l,
    'reverse': reverse,
    'logicalWidth': logicalSize?.width,
    'logicalHeight': logicalSize?.height,
    'devicePixelRatio': devicePixelRatio,
    'chapterDiagToken': chapterDiagToken,
    'pageIndex': pageIndex,
    'pageCount': pageCount,
    'atFirstPage': pageIndex <= 1,
    'atLastPage': pageCount > 0 && pageIndex >= pageCount,
    'hasPreviousChapter': hasPreviousChapter,
    'hasNextChapter': hasNextChapter,
    'pageZoomed': pageZoomed,
    'multiTouch': multiTouch,
    'physicsType': physicsType,
    'pageControllerHasClients': pageControllerHasClients,
    'pageControllerPage': pageControllerPage,
    'scrollPixels': lastPixels,
    'minScrollExtent': lastMinExtent,
    'maxScrollExtent': lastMaxExtent,
    'axisDirection': lastAxisDirection?.name,
  };

  void emit(
    String event, {
    GestureDiagSession? session,
    Map<String, dynamic>? extra,
  }) {
    if (detached) return;
    ReaderGestureDiagnostics._printLine(
      event: event,
      state: this,
      readerInstanceId: readerInstanceId,
      session: session ?? activeSession,
      extra: extra,
    );
  }

  GestureDiagSession startSession({required int primaryPointer}) {
    if (activeSession != null && !activeSession!.summaryEmitted) {
      activeSession!.cancelFinalizeTimer();
      if (activeSession!.pointerIds.isEmpty) {
        finalizeSession(activeSession!, reason: 'supersededByNewSession');
      }
    }
    final id =
        'gs-${++sessionCounter}-${DateTime.now().microsecondsSinceEpoch}';
    final session = GestureDiagSession(
      id: id,
      primaryPointer: primaryPointer,
      startTime: DateTime.now(),
      startPage: pageIndex,
      endPage: pageIndex,
    );
    activeSession = session;
    return session;
  }

  GestureDiagSession? sessionForScroll() => activeSession;

  void tryFinalizeSession(
    GestureDiagSession session, {
    required String trigger,
  }) {
    if (session.finalized || session.summaryEmitted) return;
    if (session.pointerIds.isNotEmpty) return;

    if (session.sawScrollStart && !session.sawScrollEnd) {
      session.awaitingScrollEnd = true;
      session.pendingFinalizeReason = trigger;
      pendingFinalizeSessionIds.add(session.id);
      session.scheduleFinalizeTimer(() {
        if (!session.finalized && session.pointerIds.isEmpty) {
          finalizeSession(
            session,
            reason: '${session.pendingFinalizeReason}+scrollEndTimeout',
          );
        }
      });
      return;
    }

    finalizeSession(session, reason: trigger);
  }

  void finalizeSession(GestureDiagSession session, {required String reason}) {
    if (session.finalized || session.summaryEmitted) return;
    session.cancelFinalizeTimer();
    session.finalizeTotals();
    session.lockedByMultiTouch = multiTouch;
    session.lockedByZoom = pageZoomed;
    session.finalized = true;
    session.summaryEmitted = true;
    pendingFinalizeSessionIds.remove(session.id);
    if (activeSession == session) activeSession = null;

    final dirs = SwipeDirectionFields.compute(
      totalDx: session.totalDx,
      totalDy: session.totalDy,
      readMode: readMode,
      r2l: r2l,
      reverse: reverse,
      atFirstPage: pageIndex <= 1,
      atLastPage: pageCount > 0 && pageIndex >= pageCount,
    );

    final durationMs = DateTime.now()
        .difference(session.startTime)
        .inMilliseconds;
    final vel = session.averageVelocity(durationMs);

    emit(
      'gestureSummary',
      session: session,
      extra: {
        'endReason': reason,
        'durationMs': durationMs,
        'totalDx': session.totalDx,
        'totalDy': session.totalDy,
        'signedPrimaryAxisDistance': dirs.signedPrimaryAxisDistance,
        'primaryAxisDistance': dirs.primaryAxisDistance,
        'crossAxisDistance': dirs.crossAxisDistance,
        'averageVelocityX': vel.dx,
        'averageVelocityY': vel.dy,
        'dominantAxis': dirs.dominantAxis,
        'physicalSwipeDirection': dirs.physicalSwipeDirection,
        'logicalReadingDirection': dirs.logicalReadingDirection,
        'edgeIntent': dirs.edgeIntent,
        'pointerEnd': reason.contains('Cancel') ? 'pointerCancel' : 'pointerUp',
        'cancelled': session.cancelled,
        'sawScrollStart': session.sawScrollStart,
        'scrollUpdateCount': session.scrollUpdateCount,
        'overscrollCount': session.overscrollCount,
        'firstOverscroll': session.firstOverscroll,
        'maxAbsOverscroll': session.maxAbsOverscroll,
        'sawScrollEnd': session.sawScrollEnd,
        'pageChanged': session.pageChanged,
        'startPage': session.startPage,
        'endPage': session.endPage,
        'lockedByMultiTouch': session.lockedByMultiTouch,
        'lockedByZoom': session.lockedByZoom,
        'interactionStarted': session.interactionStarted,
        'interactionEnded': session.interactionEnded,
        'maxScaleDelta':
            session.maxObservedScale - session.interactionStartScale,
        'observedScaleChange':
            (session.maxObservedScale - session.interactionStartScale).abs() >
            0.02,
        'observedPanChange': session.observedPanChange,
        'multiTouchSession': session.multiTouch,
        'edgeGuardAtEnd': edgeGuard?.debugSnapshot(),
      },
    );
  }

  void abortPendingSessions({required String reason}) {
    if (activeSession != null &&
        !activeSession!.summaryEmitted &&
        activeSession!.pointerIds.isEmpty) {
      finalizeSession(activeSession!, reason: reason);
    }
  }

  void captureMetrics(ScrollMetrics m) {
    lastPixels = m.pixels;
    lastMinExtent = m.minScrollExtent;
    lastMaxExtent = m.maxScrollExtent;
    lastAxisDirection = m.axisDirection;
  }

  void dispose({required bool aborted}) {
    detached = true;
    for (final session in pointerSessions.values.toSet()) {
      session.cancelFinalizeTimer();
    }
    pointerSessions.clear();
    if (activeSession != null &&
        !activeSession!.summaryEmitted &&
        activeSession!.pointerIds.isEmpty) {
      finalizeSession(
        activeSession!,
        reason: aborted ? 'readerAborted' : 'readerDisposed',
      );
    } else if (activeSession != null && !activeSession!.summaryEmitted) {
      activeSession!.cancelFinalizeTimer();
      activeSession!.markCancelled();
      activeSession!.pointerIds.clear();
      finalizeSession(activeSession!, reason: 'readerAbortedWithPointers');
    }
    activeSession = null;
    emit('readerDisposed');
  }
}

class SwipeDirectionFields {
  SwipeDirectionFields({
    required this.dominantAxis,
    required this.physicalSwipeDirection,
    required this.logicalReadingDirection,
    required this.edgeIntent,
    required this.signedPrimaryAxisDistance,
    required this.primaryAxisDistance,
    required this.crossAxisDistance,
  });

  final String dominantAxis;
  final String physicalSwipeDirection;
  final String logicalReadingDirection;
  final String edgeIntent;
  final double signedPrimaryAxisDistance;
  final double primaryAxisDistance;
  final double crossAxisDistance;

  static SwipeDirectionFields compute({
    required double totalDx,
    required double totalDy,
    required String readMode,
    required bool r2l,
    required bool reverse,
    required bool atFirstPage,
    required bool atLastPage,
  }) {
    // reverse 仅作诊断标注；业务映射只认 r2l，避免双重反转。
    final horizontalReading = readMode == 'h';
    final dominantByDelta = totalDx.abs() >= totalDy.abs();
    final dominantAxis = dominantByDelta ? 'horizontal' : 'vertical';

    final swipe = ReaderReadingDirection.physicalSwipe(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    final physical = ReaderReadingDirection.physicalLabel(swipe);
    final intent = ReaderReadingDirection.resolve(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
      r2l: r2l,
      atFirstPage: atFirstPage,
      atLastPage: atLastPage,
      requirePrimaryAxis: false,
    );
    final logical = ReaderReadingDirection.logicalReadingLabel(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
      r2l: r2l,
    );

    final edgeIntent = switch (intent) {
      ReadingNavIntent.towardNextChapter => 'nextChapter',
      ReadingNavIntent.towardPreviousChapter => 'previousChapter',
      _ => 'none',
    };

    final signedPrimary = ReaderReadingDirection.signedPrimaryDelta(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    final cross = ReaderReadingDirection.crossAbs(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    // reverse 仅作调用方上下文标注，不得参与二次反转（映射只认 r2l）。
    reverse;

    return SwipeDirectionFields(
      dominantAxis: dominantAxis,
      physicalSwipeDirection: physical,
      logicalReadingDirection: logical,
      edgeIntent: edgeIntent,
      signedPrimaryAxisDistance: signedPrimary,
      primaryAxisDistance: signedPrimary.abs(),
      crossAxisDistance: cross,
    );
  }
}

class GestureDiagSession {
  GestureDiagSession({
    required this.id,
    required this.primaryPointer,
    required this.startTime,
    required this.startPage,
    required this.endPage,
  });

  static const _finalizeTimeoutMs = 800;

  final String id;
  final int primaryPointer;
  final DateTime startTime;
  int startPage;
  int endPage;

  final Set<int> pointerIds = {};
  bool multiTouch = false;
  bool cancelled = false;
  bool finalized = false;
  bool summaryEmitted = false;
  bool pointerSequenceEnded = false;
  bool awaitingScrollEnd = false;
  String pendingFinalizeReason = '';
  Timer? finalizeTimer;

  Offset? _firstPos;
  Offset? _lastPos;
  double totalDx = 0;
  double totalDy = 0;

  bool sawScrollStart = false;
  bool sawScrollEnd = false;
  int scrollUpdateCount = 0;
  int overscrollCount = 0;
  double? firstOverscroll;
  double maxAbsOverscroll = 0;

  bool pageChanged = false;
  bool interactionStarted = false;
  bool interactionEnded = false;
  double interactionStartScale = 1.0;
  double interactionEndScale = 1.0;
  double maxObservedScale = 1.0;
  int interactionUpdateCount = 0;
  bool observedPanChange = false;
  bool lockedByMultiTouch = false;
  bool lockedByZoom = false;

  void touch(int pointer, Offset pos) {
    pointerIds.add(pointer);
    _firstPos ??= pos;
    _lastPos = pos;
  }

  void releasePointer(int pointer) => pointerIds.remove(pointer);

  void promoteToMultiTouch() => multiTouch = true;

  void markCancelled() => cancelled = true;

  void markPointerSequenceEnded() => pointerSequenceEnded = true;

  void accumulateMove(Offset pos) {
    if (_lastPos != null) {
      totalDx += pos.dx - _lastPos!.dx;
      totalDy += pos.dy - _lastPos!.dy;
    }
    _lastPos = pos;
  }

  void markScrollStart() => sawScrollStart = true;
  void markScrollEnd() => sawScrollEnd = true;

  void recordOverscroll(double value) {
    overscrollCount++;
    firstOverscroll ??= value;
    final abs = value.abs();
    if (abs > maxAbsOverscroll) maxAbsOverscroll = abs;
  }

  void finalizeTotals() {
    if (_firstPos != null && _lastPos != null) {
      totalDx = _lastPos!.dx - _firstPos!.dx;
      totalDy = _lastPos!.dy - _firstPos!.dy;
    }
  }

  void scheduleFinalizeTimer(void Function() onTimeout) {
    cancelFinalizeTimer();
    finalizeTimer = Timer(
      const Duration(milliseconds: _finalizeTimeoutMs),
      onTimeout,
    );
  }

  void cancelFinalizeTimer() {
    finalizeTimer?.cancel();
    finalizeTimer = null;
  }

  Offset averageVelocity(int durationMs) {
    if (durationMs <= 0) return Offset.zero;
    final sec = durationMs / 1000.0;
    return Offset(totalDx / sec, totalDy / sec);
  }
}
