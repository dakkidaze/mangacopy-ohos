import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_page.dart' show pcUserAgent;
import 'chapter_data.dart';
import 'downloader.dart';
import 'settings.dart';
import 'url_manager.dart';

/// 批量下载页：分组章节多选 → 逐章收图 → 并发下载。
/// 对应原生版 DlActivity，自带一个专用隐藏收图 WebView（页面存活期间有效，
/// 离开页面即停止下载，与原生版 onDestroy 行为一致）。
class DownloadSelectPage extends StatefulWidget {
  const DownloadSelectPage({
    super.key,
    required this.comicName,
    required this.groups,
  });

  final String comicName;
  final List<ComicGroup> groups;

  @override
  State<DownloadSelectPage> createState() => _DownloadSelectPageState();
}

class _DownloadSelectPageState extends State<DownloadSelectPage> {
  InAppWebViewController? _webController;
  String _gmShim = '';
  String _hJs = '';

  final Set<String> _selected = {}; // chapter url
  final Map<String, bool> _downloaded = {}; // chapter name -> exists
  bool _running = false;
  bool _cancelRequested = false;
  String _status = '';
  double _progress = 0;

  Completer<ChapterData>? _collectCompleter;
  DateTime _lastProgressAt = DateTime.now();

  int get _totalChapters =>
      widget.groups.fold(0, (s, g) => s + g.chapters.length);

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    // 立即打断收图等待与下载循环，避免定时器/HTTP 在页面销毁后继续跑
    _cancelRequested = true;
    if (_collectCompleter?.isCompleted == false) {
      _collectCompleter!.completeError(StateError('页面已关闭'));
    }
    super.dispose();
  }

  Future<void> _init() async {
    String strip(String s) =>
        s.startsWith('javascript:') ? s.substring('javascript:'.length) : s;
    _gmShim = await rootBundle.loadString('assets/js/gm_shim.js');
    _hJs = strip(await rootBundle.loadString('assets/js/h.js'));
    await Downloader.saveComicMeta(widget.comicName, widget.groups);
    await _refreshDownloadedMarks();
  }

  Future<void> _refreshDownloadedMarks() async {
    for (final g in widget.groups) {
      for (final c in g.chapters) {
        _downloaded[c.name] = await Downloader.isChapterDownloaded(
          widget.comicName,
          c.name,
        );
      }
    }
    if (mounted) setState(() {});
  }

  // ---- 收图（专用 WebView，串行）----

  Future<ChapterData> _collectChapter(String pcUrl) {
    final completer = Completer<ChapterData>();
    _collectCompleter = completer;
    _lastProgressAt = DateTime.now();
    _webController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(UrlManager.rehost(pcUrl))),
    );
    // 停滞守护：90 秒无进度判失败
    Timer.periodic(const Duration(seconds: 5), (t) {
      if (completer.isCompleted) {
        t.cancel();
        return;
      }
      if (DateTime.now().difference(_lastProgressAt).inSeconds >= 90) {
        t.cancel();
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('收图停滞'));
        }
      }
    });
    return completer.future;
  }

  void _registerHandlers(InAppWebViewController c) {
    c.addJavaScriptHandler(
      handlerName: 'loadChapter',
      callback: (args) {
        if (args.isEmpty) return;
        final data = ChapterData.parse(args[0] as String);
        if (data != null &&
            data.imgUrls.isNotEmpty &&
            _collectCompleter?.isCompleted == false) {
          _collectCompleter!.complete(data);
        }
      },
    );
    c.addJavaScriptHandler(handlerName: 'setTitle', callback: (_) {});
    c.addJavaScriptHandler(handlerName: 'setFab', callback: (_) {});
    c.addJavaScriptHandler(handlerName: 'setLoadingDialog', callback: (_) {});
    c.addJavaScriptHandler(
      handlerName: 'setLoadingDialogProgress',
      callback: (args) {
        _lastProgressAt = DateTime.now();
        if (args.length >= 2 && mounted && _running) {
          setState(() => _status = '$_currentName 收图 ${args[0]}/${args[1]}');
        }
      },
    );
  }

  // ---- 下载流水线 ----

  String _currentName = '';

  Future<void> _startDownload() async {
    if (_running) {
      // 再点一次 = 请求取消
      setState(() {
        _cancelRequested = true;
        _status = '正在取消…';
      });
      return;
    }
    final tasks = <ComicChapter>[];
    for (final g in widget.groups) {
      for (final c in g.chapters) {
        if (_selected.contains(c.url)) tasks.add(c);
      }
    }
    if (tasks.isEmpty) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = 0;
    });
    var doneChapters = 0;
    var failed = 0;
    for (final c in tasks) {
      if (_cancelRequested || !mounted) break;
      _currentName = c.name;
      setState(() => _status = '${c.name} 收图中…');
      try {
        final data = await _collectChapter(c.url);
        if (_cancelRequested || !mounted) break;
        setState(() => _status = '${c.name} 下载中…');
        final ids = Downloader.parseComicAndUuid(c.url);
        final ok = await Downloader.downloadImages(
          widget.comicName,
          c.name,
          data.imgUrls,
          (done, total) {
            if (mounted) {
              setState(() {
                _status = '${c.name} 下载 $done/$total';
                _progress = (doneChapters + done / total) / tasks.length;
              });
            }
          },
          isCancelled: () => _cancelRequested,
          chapterUuid: ids?.uuid,
          comicId: ids?.comicId,
          displayName: c.name,
        );
        if (_cancelRequested || !mounted) break;
        if (!ok) {
          failed++;
        } else {
          _downloaded[c.name] = true;
          _selected.remove(c.url);
        }
      } catch (_) {
        if (_cancelRequested || !mounted) break;
        failed++;
      }
      doneChapters++;
      if (mounted) setState(() => _progress = doneChapters / tasks.length);
    }
    if (mounted) {
      setState(() {
        _running = false;
        _status = _cancelRequested
            ? '已取消（已完成 $doneChapters 章）'
            : '下载完成：$doneChapters 章${failed > 0 ? '，$failed 章有失败' : ''}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_status), duration: const Duration(seconds: 3)),
      );
    }
  }

  void _selectAllUndownloaded() {
    setState(() {
      var changed = false;
      for (final g in widget.groups) {
        for (final c in g.chapters) {
          if (_downloaded[c.name] != true && !_selected.contains(c.url)) {
            _selected.add(c.url);
            changed = true;
          }
        }
      }
      if (!changed) _selected.clear(); // 已全选则取消全选
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.comicName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '全选未下载',
            icon: const Icon(Icons.select_all),
            onPressed: _running ? null : _selectAllUndownloaded,
          ),
        ],
      ),
      body: Stack(
        children: [
          // 专用收图 WebView（被列表完全遮住，保持 rAF 全速）
          Positioned.fill(
            child: IgnorePointer(
              child: InAppWebView(
                initialSettings: InAppWebViewSettings(
                  userAgent: pcUserAgent,
                  javaScriptEnabled: true,
                  useShouldOverrideUrlLoading: true,
                ),
                onWebViewCreated: (c) {
                  _webController = c;
                  _registerHandlers(c);
                },
                shouldOverrideUrlLoading: (c, action) async {
                  final s = action.request.url?.toString() ?? '';
                  return s == 'about:blank' ||
                          UrlManager.allowedPrefixes.any((p) => s.startsWith(p))
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                },
                onLoadStop: (c, url) async {
                  await Future.delayed(const Duration(milliseconds: 500));
                  await c.evaluateJavascript(
                    source:
                        "window.__CM_SOURCE_PROFILE='${AppSettings.sourceProfile}';"
                        "window.__CM_ACTIVE_URL='${UrlManager.activeUrl}';",
                  );
                  await c.evaluateJavascript(source: _gmShim);
                  await c.evaluateJavascript(source: _hJs);
                },
              ),
            ),
          ),
          // 章节列表（不透明底，遮住 WebView）
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                for (final g in widget.groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      g.name,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in g.chapters)
                          FilterChip(
                            label: Text(
                              c.name,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _selected.contains(c.url),
                            showCheckmark: false,
                            backgroundColor: _downloaded[c.name] == true
                                ? Colors.green.withValues(alpha: 0.25)
                                : null,
                            onSelected: _running
                                ? null
                                : (on) {
                                    setState(() {
                                      if (on) {
                                        _selected.add(c.url);
                                      } else {
                                        _selected.remove(c.url);
                                      }
                                    });
                                  },
                          ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '共 $_totalChapters 章，绿色为已下载',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          // 底部下载条
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_status.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            _status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (_running)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: LinearProgressIndicator(value: _progress),
                        ),
                      FilledButton.icon(
                        onPressed: _selected.isEmpty && !_running
                            ? null
                            : _startDownload,
                        icon: Icon(_running ? Icons.stop : Icons.download),
                        label: Text(
                          _running ? '取消下载' : '下载选中的 ${_selected.length} 章',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
