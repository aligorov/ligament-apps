import 'package:package_info_plus/package_info_plus.dart';

/// Единая точка правды о версии приложения (статический fallback).
/// Держится синхронной с `version:` в pubspec.yaml — менять только вместе.
const String kAppVersion = '1.1.29+55';

String _runtimeAppVersion = kAppVersion;

/// Реальная версия приложения (из PackageInfo платформы либо fallback kAppVersion)
String get appVersion => _runtimeAppVersion;

/// Инициализация версии во время старта приложения
Future<void> initAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) {
      _runtimeAppVersion = info.buildNumber.isNotEmpty
          ? '${info.version}+${info.buildNumber}'
          : info.version;
    }
  } catch (_) {
    _runtimeAppVersion = kAppVersion;
  }
}
