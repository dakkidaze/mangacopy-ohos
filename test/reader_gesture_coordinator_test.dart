import 'package:copymanga_flutter/reader_gesture_config.dart';
import 'package:copymanga_flutter/reader_gesture_coordinator.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReaderGestureCoordinator', () {
    late ReaderGestureCoordinator c;
    late List<String> modes;
    late List<String> owners;

    setUp(() {
      modes = [];
      owners = [];
      c = ReaderGestureCoordinator(
        onModeChanged: (from, to) => modes.add('${from.name}->${to.name}'),
        onOwnerChanged: (o, {required reason}) =>
            owners.add('${o.name}:$reason'),
      );
      c.updateViewport(const Size(360, 640));
    });

    tearDown(() => c.dispose());

    test('未缩放单指横滑 → pageDrag', () {
      c.onPointerDown(1, const Offset(200, 300));
      expect(c.mode, ReaderGestureMode.singlePointerCandidate);
      c.onPointerMove(1, const Offset(140, 300));
      expect(c.mode, ReaderGestureMode.pageDrag);
      expect(c.owner, ReaderGestureOwner.pageView);
      expect(c.locksPageView, isFalse);
    });

    test('未缩放单指点击 → 不变成 pageDrag', () {
      c.onPointerDown(1, const Offset(200, 300));
      c.onPointerMove(1, const Offset(205, 302));
      expect(c.mode, ReaderGestureMode.singlePointerCandidate);
      expect(c.isTapCandidate, isTrue);
      c.onPointerUp(1, const Offset(205, 302));
      expect(c.mode, ReaderGestureMode.idle);
    });

    test('第二指加入 → imageScaling', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerMove(1, const Offset(100, 300));
      expect(c.mode, ReaderGestureMode.pageDrag);
      c.onPointerDown(2, const Offset(250, 300));
      expect(c.mode, ReaderGestureMode.imageScaling);
      expect(c.owner, ReaderGestureOwner.imageScale);
      expect(c.locksPageView, isTrue);
    });

    test('双指结束 → 状态正确恢复', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(1, const Offset(140, 300));
      c.onPointerMove(2, const Offset(270, 300));
      c.onPointerUp(2, const Offset(270, 300));
      c.onPointerUp(1, const Offset(140, 300));
      expect(c.mode, ReaderGestureMode.idle);
      expect(c.activePointerCount, 0);
    });

    test('已放大单指 → imagePanning', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(2, const Offset(320, 300));
      expect(c.isZoomed, isTrue);
      c.onPointerUp(2, const Offset(320, 300));
      c.onPointerUp(1, const Offset(150, 300));
      expect(c.isZoomed, isTrue);
      c.onPointerDown(3, const Offset(180, 320));
      expect(c.mode, ReaderGestureMode.imagePanning);
      expect(c.locksPageView, isTrue);
    });

    test('缩回 1.0，当前手势结束后 → 恢复页面拖动', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(2, const Offset(320, 300));
      expect(c.isZoomed, isTrue);
      // 捏合回缩
      c.onPointerMove(2, const Offset(250, 300));
      c.onPointerUp(2, const Offset(250, 300));
      // 仍有一指时保持锁定
      expect(c.locksPageView, isTrue);
      c.onPointerUp(1, const Offset(150, 300));
      expect(c.isZoomed, isFalse);
      expect(c.locksPageView, isFalse);

      c.onPointerDown(3, const Offset(200, 300));
      c.onPointerMove(3, const Offset(120, 300));
      expect(c.mode, ReaderGestureMode.pageDrag);
      expect(c.locksPageView, isFalse);
    });

    test('pointerCancel → idle', () {
      c.onPointerDown(1, const Offset(200, 300));
      c.onPointerCancel(1);
      expect(c.mode, ReaderGestureMode.idle);
      expect(c.activePointerCount, 0);
    });

    test('dispose → 不接受后续事件', () {
      c.dispose();
      c.onPointerDown(1, const Offset(200, 300));
      expect(c.mode, ReaderGestureMode.disposed);
      expect(c.activePointerCount, 0);
    });

    test('双击放大和缩回', () {
      expect(c.onDoubleTap(const Offset(180, 240)), isTrue);
      expect(c.isZoomed, isTrue);
      expect(c.transform.scale, closeTo(kReaderDoubleTapScale, 0.01));
      expect(c.onDoubleTap(const Offset(180, 240)), isTrue);
      expect(c.isZoomed, isFalse);
      expect(c.locksPageView, isFalse);
    });

    test('多次快速 pointerDown/Up 不残留锁', () {
      for (var i = 0; i < 8; i++) {
        c.onPointerDown(i, Offset(100.0 + i, 200));
        c.onPointerUp(i, Offset(100.0 + i, 200));
      }
      expect(c.mode, ReaderGestureMode.idle);
      expect(c.locksPageView, isFalse);
      expect(c.activePointerCount, 0);
    });

    test('第一指抬起、第二指仍在时不错误恢复 PageView', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(2, const Offset(300, 300));
      expect(c.isZoomed, isTrue);
      c.onPointerUp(1, const Offset(150, 300));
      expect(c.activePointerCount, 1);
      expect(c.locksPageView, isTrue);
      expect(c.mode, ReaderGestureMode.imagePanning);
    });

    test('第二指先抬起的情况', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(2, const Offset(300, 300));
      c.onPointerUp(2, const Offset(300, 300));
      expect(c.activePointerCount, 1);
      expect(c.locksPageView, isTrue);
      c.onPointerUp(1, const Offset(150, 300));
      expect(c.mode, ReaderGestureMode.idle);
    });

    test('阅读模式改变时重置', () {
      c.onPointerDown(1, const Offset(150, 300));
      c.onPointerDown(2, const Offset(250, 300));
      c.onPointerMove(2, const Offset(300, 300));
      expect(c.isZoomed, isTrue);
      c.onReadingModeChanged();
      expect(c.mode, ReaderGestureMode.idle);
      expect(c.isZoomed, isFalse);
      expect(c.locksPageView, isFalse);
      expect(c.activePointerCount, 0);
    });
  });
}
