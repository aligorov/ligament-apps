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
import 'alert_service.dart';
import 'gpo_service.dart';
import 'support_service.dart';
import 'telemetry_service.dart';
import 'ws_service.dart';

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
  final TelemetryService telemetry = TelemetryService();
  final WebSocketService ws = WebSocketService();
  final LocalAuthentication localAuth = LocalAuthentication();
  final SupportService support = SupportService();

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

  List<Map<String, dynamic>> pendingChallenges = [];
  List<Map<String, dynamic>> allowedApps = [];
  List<Map<String, dynamic>> history = [];
  List<Map<String, dynamic>> supportQueue = [];
  Map<String, dynamic>? currentPosture;
  bool isCompliant = true;
  bool isOnline = false;
  List<Map<String, dynamic>> relays = [];
  String? activeRelayEndpoint;
  String? activeRelayName;
  bool get isUsingRelay => activeRelayEndpoint != null;
  String get connectionStatusText => isOnline ? (isUsingRelay ? 'Online ($activeRelayName)' : 'Online') : 'Offline';

  Map<String, dynamic>? activePrompt;
  Map<String, dynamic>? activeSupportPrompt;
  Timer? _pollingTimer;
  bool _isPollingInFlight = false;
  final Set<String> _resolvedChallengeIds = {};
  // Челленджи, по которым уже сработал alert (звук + вывод окна/нотификация):
  // WS и polling оба могут доставить один и тот же prompt — алерт
  // срабатывает один раз на челлендж, без повторов каждые 4 секунды.
  final Set<String> _alertedChallengeIds = {};

  bool get isLoggedIn => token != null && currentUser != null;

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

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final savedLocale = prefs.getString(_localeKey);
    if (savedLocale != null && savedLocale.isNotEmpty) {
      _localeCode = savedLocale.toLowerCase().startsWith('en') ? 'en' : 'ru';
    } else {
      final sysLang = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
      _localeCode = sysLang.startsWith('en') ? 'en' : 'ru';
    }

    // Если GPO принудительно задает ServerURL, используем его
    serverUrl = gpo.enforcedServerUrl ?? prefs.getString('server_url');

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
        _setupServices();
        await refreshAll();
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
      alert.triggerAlert(
        title: isRu ? 'Запрос на вход: $sName' : 'Login Request: $sName',
        body: '$who (IP: $ipText)',
        challengeId: cid,
      );
    }
    notifyListeners();
  }

  void _setupServices() {
    if (api == null || token == null || serverUrl == null) return;

    // 1. WebSocket для мгновенных push-оповещений
    ws.onPrompt = (prompt) {
      _surfacePrompt(prompt);
      loadPendingChallenges();
    };

    ws.onSupportPrompt = (prompt) {
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

    if (api != null) {
      support.setApi(api!);
    }
    support.removeListener(notifyListeners);
    support.addListener(notifyListeners);

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
      notifyListeners();
    };

    ws.onDisconnected = () {
      isOnline = false;
      notifyListeners();
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
      baseUrl: serverUrl!,
      token: token!,
      fallbackUrls: fallbackRelayUrls,
    );

    // 2. Телеметрия и контроль комплаенса
    telemetry.startReporting(api!);

    // 3. Периодический опрос pending-запросов и сессий поддержки (fallback при временном обрыве WS)
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!isLoggedIn || _isPollingInFlight) return;
      // Не порождаем новый цикл опроса, пока предыдущий еще выполняется
      _isPollingInFlight = true;
      try {
        await loadPendingChallenges();
        await checkSupportSession();
        if (isEngineer) {
          await loadSupportQueue();
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
    if (serverUrl == null || serverUrl!.isEmpty) {
      throw Exception(isRu ? 'Не указан адрес сервера' : 'Server address is required');
    }

    final deviceInfo = DeviceInfoPlugin();
    String deviceName = 'Device';
    String osVersion = '';
    String platform = 'unknown';

    if (!kIsWeb) {
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

    final initialPosture = await telemetry.collectPosture();

    final resp = await api!.login(
      username: username,
      password: password,
      code: code,
      deviceName: deviceName,
      platform: platform,
      osVersion: osVersion,
      appVersion: '1.0.1+5',
      securityPosture: initialPosture,
    );

    token = resp['token'] as String;
    currentUser = resp['user'] as Map<String, dynamic>;
    currentPosture = resp['security_posture'] as Map<String, dynamic>?;
    isCompliant = currentPosture?['is_compliant'] == true;

    final prefs = await SharedPreferences.getInstance();
    await _secureStorage.write(key: _tokenKey, value: token!);
    await prefs.setString('server_url', serverUrl!);

    _setupServices();
    await refreshAll();
    notifyListeners();
  }

  Future<void> logout() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    try {
      await api?.logout();
    } catch (_) {}

    ws.disconnect();
    telemetry.stopReporting();
    support.stopScreenSharing();
    support.clearChat();

    token = null;
    currentUser = null;
    api = null;
    activePrompt = null;
    activeSupportPrompt = null;
    activeRelayEndpoint = null;
    activeRelayName = null;
    pendingChallenges.clear();
    allowedApps.clear();
    history.clear();
    supportQueue.clear();
    _resolvedChallengeIds.clear();
    _alertedChallengeIds.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
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
      checkPosture(),
      checkSupportSession(),
      refreshRelays(),
    ];
    if (isEngineer) {
      tasks.add(loadSupportQueue());
    }
    await Future.wait(tasks);
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
      final list = await api!.getPendingChallenges();
      pendingChallenges = list.where((c) {
        final id = c['id']?.toString();
        return id != null && !_resolvedChallengeIds.contains(id);
      }).toList();

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
      } else if (!stillPending) {
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

  Future<void> checkPosture() async {
    if (api == null) return;
    try {
      currentPosture = await telemetry.collectPosture();
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

    if (challengeId.isNotEmpty) {
      _resolvedChallengeIds.add(challengeId);
    }
    activePrompt = null;
    await alert.resetWindowPriority();

    if (approve) {
      // 1. Если включена GPO политика Windows Hello или системная биометрия
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
      }

      // 2. Отправка подтверждения
      await api!.challengeDecision(
        challengeId: challengeId,
        decision: 'approve',
        numberMatch: selectedNumberMatch,
      );
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

  /// Подтверждение удаленного доступа инженеру (approve) с проверкой контрольного числа
  Future<void> confirmSupport({
    required String sessionId,
    String? numberMatch,
  }) async {
    if (api == null) throw Exception('API не инициализирован');
    activeSupportPrompt = null;
    await alert.resetWindowPriority();

    // 1. Биометрия / Windows Hello при политике GPO
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

        if (status == 'connecting' || status == 'authorizing') {
          final numberMatch = sess['number_match']?.toString() ?? '';
          if (numberMatch.isNotEmpty && activeSupportPrompt == null && support.state != SupportSessionState.active) {
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
          if (support.state != SupportSessionState.requested) {
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
        if (support.state == SupportSessionState.requested) {
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
    ws.disconnect();
    telemetry.stopReporting();
    support.stopScreenSharing();
    super.dispose();
  }
}
