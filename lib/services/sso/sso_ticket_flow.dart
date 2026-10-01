import 'dart:async';

import 'package:flutter/foundation.dart';

/// Результат предъявления билета серверу (фаза 2).
enum SsoSubmitOutcome {
  /// 200 — сервер погасил jti и поставил identity_proof
  ok,

  /// 401/409 — билет невалиден или истёк: тихо, в лог
  invalid,

  /// 404 — сервер ещё не поддерживает sso-ticket: пропустить и НЕ
  /// повторять до перезапуска приложения
  notEnabled,

  /// 429 — rate-limit сервера (1/мин на устройство)
  rateLimited,

  /// транспортный сбой/другой код: тихо
  network,
}

/// Один «предъявленный» ответ сервера.
class SsoSubmitResponse {
  const SsoSubmitResponse(this.statusCode, {this.expiresAt});
  final int statusCode;
  final DateTime? expiresAt; // из 200-ответа (expires_at)
}

/// Машина состояний предъявления CP-билета.
///
/// Инварианты (серверный дизайн, фаза 2):
/// - после 404 not_enabled попыток больше НЕТ до пересоздания flow;
/// - не чаще одного раза в минуту (покрывает и серверный 429, и наши ретраи);
/// - любой сбой — тихая деградация, UI не беспокоим.
class SsoTicketFlow {
  SsoTicketFlow({required this.submit});

  /// Инжектится ApiClient (тесты подставляют мок).
  final Future<SsoSubmitResponse?> Function(String ticket) submit;

  bool _serverNotEnabled = false;
  DateTime? _lastAttemptAt;
  DateTime? _verifiedUntil;

  /// Статус «подтверждено Windows» для профиля (null — нет подтверждения).
  DateTime? get verifiedUntil => _verifiedUntil;
  bool get isServerNotEnabled => _serverNotEnabled;

  /// Предъявить билет. Возвращает null, если попытка не выполнялась
  /// (нет билета / cooldown / сервер не поддерживает).
  Future<SsoSubmitOutcome?> present(String? ticket) async {
    if (ticket == null || ticket.isEmpty) return null;
    if (_serverNotEnabled) return null;

    final now = DateTime.now();
    if (_lastAttemptAt != null &&
        now.difference(_lastAttemptAt!) < const Duration(minutes: 1)) {
      return null;
    }
    _lastAttemptAt = now;

    SsoSubmitResponse? resp;
    try {
      resp = await submit(ticket);
    } catch (e) {
      debugPrint('sso_ticket_flow: транспортная ошибка: $e');
      return SsoSubmitOutcome.network;
    }
    if (resp == null) return SsoSubmitOutcome.network;

    switch (resp.statusCode) {
      case 200:
        _verifiedUntil = resp.expiresAt;
        return SsoSubmitOutcome.ok;
      case 404:
        _serverNotEnabled = true;
        debugPrint('sso_ticket_flow: сервер не поддерживает sso-ticket (404) — до перезапуска не повторяем');
        return SsoSubmitOutcome.notEnabled;
      case 401:
      case 409:
        debugPrint('sso_ticket_flow: билет невалиден/истёк (${resp.statusCode})');
        return SsoSubmitOutcome.invalid;
      case 429:
        debugPrint('sso_ticket_flow: rate-limit сервера (429)');
        return SsoSubmitOutcome.rateLimited;
      default:
        return SsoSubmitOutcome.network;
    }
  }
}
