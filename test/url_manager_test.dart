import 'package:copymanga_flutter/url_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlManager Sticky 节点保持逻辑测试', () {
    test('当前节点为最快时，保持使用不切换', () {
      final valid = [
        const MapEntry('https://www.copy3000.com', 120),
        const MapEntry('https://www.2026copy.com', 180),
        const MapEntry('https://www.mangacopy.com', 300),
      ];
      final preferredIdx = 0; // 当前为最快 120ms
      expect(UrlManager.shouldSwitchForSlow(valid, preferredIdx), isFalse);
    });

    test('当前节点轻微相差（如 120ms vs 250ms），差值未达 2500ms，保持当前节点不切换', () {
      final valid = [
        const MapEntry('https://www.copy3000.com', 120),
        const MapEntry('https://www.2026copy.com', 150),
        const MapEntry(
          'https://www.mangacopy.com',
          250,
        ), // 虽然 250 >= 120 * 2，但差值仅 130ms
      ];
      final preferredIdx = 2; // 倒数 1 名
      expect(UrlManager.shouldSwitchForSlow(valid, preferredIdx), isFalse);
    });

    test('当前节点极其严重滞后（如 150ms vs 3000ms），满足差值>=2500ms且倍数>=3，触发切换', () {
      final valid = [
        const MapEntry('https://www.copy3000.com', 150),
        const MapEntry('https://www.2026copy.com', 300),
        const MapEntry(
          'https://www.mangacopy.com',
          3000,
        ), // 差值 2850ms >= 2500ms，且 3000 >= 150 * 3
      ];
      final preferredIdx = 2; // 倒数 1 名
      expect(UrlManager.shouldSwitchForSlow(valid, preferredIdx), isTrue);
    });

    test('当前节点绝对耗时超过 4000ms，触发切换', () {
      final valid = [
        const MapEntry('https://www.copy3000.com', 1200),
        const MapEntry('https://www.2026copy.com', 4100), // 4100ms > 4000ms
      ];
      final preferredIdx = 1;
      expect(UrlManager.shouldSwitchForSlow(valid, preferredIdx), isTrue);
    });
  });
}
