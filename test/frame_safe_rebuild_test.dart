import 'package:copymanga_flutter/frame_safe_rebuild.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻条漫 item 的危险形状：子控件在 initState（即 itemBuilder 内、build 期间）
/// 同步回调父级，父级据此请求重建。
class _SyncReportingChild extends StatefulWidget {
  const _SyncReportingChild({super.key, required this.onReport});
  final VoidCallback onReport;

  @override
  State<_SyncReportingChild> createState() => _SyncReportingChildState();
}

class _SyncReportingChildState extends State<_SyncReportingChild> {
  @override
  void initState() {
    super.initState();
    widget.onReport(); // 同步：正是 ImageStream 命中缓存时的行为
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 10);
}

class _Host extends StatefulWidget {
  const _Host({required this.itemCount});
  final int itemCount;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final rebuild = FrameSafeRebuild();
  int builds = 0;
  int rebuildsRequested = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return Column(
      children: [
        for (var i = 0; i < widget.itemCount; i++)
          _SyncReportingChild(
            key: ValueKey(i),
            onReport: () {
              rebuildsRequested++;
              rebuild.request(() {
                if (mounted) setState(() {});
              });
            },
          ),
      ],
    );
  }
}

void main() {
  group('FrameSafeRebuild', () {
    testWidgets('build 期间同步回调不触发 setState-during-build 异常', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Host(itemCount: 1)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('一帧内多次请求合并为一次重建', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Host(itemCount: 5)));
      final state = tester.state<_HostState>(find.byType(_Host));
      final buildsAfterFirst = state.builds;
      expect(state.rebuildsRequested, 5, reason: '5 个 item 都同步报告了');

      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 5 次请求只应换来 1 次额外重建，而不是 5 次
      expect(state.builds, buildsAfterFirst + 1);
    });

    testWidgets('帧外请求立即执行，不排队', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Host(itemCount: 1)));
      await tester.pumpAndSettle();
      final state = tester.state<_HostState>(find.byType(_Host));
      final before = state.builds;

      var ran = false;
      state.rebuild.request(() => ran = true);
      expect(ran, isTrue, reason: '不在 build 期间应同步执行');
      expect(state.rebuild.isScheduled, isFalse);
      expect(state.builds, before, reason: '回调没调 setState，不应有额外重建');
    });
  });
}
