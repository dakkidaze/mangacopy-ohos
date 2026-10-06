import 'package:flutter/material.dart';

/// 阅读器点击分区结果。
enum ReaderTapZone { prev, next, menu, none }

/// 横向：左/中/右三分区（随右开本左右对调）。
/// 纵向：上/中/下三分区；菜单保留居中小矩形，中带左右两侧无效（防误触）。
ReaderTapZone classifyReaderTap(
  Offset pos,
  Size size, {
  required bool isHorizontal,
  required bool r2l,
}) {
  final w = size.width;
  final h = size.height;
  if (w <= 0 || h <= 0) return ReaderTapZone.menu;
  if (isHorizontal) {
    final frac = pos.dx / w;
    if (frac <= 1 / 3) {
      return r2l ? ReaderTapZone.next : ReaderTapZone.prev;
    }
    if (frac >= 2 / 3) {
      return r2l ? ReaderTapZone.prev : ReaderTapZone.next;
    }
    return ReaderTapZone.menu;
  }

  final fracY = pos.dy / h;
  if (fracY <= 1 / 3) return ReaderTapZone.prev;
  if (fracY >= 2 / 3) return ReaderTapZone.next;

  // 中 1/3：仅现有菜单矩形生效，左右剩余区域无效
  final cx = w * 0.5;
  final cy = h * 0.5;
  final mw = w * 0.38;
  final mh = h * 0.32;
  if ((pos.dx - cx).abs() < mw / 2 && (pos.dy - cy).abs() < mh / 2) {
    return ReaderTapZone.menu;
  }
  return ReaderTapZone.none;
}

/// 条漫模式叠层：只识别轻点，多指/滑动不触发；不挡住下层滚动。
/// [enablePageTurn] 为 false 时仅中央菜单生效（条漫滑动易误触翻页）。
class ReaderTapZones extends StatefulWidget {
  const ReaderTapZones({
    super.key,
    required this.isHorizontal,
    required this.r2l,
    required this.onPageTurn,
    required this.onMenu,
    this.enablePageTurn = true,
  });

  final bool isHorizontal;
  final bool r2l;
  final void Function(bool goNext) onPageTurn;
  final VoidCallback onMenu;
  final bool enablePageTurn;

  @override
  State<ReaderTapZones> createState() => _ReaderTapZonesState();
}

class _ReaderTapZonesState extends State<ReaderTapZones> {
  static const _tapSlop = 18.0;
  Offset? _down;
  int _pointers = 0;

  void _onTap(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    switch (classifyReaderTap(
      local,
      box.size,
      isHorizontal: widget.isHorizontal,
      r2l: widget.r2l,
    )) {
      case ReaderTapZone.menu:
        widget.onMenu();
      case ReaderTapZone.next:
        if (widget.enablePageTurn) widget.onPageTurn(true);
      case ReaderTapZone.prev:
        if (widget.enablePageTurn) widget.onPageTurn(false);
      case ReaderTapZone.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointers++;
        if (_pointers == 1) _down = e.localPosition;
      },
      onPointerCancel: (_) {
        _pointers = (_pointers - 1).clamp(0, 10);
        if (_pointers == 0) _down = null;
      },
      onPointerUp: (e) {
        final down = _down;
        final multi = _pointers > 1;
        _pointers = (_pointers - 1).clamp(0, 10);
        if (_pointers == 0) _down = null;
        if (multi || down == null) return;
        if ((e.localPosition - down).distance > _tapSlop) return;
        _onTap(e.localPosition);
      },
      child: const SizedBox.expand(),
    );
  }
}
