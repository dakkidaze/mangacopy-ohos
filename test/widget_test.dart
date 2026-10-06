import 'package:flutter_test/flutter_test.dart';

import 'package:copymanga_flutter/chapter_data.dart';

void main() {
  test('ChapterData 解析 h.js 收图协议', () {
    const raw =
        '第1话 abcd-uuid\n'
        'https://site/comicContent/slug/next-uuid\n'
        'null\n'
        'https://img/1.webp\n'
        'https://img/2.webp';
    final data = ChapterData.parse(raw)!;
    expect(data.title, '第1话');
    expect(data.nextChapterUrl, isNotNull);
    expect(data.previousChapterUrl, isNull);
    expect(data.imgUrls.length, 2);
  });

  test('wrapResolution 提升图片分辨率', () {
    expect(wrapResolution('https://x/y.c800x.webp'), 'https://x/y.c1500x.webp');
  });
}
