import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Debug-only：将完整 ReaderGesture JSON 写入 JSONL，避免 logcat 行长截断。
class ReaderGestureJsonlWriter {
  ReaderGestureJsonlWriter._();

  static final ReaderGestureJsonlWriter instance = ReaderGestureJsonlWriter._();

  static const _subdir = 'reader_gesture_diag';
  static const _fileName = 'events.jsonl';

  File? _file;
  String? _testRunId;
  Future<void> _chain = Future.value();

  /// run-as 导出路径提示（相对 app_flutter）。
  static String get adbRelativePath => 'app_flutter/$_subdir/$_fileName';

  bool get isActive => kDebugMode && _file != null;

  String? get currentPath => _file?.path;

  String? get testRunId => _testRunId;

  @visibleForTesting
  Directory? overrideDirectory;

  Future<void> startRun({String? testRunId}) async {
    if (!kDebugMode) return;
    await flush();
    _testRunId = testRunId ?? DateTime.now().toUtc().toIso8601String();
    Directory diagDir;
    if (overrideDirectory != null) {
      diagDir = Directory('${overrideDirectory!.path}/$_subdir');
    } else {
      try {
        final dir = await getApplicationDocumentsDirectory();
        diagDir = Directory('${dir.path}/$_subdir');
      } catch (_) {
        diagDir = Directory('${Directory.systemTemp.path}/$_subdir');
      }
    }
    if (!await diagDir.exists()) {
      await diagDir.create(recursive: true);
    }
    _file = File('${diagDir.path}/$_fileName');
    // 新测试运行覆盖旧文件，避免无限累积。
    await _file!.writeAsString('', flush: true);
    writePayload({
      'event': 'jsonlRunStarted',
      'testRunId': _testRunId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'pathHint': adbRelativePath,
    });
    await flush();
  }

  void writePayload(Map<String, dynamic> payload) {
    if (!kDebugMode || _file == null) return;
    if (_testRunId != null && payload['testRunId'] == null) {
      payload['testRunId'] = _testRunId;
    }
    final line = '${jsonEncode(payload)}\n';
    final file = _file!;
    _chain = _chain.then(
      (_) => file.writeAsString(line, mode: FileMode.append),
    );
  }

  Future<void> flush() async {
    await _chain;
  }

  Future<void> dispose() async {
    if (!kDebugMode) return;
    if (_file != null) {
      writePayload({
        'event': 'jsonlRunEnded',
        'testRunId': _testRunId,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
      await flush();
    }
    _file = null;
    _testRunId = null;
  }
}
