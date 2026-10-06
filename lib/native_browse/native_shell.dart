import 'dart:async';

import 'package:flutter/material.dart';

import '../browser_page.dart';
import '../downloads_page.dart';
import '../settings_page.dart';
import 'browse_home_page.dart';
import 'browse_source.dart';
import 'native_account_page.dart';
import 'native_favorites_page.dart';
import 'native_history_page.dart';

/// 原生浏览外壳：底部导航（发现 / 更多）。
///
/// 与网页版并存：设置里切「浏览方式」即可来回切（重启/重进生效）。
class NativeShellPage extends StatefulWidget {
  const NativeShellPage({super.key});

  @override
  State<NativeShellPage> createState() => _NativeShellPageState();
}

class _NativeShellPageState extends State<NativeShellPage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 启动时把已持久化的登录态同步到 NativeSession（登录态由 AuthStore 落盘）。
    unawaited(() async {
      try {
        final bs = await BrowseSource.instance();
        NativeSession.instance.sync(bs.source);
      } catch (_) {}
    }());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [BrowseHomePage(), _MoreTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: '发现',
          ),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
        ],
      ),
    );
  }
}

class _MoreTab extends StatelessWidget {
  const _MoreTab();

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: NativeSession.instance,
          builder: (context, _) {
            final loggedIn = NativeSession.instance.loggedIn;
            return ListTile(
              leading: Icon(
                loggedIn ? Icons.person : Icons.person_outline,
              ),
              title: Text(loggedIn ? '账号（已登录）' : '登录'),
              subtitle: Text(
                loggedIn ? '收藏 / 历史已可用' : '登录后可用收藏与浏览历史',
              ),
              onTap: () => _push(context, const NativeAccountPage()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.favorite_outline),
          title: const Text('我的收藏'),
          onTap: () => _push(context, const NativeFavoritesPage()),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('浏览历史'),
          onTap: () => _push(context, const NativeHistoryPage()),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('我的下载'),
          onTap: () => _push(context, const DownloadsPage()),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('设置'),
          subtitle: const Text('含「浏览方式」「章节图源」等'),
          onTap: () => _push(context, const SettingsPage()),
        ),
        ListTile(
          leading: const Icon(Icons.public),
          title: const Text('网页版'),
          subtitle: const Text('登录页 / 部分站内页面仍可在此打开'),
          onTap: () => _push(context, const BrowserPage()),
        ),
      ],
    );
  }
}
