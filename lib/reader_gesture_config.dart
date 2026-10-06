// 阅读器手势与章节边界集中配置。
//
// 紧急回滚：构建时注入
// `--dart-define=READER_LEGACY_GESTURE_ROUTING=true`
// 将恢复 InteractiveViewer + ChapterEdgeGuard(overscroll) 旧路径。
// 新旧路径互斥，不得同时处理同一手势。

/// 紧急回滚开关。默认 false = 正式仲裁 / 边界状态机。
const bool kReaderLegacyGestureRouting = bool.fromEnvironment(
  'READER_LEGACY_GESTURE_ROUTING',
  defaultValue: false,
);

/// 是否走正式手势仲裁（与 [kReaderLegacyGestureRouting] 互斥）。
bool get useFormalReaderGestureRouting => !kReaderLegacyGestureRouting;

/// 缩放判定容差：scale ≤ 1 + 此值视为未放大。
const double kReaderScaleEpsilon = 0.05;

/// 点击 / 双击位移阈值（逻辑像素）。基于常见触控 slop，随密度由框架换算。
const double kReaderTapSlopLogicalPx = 18.0;

/// 双击时间窗。
const Duration kReaderDoubleTapTimeout = Duration(milliseconds: 280);

/// 双击目标倍率。
const double kReaderDoubleTapScale = 2.0;

/// 最大缩放。
const double kReaderMaxScale = 4.0;

/// 章节边界二次确认时间窗。
///
/// 依据：真机基线中用户两次独立短划间隔通常在 1–2s 内；
/// 取 2.5s 兼顾稍慢操作，过长易误触跨页后的换章。
const Duration kChapterEdgeConfirmWindow = Duration(milliseconds: 2500);

/// 独立边界 swipe 主轴最小位移：视口主轴长度的比例。
///
/// 依据：基线成功翻页中位 |totalDx|≈118（逻辑宽 360 → ~0.33）；
/// 边界确认可略低于翻页阈值，取 0.12 避免轻点误触发，又不过度依赖 overscroll。
const double kChapterEdgeMinDistanceFraction = 0.12;

/// 独立边界 swipe 主轴最小平均速度（逻辑 px/s）。
/// 与距离条件为 OR：短而快或长而慢均可。
const double kChapterEdgeMinVelocityLogicalPxPerSec = 480.0;

/// 交叉轴位移不得超过主轴的此倍数，否则视为斜滑/无效。
const double kChapterEdgeMaxCrossAxisRatio = 0.85;

/// Overscroll 辅助信号最小绝对值（逻辑 px）。仅作附加证据，非唯一入口。
const double kChapterEdgeAuxOverscrollMinAbs = 6.0;

/// 阶段 3B 实验开关（仅保留编译兼容；正式路径不依赖该开关）。
const bool kReaderGestureExperimentBypassIvWhenUnzoomed = bool.fromEnvironment(
  'READER_GESTURE_EXPERIMENT_BYPASS_IV_WHEN_UNZOOMED',
  defaultValue: false,
);
