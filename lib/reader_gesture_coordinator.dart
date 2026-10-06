import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter/material.dart' show Matrix4;

import 'reader_gesture_config.dart';

/// 阅读器图片层手势模式（单一状态机，禁止散落布尔拼接）。
enum ReaderGestureMode {
  idle,
  singlePointerCandidate,
  pageDrag,
  multiPointerCandidate,
  imageScaling,
  imagePanning,
  settling,
  disposed,
}

/// 手势所有权（诊断用）。
enum ReaderGestureOwner { none, pageView, imageScale, imagePan, tap, doubleTap }

/// 协调器输出的变换快照。
@immutable
class ReaderGestureTransform {
  const ReaderGestureTransform({
    required this.scale,
    required this.translation,
  });

  final double scale;
  final Offset translation;

  static const identity = ReaderGestureTransform(
    scale: 1.0,
    translation: Offset.zero,
  );

  bool get isZoomed => scale > 1.0 + kReaderScaleEpsilon;

  Matrix4 toMatrix4() {
    return Matrix4.identity()
      ..translateByDouble(translation.dx, translation.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  ReaderGestureTransform copyWith({double? scale, Offset? translation}) {
    return ReaderGestureTransform(
      scale: scale ?? this.scale,
      translation: translation ?? this.translation,
    );
  }
}

/// 纯 Dart 阅读器手势协调器。
///
/// 未缩放单指横/纵滑 → [ReaderGestureMode.pageDrag]（所有权交给 PageView，本层不抢竞技场）。
/// 第二指 → [ReaderGestureMode.imageScaling]。
/// 已放大单指 → [ReaderGestureMode.imagePanning]。
/// 不依赖 InteractiveViewer；不使用私有 API；不使用 Future.delayed 猜测所有权。
class ReaderGestureCoordinator {
  ReaderGestureCoordinator({
    this.onModeChanged,
    this.onOwnerChanged,
    this.onTransformChanged,
    this.onZoomChanged,
    this.onLocksPageViewChanged,
    double maxScale = kReaderMaxScale,
    double scaleEpsilon = kReaderScaleEpsilon,
    double tapSlop = kReaderTapSlopLogicalPx,
  }) : _maxScale = maxScale,
       _scaleEpsilon = scaleEpsilon,
       _tapSlop = tapSlop;

  final void Function(ReaderGestureMode from, ReaderGestureMode to)?
  onModeChanged;
  final void Function(ReaderGestureOwner owner, {required String reason})?
  onOwnerChanged;
  final void Function(ReaderGestureTransform transform)? onTransformChanged;
  final void Function(bool zoomed)? onZoomChanged;
  final void Function(bool locks)? onLocksPageViewChanged;

  final double _maxScale;
  final double _scaleEpsilon;
  final double _tapSlop;

  ReaderGestureMode _mode = ReaderGestureMode.idle;
  ReaderGestureOwner _owner = ReaderGestureOwner.none;
  ReaderGestureTransform _transform = ReaderGestureTransform.identity;

  final Map<int, Offset> _pointers = {};
  int? _primaryPointer;
  Offset? _downPos;
  bool _movedBeyondSlop = false;

  // 捏合
  double? _pinchStartDistance;
  double? _pinchStartScale;
  Offset? _pinchStartFocal;
  Offset? _pinchStartTranslation;

  // 平移
  Offset? _panLastPos;

  Size _viewport = Size.zero;
  bool _zoomed = false;
  bool _locksPageView = false;

  ReaderGestureMode get mode => _mode;
  ReaderGestureOwner get owner => _owner;
  ReaderGestureTransform get transform => _transform;
  bool get isZoomed => _zoomed;
  bool get locksPageView => _locksPageView;
  int get activePointerCount => _pointers.length;
  bool get isDisposed => _mode == ReaderGestureMode.disposed;

  void updateViewport(Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _viewport = size;
  }

  void onPointerDown(int pointer, Offset localPos) {
    if (_mode == ReaderGestureMode.disposed) return;

    _pointers[pointer] = localPos;

    if (_pointers.length == 1) {
      _primaryPointer = pointer;
      _downPos = localPos;
      _movedBeyondSlop = false;
      if (_transform.isZoomed) {
        _setMode(ReaderGestureMode.imagePanning);
        _setOwner(ReaderGestureOwner.imagePan, reason: 'zoomedSinglePointer');
        _panLastPos = localPos;
        _updateLocks();
      } else {
        _setMode(ReaderGestureMode.singlePointerCandidate);
        _setOwner(ReaderGestureOwner.none, reason: 'singlePointerCandidate');
        _updateLocks();
      }
      return;
    }

    // 第二指及以后 → 缩放
    if (_pointers.length == 2) {
      _cancelPageDragIntent();
      _beginPinch();
      _setMode(ReaderGestureMode.imageScaling);
      _setOwner(ReaderGestureOwner.imageScale, reason: 'secondPointerJoined');
      _updateLocks();
      return;
    }

    if (_mode != ReaderGestureMode.imageScaling) {
      _setMode(ReaderGestureMode.imageScaling);
      _setOwner(ReaderGestureOwner.imageScale, reason: 'additionalPointer');
      _updateLocks();
    }
  }

  void onPointerMove(int pointer, Offset localPos) {
    if (_mode == ReaderGestureMode.disposed) return;
    if (!_pointers.containsKey(pointer)) return;
    _pointers[pointer] = localPos;

    switch (_mode) {
      case ReaderGestureMode.singlePointerCandidate:
      case ReaderGestureMode.pageDrag:
        if (_downPos != null &&
            (localPos - _downPos!).distance > _tapSlop &&
            !_movedBeyondSlop) {
          _movedBeyondSlop = true;
          if (!_transform.isZoomed) {
            _setMode(ReaderGestureMode.pageDrag);
            _setOwner(ReaderGestureOwner.pageView, reason: 'singleFingerDrag');
          }
        }
      case ReaderGestureMode.imagePanning:
        if (_panLastPos != null && pointer == _primaryPointer) {
          final delta = localPos - _panLastPos!;
          _panLastPos = localPos;
          _applyTranslationDelta(delta);
        }
      case ReaderGestureMode.imageScaling:
      case ReaderGestureMode.multiPointerCandidate:
        if (_pointers.length >= 2) {
          _updatePinch();
        }
      case ReaderGestureMode.idle:
      case ReaderGestureMode.settling:
      case ReaderGestureMode.disposed:
        break;
    }
  }

  void onPointerUp(int pointer, Offset localPos) {
    if (_mode == ReaderGestureMode.disposed) return;
    _pointers.remove(pointer);

    if (_pointers.isEmpty) {
      _primaryPointer = null;
      _downPos = null;
      _panLastPos = null;
      _clearPinch();
      _finishGestureSequence();
      return;
    }

    // 仍有指针：若从双指回到单指
    if (_pointers.length == 1) {
      final remaining = _pointers.entries.first;
      _primaryPointer = remaining.key;
      if (_transform.isZoomed) {
        _setMode(ReaderGestureMode.imagePanning);
        _setOwner(
          ReaderGestureOwner.imagePan,
          reason: 'backToSingleWhileZoomed',
        );
        _panLastPos = remaining.value;
        // 保持 PageView 锁定，直到全部抬起且（若缩回）手势结束
        _updateLocks(forceLock: true);
      } else {
        // 缩放过但已回 1.0，仍有一指：不立刻恢复翻页，等全部抬起
        _setMode(ReaderGestureMode.singlePointerCandidate);
        _setOwner(ReaderGestureOwner.none, reason: 'backToSingleUnzoomed');
        _updateLocks(forceLock: true);
      }
      _clearPinch();
      return;
    }

    // 仍 ≥2 指：继续缩放
    _beginPinch();
  }

  void onPointerCancel(int pointer) {
    if (_mode == ReaderGestureMode.disposed) return;
    _pointers.remove(pointer);
    if (_pointers.isEmpty) {
      _primaryPointer = null;
      _downPos = null;
      _panLastPos = null;
      _clearPinch();
      _setMode(ReaderGestureMode.idle);
      _setOwner(ReaderGestureOwner.none, reason: 'pointerCancel');
      _updateLocks();
      return;
    }
    if (_pointers.length == 1 && _transform.isZoomed) {
      final remaining = _pointers.entries.first;
      _primaryPointer = remaining.key;
      _setMode(ReaderGestureMode.imagePanning);
      _panLastPos = remaining.value;
      _updateLocks(forceLock: true);
    }
  }

  /// 双击放大/还原。返回是否已处理。
  bool onDoubleTap(Offset localPos) {
    if (_mode == ReaderGestureMode.disposed) return false;
    if (_pointers.isNotEmpty) return false;

    _setOwner(ReaderGestureOwner.doubleTap, reason: 'doubleTap');
    if (_transform.isZoomed) {
      _setTransform(ReaderGestureTransform.identity);
      _setMode(ReaderGestureMode.settling);
      _setMode(ReaderGestureMode.idle);
      _setOwner(ReaderGestureOwner.none, reason: 'doubleTapReset');
      _updateLocks();
      return true;
    }

    final s = kReaderDoubleTapScale;
    final translation = Offset(-localPos.dx * (s - 1), -localPos.dy * (s - 1));
    _setTransform(ReaderGestureTransform(scale: s, translation: translation));
    _setMode(ReaderGestureMode.settling);
    _setMode(ReaderGestureMode.idle);
    _setOwner(ReaderGestureOwner.none, reason: 'doubleTapZoomed');
    _updateLocks();
    return true;
  }

  /// 单击：仅当未移动且未缩放交互时由 UI 层决定分区；此处只报告是否为 tap 候选。
  bool get isTapCandidate =>
      !_movedBeyondSlop &&
      !_transform.isZoomed &&
      _mode != ReaderGestureMode.imageScaling &&
      _mode != ReaderGestureMode.disposed;

  void onReadingModeChanged() {
    if (_mode == ReaderGestureMode.disposed) return;
    _pointers.clear();
    _clearPinch();
    _primaryPointer = null;
    _setTransform(ReaderGestureTransform.identity);
    _setMode(ReaderGestureMode.idle);
    _setOwner(ReaderGestureOwner.none, reason: 'readingModeChanged');
    _updateLocks();
  }

  void onAppPaused() {
    if (_mode == ReaderGestureMode.disposed) return;
    _pointers.clear();
    _clearPinch();
    _primaryPointer = null;
    _setMode(ReaderGestureMode.idle);
    _setOwner(ReaderGestureOwner.none, reason: 'appPaused');
    _updateLocks();
  }

  void resetToIdentity({required String reason}) {
    if (_mode == ReaderGestureMode.disposed) return;
    _setTransform(ReaderGestureTransform.identity);
    if (_pointers.isEmpty) {
      _setMode(ReaderGestureMode.idle);
      _setOwner(ReaderGestureOwner.none, reason: reason);
      _updateLocks();
    }
  }

  void dispose() {
    _pointers.clear();
    _clearPinch();
    _setMode(ReaderGestureMode.disposed);
    _setOwner(ReaderGestureOwner.none, reason: 'disposed');
    _locksPageView = false;
    onLocksPageViewChanged?.call(false);
  }

  // ---- internals ----

  void _finishGestureSequence() {
    // 手势完全结束后，若已缩回 1.0，恢复 PageView
    if (!_transform.isZoomed) {
      if (_transform.scale != 1.0 || _transform.translation != Offset.zero) {
        _setTransform(ReaderGestureTransform.identity);
      }
      _setMode(ReaderGestureMode.idle);
      _setOwner(ReaderGestureOwner.none, reason: 'gestureEndedUnzoomed');
      _updateLocks();
      return;
    }
    _setMode(ReaderGestureMode.idle);
    _setOwner(ReaderGestureOwner.none, reason: 'gestureEndedZoomed');
    _updateLocks();
  }

  void _cancelPageDragIntent() {
    // 进入多指时，仅切换状态；PageView 由 locksPageView 锁住。
    if (_mode == ReaderGestureMode.pageDrag ||
        _mode == ReaderGestureMode.singlePointerCandidate) {
      _setMode(ReaderGestureMode.multiPointerCandidate);
    }
  }

  void _beginPinch() {
    if (_pointers.length < 2) return;
    final pts = _pointers.values.toList();
    _pinchStartDistance = (pts[0] - pts[1]).distance.clamp(1.0, 1e6);
    _pinchStartScale = _transform.scale;
    _pinchStartFocal = Offset(
      (pts[0].dx + pts[1].dx) / 2,
      (pts[0].dy + pts[1].dy) / 2,
    );
    _pinchStartTranslation = _transform.translation;
  }

  void _updatePinch() {
    if (_pointers.length < 2 ||
        _pinchStartDistance == null ||
        _pinchStartScale == null ||
        _pinchStartFocal == null ||
        _pinchStartTranslation == null) {
      _beginPinch();
      return;
    }
    final pts = _pointers.values.toList();
    final dist = (pts[0] - pts[1]).distance.clamp(1.0, 1e6);
    final focal = Offset(
      (pts[0].dx + pts[1].dx) / 2,
      (pts[0].dy + pts[1].dy) / 2,
    );
    var newScale = (_pinchStartScale! * (dist / _pinchStartDistance!)).clamp(
      1.0,
      _maxScale,
    );

    // 以起始焦点为缩放中心，并跟随焦点平移
    final startFocal = _pinchStartFocal!;
    final startT = _pinchStartTranslation!;
    final startS = _pinchStartScale!;
    // 焦点在内容坐标中的位置（近似）
    final focalInContent = Offset(
      (startFocal.dx - startT.dx) / startS,
      (startFocal.dy - startT.dy) / startS,
    );
    var translation = Offset(
      focal.dx - focalInContent.dx * newScale,
      focal.dy - focalInContent.dy * newScale,
    );

    if (newScale <= 1.0 + _scaleEpsilon) {
      newScale = 1.0;
      translation = Offset.zero;
    } else {
      translation = _clampTranslation(newScale, translation);
    }

    _setTransform(
      ReaderGestureTransform(scale: newScale, translation: translation),
    );
  }

  void _clearPinch() {
    _pinchStartDistance = null;
    _pinchStartScale = null;
    _pinchStartFocal = null;
    _pinchStartTranslation = null;
  }

  void _applyTranslationDelta(Offset delta) {
    final next = _clampTranslation(
      _transform.scale,
      _transform.translation + delta,
    );
    _setTransform(_transform.copyWith(translation: next));
  }

  Offset _clampTranslation(double scale, Offset t) {
    if (scale <= 1.0 + _scaleEpsilon || _viewport == Size.zero) {
      return Offset.zero;
    }
    final maxX = (_viewport.width * (scale - 1)).clamp(0.0, double.infinity);
    final maxY = (_viewport.height * (scale - 1)).clamp(0.0, double.infinity);
    // translation 通常为负（内容向左上移）；允许范围约 [-max, 0]
    return Offset(t.dx.clamp(-maxX, 0.0), t.dy.clamp(-maxY, 0.0));
  }

  void _setTransform(ReaderGestureTransform next) {
    _transform = next;
    onTransformChanged?.call(next);
    final z = next.isZoomed;
    if (z != _zoomed) {
      _zoomed = z;
      onZoomChanged?.call(z);
    }
  }

  void _setMode(ReaderGestureMode next) {
    if (_mode == next) return;
    final from = _mode;
    _mode = next;
    onModeChanged?.call(from, next);
  }

  void _setOwner(ReaderGestureOwner owner, {required String reason}) {
    if (_owner == owner) return;
    _owner = owner;
    onOwnerChanged?.call(owner, reason: reason);
  }

  void _updateLocks({bool forceLock = false}) {
    final locks =
        forceLock ||
        _transform.isZoomed ||
        _pointers.length >= 2 ||
        _mode == ReaderGestureMode.imageScaling ||
        _mode == ReaderGestureMode.imagePanning ||
        _mode == ReaderGestureMode.multiPointerCandidate;
    if (locks == _locksPageView) return;
    _locksPageView = locks;
    onLocksPageViewChanged?.call(locks);
  }
}
