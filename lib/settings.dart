import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局设置，对应原生版 PropertiesTools(settings.properties) + app_settings。
class AppSettings {
  static late SharedPreferences _prefs;

  /// 'h' 横向翻页 / 'v' 纵向翻页 / 'w' 条漫连续滚动
  static String readMode = 'h';

  /// 右开本（右滑=下一页，日漫习惯）
  static bool r2l = true;

  /// 阅读器右下角常驻页码
  static bool showPageNum = true;

  /// h.js 收图滚动速度：conservative / normal / fast / turbo
  static String sourceProfile = 'fast';

  /// 音量键翻页
  static bool volTurn = false;

  /// 章节图片取数方式：'webview'（隐藏 WebView 收图，默认）| 'api'（走 /api/v3 取图）。
  static String chapterSource = 'webview';

  /// 是否在每章末尾追加「吐槽」页（作为阅读序列的最后一张虚拟页）。
  ///
  /// 注意默认值：静态初值为 false（便于不初始化设置的测试保持既有翻页行为），
  /// 应用启动时 [init] 会在用户未设置过时把它置为 true。
  static bool chapterEndComments = false;

  /// 浏览方式：'webview'（网页版 H5，默认）| 'api'（API 驱动的原生界面）。
  static String browseSource = 'webview';

  /// 夜间模式（含 WebView CSS 反色）；用 notifier 让主题和 WebView 即时响应
  static final ValueNotifier<bool> darkMode = ValueNotifier(false);

  /// 隐藏浏览页状态栏
  static final ValueNotifier<bool> hideStatusBar = ValueNotifier(false);

  /// 图片磁盘缓存上限（MB）。0 = 不限制。超限后按最后访问时间淘汰最旧的。
  static int imageCacheLimitMb = 1024;

  /// 可选档位（MB）；0 放在最后表示「不限制」。
  static const imageCacheLimitOptionsMb = [256, 512, 1024, 2048, 4096, 0];

  static int get imageCacheLimitBytes =>
      imageCacheLimitMb <= 0 ? 0 : imageCacheLimitMb * 1024 * 1024;

  static String formatCacheLimit(int mb) {
    if (mb <= 0) return '不限制';
    if (mb >= 1024) {
      final g = mb / 1024;
      return '${g == g.roundToDouble() ? g.toStringAsFixed(0) : g.toStringAsFixed(1)} GB';
    }
    return '$mb MB';
  }

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    readMode = _prefs.getString('readMode') ?? 'h';
    r2l = _prefs.getBool('r2l') ?? true;
    showPageNum = _prefs.getBool('showPageNum') ?? true;
    sourceProfile = _prefs.getString('sourceProfile') ?? 'fast';
    volTurn = _prefs.getBool('volTurn') ?? false;
    chapterSource = _prefs.getString('chapterSource') ?? 'webview';
    chapterEndComments = _prefs.getBool('chapterEndComments') ?? true;
    browseSource = _prefs.getString('browseSource') ?? 'webview';
    darkMode.value = _prefs.getBool('darkMode') ?? false;
    hideStatusBar.value = _prefs.getBool('hideStatusBar') ?? false;
    imageCacheLimitMb = _prefs.getInt('imageCacheLimitMb') ?? 1024;
  }

  static Future<void> setImageCacheLimitMb(int v) async {
    imageCacheLimitMb = v;
    await _prefs.setInt('imageCacheLimitMb', v);
  }

  static Future<void> setReadMode(String v) async {
    readMode = v;
    await _prefs.setString('readMode', v);
  }

  static Future<void> setR2l(bool v) async {
    r2l = v;
    await _prefs.setBool('r2l', v);
  }

  static Future<void> setShowPageNum(bool v) async {
    showPageNum = v;
    await _prefs.setBool('showPageNum', v);
  }

  static Future<void> setSourceProfile(String v) async {
    sourceProfile = v;
    await _prefs.setString('sourceProfile', v);
  }

  static Future<void> setVolTurn(bool v) async {
    volTurn = v;
    await _prefs.setBool('volTurn', v);
  }

  static Future<void> setChapterSource(String v) async {
    chapterSource = v;
    await _prefs.setString('chapterSource', v);
  }

  static Future<void> setChapterEndComments(bool v) async {
    chapterEndComments = v;
    await _prefs.setBool('chapterEndComments', v);
  }

  static Future<void> setBrowseSource(String v) async {
    browseSource = v;
    await _prefs.setString('browseSource', v);
  }

  static Future<void> setDarkMode(bool v) async {
    darkMode.value = v;
    await _prefs.setBool('darkMode', v);
  }

  static Future<void> setHideStatusBar(bool v) async {
    hideStatusBar.value = v;
    await _prefs.setBool('hideStatusBar', v);
  }
}

/// WebView 暗色 CSS 反色注入（与原生版 WebChromeClient.darkModeJs 相同）
const darkModeJs =
    "(function(){var e=document.getElementById('_dk');if(!e){e=document.createElement('style');e.id='_dk';(document.head||document.documentElement).appendChild(e);}e.textContent='html{filter:invert(1) hue-rotate(180deg)!important;background-color:#fff!important}img,video{filter:invert(1) hue-rotate(180deg)!important}'})();";

/// 移除暗色 CSS
const removeDarkModeJs =
    "(function(){var e=document.getElementById('_dk');if(e)e.remove();})();";
