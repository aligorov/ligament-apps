import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../app_version.dart';
import '../models/link_enrollment_credential.dart';
import '../services/debug_log_service.dart';

class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  ApiException(this.statusCode, this.code, [this.message = '', this.details]);

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}

/// Заявка SOS в полях карточки очереди инженера.
Map<String, dynamic> sosQueueItem(Map<String, dynamic> request) {
  final displayName = request['requester_display_name']?.toString() ?? '';
  final hostname = request['target_hostname']?.toString() ?? '';
  return {
    ...request,
    'sos_v2': true,
    if (displayName.isNotEmpty) 'display_name': displayName,
    'username': request['requester_username'],
    if (hostname.isNotEmpty) 'pc_name': hostname,
    'access_mode': 'full_control',
  };
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

  ApiClient({required this.baseUrl, this.token, DebugLogService? debugLogs})
      : _debugLogs = debugLogs ?? DebugLogService.instance;

  final DebugLogService _debugLogs;

  static const _routeParts = {
    'api',
    'v1',
    'app',
    'me',
    'config',
    'version',
    'login',
    'login-claim',
    'logout',
    'profile',
    'apps',
    'history',
    'challenges',
    'pending',
    'decision',
    'notifications',
    'read',
    'read-all',
    'test',
    'settings',
    'support',
    'request',
    'current',
    'signal',
    'signals',
    'connect',
    'end',
    'chat',
    'messages',
    'queue',
    'categories',
    'link',
    'hosts',
    'agents',
    'enroll',
    'enrollment-token',
    'sessions',
    'participants',
    'heartbeat',
    'close',
    'archive',
    'restore',
    'groups',
    'access',
    'unattended',
    'bind',
    'unbind',
    'sos',
    'requests',
    'claim',
    'start',
    'cancel',
    'ice-servers',
    'step-up',
    'verify',
    'rdp',
    'targets',
    'grant',
    'direct-claim',
    'bridge-info',
    'machines',
    'instances',
    'register',
    'mfa',
    'passkey-start',
    'passkey-finish',
    'browser-sso',
    'sso-ticket',
    'windows-identity',
    'notification-settings',
    'test-delivery',
    'my-ip',
    'device',
    'push-token',
    'telemetry',
    'delivered',
    'group-access',
    'stepup',
    'passkey-begin',
    'activate-screen',
    'lease',
    'status',
  };

  static String debugRoute(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '/unknown';
    return '/${uri.pathSegments.map((part) => _routeParts.contains(part) ? part : '{id}').join('/')}';
  }

  Future<http.Response> _request(
      String method, String url, Future<http.Response> Function(Map<String, String> headers) send,
      {Map<String, String>? headers, String? body, Duration timeout = _requestTimeout}) async {
    final id = _debugLogs.nextRequestId();
    final timer = Stopwatch()..start();
    final uri = Uri.tryParse(url);
    final effectiveHeaders = Map<String, String>.from(headers ?? _headers());
    effectiveHeaders.putIfAbsent('X-Request-ID', () => 'req-$id');
    final fields = <String, Object?>{
      'request_id': id,
      'method': method,
      'route': debugRoute(url),
      'server': uri == null
          ? null
          : uri.hasPort
              ? '${uri.host}:${uri.port}'
              : uri.host,
      'transport': uri?.scheme,
      'sent_bytes': body == null ? 0 : utf8.encode(body).length,
    };
    _debugLogs.record('http.request', fields: fields);
    try {
      final response = await send(effectiveHeaders).timeout(timeout);
      timer.stop();
      final error =
          response.statusCode >= 400 && response.bodyBytes.length <= 64 * 1024
              ? _decodeJsonMap(response.bodyBytes)['error']
              : null;
      _debugLogs.record('http.response', fields: {
        ...fields,
        'http_status': response.statusCode,
        'duration_ms': timer.elapsedMilliseconds,
        'response_bytes': response.bodyBytes.length,
        'result': response.statusCode < 400 ? 'received' : 'http_error',
        if (error is String) 'reason': DebugLogService.protocolLabel(error),
      });
      return response;
    } catch (error) {
      timer.stop();
      _debugLogs.record('http.failed', error: error, fields: {
        ...fields,
        'duration_ms': timer.elapsedMilliseconds,
        'result': 'transport_error',
      });
      rethrow;
    }
  }

  Future<http.Response> _get(String url, {Map<String, String>? headers}) {
    return _request(
        'GET', url, (h) => http.get(Uri.parse(url), headers: h),
        headers: headers);
  }

  Future<http.Response> _post(String url,
      {Map<String, String>? headers, String? body}) {
    return _request('POST', url,
        (h) => http.post(Uri.parse(url), headers: h, body: body),
        headers: headers, body: body);
  }

  Future<http.Response> _put(String url,
      {Map<String, String>? headers, String? body}) {
    return _request('PUT', url,
        (h) => http.put(Uri.parse(url), headers: h, body: body),
        headers: headers, body: body);
  }

  Future<http.Response> _patch(String url,
      {Map<String, String>? headers, String? body}) {
    return _request('PATCH', url,
        (h) => http.patch(Uri.parse(url), headers: h, body: body),
        headers: headers, body: body);
  }

  Future<http.Response> _delete(String url, {Map<String, String>? headers}) {
    return _request(
        'DELETE', url, (h) => http.delete(Uri.parse(url), headers: h),
        headers: headers);
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
    if (appVersion.isNotEmpty) {
      h['X-App-Version'] = appVersion;
    }
    if (clientInternalIP != null && clientInternalIP!.isNotEmpty) {
      h['X-Ligament-Internal-IP'] = clientInternalIP!;
    }
    if (clientHostname != null && clientHostname!.isNotEmpty) {
      h['X-Ligament-Hostname'] = clientHostname!;
    }
    return h;
  }

  /// Версии приложений (сервер v0.8.175+): текущая устройства против
  /// последнего релиза GitHub + ссылка обновления. При недоступности
  /// сервера или пустом ответе обращается напрямую к GitHub Releases API.
  Future<Map<String, dynamic>?> getAppVersion() async {
    try {
      final res =
          await _get(_cleanUrl('/api/v1/app/version'), headers: _headers());
      if (res.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final latest = data['latest']?.toString() ?? '';
        if (latest.isNotEmpty) {
          return data;
        }
      }
    } catch (_) {}

    // Fallback: прямой запрос к GitHub Releases API при отсутствии данных от сервера
    try {
      final uri = Uri.parse(
          'https://api.github.com/repos/aligorov/ligament-apps/releases/latest');
      final res = await http.get(uri, headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Ligament-2FA/$appVersion',
      }).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final tagName = data['tag_name']?.toString() ?? '';
        final htmlUrl = data['html_url']?.toString() ??
            'https://github.com/aligorov/ligament-apps/releases/latest';
        if (tagName.isNotEmpty) {
          return {
            'current': appVersion,
            'latest': tagName,
            'update_available': isAppUpdateAvailable(appVersion, tagName),
            'release_url': htmlUrl,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  /// Определение внешнего IP-адреса через эндпоинт сервера 2FA
  Future<Map<String, dynamic>> getMyIP() async {
    try {
      final res =
          await _get(_cleanUrl('/api/v1/app/my-ip'), headers: _headers());
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (data['relays'] is List) {
        relays =
            (data['relays'] as List).whereType<Map<String, dynamic>>().toList();
      }
      return data;
    }
    throw ApiException(res.statusCode, 'config_error');
  }

  /// Проверка доступности локального Relay-узла (только HTTPS: по открытому
  /// HTTP статус-ответ может подменить активный MITM)
  static Future<Map<String, dynamic>?> probeRelay(String ip,
      {int port = 8082}) async {
    final client = ApiClient(baseUrl: 'https://$ip:$port');
    final url = client._cleanUrl('/api/v1/status');
    try {
      final res = await client._request(
          'GET', url, (h) => http.get(Uri.parse(url), headers: h),
          timeout: const Duration(milliseconds: 1500));
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
    throw ApiException(
        res.statusCode, data['error']?.toString() ?? 'login_failed', '', data);
  }

  /// Обмен подтверждённого push-челленджа на Bearer-токен устройства
  Future<Map<String, dynamic>> loginClaim({
    required String challengeId,
    required String claimToken,
    required String deviceName,
    required String platform,
    String osVersion = '',
    String appVersion = kAppVersion,
    String pushToken = '',
    Map<String, dynamic>? securityPosture,
    Map<String, dynamic>? windowsIdentity,
    bool updateToken = true,
  }) async {
    final payload = {
      'challenge_id': challengeId,
      'claim_token': claimToken,
      'device_name': deviceName,
      'platform': platform,
      'os_version': osVersion,
      'app_version': appVersion,
      'push_token': pushToken,
      'security_posture': securityPosture ?? {},
      if (windowsIdentity != null) 'windows_identity': windowsIdentity,
    };

    final res = await _post(
      _cleanUrl('/api/v1/app/login/claim'),
      headers: _headers(),
      body: jsonEncode(payload),
    );

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) {
      if (updateToken && data['token'] != null) {
        token = data['token'] as String?;
      }
      return data;
    }
    throw ApiException(
        res.statusCode, data['error']?.toString() ?? 'claim_failed', '', data);
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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

  /// Ligament Chat: список диалогов пользователя
  Future<List<Map<String, dynamic>>> getChats() async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/chats'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'chats_fetch_failed');
  }

  /// Ligament Chat: темы форума
  Future<List<Map<String, dynamic>>> getChatTopics(String chatId) async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/topics'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'topics_fetch_failed');
  }

  /// Ligament Chat: создание темы форума
  Future<Map<String, dynamic>> createChatTopic(
    String chatId, {
    required String title,
    String iconEmoji = '💬',
  }) async {
    final res = await _post(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/topics'),
      headers: _headers(),
      body: jsonEncode({
        'title': title,
        'icon_emoji': iconEmoji,
      }),
    );
    if (res.statusCode == 201 || res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'topic_create_failed');
  }

  /// Ligament Chat: участники чата
  Future<List<Map<String, dynamic>>> getChatMembers(String chatId) async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/members'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'members_fetch_failed');
  }

  /// Ligament Chat: добавление участника в группу/форум
  Future<Map<String, dynamic>> addChatMember(
    String chatId, {
    required String userId,
    String role = 'member',
  }) async {
    final res = await _post(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/members'),
      headers: _headers(),
      body: jsonEncode({
        'user_id': userId,
        'role': role,
      }),
    );
    if (res.statusCode == 201 || res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'member_add_failed');
  }

  /// Ligament Chat: изменение роли участника
  Future<void> updateChatMemberRole(
    String chatId, {
    required String userId,
    required String role,
  }) async {
    final res = await _put(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/members/$userId'),
      headers: _headers(),
      body: jsonEncode({
        'role': role,
      }),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'member_update_failed');
    }
  }

  /// Ligament Chat: исключение участника
  Future<void> removeChatMember(String chatId, String userId) async {
    final res = await _delete(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/members/$userId'),
      headers: _headers(),
    );
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw ApiException(res.statusCode, 'member_remove_failed');
    }
  }

  /// Ligament Chat: список сообщений чата/топика
  Future<List<Map<String, dynamic>>> getChatMessages(
    String chatId, {
    int topicId = 0,
    int beforeId = 0,
    int limit = 50,
  }) async {
    final params = <String, String>{
      'topic_id': '$topicId',
      'limit': '$limit',
    };
    if (beforeId > 0) {
      params['before_id'] = '$beforeId';
    }
    final qs = Uri(queryParameters: params).query;
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/messages?$qs'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'messages_fetch_failed');
  }

  /// Ligament Chat: отправка сообщения
  Future<Map<String, dynamic>> sendChatMessage(
    String chatId, {
    int topicId = 0,
    required String body,
    String kind = 'text',
    int? replyToId,
    int? secretTtl,
    Map<String, dynamic>? metadata,
    List<String>? attachments,
  }) async {
    final payload = <String, dynamic>{
      'topic_id': topicId,
      'body': body,
      'kind': kind,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (secretTtl != null) 'secret_ttl_seconds': secretTtl,
      if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
      if (attachments != null && attachments.isNotEmpty) ...{
        'attachments': attachments,
        'attachment_ids': attachments,
      },
    };
    final res = await _post(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/messages'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    if (res.statusCode == 201 || res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'message_send_failed');
  }

  /// Ligament Chat: загрузка вложения (файла или изображения)
  Future<Map<String, dynamic>> uploadChatAttachment(
    String chatId,
    List<int> bytes,
    String fileName,
  ) async {
    final uri = Uri.parse(_cleanUrl('/apps/chat/api/v1/attachments/upload'));
    final req = http.MultipartRequest('POST', uri);
    if (token != null && token!.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    if (appVersion.isNotEmpty) {
      req.headers['X-App-Version'] = appVersion;
    }
    req.headers['Accept'] = 'application/json';
    req.fields['chat_id'] = chatId;
    req.files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: fileName,
    ));
    final streamedResponse = await req.send();
    final res = await http.Response.fromStream(streamedResponse);
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    var errMsg = 'attachment_upload_failed';
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Map && body['error'] != null) {
        errMsg = body['error'].toString();
      }
    } catch (_) {}
    throw ApiException(res.statusCode, errMsg);
  }

  /// Ligament Chat: скачивание вложения по ID
  Future<Uint8List> downloadChatAttachment(String attachmentId) async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/attachments/$attachmentId/download'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      return res.bodyBytes;
    }
    throw ApiException(res.statusCode, 'attachment_download_failed');
  }

  /// Ligament Chat: сдвиг указателя прочтения High-Water Mark
  Future<void> markChatRead(String chatId, int topicId, int lastReadId) async {
    final res = await _post(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId/read'),
      headers: _headers(),
      body: jsonEncode({
        'topic_id': topicId,
        'last_read_id': lastReadId,
      }),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'mark_read_failed');
    }
  }

  /// Ligament Chat: список сотрудников компании для начала диалога
  Future<List<Map<String, dynamic>>> getChatContacts() async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/contacts'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'contacts_fetch_failed');
  }

  /// Ligament Chat: снимок онлайн-присутствия и статусов сотрудников
  Future<List<Map<String, dynamic>>> getChatPresences() async {
    final res = await _get(
      _cleanUrl('/apps/chat/api/v1/presence'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = data['presences'] as List<dynamic>? ?? const [];
      return list.cast<Map<String, dynamic>>();
    }
    throw ApiException(res.statusCode, 'presences_fetch_failed');
  }

  /// Ligament Chat: установка статуса присутствия текущего пользователя (в сети, занят, в отпуске и др.)
  Future<Map<String, dynamic>> setChatPresence({
    required String status,
    String statusText = '',
  }) async {
    final res = await _put(
      _cleanUrl('/apps/chat/api/v1/presence'),
      headers: _headers(),
      body: jsonEncode({
        'status': status,
        'status_text': statusText,
      }),
    );
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'presence_update_failed');
  }

  /// Ligament Chat: создание чата (direct, group, forum)
  Future<Map<String, dynamic>> createChat({
    required String kind,
    String title = '',
    String description = '',
    bool isForum = false,
    String? targetUser,
    String? targetName,
    List<String> members = const [],
  }) async {
    final res = await _post(
      _cleanUrl('/apps/chat/api/v1/chats'),
      headers: _headers(),
      body: jsonEncode({
        'kind': kind,
        'title': title,
        'description': description,
        'is_forum': isForum,
        if (targetUser != null) 'target_user': targetUser,
        if (targetName != null) 'target_name': targetName,
        'members': members,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'chat_create_failed');
  }

  /// Ligament Chat: удаление диалога
  Future<void> deleteChat(String chatId) async {
    final res = await _delete(
      _cleanUrl('/apps/chat/api/v1/chats/$chatId'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'chat_delete_failed');
    }
  }

  /// Ligament Ticket: список активных быстрых заявок (пресетов)
  Future<List<Map<String, dynamic>>> getTicketPresets() async {
    final res = await _get(
      _cleanUrl('/apps/tickets/api/v1/presets'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
      return <Map<String, dynamic>>[];
    }
    throw ApiException(res.statusCode, 'presets_fetch_failed');
  }

  /// Ligament Ticket: список заявок пользователя
  Future<List<Map<String, dynamic>>> getTickets({String? status, String? authorId}) async {
    final q = <String>[];
    if (status != null && status.isNotEmpty) q.add('status=${Uri.encodeComponent(status)}');
    if (authorId != null && authorId.isNotEmpty) q.add('author_id=${Uri.encodeComponent(authorId)}');
    final queryStr = q.isNotEmpty ? '?${q.join('&')}' : '';
    final res = await _get(
      _cleanUrl('/apps/tickets/api/v1/tickets$queryStr'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
      return <Map<String, dynamic>>[];
    }
    throw ApiException(res.statusCode, 'tickets_fetch_failed');
  }

  /// Ligament Ticket: подача быстрой заявки (1-клик из трея или приложения)
  Future<Map<String, dynamic>> createTicket({
    String? presetCode,
    String? title,
    String? description,
    String? category,
    String? locationRoom,
    String? deviceName,
  }) async {
    final res = await _post(
      _cleanUrl('/apps/tickets/api/v1/tickets'),
      headers: _headers(),
      body: jsonEncode({
        if (presetCode != null && presetCode.isNotEmpty) 'preset_code': presetCode,
        if (title != null && title.isNotEmpty) 'title': title,
        if (description != null && description.isNotEmpty) 'description': description,
        if (category != null && category.isNotEmpty) 'category': category,
        if (locationRoom != null && locationRoom.isNotEmpty) 'location_room': locationRoom,
        if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
      }),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'ticket_create_failed');
  }

  /// Ligament Ticket: обновление статуса заявки
  Future<void> updateTicketStatus(String ticketId, String status, {String? note}) async {
    final res = await _patch(
      _cleanUrl('/apps/tickets/api/v1/tickets/$ticketId/status'),
      headers: _headers(),
      body: jsonEncode({
        'status': status,
        if (note != null && note.isNotEmpty) 'note': note,
      }),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'ticket_status_update_failed');
    }
  }

  /// SOS: с Link-агентом этого ПК — очередь SOS (`sos_v2`), иначе трансляция экрана приложением.
  Future<Map<String, dynamic>> requestSupport({
    required String category,
    required String problemSummary,
    String accessMode = 'full_control',
    String? targetAgentId,
  }) async {
    if (targetAgentId != null && targetAgentId.isNotEmpty) {
      try {
        final sosRes = await createSOSRequest(
          category: category,
          problemSummary: problemSummary,
          targetAgentId: targetAgentId,
        );
        return {...sosRes, 'sos_v2': true};
      } on ApiException catch (e) {
        // Legacy fallback нужен только если v2 endpoint действительно
        // отсутствует. Ошибки auth/таймауты/5xx нельзя маскировать вторым
        // запросом, который может создать другой тип обращения.
        if (e.statusCode != 404 && e.statusCode != 405 && e.statusCode != 501) {
          rethrow;
        }
      }
    }

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
    throw ApiException(
        res.statusCode, data['error']?.toString() ?? 'support_request_failed');
  }

  /// Получение текущей активной сессии поддержки
  Future<Map<String, dynamic>?> getCurrentSupportSession() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/support/current'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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
      throw ArgumentError(
          'file_* сигналы не отправляются через HTTP-fallback: $type');
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
  Future<List<Map<String, dynamic>>> getSupportMessages(
      String sessionId) async {
    final cleanId =
        sessionId.startsWith('link_') ? sessionId.substring(5) : sessionId;
    http.Response res;
    try {
      res = await _get(
        _cleanUrl('/api/v1/app/link/sessions/$cleanId/messages'),
        headers: _headers(),
      );
      if (res.statusCode != 200) {
        res = await _get(
          _cleanUrl('/api/v1/app/support/$sessionId/messages'),
          headers: _headers(),
        );
      }
    } catch (_) {
      res = await _get(
        _cleanUrl('/api/v1/app/support/$sessionId/messages'),
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

  /// Отправка сообщения в чат поддержки или сеанса Link
  Future<void> sendSupportChatMessage({
    required String sessionId,
    required String text,
    String? senderName,
    String? clientId,
  }) async {
    final cleanId =
        sessionId.startsWith('link_') ? sessionId.substring(5) : sessionId;
    final linkBody = jsonEncode({
      'body': text,
      if (clientId != null && clientId.isNotEmpty)
        'client_message_id': clientId,
    });
    final body = jsonEncode({
      'text': text,
      if (senderName != null && senderName.isNotEmpty)
        'sender_name': senderName,
      if (clientId != null && clientId.isNotEmpty) 'client_id': clientId,
    });
    http.Response res;
    try {
      res = await _post(
        _cleanUrl('/api/v1/app/link/sessions/$cleanId/messages'),
        headers: _headers(),
        body: linkBody,
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return;
      }
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
    if (res.statusCode != 200 && res.statusCode != 201) {
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

  /// Создание обращения за помощью в очередь SOS
  Future<Map<String, dynamic>> createSOSRequest({
    required String category,
    required String problemSummary,
    String? targetAgentId,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sos/request'),
      headers: _headers(),
      body: jsonEncode({
        'category': category,
        'problem_summary': problemSummary,
        if (targetAgentId != null && targetAgentId.isNotEmpty)
          'target_agent_id': targetAgentId,
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'sos_request_create_failed',
        data['message']?.toString() ?? '',
        data,
      );
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  /// Получение очереди необработанных заявок SOS для инженера
  Future<List<Map<String, dynamic>>> getPendingSOSRequests(
      {String? category}) async {
    final uri = Uri.parse(_cleanUrl('/api/v1/app/link/sos/requests')).replace(
      queryParameters: {
        if (category != null && category.isNotEmpty) 'category': category,
      },
    );
    final res = await _get(uri.toString(), headers: _headers());
    final decoded = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode != 200) {
      throw ApiException(
        res.statusCode,
        decoded['error']?.toString() ?? 'sos_queue_fetch_failed',
      );
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is Map<String, dynamic> && data['requests'] is List) {
      return (data['requests'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return [];
  }

  /// Принятие заявки SOS инженером (атомарный claim с Number Match)
  Future<Map<String, dynamic>> claimSOSRequest(String requestId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sos/requests/$requestId/claim'),
      headers: _headers(),
      body: jsonEncode({}),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'sos_claim_failed',
    );
  }

  /// Старт принятой SOS-сессии: offer уходит агенту ПК заявителя, сотрудник
  /// вводит цифры в окне агента. Ответ совпадает с [requestLinkSession].
  Future<Map<String, dynamic>> startSOSSession({
    required String requestId,
    required String sessionId,
    required String clientSdp,
    String accessMode = 'control',
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sos/requests/$requestId/start'),
      headers: _headers(),
      body: jsonEncode({
        'session_id': sessionId,
        'client_sdp': clientSdp,
        'access_mode': accessMode,
      }),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'sos_start_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Статус заявки SOS (для заявителя — без кода подтверждения).
  Future<Map<String, dynamic>> getSOSRequest(String requestId) async {
    final res = await _get(
      _cleanUrl('/api/v1/app/link/sos/requests/$requestId'),
      headers: _headers(),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'sos_request_fetch_failed',
    );
  }

  /// Отмена заявки SOS
  Future<void> cancelSOSRequest({
    required String requestId,
    String? reason,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sos/requests/$requestId/cancel'),
      headers: _headers(),
      body: jsonEncode({
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to cancel SOS request: ${res.statusCode}');
    }
  }

  /// Получение списка участников сессии LINK (операторы, пользователи, наблюдатели)
  Future<List<Map<String, dynamic>>> getLinkSessionParticipants(
      String sessionId) async {
    final res = await _get(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/participants'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      return [];
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is Map<String, dynamic> && data['participants'] is List) {
      return (data['participants'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return [];
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = data['categories'] as List<dynamic>? ?? [];
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Очередь входящих SOS-обращений для инженера: заявки SOS через Link-агент
  /// (`sos_v2`) и прежние сессии трансляции экрана приложением.
  Future<List<Map<String, dynamic>>> getSupportQueue({String? category}) async {
    final queue = <Map<String, dynamic>>[];
    try {
      final sosQueue = await getPendingSOSRequests(category: category);
      queue.addAll(sosQueue.map(sosQueueItem));
    } on ApiException catch (e) {
      // Старые серверы без SOS v2 обслуживаются legacy-очередью ниже.
      if (e.statusCode != 404) rethrow;
    }

    final res = await _get(
      _cleanUrl('/api/v1/app/support/queue'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'support_queue_fetch_failed',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is List) {
      queue.addAll(decoded.map((e) => Map<String, dynamic>.from(e as Map)));
    } else if (decoded is Map) {
      final list =
          (decoded['queue'] ?? decoded['sessions']) as List<dynamic>? ?? [];
      queue.addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
    }
    return queue;
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
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final list = (data['targets'] as List<dynamic>?);
      if (list == null) return [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (res.statusCode == 404) {
      // Фича выключена на этом сервере — не ошибка, просто пусто.
      return [];
    }
    throw ApiException(res.statusCode, 'rdp_targets_fetch_failed');
  }

  /// Корпоративный каталог устройств Link: GET /api/v1/app/link/hosts.
  Future<List<Map<String, dynamic>>> getLinkHosts() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/link/hosts'),
      headers: _headers(),
    );
    if (res.statusCode == 200) {
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final hosts = data['hosts'];
      if (hosts is! List) return <Map<String, dynamic>>[];
      return hosts
          .whereType<Map>()
          .map((host) => Map<String, dynamic>.from(host))
          .toList(growable: false);
    }
    String code = 'link_hosts_fetch_failed';
    try {
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      code = data['error']?.toString() ?? code;
    } catch (_) {}
    throw ApiException(res.statusCode, code);
  }

  /// Archives a host, preserving history. The server checks administrator role
  /// or ownership plus explicit policy; connection ACL is not sufficient.
  Future<void> archiveLinkHost(String agentId, {required String reason}) async {
    final res = await _post(
      _cleanUrl(
          '/api/v1/app/link/hosts/${Uri.encodeComponent(agentId)}/archive'),
      headers: _headers(),
      body: jsonEncode(<String, String>{'reason': reason}),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode != 200 || data['status'] != 'archived') {
      throw ApiException(
          res.statusCode, data['error']?.toString() ?? 'link_archive_failed');
    }
  }

  /// Updates Link host settings (e.g. unattended access). Accessible to Link admins.
  Future<Map<String, dynamic>> updateLinkHost(
    String agentId, {
    bool? unattendedEnabled,
  }) async {
    final body = <String, dynamic>{};
    if (unattendedEnabled != null) {
      body['unattended_enabled'] = unattendedEnabled;
    }
    final res = await _patch(
      _cleanUrl('/api/v1/app/link/hosts/${Uri.encodeComponent(agentId)}'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode != 200 || data['ok'] != true) {
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_host_update_failed',
      );
    }
    return data;
  }

  /// Fetches operators and their access rules for a specific group or OU.
  Future<Map<String, dynamic>> getLinkGroupAccess({
    required String type,
    required String target,
  }) async {
    final uri = Uri.parse(_cleanUrl('/api/v1/app/link/group-access')).replace(
      queryParameters: {
        'type': type,
        'target': target,
      },
    );
    final res = await _get(uri.toString(), headers: _headers());
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode != 200) {
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_group_access_get_failed',
      );
    }
    return data;
  }

  /// Sets operator access rules for a specific group or OU.
  Future<void> updateLinkGroupAccess({
    required String type,
    required String target,
    required List<Map<String, dynamic>> rules,
  }) async {
    final res = await _put(
      _cleanUrl('/api/v1/app/link/group-access'),
      headers: _headers(),
      body: jsonEncode({
        'type': type,
        'target': target,
        'rules': rules,
      }),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode != 200 || data['status'] != 'ok') {
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_group_access_update_failed',
      );
    }
  }

  /// Issues a short-lived, one-use credential for binding the current Windows
  /// host. The token is returned only to the authenticated app client.
  Future<LinkEnrollmentCredential> createLinkEnrollmentCredential() async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/agents/enrollment-token'),
      headers: _headers(),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 201) {
      try {
        return LinkEnrollmentCredential.fromJson(data);
      } on FormatException {
        throw ApiException(res.statusCode, 'invalid_link_enrollment_response');
      }
    }
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'link_enrollment_token_failed',
    );
  }

  /// Starts a Link session; default to view-only until the operator explicitly
  /// requests control privileges.
  Future<Map<String, dynamic>> requestLinkSession({
    required String agentId,
    String accessMode = 'view',
    String? clientSdp,
    String? resolution,
    String? actionId,
    String? sessionKind,
    String? stepUpToken,
  }) async {
    final mode = accessMode == 'full_control'
        ? 'control'
        : (accessMode == 'view_only' ? 'view' : accessMode);
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sessions/request'),
      headers: _headers(),
      body: jsonEncode({
        'agent_id': agentId,
        'access_mode': mode,
        if (actionId != null && actionId.isNotEmpty) 'action_id': actionId,
        if (clientSdp != null && clientSdp.isNotEmpty) 'client_sdp': clientSdp,
        if (resolution != null && resolution.isNotEmpty)
          'resolution': resolution,
        if (sessionKind != null && sessionKind.isNotEmpty)
          'session_kind': sessionKind,
        if (stepUpToken != null && stepUpToken.isNotEmpty)
          'stepup_token': stepUpToken,
      }),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'link_session_request_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Verifies operator Step-Up 2FA when connecting from external perimeter.
  Future<Map<String, dynamic>> verifyLinkStepUp({
    String? totpCode,
    bool? passkey,
  }) async {
    final payload = <String, dynamic>{};
    if (totpCode != null && totpCode.trim().isNotEmpty) {
      payload['totp_code'] = totpCode.trim();
    }
    if (passkey == true) {
      payload['passkey'] = true;
    }
    final res = await _post(
      _cleanUrl('/api/v1/app/link/stepup/verify'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'stepup_verify_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Fetches available Step-Up 2FA options and other authorized devices.
  Future<Map<String, dynamic>> getLinkStepUpOptions() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/link/stepup/options'),
      headers: _headers(),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'stepup_options_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Begins out-of-band Step-Up push to a specific remote device with Number Matching.
  Future<Map<String, dynamic>> beginLinkStepUpPush(String targetDeviceId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/stepup/push-begin'),
      headers: _headers(),
      body: jsonEncode({'target_device_id': targetDeviceId}),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'stepup_push_begin_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Polls the status of the Step-Up push challenge.
  Future<Map<String, dynamic>> pollLinkStepUpPush(String challengeId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/stepup/push-poll'),
      headers: _headers(),
      body: jsonEncode({'challenge_id': challengeId}),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'stepup_push_poll_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Cancels an active Step-Up push challenge.
  Future<void> cancelLinkStepUpPush(String challengeId) async {
    await _post(
      _cleanUrl('/api/v1/app/link/stepup/push-cancel'),
      headers: _headers(),
      body: jsonEncode({'challenge_id': challengeId}),
    );
  }

  /// Fetches the authenticated user's active devices and their online status.
  Future<List<Map<String, dynamic>>> getUserDevices() async {
    final res = await _get(
      _cleanUrl('/api/v1/app/devices'),
      headers: _headers(),
    );
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) {
      final list = data['devices'];
      if (list is List) {
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    }
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'get_devices_failed',
      data['message']?.toString() ?? '',
      data,
    );
  }

  /// Revokes an authorized device of the user.
  Future<void> deleteUserDevice(String deviceId) async {
    final res = await _delete(
      _cleanUrl('/api/v1/app/devices/$deviceId'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'delete_device_failed',
        data['message']?.toString() ?? '',
        data,
      );
    }
  }

  /// Posts the operator's SDP/ICE signaling payload to the enrolled agent.
  Future<void> sendLinkSessionSignal({
    required String sessionId,
    required Map<String, dynamic> signal,
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/signal'),
      headers: _headers(),
      body: jsonEncode({'signal': signal}),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_signal_send_failed',
      );
    }
  }

  /// Polls agent-originated SDP/ICE signals using the server's monotonic ID cursor.
  Future<Map<String, dynamic>> getLinkSessionSignals({
    required String sessionId,
    int after = 0,
  }) async {
    final uri = Uri.parse(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/signal'),
    ).replace(queryParameters: {'after': '$after'});
    final res = await _get(uri.toString(), headers: _headers());
    final data = _decodeJsonMap(res.bodyBytes);
    if (res.statusCode == 200) return data;
    throw ApiException(
      res.statusCode,
      data['error']?.toString() ?? 'link_signals_fetch_failed',
    );
  }

  Future<void> heartbeatLinkSession(String sessionId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/heartbeat'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_session_heartbeat_failed',
      );
    }
  }

  Future<void> closeLinkSession(String sessionId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/close'),
      headers: _headers(),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_session_close_failed',
      );
    }
  }

  Future<void> recordLinkSessionAudit(
    String sessionId, {
    required String event,
    required Map<String, dynamic> detail,
    String result = 'ok',
  }) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/link/sessions/$sessionId/audit'),
      headers: _headers(),
      body: jsonEncode({
        'event': event,
        'detail': detail,
        'result': result,
      }),
    );
    if (res.statusCode != 200) {
      final data = _decodeJsonMap(res.bodyBytes);
      throw ApiException(
        res.statusCode,
        data['error']?.toString() ?? 'link_session_audit_failed',
      );
    }
  }

  Map<String, dynamic> _decodeJsonMap(List<int> bodyBytes) {
    try {
      final value = jsonDecode(utf8.decode(bodyBytes));
      return value is Map<String, dynamic> ? value : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
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
    String? stepUpToken,
  }) async {
    final payload = <String, dynamic>{
      'target_id': targetId,
      'mode': mode,
      if (code != null && code.isNotEmpty) 'code': code,
      if (actionId != null && actionId.isNotEmpty) 'action_id': actionId,
      if (sourceInstanceId != null && sourceInstanceId.isNotEmpty)
        'source_instance_id': sourceInstanceId,
      if (attemptId != null && attemptId.isNotEmpty) 'attempt_id': attemptId,
      if (passkey == true) 'passkey': true,
      if (stepUpToken != null && stepUpToken.isNotEmpty) 'stepup_token': stepUpToken,
      if (clientLocalIps != null && clientLocalIps.isNotEmpty)
        'client_local_ips': clientLocalIps,
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

  /// Продление lease прямого локального RDP-сеанса (LAN/VPN).
  Future<void> rdpHeartbeat(String sessionId) async {
    final res = await _post(
      _cleanUrl('/api/v1/app/rdp/heartbeat'),
      headers: _headers(),
      body: jsonEncode({
        'session_id': sessionId,
      }),
    );
    if (res.statusCode == 200) {
      return;
    }
    String errCode = 'rdp_heartbeat_failed';
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
      if (machinePublicKey != null && machinePublicKey.isNotEmpty)
        'machine_public_key': machinePublicKey,
      if (keyAlgorithm != null && keyAlgorithm.isNotEmpty)
        'key_algorithm': keyAlgorithm,
      if (enclaveType != null && enclaveType.isNotEmpty)
        'enclave_type': enclaveType,
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
      if (installationId != null && installationId.isNotEmpty)
        'installation_id': installationId,
      if (instancePublicKey != null && instancePublicKey.isNotEmpty)
        'instance_public_key': instancePublicKey,
      if (bootId != null && bootId.isNotEmpty) 'boot_id': bootId,
      if (osSessionId != null) 'os_session_id': osSessionId,
      if (authLuid != null) 'auth_luid': authLuid,
      if (userSid != null && userSid.isNotEmpty) 'user_sid': userSid,
      if (posixUid != null) 'posix_uid': posixUid,
      if (posixDisplay != null && posixDisplay.isNotEmpty)
        'posix_display': posixDisplay,
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
  Future<Map<String, dynamic>> activateOwnerScreen(
      String sessionId, String instanceId) async {
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
        final data =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final raw = data['ice_servers'];
        if (raw is List) {
          return raw.whereType<Map<String, dynamic>>().toList();
        }
      }
    } catch (_) {}
    return const [];
  }

  /// Link must not silently start without TURN after a configuration request
  /// fails: otherwise a network error is misreported as a remote host failure.
  Future<List<Map<String, dynamic>>> getLinkIceServers() async {
    final res =
        await _get(_cleanUrl('/api/v1/app/ice-servers'), headers: _headers());
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'link_ice_configuration_unavailable');
    }
    if (res.bodyBytes.length > 64 * 1024) {
      throw const FormatException('Link ICE configuration exceeds size limit');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map || decoded['ice_servers'] is! List) {
      throw const FormatException('Invalid Link ICE configuration');
    }
    final raw = decoded['ice_servers'] as List;
    if (raw.length > 32 || raw.any((entry) => entry is! Map)) {
      throw const FormatException('Invalid Link ICE server list');
    }
    return raw.map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
  }
}
