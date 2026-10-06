import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'image_cache_store.dart';

/// 带自动重试的网络图片：失败后 1.5s/3s 退避自动重试 2 次
/// （对应原生版 loadImageWithRetry），仍失败则显示碎图，点按手动重试。
///
/// 原始尺寸探测见 [ImageIntrinsicSizeListener]（条漫用它锁定 item 高度），
/// 不放在这里是为了让本地图片走同一套机制。
class RetryNetworkImage extends StatefulWidget {
  const RetryNetworkImage({super.key, required this.url, this.fit});

  final String url;
  final BoxFit? fit;

  @override
  State<RetryNetworkImage> createState() => _RetryNetworkImageState();
}

class _RetryNetworkImageState extends State<RetryNetworkImage> {
  int _attempt = 0;
  bool _retryScheduled = false;

  void _scheduleRetry() {
    if (_retryScheduled) return;
    _retryScheduled = true;
    Future.delayed(Duration(milliseconds: 1500 * (_attempt + 1)), () async {
      await AppImageCache.manager.removeFile(widget.url);
      if (mounted) {
        setState(() {
          _attempt++;
          _retryScheduled = false;
        });
      }
    });
  }

  void _manualRetry() async {
    await AppImageCache.manager.removeFile(widget.url);
    if (mounted) setState(() => _attempt = 0);
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey('${widget.url}#$_attempt'),
      imageUrl: widget.url,
      cacheManager: AppImageCache.manager,
      fit: widget.fit,
      placeholder: (context, url) =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      errorWidget: (context, url, error) {
        if (_attempt < 2) {
          _scheduleRetry();
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return GestureDetector(
          onTap: _manualRetry,
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image, color: Colors.white38, size: 40),
                SizedBox(height: 8),
                Text(
                  '加载失败，点击重试',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
