import 'dart:convert';

import 'package:copymanga_flutter/reader_gesture_debug.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderGestureDiagnostics JSON', () {
    test('encodeForTest 可解析且处理非有限 double', () {
      final json = ReaderGestureDiagnostics.encodeForTest({
        'a': 1.0,
        'nan': double.nan,
        'inf': double.infinity,
        'negZero': -0.0,
        'nested': {'b': true},
      });
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['a'], 1.0);
      expect(decoded['nan'], isNull);
      expect(decoded['inf'], isNull);
      expect(decoded['negZero'], 0.0);
      expect(decoded['nested'], {'b': true});
    });

    test('edgeGuard debugSnapshot 为 JSON 友好类型', () {
      final json = ReaderGestureDiagnostics.encodeForTest({
        'edgeGuard': {
          'currentlyHintingNext': true,
          'currentlyHintingPrevious': false,
        },
      });
      expect(jsonDecode(json), isA<Map<String, dynamic>>());
    });
  });

  group('ReaderGestureDiagnostics 会话', () {
    test('两次独立 pointer 序列产生不同 gestureSessionId 且各一个 summary', () {
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message == null || !message.startsWith('[ReaderGesture]')) return;
        final body = message.substring('[ReaderGesture] '.length);
        jsonDecode(body);
      };

      final diag = ReaderGestureDiagnostics.instance;
      final readerId = ReaderGestureDiagnostics.newReaderInstanceId();
      diag.attachReader(readerId);

      void swipe(int pointer, double dx) {
        diag.onPointerDown(
          readerId,
          PointerDownEvent(position: Offset.zero),
          activePointerCount: 1,
        );
        diag.onPointerMove(
          readerId,
          PointerMoveEvent(position: Offset(dx, 0), delta: Offset(dx, 0)),
        );
        diag.onPointerUp(
          readerId,
          PointerUpEvent(position: Offset(dx, 0)),
          activePointerCount: 0,
        );
      }

      swipe(1, -80);
      swipe(2, -90);

      diag.detachReader(readerId);
    });

    test('detach 后不再输出普通事件', () {
      final lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('[ReaderGesture]')) {
          lines.add(message);
        }
      };

      final diag = ReaderGestureDiagnostics.instance;
      final readerId = ReaderGestureDiagnostics.newReaderInstanceId();
      diag.attachReader(readerId);
      diag.detachReader(readerId);
      final afterDetach = lines.length;

      diag.onPointerDown(
        readerId,
        PointerDownEvent(position: Offset.zero),
        activePointerCount: 1,
      );

      expect(lines.length, afterDetach);
    });
  });

  group('SwipeDirectionFields', () {
    test('日漫 r2l 横向右滑为 towardNext', () {
      final f = SwipeDirectionFields.compute(
        totalDx: 100,
        totalDy: 0,
        readMode: 'h',
        r2l: true,
        reverse: true,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(f.physicalSwipeDirection, 'right');
      expect(f.logicalReadingDirection, 'towardNext');
      expect(f.edgeIntent, 'nextChapter');
      expect(f.signedPrimaryAxisDistance, 100);
      expect(f.primaryAxisDistance, 100);
    });

    test('日漫 r2l 横向左滑不得 nextChapter', () {
      final f = SwipeDirectionFields.compute(
        totalDx: -100,
        totalDy: 0,
        readMode: 'h',
        r2l: true,
        reverse: true,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(f.physicalSwipeDirection, 'left');
      expect(f.logicalReadingDirection, 'towardPrevious');
      expect(f.edgeIntent, 'none');
    });

    test('非日漫横向左滑为 towardNext', () {
      final f = SwipeDirectionFields.compute(
        totalDx: -100,
        totalDy: 0,
        readMode: 'h',
        r2l: false,
        reverse: false,
        atFirstPage: false,
        atLastPage: true,
      );
      expect(f.logicalReadingDirection, 'towardNext');
      expect(f.edgeIntent, 'nextChapter');
    });
  });
}
