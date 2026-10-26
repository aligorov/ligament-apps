import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../api/client.dart';
import '../app_version.dart';
import 'alert_service.dart';
import 'deep_link_service.dart';
import 'debug_log_service.dart';
import 'gpo_service.dart';
import 'local_detect_service.dart';
import 'rdp_service.dart';
import 'web_platform.dart';
import 'server_url_validator.dart';
import 'support_service.dart';
import 'telemetry_service.dart';
import 'windows_identity.dart';
import 'sso/sso_ticket.dart';
import 'sso/sso_ticket_flow.dart';
import 'ws_service.dart';

/// Нормализация browser_sso-челленджа из WS-сообщения или pending-записи:
/// поля {id, sp_name, username, machine, auto_allowed, expires_at}, при этом
/// имя SP может приезжать как sp_name/sp/service, а челлендж — вложенно в
/// 'challenge'. Чистая функция — тестируется без сервера.
Map<String, dynamic> normalizeBrowserSsoPrompt(Map<String, dynamic> raw) {
  final src = (raw['challenge'] is Map)
      ? Map<String, dynamic>.from(raw['challenge'] as Map)
      : raw;
  final meta = (src['metadata'] is Map)
      ? Map<String, dynamic>.from(src['metadata'] as Map)
      : const <String, dynamic>{};
  String? pick(String key) => (src[key] ?? meta[key])?.toString();
  return {
    'id': (src['id'] ?? src['challenge_id'] ?? meta['id'])?.toString(),
    'sp_name': pick('sp_name') ?? pick('sp') ?? pick('service') ?? 'SSO',
    'username': pick('username') ?? pick('who'),
    'machine': pick('machine') ?? pick('host'),
    'auto_allowed': src['auto_allowed'] == true || meta['auto_allowed'] == true,
    'expires_at': src['expires_at'] ?? meta['expires_at'],
  };
}

/// Гейт адресации owner-«Экрана» (этап 2.4; Ш2 плана
/// docs/console-any-state-plan.md): должен ли ЭТОТ клиент начать
/// трансляцию по support_prompt с owner:true. Prompt может приходить
/// нескольким устройствам владельца, поэтому каждый получатель решает
/// локально. Чистая функция — тестируется без WS/сервера
/// (owner_screen_test.dart).
///
/// Устройство является целью ТОЛЬКО при точном совпадении адресации:
/// - target_device_id == ownDeviceId (оба непусты), ИЛИ
/// - target_machine_id == registeredMachineId (оба непусты).
///
/// false (prompt игнорируется), когда:
/// - адресация чужая (поле задано, но не совпало);
/// - адресация неизвестная/неполная: target-поля пусты, наш device_id
///   неизвестен при device-адресации, машина не зарегистрирована при
///   machine-адресации. Гейт fail-closed (Д3 аудита): раньше пустые
///   target-поля или незарегистрированная машина «проваливались» к
///   `return true` и машина начинала трансляцию чужой сессии.
///
/// Инициатор==мы (viewer): игнорируем ТОЛЬКО если адресация при этом не
/// наша — точное совпадение machine/device разрешает self-консоль
/// (подключение к своему ПК с той же машины, инцидент 2026-10-10).
bool ownerScreenPromptTargetsThisDevice(
    Map<String, dynamic> prompt, String? ownDeviceId,
    [String? registeredMachineId]) {
  // Точное совпадение по машине (обе стороны непусты) — приоритетная
  // адресация: machine_id переживает ротацию device_id (Д7) и покрывает
  // self-консоль (viewer и цель на одной машине).
  final targetMachine = prompt['target_machine_id']?.toString();
  if (targetMachine != null &&
      targetMachine.isNotEmpty &&
      registeredMachineId != null &&
      registeredMachineId.isNotEmpty &&
      targetMachine == registeredMachineId) {
    return true;
  }
  final target = prompt['target_device_id']?.toString();
  final deviceMatch =
      target != null && target.isNotEmpty && target == ownDeviceId;
  if (deviceMatch) {
    return true;
  }
  // Мы не цель: если мы инициатор — точно игнор (мы viewer), иначе
  // чужая/неполная адресация — fail-closed.
  final initiator = prompt['initiator_device_id']?.toString();
  if (initiator != null && initiator.isNotEmpty && initiator == ownDeviceId) {
    return false;
  }
  return false;
}

/// SOS адресуется агенту ПК, за которым сидит заявитель: свой enrolled-хост с
/// тем же именем компьютера (без домена, без учёта регистра). Неоднозначность
/// или отсутствие совпадения — null, заявка идёт прежним путём.
String? sosLocalAgentId(List<Map<String, dynamic>> hosts,
    {required String userId, required String hostname}) {
  String label(String name) => name.trim().toLowerCase().split('.').first;
  final local = label(hostname);
  if (local.isEmpty || userId.isEmpty) return null;
  final matches = hosts
      .where((h) =>
          h['owner_user_id']?.toString() == userId &&
          h['status']?.toString() == 'enrolled' &&
          label(h['hostname']?.toString() ?? '') == local)
      .toList();
  if (matches.length != 1) return null;
  final id = matches.first['id']?.toString() ?? '';
  return id.isEmpty ? null : id;
}

/// Генерация RFC 4122 v4 UUID с использованием криптостойкого ГСЧ
String generateUuidV4() {
  final rnd = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // v4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}

class AuthState extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _logoutMarkerKey = 'auth_logged_out';
  static const String _localeKey = 'app_locale';

  // Named business/init awaits only; no payloads or credential identifiers.
  Future<T> _traceAwait<T>(String operation, String phase,
      Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    final fields = <String, Object?>{'operation': operation, 'phase': phase,
      'request_id': DebugLogService.instance.nextRequestId()};
    DebugLogService.instance.record('auth.action.started', fields: fields);
    try {
      final result = await action();
      DebugLogService.instance.record('auth.action.completed', fields: {
        ...fields, 'duration_ms': watch.elapsedMilliseconds,
        'result': 'await_returned',
        if (result is List) 'count': result.length,
        if (result is bool) 'state': result ? 'true' : 'false',
      });
      return result;
    } catch (error) {
      DebugLogService.instance.record('auth.action.failed', error: error,
          fields: {...fields, 'duration_ms': watch.elapsedMilliseconds});
      rethrow;
    }
  }

  String _localeCode = 'ru';
  String get localeCode => _localeCode;
  Locale get locale => Locale(_localeCode);
  bool get isRu => _localeCode.startsWith('ru');

  Future<void> setLocale(String code) async {
    final normalized = code.toLowerCase().startsWith('en') ? 'en' : 'ru';
    if (_localeCode == normalized) return;
    _localeCode = normalized;
    final prefs = await SharedPreferences.getInstance();
    await _traceAwait('locale', normalized, () => prefs.setString(_localeKey, normalized));
    notifyListeners();
  }

  final GPOService gpo = GPOService();
  final AlertService alert = AlertService();

  /// Телеметрия — НЕ final: подменяется тестом login-крэша
  /// (test/login_crash_test.dart) на бросающую реализацию. Продакшн-код
  /// поле не переназначает.
  TelemetryService telemetry = TelemetryService();
  final WebSocketService ws = WebSocketService();
  final LocalAuthentication localAuth = LocalAuthentication();
  final SupportService support = SupportService();

  /// RDP-коннектор «Мой ПК» (этап 2): grant → loopback-слушатель →
  /// WS-мост → mstsc. Владеет активным туннелем; logout рвёт сессию.
  final RdpConnectorService rdp = RdpConnectorService();

  /// Локальный детект «умного 2FA» (этап D): HTTP-слушатель на
  /// 127.0.0.1:8757, по которому сервер отличает «вход начат с этого же
  /// ПК». Только windows/linux/macos (см. LocalDetectService.isSupported),
  /// на мобильных start/stop — no-op. Ошибка bind не роняет приложение.
  final LocalDetectService localDetect = LocalDetectService();

  int _authEpoch = 0;
  int _loginGeneration = 0;
  int _committedLoginGeneration = 0;

  Future<void> _writeLogoutMarker() async {
    final prefs = await SharedPreferences.getInstance();
    await _traceAwait('login_guard', 'write_tombstone', () => prefs.setBool(_logoutMarkerKey, true));
  }

  /// Отменяет финализацию всех незавершённых login/loginClaim. UI вызывает
  /// при смене/сбросе второго фактора и dispose; сетевой ответ при этом может
  /// завершиться, но не получит права изменить авторизацию.
  void cancelLoginAttempts() {
    _loginGeneration++;
    // Даже если отменённый ответ уже начал запись токена, после рестарта он
    // не будет восстановлен. Успешный новый login снимает этот tombstone.
    unawaited(_writeLogoutMarker());
  }

  bool _isCurrentAuthClient(
          ApiClient client, int expectedEpoch, String? expectedToken) =>
      identical(api, client) &&
      _authEpoch == expectedEpoch &&
      token == expectedToken &&
      expectedToken != null &&
      isLoggedIn;

  AuthState() {
    // A-04/A-05: доставка намерения autoshare от службы или второго экземпляра
    localDetect.onAutoshare = (sessionId) => requestAutoshare(sessionId);
  }

  /// Токен сессии устройства хранится в безопасном хранилище
  /// (Keychain / Keystore / DPAPI / libsecret), а не в SharedPreferences.
  ///
  /// macOS: useDataProtectionKeyChain=false — data-protection keychain
  /// требует keychain-entitlement и подпись; CI-сборка DMG без сертификата
  /// получала -34018 errSecMissingEntitlement. Легаси-чейн работает
  /// без подписи.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  ApiClient? api;
  String? serverUrl;
  String? token;
  Map<String, dynamic>? currentUser;

  /// Фатальная ошибка конфигурации (VULN-27): принудительный ServerURL из
  /// GPO/MDM отклонён централизованным валидатором схемы. URL НЕ
  /// используется (креды и токены не уходят по открытому каналу), текст
  /// показывается на экране подключения. Локально сохранённый server_url
  /// сознательно не подставляется: иначе подмена реестра/MDM открывала бы
  /// канал по пользовательскому значению.
  String? configError;

  List<Map<String, dynamic>> pendingChallenges = [];
  List<Map<String, dynamic>> allowedApps = [];
  List<Map<String, dynamic>> history = [];
  List<Map<String, dynamic>> notifications = [];
  int unreadNotificationsCount = 0;
  List<Map<String, dynamic>> supportQueue = [];

  /// Заявка SOS через Link-агент этого ПК: экран ведёт агент, приложение
  /// отражает статус заявки.
  String? _sosRequestId;
  @visibleForTesting
  String? get sosRequestId => _sosRequestId;
  Map<String, dynamic>? currentPosture;
  bool isCompliant = true;
  bool isOnline = false;
  List<Map<String, dynamic>> relays = [];

  /// RDP-цели «Мой ПК» (этап 2.1): GET /api/v1/app/rdp/targets. Секция на
  /// главной рисуется только при непустом списке и доступности фичи
  /// (free-лицензии могут не монтировать /rdp/* — та же деградация, что у
  /// apps_rdp_url).
  List<Map<String, dynamic>> rdpTargets = [];
  bool rdpFeatureAvailable = true;

  /// Link inventory is available only when the server grants the feature.
  List<Map<String, dynamic>> linkHosts = [];
  bool linkFeatureAvailable = true;
  bool linkHostsLoading = false;
  String? linkHostsError;
  DateTime? _linkHostsUpdatedAt;

  /// Осведомленность о сетевом периметре (Perimeter Awareness).
  String? clientIp;
  String perimeter = 'internal'; // 'internal' | 'external'
  bool get isExternalPerimeter => perimeter == 'external';

  void _updatePerimeter(Map<String, dynamic>? data) {
    if (data == null) return;
    if (data['perimeter'] != null && data['perimeter'].toString().isNotEmpty) {
      perimeter = data['perimeter'].toString();
    }
    if (data['client_ip'] != null && data['client_ip'].toString().isNotEmpty) {
      clientIp = data['client_ip'].toString();
    }
  }

  /// Проверка второго фактора (Step-Up 2FA: Passkey / Biometrics или TOTP) при подключении к ПК из внешнего периметра
  Future<String> verifyStepUp({String? totpCode, bool? passkey}) async {
    if (api == null) throw StateError('Not connected');
    final resp = await api!.verifyLinkStepUp(totpCode: totpCode, passkey: passkey);
    if (resp['ok'] == true && resp['stepup_token'] != null) {
      return resp['stepup_token'].toString();
    }
    throw StateError(resp['error']?.toString() ?? 'Step-up verification failed');
  }

  /// device_id этой сессии (выдаётся сервером при логине, хранится в prefs
  /// под тем же ключом, что у LocalDetectService). Режиму «Экран» (этап
  /// 2.4, план §5.2) он нужен, чтобы отличить инициатора от цели: пуш
  /// support_prompt с owner:true уходит ВСЕМ устройствам юзера, а делиться
  /// экраном должно только устройство-цель (инициатор — viewer).
  String? _ownDeviceId;
  String? get ownDeviceId => _ownDeviceId;

  /// Идентификатор текущего экземпляра запущенного процесса (instance_id, Tier 3).
  final String instanceId = generateUuidV4();

  /// Идентификатор установки приложения на данном устройстве (installation_id, Tier 2).
  String? _installationId;
  String get installationId => _installationId ?? instanceId;

  Timer? _rdpHeartbeatTimer;
  String? _registeredMachineId;
  bool _instanceRegistered = false;

  // --- Д8 (аудит 2026-10-10, план Ш2): ретрай регистрации машины ---
  // Тихий отказ регистрации оставлял _registeredMachineId == null
  // навсегда, а с fail-closed гейтом owner-экрана (Д3) это навсегда
  // отключало машину от консоли. Теперь после refreshAll без machine_id
  // регистрация перепробуется: первая попытка через 30с, далее каждые
  // 60с — до успеха или logout. Задержки — поля (не константы):
  // сужаются тестом.
  @visibleForTesting
  Duration machineRetryFirstDelay = const Duration(seconds: 30);
  @visibleForTesting
  Duration machineRetryNextDelay = const Duration(seconds: 60);
  Timer? _machineRetryTimer;

  // --- Ш5 (--autoshare, план docs/console-any-state-plan.md §5): ---
  // headless-запуск owner-трансляции по wake-флагу службы-сторожа.
  // Срабатывает ОДИН раз, когда сессия восстановлена (isLoggedIn) и WS
  // подключен (isOnline); реконнекты WS повторный запуск НЕ дают.
  String? _autoshareSessionId;
  bool _autoshareStarted = false;

  /// Генерация уникального action_id для операций доступа RDP / Screen
  String generateActionId() => generateUuidV4();

  // --- Deep-link ligament:// (аудит RDP-11; контракт T6) ---
  /// Ссылка ligament://rdp/<target_uuid> (T6) либо легаси
  /// ligament://rdp/<grant_id>?t=…, ожидающая применения. Ставится:
  /// - холодным стартом (argv в main.dart) до логина — применится ПОСЛЕ
  ///   успешного входа, когда HomeScreen построится;
  /// - горячим стартом/повторной доставкой при живой сессии — HomeScreen
  ///   подхватит по notifyListeners (didChangeDependencies).
  /// Потребляет HomeScreen: запускает RDP-connect флоу (rdp.connectBridge)
  /// и показывает RdpConnectDialog. null — ссылки нет.
  LigamentDeepLink? _pendingRdpDeepLink;
  LigamentDeepLink? get pendingRdpDeepLink => _pendingRdpDeepLink;

  /// Разобрать и поставить ссылку в очередь применения. Некорректные/
  /// чужие ссылки молочно игнорируются (см. parseLigamentDeepLink).
  void handleDeepLink(String raw) {
    final link = parseLigamentDeepLink(raw);
    debugLogDeepLink(raw, link);
    if (link == null) return;
    _pendingRdpDeepLink = link;
    notifyListeners();
  }

  /// Снять ожидающую ссылку (вызывает HomeScreen при запуске флоу).
  LigamentDeepLink? consumePendingRdpDeepLink() {
    final link = _pendingRdpDeepLink;
    _pendingRdpDeepLink = null;
    return link;
  }

  /// Deep-link target-режим (T6): «намерение подключиться к цели» из
  /// ссылки ligament://rdp/<target_uuid>. Приложение САМО получает
  /// bridge-грант — POST /api/v1/app/rdp/grant {target_id, mode:"bridge"}
  /// — от device-токена из защищённого хранилища; ссылка не несёт НИКАКИХ
  /// токенов/секретов (командная строка холодного старта читается любым
  /// процессом — урок аудита). Ответ {grant_id, token} уходит вызывающей
  /// стороне в память для connectBridge: грант-токен существует только
  /// внутри процесса и в URI не возвращается никогда.
  ///
  /// Отказы сервера пробрасываются как ApiException (в т.ч. 428
  /// mfa_required — HomeScreen показывает диалог «войти заново /
  /// подтвердить»); не залогинен — ApiException(401, not_authenticated).
  Future<Map<String, dynamic>> grantRdpTargetBridge(String targetId,
      {String? code}) async {
    final client = api;
    if (client == null) {
      throw ApiException(401, 'not_authenticated');
    }
    return client.rdpGrant(targetId: targetId, mode: 'bridge', code: code);
  }

  /// ICE-серверы (STUN/TURN) из /api/v1/app/config для WebRTC-сессий
  /// удаленной помощи (агент + операторский экран в приложении).
  List<Map<String, dynamic>> iceServers = [];
  String? activeRelayEndpoint;
  String? activeRelayName;
  bool get isUsingRelay => activeRelayEndpoint != null;
  String get connectionStatusText => isOnline
      ? (isUsingRelay ? 'Online ($activeRelayName)' : 'Online')
      : 'Offline';

  Map<String, dynamic>? activePrompt;
  Map<String, dynamic>? activeSupportPrompt;
  Map<String, dynamic>? activeNotificationPrompt;
  Timer? _pollingTimer;
  bool _isPollingInFlight = false;
  final Set<String> _resolvedChallengeIds = {};
  // Челленджи, по которым уже сработал alert (звук + вывод окна/нотификация):
  // WS и polling оба могут доставить один и тот же prompt — алерт
  // срабатывает один раз на челлендж, без повторов каждые 4 секунды.
  final Set<String> _alertedChallengeIds = {};

  bool get isLoggedIn => token != null && currentUser != null;

  /// Подтверждение Windows-сессии: совпадает ли аккаунт приложения с
  /// пользователем текущей Windows-сессии (true/false; null — не Windows
  /// или identity недоступна). Сигнал уходит с телеметрией
  /// (identity_mismatch) — см. docs/windows-sso-analysis.md.
  bool? get windowsIdentityMatch => WindowsIdentity.matchesAccount(username);

  /// Отображаемое имя Windows-пользователя (CORP\ivanov) для баннера.
  String get windowsUserDisplay =>
      WindowsIdentity.instance.collect()?.samCompatibleName ?? '';

  // --- Фаза 1: mismatch-баннер (гасится на сессию) ---
  bool _identityBannerDismissed = false;
  bool get showIdentityMismatchBanner =>
      windowsIdentityMatch == false && !_identityBannerDismissed;
  void dismissIdentityBanner() {
    _identityBannerDismissed = true;
    notifyListeners();
  }

  // --- Фаза 2: предъявление CP-билета серверу ---
  final SsoTicketReader _ssoTicketReader = createSsoTicketReader();
  SsoTicketFlow? _ssoTicketFlow;

  /// Статус «подтверждено Windows» для профиля (null — нет proof-а).
  DateTime? get ssoVerifiedUntil => _ssoTicketFlow?.verifiedUntil;

  /// Предъявить живой билет после логина/старта сессии. Тихая деградация
  /// при любой ошибке: cooldown 1/мин и sticky-404 живут в SsoTicketFlow.
  Future<void> presentSsoTicket() async {
    if (api == null || !isLoggedIn) return;
    _ssoTicketFlow ??= SsoTicketFlow(submit: (ticket) async {
      final client = api;
      if (client == null) return null;
      try {
        final (code, expiresAt) = await _traceAwait('sso_ticket', 'submit', () => client.submitSsoTicket(ticket));
        return SsoSubmitResponse(code, expiresAt: expiresAt);
      } catch (_) {
        return null; // транспорт — тихо
      }
    });
    try {
      final ticket = await _traceAwait('sso_ticket', 'read', _ssoTicketReader.readTicket);
      final outcome = await _traceAwait('sso_ticket', 'present', () => _ssoTicketFlow!.present(ticket?.value));
      if (outcome == SsoSubmitOutcome.ok) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('auth_state: sso-ticket предъявление пропущено: $e');
    }
  }

  // --- Фаза 2b: browser_sso-челлендж (SSO-мост) ---
  static const String _browserSsoAutoKey = 'browser_sso_auto_approve';
  Map<String, dynamic>? activeBrowserSsoPrompt;
  bool browserSsoMachineOk = false;
  bool browserSsoHasTicket = false;
  String? _browserSsoTicket;
  bool _browserSsoAutoApprove = false;

  bool get browserSsoAutoApprove => _browserSsoAutoApprove;

  Future<void> setBrowserSsoAutoApprove(bool value) async {
    _browserSsoAutoApprove = value;
    final prefs = await SharedPreferences.getInstance();
    await _traceAwait('browser_sso_auto', value ? 'enable' : 'disable', () => prefs.setBool(_browserSsoAutoKey, value));
    notifyListeners();
  }

  Future<void> _loadBrowserSsoAutoApprove() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _browserSsoAutoApprove = prefs.getBool(_browserSsoAutoKey) ?? false;
    } catch (_) {}
  }

  /// Доставка browser_sso-челленджа (WS и polling-фолбэк). Истёкшие не
  /// показываем вовсе; авто-approve — только при включённом тумблере И
  /// серверном auto_allowed, иначе всегда явный диалог.
  Future<void> _surfaceBrowserSso(Map<String, dynamic> raw) async {
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    final prompt = normalizeBrowserSsoPrompt(raw);
    final id = prompt['id']?.toString();
    if (id == null || id.isEmpty) return;
    if (_resolvedChallengeIds.contains(id)) return;
    if (isExpired(prompt['expires_at'])) return;
    if (activeBrowserSsoPrompt?['id']?.toString() == id) return;

    // Живой билет + сверка машины (machine-claim челленджа ↔ наш ПК).
    final identity = WindowsIdentity.instance.collect();
    String? ticket;
    try {
      ticket = (await _ssoTicketReader.readTicket())?.value;
    } catch (_) {}
    if (_authEpoch != expectedEpoch || token != expectedToken) return;
    _browserSsoTicket = ticket;
    browserSsoHasTicket = ticket != null && ticket.isNotEmpty;
    browserSsoMachineOk = machineMatches(
      prompt['machine']?.toString(),
      identity?.computerName,
    );

    final autoAllowed = prompt['auto_allowed'] == true;
    if (autoAllowed &&
        _browserSsoAutoApprove &&
        browserSsoHasTicket &&
        browserSsoMachineOk) {
      await resolveBrowserSso(true, silent: true, prompt: prompt);
      return;
    }

    activeBrowserSsoPrompt = prompt;
    final sp = prompt['sp_name']?.toString() ?? 'SSO';
    alert.triggerAlert(
      title: isRu ? 'Вход в $sp' : 'Sign in to $sp',
      body: isRu
          ? 'Подтвердите вход по Windows-билету в приложении'
          : 'Confirm Windows-ticket sign-in in the app',
      challengeId: id,
    );
    notifyListeners();
  }

  /// Решение по browser_sso: approve — всегда с живым билетом, deny — без.
  /// [silent] — авто-approve по тумблеру (без диалога).
  Future<void> resolveBrowserSso(bool approve,
      {bool silent = false, Map<String, dynamic>? prompt}) async {
    final data = prompt ?? activeBrowserSsoPrompt;
    if (data == null) return;
    final id = data['id']?.toString() ?? '';
    if (id.isEmpty) return;

    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;
    final useApprove = approve && browserSsoHasTicket && browserSsoMachineOk;
    final ticket = _browserSsoTicket;
    if (approve && !useApprove) {
      debugPrint(
          'auth_state: browser_sso approve без живого билета — отправляем deny');
    }
    try {
      await _traceAwait('browser_sso', useApprove ? 'approve' : 'deny', () => client.browserSsoDecision(
        challengeId: id,
        approve: useApprove,
        ssoTicket: useApprove ? ticket : null,
      ));
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      // Только успешный API-ответ делает challenge resolved. Другой prompt,
      // появившийся за время запроса, не закрываем.
      _resolvedChallengeIds.add(id);
      if (activeBrowserSsoPrompt?['id']?.toString() == id) {
        activeBrowserSsoPrompt = null;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: browser_sso decision отклонён сервером: $e');
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      // При auto-approve prompt ещё не был активным: возвращаем его для явного
      // решения. Обычный prompt оставался на месте весь HTTP-запрос.
      if (activeBrowserSsoPrompt == null) {
        activeBrowserSsoPrompt = data;
        notifyListeners();
      }
    }
  }

  String get username => currentUser?['username']?.toString() ?? '';
  String get displayName {
    final dn = currentUser?['display_name']?.toString();
    if (dn != null && dn.isNotEmpty) return dn;
    return username;
  }

  bool get isAdmin => currentUser?['role'] == 'admin';
  bool get isLinkAdmin => isAdmin || currentUser?['link_admin'] == true;
  bool get isLinkOperator =>
      isLinkAdmin ||
      currentUser?['role'] == 'operator' ||
      currentUser?['link_operator'] == true;

  List<String> get supportRoles {
    final raw = currentUser?['support_roles'];
    if (raw is List) {
      return raw.map((e) => e.toString().toLowerCase()).toList();
    }
    return [];
  }

  bool get isITEngineer => supportRoles.contains('it') || supportRoles.contains('all');
  bool get is1CEngineer => supportRoles.contains('1c') || supportRoles.contains('all');
  bool get isEngineer => supportRoles.isNotEmpty;

  String? get engineerBadge {
    if (supportRoles.contains('all') || (isITEngineer && is1CEngineer)) {
      return isRu ? '🛠 IT / 1С-инженер' : '🛠 IT / 1C Engineer';
    }
    if (is1CEngineer) return isRu ? '📊 1С-инженер' : '📊 1C Engineer';
    if (isITEngineer) return isRu ? '🖥 IT-инженер' : '🖥 IT Engineer';
    if (supportRoles.isNotEmpty) {
      return isRu
          ? '🛠 Инженер (${supportRoles.join(", ")})'
          : '🛠 Engineer (${supportRoles.join(", ")})';
    }
    if (isAdmin) return isRu ? '👑 Администратор' : '👑 Administrator';
    return null;
  }

  void dismissPrompt([String? challengeId]) {
    if (challengeId != null && challengeId.isNotEmpty) {
      _resolvedChallengeIds.add(challengeId);
    } else if (activePrompt != null) {
      final cid = activePrompt!['challenge_id']?.toString();
      if (cid != null && cid.isNotEmpty) _resolvedChallengeIds.add(cid);
    }
    activePrompt = null;
    alert.resetWindowPriority();
    notifyListeners();
  }

  void dismissNotificationPrompt() {
    activeNotificationPrompt = null;
    notifyListeners();
  }

  Future<void> init() async {
    DebugLogService.instance.record('auth.preferences.begin');
    final prefs = await _traceAwait('init', 'preferences', SharedPreferences.getInstance);
    DebugLogService.instance.record('auth.preferences.ready');
    final loggedOut = prefs.getBool(_logoutMarkerKey) ?? false;

    final savedInst = prefs.getString('installation_id');
    if (savedInst != null && savedInst.isNotEmpty) {
      _installationId = savedInst;
    } else {
      _installationId = generateUuidV4();
      await prefs.setString('installation_id', _installationId!);
    }

    final savedLocale = prefs.getString(_localeKey);
    if (savedLocale != null && savedLocale.isNotEmpty) {
      _localeCode = savedLocale.toLowerCase().startsWith('en') ? 'en' : 'ru';
    } else {
      final sysLang =
          PlatformDispatcher.instance.locale.languageCode.toLowerCase();
      _localeCode = sysLang.startsWith('en') ? 'en' : 'ru';
    }

    // Если GPO принудительно задает ServerURL, используем его — но только
    // после централизованной валидации (VULN-27): GPO-значение никто не
    // перепроверял, а по этому каналу уходят пароль и Bearer-токен.
    // http допустим лишь для loopback (localhost / 127.0.0.0/8 / ::1).
    final enforced = gpo.enforcedServerUrl;
    if (enforced != null) {
      switch (validateServerUrl(enforced)) {
        case null:
          serverUrl = enforced;
          break;
        case ServerUrlError.empty:
        case ServerUrlError.invalid:
          configError = isRu
              ? 'Адрес сервера из групповой политики некорректен. Обратитесь к администратору.'
              : 'Server URL from Group Policy is invalid. Contact your administrator.';
          break;
        case ServerUrlError.insecureHttp:
          configError = isRu
              ? 'GPO задал http-адрес сервера вне loopback: пароль передавался бы открытым текстом. Адрес отклонён, обратитесь к администратору.'
              : 'Group Policy set a non-loopback http server URL: the password would be sent in plaintext. URL rejected, contact your administrator.';
          break;
        case ServerUrlError.unsupportedScheme:
          configError = isRu
              ? 'GPO задал адрес сервера без https://. Адрес отклонён, обратитесь к администратору.'
              : 'Group Policy set a server URL without https://. URL rejected, contact your administrator.';
          break;
      }
      if (configError != null) {
        debugPrint(
            'auth_state: GPO ServerURL отклонён валидатором — URL не используется');
      }
    } else {
      final saved = prefs.getString('server_url');
      if (saved != null) {
        // Сохранённый адрес тоже проходит централизованную проверку:
        // значения, вписанные до ужесточения валидатора (http для хостов
        // вида 127.evil.example), молча использоваться больше не должны.
        if (validateServerUrl(saved) == null) {
          serverUrl = saved;
        } else {
          configError = isRu
              ? 'Сохранённый адрес сервера отклонён проверкой безопасности. Укажите https-адрес заново.'
              : 'Saved server URL failed the security check. Please re-enter the https URL.';
          debugPrint(
              'auth_state: сохранённый server_url отклонён валидатором — URL не используется');
        }
      }
    }

    final relayCacheKey = serverUrl != null
        ? 'cached_relays_${serverUrl!.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}'
        : 'cached_relays';
    final cachedRelaysRaw = prefs.getString(relayCacheKey);
    if (cachedRelaysRaw != null && cachedRelaysRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedRelaysRaw);
        if (decoded is List) {
          relays =
              decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
    } else {
      relays = [];
    }

    // Миграция: ранее токен хранился в SharedPreferences в открытом виде.
    // При первом запуске новой версии переносим его в безопасное хранилище
    // и удаляем plaintext-копию.
    final legacyToken = prefs.getString(_tokenKey);
    if (legacyToken != null && legacyToken.isNotEmpty) {
      try {
        if (!loggedOut) {
          final existing = await _traceAwait('init', 'legacy_storage_read', () => _secureStorage.read(key: _tokenKey));
          if (existing == null || existing.isEmpty) {
            await _traceAwait('init', 'legacy_storage_write', () => _secureStorage.write(key: _tokenKey, value: legacyToken));
          }
        }
        await prefs.remove(_tokenKey);
      } catch (e) {
        debugPrint('auth_state: ошибка миграции токена в secure storage: $e');
      }
    }

    String? savedToken;
    DebugLogService.instance.record('auth.secure_storage.begin');
    try {
      savedToken = await _traceAwait('init', 'secure_storage_read', () => _secureStorage.read(key: _tokenKey));
      if (loggedOut && savedToken != null) {
        // Logout уже подтверждён локальным tombstone. Если delete ранее
        // failed, повторяем его, но даже повторный сбой не восстановит вход.
        try {
          await _traceAwait('init', 'logged_out_storage_delete', () => _secureStorage.delete(key: _tokenKey));
        } catch (_) {}
        savedToken = null;
      }
    } catch (e) {
      DebugLogService.instance.record('auth.secure_storage.failed', error: e);
      debugPrint('auth_state: ошибка чтения токена из secure storage: $e');
    }
    DebugLogService.instance.record('auth.secure_storage.ready');

    if (!loggedOut && serverUrl != null && savedToken != null) {
      api = ApiClient(baseUrl: serverUrl!, token: savedToken);
      token = savedToken;

      try {
        DebugLogService.instance.record('auth.profile.begin');
        currentUser = await _traceAwait('init', 'restore_profile', () => api!.getProfile());
        DebugLogService.instance.record('auth.profile.ready');
        _updatePerimeter(currentUser);
        // Этап D «умный 2FA»: восстанавливаем локальный детект по device_id,
        // сохранённому при логине (сессия устройства живёт и через рестарт
        // приложения, пока не был logout).
        final savedDeviceId =
            prefs.getString(LocalDetectService.kDeviceIdPrefKey);
        if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
          _ownDeviceId = savedDeviceId;
          unawaited(localDetect.start(savedDeviceId));
        }
        await _traceAwait('init', 'sso_preferences', _loadBrowserSsoAutoApprove);
        DebugLogService.instance.record('auth.services.begin');
        _setupServices();
        DebugLogService.instance.record('auth.refresh.begin');
        await _traceAwait('init', 'refresh_cycle', refreshAll);
        DebugLogService.instance.record('auth.refresh.ready');
        // Фаза 2: предъявляем CP-билет при старте сессии (TTL ~5 мин с
        // входа в Windows) — тихо, любой сбой не влияет на работу.
        unawaited(presentSsoTicket());
      } catch (e) {
        DebugLogService.instance.record('auth.restore.failed', error: e);
        debugPrint(
            'auth_state: токен недействителен или сервер недоступен: $e');
        // Если ошибка 401, сбрасываем токен
        if (e is ApiException && e.statusCode == 401) {
          await logout();
        }
      }
    }

    notifyListeners();
  }

  /// Единая точка появления push-челленджа в UI — вызывается и из WS
  /// (challenge_prompt), и из polling-фолбэка (pending-список). Гасит
  /// дубли: уже закрытый пользователем челлендж не всплывает повторно,
  /// повторная доставка того же челленджа не перезапускает алерт.
  /// Модалка (ApprovalModal через activePrompt) открывается/обновляется
  /// из ОБЕИХ цепочек без второго окна.
  void _surfacePrompt(Map<String, dynamic> prompt) {
    // browser_sso-челленджи (SSO-мост, фаза 2b) могут приехать и типом
    // challenge_prompt с purpose/type=browser_sso: их UI — отдельный
    // диалог с билетом, в модалку подтверждения входа они попадать не
    // должны. Маршрутизируем в отдельный флоу и выходим.
    final purpose = prompt['purpose']?.toString() ?? prompt['type']?.toString();
    final metaPurpose = (prompt['metadata'] is Map)
        ? (prompt['metadata'] as Map)['purpose']?.toString()
        : null;
    if (purpose == 'browser_sso' || metaPurpose == 'browser_sso') {
      _surfaceBrowserSso(prompt);
      return;
    }

    final cid = prompt['challenge_id']?.toString();
    if (cid != null && cid.isNotEmpty && _resolvedChallengeIds.contains(cid)) {
      return;
    }
    final isNew = activePrompt == null ||
        activePrompt!['challenge_id']?.toString() != cid;
    activePrompt = prompt;
    if (cid != null &&
        cid.isNotEmpty &&
        isNew &&
        !_alertedChallengeIds.contains(cid)) {
      _alertedChallengeIds.add(cid);
      final clientIp = prompt['client_ip'] ?? prompt['ip'] ?? '—';
      final hostIp = prompt['host_ip'];
      final ipText = hostIp != null ? '$clientIp → $hostIp' : '$clientIp';
      final sName = prompt['service'] ?? 'Ligament 2FA';
      final who = prompt['who'] ?? (isRu ? 'Сотрудник' : 'Employee');
      final host = prompt['host']?.toString();
      final pcPart = (host != null && host.isNotEmpty)
          ? (isRu ? ' · Имя ПК: $host' : ' · PC: $host')
          : '';
      alert.triggerAlert(
        title: isRu ? 'Запрос на вход: $sName' : 'Login Request: $sName',
        body: '$who$pcPart (IP: $ipText)',
        challengeId: cid,
      );
    }
    notifyListeners();
  }

  void _setupServices() {
    // Локальные биндинги вместо `!`: между присвоениями и вызовами ниже
    // есть await'ы (logout может сбросить поля параллельно).
    final client = api;
    final base = serverUrl;
    final tok = token;
    if (client == null || tok == null || base == null) return;

    // 1. WebSocket для мгновенных push-оповещений
    ws.onPrompt = (prompt) {
      _surfacePrompt(prompt);
      loadPendingChallenges();
    };

    // Фаза 2b: SSO-мост — browser_sso-челлендж из WS-канала
    ws.onBrowserSso = (data) {
      _surfaceBrowserSso(data);
      loadPendingChallenges();
    };

    ws.onNotification = (msg) {
      final title =
          msg['title']?.toString() ?? (isRu ? 'Уведомление' : 'Notification');
      final body = msg['body']?.toString() ?? '';
      final notifId = msg['id']?.toString();

      activeNotificationPrompt = {
        'id': notifId,
        'title': title,
        'body': body,
        'source': msg['source'] ?? msg['category'] ?? 'system',
        'data': msg['data'],
        'created_at': msg['timestamp'] ?? DateTime.now().toIso8601String(),
      };

      alert.triggerAlert(
        title: title,
        body: body,
        challengeId: notifId,
      );
      loadNotifications();
      notifyListeners();
    };

    ws.onSupportPrompt = (prompt) {
      // Этап 2.4 «Экран» (план §5.2): сессию инициировал САМ владелец с
      // его другого устройства (grant mode=screen → S3-склейка на сервере).
      // Цель стартует трансляцию БЕЗ accept-диалога и number-match.
      if (prompt['owner'] == true) {
        unawaited(_handleOwnerScreenPrompt(prompt));
        return;
      }
      activeSupportPrompt = prompt;
      support.setAuthorizing(
        sessionId: prompt['session_id']?.toString() ?? '',
        category: prompt['category']?.toString(),
        problemSummary: prompt['problem_summary']?.toString(),
        accessMode: prompt['access_mode']?.toString(),
      );
      final cat = prompt['category'] == '1c'
          ? (isRu ? '1С-поддержка' : '1C Support')
          : (isRu ? 'IT-служба' : 'IT Helpdesk');
      alert.triggerAlert(
        title: isRu ? 'Удаленная помощь: $cat' : 'Remote Assistance: $cat',
        body: isRu
            ? 'Инженер готов подключиться к экрану. Подтвердите контрольное число.'
            : 'Engineer is ready to connect. Confirm the number match.',
        challengeId: prompt['session_id']?.toString(),
      );
      notifyListeners();
    };

    support.setApi(client);
    support.removeListener(notifyListeners);
    support.addListener(notifyListeners);

    // Этап 2: RDP-коннектор. Туннель закрывает грант через api.rdpClose
    // (идемпотентно, в т.ч. из dispose/logout после сброса api — хук сам
    // проверяет живость клиента).
    rdp.closeGrantHandler = (grantId) async {
      final client = api;
      if (client == null) return;
      await client.rdpClose(grantId);
    };
    rdp.removeListener(notifyListeners);
    rdp.addListener(notifyListeners);

    support.onChatMessageReceived = (msg) {
      alert.triggerChatNotification(
        sender: msg.senderName,
        message: msg.text,
      );
      notifyListeners();
    };

    ws.onSupportSignal = (signal) {
      support.handleRemoteSignal(signal);
    };

    ws.onSupportEnded = (msg) {
      support.stopScreenSharing();
      activeSupportPrompt = null;
      notifyListeners();
    };

    ws.onSupportIncoming = (msg) {
      if (isEngineer) {
        final session = (msg['session'] is Map)
            ? Map<String, dynamic>.from(msg['session'] as Map)
            : msg;
        final category = (session['category'] ?? msg['category'])?.toString().toLowerCase().trim();
        if (category != null && category.isNotEmpty &&
            !supportRoles.contains('all') &&
            !supportRoles.contains(category)) {
          return;
        }
        loadSupportQueue();
        final clientName = session['display_name'] ??
            session['employee_name'] ??
            session['username'] ??
            msg['display_name'] ??
            (isRu ? 'Пользователь' : 'User');
        final catTitle = category == '1c' ? '1C' : (category?.toUpperCase() ?? 'IT');
        final problemSummary =
            session['problem_summary'] ?? msg['problem_summary'] ?? '';
        final sessionId =
            session['id'] ?? session['session_id'] ?? msg['session_id'];
        alert.triggerAlert(
          title: isRu
              ? 'Новое SOS-обращение: $catTitle'
              : 'New SOS Ticket: $catTitle',
          body: '$clientName: $problemSummary',
          challengeId: sessionId?.toString(),
        );
      }
    };

    ws.onConnected = () {
      isOnline = true;
      // Ш5 (--autoshare): первый успешный коннект после восстановления
      // сессии — точка готовности для headless owner-запуска. Повторные
      // onConnected (реконнекты) ничего не перезапускают (one-shot).
      wsConnectedAutoshareCheck();
      loadNotifications();
      notifyListeners();
    };

    ws.onDisconnected = () {
      isOnline = false;
      notifyListeners();
    };

    // 401 на WS-handshake: токен недействителен — прекращаем цикл
    // реконнектов и выходим в разлогин (M-2).
    ws.onUnauthorized = () {
      debugPrint('auth_state: WS отвергнул токен (401) — разлогин');
      logout();
    };

    ws.onEndpointChanged = (endpoint, isRelay) {
      if (isRelay) {
        activeRelayEndpoint = endpoint;
        final found = relays.firstWhere(
          (r) => r['last_ip']?.toString() == endpoint,
          orElse: () => <String, dynamic>{'name': 'Branch Relay'},
        );
        activeRelayName = found['name']?.toString() ?? 'Branch Relay';
      } else {
        activeRelayEndpoint = null;
        activeRelayName = null;
      }
      notifyListeners();
    };

    // Relay-узлы принимаются только по HTTPS: по открытому каналу уходит
    // Bearer-токен сессии, перехват которого равен обходу 2FA. IP-записи
    // без явной схемы upgrading'у не подлежат — ждём от сервера https URL.
    final fallbackRelayUrls = <String>[];
    for (final r in relays) {
      final explicit = r['url']?.toString() ?? r['last_url']?.toString() ?? '';
      var candidate = explicit;
      if (candidate.isEmpty) {
        // Легаси-запись (только last_ip): relay без TLS отключён до тех пор,
        // пока сервер не начнёт отдавать полноценный https-адрес.
        continue;
      }
      final uri = Uri.tryParse(candidate);
      if (uri == null ||
          !uri.hasScheme ||
          uri.scheme != 'https' ||
          uri.host.isEmpty) {
        debugPrint('auth_state: relay "$candidate" отклонён: требуется https');
        continue;
      }
      fallbackRelayUrls.add(candidate);
    }

    ws.connect(
      baseUrl: base,
      token: tok,
      fallbackUrls: fallbackRelayUrls,
    );

    // 2. Телеметрия и контроль комплаенса
    telemetry.startReporting(client);

    // 3. Периодический опрос pending-запросов и сессий поддержки (fallback при временном обрыве WS)
    _pollingTimer?.cancel();
    int pollTicks = 0;
    _pollingTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!isLoggedIn || _isPollingInFlight) return;
      // Не порождаем новый цикл опроса, пока предыдущий еще выполняется
      _isPollingInFlight = true;
      pollTicks++;
      try {
        await loadPendingChallenges();
        await checkSupportSession();
        if (isEngineer) {
          await loadSupportQueue();
        }
        if (pollTicks % 4 == 0) {
          await loadNotifications();
        }
        // Плитки приложений: админ заводит/убирает приложения на сервере —
        // список догоняет реальность без перелогина (раз в минуту;
        // мгновенно — pull-to-refresh на экране приложений).
        if (pollTicks % 15 == 0) {
          await loadAllowedApps();
          // Этап 2.1: онлайн-статус RDP-целей (агент тухнет по disconnect/
          // таймауту — без обновления плитка врёт). Тот же ритм 60с, пока
          // есть хоть одна цель.
          if (rdpTargets.isNotEmpty) {
            await loadRdpTargets();
          }
        }
      } finally {
        _isPollingInFlight = false;
      }
    });
  }

  Future<void> setServerUrl(String url) async {
    cancelLoginAttempts();
    serverUrl = url.trim();
    final prefs = await SharedPreferences.getInstance();
    await _traceAwait('set_server', 'preferences', () => prefs.setString('server_url', serverUrl!));
    api = ApiClient(baseUrl: serverUrl!);
    notifyListeners();
  }

  Future<void> login(String username, String password, [String? code]) async {
    final attempt = ++_loginGeneration;
    final base = serverUrl;
    if (base == null || base.isEmpty) {
      throw Exception(
          isRu ? 'Не указан адрес сервера' : 'Server address is required');
    }
    // Раньше здесь было `api!.login(...)`: logout() обнуляет api, а экран
    // входа этого момента не переживает — получали «Null check operator
    // used on a null value» прямо в диалоге входа. Теперь явная понятная
    // ошибка вместо краша.
    final client = api;
    if (client == null) {
      throw Exception(isRu
          ? 'Клиент API не инициализирован — укажите адрес сервера заново'
          : 'API client is not initialized — re-enter the server address');
    }

    await _writeLogoutMarker();
    if (attempt != _loginGeneration || !identical(api, client)) return;

    final deviceInfo = DeviceInfoPlugin();
    String deviceName = 'Device';
    String osVersion = '';
    String platform = 'unknown';

    if (kIsWeb) {
      // PWA: честная платформа по UA (web-ios/web-android/web) — строка
      // устройства рождается правильной, без ожидания телеметрии-лечения.
      platform = detectWebPlatform(webUserAgent(),
          maxTouchPoints: webMaxTouchPoints());
    } else {
      try {
        if (Platform.isWindows) {
          platform = 'windows';
          final wInfo = await _traceAwait('login_preflight', 'windows_device_info', () => deviceInfo.windowsInfo);
          deviceName = wInfo.computerName;
          osVersion = wInfo.displayVersion;
        } else if (Platform.isAndroid) {
          platform = 'android';
          final aInfo = await _traceAwait('login_preflight', 'android_device_info', () => deviceInfo.androidInfo);
          deviceName = '${aInfo.brand} ${aInfo.model}';
          osVersion = 'Android ${aInfo.version.release}';
        } else if (Platform.isIOS) {
          platform = 'ios';
          final iInfo = await _traceAwait('login_preflight', 'ios_device_info', () => deviceInfo.iosInfo);
          deviceName = iInfo.name;
          osVersion = '${iInfo.systemName} ${iInfo.systemVersion}';
        } else if (Platform.isMacOS) {
          platform = 'macos';
          final mInfo = await _traceAwait('login_preflight', 'macos_device_info', () => deviceInfo.macOsInfo);
          deviceName = mInfo.computerName;
          osVersion = 'macOS ${mInfo.majorVersion}.${mInfo.minorVersion}';
        } else if (Platform.isLinux) {
          platform = 'linux';
          final lInfo = await _traceAwait('login_preflight', 'linux_device_info', () => deviceInfo.linuxInfo);
          deviceName = lInfo.name;
          osVersion = 'Linux';
        }
      } catch (_) {}
    }

    // Телеметрия НИКОГДА не должна ронять вход (краш-репорт v0.8.133):
    // любой сбой сбора — FFI kernel32, дочерние процессы, таймауты —
    // продолжаем вход с пустым posture, сервер досчитает дефолты сам.
    Map<String, dynamic> initialPosture = const {};
    try {
      initialPosture = await _traceAwait('login', 'collect_posture', telemetry.collectPosture);
    } catch (e) {
      debugPrint(
          'auth_state: телеметрия при входе не собрана, продолжаем без неё: $e');
    }

    final resp = await _traceAwait('login', 'request', () => client.login(
      username: username,
      password: password,
      code: code,
      deviceName: deviceName,
      platform: platform,
      osVersion: osVersion,
      appVersion: appVersion,
      securityPosture: initialPosture,
      windowsIdentity: WindowsIdentity.snapshot(),
    ));

    if (attempt != _loginGeneration || !identical(api, client)) return;
    await _traceAwait('login', 'finalize', () => _finalizeLogin(resp, base, attempt: attempt, client: client));
  }

  /// Обмен подтверждённого push-челленджа на Bearer-токен устройства (десктоп).
  Future<Map<String, dynamic>> loginClaim({
    required String challengeId,
    required String claimToken,
  }) async {
    final attempt = ++_loginGeneration;
    final base = serverUrl;
    if (base == null || base.isEmpty) {
      throw Exception(
          isRu ? 'Не указан адрес сервера' : 'Server address is required');
    }
    final client = api;
    if (client == null) {
      throw Exception(isRu
          ? 'Клиент API не инициализирован — укажите адрес сервера заново'
          : 'API client is not initialized — re-enter the server address');
    }

    await _writeLogoutMarker();
    if (attempt != _loginGeneration || !identical(api, client)) {
      return {'status': 'cancelled'};
    }

    final deviceInfo = DeviceInfoPlugin();
    String deviceName = 'Device';
    String osVersion = '';
    String platform = 'unknown';

    if (kIsWeb) {
      platform = detectWebPlatform(webUserAgent(),
          maxTouchPoints: webMaxTouchPoints());
    } else {
      try {
        if (Platform.isWindows) {
          platform = 'windows';
          final wInfo = await _traceAwait('login_preflight', 'windows_device_info', () => deviceInfo.windowsInfo);
          deviceName = wInfo.computerName;
          osVersion = wInfo.displayVersion;
        } else if (Platform.isAndroid) {
          platform = 'android';
          final aInfo = await _traceAwait('login_preflight', 'android_device_info', () => deviceInfo.androidInfo);
          deviceName = '${aInfo.brand} ${aInfo.model}';
          osVersion = 'Android ${aInfo.version.release}';
        } else if (Platform.isIOS) {
          platform = 'ios';
          final iInfo = await _traceAwait('login_preflight', 'ios_device_info', () => deviceInfo.iosInfo);
          deviceName = iInfo.name;
          osVersion = '${iInfo.systemName} ${iInfo.systemVersion}';
        } else if (Platform.isMacOS) {
          platform = 'macos';
          final mInfo = await _traceAwait('login_preflight', 'macos_device_info', () => deviceInfo.macOsInfo);
          deviceName = mInfo.computerName;
          osVersion = 'macOS ${mInfo.majorVersion}.${mInfo.minorVersion}';
        } else if (Platform.isLinux) {
          platform = 'linux';
          final lInfo = await _traceAwait('login_preflight', 'linux_device_info', () => deviceInfo.linuxInfo);
          deviceName = lInfo.name;
          osVersion = 'Linux';
        }
      } catch (_) {}
    }

    Map<String, dynamic> initialPosture = const {};
    try {
      initialPosture = await _traceAwait('login_claim', 'collect_posture', telemetry.collectPosture);
    } catch (e) {
      debugPrint(
          'auth_state: телеметрия при claim не собрана, продолжаем без неё: $e');
    }

    final resp = await _traceAwait('login_claim', 'request', () => client.loginClaim(
      challengeId: challengeId,
      claimToken: claimToken,
      deviceName: deviceName,
      platform: platform,
      osVersion: osVersion,
      appVersion: appVersion,
      securityPosture: initialPosture,
      windowsIdentity: WindowsIdentity.snapshot(),
      // Пока claim не прошёл generation-check, старый ответ не должен даже
      // менять token внутри переиспользуемого ApiClient.
      updateToken: false,
    ));

    if (attempt != _loginGeneration || !identical(api, client)) {
      return resp;
    }
    if (resp['token'] == null) {
      return resp;
    }

    await _traceAwait('login_claim', 'finalize', () => _finalizeLogin(resp, base, attempt: attempt, client: client));
    return resp;
  }

  Future<void> _finalizeLogin(
    Map<String, dynamic> resp,
    String base, {
    required int attempt,
    required ApiClient client,
  }) async {
    bool isCurrent() =>
        attempt == _loginGeneration && identical(api, client);
    if (!isCurrent()) return;
    // Разбор ответа сервера — безопасно: отсутствие токена/профиля даёт
    // понятную ошибку вместо TypeError/null-краша, отсутствующий
    // security_posture — просто null (сервер досчитает комплаенс сам).
    final respToken = resp['token']?.toString() ?? '';
    final respUser = resp['user'];
    if (respToken.isEmpty || respUser is! Map) {
      throw Exception(isRu
          ? 'Сервер вернул некорректный ответ входа'
          : 'Malformed login response from server');
    }

    final prefs = await SharedPreferences.getInstance();
    await _traceAwait('login', 'secure_storage_write', () => _secureStorage.write(key: _tokenKey, value: respToken));
    await prefs.setString('server_url', base);
    if (!isCurrent()) return; // tombstone остаётся до успешного нового входа
    await prefs.remove(_logoutMarkerKey);
    if (!isCurrent()) {
      await _rollbackCancelledLogin(attempt, respToken, client);
      return;
    }

    client.token = respToken;
    token = respToken;
    currentUser = Map<String, dynamic>.from(respUser);
    _committedLoginGeneration = attempt;
    _updatePerimeter(resp);
    _updatePerimeter(currentUser);
    currentPosture = (resp['security_posture'] is Map)
        ? Map<String, dynamic>.from(resp['security_posture'] as Map)
        : null;
    isCompliant = currentPosture?['is_compliant'] == true;

    // Этап D «умный 2FA»: сервер выдаёт сессии устройства device_id
    // (appLoginResponse.DeviceID) — по нему он отличает вход, начатый с
    // этого же ПК. Сохраняем для восстановления после рестарта.
    final deviceId =
        resp['device_id']?.toString() ?? resp['deviceId']?.toString();
    if (deviceId != null && deviceId.isNotEmpty) {
      _ownDeviceId = deviceId;
      await prefs.setString(LocalDetectService.kDeviceIdPrefKey, deviceId);
    }
    if (!isCurrent()) {
      await _rollbackCancelledLogin(attempt, respToken, client);
      return;
    }

    _loadBrowserSsoAutoApprove();
    _setupServices();
    // Слушатель localhost:8757 поднимаем только после успешного логина.
    if (deviceId != null && deviceId.isNotEmpty) {
      await _traceAwait('login', 'local_detect_start', () => localDetect.start(deviceId));
    }
    if (!isCurrent()) {
      await _rollbackCancelledLogin(attempt, respToken, client);
      return;
    }
    await _traceAwait('login', 'refresh_profile', refreshProfile);
    await _traceAwait('login', 'refresh_cycle', refreshAll);
    if (!isCurrent()) {
      await _rollbackCancelledLogin(attempt, respToken, client);
      return;
    }
    // Фаза 2: после успешного логина один раз предъявляем CP-билет.
    unawaited(presentSsoTicket());
    notifyListeners();
  }

  Future<void> _rollbackCancelledLogin(
      int attempt, String respToken, ApiClient client) async {
    if (_committedLoginGeneration != attempt) return;
    _committedLoginGeneration = 0;
    if (token == respToken && identical(api, client)) {
      token = null;
      currentUser = null;
      client.token = null;
    }
    _pollingTimer?.cancel();
    _pollingTimer = null;
    ws.disconnect();
    telemetry.stopReporting();
    await localDetect.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(LocalDetectService.kDeviceIdPrefKey);
    _ownDeviceId = null;
    notifyListeners();
  }

  Future<void> logout() async {
    _authEpoch++;
    _loginGeneration++;
    _committedLoginGeneration = 0;
    // Сначала durable tombstone: даже failed secure-storage delete и
    // недействительный server logout не смогут воскресить токен при рестарте.
    await _writeLogoutMarker();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    // Д8: ретрай регистрации машины не переживает разлогин.
    _machineRetryTimer?.cancel();
    _machineRetryTimer = null;
    try {
      await _traceAwait('logout', 'server_logout', () async => await api?.logout().timeout(const Duration(seconds: 3)));
    } catch (error) {
      DebugLogService.instance.record('auth.logout.server.failed', error: error);
    }

    // Этап D: сессия устройства завершена — локальный детект больше не
    // должен отвечать device_id этого входа.
    try {
      await _traceAwait('logout', 'local_detect_stop', () => localDetect.stop().timeout(const Duration(seconds: 2)));
    } catch (error) {
      DebugLogService.instance.record('auth.logout.local_detect.failed', error: error);
    }
    ws.disconnect();
    telemetry.stopReporting();
    support.stopScreenSharing();
    support.clearChat();

    // Этап 2: активный RDP-туннель не переживает разлогин — режем сразу
    // (грант закроется сервером по разрыву трубы, повторный /rdp/close не
    // нужен: api уже сбрасывается ниже).
    unawaited(rdp.close(isRu: isRu));
    rdp.closeGrantHandler = null;
    rdpTargets.clear();
    rdpFeatureAvailable = true;
    _rdpHeartbeatTimer?.cancel();
    _rdpHeartbeatTimer = null;
    _instanceRegistered = false;

    // Windows-identity / SSO-состояние не переживает разлогин: proof
    // привязан к сессии устройства, баннер сбрасываем для следующего входа.
    _ssoTicketFlow = null;
    activeBrowserSsoPrompt = null;
    _browserSsoTicket = null;
    browserSsoHasTicket = false;
    browserSsoMachineOk = false;
    _identityBannerDismissed = false;

    token = null;
    currentUser = null;
    api = null;
    activePrompt = null;
    activeSupportPrompt = null;
    activeNotificationPrompt = null;
    activeRelayEndpoint = null;
    activeRelayName = null;
    relays.clear();
    linkHosts.clear();
    linkFeatureAvailable = true;
    linkHostsLoading = false;
    linkHostsError = null;
    pendingChallenges.clear();
    _linkHostsUpdatedAt = null;
    allowedApps.clear();
    history.clear();
    notifications.clear();
    unreadNotificationsCount = 0;
    supportQueue.clear();
    _sosRequestId = null;
    _resolvedChallengeIds.clear();
    _alertedChallengeIds.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove(LocalDetectService.kDeviceIdPrefKey);
    _ownDeviceId = null;
    // Deep-link грант одноразовый и короткоживущий — разлогин обнуляет
    // ожидание (ссылка устареет раньше следующего входа).
    _pendingRdpDeepLink = null;
    // Ш5: autoshare-ожидание тоже привязано к сессии устройства — после
    // logout headless-запуск не срабатывает.
    _autoshareSessionId = null;
    _autoshareStarted = false;
    try {
      await _traceAwait('logout', 'secure_storage_delete', () => _secureStorage.delete(key: _tokenKey));
    } catch (e) {
      debugPrint('auth_state: ошибка удаления токена из secure storage: $e');
    }
    notifyListeners();
  }

  Future<void> refreshAll() async {
    if (!isLoggedIn) return;
    final tasks = <Future>[
      refreshProfile(),
      loadPendingChallenges(),
      loadAllowedApps(),
      loadHistory(),
      loadNotifications(),
      checkPosture(),
      checkSupportSession(),
      refreshRelays(),
      loadRdpTargets(),
      loadLinkHosts(),
      registerRdpMachineAndInstance(),
    ];
    if (isEngineer) {
      tasks.add(loadSupportQueue());
    }
    await Future.wait(tasks);
    // Д8: машина могла не зарегистрироваться (сеть/5xx) — планируем
    // повтор, пока machine_id не появится. Идемпотентно: уже
    // запланированный ретрай или успех ничего не делают.
    _scheduleMachineRetryIfNeeded();
  }

  /// Загрузка RDP-целей «Мой ПК» (этап 2.1). 404/free-лицензия — фича
  /// выключена: список пуст, секция скрыта, НЕ ошибка. Прочие сбои —
  /// debugPrint, прежние данные не трогаем (плитка не мигает).
  Future<void> loadRdpTargets() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;
    try {
      final targets = await _traceAwait('refresh_rdp', 'request', () => client.getRdpTargets(instanceId: instanceId));
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      rdpTargets = targets;
      rdpFeatureAvailable = true;
      notifyListeners();
    } on ApiException catch (e) {
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      if (e.statusCode == 404) {
        rdpFeatureAvailable = false;
        rdpTargets = [];
        notifyListeners();
        return;
      }
      debugPrint('auth_state: ошибка загрузки RDP-целей: $e');
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки RDP-целей: $e');
    }
  }

  /// Loads the authenticated Link inventory. A license denial hides the
  /// feature's data while preserving network and server errors for the UI.
  Future<void> loadLinkHosts() async {
    if (api == null || linkHostsLoading) return;
    if (_linkHostsUpdatedAt == null ||
        DateTime.now().difference(_linkHostsUpdatedAt!) >
            const Duration(seconds: 45)) {
      _markLinkPresenceUnknown();
    }
    final expectedEpoch = _authEpoch;
    linkHostsLoading = true;
    linkHostsError = null;
    notifyListeners();
    try {
      final hosts = await _traceAwait('refresh_link', 'request', () => api!.getLinkHosts());
      if (_authEpoch == expectedEpoch && isLoggedIn) {
        linkHosts = hosts;
        _linkHostsUpdatedAt = DateTime.now();
        linkFeatureAvailable = true;
      }
    } on ApiException catch (e) {
      if (_authEpoch == expectedEpoch && isLoggedIn) {
        if (e.statusCode == 402 || e.statusCode == 403 || e.statusCode == 404) {
          linkFeatureAvailable = false;
          linkHosts = [];
        } else {
          linkHostsError = e.code;
          _markLinkPresenceUnknown();
        }
      }
    } catch (e) {
      if (_authEpoch == expectedEpoch && isLoggedIn) {
        linkHostsError = e.toString();
        _markLinkPresenceUnknown();
      }
    } finally {
      if (_authEpoch == expectedEpoch) {
        linkHostsLoading = false;
        notifyListeners();
      }
    }
  }

  void _markLinkPresenceUnknown() {
    linkHosts = linkHosts
        .map((host) => <String, dynamic>{
              ...host,
              'is_online': null,
            })
        .toList();
  }

  /// Регистрация машины доступа и экземпляра сессии (Sharer/Viewer), запуск heartbeat (V01)
  /// Стабильный ключ установки для идентичности машины (rdp_machines.
  /// machine_public_key): 32 случайных байт hex, генерируется один раз и
  /// живёт в защищённом хранилище (flutter_secure_storage) до удаления
  /// установки. См. комментарий в registerRdpMachineAndInstance.
  String? _machinePublicKey;

  /// Ключ и в легаси-prefs (до A-10), и в secure storage — одинаковый.
  static const String _machinePublicKeyKey = 'machine_public_key';
  Future<String> ensureMachinePublicKey() async {
    final cached = _machinePublicKey;
    if (cached != null && cached.isNotEmpty) return cached;
    // A-10 (аудит 2026-10-12): ключ — идентификатор машины, сервер держит
    // на нём ON CONFLICT-пиннинг. Раньше лежал в SharedPreferences открытым
    // текстом → локальный пользователь мог подменить идентичность машины.
    // Теперь храним во flutter_secure_storage; при загрузке мигрируем
    // старое plaintext-значение (само значение НЕ меняем — сервер считает
    // его идентификатором) и удаляем копию из prefs.
    String? legacyKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      legacyKey = prefs.getString(_machinePublicKeyKey);
      var key = await _secureStorage.read(key: _machinePublicKeyKey);
      if (key == null || key.isEmpty) {
        if (legacyKey != null && legacyKey.isNotEmpty) {
          // Миграция со старых версий: переносим существующее значение,
          // чтобы машина не «размножилась» на сервере новым ключом.
          await _secureStorage.write(
              key: _machinePublicKeyKey, value: legacyKey);
          key = legacyKey;
        } else {
          final rnd = math.Random.secure();
          key = List<int>.generate(32, (_) => rnd.nextInt(256))
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          await _secureStorage.write(key: _machinePublicKeyKey, value: key);
        }
      }
      // Значение уверенно живёт в secure storage — убираем plaintext-копию.
      await prefs.remove(_machinePublicKeyKey);
      _machinePublicKey = key;
      return key;
    } catch (e) {
      debugPrint(
          'auth_state: ошибка secure storage для machine_public_key: $e');
      _machinePublicKey = null;
      rethrow; // upstream registerRdpMachineAndInstance поймает и ретрайнет
    }
  }

  Future<void> registerRdpMachineAndInstance() async {
    if (api == null || !isLoggedIn) return;
    try {
      String hostname = 'Device';
      String osType = 'unknown';
      if (kIsWeb) {
        hostname = 'WebClient';
        osType = 'web';
      } else {
        hostname = Platform.localHostname;
        osType = Platform.operatingSystem;
      }
      final mResp = await api!.rdpRegisterMachine(
        hostname: hostname,
        osType: osType,
        // Стабильный ключ установки: server ON CONFLICT (machine_public_key)
        // держит ОДНУ машину на установку. Без ключа машина = SHA256(device_id
        // + hostname) — каждый перелогин/ротация device-токена создавала
        // НОВУЮ машину, пиннинг rdp_endpoints оставался на старой, промпт
        // консоли уходил офлайн-устройству («Ждём начала трансляции…»).
        // Ключ — идентификатор, не кред: сервер не верифицирует подписи.
        machinePublicKey: await ensureMachinePublicKey(),
        keyAlgorithm: 'INSTALL_RANDOM',
        enclaveType: 'app_storage',
      );
      if (mResp['ok'] == true && mResp['machine_id'] != null) {
        _registeredMachineId = mResp['machine_id'].toString();
      }

      final canShare = !kIsWeb &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
      String? userSid;
      if (!kIsWeb && Platform.isWindows) {
        final winIdent = WindowsIdentity.instance.collect();
        if (winIdent != null) {
          userSid = winIdent.samCompatibleName;
        }
      }

      final iResp = await api!.rdpRegisterInstance(
        instanceId: instanceId,
        machineId: _registeredMachineId,
        installationId: installationId,
        userSid: userSid,
        canShareScreen: canShare,
      );
      if (iResp['ok'] == true) {
        _instanceRegistered = true;
        _startRdpHeartbeat();
        await loadRdpTargets();
      }
    } catch (e) {
      debugPrint('auth_state: ошибка регистрации RDP machine/instance: $e');
    }
  }

  /// Д8: спланировать повторную регистрацию машины, если её id так и не
  /// получен. Безопасно вызывать из любого места (refreshAll, ретрай) —
  /// уже запланированный таймер и успешная регистрация ничего не делают.
  void _scheduleMachineRetryIfNeeded() {
    if (_machineRetryTimer != null) return; // попытка уже запланирована
    if (!isLoggedIn) return;
    if (_registeredMachineId != null && _registeredMachineId!.isNotEmpty) {
      return;
    }
    _machineRetryTimer =
        Timer(machineRetryFirstDelay, _retryMachineRegistration);
  }

  /// Одна итерация ретрая: повторить регистрацию (если id всё ещё нет) и
  /// перепланировать себя с интервалом machineRetryNextDelay. Останавливается
  /// на успехе, при logout/dispose (таймер снят) — спама при успехе нет.
  Future<void> _retryMachineRegistration() async {
    _machineRetryTimer = null;
    if (!isLoggedIn) return;
    if (_registeredMachineId == null || _registeredMachineId!.isEmpty) {
      await registerRdpMachineAndInstance();
    }
    if (!isLoggedIn) return; // logout во время запроса
    if (_registeredMachineId != null && _registeredMachineId!.isNotEmpty) {
      return;
    }
    _machineRetryTimer?.cancel();
    _machineRetryTimer =
        Timer(machineRetryNextDelay, _retryMachineRegistration);
  }

  void _startRdpHeartbeat() {
    _rdpHeartbeatTimer?.cancel();
    _rdpHeartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (api == null || !isLoggedIn || !_instanceRegistered) return;
      try {
        await api!.rdpInstanceHeartbeat(instanceId);
      } catch (e) {
        debugPrint('auth_state: rdp instance heartbeat failed: $e');
      }
    });
  }

  /// Обновление профиля текущего пользователя (включая статус факторов 2FA)
  Future<void> refreshProfile() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || !isLoggedIn || expectedToken == null) return;
    try {
      final p = await client.getProfile();
      // A-38 (аудит 2026-10-10): защита от гонки при logout/смене пользователя
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) {
        debugPrint(
            'auth_state: refreshProfile ответ проигнорирован — авторизация изменилась');
        return;
      }
      currentUser = p;
      _updatePerimeter(p);
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка обновления профиля: $e');
    }
  }

  /// Загрузка и кэширование списка филиальных Relay-узлов
  Future<void> refreshRelays() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    final expectedServerUrl = serverUrl;
    if (client == null || expectedToken == null) return;
    try {
      final cfg = await client.getConfig();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      final freshRelays = cfg['relays'] is List
          ? (cfg['relays'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()
          : <Map<String, dynamic>>[];
      final prefs = await SharedPreferences.getInstance();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      final relayCacheKey = expectedServerUrl != null
          ? 'cached_relays_${expectedServerUrl.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}'
          : 'cached_relays';
      await prefs.setString(relayCacheKey, jsonEncode(freshRelays));
      await prefs.remove('cached_relays');
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      relays = freshRelays;
      notifyListeners();
      // ICE-серверы (STUN/TURN) для WebRTC удаленной помощи (B-1)
      final iceFromCfg = parseIceServersConfig(cfg);
      if (iceFromCfg.isNotEmpty) {
        iceServers = iceFromCfg;
        support.setIceServers(iceFromCfg);
      }
      try {
        final iceRaw = await client.getIceServers();
        if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
        final ice = parseIceServersConfig({'ice_servers': iceRaw});
        if (ice.isNotEmpty) {
          iceServers = ice;
          support.setIceServers(ice);
        }
      } catch (e) {
        debugPrint('auth_state: ошибка получения ice-servers: $e');
      }
    } catch (e) {
      debugPrint('auth_state: ошибка обновления списка relay: $e');
    }
  }

  /// Загрузка очереди входящих обращений на поддержку (для инженеров)
  Future<void> loadSupportQueue() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null || !isEngineer) return;
    try {
      final queue = await client.getSupportQueue();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      supportQueue = queue;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки очереди поддержки: $e');
    }
  }

  /// Подключение инженера к удаленной сессии пользователя (трансляция экрана
  /// приложением). Заявки SOS через Link-агент принимает [claimSOSRequest].
  Future<Map<String, dynamic>> connectToSupportSession(String sessionId) async {
    if (api == null) throw Exception('API не инициализирован');
    final adminName = currentUser?['display_name'] ??
        currentUser?['username'] ??
        'Инженер поддержки';
    final res =
        await api!.connectToSupport(sessionId: sessionId, adminName: adminName);
    await loadSupportQueue();
    return res;
  }

  /// Claim заявки SOS: сервер создаёт сессию к агенту ПК заявителя и выдаёт
  /// цифры, которые инженер диктует сотруднику.
  Future<Map<String, dynamic>> claimSOSRequest(String requestId) async {
    if (api == null) throw Exception('API не инициализирован');
    try {
      return await api!.claimSOSRequest(requestId);
    } finally {
      await loadSupportQueue();
    }
  }

  Future<void> loadPendingChallenges() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;
    try {
      final all = await client.getPendingChallenges();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;

      // browser_sso-челленджи идут отдельным флоу (фаза 2b): их не смешиваем
      // с обычными push-промптами и не показываем как модалку входа.
      final browserSso = <Map<String, dynamic>>[];
      final freshChallenges = all.where((c) {
        final id = c['id']?.toString();
        if (id == null || _resolvedChallengeIds.contains(id)) return false;
        final isBrowserSso = c['type']?.toString() == 'browser_sso' ||
            c['purpose']?.toString() == 'browser_sso';
        if (isBrowserSso) {
          browserSso.add(c);
          return false;
        }
        return true;
      }).toList();
      pendingChallenges = freshChallenges;

      // Polling-доставка browser_sso (WS был offline): нормализуем и
      // показываем; активный/закрытый/истёкший отсеется внутри.
      for (final item in browserSso) {
        if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
        if (activeBrowserSsoPrompt == null) {
          await _surfaceBrowserSso(item);
        }
      }
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;

      final activeId = activePrompt?['challenge_id']?.toString();
      final stillPending = activeId != null &&
          freshChallenges.any((c) => c['id']?.toString() == activeId);

      if (freshChallenges.isEmpty) {
        // Все челленджи закрыты (подтверждены в другом канале — например в
        // Telegram — или истекли): гасим модалку и приоритет окна.
        if (activePrompt != null) {
          activePrompt = null;
          alert.resetWindowPriority();
        }
      } else if (stillPending) {
        // Челлендж ещё жив: поддерживаем в существующем activePrompt свежий
        // остаток TTL — ЕДИНСТВЕННОЕ поле, которое меняется со временем.
        // Остальные поля не трогаем: модалка строит опты number matching
        // один раз, и перегенерация кнопок каждые 4с недопустима. Сама
        // модалка это поле для того же challenge_id не перечитывает
        // (отсчёт локальный), значение — для внешних потребителей.
        final fresh = freshChallenges.firstWhere(
            (c) => c['id']?.toString() == activeId)['expires_in_seconds'];
        if (fresh != null && activePrompt != null) {
          activePrompt!['expires_in_seconds'] = fresh;
        }
      } else {
        // Активного prompt нет, либо он исчез из pending (закрыт в другом
        // канале) — выводим свежейший из очереди. Это и есть показ
        // RADIUS-push из polling-фолбэка (WS был offline/в трее).
        final first = freshChallenges.first;
        final meta = first['metadata'] as Map<String, dynamic>? ?? {};
        final clientIp = meta['client_ip']?.toString();
        final hostIp = meta['host_ip']?.toString();
        final serviceName = meta['service']?.toString() ??
            first['purpose']?.toString() ??
            '2FA Login';
        _surfacePrompt({
          'challenge_id': first['id'],
          'who': meta['username'] ?? currentUser?['username'],
          'ip': (clientIp != null && clientIp.isNotEmpty)
              ? clientIp
              : (meta['ip'] ?? '—'),
          'client_ip': clientIp,
          'host_ip': hostIp,
          'host': meta['host'],
          'device': meta['device'] ?? meta['client'],
          'ua': meta['ua'] ?? meta['device'] ?? '—',
          'service': serviceName,
          'number_match': meta['number_match'],
          'expires_in_seconds': first['expires_in_seconds'],
        });
      }
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки челленджей: $e');
    }
  }

  Future<void> loadAllowedApps() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;
    try {
      final apps = await client.getAllowedApps();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      allowedApps = apps;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки приложений: $e');
    }
  }

  Future<void> loadHistory() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;
    try {
      final items = await client.getHistory();
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      history = items;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки истории: $e');
    }
  }

  Future<void> loadNotifications() async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null || !isLoggedIn) return;
    try {
      final list = await _traceAwait('notifications', 'load', client.getNotifications);
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      notifications = list;
      unreadNotificationsCount = list
          .where((n) => n['is_read'] != true && n['read_at'] == null)
          .length;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки уведомлений: $e');
    }
  }

  Future<void> markNotificationRead(String id) async {
    if (api == null) return;
    try {
      await _traceAwait('notifications', 'mark_read', () => api!.markNotificationRead(id));
      for (var i = 0; i < notifications.length; i++) {
        if (notifications[i]['id'] == id) {
          notifications[i] = Map<String, dynamic>.from(notifications[i])
            ..['is_read'] = true
            ..['read_at'] = DateTime.now().toIso8601String();
          break;
        }
      }
      unreadNotificationsCount = notifications
          .where((n) => n['is_read'] != true && n['read_at'] == null)
          .length;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка отметки прочитанным: $e');
    }
  }

  Future<void> markAllNotificationsRead() async {
    if (api == null) return;
    try {
      await _traceAwait('notifications', 'mark_all_read', () => api!.markAllNotificationsRead());
      for (var i = 0; i < notifications.length; i++) {
        notifications[i] = Map<String, dynamic>.from(notifications[i])
          ..['is_read'] = true
          ..['read_at'] = DateTime.now().toIso8601String();
      }
      unreadNotificationsCount = 0;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка отметки всех прочитанными: $e');
      rethrow;
    }
  }

  Future<void> checkPosture() async {
    if (api == null) return;
    try {
      currentPosture = await telemetry.collectPosture();
      // Аттестация Windows-сессии: флаг расхождения «кто в приложении» и
      // «кто за Windows» — ключевой сигнал мониторинга для сервера.
      final match = windowsIdentityMatch;
      if (currentPosture != null && match != null) {
        currentPosture!['identity_mismatch'] = !match;
      }
      isCompliant = currentPosture?['is_compliant'] == true;
      notifyListeners();
    } catch (_) {}
  }

  /// Решение по push-запросу: подтвердить (approve) или отклонить (deny)
  Future<void> submitDecision({
    required String challengeId,
    required bool approve,
    String? selectedNumberMatch,
    String? code,
    bool? passkey,
  }) async {
    final client = api;
    final expectedEpoch = _authEpoch;
    final expectedToken = token;
    if (client == null || expectedToken == null) return;

    // Снимок карточки ДО закрытия (W08): сохраняем snapshot, но НЕ считаем
    // челлендж завершённым (resolved) до успешного ответа сервера.
    // При отмене биометрии, неверном коде, ошибке сети или 5xx карточка
    // возвращается на экран, чтобы пользователь мог повторить действие.
    final promptSnapshot =
        activePrompt?['challenge_id']?.toString() == challengeId
            ? activePrompt
            : null;
    await alert.resetWindowPriority();

    try {
      if (approve) {
        bool passkeyVerified = passkey ?? false;
        // 1. Если передана явная просьба passkey, или включена GPO политика Windows Hello
        if (passkey == true || gpo.requireWindowsHello) {
          final didAuth = await _traceAwait('challenge_decision', 'passkey_authenticate', () => localAuth.authenticate(
            localizedReason: isRu
                ? 'Подтвердите вход в корпоративную систему с помощью Passkey / биометрии'
                : 'Confirm sign-in with Passkey / biometrics',
            options: const AuthenticationOptions(
                biometricOnly: false, stickyAuth: true),
          ));
          if (!didAuth) {
            throw Exception(isRu
                ? 'Подтверждение Passkey отклонено'
                : 'Passkey authentication rejected');
          }
          passkeyVerified = true;
        } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          // Мобильная биометрия: гейт только если биометрии ЗАРЕГИСТРИРОВАНЫ
          var mobileBiometricsEnrolled = false;
          try {
            mobileBiometricsEnrolled =
                (await _traceAwait('challenge_decision', 'available_biometrics', localAuth.getAvailableBiometrics)).isNotEmpty;
          } catch (error) {
            DebugLogService.instance.record('auth.biometrics.unavailable', error: error);
            // Плагин local_auth недоступен (стенд/эмулятор без биометрии) —
            // не ломаем approve, пропускаем гейт
          }
          if (mobileBiometricsEnrolled) {
            final didAuth = await _traceAwait('challenge_decision', 'mobile_authenticate', () => localAuth.authenticate(
              localizedReason: isRu
                  ? 'Подтвердите вход в корпоративную систему с помощью биометрии'
                  : 'Confirm login with biometrics',
              options: const AuthenticationOptions(
                  biometricOnly: false, stickyAuth: true),
            ));
            if (!didAuth) {
              throw Exception(isRu
                  ? 'Биометрическое подтверждение отклонено'
                  : 'Biometric confirmation rejected');
            }
            passkeyVerified = true;
          }
        } else if (!kIsWeb &&
            (Platform.isMacOS || Platform.isWindows) &&
            (code == null || code.isEmpty)) {
          // Десктоп-аутентификация при подтверждении без TOTP-кода:
          // пробуем вызвать системный Passkey (Touch ID / Windows Hello)
          try {
            final isSupported = await _traceAwait('challenge_decision', 'biometrics_supported', localAuth.isDeviceSupported);
            if (isSupported) {
              final didAuth = await _traceAwait('challenge_decision', 'desktop_authenticate', () => localAuth.authenticate(
                localizedReason: isRu
                    ? 'Подтвердите вход в корпоративную систему (Touch ID / Windows Hello)'
                    : 'Confirm sign-in with Touch ID / Windows Hello',
                options: const AuthenticationOptions(
                    biometricOnly: false, stickyAuth: true),
              ));
              if (didAuth) {
                passkeyVerified = true;
              }
            }
          } catch (_) {}
        }

        // 2. Отправка подтверждения
        await _traceAwait('challenge_decision', 'approve', () => client.challengeDecision(
          challengeId: challengeId,
          decision: 'approve',
          numberMatch: selectedNumberMatch,
          code: code,
          passkey: passkeyVerified,
        ));
      } else {
        await _traceAwait('challenge_decision', 'deny', () => client.challengeDecision(
          challengeId: challengeId,
          decision: 'deny',
        ));
      }

      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) return;
      // Успешно подтверждено сервером: resolved только своего challenge;
      // activePrompt другого challenge, появившийся за время await, не трогаем.
      if (challengeId.isNotEmpty) {
        _resolvedChallengeIds.add(challengeId);
      }
      if (activePrompt?['challenge_id']?.toString() == challengeId) {
        activePrompt = null;
      }
    } catch (e) {
      if (!_isCurrentAuthClient(client, expectedEpoch, expectedToken)) rethrow;
      // W08: Терминальные ошибки (например, промах числа number_match_mismatch или истёкший челлендж)
      // закрывают карточку. Любые временные сбои (отмена биометрии, ошибка сети, 5xx,
      // desktop_confirm_forbidden, invalid_code) восстанавливают карточку для повтора.
      final isTerminal = e is ApiException &&
          (e.code == 'number_match_mismatch' ||
              e.code == 'challenge_expired' ||
              e.code == 'challenge_closed');
      final activeId = activePrompt?['challenge_id']?.toString();

      if (isTerminal) {
        if (challengeId.isNotEmpty) {
          _resolvedChallengeIds.add(challengeId);
        }
        if (activeId == challengeId) activePrompt = null;
      } else {
        if (activePrompt == null || activeId == challengeId) {
          activePrompt = promptSnapshot;
        }
        if (challengeId.isNotEmpty) {
          _resolvedChallengeIds.remove(challengeId);
        }
      }
      notifyListeners();
      rethrow;
    }

    await loadPendingChallenges();
    await loadHistory();
    notifyListeners();
  }

  /// Отправка SOS-заявки на удаленный доступ
  Future<void> requestSupport({
    required String category,
    required String problemSummary,
    String accessMode = 'full_control',
  }) async {
    if (api == null) throw Exception('API не инициализирован');
    final resp = await api!.requestSupport(
      category: category,
      problemSummary: problemSummary,
      accessMode: accessMode,
      targetAgentId: await _localLinkAgentId(),
    );
    final sessId = resp['id']?.toString() ?? '';
    _sosRequestId = resp['sos_v2'] == true && sessId.isNotEmpty ? sessId : null;
    support.setRequested(
      sessionId: sessId,
      category: category,
      problemSummary: problemSummary,
      accessMode: accessMode,
      api: api,
    );
    notifyListeners();
  }

  /// Link-агент этого ПК: свой enrolled-хост с тем же именем компьютера.
  Future<String?> _localLinkAgentId() async {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return null;
    }
    final userId = currentUser?['id']?.toString() ?? '';
    if (userId.isEmpty) return null;
    try {
      final hosts = await _traceAwait('refresh_link', 'request', () => api!.getLinkHosts());
      return sosLocalAgentId(hosts,
          userId: userId, hostname: Platform.localHostname);
    } catch (e) {
      debugPrint('auth_state: Link-агент этого ПК не определён: $e');
      return null;
    }
  }

  /// Owner-режим «Экрана» (этап 2.4, план §5.2): это устройство — ЦЕЛЬ,
  /// владелец открыл экран своего ПК с другого устройства (grant
  /// mode=screen → S3-склейка на сервере → support_prompt с owner:true).
  /// Без accept-диалога и number-match: сразу startScreenSharing().
  ///
  /// Гейты входа:
  /// - адресация (fail-closed, Д3): только точное совпадение
  ///   device/machine (ownerScreenPromptTargetsThisDevice) — иначе
  ///   prompt адресован другому агенту и игнорируется;
  /// - инициатор (initiator_device_id == наш device_id) — это viewer, он
  ///   экран НЕ транслирует.
  /// Дальше — общий запуск startOwnerScreenFromWake (платформа,
  /// идемпотентность, занятость).
  Future<void> _handleOwnerScreenPrompt(Map<String, dynamic> prompt) async {
    final sessionId = prompt['session_id']?.toString() ?? '';
    if (sessionId.isEmpty || api == null) return;

    if (!ownerScreenPromptTargetsThisDevice(
        prompt, _ownDeviceId, _registeredMachineId)) {
      debugPrint(
          'auth_state: owner-экран адресован другому устройству — игнорируем');
      return;
    }

    final initiatorName = prompt['initiator_device_name']?.toString() ??
        prompt['initiator_device']?.toString();
    await startOwnerScreenFromWake(
      sessionId,
      category: prompt['category']?.toString(),
      initiatorDeviceName: initiatorName,
    );
  }

  /// Общий запуск owner-трансляции по session_id — для WS-промпта
  /// (этап 2.4, адресация проверена гейтом выше) и для headless-запуска
  /// по --autoshare (Ш5 Wake: служба-сторож подняла приложение уже с
  /// выбранной сессией — промпт-гейт не нужен, адресация состоялась
  /// локально). Ошибки — только debugPrint, без UI.
  Future<void> startOwnerScreenFromWake(
    String sessionId, {
    String? category,
    String? initiatorDeviceName,
  }) async {
    if (sessionId.isEmpty) return;
    // Локальный биндинг вместо `api!`: между await'ами параллельный
    // logout может сбросить api.
    final client = api;
    if (client == null) return;

    // Платформенный гейт: транслировать экран может только десктоп
    // (getDisplayMedia на мобильных/web недоступен — там только просмотр).
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      debugPrint(
          'auth_state: owner-экран проигнорирован: платформа не может быть целью');
      return;
    }

    // Идемпотентность: эта сессия уже авторизуется/подключается/
    // транслируется (WS-промпт и --autoshare могут прийти вместе), либо
    // по ней открыт accept-диалог — ничего не делаем.
    if (support.activeSessionId == sessionId &&
        (support.state == SupportSessionState.authorizing ||
            support.state == SupportSessionState.connecting ||
            support.state == SupportSessionState.active)) {
      return; // эта сессия уже запускается/транслируется
    }
    if (activeSupportPrompt?['session_id']?.toString() == sessionId) {
      return; // ждём явного решения пользователя по этой сессии
    }

    // Занятость: уже идёт другая трансляция (например, живой SOS к
    // инженеру) — owner-сессия закрывается на сервере, чтобы инициатор
    // сразу увидел завершение, а не молчание.
    if (support.state == SupportSessionState.connecting ||
        support.state == SupportSessionState.active) {
      debugPrint(
          'auth_state: завершаем предыдущую сессию ${support.activeSessionId} для подключения новой owner-сессии $sessionId');
      try {
        await support.stopScreenSharing();
      } catch (e) {
        debugPrint('auth_state: ошибка остановки предыдущей сессии: $e');
      }
    }

    // Ключевое отличие от SOS: accept-диалог (SupportApprovalModal) не
    // показывается — activeSupportPrompt остаётся null.
    support.setAuthorizing(
      sessionId: sessionId,
      category: category,
      accessMode: 'full_control', // свой ПК — всегда полный доступ (§5.2)
      api: client,
      owner: true,
      initiatorDevice: initiatorDeviceName,
    );
    notifyListeners();

    try {
      // Активируем экранную сессию на сервере выбранным Sharer:
      await client.activateOwnerScreen(sessionId, instanceId);

      await support.startScreenSharing(
        sessionId: sessionId,
        api: client,
        accessMode: 'full_control',
      );
    } catch (e) {
      debugPrint('auth_state: не удалось начать трансляцию owner-экрана: $e');
      await support.stopScreenSharing();
      // Не завершаем сессию на сервере при временном локальном сбое захвата,
      // чтобы оператор не получал ложное «Сеанс завершен пользователем».
    }
    notifyListeners();
  }

  /// Ш5 Wake: main() передаёт session_id из argv (--autoshare=<sid>,
  /// запуск службой-сторожем). Запуск owner-трансляции сработает один
  /// раз — когда сессия восстановлена (isLoggedIn) И WS подключен
  /// (isOnline; точка готовности — первый ws.onConnected, см.
  /// wsConnectedAutoshareCheck). Реконнекты WS повторный запуск НЕ
  /// дают. Если сессия не восстановилась (нет токена / 401 → logout) —
  /// молча ничего не происходит, окно остаётся свёрнутым в трее.
  void requestAutoshare(String sessionId) {
    if (sessionId.isEmpty) return;
    _autoshareSessionId = sessionId;
    _autoshareStarted = false;
    _maybeStartAutoshare();
  }

  /// Точка готовности WS для autoshare (вызывается из ws.onConnected).
  /// Публичный метод только для теста защиты от повторного срабатывания
  /// при реконнекте.
  @visibleForTesting
  void wsConnectedAutoshareCheck() => _maybeStartAutoshare();

  void _maybeStartAutoshare() {
    final sid = _autoshareSessionId;
    if (sid == null || _autoshareStarted) return;
    if (!isLoggedIn || !isOnline) return; // ждём сессию и первый коннект
    _autoshareStarted = true; // one-shot: реконнекты не перезапускают
    debugPrint('auth_state: autoshare — headless запуск owner-сессии $sid');
    unawaited(startOwnerScreenFromWake(sid).catchError((Object e) {
      debugPrint('auth_state: autoshare owner-запуск не удался: $e');
    }));
  }

  /// Подтверждение удаленного доступа инженеру (approve) с проверкой контрольного числа
  Future<void> confirmSupport({
    required String sessionId,
    String? numberMatch,
  }) async {
    if (api == null) throw Exception('API не инициализирован');
    activeSupportPrompt = null;
    await alert.resetWindowPriority();

    // 1. Биометрия / Windows Hello при политике GPO (desktop) либо
    // зарегистрированная системная биометрия на мобильном устройстве
    if (gpo.requireWindowsHello) {
      final didAuth = await _traceAwait('support_decision', 'desktop_authenticate', () => localAuth.authenticate(
        localizedReason: isRu
            ? 'Подтвердите разрешение удаленного доступа к экрану'
            : 'Authorize remote screen sharing access',
        options:
            const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      ));
      if (!didAuth) {
        throw Exception(isRu
            ? 'Биометрическая авторизация отклонена'
            : 'Biometric authorization rejected');
      }
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // Мобильная биометрия: гейт только если биометрии ЗАРЕГИСТРИРОВАНЫ
      var mobileBiometricsEnrolled = false;
      try {
        mobileBiometricsEnrolled =
            (await _traceAwait('support_decision', 'available_biometrics', localAuth.getAvailableBiometrics)).isNotEmpty;
      } catch (error) {
        DebugLogService.instance.record('auth.biometrics.unavailable', error: error);
        // Плагин local_auth недоступен (стенд/эмулятор без биометрии) —
        // не ломаем approve, пропускаем гейт
      }
      if (mobileBiometricsEnrolled) {
        final didAuth = await _traceAwait('support_decision', 'mobile_authenticate', () => localAuth.authenticate(
          localizedReason: isRu
              ? 'Подтвердите разрешение удаленного доступа к экрану'
              : 'Authorize remote screen sharing access',
          options: const AuthenticationOptions(
              biometricOnly: false, stickyAuth: true),
        ));
        if (!didAuth) {
          throw Exception(isRu
              ? 'Биометрическая авторизация отклонена'
              : 'Biometric authorization rejected');
        }
      }
    }

    // 2. Одобрение на сервере (SOS через Link-агент сюда не попадает: цифры вводят в окне агента)
    await _traceAwait('support_decision', 'approve', () => api!.supportDecision(
      sessionId: sessionId,
      decision: 'approve',
      numberMatch: numberMatch,
    ));

    // 3. Запуск трансляции экрана WebRTC
    await support.startScreenSharing(
      sessionId: sessionId,
      api: api!,
      accessMode: support.accessMode,
    );
    notifyListeners();
  }

  /// Отклонение входящего запроса на подключение (deny)
  Future<void> rejectSupport({
    required String sessionId,
  }) async {
    if (api == null) return;
    activeSupportPrompt = null;
    await alert.resetWindowPriority();

    try {
      await _traceAwait('support_decision', 'deny', () => api!.supportDecision(
        sessionId: sessionId,
        decision: 'deny',
      ));
    } catch (error) {
      DebugLogService.instance.record('auth.support_decision.failed', error: error, fields: {'session_id': sessionId, 'operation': 'deny'});
    }
    await support.stopScreenSharing();
    notifyListeners();
  }

  bool _isEndingSupport = false;

  /// Завершение сеанса удаленного доступа со стороны пользователя
  Future<void> endSupport() async {
    if (_isEndingSupport) return;
    _isEndingSupport = true;
    try {
      final sosRequestId = _sosRequestId;
      final sessId = support.activeSessionId;
      if (sosRequestId != null && api != null) {
        // Отмена заявки завершает её сессию и закрывает окно агента на ПК.
        _sosRequestId = null;
        try {
          await api!
              .cancelSOSRequest(
                  requestId: sosRequestId, reason: 'cancelled_by_requester')
              .timeout(
                const Duration(milliseconds: 1500),
                onTimeout: () => null,
              );
        } catch (e) {
          debugPrint('auth_state: ошибка отмены заявки SOS: $e');
        }
      } else if (sessId != null && api != null) {
        try {
          await api!.endSupportSession(sessionId: sessId).timeout(
                const Duration(milliseconds: 1500),
                onTimeout: () => null,
              );
        } catch (e) {
          debugPrint('auth_state: ошибка завершения сессии поддержки: $e');
        }
      }
      await support.stopScreenSharing();
      activeSupportPrompt = null;
      notifyListeners();
    } finally {
      _isEndingSupport = false;
    }
  }

  /// Проверка наличия активной сессии поддержки на сервере (периодический поллинг)
  Future<void> checkSupportSession() async {
    if (api == null) return;
    final sosRequestId = _sosRequestId;
    if (sosRequestId != null) {
      await _checkSOSRequest(sosRequestId);
      return;
    }
    try {
      final sess = await api!.getCurrentSupportSession();
      if (sess != null) {
        final status = sess['status']?.toString();
        final sessionId = sess['id']?.toString() ?? '';
        final category = sess['category']?.toString() ?? 'it';
        final summary = sess['problem_summary']?.toString() ?? '';
        final accessMode = sess['access_mode']?.toString() ?? 'full_control';

        // Этап 2.4: owner-сессия «Экрана» (S3 помечает сессию owner=true,
        // план §5.2) видна в /support/current ВСЕМ устройствам юзера, но
        // это не SOS-обращение: ни number-match промпт, ни «Заявка на
        // помощь» по ней не показываются. Управление жизнью — через WS-пуш
        // support_prompt(owner:true)/support_ended и экран viewer'а.
        final isOwnerSess = sess['owner'] == true ||
            sess['mode']?.toString() == 'screen' ||
            (support.ownerSession && sessionId == support.activeSessionId);

        if (status == 'connecting' || status == 'authorizing') {
          final numberMatch = sess['number_match']?.toString() ?? '';
          // Не переспрашиваем подтверждение, когда WebRTC уже устанавливается
          // (connecting) или сессия завершилась ошибкой на клиенте (ended) —
          // пользователь уже одобрил/увидел ошибку.
          if (!isOwnerSess &&
              numberMatch.isNotEmpty &&
              activeSupportPrompt == null &&
              support.state != SupportSessionState.active &&
              support.state != SupportSessionState.connecting &&
              support.state != SupportSessionState.ended) {
            activeSupportPrompt = {
              'session_id': sessionId,
              'category': category,
              'problem_summary': summary,
              'number_match': numberMatch,
              'access_mode': accessMode,
              'admin_name': sess['admin_name'] ?? 'Инженер техподдержки',
            };
            support.setAuthorizing(
              sessionId: sessionId,
              category: category,
              problemSummary: summary,
              accessMode: accessMode,
              api: api,
            );
            final cat = category == '1c'
                ? (isRu ? '1С-поддержка' : '1C Support')
                : (isRu ? 'IT-служба' : 'IT Helpdesk');
            alert.triggerAlert(
              title:
                  isRu ? 'Удаленная помощь: $cat' : 'Remote Assistance: $cat',
              body: isRu
                  ? 'Инженер готов подключиться к экрану. Подтвердите контрольное число.'
                  : 'Engineer is ready to connect. Confirm the number match.',
              challengeId: sessionId,
            );
            notifyListeners();
          }
        } else if (status == 'requested') {
          if (!isOwnerSess &&
              support.state != SupportSessionState.requested &&
              support.state != SupportSessionState.connecting) {
            support.setRequested(
              sessionId: sessionId,
              category: category,
              problemSummary: summary,
              accessMode: accessMode,
              api: api,
            );
            notifyListeners();
          }
        } else if (status == 'ended' ||
            status == 'rejected' ||
            status == 'completed' ||
            status == 'cancelled') {
          if (support.state != SupportSessionState.idle) {
            await support.stopScreenSharing();
          }
          if (activeSupportPrompt != null) {
            activeSupportPrompt = null;
            notifyListeners();
          }
        }
      } else {
        // Если активных сессий на сервере нет (при этом не сбрасываем модалку, пока пользователь в процессе ввода)
        if (support.state == SupportSessionState.requested ||
            support.state == SupportSessionState.connecting) {
          await support.stopScreenSharing();
          activeSupportPrompt = null;
          notifyListeners();
        } else if (support.state == SupportSessionState.authorizing &&
            activeSupportPrompt == null) {
          await support.stopScreenSharing();
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  /// Статус заявки SOS через Link-агент: цифры и экран живут в окне агента,
  /// приложение только отражает этапы заявки (UI обновляет слушатель support).
  Future<void> _checkSOSRequest(String requestId) async {
    final Map<String, dynamic> request;
    try {
      request = await api!.getSOSRequest(requestId);
    } on ApiException catch (e) {
      if ((e.statusCode == 404 || e.statusCode == 403) &&
          _sosRequestId == requestId) {
        _sosRequestId = null;
        await support.stopScreenSharing();
      }
      return;
    } catch (_) {
      return;
    }
    if (_sosRequestId != requestId) return;
    final sessionId = request['active_session_id']?.toString() ?? '';
    switch (request['status']?.toString()) {
      case 'requested':
        if (support.state != SupportSessionState.requested) {
          support.setRequested(
            sessionId: requestId,
            category: request['category']?.toString() ?? 'it',
            problemSummary: request['problem_summary']?.toString() ?? '',
            api: api,
          );
        }
      case 'connecting' || 'active':
        if (sessionId.isNotEmpty) {
          support.setLinkHostedSession(
            sessionId: sessionId,
            active: request['status'] == 'active',
          );
        }
      default:
        _sosRequestId = null;
        await support.stopScreenSharing();
    }
  }

  Map<String, dynamic> get notificationSettings {
    final raw = currentUser?['notification_settings'];
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return {
      'login_success': true,
      'login_denied': true,
      'notify_tg': true,
      'notify_email': true,
    };
  }

  Future<void> updateNotificationSettings({
    required bool loginSuccess,
    required bool loginDenied,
    required bool notifyTG,
    required bool notifyEmail,
  }) async {
    if (api == null) return;
    final res = await _traceAwait('notifications', 'update_settings', () => api!.updateNotificationSettings(
      loginSuccess: loginSuccess,
      loginDenied: loginDenied,
      notifyTG: notifyTG,
      notifyEmail: notifyEmail,
    ));
    if (currentUser != null && res['notification_settings'] != null) {
      currentUser!['notification_settings'] = res['notification_settings'];
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> testNotificationDelivery() async {
    if (api == null) return [];
    return await _traceAwait('notifications', 'test_delivery', () => api!.testNotificationDelivery());
  }

  @override
  void dispose() {
    _loginGeneration++;
    _pollingTimer?.cancel();
    _machineRetryTimer?.cancel();
    unawaited(localDetect.stop());
    ws.disconnect();
    telemetry.stopReporting();
    support.stopScreenSharing();
    // Этап 2: выход из приложения = обрыв туннеля = конец RDP-сессии
    // (дизайн §2.2); грант на сервере закрывается по разрыву WS.
    rdp.dispose();
    super.dispose();
  }
}
