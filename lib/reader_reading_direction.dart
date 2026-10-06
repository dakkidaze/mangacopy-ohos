import 'package:flutter/painting.dart';

import 'reader_gesture_config.dart';

/// 阅读方向意图：相对「下一页 / 上一页 / 下一章 / 上一章」。
enum ReadingNavIntent {
  none,
  towardNextPage,
  towardPreviousPage,
  towardNextChapter,
  towardPreviousChapter,
}

/// 物理主轴方向（屏幕坐标，不受 PageView.reverse 影响）。
enum PhysicalAxisSwipe { none, left, right, up, down }

/// 单一方向映射：物理滑动 → 页/章导航意图。
///
/// 权威输入：手指物理位移 + 是否横向 + [r2l]（日漫/右开）。
/// [PageView.reverse] 只负责视觉/滚动物理；业务层不得再对 reverse 做第二次反转。
///
/// 横向产品语义：
/// - 日漫 / r2l=true：右滑 (dx&gt;0) → next；左滑 (dx&lt;0) → previous
/// - 左开 / r2l=false：左滑 (dx&lt;0) → next；右滑 (dx&gt;0) → previous
/// - 纵向：上滑 (dy&lt;0) → next；下滑 → previous（与 r2l 无关）
///
/// Overscroll 符号属于滚动轴空间（已含 reverse），见 [resolveFromOverscroll]。
class ReaderReadingDirection {
  const ReaderReadingDirection._();

  static PhysicalAxisSwipe physicalSwipe({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
  }) {
    if (horizontalReading) {
      if (totalDx.abs() < 0.5 && totalDy.abs() < 0.5) {
        return PhysicalAxisSwipe.none;
      }
      // 主轴优先：交叉轴过大时仍按主轴判方向，由调用方做比例过滤。
      if (totalDx.abs() >= totalDy.abs()) {
        return totalDx < 0 ? PhysicalAxisSwipe.left : PhysicalAxisSwipe.right;
      }
      return totalDy < 0 ? PhysicalAxisSwipe.up : PhysicalAxisSwipe.down;
    }
    if (totalDy.abs() < 0.5 && totalDx.abs() < 0.5) {
      return PhysicalAxisSwipe.none;
    }
    if (totalDy.abs() >= totalDx.abs()) {
      return totalDy < 0 ? PhysicalAxisSwipe.up : PhysicalAxisSwipe.down;
    }
    return totalDx < 0 ? PhysicalAxisSwipe.left : PhysicalAxisSwipe.right;
  }

  /// 物理滑动是否指向「下一页」方向（章内）。
  ///
  /// [r2l] 仅影响横向；纵向忽略。
  static bool isTowardNextPage({
    required PhysicalAxisSwipe swipe,
    required bool horizontalReading,
    required bool r2l,
  }) {
    if (horizontalReading) {
      return r2l
          ? swipe == PhysicalAxisSwipe.right
          : swipe == PhysicalAxisSwipe.left;
    }
    return swipe == PhysicalAxisSwipe.up;
  }

  static bool isTowardPreviousPage({
    required PhysicalAxisSwipe swipe,
    required bool horizontalReading,
    required bool r2l,
  }) {
    if (horizontalReading) {
      return r2l
          ? swipe == PhysicalAxisSwipe.left
          : swipe == PhysicalAxisSwipe.right;
    }
    return swipe == PhysicalAxisSwipe.down;
  }

  /// 主轴有符号位移（屏幕坐标；正负本身不是业务 next/previous）。
  static double signedPrimaryDelta({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
  }) {
    return horizontalReading ? totalDx : totalDy;
  }

  static double primaryAbs({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
  }) {
    return signedPrimaryDelta(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    ).abs();
  }

  static double crossAbs({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
  }) {
    return horizontalReading ? totalDy.abs() : totalDx.abs();
  }

  /// 将物理滑动映射为页/章意图（唯一业务入口）。
  static ReadingNavIntent resolve({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
    required bool r2l,
    required bool atFirstPage,
    required bool atLastPage,
    bool requirePrimaryAxis = true,
  }) {
    final primary = primaryAbs(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    final cross = crossAbs(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    if (primary < 0.5) return ReadingNavIntent.none;
    if (requirePrimaryAxis && cross > primary * kChapterEdgeMaxCrossAxisRatio) {
      return ReadingNavIntent.none;
    }

    final swipe = physicalSwipe(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    if (swipe == PhysicalAxisSwipe.none) return ReadingNavIntent.none;

    final towardNext = isTowardNextPage(
      swipe: swipe,
      horizontalReading: horizontalReading,
      r2l: r2l,
    );
    if (towardNext) {
      if (atLastPage) return ReadingNavIntent.towardNextChapter;
      return ReadingNavIntent.towardNextPage;
    }
    if (isTowardPreviousPage(
      swipe: swipe,
      horizontalReading: horizontalReading,
      r2l: r2l,
    )) {
      if (atFirstPage) return ReadingNavIntent.towardPreviousChapter;
      return ReadingNavIntent.towardPreviousPage;
    }
    return ReadingNavIntent.none;
  }

  /// 别名：强调「物理位移 → 逻辑意图」的唯一映射。
  static ReadingNavIntent resolveSwipeIntent({
    required double physicalDeltaDx,
    required double physicalDeltaDy,
    required bool horizontalReading,
    required bool r2l,
    required int currentPageIndex,
    required int pageCount,
    bool requirePrimaryAxis = true,
  }) {
    final atFirst = pageCount > 0 && currentPageIndex <= 0;
    final atLast = pageCount > 0 && currentPageIndex >= pageCount - 1;
    return resolve(
      totalDx: physicalDeltaDx,
      totalDy: physicalDeltaDy,
      horizontalReading: horizontalReading,
      r2l: r2l,
      atFirstPage: atFirst,
      atLastPage: atLast,
      requirePrimaryAxis: requirePrimaryAxis,
    );
  }

  /// Overscroll 符号 → 是否指向更高页索引（逻辑 next）。
  ///
  /// Flutter：overscroll &gt; 0 表示越过 maxScrollExtent。
  /// PageView.reverse（与 r2l 同步）已决定何种物理滑动产生正 overscroll，
  /// 此处不得再按 r2l 反转。
  static bool overscrollTowardEnd(double overscroll) => overscroll > 0;

  /// 将滚动轴 overscroll 映射为页/章意图（不二次应用 r2l）。
  static ReadingNavIntent resolveFromOverscroll({
    required double overscroll,
    required bool atFirstPage,
    required bool atLastPage,
  }) {
    if (overscroll.abs() < 0.5) return ReadingNavIntent.none;
    if (overscrollTowardEnd(overscroll)) {
      if (atLastPage) return ReadingNavIntent.towardNextChapter;
      return ReadingNavIntent.towardNextPage;
    }
    if (atFirstPage) return ReadingNavIntent.towardPreviousChapter;
    return ReadingNavIntent.towardPreviousPage;
  }

  /// 调试字段：逻辑阅读方向标签。
  static String logicalReadingLabel({
    required double totalDx,
    required double totalDy,
    required bool horizontalReading,
    required bool r2l,
  }) {
    final swipe = physicalSwipe(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    if (swipe == PhysicalAxisSwipe.none) return 'none';
    if (isTowardNextPage(
      swipe: swipe,
      horizontalReading: horizontalReading,
      r2l: r2l,
    )) {
      return 'towardNext';
    }
    if (isTowardPreviousPage(
      swipe: swipe,
      horizontalReading: horizontalReading,
      r2l: r2l,
    )) {
      return 'towardPrevious';
    }
    return 'none';
  }

  static String physicalLabel(PhysicalAxisSwipe swipe) => switch (swipe) {
    PhysicalAxisSwipe.none => 'none',
    PhysicalAxisSwipe.left => 'left',
    PhysicalAxisSwipe.right => 'right',
    PhysicalAxisSwipe.up => 'up',
    PhysicalAxisSwipe.down => 'down',
  };

  /// 供点击分区使用：左/上区域是否为「下一页」（受 r2l 影响）。
  static bool tapLeadingMeansNext({
    required bool isHorizontal,
    required bool r2l,
  }) {
    if (!isHorizontal) return false; // 纵向：上=prev
    return r2l;
  }
}

/// 边界 swipe 几何判定（纯函数，便于单测）。
class EdgeSwipeGeometry {
  const EdgeSwipeGeometry({
    required this.accepted,
    required this.rejectReason,
    required this.intent,
    required this.primaryDistance,
    required this.velocityPrimary,
  });

  final bool accepted;
  final String rejectReason;
  final ReadingNavIntent intent;
  final double primaryDistance;
  final double velocityPrimary;

  static EdgeSwipeGeometry evaluate({
    required double totalDx,
    required double totalDy,
    required int durationMs,
    required Size viewport,
    required bool horizontalReading,
    required bool r2l,
    required bool atFirstPage,
    required bool atLastPage,
    double minDistanceFraction = kChapterEdgeMinDistanceFraction,
    double minVelocity = kChapterEdgeMinVelocityLogicalPxPerSec,
  }) {
    final intent = ReaderReadingDirection.resolve(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
      r2l: r2l,
      atFirstPage: atFirstPage,
      atLastPage: atLastPage,
    );
    final primary = ReaderReadingDirection.primaryAbs(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    final axisLen = horizontalReading ? viewport.width : viewport.height;
    final minDist = axisLen * minDistanceFraction;
    final sec = durationMs <= 0 ? 0.001 : durationMs / 1000.0;
    final signed = ReaderReadingDirection.signedPrimaryDelta(
      totalDx: totalDx,
      totalDy: totalDy,
      horizontalReading: horizontalReading,
    );
    final velocity = signed / sec;

    if (intent != ReadingNavIntent.towardNextChapter &&
        intent != ReadingNavIntent.towardPreviousChapter) {
      return EdgeSwipeGeometry(
        accepted: false,
        rejectReason: 'notChapterEdgeIntent',
        intent: intent,
        primaryDistance: primary,
        velocityPrimary: velocity,
      );
    }

    final distanceOk = primary >= minDist;
    final velocityOk = velocity.abs() >= minVelocity;
    if (!distanceOk && !velocityOk) {
      return EdgeSwipeGeometry(
        accepted: false,
        rejectReason: 'distanceAndVelocityBelowThreshold',
        intent: intent,
        primaryDistance: primary,
        velocityPrimary: velocity,
      );
    }

    return EdgeSwipeGeometry(
      accepted: true,
      rejectReason: 'none',
      intent: intent,
      primaryDistance: primary,
      velocityPrimary: velocity,
    );
  }
}
