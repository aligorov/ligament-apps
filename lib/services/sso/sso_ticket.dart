// Публичный API чтения sso-билета (фаза 2 Windows-identity).
//
// Модель: билет — доказательство «этот пользователь только что прошёл вход в
// Windows через Ligament CP» (серверный дизайн, docs/windows-identity-server-design.md):
// CP кладёт его в C:\ProgramData\Ligament\sso\<SID>\sso.bin с DACL на SID
// владельца; приложение читает и предъявляет серверу. Любой сбой цепочки —
// тихая деградация (null), обычный вход и работа приложения не страдают.
//
// Реализация подменяется conditional import: не-io платформы получают
// заглушку. Внутри io-реализации есть runtime-гейт Platform.isWindows —
// macOS/Linux тоже собирают dart.library.io, но FFI-к DLL не обращаются.
export 'sso_ticket_stub.dart' if (dart.library.io) 'sso_ticket_io.dart';

class SsoTicket {
  const SsoTicket(this.value);
  final String value;
}

abstract class SsoTicketReader {
  /// Живой билет текущего пользователя или null (нет файла / нет доступа /
  /// не-Windows). Никогда не бросает.
  Future<SsoTicket?> readTicket();
}

/// Путь к файлу билета: <ProgramData>\Ligament\sso\<SID>\sso.bin.
/// Чистая функция — тестируется без Windows.
String buildSsoTicketPath(String programDataRoot, String sid) {
  final root = programDataRoot.endsWith('\\')
      ? programDataRoot.substring(0, programDataRoot.length - 1)
      : programDataRoot;
  return '$root\\Ligament\\sso\\$sid\\sso.bin';
}

/// Сверка машины челленджа browser_sso с текущей машиной.
/// DNS-суффиксы не должны ломать матч: 'ws-001' == 'ws-001.corp.local'.
/// Чистая функция — тестируется без Windows.
bool machineMatches(String? expectedMachine, String? actualMachine) {
  String norm(String s) => s.trim().toLowerCase();
  String short(String s) {
    final n = norm(s);
    final dot = n.indexOf('.');
    return dot == -1 ? n : n.substring(0, dot);
  }

  if (expectedMachine == null || expectedMachine.trim().isEmpty) return false;
  if (actualMachine == null || actualMachine.trim().isEmpty) return false;
  return norm(expectedMachine) == norm(actualMachine) ||
      short(expectedMachine) == short(actualMachine);
}

/// Истёк ли expires_at челленджа (принимает ISO-строку или epoch-секунды).
bool isExpired(dynamic expiresAt, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  DateTime? parsed;
  if (expiresAt is String) {
    parsed = DateTime.tryParse(expiresAt);
  } else if (expiresAt is num) {
    parsed = DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt() * 1000);
  }
  return parsed == null || parsed.isBefore(ref);
}
