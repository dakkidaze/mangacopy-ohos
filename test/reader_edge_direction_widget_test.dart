import 'package:copymanga_flutter/chapter_edge_fsm.dart';
import 'package:copymanga_flutter/reader_reading_direction.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget 级：PageView.reverse + 统一方向映射 + ChapterEdgeFsm。
/// 不拉起完整 ReaderPage，避免 WebView/缓存依赖。
void main() {
  group('日漫 PageView 边界方向', () {
    testWidgets('reverse=true 时逻辑末页索引仍为 count-1，右滑双次只请求下一章一次', (
      WidgetTester tester,
    ) async {
      const pageCount = 3;
      var pageIndex = pageCount - 1; // 逻辑末页
      final chapterRequests = <bool>[];
      final fsm = ChapterEdgeFsm(
        confirmWindow: const Duration(seconds: 5),
        nowMs: () => 1000,
        nextRequestId: () => chapterRequests.length + 1,
      );

      Future<void> completeEdgeDrag(Offset delta, String session) async {
        final intent = ReaderReadingDirection.resolveSwipeIntent(
          physicalDeltaDx: delta.dx,
          physicalDeltaDy: delta.dy,
          horizontalReading: true,
          r2l: true,
          currentPageIndex: pageIndex,
          pageCount: pageCount,
        );
        final result = fsm.handle(
          event: ChapterEdgeFsmEvent.independentSwipeCompleted,
          gestureSessionId: session,
          intent: intent,
          goNext: intent == ReadingNavIntent.towardNextChapter,
          hasAdjacent: true,
        );
        if (result.action == ChapterEdgeFsmAction.requestChapterSwitch) {
          chapterRequests.add(result.goNext);
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 640,
              child: PageView.builder(
                reverse: true,
                controller: PageController(initialPage: pageIndex),
                itemCount: pageCount,
                onPageChanged: (i) {
                  pageIndex = i;
                  fsm.handle(event: ChapterEdgeFsmEvent.pageChanged);
                },
                itemBuilder: (context, index) => Container(
                  key: Key('p-$index'),
                  color: Colors.blue,
                  child: Center(child: Text('$index')),
                ),
              ),
            ),
          ),
        ),
      );

      expect(pageIndex, pageCount - 1);

      // 日漫：向右两次独立划
      await completeEdgeDrag(const Offset(200, 0), 'gs-1');
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
      await completeEdgeDrag(const Offset(200, 0), 'gs-2');
      expect(chapterRequests, [true]);
      expect(fsm.state, ChapterEdgeFsmState.switchingNext);

      // 第三划不重复
      await completeEdgeDrag(const Offset(200, 0), 'gs-3');
      expect(chapterRequests, [true]);
    });

    testWidgets('日漫末页向左不会提示下一章', (WidgetTester tester) async {
      final fsm = ChapterEdgeFsm(nowMs: () => 1000, nextRequestId: () => 1);
      const pageCount = 3;
      const pageIndex = 2;

      await tester.pumpWidget(
        const MaterialApp(home: SizedBox(width: 360, height: 640)),
      );

      final intent = ReaderReadingDirection.resolveSwipeIntent(
        physicalDeltaDx: -200,
        physicalDeltaDy: 0,
        horizontalReading: true,
        r2l: true,
        currentPageIndex: pageIndex,
        pageCount: pageCount,
      );
      expect(intent, isNot(ReadingNavIntent.towardNextChapter));

      final r = fsm.handle(
        event: ChapterEdgeFsmEvent.independentSwipeCompleted,
        gestureSessionId: 'gs-1',
        intent: intent,
        goNext: intent == ReadingNavIntent.towardNextChapter,
        hasAdjacent: true,
      );
      expect(r.action, ChapterEdgeFsmAction.none);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });

    testWidgets('非日漫方向与日漫相反', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      final mangaLastRight = ReaderReadingDirection.resolveSwipeIntent(
        physicalDeltaDx: 100,
        physicalDeltaDy: 0,
        horizontalReading: true,
        r2l: true,
        currentPageIndex: 4,
        pageCount: 5,
      );
      final ltrLastRight = ReaderReadingDirection.resolveSwipeIntent(
        physicalDeltaDx: 100,
        physicalDeltaDy: 0,
        horizontalReading: true,
        r2l: false,
        currentPageIndex: 4,
        pageCount: 5,
      );
      expect(mangaLastRight, ReadingNavIntent.towardNextChapter);
      expect(ltrLastRight, isNot(ReadingNavIntent.towardNextChapter));

      final ltrLastLeft = ReaderReadingDirection.resolveSwipeIntent(
        physicalDeltaDx: -100,
        physicalDeltaDy: 0,
        horizontalReading: true,
        r2l: false,
        currentPageIndex: 4,
        pageCount: 5,
      );
      expect(ltrLastLeft, ReadingNavIntent.towardNextChapter);
    });
  });
}
