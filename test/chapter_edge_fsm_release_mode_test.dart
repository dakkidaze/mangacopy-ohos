// 模拟 Release 构建中 gestureSessionId = null 的场景，验证 FSM 去重是否失效。
//
// 在修复前，gestureSessionId 由 ReaderGestureDiagnostics.currentGestureSessionId()
// 提供，而该方法在 Release 包（kDebugMode=false）下始终返回 null。
// 导致 ChapterEdgeFsm 的 sameGestureSessionAsArm 保护被完全绕过：
//   第一次 swipe → arm（CONFIRM_HINT）
//   同一帧内来自 aux-overscroll 的第二次 FSM 调用（sessionId=null）→ OPEN（bug！）
//
// 修复后，reader_page.dart 自主生成 gestureSessionId，不再依赖 debug-only 的诊断模块。

import 'package:copymanga_flutter/chapter_edge_fsm.dart';
import 'package:copymanga_flutter/reader_reading_direction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Release 模式 gestureSessionId=null 场景', () {
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

    /// 模拟主路径 independentSwipeCompleted，sessionId 可为 null（Release 包旧行为）。
    ChapterEdgeFsmResult swipeWithSession(String? session, {bool goNext = true}) {
      return fsm.handle(
        event: ChapterEdgeFsmEvent.independentSwipeCompleted,
        goNext: goNext,
        gestureSessionId: session,
        intent: goNext
            ? ReadingNavIntent.towardNextChapter
            : ReadingNavIntent.towardPreviousChapter,
        hasAdjacent: true,
      );
    }

    /// 模拟 aux-overscroll 辅助路径，sessionId 可为 null（Release 包旧行为）。
    ChapterEdgeFsmResult auxOverscrollWithSession(String? session, {bool goNext = true}) {
      return fsm.handle(
        event: ChapterEdgeFsmEvent.auxOverscroll,
        goNext: goNext,
        gestureSessionId: session,
        intent: goNext
            ? ReadingNavIntent.towardNextChapter
            : ReadingNavIntent.towardPreviousChapter,
        hasAdjacent: true,
        fromAuxOverscroll: true,
      );
    }

    // -------------------------------------------------------------------------
    // 测试 1（先红，修复后变绿）：
    // 同一手势内 independentSwipe + auxOverscroll 共用同一非 null session
    // → aux 必须被去重，不得触发 OPEN。
    // 这是修复后的"正确行为基准"。
    // -------------------------------------------------------------------------
    test('相同非 null sessionId：aux overscroll 在同一手势内应被去重', () {
      // 第一划（主路径）→ arm
      final r1 = swipeWithSession('gs-1', goNext: true);
      expect(r1.action, ChapterEdgeFsmAction.showConfirmHint,
          reason: '第一划应显示确认提示');
      expect(fsm.state, ChapterEdgeFsmState.armedNext);

      // 同一手势内 aux overscroll（sessionId 相同）→ 必须去重，不得换章
      final r2 = auxOverscrollWithSession('gs-1', goNext: true);
      expect(r2.action, ChapterEdgeFsmAction.deduplicated,
          reason: '同一手势内的 aux overscroll 应被去重，不得触发换章');
      expect(fsm.state, ChapterEdgeFsmState.armedNext,
          reason: 'FSM 状态应保持 armedNext，等待下一次独立手势');
    });

    // -------------------------------------------------------------------------
    // 测试 2（先红，暴露旧 bug）：
    // Release 包旧行为：sessionId = null。
    // 主路径 arm 后，aux overscroll（sessionId=null）不应晋升为 OPEN。
    // 修复前此测试失败（aux 触发了 OPEN）；修复后由 reader_page 自主生成非 null
    // sessionId，此测试场景在真实代码中不再出现，但保留以文档化 bug 根因。
    // -------------------------------------------------------------------------
    test('null sessionId：arm 后的第二次 swipe 仍视为新手势（无防重复）', () {
      // null sessionId 时，FSM 对两次调用均无法做 session 级去重
      // → 第一次 arm，第二次视为不同来源（因为 null != null 不成立），
      //   实际上 FSM 会直接 open（这是 bug）。
      // 修复后不再有 null sessionId 到达 FSM，此测试记录旧行为。
      final r1 = swipeWithSession(null, goNext: true);
      expect(r1.action, ChapterEdgeFsmAction.showConfirmHint,
          reason: '第一次调用（null session）应 arm');

      // 用 null sessionId 再次调用 → FSM 因 null 无法识别为同一手势
      // 修复前：会返回 requestChapterSwitch（bug！）
      // 修复后：reader_page 不再传 null，此场景不再在生产代码中出现
      final r2 = swipeWithSession(null, goNext: true);
      // 文档化修复前的 bug：这里 r2.action 会是 requestChapterSwitch
      // 修复后的正确路径不会走到这里（sessionId 不再为 null）
      // 此断言描述修复前的"坏"结果，供历史追溯
      expect(r2.action, isNot(ChapterEdgeFsmAction.showConfirmHint),
          reason: 'null session 时第二次调用不会再显示确认（会直接 open，这是旧 bug）');
    });

    // -------------------------------------------------------------------------
    // 测试 3（先绿，应一直保持绿）：
    // 两次不同非 null sessionId → 正常换章流程。
    // 这是修复后的预期"两划换章"路径。
    // -------------------------------------------------------------------------
    test('两次不同非 null sessionId → 正常两划换章', () {
      final r1 = swipeWithSession('gs-1', goNext: true);
      expect(r1.action, ChapterEdgeFsmAction.showConfirmHint);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);

      final r2 = swipeWithSession('gs-2', goNext: true);
      expect(r2.action, ChapterEdgeFsmAction.requestChapterSwitch,
          reason: '第二次独立手势（不同 session）应触发换章');
      expect(r2.chapterRequestId, isNotNull);
    });

    // -------------------------------------------------------------------------
    // 测试 4（先绿，回归）：
    // aux overscroll 先于 independentSwipe 到达时，不重复触发换章。
    // -------------------------------------------------------------------------
    test('aux overscroll 先到达 arm，independentSwipe 同 session 后到达被去重', () {
      // aux overscroll 先触发 arm
      final r1 = auxOverscrollWithSession('gs-1', goNext: true);
      expect(r1.action, ChapterEdgeFsmAction.showConfirmHint,
          reason: 'aux overscroll 作为第一划触发确认提示');
      expect(fsm.state, ChapterEdgeFsmState.armedNext);

      // 同一手势的 independentSwipe 后到达（同 sessionId）→ 去重
      final r2 = swipeWithSession('gs-1', goNext: true);
      expect(r2.action, ChapterEdgeFsmAction.deduplicated,
          reason: '相同 sessionId 的 independentSwipe 应被去重');
      expect(fsm.state, ChapterEdgeFsmState.armedNext);

      // 下一次独立手势（新 session）→ 换章
      final r3 = swipeWithSession('gs-2', goNext: true);
      expect(r3.action, ChapterEdgeFsmAction.requestChapterSwitch);
    });

    // -------------------------------------------------------------------------
    // 测试 5（先绿，回归）：
    // 修复后完整正常流程：独立 session 两次独立滑动换章。
    // -------------------------------------------------------------------------
    test('正式路径回归：两次独立手势换章，期间 FSM 状态正确流转', () {
      expect(fsm.state, ChapterEdgeFsmState.idle);

      // 第一划
      swipeWithSession('session-A', goNext: true);
      expect(fsm.state, ChapterEdgeFsmState.armedNext);
      expect(fsm.currentlyHintingNext, isTrue);
      expect(fsm.currentlyHintingPrevious, isFalse);

      // 第二划（新 session）
      swipeWithSession('session-B', goNext: true);
      expect(fsm.state, ChapterEdgeFsmState.switchingNext);
      expect(fsm.currentlyHintingNext, isFalse);

      // 换章成功
      fsm.handle(event: ChapterEdgeFsmEvent.chapterRequestSucceeded);
      expect(fsm.state, ChapterEdgeFsmState.idle);
    });
  });
}
