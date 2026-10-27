import 'package:package_info_plus/package_info_plus.dart';

/// Единая точка правды о версии приложения (статический fallback).
/// Держится синхронной с `version:` в pubspec.yaml — менять только вместе.
const String kAppVersion = '1.1.153+179';

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

String formatAppVersion(String version) {
  var value = version.trim();
  final buildIndex = value.indexOf('+');
  if (buildIndex >= 0) value = value.substring(0, buildIndex);
  if (value.isEmpty || value.startsWith('v')) return value;
  return 'v$value';
}

bool isAppUpdateAvailable(String current, String latest) {
  final currentParsed = _parseAppVersion(current);
  final latestParsed = _parseAppVersion(latest);
  if (currentParsed == null || latestParsed == null) return false;

  final length = currentParsed.numbers.length > latestParsed.numbers.length
      ? currentParsed.numbers.length
      : latestParsed.numbers.length;
  for (var i = 0; i < length; i++) {
    final currentPart =
        i < currentParsed.numbers.length ? currentParsed.numbers[i] : 0;
    final latestPart =
        i < latestParsed.numbers.length ? latestParsed.numbers[i] : 0;
    if (currentPart != latestPart) return currentPart < latestPart;
  }

  if (currentParsed.preRelease == latestParsed.preRelease) return false;
  if (currentParsed.preRelease.isEmpty) return false;
  if (latestParsed.preRelease.isEmpty) return true;
  return currentParsed.preRelease.compareTo(latestParsed.preRelease) < 0;
}

typedef _ParsedAppVersion = ({List<int> numbers, String preRelease});

_ParsedAppVersion? _parseAppVersion(String version) {
  var value = version.trim();
  if (value.startsWith('v')) value = value.substring(1);
  final buildIndex = value.indexOf('+');
  if (buildIndex >= 0) value = value.substring(0, buildIndex);

  var preRelease = '';
  final preReleaseIndex = value.indexOf('-');
  if (preReleaseIndex >= 0) {
    preRelease = value.substring(preReleaseIndex + 1);
    value = value.substring(0, preReleaseIndex);
  }

  final parts = value.split('.');
  if (parts.length < 2 || parts.length > 4) return null;
  final numbers = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^[0-9]+$').hasMatch(part)) return null;
    final number = int.tryParse(part);
    if (number == null) return null;
    numbers.add(number);
  }
  return (numbers: numbers, preRelease: preRelease);
}
