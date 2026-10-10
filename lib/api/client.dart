import 'dart:convert';
import 'package:http/http.dart' as http;

import '../app_version.dart';

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  ApiException(this.statusCode, this.code, [this.message = '']);

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}

class ApiClient {
  /// Максимальное время выполнения любого HTTP-запроса.
  /// Защищает UI от вечного спиннера при сетевых проблемах.
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Локальный IP и хостнейм клиента для телеметрии и заголовков
  static String? clientInternalIP;
  static String? clientHostname;

  String baseUrl;
  String? token;

  ApiClient({required this.baseUrl, this.token});

  Future<http.Response> _get(String url, {Map<String, String>? headers}) {
    return http.get(Uri.parse(url), headers: headers).timeout(_requestTimeout);
  }

  Future<http.Response> _post(String url, {Map<String, String>? headers, String? body}) {
    return http
        .post(Uri.parse(url), headers: headers, body: body)
        .timeout(_requestTimeout);
  }

  Future<http.Response> _put(String url, {Map<String, String>? headers, String? body}) {
    return http
        .put(Uri.parse(url), headers: headers, body: body)
        .timeout(_requestTimeout);
  }

  String _cleanUrl(String path) {
    var base = baseUrl.trim();
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    return '$base$path';
  }

  Map<String, String> _headers() {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (token != null && token!.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    if (clientInternalIP != null && clientInternalIP!.isNotEmpty) {
      h['X-Ligament-Internal-IP'] = clientInternalIP!;
    }
    if (clientHostname != null && clientHostname!.isNotEmpty) {
      h['X-Ligament-Hostname'] = clientHostname!;
    }
    return h;
  }

  /// Определение внешнего IP-адреса через эндпоинт сервера 2FA
  Future<Map<String, dynamic>> getMyIP() async {
    try {
      final res = await _get(_cleanUrl('/api/v1/app/my-ip'), headers: _headers());
      if (res.statusCode == 200) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  List<Map<String, dynamic>> relays = [];

  /// Получение базовой конфигурации сервера
  Future<Map<String, dynamic>> getConfig() async {
    final res = await _get(_cleanUrl('/api/v1/app/config'));
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (data['relays'] is List) {
        relays = (data['relays'] as List).whereType<Map<String, dynamic>>().toList();
      }
      return data;
    }
    throw ApiException(res.statusCode, 'config_error');
  }

  /// Проверка доступности локального Relay-узла (только HTTPS: по открытому
  /// HTTP статус-ответ может подменить активный MITM)
  static Future<Map<String, dynamic>?> probeRelay(String ip, {int port = 8082}) async {
    try {
      final res = await http
          .get(Uri.parse('https://$ip:$port/api/v1/status'))
          .timeout(const Duration(milliseconds: 1500));
      if (res.statusCode == 200) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  /// Авторизация устройства в приложении
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? code,
    required String deviceName,
    required String platform,
    String osVersion = '',
    String appVersion = kAppVersion,
    String pushToken = '',
    Map<String, dynamic>? securityPosture,
    Map<String, dynamic>? windowsIdentity,
  }) async {
    final payload = {
      'username': username,
      'password': password,
      if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
      'device_name': deviceName,
      'platform': platform,
      'os_version': osVersion,
      'app_version': appVersion,
      'push_token': pushToken,
      'security_posture': securityPosture ?? {},
      // Аттестация Windows-сессии (desktop): кто за машиной на самом деле —
      // для мониторинга/аудита на сервере. null = не Windows.
      if (windowsIdentity != null) 'windows_identity': windowsIdentity,
    };

    final res = await _post(
      _cleanUrl('/api/v1/app/login'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      token = data['token'] as String?;
      return data;
    }
    throw ApiException(res.statusCode, data['error']?.toString() ?? 'login_failed');
  }

  /// Выход устройства (деактивация сессии)
  Future<void> logout() async {
    try {
      await _post(
        _cleanUrl('/api/v1/app/logout'),
        headers: _headers(),
      );
    } finally {
      token = null;
    }
  }

  /// Обновление APNs/FCM push-токена
  Future<void> updatePushToken(String pushToken) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/device/push-token'),
      headers: _headers(),
      body: jsonEncode({'push_token': pushToken}),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'push_token_update_failed');
    }
  }

  /// Передача снимка безопасности (телеметрии) устройства
  Future<bool> sendTelemetry(Map<String, dynamic> posture) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/telemetry'),
      headers: _headers(),
      body: jsonEncode({'security_posture': posture}),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return data['is_compliant'] == true;
    }
    throw ApiException(res.statusCode, 'telemetry_failed');
  }

  /// Получение активных запросов на подтверждение входа
  Future<List<Map<String, dynamic>>> getPendingChallenges() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/challenges/pending'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'challenges_fetch_failed');
  }

  /// Принятие решения по запросу авторизации: approve или deny
  Future<void> challengeDecision({
    required String challengeId,
    required String decision,
    String? numberMatch,
    String? code,
    bool? passkey,
  }) async {
    final payload = <String, dynamic>{
      'decision': decision,
    };
    if (numberMatch != null && numberMatch.isNotEmpty) {
      payload['number_match'] = numberMatch;
    }
    if (code != null && code.trim().isNotEmpty) {
      payload['code'] = code.trim();
    }
    if (passkey == true) {
      payload['passkey'] = true;
    }

    final res = await _post(
      _cleanUrl('/api/v1/app/challenges/$challengeId/decision'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    if (res.statusCode != 200) {
      String code = 'decision_failed';
      try {
        final errObj = jsonDecode(utf8.decode(res.bodyBytes));
        code = errObj['error']?.toString() ?? code;
      } catch (_) {}
      throw ApiException(res.statusCode, code);
    }
  }

  /// Предъявление CP-билета Windows-идентичности (фаза 2):
  /// POST /api/v1/app/sso-ticket {"ticket": ...}. Коды: 200 — погашен
  /// (expires_at в ответе), 401/409 — невалиден/истёк, 404 — сервер ещё не
  /// поддерживает, 429 — rate-limit 1/мин. Все ошибки наверх НЕ бросаются —
  /// возвращает код+expiresAt, интерпретирует SsoTicketFlow.
  Future<(int, DateTime?)> submitSsoTicket(String ticket) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/sso-ticket'),
      headers: _headers(),
      body: jsonEncode({'ticket': ticket}),
    );
    DateTime? expiresAt;
    try {
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['expires_at'] ?? data['expiresAt'];
        if (raw is String) {
          expiresAt = DateTime.tryParse(raw)?.toLocal();
        } else if (raw is num) {
          expiresAt = DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
        }
      }
    } catch (_) {}
    return (res.statusCode, expiresAt);
  }

  /// Решение по browser_sso-челленджу (фаза 2b, контракт финален):
  /// approve — ВСЕГДА с живым билетом, deny — без билета.
  /// Payload: {"action":"approve","sso_ticket":...} / {"action":"deny"}.
  Future<void> browserSsoDecision({
    required String challengeId,
    required bool approve,
    String? ssoTicket,
  }) async {
    final payload = <String, dynamic>{
      'action': approve ? 'approve' : 'deny',
    };
    if (approve && ssoTicket != null && ssoTicket.isNotEmpty) {
      payload['sso_ticket'] = ssoTicket;
    }

    final res = await _post(
      _cleanUrl('/api/v1/app/challenges/$challengeId/decision'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    if (res.statusCode != 200) {
      String code = 'decision_failed';
      try {
        final errObj = jsonDecode(utf8.decode(res.bodyBytes));
        code = errObj['error']?.toString() ?? code;
      } catch (_) {}
      throw ApiException(res.statusCode, code);
    }
  }

  /// Профиль текущего пользователя
  Future<Map<String, dynamic>> getProfile() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/me/profile'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'profile_fetch_failed');
  }

  /// Обновление настроек уведомлений пользователя
  Future<Map<String, dynamic>> updateNotificationSettings({
    required bool loginSuccess,
    required bool loginDenied,
    required bool notifyTG,
    required bool notifyEmail,
  }) async {
    final payload = {
      'login_success': loginSuccess,
      'login_denied': loginDenied,
      'notify_tg': notifyTG,
      'notify_email': notifyEmail,
    };
    final res = await _put(
      _cleanUrl('/api/v1/app/me/notifications'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'notifications_update_failed');
  }

  /// Проверка реальной доставки тестового уведомления
  Future<List<Map<String, dynamic>>> testNotificationDelivery() async {
    final res = await _post(
      _cleanUrl('/api/v1/app/me/notifications/test'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (data['results'] as List<dynamic>?) ?? [];
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'notifications_test_failed');
  }

  /// Получение списка уведомлений пользователя (Inbox)
  Future<List<Map<String, dynamic>>> getNotifications({int limit = 50}) async {
    final res = await _get(
      _cleanUrl('/api/v1/app/me/notifications?limit=$limit'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (data['notifications'] as List<dynamic>?) ?? [];
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'notifications_fetch_failed');
  }

  /// Отметка уведомления как доставленного
  Future<void> markNotificationDelivered(String id) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/me/notifications/$id/delivered'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'notification_delivered_failed');
    }
  }

  /// Отметка уведомления как прочитанного
  Future<void> markNotificationRead(String id) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/me/notifications/$id/read'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'notification_read_failed');
    }
  }

  /// Отметка всех уведомлений как прочитанных
  Future<void> markAllNotificationsRead() async {
    final res = await _post(
      _cleanUrl('/api/v1/app/me/notifications/read-all'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'notifications_read_all_failed');
    }
  }

  /// Список доступных корпоративных приложений (SSO Launchpad)
  Future<List<Map<String, dynamic>>> getAllowedApps() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/me/apps'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'apps_fetch_failed');
  }

  /// История недавних входов пользователя (аудит-лог)
  Future<List<Map<String, dynamic>>> getHistory() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/me/history'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'history_fetch_failed');
  }

  /// Запрос экстренной удаленной помощи (SOS)
  Future<Map<String, dynamic>> requestSupport({
    required String category,
    required String problemSummary,
    String accessMode = 'full_control',
  }) async {
    final payload = {
      'category': category,
      'problem_summary': problemSummary,
      'access_mode': accessMode,
    };

    final res = await _post(
      _cleanUrl('/api/v1/app/support/request'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      return data;
    }
    throw ApiException(res.statusCode, data['error']?.toString() ?? 'support_request_failed');
  }

  /// Получение текущей активной сессии поддержки
  Future<Map<String, dynamic>?> getCurrentSupportSession() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/support/current'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (data['active'] == true) {
        return data['session'] as Map<String, dynamic>?;
      }
      return null;
    }
    throw ApiException(res.statusCode, 'support_current_fetch_failed');
  }

  /// Решение пользователя по запросу на подключение к экрану (approve / deny)
  Future<void> supportDecision({
    required String sessionId,
    required String decision,
    String? numberMatch,
  }) async {
    final payload = <String, dynamic>{
      'decision': decision,
    };
    if (numberMatch != null && numberMatch.isNotEmpty) {
      payload['number_match'] = numberMatch;
    }

    final res = await _post(
      _cleanUrl('/api/v1/app/support/$sessionId/decision'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    if (res.statusCode != 200) {
      String code = 'decision_failed';
      try {
        final errObj = jsonDecode(utf8.decode(res.bodyBytes));
        code = errObj['error']?.toString() ?? code;
      } catch (_) {}
      throw ApiException(res.statusCode, code);
    }
  }

  /// Отправка WebRTC сигнального пакета оператору поддержки
  Future<void> sendSupportSignal({
    required String sessionId,
    required Map<String, dynamic> signal,
  }) async {
    // M-3: файловые передачи запрещены через HTTP-сигнальный шлюз —
    // только через WebRTC DataChannel (см. SupportService._sendSignalOrData).
    final type = signal['type']?.toString() ?? '';
    if (type.startsWith('file_')) {
      throw ArgumentError('file_* сигналы не отправляются через HTTP-fallback: $type');
    }
    final res = await _post(
      _cleanUrl('/api/v1/app/support/$sessionId/signal'),
      headers: _headers(),
      body: jsonEncode(signal),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'signal_failed');
    }
  }

  /// Получение истории сообщений чата сессии поддержки
  Future<List<Map<String, dynamic>>> getSupportMessages(String sessionId) async {
    http.Response res;
    try {
      res = await _get(
        _cleanUrl('/api/v1/app/support/$sessionId/messages'),
        headers: _headers(),
      );
    } catch (_) {
      res = await _get(
        _cleanUrl('/api/v1/support/sessions/$sessionId/messages'),
        headers: _headers(),
      );
    }
    if (res.statusCode != 200) {
      res = await _get(
        _cleanUrl('/api/v1/support/sessions/$sessionId/messages'),
        headers: _headers(),
      );
    }
    if (res.statusCode != 200) {
      return [];
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is Map<String, dynamic> && data['messages'] is List) {
      return (data['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList();
    }
    return [];
  }

  /// Отправка сообщения в чат поддержки
  Future<void> sendSupportChatMessage({
    required String sessionId,
    required String text,
    String? senderName,
    String? clientId,
  }) async {
    final body = jsonEncode({
      'text': text,
      if (senderName != null && senderName.isNotEmpty) 'sender_name': senderName,
      // Идемпотентный ключ (0074): повторная запись той же пары
      // (session_id, client_id) на сервере — no-op, дублей в чате нет.
      if (clientId != null && clientId.isNotEmpty) 'client_id': clientId,
    });
    http.Response res;
    try {
      res = await _post(
        _cleanUrl('/api/v1/app/support/$sessionId/messages'),
        headers: _headers(),
        body: body,
      );
      if (res.statusCode != 200) {
        res = await _post(
          _cleanUrl('/api/v1/support/sessions/$sessionId/messages'),
          headers: _headers(),
          body: body,
        );
      }
    } catch (_) {
      res = await _post(
        _cleanUrl('/api/v1/support/sessions/$sessionId/messages'),
        headers: _headers(),
        body: body,
      );
    }
    if (res.statusCode != 200) {
      // Fallback на /signal
      await sendSupportSignal(
        sessionId: sessionId,
        signal: {
          'type': 'chat_message',
          'text': text,
          'sender_name': senderName ?? 'Пользователь',
          if (clientId != null && clientId.isNotEmpty) 'client_id': clientId,
        },
      );
    }
  }

  /// Завершение сеанса удаленного доступа со стороны пользователя
  Future<void> endSupportSession({
    required String sessionId,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/support/$sessionId/end'),
      headers: _headers(),
    ).timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'end_support_failed');
    }
  }

  /// Завершение сессии ОПЕРАТОРОМ (инженером): app-токен, сервер пускает
  /// админа/engineer-роли и владельца (checkOperatorAuth). Прежний путь
  /// /app/support/{id}/end для оператора всегда давал 403 (только владелец)
  /// — «завершённая» оператором сессия висела active в очереди часами.
  Future<void> endSupportSessionAsOperator({
    required String sessionId,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/support/sessions/$sessionId/end'),
      headers: _headers(),
    ).timeout(const Duration(seconds: 4));
    if (res.statusCode == 409) {
      return; // уже терминальная — повторное закрытие не ошибка
    }
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'end_support_failed');
    }
  }

  /// Получение активных категорий поддержки (IT, 1C и др.)
  Future<List<Map<String, dynamic>>> getSupportCategories() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/support/categories'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = data['categories'] as List<dynamic>? ?? [];
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Получение очереди входящих SOS-обращений для инженера
  Future<List<Map<String, dynamic>>> getSupportQueue() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/support/queue'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is List) {
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } else if (decoded is Map) {
        final list = (decoded['queue'] ?? decoded['sessions']) as List<dynamic>? ?? [];
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    }
    return [];
  }

  // ---- RDP Access Gateway (этап 2: /api/v1/app/rdp/*) ----

  /// Мои RDP-цели («Мой ПК», этап 2.1): GET /api/v1/app/rdp/targets.
  ///
  /// 404 трактуются вызывающей стороной как «фича не смонтирована на
  /// сервере» (free-лицензия) — возвращаем пустой список, секция на главной
  /// скрывается. Коды ошибок пробрасываются ApiException'ом с серверным
  /// code (db_error и т.п.).
  Future<List<Map<String, dynamic>>> getRdpTargets({String? instanceId}) async {
    final query = (instanceId != null && instanceId.isNotEmpty)
        ? '?instance_id=${Uri.encodeQueryComponent(instanceId)}'
        : '';
    final res = await _get(
      _cleanUrl('/api/v1/app/rdp/targets$query'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (data['targets'] as List<dynamic>?);
      if (list == null) return [];
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (res.statusCode == 404) {
      // Фича выключена на этом сервере — не ошибка, просто пусто.
      return [];
    }
    throw ApiException(res.statusCode, 'rdp_targets_fetch_failed');
  }

  /// Одноразовый грант доступа к цели: POST /api/v1/app/rdp/grant.
  ///
  /// Ответ 201: {grant_id, token (64 hex = 32 байта), route, expires_in}.
  /// Серверные ошибки пробрасываются как ApiException с точным кодом:
  /// 403 target_not_assigned | 403 passkey_required | 428 mfa_required |
  /// 409 target_busy | 500 db_error — UI мапит их в человеческий текст.
  /// Выдача одноразового гранта доступа RDP/Экран: POST /api/v1/app/rdp/grant.
  /// 403 target_not_assigned | 403 passkey_required | 428 mfa_required |
  /// 409 target_busy | 500 db_error — UI мапит их в человеческий текст.
  Future<Map<String, dynamic>> rdpGrant({
    required String targetId,
    String mode = 'rdp',
    String? code,
    String? actionId,
    String? sourceInstanceId,
    String? attemptId,
    bool? passkey,
    List<String>? clientLocalIps,
  }) async {
    final payload = <String, dynamic>{
      'target_id': targetId,
      'mode': mode,
      if (code != null && code.isNotEmpty) 'code': code,
      if (actionId != null && actionId.isNotEmpty) 'action_id': actionId,
      if (sourceInstanceId != null && sourceInstanceId.isNotEmpty) 'source_instance_id': sourceInstanceId,
      if (attemptId != null && attemptId.isNotEmpty) 'attempt_id': attemptId,
      if (passkey == true) 'passkey': true,
      if (clientLocalIps != null && clientLocalIps.isNotEmpty) 'client_local_ips': clientLocalIps,
    };
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/grant'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'grant_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Активация прямого локального RDP-сеанса (LAN/VPN) без WSS-туннеля ядра.
  Future<Map<String, dynamic>> rdpDirectClaim({
    required String grantId,
    required String token,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/direct-claim'),
      headers: _headers(),
      body: jsonEncode({
        'grant_id': grantId,
        'token': token,
      }),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'direct_claim_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Начало церемонии подтверждения доступа через WebAuthn / Passkey.
  Future<Map<String, dynamic>> rdpMfaPasskeyBegin({
    required String targetId,
    required String mode,
    required String actionId,
    required String sourceInstanceId,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/mfa/passkey-begin'),
      headers: _headers(),
      body: jsonEncode({
        'target_id': targetId,
        'mode': mode,
        'action_id': actionId,
        'source_instance_id': sourceInstanceId,
      }),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'passkey_begin_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Завершение церемонии подтверждения доступа через WebAuthn / Passkey.
  Future<Map<String, dynamic>> rdpMfaPasskeyFinish({
    required String handle,
    required String attemptId,
    required Map<String, dynamic> assertion,
  }) async {
    final body = <String, dynamic>{
      'handle': handle,
      'attempt_id': attemptId,
      ...assertion,
    };
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/mfa/passkey-finish'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'passkey_finish_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Закрыть свой грант и активную сессию: POST /api/v1/app/rdp/close.
  /// Чужой грант → 404 not_found (не ошибка для идемпотентного закрытия).
  Future<void> rdpClose(String grantId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/close'),
      headers: _headers(),
      body: jsonEncode({'grant_id': grantId}),
    );
    if (res.statusCode == 200) return;
    String code = 'close_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      code = errObj['error']?.toString() ?? code;
    } catch (_) {}
    throw ApiException(res.statusCode, code);
  }

  /// Адрес одноразового bridge-порта для гранта (Connector-helper, P1 #3
  /// аудита 2026-10-08): POST /api/v1/app/rdp/bridge-info.
  ///
  /// Ответ 200: {host, port} — TCP-порт моста на ядре; приложение
  /// подключается к нему, ПЕРВЫМИ байтами шлёт hex-токен + "\n" (handshake
  /// порта) и мостит локального mstsc (RdpConnectorService.connectBridge).
  /// Токен идёт телом POST, не в query — секрет не должен оседать в
  /// access-логах прокси (аудит P2). Серверные ошибки: 400 bad_token |
  /// 403 forbidden | 409 bridge_already_open | 410 grant_expired |
  /// 500 bridge_port_error — UI мапит их в человеческий текст.
  Future<Map<String, dynamic>> rdpBridgeInfo({
    required String grantId,
    required String token,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/bridge-info'),
      headers: _headers(),
      body: jsonEncode({'grant_id': grantId, 'token': token}),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String code = 'bridge_info_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      code = errObj['error']?.toString() ?? code;
    } catch (_) {}
    throw ApiException(res.statusCode, code);
  }

  /// Инициация подключения инженера к удаленной сессии из приложения
  Future<Map<String, dynamic>> connectToSupport({
    required String sessionId,
    String? adminName,
  }) async {
    final payload = <String, dynamic>{};
    if (adminName != null && adminName.isNotEmpty) {
      payload['admin_name'] = adminName;
    }
    final res = await _post(
      _cleanUrl('/api/v1/app/support/$sessionId/connect'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'connect_failed');
  }

  /// Регистрация машины доступа: POST /api/v1/app/rdp/machines/register
  Future<Map<String, dynamic>> rdpRegisterMachine({
    String? id,
    String? hostname,
    String? osType,
    String? machinePublicKey,
    String? keyAlgorithm,
    String? enclaveType,
  }) async {
    final payload = <String, dynamic>{
      if (id != null && id.isNotEmpty) 'id': id,
      if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
      if (osType != null && osType.isNotEmpty) 'os_type': osType,
      if (machinePublicKey != null && machinePublicKey.isNotEmpty) 'machine_public_key': machinePublicKey,
      if (keyAlgorithm != null && keyAlgorithm.isNotEmpty) 'key_algorithm': keyAlgorithm,
      if (enclaveType != null && enclaveType.isNotEmpty) 'enclave_type': enclaveType,
    };
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/machines/register'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'machine_register_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Регистрация экземпляра сессии приложения (Sharer/Viewer): POST /api/v1/app/rdp/instances/register
  Future<Map<String, dynamic>> rdpRegisterInstance({
    required String instanceId,
    String? machineId,
    String? installationId,
    String? instancePublicKey,
    String? bootId,
    int? osSessionId,
    int? authLuid,
    String? userSid,
    int? posixUid,
    String? posixDisplay,
    bool canShareScreen = true,
  }) async {
    final payload = <String, dynamic>{
      'instance_id': instanceId,
      if (machineId != null && machineId.isNotEmpty) 'machine_id': machineId,
      if (installationId != null && installationId.isNotEmpty) 'installation_id': installationId,
      if (instancePublicKey != null && instancePublicKey.isNotEmpty) 'instance_public_key': instancePublicKey,
      if (bootId != null && bootId.isNotEmpty) 'boot_id': bootId,
      if (osSessionId != null) 'os_session_id': osSessionId,
      if (authLuid != null) 'auth_luid': authLuid,
      if (userSid != null && userSid.isNotEmpty) 'user_sid': userSid,
      if (posixUid != null) 'posix_uid': posixUid,
      if (posixDisplay != null && posixDisplay.isNotEmpty) 'posix_display': posixDisplay,
      'can_share_screen': canShareScreen,
    };
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/instances/register'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'instance_register_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Heartbeat экземпляра процесса: POST /api/v1/app/rdp/instances/heartbeat
  Future<void> rdpInstanceHeartbeat(String instanceId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/instances/heartbeat'),
      headers: _headers(),
      body: jsonEncode({'instance_id': instanceId}),
    );
    if (res.statusCode == 200) return;
    String errCode = 'heartbeat_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Активация сессии экрана выбранным Sharer: POST /api/v1/app/support/{id}/activate-screen
  Future<Map<String, dynamic>> activateOwnerScreen(String sessionId, String instanceId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/support/$sessionId/activate-screen'),
      headers: _headers(),
      body: jsonEncode({'instance_id': instanceId}),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'activate_screen_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Challenge-response продление media lease активной сессии экрана / Console:
  /// GET /api/v1/app/support/{id}/lease
  Future<Map<String, dynamic>> renewSupportLease(String sessionId) async {
    final res = await _get(
      _cleanUrl('/api/v1/app/support/$sessionId/lease'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    String errCode = 'lease_renew_failed';
    try {
      final errObj = jsonDecode(utf8.decode(res.bodyBytes));
      errCode = errObj['error']?.toString() ?? errCode;
    } catch (_) {}
    throw ApiException(res.statusCode, errCode);
  }

  /// Получение STUN/TURN серверов для WebRTC удаленной помощи:
  /// GET /api/v1/app/ice-servers
  Future<List<Map<String, dynamic>>> getIceServers() async {
    try {
      final res = await _get(
        _cleanUrl('/api/v1/app/ice-servers'),
        headers: _headers(),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final raw = data['ice_servers'];
        if (raw is List) {
          return raw.whereType<Map<String, dynamic>>().toList();
        }
      }
    } catch (_) {}
    return const [];
  }
}

