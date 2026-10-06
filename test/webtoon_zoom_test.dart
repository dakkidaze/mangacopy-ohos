import 'package:copymanga_flutter/zoomable_webtoon_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ZoomableWebtoonView 条漫模式缩放手势测试', () {
    testWidgets('条漫长列表支持双击放大到 2.0x 再次双击还原到 1.0x', (WidgetTester tester) async {
      bool isZoomed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 600,
              child: ZoomableWebtoonView(
                onZoomChanged: (z) => isZoomed = z,
                child: ListView.builder(
                  itemCount: 10,
                  itemBuilder: (context, i) => Container(
                    height: 200,
                    color: i.isEven ? Colors.red : Colors.green,
                    child: Text('Item $i'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final finder = find.text('Item 0');
      expect(finder, findsOneWidget);
      expect(isZoomed, isFalse);

      final center = tester.getCenter(finder);

      // 第1次双击：条漫列表放大
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(isZoomed, isTrue, reason: '条漫双击后应进入放大状态');

      // 第2次双击：条漫列表还原缩小
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(isZoomed, isFalse, reason: '条漫再次双击后应还原至 1.0x 原始比例');
    });
  });
}
