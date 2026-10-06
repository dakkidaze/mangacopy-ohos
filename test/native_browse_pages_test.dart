import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:copymanga_flutter/api/manga_source.dart';
import 'package:copymanga_flutter/api/models.dart';
import 'package:copymanga_flutter/native_browse/browse_detail_page.dart';
import 'package:copymanga_flutter/native_browse/browse_home_page.dart';
import 'package:copymanga_flutter/native_browse/browse_search_page.dart';
import 'package:copymanga_flutter/native_browse/widgets.dart';

/// 固定数据的假图源：记录请求，便于断言分页行为。
class FakeSource implements MangaSource {
  FakeSource({
    this.popularPages = const [],
    this.latestPages = const [],
    this.searchPages = const [],
    this.filterPages = const [],
    this.detailFor,
    this.chaptersFor,
    this.failPopular = false,
    this.failChapters = false,
    this.failDetail = false,
  });

  final List<List<MangaSummary>> popularPages;
  final List<List<MangaSummary>> latestPages;
  final List<List<MangaSummary>> searchPages;
  final List<List<MangaSummary>> filterPages;
  final MangaDetail? Function(String id)? detailFor;
  final List<Chapter> Function(String id)? chaptersFor;
  final bool failPopular;
  final bool failChapters;
  final bool failDetail;

  final List<int> popularOffsets = [];
  final List<int> latestOffsets = [];
  final List<String> queries = [];
  final List<int> searchOffsets = [];
  final List<Map<String, String?>> filters = [];

  MangaSummary _item(String id) => MangaSummary(
        id: id,
        title: '漫画 $id',
        cover: 'https://img/$id.webp',
        author: '作者 $id',
      );

  List<MangaSummary> _page(List<List<MangaSummary>> pages, int offset) {
    if (pages.isEmpty) return const [];
    final page = offset ~/ 21;
    return page < pages.length ? pages[page] : const [];
  }

  @override
  Future<List<MangaSummary>> popular({int? offset}) async {
    final o = offset ?? 0;
    popularOffsets.add(o);
    if (failPopular) throw StateError('热门取不到');
    return _page(popularPages, o);
  }

  @override
  Future<List<MangaSummary>> latest({int? offset}) async {
    final o = offset ?? 0;
    latestOffsets.add(o);
    return _page(latestPages, o);
  }

  @override
  Future<List<MangaSummary>> search(String query, {int? offset}) async {
    final o = offset ?? 0;
    queries.add(query);
    searchOffsets.add(o);
    return _page(searchPages, o);
  }

  @override
  Future<List<MangaSummary>> filter({
    String? ordering,
    String? region,
    String? theme,
    String? freeType,
    int? offset,
  }) async {
    filters.add({
      'ordering': ordering,
      'region': region,
      'theme': theme,
      'freeType': freeType,
      'offset': '${offset ?? 0}',
    });
    return _page(filterPages, offset ?? 0);
  }

  @override
  Future<MangaSummary?> searchById(String id) async => _item(id);

  @override
  Future<MangaDetail?> detail(String id) async {
    if (failDetail) throw StateError('详情取不到');
    final d = detailFor?.call(id);
    return d ??
        MangaDetail(
          id: id,
          title: '漫画 $id',
          cover: 'https://img/$id.webp',
          author: '作者 $id',
          description: '简介 $id',
          status: '连载中',
          region: '日漫',
          genres: const ['热血', '冒险'],
        );
  }

  @override
  Future<List<Chapter>> chapters(String id, {String? group}) async {
    if (failChapters) throw StateError('章节取不到');
    final c = chaptersFor?.call(id);
    return c ??
        const [
          Chapter(id: 'u1', name: '第01话', index: 0, size: 12),
          Chapter(id: 'u2', name: '第02话', index: 1, size: 15),
        ];
  }

  @override
  Future<List<String>> pages(String id, String chapterId) async => const [];

  @override
  Future<List<Comment>> chapterComments(String chapterId) async => const [];

  @override
  Future<List<Comment>> comicComments(String comicUuid) async => const [];

  @override
  Future<bool> login(String user, String pass) async => false;

  @override
  Future<List<MangaSummary>> favorites({int? offset}) async => const [];

  @override
  Future<List<MangaSummary>> history({int? offset}) async => const [];
}

/// 测试里把封面换成纯色块：不碰真实网络与磁盘缓存。
Widget _fakeCover(BuildContext context, String url, BoxFit fit) =>
    Container(color: Colors.deepPurple, key: Key('cover-$url'));

MaterialApp _app(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange)),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      home: child,
    );

void main() {
  setUp(() {
    MangaCover.imageBuilder = _fakeCover;
  });
  tearDown(() {
    MangaCover.imageBuilder = null;
  });

  testWidgets('首页热门：出卡片，标题作者可见', (tester) async {
    final s = FakeSource(
      popularPages: [
        List.generate(3, (i) => MangaSummary(
              id: 'p$i',
              title: '热门$i',
              cover: 'https://img/p$i.webp',
              author: 'A$i',
            )),
      ],
    );
    await tester.pumpWidget(_app(BrowseHomePage(source: s)));
    await tester.pumpAndSettle();

    expect(find.text('发现'), findsOneWidget);
    expect(find.text('热门'), findsWidgets);
    expect(find.text('最新'), findsWidgets);
    expect(find.text('热门0'), findsOneWidget);
    expect(find.text('A0'), findsOneWidget);
    expect(s.popularOffsets, [0]);
  });

  testWidgets('首页热门：空数据 → 空态文案', (tester) async {
    await tester.pumpWidget(_app(BrowseHomePage(source: FakeSource())));
    await tester.pumpAndSettle();
    expect(find.text('暂时取不到热门漫画'), findsOneWidget);
  });

  testWidgets('首页热门：失败 → 错误态 + 重试按钮生效', (tester) async {
    var fail = true;
    final ctrl = _ToggleSource(FakeSource(), () => fail);
    await tester.pumpWidget(_app(BrowseHomePage(source: ctrl)));
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂时取不到热门漫画'), findsOneWidget);
  });

  testWidgets('首页：切到「最新」分段走 latest 接口', (tester) async {
    final s = FakeSource(
      latestPages: [
        [
          const MangaSummary(
            id: 'n0',
            title: '最新0',
            cover: 'https://img/n0.webp',
            author: 'N0',
          ),
        ],
      ],
    );
    await tester.pumpWidget(_app(BrowseHomePage(source: s)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    expect(s.latestOffsets, isNotEmpty);
    expect(find.text('最新0'), findsOneWidget);
  });

  testWidgets('首页：滚到底加载下一页（offset += 21）', (tester) async {
    final s = FakeSource(
      popularPages: [
        List.generate(21, (i) => MangaSummary(
              id: 'a$i',
              title: 'A$i',
              cover: '',
              author: 'x',
            )),
        List.generate(21, (i) => MangaSummary(
              id: 'b$i',
              title: 'B$i',
              cover: '',
              author: 'x',
            )),
      ],
    );
    await tester.pumpWidget(_app(BrowseHomePage(source: s)));
    await tester.pumpAndSettle();

    // 21 条不足以滚到底：反复拖动直到触发下一页。
    for (var i = 0; i < 6 && !s.popularOffsets.contains(21); i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
    }
    expect(s.popularOffsets, contains(21));
  });

  testWidgets('搜索页：输入关键词走 search 接口并出结果', (tester) async {
    final s = FakeSource(
      searchPages: [
        [
          const MangaSummary(
            id: 's0',
            title: '搜索结果0',
            cover: 'https://img/s0.webp',
            author: 'S0',
          ),
        ],
      ],
    );
    await tester.pumpWidget(_app(BrowseSearchPage(source: s)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '海贼');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(s.queries, contains('海贼'));
    expect(find.text('搜索结果0'), findsOneWidget);
  });

  testWidgets('搜索页：无关键词时列全站（走 filter）', (tester) async {
    final s = FakeSource(
      filterPages: [
        [
          const MangaSummary(
            id: 'f0',
            title: '全站0',
            cover: '',
            author: 'F0',
          ),
        ],
      ],
    );
    await tester.pumpWidget(_app(BrowseSearchPage(source: s)));
    await tester.pumpAndSettle();
    expect(s.filters, isNotEmpty);
    expect(find.text('全站0'), findsOneWidget);
  });

  testWidgets('搜索页：筛选面板展开并改变参数', (tester) async {
    final s = FakeSource(
      filterPages: [
        const [MangaSummary(id: 'f0', title: '全站0', cover: '', author: 'F0')],
      ],
    );
    await tester.pumpWidget(_app(BrowseSearchPage(source: s)));
    await tester.pumpAndSettle();

    // 展开筛选
    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('地区'), findsOneWidget);
    expect(find.text('收费'), findsOneWidget);

    await tester.tap(find.text('日漫'));
    await tester.pumpAndSettle();
    expect(s.filters.last['region'], 'japan');

    await tester.tap(find.text('免费'));
    await tester.pumpAndSettle();
    expect(s.filters.last['freeType'], '1');

    await tester.tap(find.text('最热门'));
    await tester.pumpAndSettle();
    expect(s.filters.last['ordering'], '-popular');

    await tester.tap(find.text('重置筛选'));
    await tester.pumpAndSettle();
    expect(s.filters.last['region'], isNull);
    expect(s.filters.last['freeType'], isNull);
  });

  testWidgets('搜索页：无结果 → 空态文案带关键词', (tester) async {
    await tester.pumpWidget(_app(BrowseSearchPage(source: FakeSource())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在的漫画');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有找到「不存在的漫画」'), findsOneWidget);
  });

  testWidgets('详情页：封面/标题/作者/状态/简介/题材 + 章节列表', (tester) async {
    final s = FakeSource(
      detailFor: (id) => MangaDetail(
        id: id,
        title: '进击的巨人',
        cover: 'https://img/g.webp',
        author: '谏山创',
        description: '简介内容',
        status: '已完结',
        region: '日漫',
        uuid: 'uuid-1',
        genres: const ['热血', '奇幻'],
      ),
      chaptersFor: (id) => const [
        Chapter(id: 'c1', name: '第01话', index: 0, size: 12),
        Chapter(id: 'c2', name: '第02话', index: 1, size: 15),
      ],
    );
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'giant', source: s)),
    );
    await tester.pumpAndSettle();

    expect(find.text('进击的巨人'), findsWidgets);
    expect(find.text('谏山创'), findsOneWidget);
    expect(find.text('日漫'), findsOneWidget);
    expect(find.text('已完结'), findsOneWidget);
    expect(find.text('简介内容'), findsOneWidget);
    expect(find.text('热血'), findsOneWidget);
    expect(find.text('奇幻'), findsOneWidget);
    expect(find.text('第01话'), findsOneWidget);
    expect(find.text('第02话'), findsOneWidget);
    expect(find.text('12 页'), findsOneWidget);
  });

  testWidgets('详情页：章节排序可切换（默认倒序）', (tester) async {
    final s = FakeSource(
      chaptersFor: (id) => const [
        Chapter(id: 'c1', name: '第01话', index: 0),
        Chapter(id: 'c2', name: '第02话', index: 1),
        Chapter(id: 'c3', name: '第03话', index: 2),
      ],
    );
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'x', source: s)),
    );
    await tester.pumpAndSettle();

    // 倒序：第03话在第01话之前（同一行时比较横向位置）
    final p3 = tester.getTopLeft(find.text('第03话'));
    final p1 = tester.getTopLeft(find.text('第01话'));
    expect(p3.dy < p1.dy || (p3.dy == p1.dy && p3.dx < p1.dx), isTrue);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    final q1 = tester.getTopLeft(find.text('第01话'));
    final q3 = tester.getTopLeft(find.text('第03话'));
    expect(q1.dy < q3.dy || (q1.dy == q3.dy && q1.dx < q3.dx), isTrue);
  });

  testWidgets('详情页：章节加载失败只影响章节区，详情仍在', (tester) async {
    final s = FakeSource(
      failChapters: true,
      detailFor: (id) => MangaDetail(
        id: id,
        title: '只有详情',
        cover: '',
        author: '某人',
        description: 'd',
      ),
    );
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'x', source: s)),
    );
    await tester.pumpAndSettle();

    expect(find.text('只有详情'), findsWidgets);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('详情页：详情失败 → 头部错误态可重试', (tester) async {
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'x', source: FakeSource(failDetail: true))),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('详情取不到'), findsOneWidget);
  });

  testWidgets('详情页：无章节 → 空态', (tester) async {
    final s = FakeSource(chaptersFor: (id) => const <Chapter>[]);
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'x', source: s)),
    );
    await tester.pumpAndSettle();
    expect(find.text('这部漫画还没有章节'), findsOneWidget);
  });

  testWidgets('深色主题下三态视图不抛错', (tester) async {
    final s = FakeSource(failPopular: true);
    await tester.pumpWidget(
      _app(
        BrowseHomePage(source: s),
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepOrange,
            brightness: Brightness.dark,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点章节：交给 NativeReaderLauncher（不自建阅读器）',
      (tester) async {
    final s = FakeSource(
      chaptersFor: (id) => const [
        Chapter(id: 'cu1', name: '第01话', index: 0),
      ],
    );
    await tester.pumpWidget(
      _app(BrowseDetailPage(comicId: 'book1', source: s)),
    );
    await tester.pumpAndSettle();

    expect(find.text('第01话'), findsOneWidget);
    // 点击后应压入一个阅读器路由；这里只验证按钮可点、无异常。
    // 真实阅读器由 NativeReaderLauncher.open 打开（需网络取图，不在单测范围）。
    await tester.tap(find.text('第01话'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('封面占位：空 URL 不报错且给出占位', (tester) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: MangaCover(url: '', iconSize: 24),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
  });
}

/// 包装源：按 [shouldFail] 决定热门是否失败，用于测重试。
class _ToggleSource implements MangaSource {
  _ToggleSource(this.inner, this.shouldFail);

  final MangaSource inner;
  final bool Function() shouldFail;

  @override
  Future<List<MangaSummary>> popular({int? offset}) async {
    if (shouldFail()) throw StateError('热门取不到');
    return inner.popular(offset: offset);
  }

  @override
  Future<List<MangaSummary>> latest({int? offset}) => inner.latest(offset: offset);

  @override
  Future<List<MangaSummary>> search(String query, {int? offset}) =>
      inner.search(query, offset: offset);

  @override
  Future<MangaSummary?> searchById(String id) => inner.searchById(id);

  @override
  Future<List<MangaSummary>> filter({
    String? ordering,
    String? region,
    String? theme,
    String? freeType,
    int? offset,
  }) =>
      inner.filter(
        ordering: ordering,
        region: region,
        theme: theme,
        freeType: freeType,
        offset: offset,
      );

  @override
  Future<MangaDetail?> detail(String id) => inner.detail(id);

  @override
  Future<List<Chapter>> chapters(String id, {String? group}) =>
      inner.chapters(id, group: group);

  @override
  Future<List<String>> pages(String id, String chapterId) =>
      inner.pages(id, chapterId);

  @override
  Future<List<Comment>> chapterComments(String chapterId) =>
      inner.chapterComments(chapterId);

  @override
  Future<List<Comment>> comicComments(String comicUuid) =>
      inner.comicComments(comicUuid);

  @override
  Future<bool> login(String user, String pass) => inner.login(user, pass);

  @override
  Future<List<MangaSummary>> favorites({int? offset}) =>
      inner.favorites(offset: offset);

  @override
  Future<List<MangaSummary>> history({int? offset}) =>
      inner.history(offset: offset);
}
