import 'package:flutter/foundation.dart';

/// Разбор deep-link'ов схемы ligament:// (аудит RDP-11).
///
/// Веб-кабинет открывает приложение кнопкой «Открыть в приложении»:
///   ligament://rdp/<grant_id>
/// — запуск приложения по схеме регистрируется платформой (MSI на Windows,
/// intent-filter на Android, CFBundleURLTypes на iOS), а ЭТА точка —
/// единый разбор URI на стороне Dart: холодный старт Windows получает
/// URI в argv (windows/runner/main.cpp уже пробрасывает аргументы в
/// main(List<String> args)), мобильные платформы доставят ссылку
/// intent'ом/URL-событием (нужен events-плагин — этап следующий).
///
/// Формат:
///   scheme  — строго ligament (иначе ссылка чужая, игнорируем);
///   host    — строго rdp (иные хосты схемы не поддержаны);
///   path    — РОВНО один сегмент: UUID гранта (8-4-4-4-12 hex);
///   query   — необязательный одноразовый токен гранта (t / token),
///             без него bridge-подключение невозможно (см. RdpConnector
///             Service.connectBridge).
///
/// Чистая функция — покрыта тестами без платформы (test/deep_link_test.dart).
class LigamentDeepLink {
  const LigamentDeepLink({required this.grantId, this.grantToken});

  /// UUID гранта RDP-сессии, созданного в веб-кабинете.
  final String grantId;

  /// Одноразовый токен гранта (query t=/token=), если веб-кабинет его
  /// передал. null — подключение по гранту без токена невозможно.
  final String? grantToken;
}

/// UUID гранта: 8-4-4-4-12 hex-символов (строчные/прописные).
final RegExp _grantIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Единая точка разбора URI схемы ligament://. Возвращает null на любом
/// отклонении от контракта: чужая схема, чужой/неизвестный host, не-UUID
/// в пути, мусорный URI — такие ссылки молча игнорируются (без крашей
/// и без диалогов).
LigamentDeepLink? parseLigamentDeepLink(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() != 'ligament') return null; // чужая схема
  if (uri.host.toLowerCase() != 'rdp') return null; // чужой/неизвестный host
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1) return null; // ровно один сегмент — grant UUID
  final grantId = segments.first;
  if (!_grantIdPattern.hasMatch(grantId)) return null;
  final token =
      uri.queryParameters['token'] ?? uri.queryParameters['t'] ?? '';
  return LigamentDeepLink(
    grantId: grantId.toLowerCase(),
    grantToken: token.trim().isEmpty ? null : token.trim(),
  );
}

/// Выделение ligament://-ссылки из аргументов командной строки (холодный
/// старт Windows: ОС подставляет URI в argv). null — ссылки нет.
String? ligamentUriFromArgs(List<String> args) {
  for (final arg in args) {
    final lowered = arg.trim().toLowerCase();
    if (lowered.startsWith('ligament:')) {
      return arg.trim();
    }
  }
  return null;
}

/// Отладочная печать разбора (диагностика «кнопка не открыла приложение»).
void debugLogDeepLink(String raw, LigamentDeepLink? parsed) {
  debugPrint('deep_link: "$raw" → ${parsed == null ? "игнорирована" : "grant=${parsed.grantId} token=${parsed.grantToken == null ? "нет" : "есть"}"}');
}
