# 阅读器手势正式修复 — 实现报告

**日期：** 2026-08-04  
**项目：** `copymanga_flutter`  
**依据：** `test_output/android_20260804_153807/stage2_analysis_report.md` + 仓库当前代码  

---

## 1. 修改前根因判断

1. **横滑（高置信）**：未缩放时 `InteractiveViewer` 的 Scale 识别器仍参与 Gesture Arena，快速短划出现 `interactionStarted` 却无 `scrollStart`（基线 B1 ≈43%）。
2. **边界双滑（高置信）**：换章过度依赖 `OverscrollNotification`；第二划常无 overscroll，或再次落入 IV 竞争路径。
3. **已降低优先级**：multiTouch 永久锁、gate 同划多次 overscroll 误确认、默认 `PageScrollPhysics` / fling 阈值。

## 2. 采用的正式手势仲裁方案

**外层统一仲裁器（优先方案）**：

- `ReaderGestureCoordinator`（纯 Dart 状态机）拥有指针生命周期与模式转换
- 正式路径下 `ZoomableReaderImage` **未缩放不挂载 InteractiveViewer**，用 `Listener` + `Transform` 实现捏合/平移/双击
- 单指横滑不进入图片手势竞技场，PageView 使用原生 `PageScrollPhysics`（未改 physics、未调 fling）
- 放大或双指时通过 `locksPageView` / `onZoomChanged` 将 PageView 设为 `NeverScrollableScrollPhysics`

## 3. 为什么没有采用其他方案

| 方案 | 结论 |
|------|------|
| 永久 `scaleEnabled: false` / 移除 IV | 禁止；破坏缩放产品能力 |
| 第二指 setState 再挂 IV | 禁止；无法保证加入当前 Gesture Arena |
| 自定义 ScaleRecognizer 延迟接受 | 可接受但更脆；外层仲裁更可测、与真机 bypass 证据一致 |
| 改 PageScrollPhysics / 降 fling | 本轮禁止；证据指向竞争而非阈值 |
| 实验 bypass 作为默认 | 保留编译兼容，正式路径不依赖 |

## 4. 修改文件

**新增：**

- `lib/reader_gesture_config.dart`
- `lib/reader_gesture_coordinator.dart`
- `lib/reader_reading_direction.dart`
- `lib/chapter_edge_fsm.dart`
- `test/reader_gesture_coordinator_test.dart`
- `test/chapter_edge_fsm_test.dart`
- `test/zoomable_reader_formal_test.dart`
- `docs/reader_gesture_architecture.md`
- `docs/reader_gesture_implementation_report.md`

**修改：**

- `lib/zoomable_reader_image.dart`
- `lib/reader_page.dart`
- `lib/reader_gesture_debug.dart`
- `test/zoomable_reader_image_test.dart`
- `CHANGELOG.md`

**保留兼容：**

- `lib/chapter_edge_guard.dart`（legacy + 既有单测）
- 实验 define `READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED`（非正式默认）

## 5. Patch 1 / 2 / 3 分别改了什么

（逻辑分片；未自动 git commit）

### Patch 1 — 正式手势协调器

- 配置、方向映射、`ReaderGestureCoordinator`
- `ZoomableReaderImage` 正式路径改 Listener+Transform
- `reader_page` 接入 `onLocksPageViewChanged`
- 协调器单测 + 相关 widget 测

### Patch 2 — 章节边界状态机

- `ChapterEdgeFsm` + 独立 swipe 几何判定
- overscroll 降为辅助并与 session 去重
- 音量/点击走 `manualEdgeAction`
- FSM / 方向映射单测

### Patch 3 — 清理与诊断

- 统一回滚开关 `READER_LEGACY_GESTURE_ROUTING`
- 诊断事件：`gestureOwnerChanged`、`edgeSwipe*`、`edgeStateChanged`、`chapterSwitchDeduplicated` 等
- 架构文档与本报告

## 6. 手势状态机说明

见 `docs/reader_gesture_architecture.md` §2–3。  
模式：`idle → singlePointerCandidate → pageDrag | imageScaling | imagePanning → idle/disposed`。

## 7. 边界状态机说明

见架构文档 §5。  
`idle → armed* → switching* → waitingForChapter → idle`；失败可恢复再武装。

## 8. r2l / reverse 映射说明

见架构文档 §4。业务映射以物理位移 + `r2l` 为准（日漫右滑=next）；`PageView.reverse` 只负责滚动物理，不得二次反转。Overscroll 走滚动轴空间映射。

## 9. 自动化测试列表和结果

```
flutter test → All tests passed! (72)
```

覆盖：协调器、边界 FSM、方向映射、PageView 横滑、无 IV、双击、点击菜单、legacy guard 回归、JSONL/诊断既有用例、条漫双击等。

## 10. analyze / build 结果

| 命令 | 结果 |
|------|------|
| `dart format lib test` | 通过 |
| `flutter analyze --no-fatal-infos` | exit 0（仅既有 info，无 error） |
| `flutter test` | 72 passed |
| `flutter build apk --debug` | 成功 |
| `flutter build apk --release` | 成功 |

## 11. debug APK 路径

`d:\vibe coding\rebuild_copymanga\copymanga_flutter\build\app\outputs\flutter-apk\app-debug.apk`

副本：`build\gesture_fix_apks\app-debug.apk`

## 12. release APK 路径

`d:\vibe coding\rebuild_copymanga\copymanga_flutter\build\app\outputs\flutter-apk\app-release.apk`

副本：`build\gesture_fix_apks\app-release.apk`

## 13. legacy 回滚构建命令

```bash
flutter build apk --debug --dart-define=READER_LEGACY_GESTURE_ROUTING=true
flutter build apk --release --dart-define=READER_LEGACY_GESTURE_ROUTING=true
```

## 14. 已知风险

- 真机 Gesture Arena 行为无法被 WidgetTester 完整复现
- 手写捏合边界钳位相对 InteractiveViewer 为简化实现
- 条漫仍用 InteractiveViewer（本轮焦点 PageView）
- 修复后尚未做真机 smoke（不阻塞交付）

## 15. 未验证范围

- iOS 任意真机
- Android 非 API29 机型矩阵
- 不得声称已验证 iOS 16–27 或 Android 10–17 全版本

## 16. 极简 smoke test（用户可选，勿再扩展矩阵）

1. 章内快速短划 3 次  
2. 双指缩放 1 次  
3. 放大后平移 1 次  
4. 缩回后翻页 1 次  
5. 尾页双滑换下一章 1 次  
6. 首页双滑换上一章 1 次  

## 17. 是否建议作为正式默认实现

**是。** 默认正式路径；legacy 仅紧急回滚。建议用户完成上述 6 步 smoke 后发版；若异常用 legacy define 对照。

---

## 可直接复制给外部 Orchestrator 的汇报

### 任务

Flutter 漫画阅读器正式修复：（1）未缩放图片与 PageView 手势仲裁；（2）章节边界双次独立 swipe。已跳过额外诊断实验与大型真机矩阵。

### 根因（修复前证据）

- 目录：`test_output/android_20260804_153807/`
- 设备：Xiaomi MI 6X，Android 10，横向，r2l=true/reverse=true
- 快滑失败主模式：无 scrollStart + interactionStarted（IV vs PageView）
- 边界失败主模式：第二划无可靠 overscroll / 或再次 IV 竞争；gate 同划去重正常

### 正式方案

- 默认：`ReaderGestureCoordinator` + 未缩放不挂 InteractiveViewer + 手写捏合/平移
- 边界：`ChapterEdgeFsm`，独立 swipe 主路径，overscroll 辅助，confirm 窗 2.5s
- 方向：`ReaderReadingDirection` 单一映射
- 未改 PageScrollPhysics，未调 fling
- 回滚：`READER_LEGACY_GESTURE_ROUTING=true`（与正式互斥）

### 验证

- `flutter test`：72 passed
- `flutter analyze --no-fatal-infos`：无 error
- debug/release APK 均构建成功
- **未做修复后真机验证；未验证 iOS**

### 产物

- Debug：`build/app/outputs/flutter-apk/app-debug.apk`
- Release：`build/app/outputs/flutter-apk/app-release.apk`
- 文档：`docs/reader_gesture_architecture.md`、本报告

### 建议

作为正式默认实现；用户可选 6 步极简 smoke；异常时用 legacy define 出对照包。不要再要求大型 CSV/20 次矩阵。未 git commit/push（按用户规则）。
