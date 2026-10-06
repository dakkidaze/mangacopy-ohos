/// 条漫单张图片在视口内的位置快照。
class WebtoonViewportItem {
  const WebtoonViewportItem({
    required this.index,
    required this.leadingEdge,
    required this.trailingEdge,
  });

  final int index;
  final double leadingEdge;
  final double trailingEdge;
}

/// 将条漫可见位置转换成 1-based 阅读页码。
class WebtoonReadingProgress {
  const WebtoonReadingProgress._();

  /// 最后一张图片的底部进入视口，即视为已到章节末页。
  ///
  /// 当末图比视口矮时，前一张仍可能露出一小部分；若始终按最靠上的
  /// 可见图片计数，会停留在倒数第二页，进而使章节边界被误判为未到底。
  static int resolveCurrentPage({
    required int itemCount,
    required Iterable<WebtoonViewportItem> positions,
    double endViewportTolerance = 1.02,
  }) {
    if (itemCount <= 0) return 1;

    final visible = positions.where((item) => item.trailingEdge > 0).toList();
    if (visible.isEmpty) return 1;

    final lastPageVisibleAtEnd = visible.any(
      (item) =>
          item.index == itemCount - 1 &&
          item.trailingEdge <= endViewportTolerance,
    );
    if (lastPageVisibleAtEnd) return itemCount;

    final first = visible.reduce((a, b) => a.index < b.index ? a : b);
    return (first.index + 1).clamp(1, itemCount);
  }
}
