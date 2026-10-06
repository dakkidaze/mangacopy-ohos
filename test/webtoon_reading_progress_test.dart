import 'package:copymanga_flutter/webtoon_reading_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebtoonReadingProgress', () {
    test('短末图到底时仍记为最后一页', () {
      final page = WebtoonReadingProgress.resolveCurrentPage(
        itemCount: 21,
        positions: const [
          WebtoonViewportItem(index: 19, leadingEdge: -0.4, trailingEdge: 0.3),
          WebtoonViewportItem(index: 20, leadingEdge: 0.3, trailingEdge: 0.8),
        ],
      );

      expect(page, 21);
    });

    test('末图尚未到底时仍按最靠上的可见图片计页', () {
      final page = WebtoonReadingProgress.resolveCurrentPage(
        itemCount: 21,
        positions: const [
          WebtoonViewportItem(index: 19, leadingEdge: -0.1, trailingEdge: 0.5),
          WebtoonViewportItem(index: 20, leadingEdge: 0.9, trailingEdge: 1.4),
        ],
      );

      expect(page, 20);
    });

    test('普通页面保持最靠上可见图片的页码', () {
      final page = WebtoonReadingProgress.resolveCurrentPage(
        itemCount: 21,
        positions: const [
          WebtoonViewportItem(index: 7, leadingEdge: -0.2, trailingEdge: 0.7),
          WebtoonViewportItem(index: 8, leadingEdge: 0.7, trailingEdge: 1.6),
        ],
      );

      expect(page, 8);
    });
  });
}
