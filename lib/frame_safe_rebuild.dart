import 'package:flutter/scheduler.dart';

/// 帧安全的重建调度器。
///
/// 用于「回调可能在 build 期间同步触发」的场景：条漫图片的尺寸回调挂在
/// `ImageStream` 上，图片已在 ImageCache 时 `addListener` 会同步回调，而监听是在
/// `initState`（即 itemBuilder 内）挂上的——此刻直接 setState 会抛
/// "setState() called during build"。
///
/// 同时把一帧内的多次请求合并成一次重建：条漫一屏可能有多张图同时报出尺寸。
class FrameSafeRebuild {
  FrameSafeRebuild({SchedulerBinding? binding}) : _binding = binding;

  final SchedulerBinding? _binding;
  bool _scheduled = false;

  SchedulerBinding get _sched => _binding ?? SchedulerBinding.instance;

  /// 本帧是否已有待执行的重建。
  bool get isScheduled => _scheduled;

  /// 请求一次重建。build 期间调用则延到帧后，否则立即执行。
  /// 已有待执行的重建时直接丢弃本次请求（合并）。
  void request(void Function() rebuild) {
    if (_scheduled) return;
    final phase = _sched.schedulerPhase;
    final duringFrame =
        phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
    if (!duringFrame) {
      rebuild();
      return;
    }
    _scheduled = true;
    _sched.addPostFrameCallback((_) {
      _scheduled = false;
      rebuild();
    });
  }
}
