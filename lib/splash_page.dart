import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_page.dart';
import 'native_browse/native_shell.dart';
import 'settings.dart';
import 'url_manager.dart';

/// 开机过渡：背景/图标对齐原生 SplashScreen（colorPrimary + 启动图标）。
/// 策略对齐 MainActivity：有缓存立刻进主页并后台测速；首次无缓存才在此等待测速。
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final hasCache = await UrlManager.bootstrap();
    if (!mounted) return;

    if (!hasCache) {
      setState(() => _status = '正在选择最快线路…');
      await UrlManager.probe();
    } else {
      // 与原版一致：缓存可用时不阻塞启动，后台更新最快源
      unawaited(UrlManager.probe());
    }

    if (kDebugMode) {
      try {
        await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      } catch (_) {}
    }

    if (!mounted) return;
    final home = AppSettings.browseSource == 'api'
        ? const NativeShellPage()
        : const BrowserPage();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => home,
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 280),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 暗色：黑底过渡，避免橙闪→白闪→暗网；浅色仍用原生 #FFCC7F
    final dark = AppSettings.darkMode.value;
    final bg = dark ? Colors.black : const Color(0xFFFFCC7F);
    final fg = dark ? Colors.white70 : const Color(0xFF3E2723);
    final accent = dark ? Colors.white54 : const Color(0xFF5D4037);
    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon/ic_launcher.png',
              width: 96,
              height: 96,
              filterQuality: FilterQuality.high,
            ),
            const SizedBox(height: 20),
            Text(
              '拷贝漫画',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 28),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: accent,
                ),
              ),
              const SizedBox(height: 12),
              Text(_status, style: TextStyle(fontSize: 13, color: accent)),
            ],
          ],
        ),
      ),
    );
  }
}
