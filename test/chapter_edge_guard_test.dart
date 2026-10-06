import 'package:copymanga_flutter/chapter_edge_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChapterEdgeGuard', () {
    test('有邻章时首次边界操作为确认，再次同向为换章', () {
      final guard = ChapterEdgeGuard();

      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.openChapter,
      );
    });

    test('无邻章时立即到头，且不置 hint', () {
      final guard = ChapterEdgeGuard();

      expect(guard.onEdge(true, hasAdjacent: false), ChapterEdgeOutcome.atEnd);
      // 之后即使有邻章，仍应是首次确认，而非直接换章
      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
    });

    test('上下方向 hint 彼此独立', () {
      final guard = ChapterEdgeGuard();

      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
      expect(
        guard.onEdge(false, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
      expect(
        guard.onEdge(false, hasAdjacent: true),
        ChapterEdgeOutcome.openChapter,
      );
      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.openChapter,
      );
    });

    test('clear 后需重新确认', () {
      final guard = ChapterEdgeGuard();
      guard.onEdge(true, hasAdjacent: true);
      guard.clear();
      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
    });

    test('clearSide 只清对应方向', () {
      final guard = ChapterEdgeGuard();
      guard.onEdge(true, hasAdjacent: true);
      guard.onEdge(false, hasAdjacent: true);
      guard.clearSide(true);
      expect(
        guard.onEdge(true, hasAdjacent: true),
        ChapterEdgeOutcome.confirmNeeded,
      );
      expect(
        guard.onEdge(false, hasAdjacent: true),
        ChapterEdgeOutcome.openChapter,
      );
    });
  });

  group('EdgeGestureGate', () {
    test('同一手势内只放行一次越界', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();
      expect(gate.allow(), isTrue);
      expect(gate.allow(), isFalse);
      expect(gate.allow(), isFalse);
    });

    test('新手势后可再次放行', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();
      expect(gate.allow(), isTrue);
      gate.beginGesture();
      expect(gate.allow(), isTrue);
      expect(gate.allow(), isFalse);
    });
  });

  group('tryAcceptEdgeOverscroll', () {
    test('未到章节边界时不消耗 gate，同手势稍后仍可放行', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();

      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 12,
          atChapterEdge: (_) => false,
          gate: gate,
        ),
        isFalse,
      );
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 12,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isTrue,
      );
    });

    test('已在边界时同手势只放行一次', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 12,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isTrue,
      );
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 12,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isFalse,
      );
    });

    test('overscroll 过小直接拒绝且不消耗 gate', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 4,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isFalse,
      );
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 12,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isTrue,
      );
    });

    test('默认阈值 6：介于旧阈值与轻滑之间仍可放行', () {
      final gate = EdgeGestureGate();
      gate.beginGesture();
      expect(
        tryAcceptEdgeOverscroll(
          overscroll: 6.5,
          atChapterEdge: (_) => true,
          gate: gate,
        ),
        isTrue,
      );
    });
  });
}
