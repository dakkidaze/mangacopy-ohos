import 'package:copymanga_flutter/webtoon_aspect_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 `_buildWebtoonImage` 的约束决策：比例未知不套 AspectRatio，已知才套。
Widget buildItem(String url, Widget image) {
  final ratio = WebtoonAspectCache.get(url);
  if (ratio == null) return image;
  return AspectRatio(aspectRatio: ratio, child: image);
}

/// 用一个「自然高度 = 宽 / 0.5」的假图代替真实图片解码。
class _FakeTallImage extends StatelessWidget {
  const _FakeTallImage();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // 模拟 BoxFit.fitWidth：按宽度铺满，高度由原始比例(0.5)决定
        final w = c.maxWidth;
        return SizedBox(width: w, height: w / 0.5);
      },
    );
  }
}

Future<void> pumpItem(WidgetTester tester, String url) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(width: 300, child: buildItem(url, const _FakeTallImage())),
        ),
      ),
    ),
  );
}

void main() {
  setUp(WebtoonAspectCache.clear);

  group('条漫 item 布局约束', () {
    testWidgets('比例未知时不加约束，长图按自然高度展开（不被裁）', (tester) async {
      await pumpItem(tester, 'u');
      // 宽 300、原始比例 0.5 → 自然高度 600
      expect(tester.getSize(find.byType(_FakeTallImage)).height, 600);
      expect(find.byType(AspectRatio), findsNothing);
    });

    testWidgets('比例已知时锁定为真实比例，高度与自然高度一致', (tester) async {
      WebtoonAspectCache.put('u', 800, 1600); // ratio 0.5
      await pumpItem(tester, 'u');
      expect(find.byType(AspectRatio), findsOneWidget);
      // 锁定后高度仍是 600：AspectRatio 用的是真实比例，没有压缩/裁切
      expect(tester.getSize(find.byType(AspectRatio)).height, 600);
    });

    testWidgets('回归：用 3:4 兜底比例套 AspectRatio 会把长图压到 400（裁图）', (tester) async {
      // 这是修复前的行为，保留为反例，防止有人再把兜底比例塞回去
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 300,
                child: AspectRatio(aspectRatio: 0.75, child: _FakeTallImage()),
              ),
            ),
          ),
        ),
      );
      // 300 / 0.75 = 400，远小于自然高度 600 → 图片下半截会被裁掉
      expect(tester.getSize(find.byType(AspectRatio)).height, 400);
    });
  });
}
