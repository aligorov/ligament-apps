import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../api/client.dart';
import '../app_version.dart';
import '../services/auth_state.dart';
import '../services/debug_log_service.dart';
import '../services/deep_link_service.dart';
import '../services/input_injector.dart';
import '../services/rdp_actions.dart';
import '../services/support_service.dart';
import '../i18n/app_strings.dart';
import '../widgets/app_update_banner.dart';
import '../widgets/app_update_dialog.dart';
import 'approval_modal.dart';
import 'browser_sso_dialog.dart';
import 'identity_mismatch_banner.dart';
import 'apps_screen.dart';
import 'connect_screen.dart';
import 'history_screen.dart';
import 'notification_popup_dialog.dart';
import 'notifications_screen.dart';
import 'rdp_connect_dialog.dart';
import 'settings_screen.dart';
import 'support_approval_modal.dart';
import 'support_dialog.dart';
import 'support_operator_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _modalShown = false;
  bool _supportModalShown = false;
  bool _notificationModalShown = false;
  bool _browserSsoModalShown = false;
  bool _connectingToSession = false;
  Timer? _rdpTargetsTimer;
  Map<String, dynamic>? _appUpdate;

  Future<T> _traceAction<T>(String operation, Future<T> Function() action,
      {String? sessionId}) async {
    final watch = Stopwatch()..start();
    final fields = <String, Object?>{'operation': operation,
      'request_id': DebugLogService.instance.nextRequestId(), if (sessionId != null) 'session_id': sessionId};
    DebugLogService.instance.record('ui.home.action.started', fields: fields);
    try {
      final result = await action();
      DebugLogService.instance.record('ui.home.action.completed', fields: {
        ...fields, 'result': 'await_returned', 'duration_ms': watch.elapsedMilliseconds,
      });
      return result;
    } catch (error) {
      DebugLogService.instance.record('ui.home.action.failed', error: error,
          fields: {...fields, 'duration_ms': watch.elapsedMilliseconds});
      rethrow;
    }
  }

  /// Сворачивание в трей имеет смысл только на десктопе (Windows/macOS/Linux):
  /// на мобильных платформах и в вебе системного трея нет.
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkAppUpdate());
    });
    // План §2.2: online-статус RDP-целей тухнет без обновления (сервер
    // переводит endpoint в offline только по факту disconnect/timeout) —
    // дергаем список раз в 30 с, пока видимы главная вкладка (0) или вкладка сервисов (2).
    _rdpTargetsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || (_currentIndex != 0 && _currentIndex != 2)) return;
      final auth = context.read<AuthState>();
      if (auth.rdpTargets.isNotEmpty) {
        unawaited(auth.loadRdpTargets());
      }
    });
  }

  @override
  void dispose() {
    _rdpTargetsTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkAppUpdate({bool manual = false}) async {
    final auth = context.read<AuthState>();
    final update = await _traceAction(
      'check_update',
      () => auth.checkAppUpdate(manual: manual),
    );
    if (!mounted || update == null) return;
    final latest = update['latest']?.toString() ?? '';
    final releaseUrl = update['release_url']?.toString() ?? '';
    if (!isAppUpdateAvailable(appVersion, latest)) return;
    setState(() => _appUpdate = update);

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastPrompted = prefs.getString('last_prompted_app_update');
      if (manual || lastPrompted != latest) {
        await prefs.setString('last_prompted_app_update', latest);
        if (mounted) {
          await AppUpdateDialog.show(
            context,
            latestVersion: latest,
            releaseUrl: releaseUrl,
          );
        }
      }
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthState>();
    if (!auth.isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ConnectScreen()),
          (route) => false,
        );
      });
      return;
    }
    _checkPrompts(auth);
    _checkBrowserSsoPrompt(auth);
    _checkPendingRdpDeepLink(auth);
  }

  /// Deep-link ligament://rdp/<uuid> (аудит RDP-11 + контракт T6): применяем
  /// ожидающую ссылку. Target-режим (без токена в query): приложение САМО
  /// берёт bridge-грант у сервера — POST /api/v1/app/rdp/grant {target_id}
  /// от device-токена из защищённого хранилища (auth.grantRdpTargetBridge);
  /// 428 mfa_required → диалог «войти заново / подтвердил — повторить»,
  /// прочие отказы гранта → человеческий текст rdpConnectErrorText, успех →
  /// connectBridge + RdpConnectDialog (обычный connect-флоу). Легаси-формат
  /// <grant_id>?t=<token> остаётся рабочим без изменений. Ссылка могла
  /// приехать холодным стартом ДО логина (pending в AuthState) или в живой
  /// сессии (notifyListeners перезапускает didChangeDependencies).
  void _checkPendingRdpDeepLink(AuthState auth) {
    final link = auth.pendingRdpDeepLink;
    if (link == null) return;
    // Снимаем сразу: одна ссылка — один запуск флоу, повторные rebuild
    // didChangeDependencies не должны ретриггерить подключение.
    auth.consumePendingRdpDeepLink();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_applyRdpDeepLink(auth, link));
    });
  }

  /// Применение разобранной ссылки: ветвление по контракту (T6 target /
  /// легаси grant) + общий гейт занятости туннеля.
  Future<void> _applyRdpDeepLink(AuthState auth, LigamentDeepLink link) async {
    DebugLogService.instance.record('ui.home.rdp_deep_link.intent', fields: {'phase': link.kind == LigamentDeepLinkKind.target ? 'target' : 'bridge'});
    if (!mounted) {
      DebugLogService.instance.record('ui.home.rdp_deep_link.cancelled', fields: {'reason': 'unmounted'});
      return;
    }
    final s = context.stringsRead;
    final api = auth.api;
    final baseUrl = auth.serverUrl;

    // Живая/занятая RDP-сессия не срывается ради ссылки.
    if (auth.rdp.isBusy || auth.rdp.isActive) {
      DebugLogService.instance.record('ui.home.rdp_deep_link.blocked', fields: {'reason': 'busy'});
      debugPrint('deep_link: rdp занят — ссылка отброшена');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(s.rdpDeepLinkBusy)),
      );
      return;
    }

    final name = s.rdpDeepLinkTargetName;

    // Контракт T6: ligament://rdp/<target_uuid> — намерение подключиться.
    // Ссылка несёт ТОЛЬКО UUID: единый запуск через штатный WSS-коннектор
    // (RdpActions.connectRdp) с MFA, валидацией цели и проверкой самоподключения.
    if (link.kind == LigamentDeepLinkKind.target) {
      if (api == null || baseUrl == null) {
        DebugLogService.instance.record('ui.home.rdp_deep_link.blocked', fields: {'reason': 'no_auth'});
        // Сессии нет — грант нечем авторизовать: понятный диалог входа.
        await _showDeepLinkInfoDialog(
            s.rdpDeepLinkNeedLoginTitle, s.rdpDeepLinkNeedLoginBody, s.close);
        return;
      }
      final targetId = link.targetId!;
      final targetObj = auth.rdpTargets.firstWhere(
        (t) => t['id']?.toString() == targetId,
        orElse: () => <String, dynamic>{'id': targetId, 'name': name},
      );
      if (targetObj['is_self'] == true) {
        DebugLogService.instance.record('ui.home.rdp_deep_link.blocked', fields: {'reason': 'self_target'});
        await _showDeepLinkInfoDialog(
            s.rdpSelfBtn, s.rdpSelfProhibited, s.close);
        return;
      }
      await RdpActions.connectRdp(context, auth, targetObj);
      return;
    }

    // Легаси: <grant_id>?t=<token> — bridge-грант веб-кабинета.
    final token = link.grantToken;
    if (api == null || baseUrl == null || token == null || link.grantId == null) {
      DebugLogService.instance.record('ui.home.rdp_deep_link.blocked', fields: {'reason': 'incomplete_grant'});
      // Без токена гранта bridge-подключение невозможно (дизайн §5 —
      // токен не в URL не значит, что его можно достать из воздуха:
      // grant создан web-сессией, у приложения секрета нет).
      await _showDeepLinkInfoDialog(
          s.rdpDeepLinkNoTokenTitle, s.rdpDeepLinkNoTokenBody, s.close);
      return;
    }
    _startBridgeConnect(auth, api,
        grantId: link.grantId!, token: token, name: name, isRu: s.isRu);
  }



  /// Информационный диалог deep-link (единый тёмный стиль).
  Future<void> _showDeepLinkInfoDialog(
      String title, String body, String action) async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(body,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  /// Запуск bridge-подключения по гранту + диалог статуса (как у плитки
  /// «Подключиться»): connectBridge идёт без await, RdpConnectDialog
  /// слушает фазы коннектора до active/failed.
  void _startBridgeConnect(AuthState auth, ApiClient api,
      {required String grantId,
      required String token,
      required String name,
      required bool isRu}) {
    DebugLogService.instance.record('ui.home.bridge_connect.dispatched');
    unawaited(
      auth.rdp.connectBridge(
        api: api,
        grantId: grantId,
        token: token,
        name: name,
        isRu: isRu,
      ),
    );
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => RdpConnectDialog(connector: auth.rdp, targetName: name),
    );
  }

  void _checkBrowserSsoPrompt(AuthState auth) {
    if (auth.activeBrowserSsoPrompt == null) {
      _browserSsoModalShown = false;
    } else if (!_browserSsoModalShown) {
      _browserSsoModalShown = true;
      final prompt = Map<String, dynamic>.from(auth.activeBrowserSsoPrompt!);
      final ready = auth.browserSsoHasTicket && auth.browserSsoMachineOk;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _browserSsoModalShown = false;
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => BrowserSsoDialog(
            spName: prompt['sp_name']?.toString() ?? 'SSO',
            identityDisplay: auth.windowsUserDisplay,
            ready: ready,
            onDecision: (approve) {
              Navigator.of(context, rootNavigator: true).pop();
              DebugLogService.instance.record('ui.home.browser_sso.decision', fields: {'operation': approve ? 'approve' : 'deny', 'result': 'dispatched'});
              context.read<AuthState>().resolveBrowserSso(approve);
            },
          ),
        ).whenComplete(() {
          _browserSsoModalShown = false;
        });
      });
    }
  }

  void _checkPrompts(AuthState auth) {
    if (auth.activePrompt == null) {
      _modalShown = false;
    } else if (!_modalShown) {
      _modalShown = true;
      final prompt = auth.activePrompt!;
      DebugLogService.instance.record('ui.home.approval.open', fields: {'origin': 'prompt'});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _modalShown = false;
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) => ApprovalModal(prompt: prompt),
        ).whenComplete(() {
          _modalShown = false;
          if (mounted) {
            context.read<AuthState>().dismissPrompt(prompt['challenge_id']?.toString());
          }
        });
      });
    }

    if (auth.activeSupportPrompt == null) {
      _supportModalShown = false;
    } else if (!_supportModalShown) {
      _supportModalShown = true;
      final prompt = auth.activeSupportPrompt!;
      DebugLogService.instance.record('ui.home.support_approval.open', fields: {'session_id': prompt['session_id'], 'origin': 'prompt'});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _supportModalShown = false;
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => SupportApprovalModal(prompt: prompt),
        ).whenComplete(() {
          _supportModalShown = false;
        });
      });
    }

    if (auth.activeNotificationPrompt == null) {
      _notificationModalShown = false;
    } else if (!_notificationModalShown) {
      _notificationModalShown = true;
      final notif = auth.activeNotificationPrompt!;
      DebugLogService.instance.record('ui.home.notification.open', fields: {'origin': 'prompt'});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _notificationModalShown = false;
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) => NotificationPopupDialog(notification: notif),
        ).whenComplete(() {
          _notificationModalShown = false;
          if (mounted) {
            context.read<AuthState>().dismissNotificationPrompt();
          }
        });
      });
    }
  }



  /// Баннер активного RDP-туннеля (этап 2.2): «Завершить» рвёт сессию и
  /// закрывает грант на сервере (POST /rdp/close).
  Widget _buildRdpTunnelBanner(AuthState auth) {
    final s = context.strings;
    final isRu = auth.isRu;
    final rdp = auth.rdp;
    final active = rdp.isActive;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF10B981).withValues(alpha: 0.15)
            : const Color(0xFF0284C7).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: active ? const Color(0xFF10B981) : const Color(0xFF0284C7),
              shape: BoxShape.circle,
            ),
            child: active
                ? const Icon(Icons.desktop_windows, color: Colors.white, size: 20)
                : const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rdp.targetName != null && rdp.targetName!.isNotEmpty
                      ? s.rdpActiveBannerTarget(rdp.targetName!)
                      : s.rdpActiveBanner,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  active
                      ? (isRu
                          ? 'Окно удалённого рабочего стола открыто. Завершение сессии оборвёт туннель.'
                          : 'Remote Desktop window is open. Ending the session will cut the tunnel.')
                      : (rdp.phaseDetail ?? s.rdpStepGrant),
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _traceAction('rdp_close', () => rdp.close(isRu: isRu)),
            style: OutlinedButton.styleFrom(
              foregroundColor: active ? const Color(0xFFEF4444) : const Color(0xFF94A3B8),
              side: BorderSide(color: active ? const Color(0xFFEF4444) : const Color(0xFF64748B)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              s.rdpEndSessionBtn,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _connectAsOperator(AuthState auth, Map<String, dynamic> sess) async {
    final sessId = sess['id']?.toString();
    DebugLogService.instance.record('ui.home.operator_connect.intent', fields: {'session_id': sessId});
    if (sessId == null || _connectingToSession) {
      DebugLogService.instance.record('ui.home.operator_connect.blocked', fields: {'reason': _connectingToSession ? 'busy' : 'missing_session'});
      return;
    }

    setState(() => _connectingToSession = true);
    try {
      final Widget screen;
      if (sess['sos_v2'] == true) {
        // SOS через Link-агент: claim даёт сессию и цифры, экран стартует её через /start.
        final claim = await _traceAction('claim_sos', () => auth.claimSOSRequest(sessId));
        final sessionId = claim['session_id']?.toString() ?? '';
        final agentId = claim['agent_id']?.toString() ?? '';
        if (sessionId.isEmpty || agentId.isEmpty) {
          throw StateError('SOS claim returned no session');
        }
        screen = SupportOperatorScreen(
          sessionId: 'link_$agentId',
          numberMatch: claim['confirmation_code']?.toString(),
          isLink: true,
          linkAgentId: agentId,
          linkAccessMode: 'control',
          sessionData: {
            ...sess,
            'agent_id': agentId,
            'hostname': sess['pc_name'] ?? agentId,
            'employee_name': sess['display_name'] ?? sess['username'] ?? '',
            'access_mode': 'control',
            'session_kind': 'sos',
            'sos_request_id': sessId,
            'sos_session_id': sessionId,
          },
        );
      } else {
        final res = await _traceAction('connect_support', () => auth.connectToSupportSession(sessId), sessionId: sessId);
        screen = SupportOperatorScreen(
          sessionId: sessId,
          numberMatch: res['number_match']?.toString(),
          sessionData: {
            ...sess,
            'session_kind': 'sos',
          },
        );
      }

      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => screen),
        );
        if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
          try {
            await windowManager.setMinimumSize(const Size(380, 600));
            await Future.delayed(const Duration(milliseconds: 50));
            await windowManager.setSize(const Size(440, 720));
            WidgetsBinding.instance.scheduleFrame();
          } catch (error) { DebugLogService.instance.record('ui.home.window_restore.failed', error: error); }
        }
      }
    } catch (e) {
      DebugLogService.instance.record('ui.home.operator_connect.failed', error: e, fields: {'session_id': sessId});
      if (mounted) {
        final errText = auth.isRu ? 'Ошибка подключения: $e' : 'Connection error: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFEF4444),
            content: Text(errText),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _connectingToSession = false);
    }
  }

  void _showQueueChatModal(BuildContext context, AuthState auth, Map<String, dynamic> sess) async {
    final sessId = sess['id']?.toString();
    if (sessId == null) return;
    DebugLogService.instance.record('ui.home.queue_chat.open', fields: {'session_id': sessId});
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SupportOperatorScreen(
          sessionId: sessId,
          sessionData: sess,
          isChatOnly: true,
        ),
      ),
    );
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        await windowManager.setMinimumSize(const Size(380, 600));
        await Future.delayed(const Duration(milliseconds: 50));
        await windowManager.setSize(const Size(440, 720));
        WidgetsBinding.instance.scheduleFrame();
      } catch (error) { DebugLogService.instance.record('ui.home.window_restore.failed', error: error); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final s = context.strings;
    final isRu = auth.isRu;
    _checkPrompts(auth);

    final pages = [
      _buildRequestsTab(auth),
      const NotificationsScreen(),
      const AppsScreen(),
      const HistoryScreen(),
      const SettingsScreen(),
    ];

    final badgeCount = auth.pendingChallenges.length + (auth.isEngineer ? auth.supportQueue.length : 0);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (idx) {
          DebugLogService.instance.record('ui.home.tab.select', fields: {'code': idx});
          setState(() => _currentIndex = idx);
          if (idx == 2) {
            final auth = context.read<AuthState>();
            if (auth.rdpFeatureAvailable) {
              unawaited(auth.loadRdpTargets());
            }
          }
        },
        backgroundColor: const Color(0xFF1E293B),
        selectedItemColor: const Color(0xFF38BDF8),
        unselectedItemColor: const Color(0xFF64748B),
        type: BottomNavigationBarType.fixed,
        items: [
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: badgeCount > 0,
              label: Text('$badgeCount'),
              child: const Icon(Icons.shield_outlined),
            ),
            label: isRu ? 'Запросы' : 'Requests',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: auth.unreadNotificationsCount > 0,
              label: Text('${auth.unreadNotificationsCount}'),
              child: const Icon(Icons.mark_email_unread_outlined),
            ),
            label: isRu ? 'Сообщения' : 'Inbox',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.apps_outlined),
            label: isRu ? 'Сервисы' : 'Services',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.history_outlined),
            label: s.navHistory,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.tune_outlined),
            label: s.navSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildRequestsTab(AuthState auth) {
    final s = context.strings;
    final isRu = auth.isRu;
    final challenges = auth.pendingChallenges;
    final supportQueue = auth.supportQueue;
    final support = auth.support;
    final isEngineer = auth.isEngineer;
    final badge = auth.engineerBadge;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        toolbarHeight: 74,
        title: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            auth.displayName.isNotEmpty ? auth.displayName : 'Ligament 2FA',
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (auth.username.isNotEmpty && auth.displayName != auth.username) ...[
                          const SizedBox(width: 6),
                          Text(
                            '(@${auth.username})',
                            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: auth.isAdmin
                          ? const Color(0xFF8B5CF6).withValues(alpha: 0.25)
                          : (auth.is1CEngineer
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.25)
                              : (auth.isITEngineer
                                  ? const Color(0xFF0284C7).withValues(alpha: 0.25)
                                  : const Color(0xFF64748B).withValues(alpha: 0.25))),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: auth.isAdmin
                            ? const Color(0xFF8B5CF6)
                            : (auth.is1CEngineer
                                ? const Color(0xFFF59E0B)
                                : (auth.isITEngineer
                                    ? const Color(0xFF38BDF8)
                                    : const Color(0xFF64748B))),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      badge ?? (isRu ? '👤 Пользователь' : '👤 User'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: auth.isAdmin
                            ? const Color(0xFFA78BFA)
                            : (auth.is1CEngineer
                                ? const Color(0xFFFBBF24)
                                : (auth.isITEngineer
                                    ? const Color(0xFF38BDF8)
                                    : const Color(0xFFCBD5E1))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: auth.isOnline
                    ? (auth.isUsingRelay ? const Color(0xFF0284C7).withValues(alpha: 0.2) : const Color(0xFF10B981).withValues(alpha: 0.15))
                    : const Color(0xFFEF4444).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: auth.isOnline
                          ? (auth.isUsingRelay ? const Color(0xFF38BDF8) : const Color(0xFF10B981))
                          : const Color(0xFFEF4444),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    auth.isOnline ? (auth.isUsingRelay ? 'Relay: ${auth.activeRelayName ?? "LAN"}' : 'Online') : 'Offline',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: auth.isOnline
                          ? (auth.isUsingRelay ? const Color(0xFF38BDF8) : const Color(0xFF10B981))
                          : const Color(0xFFEF4444),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Badge(
                isLabelVisible: auth.unreadNotificationsCount > 0,
                label: Text('${auth.unreadNotificationsCount}'),
                backgroundColor: const Color(0xFF0284C7),
                child: const Icon(Icons.notifications_outlined, color: Colors.white, size: 22),
              ),
              tooltip: s.notificationsTooltip,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () {
                DebugLogService.instance.record('ui.home.notifications.open');
                setState(() => _currentIndex = 1);
              },
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              onPressed: () {
                DebugLogService.instance.record('ui.home.sos.open');
                showDialog<bool>(
                  context: context,
                  builder: (_) => const SupportDialog(),
                ).then((submitted) {
                  DebugLogService.instance.record('ui.home.sos.closed', fields: {
                    'result': submitted == true ? 'submitted' : 'cancelled',
                  });
                });
              },
              icon: const Icon(Icons.support_agent, size: 16),
              label: const Text('SOS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            // Сворачивание окна в системный трей (только десктоп): окно
            // прячется, процесс остается жить — 2FA-push и SOS продолжают
            // приходить, окно возвращается из меню трея. Это не выход,
            // поэтому GPO-политика AllowExit кнопку не ограничивает.
            if (_isDesktop) ...[
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.minimize, color: Colors.white, size: 22),
                tooltip: s.trayMinimize,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => _traceAction('minimize', windowManager.hide),
              ),
            ],
          ],
        ),
      ),
      bottom: AppUpdateBanner.maybeFromAuth(auth, _appUpdate),
      ),
      body: RefreshIndicator(
        onRefresh: () => _traceAction('manual_refresh', auth.refreshAll),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Фаза 1 Windows-identity: ненавязчивый баннер расхождения
            // «кто в приложении ↔ кто за Windows-сессией», закрывается на сессию.
            if (auth.showIdentityMismatchBanner)
              IdentityMismatchBanner(
                accountUsername: auth.username,
                windowsUser: auth.windowsUserDisplay,
                onClose: () => auth.dismissIdentityBanner(),
              ),

            // Фаза 2: proof-backed статус «подтверждено Windows»
            if (auth.ssoVerifiedUntil != null) _buildSsoVerifiedChip(auth),

            if (support.state != SupportSessionState.idle || support.lastError != null)
              // Этап 2.4: owner-сессия «Экрана» получает собственный баннер
              // (цель видит, что экран открыт САМОМУ владельцу, а не
              // инженеру поддержки); ошибки — общей карточкой ниже.
              if (support.ownerSession)
                _buildOwnerScreenBanner(auth)
              else
                _buildSupportSessionBanner(auth),

            // Этап 2.2: баннер активного/устанавливаемого RDP-туннеля —
            // пользователь видит живую сессию и может завершить её (§8 R6).
            if (auth.rdp.isBusy || auth.rdp.isActive) _buildRdpTunnelBanner(auth),



            // РАЗДЕЛ ДЛЯ ИНЖЕНЕРОВ: Входящие заявки на удаленную помощь
            if (isEngineer) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.headset_mic_outlined, color: Color(0xFF38BDF8), size: 20),
                      const SizedBox(width: 8),
                      Text(
                        isRu ? 'Входящие SOS-обращения' : 'Incoming SOS Requests',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      if (supportQueue.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${supportQueue.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF94A3B8)),
                    tooltip: isRu ? 'Обновить очередь' : 'Refresh queue',
                    onPressed: () => _traceAction('refresh_queue_cycle', auth.loadSupportQueue),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (supportQueue.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, color: Color(0xFF10B981), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          isRu
                              ? 'Очередь обращений пуста. Новые запросы сотрудников появятся здесь.'
                              : 'Support queue is empty. New employee requests will appear here.',
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ...supportQueue.map((sess) => _buildQueueItem(auth, sess)),
              const SizedBox(height: 16),
            ],

            // РАЗДЕЛ 2FA ЗАПРОСОВ
            Row(
              children: [
                const Icon(Icons.lock_outline, color: Color(0xFF38BDF8), size: 20),
                const SizedBox(width: 8),
                Text(
                  isRu ? 'Запросы подтверждения входа (2FA)' : '2FA Login Requests',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (challenges.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: const BoxDecoration(
                        color: Color(0xFF0F172A),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.verified_user_outlined, size: 48, color: Color(0xFF10B981)),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isRu ? 'Нет активных 2FA запросов' : 'No active 2FA requests',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isRu
                          ? 'При входе в корпоративную систему окно подтверждения появится автоматически'
                          : 'When logging in to corporate systems, the approval window will appear automatically',
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ...challenges.map((ch) => _buildChallengeItem(auth, ch)),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueItem(AuthState auth, Map<String, dynamic> sess) {
    final isRu = auth.isRu;
    final is1C = sess['category'] == '1c';
    final clientName = sess['display_name'] ?? sess['employee_name'] ?? sess['username'] ?? (isRu ? 'Сотрудник' : 'Employee');
    final pcName = sess['device_name'] ?? sess['pc_name'] ?? '—';
    final osName = sess['platform'] ?? sess['os_name'] ?? '—';
    final ip = sess['last_ip'] ?? sess['ip'] ?? '—';
    final summary = sess['problem_summary'] ?? (isRu ? 'Запрос помощи' : 'Assistance request');
    final fullControl = sess['access_mode'] == 'full_control';

    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: is1C ? const Color(0xFFF59E0B) : const Color(0xFF0284C7),
          width: 1.5,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: is1C
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.2)
                        : const Color(0xFF0284C7).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: is1C ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        is1C ? Icons.analytics_outlined : Icons.computer,
                        size: 14,
                        color: is1C ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        is1C ? (isRu ? 'Поддержка 1С' : '1C Support') : (isRu ? 'IT-служба' : 'IT Helpdesk'),
                        style: TextStyle(
                          color: is1C ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: fullControl
                        ? const Color(0xFF10B981).withValues(alpha: 0.15)
                        : const Color(0xFF64748B).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    fullControl ? (isRu ? '🎮 Полный доступ' : '🎮 Full Access') : (isRu ? '👀 Просмотр' : '👀 View Only'),
                    style: TextStyle(
                      color: fullControl ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  sess['status'] == 'connecting'
                      ? (isRu ? '⚡ Подключение...' : '⚡ Connecting...')
                      : (isRu ? '⏳ Ожидает' : '⏳ Waiting'),
                  style: TextStyle(
                    color: sess['status'] == 'connecting' ? const Color(0xFF38BDF8) : const Color(0xFFF59E0B),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              clientName,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 2),
            Text(
              isRu ? 'ПК: $pcName • ОС: $osName • IP: $ip' : 'PC: $pcName • OS: $osName • IP: $ip',
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 14, color: Color(0xFF64748B)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                // Заявки SOS через Link-агент получают чат вместе с сессией после claim.
                if (sess['sos_v2'] != true) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showQueueChatModal(context, auth, sess),
                      icon: const Icon(Icons.chat_bubble_outline, size: 16),
                      label: Text(isRu ? '💬 Чат' : '💬 Chat', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: const BorderSide(color: Color(0xFF0284C7)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connectingToSession ? null : () => _connectAsOperator(auth, sess),
                    icon: Icon(fullControl ? Icons.sports_esports : Icons.desktop_windows, size: 16),
                    label: Text(
                      fullControl ? (isRu ? 'Управление: Console' : 'Control: Console') : (isRu ? 'Просмотр: Console' : 'View: Console'),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: is1C ? const Color(0xFFF59E0B) : const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChallengeItem(AuthState auth, Map<String, dynamic> ch) {
    final s = context.strings;
    final isRu = auth.isRu;
    final meta = ch['metadata'] as Map<String, dynamic>? ?? {};

    final clientIp = meta['client_ip']?.toString();
    final hostIp = meta['host_ip']?.toString();
    final serviceName = meta['service']?.toString() ?? ch['purpose']?.toString() ?? (isRu ? 'Запрос входа' : 'Login Request');
    final effectiveClientIp = (clientIp != null && clientIp.isNotEmpty) ? clientIp : (meta['ip'] ?? '—');
    final ipText = (hostIp != null && hostIp.isNotEmpty && hostIp != effectiveClientIp)
        ? '$effectiveClientIp → $hostIp'
        : effectiveClientIp;

    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const CircleAvatar(
          backgroundColor: Color(0xFF0284C7),
          child: Icon(Icons.security, color: Colors.white),
        ),
        title: Text(
          serviceName,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        subtitle: Text(
          'IP: $ipText • ${ch['expires_in_seconds']} ${isRu ? 'сек' : 's'}',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        trailing: ElevatedButton(
          onPressed: () {
            DebugLogService.instance.record('ui.home.approval.open', fields: {
              'origin': 'manual', 'result': _modalShown ? 'blocked' : 'requested',
            });
            if (_modalShown) return;
            _modalShown = true;
            final promptData = {
              'challenge_id': ch['id'],
              'who': meta['username'] ?? auth.currentUser?['username'],
              'ip': effectiveClientIp,
              'client_ip': clientIp,
              'host_ip': hostIp,
              'host': meta['host'],
              'ua': meta['ua'] ?? meta['device'] ?? '—',
              'device': meta['device'] ?? meta['client'],
              'service': serviceName,
              'number_match': meta['number_match'],
              'expires_in_seconds': ch['expires_in_seconds'],
            };
            final currentAuth = context.read<AuthState>();
            currentAuth.activePrompt = promptData;
            _modalShown = true;
            showDialog(
              context: context,
              barrierDismissible: true,
              builder: (_) => ApprovalModal(prompt: promptData),
            ).then((_) {
              DebugLogService.instance.record('ui.home.approval.closed', fields: {
                'origin': 'manual', 'result': 'dialog_returned',
              });
              _modalShown = false;
              if (mounted) {
                currentAuth.dismissPrompt(ch['id']?.toString());
              }
            });
          },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
          child: Text(s.open),
        ),
      ),
    );
  }

  /// Статус proof-backed идентичности (фаза 2): «Подтверждено Windows · до HH:mm».
  Widget _buildSsoVerifiedChip(AuthState auth) {
    final s = context.stringsRead;
    final until = auth.ssoVerifiedUntil!;
    final time = DateFormat('HH:mm').format(until);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF065F46).withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined, color: Color(0xFF34D399), size: 18),
          const SizedBox(width: 8),
          Text(
            '${s.ssoVerifiedPrefix} · ${s.ssoVerifiedUntil(time)}',
            style: const TextStyle(color: Color(0xFFA7F3D0), fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Баннер owner-сессии «Экрана» (этап 2.4) на ЦЕЛИ: экран этого ПК
  /// транслируется самому владельцу с его другого устройства. Гвоздь №1
  /// (план §5.3): заметный, некрываемый «просто так» индикатор трансляции
  /// + кнопка «Завершить».
  Widget _buildOwnerScreenBanner(AuthState auth) {
    final s = context.strings;
    final support = auth.support;
    final isActive = support.state == SupportSessionState.active;
    final isConnecting = support.state == SupportSessionState.connecting;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isActive
            ? const Color(0xFF0284C7).withValues(alpha: 0.18)
            : const Color(0xFF10B981).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? const Color(0xFF38BDF8) : const Color(0xFF10B981),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Color(0xFF0284C7),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.screen_share, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.ownerScreenBannerTitle,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  isConnecting
                      ? s.ownerScreenWaiting
                      : s.ownerScreenBannerBody(support.ownerInitiatorDevice ?? ''),
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _traceAction('end_support_local_cleanup', auth.endSupport, sessionId: auth.support.activeSessionId),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFEF4444),
              side: const BorderSide(color: Color(0xFFEF4444)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              s.rdpEndSessionBtn,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSupportSessionBanner(AuthState auth) {
    final isRu = auth.isRu;
    final support = auth.support;
    final is1C = support.category == '1c';
    final isActive = support.state == SupportSessionState.active;
    final isAuthorizing = support.state == SupportSessionState.authorizing;
    final isConnecting = support.state == SupportSessionState.connecting;
    final isError = support.state == SupportSessionState.ended;
    // M-8: на платформах без InputInjector (Android/iOS/Web) режим
    // full_control фактически является просмотром — говорим об этом честно.
    final inputControlUnavailable =
        !InputInjector.instance.isInputInjectionSupported && support.accessMode == 'full_control';

    // Ошибка последней сессии (M-1: таймаут установления / исчерпание
    // ICE-рестартов) — отдельная карточка с кнопкой закрытия.
    if (isError || (support.state == SupportSessionState.idle && support.lastError != null)) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${isRu ? 'Сеанс удаленной помощи завершился ошибкой' : 'Remote support session ended with error'}: ${support.lastError ?? ''}',
                style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => auth.support.clearError(),
              child: Text(isRu ? 'Закрыть' : 'Close'),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isActive
            ? const Color(0xFFEF4444).withValues(alpha: 0.15)
            : (isAuthorizing
                ? const Color(0xFF10B981).withValues(alpha: 0.15)
                : (is1C ? const Color(0xFFF59E0B).withValues(alpha: 0.12) : const Color(0xFF0284C7).withValues(alpha: 0.12))),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? const Color(0xFFEF4444)
              : (isAuthorizing
                  ? const Color(0xFF10B981)
                  : (is1C ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8))),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFFEF4444)
                  : (isAuthorizing
                      ? const Color(0xFF10B981)
                      : (is1C ? const Color(0xFFF59E0B) : const Color(0xFF0284C7))),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isActive
                  ? Icons.screen_share
                  : (isAuthorizing ? Icons.verified_user : Icons.hourglass_top),
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive
                      ? (isRu ? '🔴 Идет удаленный сеанс (${is1C ? '1С' : 'IT'})' : '🔴 Remote session active (${is1C ? '1C' : 'IT'})')
                      : (isConnecting
                          ? (isRu ? '🔵 Установка соединения (${is1C ? '1С' : 'IT'})' : '🔵 Connecting (${is1C ? '1C' : 'IT'})')
                          : (isAuthorizing
                              ? (isRu ? '🟡 Запрос на подключение (${is1C ? '1С' : 'IT'})' : '🟡 Connection request (${is1C ? '1C' : 'IT'})')
                              : (isRu ? '⏳ Заявка на помощь (${is1C ? '1С-поддержка' : 'IT-служба'})' : '⏳ Assistance request (${is1C ? '1C Support' : 'IT Helpdesk'})'))),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isActive
                      // M-8: честный режим на платформах без инъекции ввода
                      ? (inputControlUnavailable
                          ? (isRu ? 'Просмотр (управление недоступно на этой платформе)' : 'View only (control unavailable on this platform)')
                          : (isRu ? 'Экран транслируется инженеру поддержки' : 'Screen is shared with support engineer'))
                      : (isConnecting
                          ? (isRu ? 'Ожидание установления P2P-соединения...' : 'Waiting for P2P connection...')
                          : (isAuthorizing
                              ? (support.linkHosted
                                  ? (isRu ? 'Введите цифры инженера в окне Ligament на экране' : "Enter the engineer's digits in the Ligament window")
                                  : (isRu ? 'Инженер ожидает ввода контрольного числа' : 'Engineer is waiting for verification code'))
                              : (support.problemSummary?.isNotEmpty == true
                                  ? '"${support.problemSummary}"'
                                  : (isRu ? 'Ожидание подключения инженера...' : 'Waiting for engineer connection...')))),
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isAuthorizing && auth.activeSupportPrompt != null) ...[
            ElevatedButton.icon(
              onPressed: () {
                DebugLogService.instance.record('ui.home.support_approval.open', fields: {'origin': 'manual'});
                _supportModalShown = true;
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SupportApprovalModal(prompt: auth.activeSupportPrompt!),
                ).whenComplete(() {
                  DebugLogService.instance.record('ui.home.support_approval.closed', fields: {
                    'origin': 'manual', 'result': 'dialog_returned',
                  });
                  _supportModalShown = false;
                });
              },
              icon: const Icon(Icons.check_circle, size: 14),
              label: Text(isRu ? 'Ввести код' : 'Enter Code', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (isActive ||
              support.state == SupportSessionState.requested ||
              support.state == SupportSessionState.authorizing ||
              support.state == SupportSessionState.connecting) ...[
            ElevatedButton.icon(
              onPressed: () => _showInSessionChatModal(context, auth),
              icon: const Icon(Icons.chat_bubble_outline, size: 13),
              label: Text(
                support.unreadChatCount > 0
                    ? (isRu ? 'Чат (${support.unreadChatCount})' : 'Chat (${support.unreadChatCount})')
                    : (isRu ? 'Чат' : 'Chat'),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: support.unreadChatCount > 0
                    ? const Color(0xFF3B82F6)
                    : const Color(0xFF334155),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (isActive && !support.linkHosted) ...[
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => _showReceivedFilesModal(context, auth),
                icon: const Icon(Icons.folder_open, size: 18, color: Color(0xFF94A3B8)),
                tooltip: isRu ? 'Файлы от инженера' : 'Files from engineer',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
            const SizedBox(width: 4),
          ],
          OutlinedButton(
            onPressed: () => _traceAction('end_support_local_cleanup', auth.endSupport, sessionId: auth.support.activeSessionId),
            style: OutlinedButton.styleFrom(
              foregroundColor: isActive ? const Color(0xFFEF4444) : const Color(0xFF94A3B8),
              side: BorderSide(
                color: isActive ? const Color(0xFFEF4444) : const Color(0xFF64748B),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              isActive ? (isRu ? 'Завершить' : 'End') : (isRu ? 'Отменить' : 'Cancel'),
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showInSessionChatModal(BuildContext context, AuthState auth) {
    DebugLogService.instance.record('ui.home.chat.open', fields: {'session_id': auth.support.activeSessionId});
    auth.support.markChatAsRead();
    final textController = TextEditingController();
    final scrollController = ScrollController();
    final activeSessId = auth.support.activeSessionId;

    if (activeSessId != null && activeSessId.isNotEmpty) {
      auth.support.loadChatHistory(activeSessId);
    }

    Timer? historyPoller;
    historyPoller = Timer.periodic(const Duration(seconds: 2), (_) {
      final sId = auth.support.activeSessionId ?? activeSessId;
      if (sId != null && sId.isNotEmpty) {
        auth.support.loadChatHistory(sId);
      }
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return ListenableBuilder(
          listenable: auth.support,
          builder: (context, _) {
            final messages = auth.support.chatMessages;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (scrollController.hasClients) {
                scrollController.animateTo(
                  scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(
                  top: BorderSide(color: Color(0xFF334155), width: 1.5),
                  left: BorderSide(color: Color(0xFF334155), width: 1),
                  right: BorderSide(color: Color(0xFF334155), width: 1),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.support_agent, color: Color(0xFF38BDF8), size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            auth.isRu
                                ? 'Чат с инженером (${auth.support.category == '1c' ? '1С' : 'IT'})'
                                : 'Chat with Engineer (${auth.support.category == '1c' ? '1C' : 'IT'})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Color(0xFF1E293B), height: 1),

                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        _buildQuickReplyChip(auth, auth.isRu ? '👋 Здравствуйте!' : '👋 Hello!'),
                        _buildQuickReplyChip(auth, auth.isRu ? '👍 Хорошо, ожидаю' : '👍 OK, waiting'),
                        _buildQuickReplyChip(auth, auth.isRu ? '🔄 Перезагружаю ПК' : '🔄 Rebooting PC'),
                        _buildQuickReplyChip(auth, auth.isRu ? '✅ Всё заработало!' : '✅ It works now!'),
                      ],
                    ),
                  ),

                  Expanded(
                    child: messages.isEmpty
                        ? Center(
                            child: Text(
                              auth.isRu
                                  ? 'Сообщений пока нет.\nВы можете написать инженеру здесь.'
                                  : 'No messages yet.\nYou can write to the engineer here.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            itemCount: messages.length,
                            itemBuilder: (ctx, i) {
                              final msg = messages[i];
                              final isMe = msg.sender == 'user';
                              final timeStr = DateFormat('HH:mm').format(msg.timestamp);

                              return Align(
                                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  constraints: BoxConstraints(
                                    maxWidth: MediaQuery.of(context).size.width * 0.75,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isMe
                                        ? const Color(0xFF2563EB)
                                        : const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isMe
                                          ? const Color(0xFF3B82F6)
                                          : const Color(0xFF334155),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                    children: [
                                      if (!isMe)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 2),
                                          child: Text(
                                            msg.senderName,
                                            style: const TextStyle(
                                              color: Color(0xFF38BDF8),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      Text(
                                        msg.text,
                                        style: const TextStyle(color: Colors.white, fontSize: 13),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        timeStr,
                                        style: TextStyle(
                                          color: isMe ? Colors.white70 : const Color(0xFF64748B),
                                          fontSize: 9,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  Container(
                    padding: EdgeInsets.only(
                      left: 12,
                      right: 12,
                      top: 8,
                      bottom: MediaQuery.of(context).viewInsets.bottom + 8,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF0B0F19),
                      border: Border(top: BorderSide(color: Color(0xFF1E293B))),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: textController,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: auth.isRu ? 'Написать инженеру...' : 'Type to engineer...',
                              hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onSubmitted: (val) {
                              DebugLogService.instance.record('ui.home.chat.submit', fields: {'session_id': auth.support.activeSessionId, 'result': val.trim().isNotEmpty ? 'dispatched' : 'empty'});
                              if (val.trim().isNotEmpty) {
                                auth.support.sendChatMessage(
                                  val.trim(),
                                  senderName: auth.displayName,
                                );
                                textController.clear();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        // m-4: отправка файла инженеру через существующий
                        // SupportService.sendFile (только через DataChannel).
                        IconButton(
                          icon: const Icon(Icons.attach_file, color: Color(0xFF38BDF8)),
                          tooltip: auth.isRu ? 'Отправить файл' : 'Send file',
                          onPressed: () => _pickAndSendFile(context, auth),
                        ),
                        IconButton(
                          icon: const Icon(Icons.send, color: Color(0xFF38BDF8)),
                          onPressed: () {
                            final val = textController.text.trim();
                            DebugLogService.instance.record('ui.home.chat.send', fields: {'session_id': auth.support.activeSessionId, 'result': val.isNotEmpty ? 'dispatched' : 'empty'});
                            if (val.isNotEmpty) {
                              auth.support.sendChatMessage(
                                val,
                                senderName: auth.displayName,
                              );
                              textController.clear();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      historyPoller?.cancel();
      textController.dispose();
      scrollController.dispose();
    });
  }

  /// m-4: выбор файла и отправка инженеру через SupportService.sendFile.
  Future<void> _pickAndSendFile(BuildContext context, AuthState auth) async {
    final watch = Stopwatch()..start();
    var phase = 'pick';
    final fields = <String, Object?>{'session_id': auth.support.activeSessionId};
    DebugLogService.instance.record('ui.home.file_send.started', fields: fields);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: false);
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) {
        DebugLogService.instance.record('ui.home.file_send.cancelled', fields: {...fields, 'duration_ms': watch.elapsedMilliseconds});
        return;
      }
      phase = 'send';
      DebugLogService.instance.record('ui.home.file_send.selected', fields: {...fields, 'count': result!.files.length, 'bytes': result.files.single.size});
      await auth.support.sendFile(File(path));
      DebugLogService.instance.record('ui.home.file_send.completed', fields: {...fields, 'result': 'send_future_returned', 'duration_ms': watch.elapsedMilliseconds});
    } catch (e) {
      DebugLogService.instance.record('ui.home.file_send.failed', error: e, fields: {...fields, 'phase': phase, 'duration_ms': watch.elapsedMilliseconds});
      debugPrint('home_screen: ошибка выбора файла: $e');
    }
  }

  Widget _buildQuickReplyChip(AuthState auth, String text) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          DebugLogService.instance.record('ui.home.chat.quick_reply', fields: {'session_id': auth.support.activeSessionId, 'result': 'dispatched'});
          auth.support.sendChatMessage(
            text,
            senderName: auth.displayName,
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
          ),
        ),
      ),
    );
  }

  void _showReceivedFilesModal(BuildContext context, AuthState auth) {
    DebugLogService.instance.record('ui.home.received_files.open', fields: {'session_id': auth.support.activeSessionId, 'count': auth.support.receivedFiles.length});
    final support = auth.support;
    final isRu = auth.isRu;

    String downloadsPath = '';
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
      downloadsPath = '$profile\\Downloads\\LigamentSupport';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      downloadsPath = '$home/Downloads/LigamentSupport';
    } else {
      downloadsPath = '/sdcard/Download/LigamentSupport';
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          title: Row(
            children: [
              const Icon(Icons.folder_shared, color: Color(0xFF38BDF8), size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isRu ? 'Файлы удаленной поддержки' : 'Remote Support Files',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF94A3B8), size: 20),
                onPressed: () => Navigator.of(ctx).pop(),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (support.receivedFiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      isRu
                          ? 'Инженер пока не передавал файлов.\nВсе полученные файлы автоматически сохраняются в вашу папку Загрузки/LigamentSupport.'
                          : 'The engineer has not sent any files yet.\nAll received files are automatically saved to your Downloads/LigamentSupport folder.',
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
                    ),
                  )
                else ...[
                  Text(
                    isRu ? 'Полученные файлы в этой сессии:' : 'Files received in this session:',
                    style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: support.receivedFiles.length,
                      separatorBuilder: (_, __) => const Divider(color: Color(0xFF1E293B), height: 1),
                      itemBuilder: (c, idx) {
                        final f = support.receivedFiles[idx];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.insert_drive_file, color: Color(0xFF38BDF8)),
                          title: Text(
                            f.filename,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${(f.size / 1024).toStringAsFixed(1)} ${isRu ? 'КБ' : 'KB'} • ${DateFormat('HH:mm').format(f.receivedAt)}',
                            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.folder_open, color: Color(0xFF94A3B8), size: 18),
                            tooltip: isRu ? 'Показать в папке' : 'Show in folder',
                            onPressed: () => _openFolder(downloadsPath),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, color: Color(0xFFF59E0B), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          downloadsPath,
                          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, fontFamily: 'monospace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => _openFolder(downloadsPath),
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(isRu ? 'Открыть папку' : 'Open folder'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF38BDF8)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
              ),
              child: Text(isRu ? 'Закрыть' : 'Close'),
            ),
          ],
        );
      },
    );
  }

  void _openFolder(String path) {
    final watch = Stopwatch()..start();
    DebugLogService.instance.record('ui.home.folder_open.started');
    // Observe the existing fire-and-forget launcher without awaiting it.
    void observe(Future<ProcessResult> process) {
      unawaited(process.then<void>((result) {
        DebugLogService.instance.record('ui.home.folder_open.completed', fields: {
          'code': result.exitCode, 'result': result.exitCode == 0 ? 'launcher_returned' : 'launcher_failed',
          'duration_ms': watch.elapsedMilliseconds,
        });
      }, onError: (Object error) {
        DebugLogService.instance.record('ui.home.folder_open.failed', error: error,
            fields: {'duration_ms': watch.elapsedMilliseconds});
      }));
    }
    try {
      if (Platform.isWindows) {
        observe(Process.run('explorer.exe', [path]));
      } else if (Platform.isMacOS) {
        observe(Process.run('open', [path]));
      } else if (Platform.isLinux) {
        observe(Process.run('xdg-open', [path]));
      } else {
        DebugLogService.instance.record('ui.home.folder_open.blocked', fields: {'reason': 'platform'});
      }
    } catch (error) {
      DebugLogService.instance.record('ui.home.folder_open.failed', error: error,
          fields: {'duration_ms': watch.elapsedMilliseconds});
    }
  }
}
