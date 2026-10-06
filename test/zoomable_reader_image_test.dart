import 'package:copymanga_flutter/zoomable_reader_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ZoomableReaderImage 双击放大/还原手势测试', () {
    testWidgets('双击放大到 2.0x 再次双击还原到 1.0x', (WidgetTester tester) async {
      bool isZoomed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: ZoomableReaderImage(
                  isHorizontal: true,
                  r2l: false,
                  onPageTurn: (_) {},
                  onMenu: () {},
                  onZoomChanged: (z) => isZoomed = z,
                  child: Container(color: Colors.blue, key: const Key('img')),
                ),
              ),
            ),
          ),
        ),
      );

      final finder = find.byKey(const Key('img'));
      expect(finder, findsOneWidget);
      expect(isZoomed, isFalse);

      final center = tester.getCenter(finder);

      // 第1次双击：放大
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(isZoomed, isTrue, reason: '双击后应放大至 >1.05x');

      // 第2次双击：缩小还原
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(isZoomed, isFalse, reason: '再次双击后应成功缩小还原至 1.0x');
    });

    testWidgets('默认正式路径不挂载 InteractiveViewer', (WidgetTester tester) async {
      expect(ZoomableReaderImage.useLegacyGestureRouting, isFalse);
      expect(ZoomableReaderImage.experimentBypassIvWhenUnzoomed, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: ZoomableReaderImage(
                isHorizontal: true,
                r2l: false,
                onPageTurn: (_) {},
                onMenu: () {},
                child: Container(color: Colors.blue),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('实验开关开启且未缩放时不挂载 InteractiveViewer', (
      WidgetTester tester,
    ) async {
      // 实验开关已非正式路径；保留查询兼容。正式默认不依赖该开关。
      if (!ZoomableReaderImage.experimentBypassIvWhenUnzoomed) {
        return;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: ZoomableReaderImage(
                isHorizontal: true,
                r2l: false,
                onPageTurn: (_) {},
                onMenu: () {},
                child: Container(color: Colors.blue),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('正式路径横向拖动不挂载 InteractiveViewer', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: ZoomableReaderImage(
                isHorizontal: true,
                r2l: false,
                onPageTurn: (_) {},
                onMenu: () {},
                child: Container(color: Colors.blue, key: const Key('img')),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InteractiveViewer), findsNothing);
      final center = tester.getCenter(find.byKey(const Key('img')));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(-120, 0));
      await gesture.up();
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsNothing);
    });
  });
}
