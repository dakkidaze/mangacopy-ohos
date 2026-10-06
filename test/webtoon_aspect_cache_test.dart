import 'package:copymanga_flutter/webtoon_aspect_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(WebtoonAspectCache.clear);

  group('WebtoonAspectCache', () {
    test('未记录时返回 null：调用方据此不加约束，避免裁图', () {
      expect(WebtoonAspectCache.get('a'), isNull);
      expect(WebtoonAspectCache.isKnown('a'), isFalse);
    });

    test('记录后 item 高度稳定：同一 url 反复取到同一比例', () {
      expect(WebtoonAspectCache.put('a', 800, 1600), isTrue);
      expect(WebtoonAspectCache.get('a'), 0.5);
      expect(WebtoonAspectCache.get('a'), 0.5);
    });

    test('相同比例重复上报不触发重建', () {
      expect(WebtoonAspectCache.put('a', 800, 1600), isTrue);
      expect(WebtoonAspectCache.put('a', 400, 800), isFalse);
    });

    test('非法尺寸被忽略，避免 AspectRatio 抛异常', () {
      expect(WebtoonAspectCache.put('a', 0, 100), isFalse);
      expect(WebtoonAspectCache.put('a', 100, 0), isFalse);
      expect(WebtoonAspectCache.isKnown('a'), isFalse);
    });

    test('get 会刷新 LRU 位置', () {
      WebtoonAspectCache.put('a', 100, 200);
      WebtoonAspectCache.put('b', 100, 100);
      WebtoonAspectCache.get('a');
      expect(WebtoonAspectCache.isKnown('a'), isTrue);
      expect(WebtoonAspectCache.isKnown('b'), isTrue);
    });
  });
}
