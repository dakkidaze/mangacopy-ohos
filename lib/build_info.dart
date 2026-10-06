/// 诊断日志用的构建元数据。
///
/// 优先使用 `--dart-define=APP_VERSION_NAME=…` / `APP_VERSION_CODE=…`；
/// 未注入时回退到与 [pubspec.yaml] 同步的常量，并在日志中标记 [appVersionSource]。
class BuildInfo {
  BuildInfo._();

  static const _versionNameEnv = String.fromEnvironment('APP_VERSION_NAME');
  static const _versionCodeEnv = String.fromEnvironment('APP_VERSION_CODE');
  static const _flutterSdkEnv = String.fromEnvironment('FLUTTER_SDK_VERSION');

  /// pubspec `version:` 的 name 部分；发版时请与 pubspec 保持一致。
  static const _pubspecFallbackName = '1.0.11';
  static const _pubspecFallbackCode = 12;

  static String get versionName =>
      _versionNameEnv.isNotEmpty ? _versionNameEnv : _pubspecFallbackName;

  static int get versionCode {
    if (_versionCodeEnv.isNotEmpty) {
      return int.tryParse(_versionCodeEnv) ?? _pubspecFallbackCode;
    }
    return _pubspecFallbackCode;
  }

  /// `dartDefine` | `pubspecFallback`
  static String get appVersionSource =>
      _versionNameEnv.isNotEmpty ? 'dartDefine' : 'pubspecFallback';

  /// 仅当构建时注入 `FLUTTER_SDK_VERSION` 才有值；否则为 null。
  static String? get flutterSdk =>
      _flutterSdkEnv.isNotEmpty ? _flutterSdkEnv : null;

  /// `dartDefine` | `unavailable`
  static String get flutterSdkSource =>
      _flutterSdkEnv.isNotEmpty ? 'dartDefine' : 'unavailable';
}
