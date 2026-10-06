import 'package:copymanga_flutter/chapter_edge_fsm.dart';
import 'package:copymanga_flutter/reader_reading_direction.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChapterEdgeFsm', () {
    late ChapterEdgeFsm fsm;
    var now = 1000;
    var reqSeq = 0;

    setUp(() {
      now = 1000;
      reqSeq = 0;
      ChapterEdgeFsm.resetRequestIdSeqForTest();
      fsm = ChapterEdgeFsm(
        confirmWindow: const Duration(seconds: 2),
        nowMs: () => now,
        nextRequestId: () => ++reqSeq,
      );
    });

    ChapterEdgeFsmResult swipe({
      required String session,
      required bool goNext,
      bool hasAdjacent = true,
    }) {
      return fsm.handle(
        event: ChapterEdgeFsmEvent.independentSwipeCompleted,
        goNext: goNext,
        gestureSessionId: session,
        intent: goNext
            ? ReadingNavIntent.towardNextChapter
            : ReadingNavIntent.towardPreviousChapter,
        hasAdjacent: hasAdjacent,
      );
    }

    test('尾页第一次向下一章方向 swipe → armedNext', () {
      final r = swipe(session: 'gs-1', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(r.state, ChapterEdgeFsmState.armedNext);
    });

    test('尾页第二次独立同向 swipe → 单次 switchNext', () {
      swipe(session: 'gs-1', goNext: true);
      final r = swipe(session: 'gs-2', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r.state, ChapterEdgeFsmState.switchingNext);
      expect(r.chapterRequestId, 1);
      final third = swipe(session: 'gs-3', goNext: true);
      expect(third.action, ChapterEdgeFsmAction.deduplicated);
      expect(third.rejectReason, 'switchingInProgress');
    });

    test('首页对应 previous', () {
      final r1 = swipe(session: 'gs-1', goNext: false);
      expect(r1.state, ChapterEdgeFsmState.armedPrevious);
      final r2 = swipe(session: 'gs-2', goNext: false);
      expect(r2.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r2.state, ChapterEdgeFsmState.switchingPrevious);
    });

    test('同一个 gestureSessionId 重复事件不算第二划', () {
      swipe(session: 'gs-1', goNext: true);
      final r = swipe(session: 'gs-1', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.deduplicated);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
    });

    test('第二划方向相反 → 重新武装', () {
      swipe(session: 'gs-1', goNext: true);
      final r = swipe(session: 'gs-2', goNext: false);
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(r.state, ChapterEdgeFsmState.armedPrevious);
    });

    test('第二划超时 / armedNext 超时', () {
      swipe(session: 'gs-1', goNext: true);
      now += 2500;
      final r = swipe(session: 'gs-2', goNext: true);
      // 超时后当作新的第一划
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(r.state, ChapterEdgeFsmState.armedNext);
    });

    test('armedPrevious 超时', () {
      swipe(session: 'gs-1', goNext: false);
      now += 2500;
      final r = swipe(session: 'gs-2', goNext: false);
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(r.state, ChapterEdgeFsmState.armedPrevious);
    });

    test('第一划后离开边界', () {
      swipe(session: 'gs-1', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.leftBoundary);
      expect(fsm.state, ChapterEdgeFsmState.idle);
      final r = swipe(session: 'gs-2', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
    });

    test('真实 pageChanged 离开边界 → 重置 armed', () {
      swipe(session: 'gs-1', goNext: true);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
      fsm.handle(event: ChapterEdgeFsmEvent.pageChanged);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('边界回弹无 pageChanged → armedNext 保留', () {
      swipe(session: 'gs-1', goNext: true);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
      // 无 pageChanged / leftBoundary
      final r = swipe(session: 'gs-2', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
    });

    test('pointerCancel / gestureCancelled', () {
      swipe(session: 'gs-1', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.gestureCancelled);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('图片缩放开始重置', () {
      swipe(session: 'gs-1', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.imageScaleStarted);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('阅读模式变化重置', () {
      swipe(session: 'gs-1', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.readingModeChanged);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('App 进入后台重置', () {
      swipe(session: 'gs-1', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.appPaused);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('switching 期间第三划去重 / 只触发一次 chapterRequestId', () {
      swipe(session: 'gs-1', goNext: true);
      final open = swipe(session: 'gs-2', goNext: true);
      expect(open.chapterRequestId, 1);
      final r = swipe(session: 'gs-3', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.deduplicated);
      expect(r.chapterRequestId, 1);
    });

    test('加载失败后恢复可重新触发', () {
      swipe(session: 'gs-1', goNext: true);
      final open = swipe(session: 'gs-2', goNext: true);
      fsm.handle(
        event: ChapterEdgeFsmEvent.chapterRequestFailed,
        chapterRequestId: open.chapterRequestId,
      );
      expect(fsm.state, ChapterEdgeFsmState.idle);
      final again = swipe(session: 'gs-3', goNext: true);
      expect(again.action, ChapterEdgeFsmAction.showConfirmHint);
    });

    test('加载成功后清理', () {
      swipe(session: 'gs-1', goNext: true);
      swipe(session: 'gs-2', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.chapterRequestSucceeded);
      expect(fsm.state, ChapterEdgeFsmState.idle);
      expect(fsm.activeChapterRequestId, isNull);
    });

    test('旧 chapterRequestId 返回不得污染当前状态', () {
      swipe(session: 'gs-1', goNext: true);
      final open = swipe(session: 'gs-2', goNext: true);
      final stale = fsm.handle(
        event: ChapterEdgeFsmEvent.chapterRequestFailed,
        chapterRequestId: (open.chapterRequestId ?? 0) + 99,
      );
      expect(stale.action, ChapterEdgeFsmAction.deduplicated);
      expect(fsm.state, ChapterEdgeFsmState.switchingNext);
    });

    test('无邻章 → atEnd', () {
      final r = swipe(session: 'gs-1', goNext: true, hasAdjacent: false);
      expect(r.action, ChapterEdgeFsmAction.showAtEnd);
    });

    test('prefetch 命中路径：成功后可再次双滑', () {
      swipe(session: 'gs-1', goNext: true);
      swipe(session: 'gs-2', goNext: true);
      fsm.handle(event: ChapterEdgeFsmEvent.chapterRequestSucceeded);
      final r = swipe(session: 'gs-3', goNext: true);
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
    });

    test('manualEdgeAction 与 swipe 共享确认语义', () {
      final r1 = fsm.handle(
        event: ChapterEdgeFsmEvent.manualEdgeAction,
        goNext: true,
        hasAdjacent: true,
      );
      expect(r1.action, ChapterEdgeFsmAction.showConfirmHint);
      final r2 = fsm.handle(
        event: ChapterEdgeFsmEvent.manualEdgeAction,
        goNext: true,
        hasAdjacent: true,
      );
      expect(r2.action, ChapterEdgeFsmAction.requestChapterSwitch);
    });

    test('auxOverscroll 第二划可换章', () {
      fsm.handle(
        event: ChapterEdgeFsmEvent.auxOverscroll,
        goNext: true,
        gestureSessionId: 'gs-a',
        intent: ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
      );
      final r = fsm.handle(
        event: ChapterEdgeFsmEvent.auxOverscroll,
        goNext: true,
        gestureSessionId: 'gs-b',
        intent: ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
      );
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
    });

    test('条漫 ScrollUpdate 兜底与 Overscroll 必须共享同一确认状态', () {
      // 部分 Android 在顶住条漫底部时，首划只发 ScrollUpdate；下一划才发
      // Overscroll。两种通知都必须送入同一 FSM，不能由旧 Guard 另行计数。
      final fromScrollUpdateFallback = fsm.handle(
        event: ChapterEdgeFsmEvent.auxOverscroll,
        goNext: true,
        gestureSessionId: 'scroll-update-1',
        intent: ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
        fromAuxOverscroll: true,
      );
      expect(
        fromScrollUpdateFallback.action,
        ChapterEdgeFsmAction.showConfirmHint,
      );

      final fromOverscroll = fsm.handle(
        event: ChapterEdgeFsmEvent.auxOverscroll,
        goNext: true,
        gestureSessionId: 'overscroll-2',
        intent: ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
        fromAuxOverscroll: true,
      );
      expect(fromOverscroll.action, ChapterEdgeFsmAction.requestChapterSwitch);
    });
  });

  group('ReaderReadingDirection 日漫横向 r2l=true', () {
    test('最后一页 dx>0 → next chapter', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: 90,
          totalDy: 1,
          horizontalReading: true,
          r2l: true,
          atFirstPage: false,
          atLastPage: true,
        ),
        ReadingNavIntent.towardNextChapter,
      );
    });

    test('最后一页 dx<0 → 不得 next', () {
      final intent = ReaderReadingDirection.resolve(
        totalDx: -80,
        totalDy: 2,
        horizontalReading: true,
        r2l: true,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(intent, isNot(ReadingNavIntent.towardNextChapter));
      expect(intent, ReadingNavIntent.towardPreviousPage);
    });

    test('第一页 dx<0 → previous chapter', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: -90,
          totalDy: 0,
          horizontalReading: true,
          r2l: true,
          atFirstPage: true,
          atLastPage: false,
        ),
        ReadingNavIntent.towardPreviousChapter,
      );
    });

    test('第一页 dx>0 → 不得 previous', () {
      final intent = ReaderReadingDirection.resolve(
        totalDx: 90,
        totalDy: 0,
        horizontalReading: true,
        r2l: true,
        atFirstPage: true,
        atLastPage: false,
      );
      expect(intent, isNot(ReadingNavIntent.towardPreviousChapter));
      expect(intent, ReadingNavIntent.towardNextPage);
    });

    test('resolveSwipeIntent 与 resolve 一致（0-based index）', () {
      expect(
        ReaderReadingDirection.resolveSwipeIntent(
          physicalDeltaDx: 100,
          physicalDeltaDy: 0,
          horizontalReading: true,
          r2l: true,
          currentPageIndex: 4,
          pageCount: 5,
        ),
        ReadingNavIntent.towardNextChapter,
      );
      expect(
        ReaderReadingDirection.resolveSwipeIntent(
          physicalDeltaDx: -100,
          physicalDeltaDy: 0,
          horizontalReading: true,
          r2l: true,
          currentPageIndex: 0,
          pageCount: 5,
        ),
        ReadingNavIntent.towardPreviousChapter,
      );
    });
  });

  group('ReaderReadingDirection 非日漫横向 r2l=false', () {
    test('最后一页 dx<0 → next chapter', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: -80,
          totalDy: 2,
          horizontalReading: true,
          r2l: false,
          atFirstPage: false,
          atLastPage: true,
        ),
        ReadingNavIntent.towardNextChapter,
      );
    });

    test('第一页 dx>0 → previous chapter', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: 90,
          totalDy: 1,
          horizontalReading: true,
          r2l: false,
          atFirstPage: true,
          atLastPage: false,
        ),
        ReadingNavIntent.towardPreviousChapter,
      );
    });

    test('与日漫模式映射互为反向', () {
      const dx = 100.0;
      final manga = ReaderReadingDirection.resolve(
        totalDx: dx,
        totalDy: 0,
        horizontalReading: true,
        r2l: true,
        atFirstPage: false,
        atLastPage: true,
      );
      final ltr = ReaderReadingDirection.resolve(
        totalDx: dx,
        totalDy: 0,
        horizontalReading: true,
        r2l: false,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(manga, ReadingNavIntent.towardNextChapter);
      expect(ltr, ReadingNavIntent.towardPreviousPage);
    });
  });

  group('ReaderReadingDirection 纵向', () {
    test('上滑 → next（不受 r2l 影响）', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: 1,
          totalDy: -100,
          horizontalReading: false,
          r2l: true,
          atFirstPage: false,
          atLastPage: true,
        ),
        ReadingNavIntent.towardNextChapter,
      );
      expect(
        ReaderReadingDirection.resolve(
          totalDx: 1,
          totalDy: -100,
          horizontalReading: false,
          r2l: false,
          atFirstPage: false,
          atLastPage: true,
        ),
        ReadingNavIntent.towardNextChapter,
      );
    });

    test('下滑 → previous', () {
      expect(
        ReaderReadingDirection.resolve(
          totalDx: 0,
          totalDy: 120,
          horizontalReading: false,
          r2l: true,
          atFirstPage: true,
          atLastPage: false,
        ),
        ReadingNavIntent.towardPreviousChapter,
      );
    });
  });

  group('日漫边界 FSM 集成（统一映射）', () {
    late ChapterEdgeFsm fsm;
    var now = 1000;
    var reqSeq = 0;

    setUp(() {
      now = 1000;
      reqSeq = 0;
      ChapterEdgeFsm.resetRequestIdSeqForTest();
      fsm = ChapterEdgeFsm(
        confirmWindow: const Duration(seconds: 2),
        nowMs: () => now,
        nextRequestId: () => ++reqSeq,
      );
    });

    ChapterEdgeFsmResult edgeSwipe({
      required String session,
      required double dx,
      required bool r2l,
      required bool atLast,
      required bool atFirst,
    }) {
      final intent = ReaderReadingDirection.resolve(
        totalDx: dx,
        totalDy: 0,
        horizontalReading: true,
        r2l: r2l,
        atFirstPage: atFirst,
        atLastPage: atLast,
      );
      return fsm.handle(
        event: ChapterEdgeFsmEvent.independentSwipeCompleted,
        gestureSessionId: session,
        intent: intent,
        goNext: intent == ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
      );
    }

    test('日漫末页第一次向右 → armedNext', () {
      final r = edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      expect(r.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(r.state, ChapterEdgeFsmState.armedNext);
      expect(r.goNext, isTrue);
    });

    test('日漫末页第二次不同 session 向右 → switchNext', () {
      edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      final r = edgeSwipe(
        session: 'gs-2',
        dx: 130,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r.state, ChapterEdgeFsmState.switchingNext);
      expect(r.chapterRequestId, 1);
    });

    test('日漫末页第二次相同 session → 不换章', () {
      edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      final r = edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      expect(r.action, ChapterEdgeFsmAction.deduplicated);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
    });

    test('日漫末页第一次向右、第二次向左 → 不换下一章', () {
      edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      final r = edgeSwipe(
        session: 'gs-2',
        dx: -120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      // 左滑在末页是 previous page，不是章节边界意图
      expect(r.action, ChapterEdgeFsmAction.none);
      expect(r.rejectReason, 'intentNotChapterEdge');
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
    });

    test('日漫末页向左不得 armedNext', () {
      final r = edgeSwipe(
        session: 'gs-1',
        dx: -120,
        r2l: true,
        atLast: true,
        atFirst: false,
      );
      expect(r.action, ChapterEdgeFsmAction.none);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('日漫首页向左双滑 → previous chapter', () {
      final r1 = edgeSwipe(
        session: 'gs-1',
        dx: -120,
        r2l: true,
        atLast: false,
        atFirst: true,
      );
      expect(r1.state, ChapterEdgeFsmState.armedPrevious);
      final r2 = edgeSwipe(
        session: 'gs-2',
        dx: -130,
        r2l: true,
        atLast: false,
        atFirst: true,
      );
      expect(r2.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r2.state, ChapterEdgeFsmState.switchingPrevious);
    });

    test('日漫首页向右不得 previous chapter', () {
      final r = edgeSwipe(
        session: 'gs-1',
        dx: 120,
        r2l: true,
        atLast: false,
        atFirst: true,
      );
      expect(r.action, ChapterEdgeFsmAction.none);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    test('非日漫末页向左双滑 → next chapter', () {
      edgeSwipe(
        session: 'gs-1',
        dx: -120,
        r2l: false,
        atLast: true,
        atFirst: false,
      );
      final r = edgeSwipe(
        session: 'gs-2',
        dx: -130,
        r2l: false,
        atLast: true,
        atFirst: false,
      );
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r.goNext, isTrue);
    });

    test('非日漫首页向右双滑 → previous chapter', () {
      edgeSwipe(
        session: 'gs-a',
        dx: 120,
        r2l: false,
        atLast: false,
        atFirst: true,
      );
      final r = edgeSwipe(
        session: 'gs-b',
        dx: 130,
        r2l: false,
        atLast: false,
        atFirst: true,
      );
      expect(r.action, ChapterEdgeFsmAction.requestChapterSwitch);
      expect(r.goNext, isFalse);
    });
  });

  group('EdgeSwipeGeometry + overscroll', () {
    test('日漫末页右滑几何接受 next chapter', () {
      final g = EdgeSwipeGeometry.evaluate(
        totalDx: 200,
        totalDy: 0,
        durationMs: 180,
        viewport: const Size(360, 640),
        horizontalReading: true,
        r2l: true,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(g.accepted, isTrue);
      expect(g.intent, ReadingNavIntent.towardNextChapter);
    });

    test('日漫末页左滑几何拒绝 next', () {
      final g = EdgeSwipeGeometry.evaluate(
        totalDx: -200,
        totalDy: 0,
        durationMs: 180,
        viewport: const Size(360, 640),
        horizontalReading: true,
        r2l: true,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(g.accepted, isFalse);
      expect(g.intent, isNot(ReadingNavIntent.towardNextChapter));
    });

    test('overscroll 正值在末页 → next，且不二次应用 r2l', () {
      expect(
        ReaderReadingDirection.resolveFromOverscroll(
          overscroll: 12,
          atFirstPage: false,
          atLastPage: true,
        ),
        ReadingNavIntent.towardNextChapter,
      );
      expect(
        ReaderReadingDirection.resolveFromOverscroll(
          overscroll: -12,
          atFirstPage: true,
          atLastPage: false,
        ),
        ReadingNavIntent.towardPreviousChapter,
      );
    });

    test('reverse=true 时逻辑页边界仍按 index 0 / count-1', () {
      // itemBuilder 未逆序；reverse 只影响滚动轴
      expect(
        ReaderReadingDirection.resolveSwipeIntent(
          physicalDeltaDx: 100,
          physicalDeltaDy: 0,
          horizontalReading: true,
          r2l: true,
          currentPageIndex: 0,
          pageCount: 10,
        ),
        ReadingNavIntent.towardNextPage,
      );
      expect(
        ReaderReadingDirection.resolveSwipeIntent(
          physicalDeltaDx: 100,
          physicalDeltaDy: 0,
          horizontalReading: true,
          r2l: true,
          currentPageIndex: 9,
          pageCount: 10,
        ),
        ReadingNavIntent.towardNextChapter,
      );
    });
  });
}
