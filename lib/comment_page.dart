import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'api/comment_repository.dart';
import 'api/models.dart';

/// 阅读器中的章末吐槽虚拟页。
///
/// 页面本身可滚动；本章吐槽与漫画总评分别维护加载、空和失败状态，
/// 任一请求失败都不会影响另一区块。
class CommentPage extends StatefulWidget {
  const CommentPage({
    super.key,
    required this.chapterId,
    required this.comicId,
  });

  /// 章节 uuid，用于读取本章吐槽。
  final String chapterId;

  /// 漫画 path_word；为空时不显示总评。
  final String comicId;

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  final CommentRepository _repository = CommentRepository();
  Future<void>? _repositoryReady;

  Future<void> _ensureRepositoryReady() async {
    final ready = _repositoryReady ??= _repository.ensureReady();
    try {
      await ready;
    } catch (_) {
      // 失败的初始化不能被永久缓存，之后可由任一区块独立重试。
      if (identical(_repositoryReady, ready)) _repositoryReady = null;
      rethrow;
    }
  }

  Future<List<Comment>> _loadChapterComments(String chapterId) async {
    if (chapterId.isEmpty) return const [];
    await _ensureRepositoryReady();
    return _repository.chapterComments(chapterId);
  }

  Future<List<Comment>> _loadComicComments(String comicId) async {
    if (comicId.isEmpty) return const [];
    await _ensureRepositoryReady();
    return _repository.comicComments(comicId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        child: CustomScrollView(
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 22, 16, 32),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '章末吐槽',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '看看大家读完这一章后说了什么',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _CommentSection(
                          key: const ValueKey('chapter-comments'),
                          title: '本章吐槽',
                          requestKey: widget.chapterId,
                          loader: () => _loadChapterComments(widget.chapterId),
                        ),
                        if (widget.comicId.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          _CommentSection(
                            key: const ValueKey('comic-comments'),
                            title: '总评',
                            requestKey: widget.comicId,
                            loader: () => _loadComicComments(widget.comicId),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentSection extends StatefulWidget {
  const _CommentSection({
    super.key,
    required this.title,
    required this.requestKey,
    required this.loader,
  });

  final String title;
  final String requestKey;
  final Future<List<Comment>> Function() loader;

  @override
  State<_CommentSection> createState() => _CommentSectionState();
}

class _CommentSectionState extends State<_CommentSection> {
  List<Comment>? _comments;
  bool _failed = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _CommentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestKey == oldWidget.requestKey) return;
    _comments = null;
    _failed = false;
    unawaited(_load());
  }

  Future<void> _load() async {
    final serial = ++_requestSerial;
    try {
      final comments = await widget.loader();
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _comments = comments;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _comments = null;
        _failed = true;
      });
    }
  }

  void _retry() {
    setState(() {
      _comments = null;
      _failed = false;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Text(
                widget.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(height: 1, color: colorScheme.outlineVariant),
            _buildBody(context),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_failed) return _ErrorState(onRetry: _retry);

    final comments = _comments;
    if (comments == null) return const _LoadingState();
    if (comments.isEmpty) return const _EmptyState();

    return Column(
      children: [
        for (var index = 0; index < comments.length; index++) ...[
          _CommentTile(comment: comments[index]),
          if (index != comments.length - 1)
            const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(width: 12),
          Text(
            '加载中…',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      child: Column(
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 28,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 10),
          Text(
            '还没有吐槽',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 28,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 10),
          Text(
            '加载失败，请检查网络后重试',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = comment.user.trim().isEmpty ? '匿名' : comment.user;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  user,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (comment.createdAt.isNotEmpty) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    comment.createdAt,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text(comment.content, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
