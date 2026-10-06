import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../image_cache_store.dart';
import 'browse_paging.dart';

/// 原生浏览界面共用控件：封面、卡片、三态视图、分页尾部。
///
/// 这一层只管外观，不碰 [MangaSource]，方便在测试里直接喂假数据。

/// 封面图构造入口。测试可整体替换为占位方块，避免走真实网络/磁盘缓存。
typedef CoverImageBuilder =
    Widget Function(BuildContext context, String url, BoxFit fit);

/// 单张封面：加载中占位 + 失败占位（不再是空白）。
///
/// 封面按 3:4 竖版比例，和站点返回的图一致，不留上下黑边。
class MangaCover extends StatelessWidget {
  const MangaCover({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.aspectRatio = 3 / 4,
    this.iconSize = 28,
    this.placeholder,
  });

  final String url;

  /// 测试注入点：非 null 时用它代替真实网络图片。
  static CoverImageBuilder? imageBuilder;

  final BoxFit fit;

  /// 宽高比（宽 / 高）。传 null 时撑满父容器。
  final double? aspectRatio;
  final double iconSize;

  /// 加载中/失败时叠加的说明文字；列表里通常不传，详情页可传。
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final box = _placeholderColor(scheme);
    Widget child;
    if (url.isEmpty) {
      child = _placeholderBox(context, box, placeholder, iconSize, broken: false);
    } else if (imageBuilder != null) {
      child = imageBuilder!(context, url, fit);
    } else {
      child = CachedNetworkImage(
        imageUrl: url,
        cacheManager: AppImageCache.manager,
        fit: fit,
        fadeInDuration: const Duration(milliseconds: 160),
        placeholder: (context, url) => Container(
          color: box,
          alignment: Alignment.center,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        errorWidget: (context, url, error) =>
            _placeholderBox(context, box, placeholder, iconSize, broken: true),
      );
    }
    if (aspectRatio == null) return child;
    return AspectRatio(aspectRatio: aspectRatio!, child: child);
  }

  /// 加载失败/无封面时的占位：图标 + 可选一行小字。
  static Widget _placeholderBox(
    BuildContext context,
    Color bg,
    String? text,
    double iconSize, {
    required bool broken,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurfaceVariant.withValues(alpha: 0.55);
    final child = broken
        ? Icon(Icons.image_not_supported_outlined, size: iconSize, color: fg)
        : Icon(Icons.menu_book_outlined, size: iconSize, color: fg);
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: text == null
          ? child
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    text,
                    style: TextStyle(color: fg, fontSize: 12),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
    );
  }

  /// 占位底色：暗色下略亮一档，避免和背景糊在一起。
  static Color _placeholderColor(ColorScheme scheme) =>
      scheme.surfaceContainerHighest.withValues(alpha: 0.6);
}

/// 卡片入场：轻微上浮淡入。
///
/// 只对第一屏做（index 超过 [_kMaxStagger] 后不再有动画），滚动加载更多时
/// 新卡片直接出现，避免每页都抖一遍惹人烦。
class CardEntrance extends StatelessWidget {
  const CardEntrance({super.key, required this.index, required this.child});

  /// 参与入场序的卡片数量上限。
  static const int maxStagger = 12;

  /// 单张卡片的入场时长。
  static const Duration duration = Duration(milliseconds: 320);

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final i = index >= maxStagger ? maxStagger - 1 : index;
    return TweenAnimationBuilder<double>(
      key: ValueKey<double>(i.toDouble()),
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: duration.inMilliseconds + i * 32),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 网格卡片：封面 + 标题 + 作者，点整卡进入详情。
class MangaGridCard extends StatelessWidget {
  const MangaGridCard({
    super.key,
    required this.title,
    required this.author,
    required this.cover,
    this.onTap,
    this.animated = false,
    this.index = 0,
  });

  final String title;
  final String author;
  final String cover;
  final VoidCallback? onTap;

  /// 是否套一层入场动画（仅列表首屏开启）。
  final bool animated;

  /// 卡片序号，决定入场错开的先后。
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: MangaCover(url: cover, aspectRatio: null, iconSize: 26),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.isEmpty ? '（无标题）' : title,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    author.isEmpty ? '未知作者' : author,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!animated) return card;
    return CardEntrance(index: index, child: card);
  }
}

/// 列表行：左侧小封面 + 右侧标题/作者，用于搜索结果。
class MangaListRow extends StatelessWidget {
  const MangaListRow({
    super.key,
    required this.title,
    required this.author,
    required this.cover,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String author;
  final String cover;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: SizedBox(
        width: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: MangaCover(url: cover, iconSize: 20),
        ),
      ),
      title: Text(
        title.isEmpty ? '（无标题）' : title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        author.isEmpty ? '未知作者' : author,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
      dense: false,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      tileColor: scheme.surfaceContainerLowest,
    );
  }
}

/// 三态视图：加载 / 空 / 失败（可重试）。有内容时渲染 [child]。
class BrowseStateView extends StatelessWidget {
  const BrowseStateView({
    super.key,
    required this.status,
    required this.child,
    this.error,
    this.onRetry,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyText = '这里还没有内容',
    this.errorText,
    this.padding = const EdgeInsets.all(24),
  });

  final BrowseStatus status;
  final Widget child;
  final Object? error;
  final VoidCallback? onRetry;

  /// 空态图标；列表为空时给个不刺眼的符号即可。
  final IconData emptyIcon;
  final String emptyText;
  final String? errorText;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case BrowseStatus.loading:
        return Center(
          child: Padding(
            padding: padding,
            child: const CircularProgressIndicator(),
          ),
        );
      case BrowseStatus.empty:
        return Center(
          child: Padding(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  emptyIcon,
                  size: 44,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 12),
                Text(
                  emptyText,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新加载'),
                  ),
                ],
              ],
            ),
          ),
        );
      case BrowseStatus.error:
        return Center(
          child: Padding(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 40,
                  color: scheme.error.withValues(alpha: 0.85),
                ),
                const SizedBox(height: 12),
                Text(
                  '加载失败',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  errorText ?? describeBrowseError(error),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      case BrowseStatus.ready:
        return child;
    }
  }
}

/// 分页尾部：加载中 / 到底 / 下一页失败可重试。
class BrowsePagingFooter extends StatelessWidget {
  const BrowsePagingFooter({super.key, required this.controller});

  final BrowsePagingController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (controller.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (controller.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: controller.retryLoadMore,
            icon: const Icon(Icons.refresh),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (!controller.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    // 还有下一页但未触发时留一段空白，避免滚到底毫无提示。
    return const SizedBox(height: 16);
  }
}

/// 顶部/分组内的筛选标签行：单选，选中项高亮。
class BrowseOptionChips<T> extends StatelessWidget {
  const BrowseOptionChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.label,
  });

  /// 候选值：显示名 → 实际参数值（null 表示「全部」）。
  final List<BrowseOption<T>> options;
  final T? selected;
  final ValueChanged<T?> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 2),
              child: Text(
                label!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: options
                .map(
                  (o) => ChoiceChip(
                    label: Text(o.label),
                    selected: o.value == selected,
                    showCheckmark: false,
                    onSelected: (_) => onChanged(o.value),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: o.value == selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

/// 筛选项：界面显示名 + 传给接口的值。
class BrowseOption<T> {
  const BrowseOption(this.label, this.value);

  final String label;

  /// 为 null 表示「全部」，接口侧不传该参数。
  final T? value;
}
