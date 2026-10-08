import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

/// Гейт адресации owner-«Экрана» (этап 2.4): должен ли ЭТОТ клиент начать
/// трансляцию по support_prompt с owner:true. Prompt рассылается ВСЕМ
/// устройствам владельца, поэтому каждый получатель решает локально.
/// Чистая функция — тестируется без WS/сервера (owner_screen_test.dart).
///
/// false (prompt игнорируется), когда:
/// - инициатор — мы сами (initiator_device_id == наш device_id): это
///   устройство — viewer, экран оно не транслирует;
/// - сервер адресовал трансляцию конкретной agent-цели
///   (target_device_id непуст и != наш device_id): это не моя машина.
bool ownerScreenPromptTargetsThisDevice(
    Map<String, dynamic> prompt, String? ownDeviceId) {
  final initiator = prompt['initiator_device_id']?.toString();
  if (initiator != null && initiator.isNotEmpty && initiator == ownDeviceId) {
    return false;
  }
  final target = prompt['target_device_id']?.toString();
  if (target != null && target.isNotEmpty && target != ownDeviceId) {
    return false;
  }
  return true;
}

class AuthState extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _localeKey = 'app_locale';

  String _localeCode = 'ru';
  String get localeCode => _localeCode;
  Locale get locale => Locale(_localeCode);
  bool get isRu => _localeCode.startsWith('ru');

  Future<void> setLocale(String code) async {
    final normalized = code.toLowerCase().startsWith('en') ? 'en' : 'ru';
    if (_localeCode == normalized) return;
    _localeCode = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, normalized);
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

  /// device_id этой сессии (выдаётся сервером при логине, хранится в prefs
  /// под тем же ключом, что у LocalDetectService). Режиму «Экран» (этап
  /// 2.4, план §5.2) он нужен, чтобы отличить инициатора от цели: пуш
  /// support_prompt с owner:true уходит ВСЕМ устройствам юзера, а делиться
  /// экраном должно только устройство-цель (инициатор — viewer).
  String? _ownDeviceId;
  String? get ownDeviceId => _ownDeviceId;

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
  Future<Map<String, dynamic>> grantRdpTargetBridge(String targetId) async {
    final client = api;
    if (client == null) {
      throw ApiException(401, 'not_authenticated');
    }
    return client.rdpGrant(targetId: targetId, mode: 'bridge');
  }

  /// ICE-серверы (STUN/TURN) из /api/v1/app/config для WebRTC-сессий
  /// удаленной помощи (агент + операторский экран в приложении).
  List<Map<String, dynamic>> iceServers = [];
  String? activeRelayEndpoint;
  String? activeRelayName;
  bool get isUsingRelay => activeRelayEndpoint != null;
  String get connectionStatusText => isOnline ? (isUsingRelay ? 'Online ($activeRelayName)' : 'Online') : 'Offline';

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
        final (code, expiresAt) = await client.submitSsoTicket(ticket);
        return SsoSubmitResponse(code, expiresAt: expiresAt);
      } catch (_) {
        return null; // транспорт — тихо
      }
    });
    try {
      final ticket = await _ssoTicketReader.readTicket();
      final outcome = await _ssoTicketFlow!.present(ticket?.value);
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
    await prefs.setBool(_browserSsoAutoKey, value);
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
    _browserSsoTicket = ticket;
    browserSsoHasTicket = ticket != null && ticket.isNotEmpty;
    browserSsoMachineOk = machineMatches(
      prompt['machine']?.toString(),
      identity?.computerName,
    );

    final autoAllowed = prompt['auto_allowed'] == true;
    if (autoAllowed && _browserSsoAutoApprove && browserSsoHasTicket && browserSsoMachineOk) {
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

    activeBrowserSsoPrompt = null;
    _resolvedChallengeIds.add(id);
    notifyListeners();

    if (api == null) return;
    final useApprove = approve && browserSsoHasTicket && browserSsoMachineOk;
    if (approve && !useApprove) {
      debugPrint('auth_state: browser_sso approve без живого билета — отправляем deny');
    }
    try {
      await api!.browserSsoDecision(
        challengeId: id,
        approve: useApprove,
        ssoTicket: useApprove ? _browserSsoTicket : null,
      );
    } catch (e) {
      debugPrint('auth_state: browser_sso decision отклонён сервером: $e');
    }
  }

  String get username => currentUser?['username']?.toString() ?? '';
  String get displayName {
    final dn = currentUser?['display_name']?.toString();
    if (dn != null && dn.isNotEmpty) return dn;
    return username;
  }

  bool get isAdmin => currentUser?['role'] == 'admin';

  List<String> get supportRoles {
    final raw = currentUser?['support_roles'];
    if (raw is List) {
      return raw.map((e) => e.toString().toLowerCase()).toList();
    }
    return [];
  }

  bool get isITEngineer => isAdmin || supportRoles.contains('it');
  bool get is1CEngineer => isAdmin || supportRoles.contains('1c');
  bool get isEngineer => isAdmin || supportRoles.isNotEmpty;

  String? get engineerBadge {
    if (isAdmin) return isRu ? '👑 Администратор' : '👑 Administrator';
    if (isITEngineer && is1CEngineer) return isRu ? '🛠 IT / 1С-инженер' : '🛠 IT / 1C Engineer';
    if (is1CEngineer) return isRu ? '📊 1С-инженер' : '📊 1C Engineer';
    if (isITEngineer) return isRu ? '🖥 IT-инженер' : '🖥 IT Engineer';
    if (supportRoles.isNotEmpty) {
      return isRu ? '🛠 Инженер (${supportRoles.join(", ")})' : '🛠 Engineer (${supportRoles.join(", ")})';
    }
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
    final prefs = await SharedPreferences.getInstance();

    final savedLocale = prefs.getString(_localeKey);
    if (savedLocale != null && savedLocale.isNotEmpty) {
      _localeCode = savedLocale.toLowerCase().startsWith('en') ? 'en' : 'ru';
    } else {
      final sysLang = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
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
        debugPrint('auth_state: GPO ServerURL отклонён валидатором — URL не используется');
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
          debugPrint('auth_state: сохранённый server_url отклонён валидатором — URL не используется');
        }
      }
    }

    final cachedRelaysRaw = prefs.getString('cached_relays');
    if (cachedRelaysRaw != null && cachedRelaysRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedRelaysRaw);
        if (decoded is List) {
          relays = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
    }

    // Миграция: ранее токен хранился в SharedPreferences в открытом виде.
    // При первом запуске новой версии переносим его в безопасное хранилище
    // и удаляем plaintext-копию.
    final legacyToken = prefs.getString(_tokenKey);
    if (legacyToken != null && legacyToken.isNotEmpty) {
      try {
        final existing = await _secureStorage.read(key: _tokenKey);
        if (existing == null || existing.isEmpty) {
          await _secureStorage.write(key: _tokenKey, value: legacyToken);
        }
        await prefs.remove(_tokenKey);
      } catch (e) {
        debugPrint('auth_state: ошибка миграции токена в secure storage: $e');
      }
    }

    String? savedToken;
    try {
      savedToken = await _secureStorage.read(key: _tokenKey);
    } catch (e) {
      debugPrint('auth_state: ошибка чтения токена из secure storage: $e');
    }

    if (serverUrl != null && savedToken != null) {
      api = ApiClient(baseUrl: serverUrl!, token: savedToken);
      token = savedToken;

      try {
        currentUser = await api!.getProfile();
        // Этап D «умный 2FA»: восстанавливаем локальный детект по device_id,
        // сохранённому при логине (сессия устройства живёт и через рестарт
        // приложения, пока не был logout).
        final savedDeviceId = prefs.getString(LocalDetectService.kDeviceIdPrefKey);
        if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
          _ownDeviceId = savedDeviceId;
          unawaited(localDetect.start(savedDeviceId));
        }
        await _loadBrowserSsoAutoApprove();
        _setupServices();
        await refreshAll();
        // Фаза 2: предъявляем CP-билет при старте сессии (TTL ~5 мин с
        // входа в Windows) — тихо, любой сбой не влияет на работу.
        unawaited(presentSsoTicket());
      } catch (e) {
        debugPrint('auth_state: токен недействителен или сервер недоступен: $e');
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
    if (cid != null && cid.isNotEmpty && isNew && !_alertedChallengeIds.contains(cid)) {
      _alertedChallengeIds.add(cid);
      final clientIp = prompt['client_ip'] ?? prompt['ip'] ?? '—';
      final hostIp = prompt['host_ip'];
      final ipText = hostIp != null ? '$clientIp → $hostIp' : '$clientIp';
      final sName = prompt['service'] ?? 'Ligament 2FA';
      final who = prompt['who'] ?? (isRu ? 'Сотрудник' : 'Employee');
      final host = prompt['host']?.toString();
      final pcPart = (host != null && host.isNotEmpty) ? (isRu ? ' · Имя ПК: $host' : ' · PC: $host') : '';
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
      final title = msg['title']?.toString() ?? (isRu ? 'Уведомление' : 'Notification');
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
        loadSupportQueue();
        final session = (msg['session'] is Map) ? Map<String, dynamic>.from(msg['session'] as Map) : msg;
        final clientName = session['display_name'] ?? session['employee_name'] ?? session['username'] ?? msg['display_name'] ?? (isRu ? 'Пользователь' : 'User');
        final category = session['category'] ?? msg['category'];
        final catTitle = category == '1c' ? '1C' : 'IT';
        final problemSummary = session['problem_summary'] ?? msg['problem_summary'] ?? '';
        final sessionId = session['id'] ?? session['session_id'] ?? msg['session_id'];
        alert.triggerAlert(
          title: isRu ? 'Новое SOS-обращение: $catTitle' : 'New SOS Ticket: $catTitle',
          body: '$clientName: $problemSummary',
          challengeId: sessionId?.toString(),
        );
      }
    };

    ws.onConnected = () {
      isOnline = true;
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
      if (uri == null || !uri.hasScheme || uri.scheme != 'https' || uri.host.isEmpty) {
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
    serverUrl = url.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', serverUrl!);
    api = ApiClient(baseUrl: serverUrl!);
    notifyListeners();
  }

  Future<void> login(String username, String password, [String? code]) async {
    final base = serverUrl;
    if (base == null || base.isEmpty) {
      throw Exception(isRu ? 'Не указан адрес сервера' : 'Server address is required');
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

    final deviceInfo = DeviceInfoPlugin();
    String deviceName = 'Device';
    String osVersion = '';
    String platform = 'unknown';

    if (kIsWeb) {
      // PWA: честная платформа по UA (web-ios/web-android/web) — строка
      // устройства рождается правильной, без ожидания телеметрии-лечения.
      platform = detectWebPlatform(webUserAgent(), maxTouchPoints: webMaxTouchPoints());
    } else {
      try {
        if (Platform.isWindows) {
          platform = 'windows';
          final wInfo = await deviceInfo.windowsInfo;
          deviceName = wInfo.computerName;
          osVersion = wInfo.displayVersion;
        } else if (Platform.isAndroid) {
          platform = 'android';
          final aInfo = await deviceInfo.androidInfo;
          deviceName = '${aInfo.brand} ${aInfo.model}';
          osVersion = 'Android ${aInfo.version.release}';
        } else if (Platform.isIOS) {
          platform = 'ios';
          final iInfo = await deviceInfo.iosInfo;
          deviceName = iInfo.name;
          osVersion = '${iInfo.systemName} ${iInfo.systemVersion}';
        } else if (Platform.isMacOS) {
          platform = 'macos';
          final mInfo = await deviceInfo.macOsInfo;
          deviceName = mInfo.computerName;
          osVersion = 'macOS ${mInfo.majorVersion}.${mInfo.minorVersion}';
        } else if (Platform.isLinux) {
          platform = 'linux';
          final lInfo = await deviceInfo.linuxInfo;
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
      initialPosture = await telemetry.collectPosture();
    } catch (e) {
      debugPrint('auth_state: телеметрия при входе не собрана, продолжаем без неё: $e');
    }

    final resp = await client.login(
      username: username,
      password: password,
      code: code,
      deviceName: deviceName,
      platform: platform,
      osVersion: osVersion,
      appVersion: kAppVersion,
      securityPosture: initialPosture,
      windowsIdentity: WindowsIdentity.snapshot(),
    );

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
    token = respToken;
    currentUser = Map<String, dynamic>.from(respUser);
    currentPosture = (resp['security_posture'] is Map)
        ? Map<String, dynamic>.from(resp['security_posture'] as Map)
        : null;
    isCompliant = currentPosture?['is_compliant'] == true;

    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(key: _tokenKey, value: respToken);
    await prefs.setString('server_url', base);

    // Этап D «умный 2FA»: сервер выдаёт сессии устройства device_id
    // (appLoginResponse.DeviceID) — по нему он отличает вход, начатый с
    // этого же ПК. Сохраняем для восстановления после рестарта.
    final deviceId = resp['device_id']?.toString() ?? resp['deviceId']?.toString();
    if (deviceId != null && deviceId.isNotEmpty) {
      _ownDeviceId = deviceId;
      await prefs.setString(LocalDetectService.kDeviceIdPrefKey, deviceId);
    }

    _loadBrowserSsoAutoApprove();
    _setupServices();
    // Слушатель localhost:8757 поднимаем только после успешного логина.
    if (deviceId != null && deviceId.isNotEmpty) {
      await localDetect.start(deviceId);
    }
    await refreshAll();
    // Фаза 2: после успешного логина один раз предъявляем CP-билет.
    unawaited(presentSsoTicket());
    notifyListeners();
  }

  Future<void> logout() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    try {
      await api?.logout();
    } catch (_) {}

    // Этап D: сессия устройства завершена — локальный детект больше не
    // должен отвечать device_id этого входа.
    await localDetect.stop();
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
    pendingChallenges.clear();
    allowedApps.clear();
    history.clear();
    notifications.clear();
    unreadNotificationsCount = 0;
    supportQueue.clear();
    _resolvedChallengeIds.clear();
    _alertedChallengeIds.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove(LocalDetectService.kDeviceIdPrefKey);
    _ownDeviceId = null;
    // Deep-link грант одноразовый и короткоживущий — разлогин обнуляет
    // ожидание (ссылка устареет раньше следующего входа).
    _pendingRdpDeepLink = null;
    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (e) {
      debugPrint('auth_state: ошибка удаления токена из secure storage: $e');
    }
    notifyListeners();
  }

  Future<void> refreshAll() async {
    if (!isLoggedIn) return;
    final tasks = <Future>[
      loadPendingChallenges(),
      loadAllowedApps(),
      loadHistory(),
      loadNotifications(),
      checkPosture(),
      checkSupportSession(),
      refreshRelays(),
      loadRdpTargets(),
    ];
    if (isEngineer) {
      tasks.add(loadSupportQueue());
    }
    await Future.wait(tasks);
  }

  /// Загрузка RDP-целей «Мой ПК» (этап 2.1). 404/free-лицензия — фича
  /// выключена: список пуст, секция скрыта, НЕ ошибка. Прочие сбои —
  /// debugPrint, прежние данные не трогаем (плитка не мигает).
  Future<void> loadRdpTargets() async {
    if (api == null) return;
    try {
      rdpTargets = await api!.getRdpTargets();
      rdpFeatureAvailable = true;
      notifyListeners();
    } on ApiException catch (e) {
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

  /// Загрузка и кэширование списка филиальных Relay-узлов
  Future<void> refreshRelays() async {
    if (api == null) return;
    try {
      final cfg = await api!.getConfig();
      if (cfg['relays'] is List) {
        relays = (cfg['relays'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cached_relays', jsonEncode(relays));
        notifyListeners();
      }
      // ICE-серверы (STUN/TURN) для WebRTC удаленной помощи (B-1)
      final ice = parseIceServersConfig(cfg);
      if (ice.isNotEmpty) {
        iceServers = ice;
        support.setIceServers(ice);
      }
    } catch (e) {
      debugPrint('auth_state: ошибка обновления списка relay: $e');
    }
  }

  /// Загрузка очереди входящих обращений на поддержку (для инженеров)
  Future<void> loadSupportQueue() async {
    if (api == null || !isEngineer) return;
    try {
      supportQueue = await api!.getSupportQueue();
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки очереди поддержки: $e');
    }
  }

  /// Подключение инженера к удаленной сессии пользователя
  Future<Map<String, dynamic>> connectToSupportSession(String sessionId) async {
    if (api == null) throw Exception('API не инициализирован');
    final adminName = currentUser?['display_name'] ?? currentUser?['username'] ?? 'Инженер поддержки';
    final res = await api!.connectToSupport(sessionId: sessionId, adminName: adminName);
    await loadSupportQueue();
    return res;
  }

  Future<void> loadPendingChallenges() async {
    if (api == null) return;
    try {
      final all = await api!.getPendingChallenges();

      // browser_sso-челленджи идут отдельным флоу (фаза 2b): их не смешиваем
      // с обычными push-промптами и не показываем как модалку входа.
      final browserSso = <Map<String, dynamic>>[];
      pendingChallenges = all.where((c) {
        final id = c['id']?.toString();
        if (id == null || _resolvedChallengeIds.contains(id)) return false;
        final isBrowserSso =
            c['type']?.toString() == 'browser_sso' || c['purpose']?.toString() == 'browser_sso';
        if (isBrowserSso) {
          browserSso.add(c);
          return false;
        }
        return true;
      }).toList();

      // Polling-доставка browser_sso (WS был offline): нормализуем и
      // показываем; активный/закрытый/истёкший отсеется внутри.
      for (final item in browserSso) {
        if (activeBrowserSsoPrompt == null) {
          await _surfaceBrowserSso(item);
        }
      }

      final activeId = activePrompt?['challenge_id']?.toString();
      final stillPending = activeId != null &&
          pendingChallenges.any((c) => c['id']?.toString() == activeId);

      if (pendingChallenges.isEmpty) {
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
        final fresh = pendingChallenges
            .firstWhere((c) => c['id']?.toString() == activeId)['expires_in_seconds'];
        if (fresh != null && activePrompt != null) {
          activePrompt!['expires_in_seconds'] = fresh;
        }
      } else {
        // Активного prompt нет, либо он исчез из pending (закрыт в другом
        // канале) — выводим свежейший из очереди. Это и есть показ
        // RADIUS-push из polling-фолбэка (WS был offline/в трее).
        final first = pendingChallenges.first;
        final meta = first['metadata'] as Map<String, dynamic>? ?? {};
        final clientIp = meta['client_ip']?.toString();
        final hostIp = meta['host_ip']?.toString();
        final serviceName = meta['service']?.toString() ?? first['purpose']?.toString() ?? '2FA Login';
        _surfacePrompt({
          'challenge_id': first['id'],
          'who': meta['username'] ?? currentUser?['username'],
          'ip': (clientIp != null && clientIp.isNotEmpty) ? clientIp : (meta['ip'] ?? '—'),
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
    if (api == null) return;
    try {
      allowedApps = await api!.getAllowedApps();
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки приложений: $e');
    }
  }

  Future<void> loadHistory() async {
    if (api == null) return;
    try {
      history = await api!.getHistory();
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки истории: $e');
    }
  }

  Future<void> loadNotifications() async {
    if (api == null || !isLoggedIn) return;
    try {
      final list = await api!.getNotifications();
      notifications = list;
      unreadNotificationsCount = list.where((n) => n['is_read'] != true && n['read_at'] == null).length;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка загрузки уведомлений: $e');
    }
  }

  Future<void> markNotificationRead(String id) async {
    if (api == null) return;
    try {
      await api!.markNotificationRead(id);
      for (var i = 0; i < notifications.length; i++) {
        if (notifications[i]['id'] == id) {
          notifications[i] = Map<String, dynamic>.from(notifications[i])
            ..['is_read'] = true
            ..['read_at'] = DateTime.now().toIso8601String();
          break;
        }
      }
      unreadNotificationsCount = notifications.where((n) => n['is_read'] != true && n['read_at'] == null).length;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка отметки прочитанным: $e');
    }
  }

  Future<void> markAllNotificationsRead() async {
    if (api == null) return;
    try {
      await api!.markAllNotificationsRead();
      for (var i = 0; i < notifications.length; i++) {
        notifications[i] = Map<String, dynamic>.from(notifications[i])
          ..['is_read'] = true
          ..['read_at'] = DateTime.now().toIso8601String();
      }
      unreadNotificationsCount = 0;
      notifyListeners();
    } catch (e) {
      debugPrint('auth_state: ошибка отметки всех прочитанными: $e');
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
  }) async {
    if (api == null) return;

    // Снимок карточки ДО закрытия: при 403 desktop_confirm_forbidden
    // (вход начат с этого же ПК — этап D) карточка возвращается на экран.
    final promptSnapshot = activePrompt;
    if (challengeId.isNotEmpty) {
      _resolvedChallengeIds.add(challengeId);
    }
    activePrompt = null;
    await alert.resetWindowPriority();

    if (approve) {
      // 1. Если включена GPO политика Windows Hello (desktop) или на мобильном
      // устройстве зарегистрирована системная биометрия (отпечаток / Face ID)
      if (gpo.requireWindowsHello) {
        final didAuth = await localAuth.authenticate(
          localizedReason: isRu
              ? 'Подтвердите вход в корпоративную систему с помощью Windows Hello'
              : 'Confirm login with Windows Hello / biometrics',
          options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
        );
        if (!didAuth) {
          throw Exception(isRu
              ? 'Подтверждение Windows Hello отклонено'
              : 'Windows Hello authentication rejected');
        }
      } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        // Мобильная биометрия: гейт только если биометрии ЗАРЕГИСТРИРОВАНЫ
        var mobileBiometricsEnrolled = false;
        try {
          mobileBiometricsEnrolled =
              (await localAuth.getAvailableBiometrics()).isNotEmpty;
        } catch (_) {
          // Плагин local_auth недоступен (стенд/эмулятор без биометрии) —
          // не ломаем approve, пропускаем гейт
        }
        if (mobileBiometricsEnrolled) {
          final didAuth = await localAuth.authenticate(
            localizedReason: isRu
                ? 'Подтвердите вход в корпоративную систему с помощью биометрии'
                : 'Confirm login with biometrics',
            options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
          );
          if (!didAuth) {
            throw Exception(isRu
                ? 'Биометрическое подтверждение отклонено'
                : 'Biometric confirmation rejected');
          }
        }
      }

      // 2. Отправка подтверждения
      try {
        await api!.challengeDecision(
          challengeId: challengeId,
          decision: 'approve',
          numberMatch: selectedNumberMatch,
        );
      } on ApiException catch (e) {
        if (e.statusCode == 403 && e.code == 'desktop_confirm_forbidden') {
          // Сервер запретил подтверждать вход с того же ПК, с которого он
          // начат: карточка ВОЗВРАЩАЕТСЯ — id вынимается из resolved (чтобы
          // polling-тик не счёл челлендж закрытым и не погасил модалку),
          // снимок восстанавливается, ошибка уходит в модал с пояснением
          // «подтвердите с телефона или введите код».
          _resolvedChallengeIds.remove(challengeId);
          activePrompt = promptSnapshot;
          notifyListeners();
        }
        rethrow;
      }
    } else {
      await api!.challengeDecision(
        challengeId: challengeId,
        decision: 'deny',
      );
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
    );
    final sessId = resp['id']?.toString() ?? '';
    support.setRequested(
      sessionId: sessId,
      category: category,
      problemSummary: problemSummary,
      accessMode: accessMode,
      api: api,
    );
    notifyListeners();
  }

  /// Owner-режим «Экрана» (этап 2.4, план §5.2): это устройство — ЦЕЛЬ,
  /// владелец открыл экран своего ПК с другого устройства (grant
  /// mode=screen → S3-склейка на сервере → support_prompt с owner:true).
  /// Без accept-диалога и number-match: сразу startScreenSharing().
  ///
  /// Гейты:
  /// - инициатор (initiator_device_id == наш device_id) — это viewer, он
  ///   экран НЕ транслирует;
  /// - точечная адресация agent-цели (target_device_id непуст и не наш
  ///   device_id) — это не моя машина, prompt адресован другому агенту;
  /// - мобильные/web цели не поддержаны (getDisplayMedia нет) — «Экран»
  ///   открывают только НА десктоп, с телефона — только просмотр;
  /// - занятость: уже идёт другая трансляция (например, живой SOS к
  ///   инженеру) — owner-сессия закрывается на сервере, чтобы инициатор
  ///   сразу увидел завершение, а не молчание.
  Future<void> _handleOwnerScreenPrompt(Map<String, dynamic> prompt) async {
    final sessionId = prompt['session_id']?.toString() ?? '';
    if (sessionId.isEmpty || api == null) return;

    if (!ownerScreenPromptTargetsThisDevice(prompt, _ownDeviceId)) {
      debugPrint(
          'auth_state: owner-экран адресован другому устройству — игнорируем');
      return;
    }

    if (kIsWeb || !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      debugPrint('auth_state: owner-экран проигнорирован: платформа не может быть целью');
      return;
    }

    if (support.activeSessionId == sessionId &&
        (support.state == SupportSessionState.connecting ||
            support.state == SupportSessionState.active)) {
      return; // эта сессия уже транслируется
    }

    if (support.state == SupportSessionState.connecting ||
        support.state == SupportSessionState.active) {
      debugPrint('auth_state: owner-экран отклонён — уже идёт другая сессия поддержки');
      try {
        await api!.endSupportSession(sessionId: sessionId);
      } catch (_) {}
      return;
    }

    final initiatorName = prompt['initiator_device_name']?.toString() ??
        prompt['initiator_device']?.toString();
    // Ключевое отличие от SOS: accept-диалог (SupportApprovalModal) не
    // показывается — activeSupportPrompt остаётся null.
    support.setAuthorizing(
      sessionId: sessionId,
      category: prompt['category']?.toString(),
      accessMode: 'full_control', // свой ПК — всегда полный доступ (§5.2)
      api: api,
      owner: true,
      initiatorDevice: initiatorName,
    );
    notifyListeners();

    try {
      await support.startScreenSharing(
        sessionId: sessionId,
        api: api!,
        accessMode: 'full_control',
      );
    } catch (e) {
      debugPrint('auth_state: не удалось начать трансляцию owner-экрана: $e');
      await support.stopScreenSharing();
      // Сессию закрываем на сервере — инициатор увидит support_ended,
      // а не зависший «ожидание экрана».
      try {
        await api!.endSupportSession(sessionId: sessionId);
      } catch (_) {}
    }
    notifyListeners();
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
      final didAuth = await localAuth.authenticate(
        localizedReason: isRu
            ? 'Подтвердите разрешение удаленного доступа к экрану'
            : 'Authorize remote screen sharing access',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
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
            (await localAuth.getAvailableBiometrics()).isNotEmpty;
      } catch (_) {
        // Плагин local_auth недоступен (стенд/эмулятор без биометрии) —
        // не ломаем approve, пропускаем гейт
      }
      if (mobileBiometricsEnrolled) {
        final didAuth = await localAuth.authenticate(
          localizedReason: isRu
              ? 'Подтвердите разрешение удаленного доступа к экрану'
              : 'Authorize remote screen sharing access',
          options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
        );
        if (!didAuth) {
          throw Exception(isRu
              ? 'Биометрическая авторизация отклонена'
              : 'Biometric authorization rejected');
        }
      }
    }

    // 2. Отправка одобрения на сервер
    await api!.supportDecision(
      sessionId: sessionId,
      decision: 'approve',
      numberMatch: numberMatch,
    );

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
      await api!.supportDecision(
        sessionId: sessionId,
        decision: 'deny',
      );
    } catch (_) {}
    await support.stopScreenSharing();
    notifyListeners();
  }

  bool _isEndingSupport = false;

  /// Завершение сеанса удаленного доступа со стороны пользователя
  Future<void> endSupport() async {
    if (_isEndingSupport) return;
    _isEndingSupport = true;
    try {
      final sessId = support.activeSessionId;
      if (sessId != null && api != null) {
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
              title: isRu ? 'Удаленная помощь: $cat' : 'Remote Assistance: $cat',
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
        } else if (status == 'ended' || status == 'rejected' || status == 'completed' || status == 'cancelled') {
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
        } else if (support.state == SupportSessionState.authorizing && activeSupportPrompt == null) {
          await support.stopScreenSharing();
          notifyListeners();
        }
      }
    } catch (_) {}
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
    final res = await api!.updateNotificationSettings(
      loginSuccess: loginSuccess,
      loginDenied: loginDenied,
      notifyTG: notifyTG,
      notifyEmail: notifyEmail,
    );
    if (currentUser != null && res['notification_settings'] != null) {
      currentUser!['notification_settings'] = res['notification_settings'];
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> testNotificationDelivery() async {
    if (api == null) return [];
    return await api!.testNotificationDelivery();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
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
