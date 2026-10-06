import 'dart:async';

import 'package:flutter/material.dart';

import '../api/manga_source.dart';
import '../api/models.dart';
import '../downloader.dart';
import 'browse_detail_state.dart';
import 'browse_paging.dart';
import 'browse_source.dart';
import 'native_chapter_downloader.dart';
import 'native_reader_launcher.dart';
import 'widgets.dart';

/// 漫画详情：封面 / 标题 / 作者 / 地区 · 状态 / 题材 / 简介 + 章节列表。
///
/// 详情与章节是两次请求，各自独立加载：详情失败时整页给重试，
/// 章节失败只在章节区给重试，不连坐已经显示出来的详情。
class BrowseDetailPage extends StatefulWidget {
  const BrowseDetailPage({
    super.key,
    required this.comicId,
    this.source,
    this.summary,
  });

  /// 作品 path_word。
  final String comicId;

  /// 测试注入；为空时走 [BrowseSource.instance]。
  final MangaSource? source;

  /// 列表页已经拿到的摘要，用于先渲染标题骨架，减少空白等待。
  final MangaSummary? summary;

  /// 入口：压入路由。
  static Future<void> open(
    BuildContext context, {
    required String comicId,
    MangaSource? source,
    MangaSummary? summary,
  }) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BrowseDetailPage(
            comicId: comicId,
            source: source,
            summary: summary,
          ),
        ),
      );

  @override
  State<BrowseDetailPage> createState() => _BrowseDetailPageState();
}

class _BrowseDetailPageState extends State<BrowseDetailPage> {
  /// 详情与章节分开管理，各自有自己的加载/空/失败状态。
  late final DetailLoader _detail = DetailLoader(comicId: widget.comicId);
  late ChapterLoader _chapters;

  /// 章节是否正序（false 时倒序，最新的在最上面）。
  bool _ascending = false;

  final Set<String> _opening = <String>{};

  /// 正在下载的章节：uuid → (已完成, 总数)。有值即表示该行锁定，不可重复点。
  final Map<String, ({int done, int total})> _downloading = <String, ({int done, int total})>{};

  /// 已按下取消的章节 uuid：[NativeChapterDownloader.download] 通过
  /// `isCancelled` 读到 true 后会尽快收尾并返回 false（不会写 `.done`）。
  /// 下载真正返回后清掉，让该章可以重新下载。
  final Set<String> _cancelled = <String>{};

  /// 已下载完成的章节 uuid（下载成功后立即记下，避免再查一次磁盘）。
  final Set<String> _downloaded = <String>{};

  /// 已经问过磁盘的章节 uuid；问过就不再问，失败也只问一次。
  final Set<String> _probed = <String>{};
  bool _probing = false;

  /// 下载用的漫画名：优先详情标题，其次列表页摘要。
  String get _comicName =>
      _detail.value.detail?.title ?? widget.summary?.title ?? '';

  @override
  void initState() {
    super.initState();
    _chapters = ChapterLoader(comicId: widget.comicId);
    // 章节或详情任一到位，就去核一次已下载标记（标题没到时查不出目录，会自己跳过）。
    _chapters.addListener(_maybeRefreshMarks);
    _detail.addListener(_maybeRefreshMarks);
    _resolveSource();
  }

  void _maybeRefreshMarks() {
    if (_chapters.value.chapters.isNotEmpty && _comicName.isNotEmpty) {
      unawaited(_refreshDownloadedMarks());
    }
  }

  void _resolveSource() {
    final injected = widget.source;
    if (injected != null) {
      _attach(injected);
      return;
    }
    unawaited(
      BrowseSource.instance().then((v) {
        if (!mounted) return;
        _attach(v.source);
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _sourceError = e);
      }),
    );
  }

  Object? _sourceError;

  void _attach(MangaSource source) {
    if (!mounted) return;
    setState(() => _sourceError = null);
    _detail.attach(source);
    _chapters.attach(source);
    unawaited(_detail.load());
    unawaited(_chapters.load());
  }

  @override
  void dispose() {
    _detail.dispose();
    _chapters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final err = _sourceError;
    final hasDetail = _detail.value.detail != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(hasDetail ? _detail.value.detail!.title : '漫画详情'),
        actions: [
          IconButton(
            tooltip: _ascending ? '当前：正序' : '当前：倒序',
            icon: Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward),
            onPressed: () => setState(() => _ascending = !_ascending),
          ),
        ],
      ),
      body: err != null && !hasDetail
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 40, color: scheme.error),
                    const SizedBox(height: 12),
                    const Text('线路不可用'),
                    const SizedBox(height: 14),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() => _sourceError = null);
                        _resolveSource();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : ValueListenableBuilder<DetailState>(
              valueListenable: _detail,
              builder: (context, detailState, _) {
                final d = detailState.detail;
                final fallback = widget.summary;
                // 详情还没到，但有摘要：先渲染头部骨架，详情区仍显示加载中。
                final loading = d == null && !detailState.loadedOnce;
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: _Header(
                        detail: d,
                        summary: fallback,
                        status: loading
                            ? BrowseStatus.loading
                            : (d == null
                                  ? BrowseStatus.error
                                  : BrowseStatus.ready),
                        error: detailState.error,
                        onRetry: () => unawaited(_detail.load()),
                      ),
                    ),
                    if (d != null)
                      SliverToBoxAdapter(child: _IntroSection(detail: d)),
                    if (d != null && d.genres.isNotEmpty)
                      SliverToBoxAdapter(child: _Genres(genres: d.genres)),
                    const SliverToBoxAdapter(child: Divider(height: 1)),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                        child: Row(
                          children: [
                            Text(
                              '章节',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${_chapters.value.chapters.length}',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ..._chapterSectionSlivers(context),
                    const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  ],
                );
              },
            ),
    );
  }

  /// 章节区：加载中 / 空 / 失败（重试）/ 一章一行的懒加载列表。
  List<Widget> _chapterSectionSlivers(BuildContext context) {
    return [
      ValueListenableBuilder<ChapterState>(
        valueListenable: _chapters,
        builder: (context, s, _) {
          final items = _ascending
              ? s.chapters
              : s.chapters.reversed.toList(growable: false);
          final status = s.loading && items.isEmpty
              ? BrowseStatus.loading
              : (items.isEmpty
                    ? (s.error != null ? BrowseStatus.error : BrowseStatus.empty)
                    : BrowseStatus.ready);
          if (status != BrowseStatus.ready) {
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              sliver: SliverToBoxAdapter(
                child: BrowseStateView(
                  status: status,
                  error: s.error,
                  onRetry: _reloadChapters,
                  emptyIcon: Icons.auto_stories_outlined,
                  emptyText: '这部漫画还没有章节',
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: const SizedBox.shrink(),
                ),
              ),
            );
          }
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            sliver: SliverFixedExtentList(
              itemExtent: _chapterRowHeight,
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final c = items[i];
                  return _ChapterRow(
                    chapter: c,
                    opening: _opening.contains(c.id),
                    progress: _downloading[c.id],
                    downloaded: _downloaded.contains(c.id),
                    cancelling: _cancelled.contains(c.id),
                    onTap: () => unawaited(_openChapter(c)),
                    onDownload: () => unawaited(_downloadChapter(c)),
                    onCancel: () => _cancelDownload(c),
                  );
                },
                childCount: items.length,
              ),
            ),
          );
        },
      ),
    ];
  }

  /// 重新拉取章节，顺带刷新已下载标记。
  void _reloadChapters() {
    unawaited(_chapters.load().then((_) => _refreshDownloadedMarks()));
  }

  /// 点章节：交给阅读器启动器，这里不实现阅读器。
  Future<void> _openChapter(Chapter c) async {
    if (_opening.contains(c.id)) return;
    setState(() => _opening.add(c.id));
    try {
      await NativeReaderLauncher.open(
        context,
        comicId: widget.comicId,
        chapterUuid: c.id,
      );
    } finally {
      if (mounted) setState(() => _opening.remove(c.id));
    }
  }

  /// 下载某一章；期间该行锁定，避免重复点。可中途取消。
  Future<void> _downloadChapter(Chapter c) async {
    if (_downloading.containsKey(c.id)) return;
    final comicName = _comicName;
    if (comicName.isEmpty) {
      _toast('详情还没加载完，稍后再试');
      return;
    }
    setState(() => _downloading[c.id] = (done: 0, total: 0));
    var ok = false;
    try {
      ok = await NativeChapterDownloader.download(
        comicId: widget.comicId,
        chapterUuid: c.id,
        comicName: comicName,
        chapterName: c.name,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _downloading[c.id] = (done: done, total: total));
        },
        isCancelled: () => _cancelled.contains(c.id),
      );
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    // 取消时 download 同样返回 false，这里靠自己的标记区分，避免弹成「下载失败」。
    final wasCancelled = _cancelled.remove(c.id);
    setState(() {
      _downloading.remove(c.id);
      _probed.add(c.id);
      if (ok) {
        _downloaded.add(c.id);
      } else {
        _downloaded.remove(c.id);
      }
    });
    if (ok) {
      _toast('本章下载完成');
    } else if (wasCancelled) {
      // 取消不是失败，可以再点一次重新下；已下过的页会断点续传。
      _toast('已取消下载');
    } else {
      _toast('下载失败');
    }
  }

  /// 该章正在下载 → 记下取消意图，下载会尽快中断；行上按钮同时变回「下载」。
  void _cancelDownload(Chapter c) {
    if (!_downloading.containsKey(c.id)) return;
    setState(() => _cancelled.add(c.id));
  }

  /// 逐章问一次磁盘：已下载的打勾。只问没问过的，结果记在 [_probed]/[_downloaded]。
  Future<void> _refreshDownloadedMarks() async {
    final name = _comicName;
    if (name.isEmpty || _probing) return;
    _probing = true;
    try {
      final hit = <String>[];
      for (final c in _chapters.value.chapters) {
        if (_probed.contains(c.id)) continue;
        var ok = false;
        try {
          ok = await Downloader.isChapterDownloaded(name, _chapterFolder(c.id));
        } catch (_) {
          ok = false; // 磁盘/插件不可用时不打勾，也不再重复问。
        }
        _probed.add(c.id);
        if (ok) hit.add(c.id);
      }
      if (!mounted || hit.isEmpty) return;
      setState(() => _downloaded.addAll(hit));
    } finally {
      _probing = false;
    }
  }

  /// 章节落盘目录名，与 [NativeChapterDownloader] 保持一致。
  static String _chapterFolder(String uuid) =>
      '章节_${uuid.length >= 8 ? uuid.substring(0, 8) : uuid}';

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }
}

/// 一行一章的行高，列表用它做懒加载与等高分片。
const double _chapterRowHeight = 56;

/// 头部：封面 + 右侧元信息。
class _Header extends StatelessWidget {
  const _Header({
    required this.detail,
    this.summary,
    required this.status,
    this.error,
    required this.onRetry,
  });

  final MangaDetail? detail;
  final MangaSummary? summary;
  final BrowseStatus status;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cover = detail?.cover ?? summary?.cover ?? '';
    final title = detail?.title ?? summary?.title ?? '';
    final author = detail?.author ?? summary?.author ?? '';

    if (status == BrowseStatus.error) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: BrowseStateView(
          status: status,
          error: error,
          onRetry: onRetry,
          emptyText: '没有这部漫画',
          child: const SizedBox.shrink(),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 108,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: MangaCover(
              url: cover,
              iconSize: 30,
              placeholder: cover.isEmpty ? '暂无封面' : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.3,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                if (status == BrowseStatus.loading) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ] else ...[
                  if (author.isNotEmpty)
                    _MetaLine(icon: Icons.person_outline, text: author),
                  if (detail?.region.isNotEmpty ?? false)
                    _MetaLine(icon: Icons.public, text: detail!.region),
                  if (detail?.status.isNotEmpty ?? false)
                    _MetaLine(
                      icon: Icons.schedule_outlined,
                      text: detail!.status,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 简介：默认收起到 4 行，点「展开」看全文。
class _IntroSection extends StatelessWidget {
  const _IntroSection({required this.detail});

  final MangaDetail detail;

  static const int _maxLines = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = detail.description.trim();
    if (text.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text(
          '这部漫画还没有简介',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: _ExpandableText(
        key: ValueKey<String>('intro-${detail.id}'),
        text: text,
        maxLines: _maxLines,
        style: TextStyle(
          fontSize: 13,
          height: 1.55,
          color: scheme.onSurface.withValues(alpha: 0.88),
        ),
      ),
    );
  }
}

/// 可展开文本：超出 [maxLines] 时显示「展开 / 收起」。
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({
    super.key,
    required this.text,
    required this.maxLines,
    required this.style,
  });

  final String text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded ? null : widget.maxLines,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              foregroundColor: scheme.primary,
            ),
            child: Text(_expanded ? '收起' : '展开'),
          ),
        ),
      ],
    );
  }
}

/// 题材标签。
class _Genres extends StatelessWidget {
  const _Genres({required this.genres});

  final List<String> genres;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: genres
            .map(
              (g) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  g,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

/// 章节行：整行点开阅读器，右侧一个下载按钮（下载中显示进度且锁定）。
class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.onTap,
    required this.onDownload,
    required this.onCancel,
    this.opening = false,
    this.progress,
    this.downloaded = false,
    this.cancelling = false,
  });

  final Chapter chapter;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  /// 正在打开阅读器：整行禁用，避免连点开多个。
  final bool opening;

  /// 下载进度 (已完成, 总数)；非 null 即下载中，按钮变成取消。
  final ({int done, int total})? progress;

  /// 已下载过：按钮位置显示对勾。
  final bool downloaded;

  /// 已按下取消，正在等下载收尾：按钮禁用，避免又起一个下载。
  final bool cancelling;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = progress;
    final name = chapter.name.isEmpty ? '第 ${chapter.index + 1} 话' : chapter.name;
    final downloading = p != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: opening ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              if (opening)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                Icon(
                  Icons.menu_book_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 14,
                        color: opening
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (chapter.size > 0 && !downloading)
                      Text(
                        '${chapter.size} 页',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (downloading)
                      Text(
                        cancelling
                            ? '正在取消…'
                            : (p.total > 0
                                  ? '下载中 ${p.done}/${p.total}'
                                  : '准备中…'),
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: cancelling ? scheme.onSurfaceVariant : scheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _DownloadButton(
                downloading: downloading,
                downloaded: downloaded,
                cancelling: cancelling,
                progress: p,
                onDownload: onDownload,
                onCancel: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行右侧按钮：待下载是下载图标，下载中变成取消，已下载是对勾。
///
/// 进度百分比显示在行里（"下载中 3/21"），按钮位置留给操作，
/// 这样下载中也能立刻点掉，不用等它跑完。
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.downloading,
    required this.downloaded,
    required this.cancelling,
    required this.onDownload,
    required this.onCancel,
    this.progress,
  });

  final bool downloading;
  final bool downloaded;

  /// 已按下取消、等下载收尾：按钮禁用，避免又起一个下载。
  final bool cancelling;

  final VoidCallback onDownload;

  /// 取消下载；只有在 [downloading] 时才有意义。
  final VoidCallback onCancel;

  /// 下载进度，用于在取消按钮底下画一圈细进度环。
  final ({int done, int total})? progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (downloaded && !downloading) {
      return Icon(Icons.check_circle, size: 22, color: scheme.primary);
    }
    if (downloading) {
      // 取消按钮底下压一圈细进度环：既看得到进度，又随时能点掉。
      final p = progress;
      final value =
          p != null && p.total > 0 ? (p.done / p.total).clamp(0.0, 1.0) : null;
      return Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 1.6,
              color: cancelling ? scheme.outlineVariant : scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
          IconButton(
            tooltip: cancelling ? '正在取消…' : '取消下载',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            // 收尾期间才禁用，避免又起一个下载。
            onPressed: cancelling ? null : onCancel,
            icon: Icon(
              Icons.close,
              color: cancelling ? scheme.onSurfaceVariant : scheme.error,
            ),
          ),
        ],
      );
    }
    return IconButton(
      tooltip: '下载本章',
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      icon: Icon(Icons.download_outlined, color: scheme.onSurfaceVariant),
      onPressed: onDownload,
    );
  }
}
