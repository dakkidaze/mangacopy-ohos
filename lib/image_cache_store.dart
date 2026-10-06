import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'settings.dart';

/// 漫画图片磁盘缓存：自带字节上限的 LRU 淘汰。
///
/// flutter_cache_manager 原生只支持「条目数 + 过期时间」两个维度，没有字节上限；
/// 条漫单张图动辄几 MB，条目数根本约束不住体积。这里额外维护一层按字节的
/// LRU：超过用户设定的上限后，按最后访问时间从旧到新删文件，一直删到上限的
/// [_trimTargetRatio]（而不是只删到刚好等于上限），避免每存一张新图就要重扫一次目录。
///
/// 直接删文件不会破坏 cache_manager：它取文件前会 exists() 校验，文件没了就当未命中
/// 重新下载；残留的数据库行由 [_maxCacheObjects] 兜底回收。
class AppImageCache {
  const AppImageCache._();

  /// 独立 key，避免和别处默认的 libCachedImageData 目录混在一起。
  static const cacheKey = 'copymangaImageCache';

  /// 字节上限达到后，一次性削减到上限的这个比例。
  static const _trimTargetRatio = 0.8;

  /// 两次自动 trim 的最小间隔：翻页时频繁扫目录不值当。
  static const _minTrimInterval = Duration(seconds: 45);

  /// 条目数上限只用来回收残留 db 行，真正的约束是字节上限。
  static const _maxCacheObjects = 20000;

  static CacheManager? _manager;
  static DateTime? _lastTrimAt;
  static Future<void>? _trimInFlight;

  static CacheManager get manager => _manager ??= CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: _maxCacheObjects,
    ),
  );

  static Future<Directory> _cacheDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}${Platform.pathSeparator}$cacheKey');
  }

  /// 当前图片缓存占用字节数。
  static Future<int> currentBytes() async {
    final dir = await _cacheDir();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// 按需 trim：距上次不足 [_minTrimInterval] 则跳过；同一时刻只跑一个。
  static Future<void> maybeTrim() {
    final last = _lastTrimAt;
    if (last != null && DateTime.now().difference(last) < _minTrimInterval) {
      return Future.value();
    }
    return trim();
  }

  /// 强制执行一次字节上限淘汰。
  static Future<void> trim() {
    return _trimInFlight ??= _trim().whenComplete(() {
      _trimInFlight = null;
      _lastTrimAt = DateTime.now();
    });
  }

  static Future<void> _trim() async {
    final limit = AppSettings.imageCacheLimitBytes;
    if (limit <= 0) return; // 0 = 不限制
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;

      final entries = <_CacheEntry>[];
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          final stat = await e.stat();
          // accessed 在部分 Android ROM 上不更新（noatime 挂载），退回 modified。
          final at = stat.accessed.isAfter(stat.modified)
              ? stat.accessed
              : stat.modified;
          entries.add(_CacheEntry(e, stat.size, at));
          total += stat.size;
        } catch (_) {}
      }
      if (total <= limit) return;

      entries.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
      final target = (limit * _trimTargetRatio).round();
      var removed = 0;
      for (final entry in entries) {
        if (total <= target) break;
        try {
          await entry.file.delete();
          total -= entry.size;
          removed++;
        } catch (_) {}
      }
      if (kDebugMode) {
        debugPrint(
          '[AppImageCache] trim: 删除 $removed 个文件，剩余 ${(total / 1024 / 1024).toStringAsFixed(1)} MB',
        );
      }
    } catch (_) {}
  }

  /// 清空图片磁盘缓存（设置页「清理缓存」调用）。
  static Future<void> clear() async {
    try {
      await manager.emptyCache();
    } catch (_) {}
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    _lastTrimAt = null;
  }

  /// 内存中已解码图片的上限。默认 100MB 对条漫长图太小：单张解码后可能 20–40MB，
  /// 几张就把 LRU 撑爆、把还在视口附近的图挤掉，导致 item 高度塌陷回跳。
  static void applyMemoryCacheLimits() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = 320 << 20; // 320 MB
    cache.maximumSize = 80; // 条数压低，避免小图占坑
  }
}

class _CacheEntry {
  const _CacheEntry(this.file, this.size, this.accessedAt);

  final File file;
  final int size;
  final DateTime accessedAt;
}
