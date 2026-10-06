import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 条漫模式连续长列表可缩放容器：
/// - 支持 1.0x ~ 4.0x 随意双指捏合连续缩放与双击放大/还原；
/// - 未放大（Scale 1.0）时关闭二维平移（panEnabled = false），单指上下滑直接驱动长列表流畅滚动。
class ZoomableWebtoonView extends StatefulWidget {
  const ZoomableWebtoonView({
    super.key,
    required this.child,
    this.onZoomChanged,
  });

  final Widget child;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<ZoomableWebtoonView> createState() => _ZoomableWebtoonViewState();
}

class _ZoomableWebtoonViewState extends State<ZoomableWebtoonView>
    with SingleTickerProviderStateMixin {
  static const _maxScale = 4.0;
  static const _doubleTapScale = 2.0;
  static const _tapSlop = 18.0;
  static const _doubleTapTimeout = Duration(milliseconds: 280);

  final _transform = TransformationController();
  late final AnimationController _anim;
  Animation<Matrix4>? _matrixAnim;
  bool _zoomed = false;

  int _pointers = 0;
  Offset? _downPos;
  int? _downPointer;
  DateTime? _firstTapAt;
  Offset? _firstTapPos;
  bool _moved = false;
  bool _scaleInteracting = false;

  @override
  void initState() {
    super.initState();
    _anim =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          final a = _matrixAnim;
          if (a != null) _transform.value = a.value;
        });
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final z = _transform.value.getMaxScaleOnAxis() > 1.05;
    if (z != _zoomed) {
      setState(() => _zoomed = z);
      widget.onZoomChanged?.call(z);
    }
  }

  void _animateTo(Matrix4 target) {
    _matrixAnim = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
  }

  void _toggleDoubleTapZoom(Offset pos) {
    final scale = _transform.value.getMaxScaleOnAxis();
    if (scale > 1.05) {
      _animateTo(Matrix4.identity());
      return;
    }
    const s = _doubleTapScale;
    final zoomed = Matrix4.identity()
      ..translateByDouble(-pos.dx * (s - 1), -pos.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
    _animateTo(zoomed);
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers > 1) {
      _downPointer = null;
      _downPos = null;
      _firstTapAt = null;
      _firstTapPos = null;
      return;
    }
    _downPointer = e.pointer;
    _downPos = e.localPosition;
    _moved = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _downPointer || _downPos == null) return;
    if ((e.localPosition - _downPos!).distance > _tapSlop) {
      _moved = true;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointers = (_pointers - 1).clamp(0, 20);
    if (e.pointer != _downPointer) return;
    final down = _downPos;
    final moved = _moved;
    final scaleBusy = _scaleInteracting;
    _downPointer = null;
    _downPos = null;
    if (down == null || moved || scaleBusy || _pointers > 0) return;

    final now = DateTime.now();
    final firstAt = _firstTapAt;
    final firstPos = _firstTapPos;
    if (firstAt != null &&
        firstPos != null &&
        now.difference(firstAt) <= _doubleTapTimeout &&
        (e.localPosition - firstPos).distance <= _tapSlop * 2) {
      _firstTapAt = null;
      _firstTapPos = null;
      _toggleDoubleTapZoom(e.localPosition);
      return;
    }

    _firstTapAt = now;
    _firstTapPos = e.localPosition;
  }

  void _onPointerCancel(PointerEvent e) {
    _pointers = (_pointers - 1).clamp(0, 20);
    if (e.pointer == _downPointer) {
      _downPointer = null;
      _downPos = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1.0,
        maxScale: _maxScale,
        panEnabled: _zoomed,
        scaleEnabled: true,
        clipBehavior: Clip.hardEdge,
        onInteractionStart: (details) {
          if (details.pointerCount > 1) {
            _scaleInteracting = true;
            _firstTapAt = null;
            _firstTapPos = null;
          }
        },
        onInteractionEnd: (_) {
          _scaleInteracting = false;
          _onTransformChanged();
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) _onTransformChanged();
          });
        },
        child: widget.child,
      ),
    );
  }
}
