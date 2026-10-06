import 'package:flutter/material.dart';

/// 监听 [provider] 解码后的原始像素尺寸，并把 [child] 原样透出。
///
/// 与真正显示图片的控件共用同一个 ImageProvider：命中的是同一条 ImageCache
/// 记录，不会产生额外的下载或解码。
///
/// ⚠ [onSize] **可能在 build 期间同步触发**——图片已在 ImageCache 里时
/// `ImageStream.addListener` 会立刻回调，而监听是在 `initState`（长列表里即
/// itemBuilder 内）挂上的。调用方不得在 [onSize] 里直接 setState，
/// 应经由 `FrameSafeRebuild` 之类的帧后调度。
class ImageIntrinsicSizeListener extends StatefulWidget {
  const ImageIntrinsicSizeListener({
    super.key,
    required this.provider,
    required this.onSize,
    required this.child,
  });

  final ImageProvider provider;
  final ValueChanged<Size> onSize;
  final Widget child;

  @override
  State<ImageIntrinsicSizeListener> createState() =>
      _ImageIntrinsicSizeListenerState();
}

class _ImageIntrinsicSizeListenerState
    extends State<ImageIntrinsicSizeListener> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ImageIntrinsicSizeListener old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _stop();
      _listen();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _listen() {
    final stream = widget.provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        widget.onSize(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      },
      onError: (_, _) {},
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _stop() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
