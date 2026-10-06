/// 条漫图片宽高比缓存（进程内 LRU）。
///
/// 条漫 item 的高度必须在图片被回收、重建、重下载期间保持不变：
/// 一旦某个已滑过的 item 退回到「占位符高度」，列表总高度塌陷，
/// ScrollablePositionedList 重新对齐锚点，画面就会闪一下往回跳一段。
/// 记住每个 url 的宽高比后，占位符和真实图片用同一个高度，回跳消失。
class WebtoonAspectCache {
  const WebtoonAspectCache._();

  static const _maxEntries = 3000;

  /// url -> width / height。用 LinkedHashMap 的插入序当 LRU。
  static final Map<String, double> _ratios = <String, double>{};

  /// 比例未知时调用方应**不加约束**地渲染（见 `_buildWebtoonImage`）：
  /// 用兜底比例套 AspectRatio 会因紧约束 + BoxFit.fitWidth 裁掉过长的图。
  static double? get(String url) {
    final v = _ratios.remove(url);
    if (v == null) return null;
    _ratios[url] = v; // 重新插入 = 标记为最近使用
    return v;
  }

  static bool isKnown(String url) => _ratios.containsKey(url);

  /// 返回 true 表示这是新记录到的比例（调用方需要重建以应用新高度）。
  static bool put(String url, double width, double height) {
    if (width <= 0 || height <= 0) return false;
    final ratio = width / height;
    final old = _ratios[url];
    if (old != null && (old - ratio).abs() < 0.001) {
      get(url); // 刷新 LRU 位置
      return false;
    }
    _ratios.remove(url);
    _ratios[url] = ratio;
    while (_ratios.length > _maxEntries) {
      _ratios.remove(_ratios.keys.first);
    }
    return true;
  }

  static void clear() => _ratios.clear();
}
