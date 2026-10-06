import 'dart:convert';
import 'dart:io';

import 'package:copymanga_flutter/chapter_edge_guard.dart';
import 'package:copymanga_flutter/reader_gesture_debug.dart';
import 'package:copymanga_flutter/reader_gesture_jsonl.dart';
import 'package:copymanga_flutter/reader_gesture_marker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderGestureJsonlWriter', () {
    test('debug 模式下写入完整 JSON 行', () async {
      expect(kDebugMode, isTrue);
      final writer = ReaderGestureJsonlWriter.instance;
      writer.overrideDirectory = Directory.systemTemp.createTempSync(
        'rg_jsonl_',
      );
      await writer.startRun(testRunId: 'test-run-1');
      writer.writePayload({
        'event': 'unitTest',
        'gestureSessionId': 'gs-test',
        'longField': 'x' * 5000,
      });
      await writer.flush();
      final path = writer.currentPath;
      expect(path, isNotNull);
      final lines = await File(path!).readAsLines();
      expect(lines.length, greaterThanOrEqualTo(2));
      for (final line in lines) {
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
      await writer.dispose();
      writer.overrideDirectory = null;
    });
  });

  group('ReaderGestureDiagnostics 因果链', () {
    test('chapterRequestId 贯穿 load 事件', () {
      final lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('[ReaderGesture]')) {
          lines.add(message.substring('[ReaderGesture] '.length));
        }
      };

      final diag = ReaderGestureDiagnostics.instance;
      final readerId = ReaderGestureDiagnostics.newReaderInstanceId();
      diag.attachReader(readerId);
      diag.bindReaderContext(
        readerInstanceId: readerId,
        readMode: 'h',
        r2l: true,
        reverse: true,
        chapterDiagToken: 'ct-old-token',
        pageIndex: 1,
        pageCount: 10,
        hasPreviousChapter: true,
        hasNextChapter: true,
        pageZoomed: false,
        multiTouch: false,
        physicsType: 'PageScrollPhysics',
        pageControllerHasClients: true,
        pageControllerPage: 0,
        edgeGuard: ChapterEdgeGuard(),
        logicalSize: const Size(360, 720),
        devicePixelRatio: 3,
      );

      const reqId = 42;
      diag.onChapterLoadStarted(
        chapterRequestId: reqId,
        readerInstanceId: readerId,
        triggeringGestureSessionId: 'gs-edge',
        inputSource: 'touchSwipe',
      );
      diag.onChapterDiagTokenChanged(readerId, 'ct-new-token');
      diag.onChapterLoadSucceeded(
        chapterRequestId: reqId,
        readerInstanceId: readerId,
        newChapterDiagToken: 'ct-new-token',
      );
      diag.detachReader(readerId);

      final started =
          jsonDecode(
                lines.firstWhere((l) {
                  final m = jsonDecode(l) as Map<String, dynamic>;
                  return m['event'] == 'chapterLoadStarted';
                }),
              )
              as Map<String, dynamic>;
      final succeeded =
          jsonDecode(
                lines.firstWhere((l) {
                  final m = jsonDecode(l) as Map<String, dynamic>;
                  return m['event'] == 'chapterLoadSucceeded';
                }),
              )
              as Map<String, dynamic>;

      expect(started['chapterRequestId'], reqId);
      expect(started['previousChapterDiagToken'], 'ct-old-token');
      expect(succeeded['chapterRequestId'], reqId);
      expect(succeeded['previousChapterDiagToken'], 'ct-old-token');
      expect(succeeded['newChapterDiagToken'], 'ct-new-token');
    });
  });

  group('testActionMarker', () {
    test('marker 不改变手势状态', () {
      final lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('[ReaderGesture]')) {
          lines.add(message);
        }
      };

      final diag = ReaderGestureDiagnostics.instance;
      final readerId = ReaderGestureDiagnostics.newReaderInstanceId();
      diag.attachReader(readerId);

      ReaderGestureMarkerBridge.injectForTest({
        'phase': 'started',
        'testRunId': 'run-marker',
        'scenarioId': 'E-B',
        'actionId': 'B03',
        'actionPhase': 'singleSwipe',
        'timestamp': '2026-08-04T10:00:00.000Z',
      });

      expect(lines.any((l) => l.contains('testActionStarted')), isTrue);
      diag.detachReader(readerId);
    });
  });
}
