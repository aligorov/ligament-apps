import 'package:flutter/foundation.dart';

/// Разбор deep-link'ов схемы ligament:// (аудит RDP-11, расширение T6).
///
/// Веб-кабинет открывает приложение кнопкой «Открыть в приложении»:
///   ligament://rdp/<target_uuid>  — контракт T6, «намерение подключиться
///                                   к цели»: приложение САМО вызывает
///                                   POST /api/v1/app/rdp/grant {target_id}
///                                   (device-токен уже в защищённом
///                                   хранилище), при 428 mfa_required
///                                   показывает диалог «войти заново /
///                                   подтвердить», при успехе — обычный
///                                   connect-флоу (connectBridge);
///   ligament://rdp/<grant_id>?t=… — ЛЕГАСИ (аудит RDP-11): bridge-грант,
///                                   созданный веб-сессией, одноразовый
///                                   токен в query. Остаётся рабочим для
///                                   совместимости уже выпущенных ссылок.
///
/// ГРАНТЫ И ТОКЕНЫ ЧЕРЕЗ URI НЕ ПЕРЕДАЮТСЯ НИКОГДА: холодный старт Windows
/// получает URI в argv, а командную строку читает любой процесс (урок
/// аудита) — ссылка несёт ТОЛЬКО целевой UUID.
///
/// Формат:
///   scheme  — строго ligament (иначе ссылка чужая, игнорируем);
///   host    — строго rdp (иные хосты схемы не поддержаны);
///   path    — РОВНО один сегмент: UUID (8-4-4-4-12 hex);
///   query   — одноразовый токен гранта (t / token) — только легаси-формат.
///
/// Разграничение контрактов: и target_uuid, и grant_id лежат в одном
/// сегменте пути и синтаксически неразличимы, поэтому семантику выбирает
/// наличие grant-токена в query — токен бывает только у легаси-ссылок
/// (новый контракт токенов не несёт). Токен без гранта-легаси смысла не
/// имеет, грант без токена — это и есть целевой UUID.
///
/// Чистая функция — покрыта тестами без платформы (test/deep_link_test.dart).

/// Семантика UUID в path-сегменте ссылки ligament://rdp/<uuid>.
enum LigamentDeepLinkKind {
  /// <target_uuid>: приложение само берёт грант у сервера своим
  /// device-токеном (T6). Токена в query нет.
  target,

  /// Легаси <grant_id>?t=<token>: bridge-грант веб-кабинета + одноразовый
  /// токен из query (аудит RDP-11).
  grant,
}

class LigamentDeepLink {
  const LigamentDeepLink({
    required this.kind,
    required this.uuid,
    this.grantToken,
  });

  /// Семантика UUID: намерение подключиться к цели (T6) либо легаси-грант.
  final LigamentDeepLinkKind kind;

  /// Единственный path-сегмент (нормализован к нижнему регистру):
  /// UUID цели в [LigamentDeepLinkKind.target], UUID гранта в grant.
  final String uuid;

  /// Одноразовый токен гранта (query t=/token=) — только в легаси-режиме
  /// [LigamentDeepLinkKind.grant]. null в target-режиме и у легаси-ссылок
  /// без токена (такие больше не поддержаны: см. контракт выше).
  final String? grantToken;

  /// UUID цели — непуст только в target-режиме (T6).
  String? get targetId => kind == LigamentDeepLinkKind.target ? uuid : null;

  /// UUID гранта — непуст только в легаси-режиме.
  String? get grantId => kind == LigamentDeepLinkKind.grant ? uuid : null;
}

/// UUID: 8-4-4-4-12 hex-символов (строчные/прописные). Подходит и для
/// target_uuid, и для легаси grant_id.
final RegExp _uuidPattern = RegExp(
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
  if (segments.length != 1) return null; // ровно один сегмент — UUID
  final uuid = segments.first;
  if (!_uuidPattern.hasMatch(uuid)) return null;
  final token =
      uri.queryParameters['token'] ?? uri.queryParameters['t'] ?? '';
  final normalizedToken = token.trim();
  if (normalizedToken.isEmpty) {
    // Контракт T6: без токена UUID — намерение подключиться к цели;
    // приложение само получит грант (никаких секретов в URI).
    return LigamentDeepLink(
        kind: LigamentDeepLinkKind.target, uuid: uuid.toLowerCase());
  }
  // Легаси: токен в query означает bridge-грант веб-кабинета.
  return LigamentDeepLink(
    kind: LigamentDeepLinkKind.grant,
    uuid: uuid.toLowerCase(),
    grantToken: normalizedToken,
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
  if (parsed == null) {
    debugPrint('deep_link: "$raw" → игнорирована');
    return;
  }
  final what = parsed.kind == LigamentDeepLinkKind.target
      ? 'target=${parsed.targetId}'
      : 'grant=${parsed.grantId} token=${parsed.grantToken == null ? "нет" : "есть"}';
  debugPrint('deep_link: "$raw" → $what');
}
