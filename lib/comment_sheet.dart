import 'package:flutter/material.dart';

import 'api/comment_repository.dart';
import 'api/models.dart';

/// 打开吐槽（评论）面板。
///
/// - [chapterId]：章节 uuid，用于「章末吐槽」；为空时该页大概率是空态。
/// - [comicId]：漫画 path_word，用于「总评」；为空串时不显示「总评」页。
///
/// CommentRepository 首次请求前要先选域（可能耗时数秒），
/// 因此每个列表自带加载态；两个页签共用同一个仓库实例，选域只做一次。
Future<void> showCommentSheet(
  BuildContext context, {
  required String chapterId,
  required String comicId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) =>
        _CommentSheet(chapterId: chapterId, comicId: comicId),
  );
}

class _CommentSheet extends StatefulWidget {
  const _CommentSheet({required this.chapterId, required this.comicId});

  final String chapterId;
  final String comicId;

  @override
  State<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<_CommentSheet> {
  final CommentRepository _repo = CommentRepository();

  bool get _hasComicTab => widget.comicId.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: DefaultTabController(
        length: _hasComicTab ? 2 : 1,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _hasComicTab ? '吐槽' : '章末吐槽',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (_hasComicTab)
              const TabBar(
                tabs: [Tab(text: '章末吐槽'), Tab(text: '总评')],
              ),
            Expanded(
              child: TabBarView(
                children: [
                  _CommentList(
                    loader: () => _repo.chapterComments(widget.chapterId),
                  ),
                  if (_hasComicTab)
                    _CommentList(
                      loader: () => _repo.comicComments(widget.comicId),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个评论列表：加载态 / 空态 / 错误态（带重试）/ 列表。
class _CommentList extends StatefulWidget {
  const _CommentList({required this.loader});

  final Future<List<Comment>> Function() loader;

  @override
  State<_CommentList> createState() => _CommentListState();
}

class _CommentListState extends State<_CommentList> {
  List<Comment>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.loader();
      if (!mounted) return;
      setState(() {
        _items = items;
        _failed = false;
      });
    } catch (_) {
      // 网络异常、所有域名不可用等：统一按错误态处理，给用户重试入口
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _reload() {
    setState(() {
      _items = null;
      _failed = false;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return _buildError(context);
    final items = _items;
    if (items == null) return _buildLoading(context);
    if (items.isEmpty) return _buildEmpty(context);
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
      ),
      itemBuilder: (context, index) => _CommentTile(comment: items[index]),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            '加载中…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 36,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            '还没有吐槽',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off,
            size: 36,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            '加载失败，请检查网络后重试',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _reload,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 单条评论：用户名 + 时间一行，内容在下。
class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = comment.user.isEmpty ? '匿名' : comment.user;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (comment.createdAt.isNotEmpty)
                Text(
                  comment.createdAt,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(comment.content, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
