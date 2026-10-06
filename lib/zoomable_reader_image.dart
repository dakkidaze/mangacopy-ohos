import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'reader_gesture_config.dart';
import 'reader_gesture_coordinator.dart';
import 'reader_gesture_debug.dart';
import 'reader_tap_zones.dart';

/// 单页可缩放图：正式路径由 [ReaderGestureCoordinator] 仲裁；
/// legacy 路径保留 InteractiveViewer（`--dart-define=READER_LEGACY_GESTURE_ROUTING=true`）。
class ZoomableReaderImage extends StatefulWidget {
  const ZoomableReaderImage({
    super.key,
    required this.child,
    required this.isHorizontal,
    required this.r2l,
    required this.onPageTurn,
    required this.onMenu,
    this.onZoomChanged,
    this.onLocksPageViewChanged,
  });

  final Widget child;
  final bool isHorizontal;
  final bool r2l;
  final void Function(bool goNext) onPageTurn;
  final VoidCallback onMenu;
  final ValueChanged<bool>? onZoomChanged;
  final ValueChanged<bool>? onLocksPageViewChanged;

  /// 兼容旧实验测试查询；正式默认恒为 false。
  @visibleForTesting
  static bool get experimentBypassIvWhenUnzoomed =>
      kReaderGestureExperimentBypassIvWhenUnzoomed;

  @visibleForTesting
  static bool get useLegacyGestureRouting => kReaderLegacyGestureRouting;

  @override
  State<ZoomableReaderImage> createState() => _ZoomableReaderImageState();
}

class _ZoomableReaderImageState extends State<ZoomableReaderImage>
    with SingleTickerProviderStateMixin {
  // ---- shared tap / double-tap ----
  int _pointers = 0;
  Offset? _downPos;
  int? _downPointer;
  DateTime? _firstTapAt;
  Offset? _firstTapPos;
  bool _moved = false;
  bool _scaleInteracting = false;

  // ---- formal path ----
  late final ReaderGestureCoordinator _coordinator;
  Matrix4 _matrix = Matrix4.identity();
  late final AnimationController _anim;
  Animation<Matrix4>? _matrixAnim;

  // ---- legacy path ----
  final _legacyTransform = TransformationController();
  bool _legacyZoomed = false;

  bool get _legacy => kReaderLegacyGestureRouting;

  @override
  void initState() {
    super.initState();
    _anim =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          final a = _matrixAnim;
          if (a != null) {
            setState(() => _matrix = a.value);
          }
        });

    _coordinator = ReaderGestureCoordinator(
      onModeChanged: (from, to) {
        if (ReaderGestureDiagnostics.enabled) {
          ReaderGestureDiagnostics.instance.onGestureModeChanged(
            from: from.name,
            to: to.name,
          );
        }
      },
      onOwnerChanged: (owner, {required reason}) {
        if (ReaderGestureDiagnostics.enabled) {
          ReaderGestureDiagnostics.instance.onGestureOwnerChanged(
            owner: owner.name,
            reason: reason,
          );
        }
      },
      onTransformChanged: (t) {
        if (_anim.isAnimating) _anim.stop();
        setState(() => _matrix = t.toMatrix4());
      },
      onZoomChanged: (z) {
        widget.onZoomChanged?.call(z);
      },
      onLocksPageViewChanged: (locks) {
        widget.onLocksPageViewChanged?.call(locks);
      },
    );

    if (_legacy) {
      _legacyTransform.addListener(_onLegacyTransformChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    _coordinator.updateViewport(size);
  }

  @override
  void dispose() {
    if (_legacy) {
      _legacyTransform.removeListener(_onLegacyTransformChanged);
      _legacyTransform.dispose();
    }
    _coordinator.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _onLegacyTransformChanged() {
    final z = _legacyTransform.value.getMaxScaleOnAxis() > 1.05;
    if (z != _legacyZoomed) {
      setState(() => _legacyZoomed = z);
      widget.onZoomChanged?.call(z);
    }
  }

  void _animateMatrixTo(Matrix4 target) {
    _matrixAnim = Matrix4Tween(
      begin: _matrix,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
  }

  void _toggleDoubleTapZoom(Offset pos) {
    if (_legacy) {
      _legacyToggleDoubleTap(pos);
      return;
    }
    final begin = _matrix.clone();
    if (!_coordinator.onDoubleTap(pos)) return;
    final end = _coordinator.transform.toMatrix4();
    _matrix = begin;
    _animateMatrixTo(end);
  }

  void _legacyToggleDoubleTap(Offset pos) {
    final scale = _legacyTransform.value.getMaxScaleOnAxis();
    if (scale > 1.05) {
      _legacyAnimateTo(Matrix4.identity());
      return;
    }
    const s = kReaderDoubleTapScale;
    final zoomed = Matrix4.identity()
      ..translateByDouble(-pos.dx * (s - 1), -pos.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
    _legacyAnimateTo(zoomed);
  }

  void _legacyAnimateTo(Matrix4 target) {
    _matrixAnim = Matrix4Tween(
      begin: _legacyTransform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward(from: 0);
    // legacy uses TransformationController via listener on _anim
    void tick() {
      final a = _matrixAnim;
      if (a != null) _legacyTransform.value = a.value;
    }

    _anim.removeListener(tick);
    _anim.addListener(tick);
  }

  void _handleSingleTap(Offset pos) {
    final zoomed = _legacy ? _legacyZoomed : _coordinator.isZoomed;
    if (zoomed) {
      if (_legacy) {
        _legacyAnimateTo(Matrix4.identity());
      } else {
        _coordinator.resetToIdentity(reason: 'singleTapResetZoom');
        _animateMatrixTo(Matrix4.identity());
      }
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    switch (classifyReaderTap(
      pos,
      box.size,
      isHorizontal: widget.isHorizontal,
      r2l: widget.r2l,
    )) {
      case ReaderTapZone.menu:
        widget.onMenu();
      case ReaderTapZone.next:
        widget.onPageTurn(true);
      case ReaderTapZone.prev:
        widget.onPageTurn(false);
      case ReaderTapZone.none:
        break;
    }
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (!_legacy) {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _coordinator.updateViewport(box.size);
      }
      _coordinator.onPointerDown(e.pointer, e.localPosition);
    }
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
    if (!_legacy) {
      _coordinator.onPointerMove(e.pointer, e.localPosition);
    }
    if (e.pointer != _downPointer || _downPos == null) return;
    if ((e.localPosition - _downPos!).distance > kReaderTapSlopLogicalPx) {
      _moved = true;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointers = (_pointers - 1).clamp(0, 20);
    if (!_legacy) {
      _coordinator.onPointerUp(e.pointer, e.localPosition);
    }
    if (e.pointer != _downPointer) return;
    final down = _downPos;
    final moved = _moved;
    final scaleBusy = _legacy
        ? _scaleInteracting
        : (_coordinator.mode == ReaderGestureMode.imageScaling);
    _downPointer = null;
    _downPos = null;
    if (down == null || moved || scaleBusy || _pointers > 0) return;

    final now = DateTime.now();
    final firstAt = _firstTapAt;
    final firstPos = _firstTapPos;
    if (firstAt != null &&
        firstPos != null &&
        now.difference(firstAt) <= kReaderDoubleTapTimeout &&
        (e.localPosition - firstPos).distance <= kReaderTapSlopLogicalPx * 2) {
      _firstTapAt = null;
      _firstTapPos = null;
      _toggleDoubleTapZoom(e.localPosition);
      return;
    }

    _firstTapAt = now;
    _firstTapPos = e.localPosition;
    final scheduledPos = e.localPosition;
    final scheduledAt = now;
    Future<void>.delayed(kReaderDoubleTapTimeout, () {
      if (!mounted) return;
      if (_firstTapAt != scheduledAt || _firstTapPos != scheduledPos) return;
      _firstTapAt = null;
      _firstTapPos = null;
      _handleSingleTap(scheduledPos);
    });
  }

  void _onPointerCancel(PointerEvent e) {
    _pointers = (_pointers - 1).clamp(0, 20);
    if (!_legacy) {
      _coordinator.onPointerCancel(e.pointer);
    }
    if (e.pointer == _downPointer) {
      _downPointer = null;
      _downPos = null;
    }
  }

  Widget _buildImageContent() {
    return SizedBox.expand(child: Center(child: widget.child));
  }

  Widget _buildFormalLayer() {
    // 未放大时不用 InteractiveViewer，单指横滑完全交给 PageView。
    // 双指缩放 / 放大平移由 Coordinator 直接改 Matrix4。
    return ClipRect(
      child: Transform(
        transform: _matrix,
        alignment: Alignment.topLeft,
        filterQuality: FilterQuality.medium,
        child: _buildImageContent(),
      ),
    );
  }

  Widget _buildLegacyInteractiveLayer(Widget child) {
    return InteractiveViewer(
      transformationController: _legacyTransform,
      minScale: 1,
      maxScale: kReaderMaxScale,
      panEnabled: _legacyZoomed,
      scaleEnabled: true,
      clipBehavior: Clip.hardEdge,
      onInteractionStart: (details) {
        if (details.pointerCount > 1) {
          _scaleInteracting = true;
          _firstTapAt = null;
          _firstTapPos = null;
        }
        if (ReaderGestureDiagnostics.enabled) {
          ReaderGestureDiagnostics.instance.onInteractionStarted(
            pointerCount: details.pointerCount,
            startScale: _legacyTransform.value.getMaxScaleOnAxis(),
            readerInstanceId:
                ReaderGestureDiagnostics.instance.activeReaderInstanceId,
          );
        }
      },
      onInteractionUpdate: (details) {
        if (ReaderGestureDiagnostics.enabled) {
          ReaderGestureDiagnostics.instance.onInteractionUpdated(
            scale: _legacyTransform.value.getMaxScaleOnAxis(),
            panChanged: details.focalPointDelta.distanceSquared > 0,
            readerInstanceId:
                ReaderGestureDiagnostics.instance.activeReaderInstanceId,
          );
        }
      },
      onInteractionEnd: (_) {
        _scaleInteracting = false;
        _onLegacyTransformChanged();
        if (ReaderGestureDiagnostics.enabled) {
          ReaderGestureDiagnostics.instance.onInteractionEnded(
            endScale: _legacyTransform.value.getMaxScaleOnAxis(),
            readerInstanceId:
                ReaderGestureDiagnostics.instance.activeReaderInstanceId,
          );
        }
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onLegacyTransformChanged();
        });
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: _legacy
          ? _buildLegacyInteractiveLayer(_buildImageContent())
          : _buildFormalLayer(),
    );
  }
}
