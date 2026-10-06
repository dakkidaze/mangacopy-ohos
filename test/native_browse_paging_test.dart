import 'package:flutter_test/flutter_test.dart';

import 'package:copymanga_flutter/native_browse/browse_paging.dart';

void main() {
  test('首屏成功：状态 ready，数据落地', () async {
    final c = BrowsePagingController<String>(fetcher: (o) async => ['a', 'b']);
    expect(c.status, BrowseStatus.loading);
    await c.refresh();
    expect(c.status, BrowseStatus.ready);
    expect(c.items, ['a', 'b']);
  });

  test('首屏空：状态 empty', () async {
    final c = BrowsePagingController<String>(fetcher: (o) async => const []);
    await c.refresh();
    expect(c.status, BrowseStatus.empty);
    expect(c.items, isEmpty);
  });

  test('首屏失败：状态 error 且保留错误，可重试成功', () async {
    var fail = true;
    final c = BrowsePagingController<String>(fetcher: (o) async {
      if (fail) throw StateError('网络不可用');
      return ['x'];
    });
    await c.refresh();
    expect(c.status, BrowseStatus.error);
    expect(c.error, isA<StateError>());
    fail = false;
    await c.refresh();
    expect(c.status, BrowseStatus.ready);
    expect(c.items, ['x']);
  });

  test('分页：offset 按已加载条数累加，本页不足一页即判定到底', () async {
    final offsets = <int>[];
    final c = BrowsePagingController<String>(
      fetcher: (o) async {
        offsets.add(o);
        // 第 3 页只回 1 条 → 到底
        return o == 0
            ? List<String>.generate(21, (i) => 'p0-$i')
            : (o == 21 ? List<String>.generate(21, (i) => 'p1-$i') : ['p2-0']);
      },
    );
    await c.refresh();
    expect(c.items.length, 21);
    expect(c.hasMore, isTrue);
    await c.loadMore();
    expect(c.items.length, 42);
    await c.loadMore();
    expect(c.items.length, 43);
    expect(c.hasMore, isFalse);
    expect(offsets, [0, 21, 42]);
  });

  test('分页：非 ready 状态或没有更多时不重复请求', () async {
    var calls = 0;
    final c = BrowsePagingController<String>(fetcher: (o) async {
      calls++;
      return const [];
    });
    await c.refresh();
    expect(calls, 1);
    // 空态不该触发 loadMore
    await c.loadMore();
    expect(calls, 1);
  });

  test('分页失败：保留已有数据，loadMoreFailed 置位后可重试成功', () async {
    var fail = true;
    final c = BrowsePagingController<String>(fetcher: (o) async {
      if (fail && o > 0) throw StateError('断网');
      return List<String>.generate(21, (i) => 'i$i');
    });
    await c.refresh();
    expect(c.items.length, 21);
    await c.loadMore();
    expect(c.loadMoreFailed, isTrue);
    expect(c.items.length, 21, reason: '失败不丢已加载数据');
    fail = false;
    await c.retryLoadMore();
    expect(c.loadMoreFailed, isFalse);
    expect(c.items.length, 42);
  });

  test('并发 refresh 只生效一次', () async {
    var calls = 0;
    final c = BrowsePagingController<String>(fetcher: (o) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return ['a'];
    });
    await Future.wait([c.refresh(), c.refresh()]);
    expect(calls, 1);
  });

  test('notifyListeners 在状态变化时触发', () async {
    final c = BrowsePagingController<String>(fetcher: (o) async => ['a']);
    var fired = 0;
    c.addListener(() => fired++);
    await c.refresh();
    expect(fired, greaterThan(0));
  });

  test('describeBrowseError 过长截断', () {
    final long = 'x' * 200;
    final s = describeBrowseError(StateError(long));
    expect(s.length, lessThan(90));
    expect(s.endsWith('…'), isTrue);
  });

  test('dispose 不抛错', () {
    final c = BrowsePagingController<String>(fetcher: (o) async => const []);
    expect(c.dispose, returnsNormally);
  });
}
