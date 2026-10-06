import 'dart:io';

import 'package:flutter/material.dart';

import 'chapter_data.dart';
import 'downloader.dart';
import 'reader_page.dart';

/// 我的下载：漫画 → 章节两级浏览，离线阅读支持上下章。
/// 对应原生版 DlListActivity。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<Directory> _comics = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await Downloader.listComics();
    if (mounted) {
      setState(() {
        _comics = list;
        _loading = false;
      });
    }
  }

  Future<void> _delete(Directory dir) async {
    final name = dir.path.split(Platform.pathSeparator).last;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除漫画'),
        content: Text('删除「$name」的全部下载？该操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await dir.delete(recursive: true);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的下载')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _comics.isEmpty
          ? const Center(
              child: Text(
                '还没有下载的漫画\n在漫画详情页点右下角下载按钮批量下载',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: _comics.length,
              itemBuilder: (context, i) {
                final dir = _comics[i];
                final name = dir.path.split(Platform.pathSeparator).last;
                return ListTile(
                  leading: const Icon(Icons.collections_bookmark),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context)
                      .push(
                        MaterialPageRoute(
                          builder: (_) => _ChapterListPage(comicName: name),
                        ),
                      )
                      .then((_) => _refresh()),
                  onLongPress: () => _delete(dir),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(dir),
                  ),
                );
              },
            ),
    );
  }
}

/// 某漫画的已下载章节列表
class _ChapterListPage extends StatefulWidget {
  const _ChapterListPage({required this.comicName});
  final String comicName;

  @override
  State<_ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<_ChapterListPage> {
  List<Directory> _chapters = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await Downloader.listChapters(widget.comicName);
    if (mounted) {
      setState(() {
        _chapters = list;
        _loading = false;
      });
    }
  }

  /// 打开离线阅读器；离线上下章通过 `local://<index>` 伪 URL 原地切换
  Future<void> _open(int index) async {
    final data = await Downloader.loadLocal(
      _chapters[index],
      chapterDirs: _chapters,
    );
    if (data == null || !mounted) return;
    final notifier = ValueNotifier<ChapterData>(data);
    var readerClosed = false;
    Future<void> switchTo(String url) async {
      if (!url.startsWith('local://')) return;
      final idx = int.tryParse(url.substring('local://'.length));
      if (idx == null || idx < 0 || idx >= _chapters.length) return;
      // 用当前章的 previousChapterUrl 判断方向，避免目录名前缀歧义（如“第1话”/“第10话”）
      final goingBack = url == notifier.value.previousChapterUrl;
      final next = await Downloader.loadLocal(
        _chapters[idx],
        chapterDirs: _chapters,
        initialPage: goingBack ? -2 : 0,
      );
      // 阅读器可能在 loadLocal 期间被关闭，notifier 已 dispose
      if (next != null && !readerClosed) notifier.value = next;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          dataNotifier: notifier,
          loadingText: ValueNotifier<String?>(null),
          onRequestChapter:
              (
                url, {
                goNext,
                chapterRequestId,
                readerInstanceId,
                inputSource,
                triggeringGestureSessionId,
              }) => switchTo(url),
        ),
      ),
    );
    readerClosed = true;
    notifier.dispose();
  }

  Future<void> _delete(Directory dir) async {
    final name = dir.path.split(Platform.pathSeparator).last;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('删除「$name」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await dir.delete(recursive: true);
      await _refresh();
    }
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _chapters.length,
              itemBuilder: (context, i) {
                final name = _chapters[i].path
                    .split(Platform.pathSeparator)
                    .last;
                return ListTile(
                  leading: const Icon(Icons.menu_book),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _open(i),
                  onLongPress: () => _delete(_chapters[i]),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(_chapters[i]),
                  ),
                );
              },
            ),
    );
  }
}
