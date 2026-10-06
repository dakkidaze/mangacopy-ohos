import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'image_cache_store.dart';
import 'settings.dart';
import 'splash_page.dart';
import 'reader_gesture_marker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iOS：尽早 edgeToEdge，避免启动瞬间上下黑边；安全区由 BrowserPage 自行 padding
  if (Platform.isIOS) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  // 只做本地设置读取，绝不在 runApp 前做网络测速（那是旧版启动慢的主因）
  await AppSettings.init();
  AppImageCache.applyMemoryCacheLimits();
  // 启动时按用户设定的上限淘汰一次旧图；不 await，别拖慢冷启动
  unawaited(AppImageCache.trim());
  if (kDebugMode) {
    ReaderGestureMarkerBridge.init();
  }
  if (Platform.isIOS) {
    final dark = AppSettings.darkMode.value;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      ),
    );
  }
  runApp(const CopyMangaApp());
}

class CopyMangaApp extends StatelessWidget {
  const CopyMangaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.darkMode,
      builder: (context, dark, child) {
        return MaterialApp(
          title: 'CopyManga',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
            useMaterial3: true,
            scaffoldBackgroundColor: Colors.white,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepOrange,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: Colors.black,
          ),
          // 必须跟 App 开关，不能 ThemeMode.system：
          // 否则系统暗色时网页外底色发黑，而站点仍是白底，黑边感特别明显。
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const SplashPage(),
        );
      },
    );
  }
}
