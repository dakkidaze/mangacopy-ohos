# 阅读器手势架构

> 正式实现文档（2026-08-04）。以仓库当前代码为准。

## 1. 背景与根因

Android 真机基线（Xiaomi MI 6X / API 29 / 横向 / r2l=true, reverse=true）显示：

- 慢速长拖翻页 5/5 成功
- 快速短划约 43% 完全无 `scrollStart`，且这些失败 session **全部伴随** `interactionStarted`
- 成功翻页 session **没有** `interactionStarted`

结论：未缩放状态下 `InteractiveViewer`（Scale 识别器）与 `PageView` 在 Gesture Arena 中竞争，是横滑不灵敏的主要原因。

章节边界第二划失败则主要是：过度依赖 `OverscrollNotification`；部分独立 swipe 无 overscroll，或再次落入图片 interaction 路径。

## 2. 手势所有权规则

默认路径（正式）由 `ReaderGestureCoordinator` 仲裁，**未缩放时不挂载 InteractiveViewer**。

| 条件 | 所有者 | PageView |
|------|--------|----------|
| 未缩放 + 单指轻点 | 点击分区 | 不锁 |
| 未缩放 + 单指横/纵滑超 slop | PageView（`pageDrag`） | 不锁 |
| 第二指加入 | 图片缩放（`imageScaling`） | 立刻锁定 |
| 已放大 + 单指 | 图片平移（`imagePanning`） | 锁定 |
| 缩回 ≈1.0 且全部指针抬起 | 空闲 | 解锁 |
| 双击 | 图片缩放动画 | 结束后按 scale 决定 |

Legacy 回滚路径仍使用 `InteractiveViewer`（见 §7）。

## 3. 手势状态机

`ReaderGestureMode`：

```
idle
 → singlePointerCandidate
 → pageDrag                 // 未缩放单指移动超 slop
 → multiPointerCandidate    // 第二指加入瞬间
 → imageScaling             // 双指捏合
 → imagePanning             // 已放大单指
 → settling                 // 双击动画过渡
 → disposed
```

关键不变量：

- 任意结束路径（up / cancel / pause / mode change / dispose）不得残留 multiTouch / zoom / animation 锁
- 第一指抬起、第二指仍在时 **不得** 解锁 PageView
- 缩回 1.0 只在 **当前手势完全结束** 后恢复翻页，避免中途切换 physics 跳页

## 4. r2l / reverse 方向映射

单一入口：`lib/reader_reading_direction.dart`（`ReaderReadingDirection.resolve` / `resolveSwipeIntent`）。

权威输入：手指物理位移 + 是否横向 + `r2l`。`PageView.reverse` 只负责视觉/滚动物理，**不得**在业务层再反转一次。

横向产品语义：

- **日漫 / r2l=true**：右滑 (dx&gt;0) → next；左滑 (dx&lt;0) → previous
- **左开 / r2l=false**：左滑 (dx&lt;0) → next；右滑 (dx&gt;0) → previous
- **纵向**：上滑 → next；下滑 → previous（与 r2l 无关）
- 点击分区左右对调仍由 `r2l` 控制（与滑动映射同源语义）

Overscroll 符号属于滚动轴空间（已含 reverse），经 `resolveFromOverscroll` 映射，**不得**再按 r2l 反转。

边界意图：已在首/末页且方向指向章外 → `towardPreviousChapter` / `towardNextChapter`。

## 5. 章节双滑语义

状态机：`ChapterEdgeFsm`（`lib/chapter_edge_fsm.dart`）。

主输入：完成的独立 pointer sequence（`independentSwipeCompleted`）。  
辅助输入：`OverscrollNotification`（`auxOverscroll`），**不得作为唯一入口**；同 `gestureSessionId` 去重。

有效边界 swipe 条件（摘要）：

1. 完整独立 pointer sequence  
2. 主轴与阅读轴一致  
3. 方向指向章外  
4. **手势开始时**已在首/末页（防止翻入末页的那一划误武装）  
5. 未放大、非多指、非 cancel  
6. 无进行中的章节请求  
7. 距离（视口主轴 × 0.12）或速度（≥480 lp/s）满足其一  
8. 每个 `gestureSessionId` 最多一次  

双次确认：

- 第一划 → `armedNext` / `armedPrevious` + 轻量提示  
- 第二划（新 session、同向、时间窗内）→ 唯一一次 `requestChapterSwitch`（带 `chapterRequestId`）

确认窗：`kChapterEdgeConfirmWindow = 2.5s`（集中配置于 `reader_gesture_config.dart`）。

重置：超时、反向、离开边界、pageChanged、cancel、开始缩放、阅读模式变化、dispose、App 后台、请求开始/成功/失败恢复。

## 6. chapterRequestId 去重

- 第二划生成 `chapterRequestId` + `operationToken`
- switching / waiting 期间第三划 → `chapterSwitchDeduplicated`
- 旧异步失败结果若 requestId 不匹配 → 丢弃
- BrowserPage prefetch 命中与 WebView 加载均应带同一 requestId（既有诊断已接）

## 7. Legacy 回滚开关

```text
flutter build apk --debug --dart-define=READER_LEGACY_GESTURE_ROUTING=true
flutter build apk --release --dart-define=READER_LEGACY_GESTURE_ROUTING=true
```

- 默认 `false`：正式协调器 + 边界 FSM  
- `true`：InteractiveViewer + `ChapterEdgeGuard`/`Overscroll` 旧路径  
- **互斥**：`useFormalReaderGestureRouting = !kReaderLegacyGestureRouting`  
- 阶段 3B 实验开关 `READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED` 仅保留编译兼容，非正式路径

## 8. 诊断事件（debug only）

保留：JSONL、短 logcat、`readerInstanceId`、`gestureSessionId`、`chapterRequestId`、action marker、`chapterDiagToken`。

新增：`gestureOwnerChanged`、`gestureModeChanged`、`pageGestureAccepted`、`imageScaleAccepted`、`imagePanAccepted`、`edgeSwipeAccepted`、`edgeSwipeRejected`、`edgeStateChanged`、`chapterSwitchDeduplicated`。

避免超长单行 logcat（summary 走 short + JSONL full）。

## 9. 已验证范围

- 自动化：`flutter test` 全绿（含协调器、边界 FSM、方向映射、PageView widget、回归）
- `flutter analyze --no-fatal-infos` 无 error
- debug / release APK 构建（见实现报告）

真机基线（修复前证据）：Xiaomi MI 6X、Android 10、横向、r2l=true。  
**修复后真机 smoke 由用户按极简清单执行；本文不声称已完成真机回归。**

## 10. 未验证范围

- iOS 真机（任何版本）
- Android 10 以外的系统版本矩阵
- 不得写成「已适配 iOS 16–27 / Android 10–17」

## 11. 已知风险

- WidgetTester 无法完整模拟真机 Gesture Arena 多指竞争；双指缩放以协调器单测 + 有限 widget 覆盖为主
- 正式路径手写捏合/平移，边界钳位为简化实现，极端缩放开图可能与旧 InteractiveViewer 体感略有差异
- 条漫 `ZoomableWebtoonView` 仍用 InteractiveViewer（纵向列表场景；本轮焦点为 PageView 横滑）
