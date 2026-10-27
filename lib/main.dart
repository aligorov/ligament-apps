import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'services/auth_state.dart';
import 'services/autoshare_service.dart';
import 'services/deep_link_service.dart';
import 'services/debug_log_service.dart';
import 'services/local_detect_service.dart';
import 'services/support_service.dart';
import 'services/link_host_session.dart';
import 'services/link_spool_storage.dart';
import 'screens/link_host_overlay.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'app_version.dart';
import 'widgets/debug_action_scope.dart';

Future<bool> _tryForwardAutoshareToRunningInstance(String sessionId) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1500);
    final req = await client.post('127.0.0.1', kLocalDetectPort, '/autoshare');
    req.headers.contentType = ContentType.json;
    // A-2 (аудит 2026-10-12): /autoshare принимает только предъявление
    // wake-токена работающего экземпляра (файл в пер-пользовательском
    // temp). Нет токена — слушатель не поднят, доставка заведомо не
    // удастся: уходим в лок-ветку без запроса.
    final wakeToken = await LocalDetectService.readWakeToken();
    if (wakeToken == null) {
      client.close();
      return false;
    }
    req.headers.set('X-Wake-Token', wakeToken);
    req.write(jsonEncode({'session_id': sessionId}));
    final res = await req.close();
    final ok = res.statusCode == 200;
    client.close();
    return ok;
  } catch (_) {
    return false;
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    DebugLogService.instance.record('flutter.error', error: details.exception);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    DebugLogService.instance.record('dart.unhandled', error: error);
    return false;
  };
  await DebugLogService.instance.initialize();
  DebugLogService.instance.record('dart.bootstrap.begin');
  if (args.any((arg) => arg.startsWith('--link-host'))) {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      exit(2);
    }
    DebugLogService.instance.record('link.worker.begin');
    try {
      final endpoint = Platform.isWindows
          ? linkHostPipeFromArgs(args)
          : linkHostUnixSocketFromArgs(args);
      if (endpoint == null) {
        DebugLogService.instance.record('link.worker.invalid_endpoint');
        await DebugLogService.instance.flush();
        exit(2);
      }
      final workerState = LinkHostWorkerState();
      try {
        await windowManager.ensureInitialized();
        runApp(DebugActionScope(child: LinkHostOverlay(state: workerState)));
        await windowManager.waitUntilReadyToShow(
          const WindowOptions(
            size: Size(580, 780),
            minimumSize: Size(440, 88),
            center: true,
            backgroundColor: Color(0xFF10251D),
            skipTaskbar: true,
            title: 'Ligament Link — удалённая сессия',
          ),
          () async {
            await windowManager.setAlwaysOnTop(true);
            await windowManager.setPreventClose(true);
            await windowManager.setClosable(false);
            await windowManager.setMinimizable(true);
            await windowManager.setMaximizable(false);
          },
        );
      } catch (e) {
        DebugLogService.instance.record('link.worker.window_unavailable', error: e);
        debugPrint('link_host: window layout unavailable, running headless: $e');
        workerState.markConsentUiUnavailable();
        runApp(const SizedBox.shrink());
      }
      await runLinkHostWorker(
        Platform.isWindows ? endpoint : 'unix:$endpoint',
        state: workerState,
      );
    } catch (error) {
      DebugLogService.instance.record('link.worker.bootstrap_failed', error: error);
      await DebugLogService.instance.flush();
      debugPrint('link_host: worker_bootstrap_failed');
      exit(2);
    }
    DebugLogService.instance.record('link.worker.ended');
    await DebugLogService.instance.flush();
    exit(0);
  }
  DebugLogService.instance.record('app.version.begin');
  await initAppVersion();
  DebugLogService.instance.record('app.version.ready');
  if (!kIsWeb) {
    unawaited(LinkSpoolStorage.purgeOrphanedSpools());
  }

  // Deep-link ligament://rdp/<uuid> (аудит RDP-11, контракт T6), холодный
  // старт: Windows передаёт URI схемы в argv (windows/runner/main.cpp
  // пробрасывает командную строку в dart_entrypoint_arguments). Без токена
  // в query UUID трактуется как target — приложение само получит грант;
  // легаси-токен в query означает grant веб-кабинета. Если юзер ещё не
  // залогинен — AuthState сохранит ссылку и применит после успешного входа.
  final deepLinkUri = ligamentUriFromArgs(args);

  // Ш5 Wake (план docs/console-any-state-plan.md §5): запуск
  // службой-сторожем с --autoshare=<session_id>. Режим headless: окно
  // скрыто, после восстановления сессии и подключения WS приложение
  // само начнёт owner-трансляцию этой сессии (AuthState.requestAutoshare).
  final autoshareSessionId = kIsWeb ? null : autoshareSessionFromArgs(args);

  // Single-instance для autoshare-запусков (план §8, A-04/A-05):
  // сначала пытаемся передать намерение работающему экземпляру;
  // если его нет — берём эксклюзивный файл-лок.
  if (autoshareSessionId != null) {
    final delivered =
        await _tryForwardAutoshareToRunningInstance(autoshareSessionId);
    if (delivered) {
      debugPrint(
          'main: autoshare-сессия успешно доставлена запущенному экземпляру — выходим');
      exit(0);
    }

    final singleInstance = AutoshareSingleInstance();
    final locked = await singleInstance.acquire();
    if (!locked) {
      debugPrint('main: autoshare-лок занят другим экземпляром — выходим');
      exit(0);
    }
  }

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF0F172A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Color(0xFFEF4444), size: 48),
              const SizedBox(height: 16),
              const Text(
                'Ligament 2FA',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                // В release стек и текст исключения пользователю не показываем:
                // это утечка внутренностей приложения (пути, API, окружение).
                kReleaseMode
                    ? 'Что-то пошло не так. Перезапустите приложение.'
                    : details.exceptionAsString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  };

  // Запуск в свернутом виде (например, автозагрузка Windows/MSI с флагом --minimized):
  // окно не показывается, приложение сидит в системном трее. Ш5: --autoshare
  // тоже стартует свёрнутым — wake поднимает трансляцию, а не окно; при
  // неудачном восстановлении сессии приложение молча остаётся в трее.
  final startMinimized =
      !kIsWeb && (args.contains('--minimized') || autoshareSessionId != null);

  // Инициализация оконного менеджера для Windows, macOS и Linux
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    DebugLogService.instance.record('app.window.initialize');
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(440, 720),
      minimumSize: Size(380, 600),
      center: true,
      backgroundColor: Color(0xFF0F172A),
      skipTaskbar: false,
      title: 'Ligament 2FA Authenticator',
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (startMinimized) {
        // Остаемся скрытыми в трее; окно открывается из трея или по push-алерту
        // (AlertService.triggerAlert сам вызывает windowManager.show()).
        return;
      }
      await windowManager.show();
      await windowManager.focus();
    });
    DebugLogService.instance.record(
        startMinimized ? 'app.window.hidden' : 'app.window.shown');
  }

  DebugLogService.instance.record('app.auth.initialize');
  final authState = AuthState();
  try {
    await authState.init();
    DebugLogService.instance.record('app.auth.ready');
  } catch (e, st) {
    DebugLogService.instance.record('app.auth.failed', error: e);
    debugPrint('auth_state: ошибка инициализации: $e\n$st');
  }

  // Применяем deep-link ПОСЛЕ init(): при живом сохранённом токене ссылка
  // уйдёт в RDP-флоу сразу (HomeScreen подхватит pending), иначе — ждёт
  // логина. Некорректные ссылки игнорируются внутри handleDeepLink.
  if (deepLinkUri != null) {
    authState.handleDeepLink(deepLinkUri);
  }

  // Ш5: регистрируем autoshare-сессию ПОСЛЕ init(): сработает один раз,
  // когда сессия восстановлена и WS подключен. Нет токена — молчим в трее.
  if (autoshareSessionId != null) {
    authState.requestAutoshare(autoshareSessionId);
  }

  DebugLogService.instance.record('app.ui.attach');
  runApp(
    ChangeNotifierProvider.value(
      value: authState,
      child: LigamentApp(showSplash: !startMinimized),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    DebugLogService.instance.record('app.ui.first_frame');
  });
}

class LigamentApp extends StatefulWidget {
  final bool showSplash;

  const LigamentApp({super.key, this.showSplash = true});

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  State<LigamentApp> createState() => _LigamentAppState();
}

class _LigamentAppState extends State<LigamentApp>
    with TrayListener, WindowListener {
  String? _lastTrayLocale;
  String? _lastTrayUpdateVersion;
  bool? _wasLoggedIn;
  late bool _showSplash = widget.showSplash;
  final _debugNavigation = DebugNavigationObserver();

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      _initTray();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _initTray() async {
    try {
      final auth = context.read<AuthState>();
      final allowExit = auth.gpo.allowExit;
      final isRu = auth.isRu;
      final update = auth.appUpdate;
      final latest = update?['latest']?.toString() ?? '';
      final hasUpdate = isAppUpdateAvailable(appVersion, latest);

      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/icons/app_icon.ico'
            : 'assets/icons/app_icon.png',
      );

      final menuItems = <MenuItem>[
        MenuItem(
            key: 'show',
            label: isRu ? 'Открыть Ligament 2FA' : 'Open Ligament 2FA'),
      ];

      if (hasUpdate) {
        menuItems.add(MenuItem.separator());
        menuItems.add(
          MenuItem(
            key: 'update',
            label: isRu
                ? '⭐ Доступно обновление: ${formatAppVersion(latest)}'
                : '⭐ Update Available: ${formatAppVersion(latest)}',
          ),
        );
      }

      menuItems.addAll([
        MenuItem.separator(),
        MenuItem(
          key: 'exit',
          label: isRu ? 'Выход' : 'Exit',
          disabled: !allowExit, // GPO политика PreventExit
        ),
      ]);

      final menu = Menu(items: menuItems);
      await trayManager.setContextMenu(menu);
      final tooltip = hasUpdate
          ? 'Ligament 2FA - ${isRu ? 'Доступно обновление' : 'Update available'} ${formatAppVersion(latest)}'
          : 'Ligament 2FA Authenticator';
      await trayManager.setToolTip(tooltip);
    } catch (_) {}
  }

  void _updateTrayIfNeeded(AuthState auth) {
    final updateVer = auth.appUpdate?['latest']?.toString();
    if (_lastTrayLocale != auth.localeCode ||
        _lastTrayUpdateVersion != updateVer) {
      _lastTrayLocale = auth.localeCode;
      _lastTrayUpdateVersion = updateVer;
      _initTray();
    }
  }

  /// Возврат окна из трея. Порядок как в AlertService.triggerAlert
  /// (проверен на проде): hide() мог застать окно свёрнутым — тогда
  /// show() без restore() возвращает его в панель задач, но не на экран,
  /// что выглядело как «из трея не разворачивается».
  Future<void> _restoreWindowFromTray() async {
    final timer = Stopwatch()..start();
    DebugLogService.instance.record('ui.tray.restore.begin');
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
      // macOS: Metal CALayer может остаться чёрным после hide/show.
      // Джиг размера окна +1px принуждает Flutter raster thread
      // выдать новый кадр на обновлённый CAMetalLayer.
      if (!kIsWeb && Platform.isMacOS) {
        try {
          final sz = await windowManager.getSize();
          await windowManager.setSize(Size(sz.width + 1, sz.height));
          await Future.delayed(const Duration(milliseconds: 50));
          await windowManager.setSize(sz);
        } catch (_) {}
      }
      WidgetsBinding.instance.scheduleFrame();
      if (mounted) setState(() {});
      DebugLogService.instance.record('ui.tray.restore.ready',
          fields: {'duration_ms': timer.elapsedMilliseconds});
    } catch (e) {
      DebugLogService.instance.record('ui.tray.restore.failed', error: e,
          fields: {'duration_ms': timer.elapsedMilliseconds});
      debugPrint('tray: ошибка восстановления окна: $e');
    }
  }

  @override
  void onTrayIconMouseDown() {
    DebugLogService.instance.record('ui.tray.icon');
    // Левый клик по иконке трея разворачивает окно (Windows/Linux). На macOS
    // клик по иконке открывает контекстное меню — там работает пункт меню.
    if (Platform.isWindows || Platform.isLinux) {
      _restoreWindowFromTray();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    DebugLogService.instance.record('ui.tray.action',
        fields: {'operation': menuItem.key});
    if (menuItem.key == 'show') {
      _restoreWindowFromTray();
    } else if (menuItem.key == 'update') {
      final auth = context.read<AuthState>();
      final releaseUrl = auth.appUpdate?['release_url']?.toString();
      if (releaseUrl != null && releaseUrl.isNotEmpty) {
        final uri = Uri.tryParse(releaseUrl);
        if (uri != null) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else {
        _restoreWindowFromTray();
      }
    } else if (menuItem.key == 'exit') {
      final auth = context.read<AuthState>();
      if (auth.gpo.allowExit) {
        windowManager.destroy();
      }
    }
  }

  @override
  void onWindowClose() async {
    final auth = context.read<AuthState>();
    DebugLogService.instance.record('app.window.close.request', fields: {
      'connected': auth.support.state == SupportSessionState.active,
      'result': auth.gpo.allowExit ? 'exit_allowed' : 'hide_only',
    });

    // m-8: при активной SOS-сессии закрытие окна требует подтверждения —
    // случайный клик по крестику не должен молча рвать сеанс помощи.
    if (auth.support.state == SupportSessionState.active) {
      final confirmed = await _confirmCloseDuringSupport(auth);
      if (!confirmed) {
        DebugLogService.instance.record('app.window.close.cancelled');
        // Пользователь передумал — окно остается открытым.
        return;
      }
      await auth.endSupport();
    }

    // При закрытии окна не убиваем процесс, а сворачиваем в системный трей
    final isPreventExit = !auth.gpo.allowExit;
    if (isPreventExit) {
      DebugLogService.instance.record('app.window.hide');
      await windowManager.hide();
    } else {
      DebugLogService.instance.record('app.window.destroy');
      await windowManager.destroy();
    }
  }

  /// Диалог подтверждения закрытия при активной SOS-сессии (m-8).
  Future<bool> _confirmCloseDuringSupport(AuthState auth) async {
    final ctx = LigamentApp.navigatorKey.currentContext;
    if (ctx == null) return true;
    final isRu = auth.isRu;
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          isRu
              ? 'Идет сеанс удаленной помощи'
              : 'Remote support session in progress',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          isRu
              ? 'Закрытие окна завершит сеанс удаленной помощи. Действительно закрыть?'
              : 'Closing the window will end the remote support session. Close anyway?',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(isRu ? 'Отмена' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444)),
            child: Text(isRu ? 'Завершить и закрыть' : 'End & Close'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _updateTrayIfNeeded(auth);
    }

    if (_wasLoggedIn == true && !auth.isLoggedIn) {
      _wasLoggedIn = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        LigamentApp.navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ConnectScreen()),
          (route) => false,
        );
      });
    } else if (auth.isLoggedIn) {
      _wasLoggedIn = true;
    } else {
      _wasLoggedIn = false;
    }

    return MaterialApp(
      navigatorKey: LigamentApp.navigatorKey,
      navigatorObservers: [_debugNavigation],
      builder: (context, child) => DebugActionScope(
        child: child ?? const SizedBox.shrink(),
      ),
      title: 'Ligament 2FA Authenticator',
      locale: auth.locale,
      supportedLocales: const [
        Locale('ru'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF0284C7),
          surface: Color(0xFF1E293B),
        ),
        scaffoldBackgroundColor: const Color(0xFF090D1A),
        useMaterial3: true,
      ),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _showSplash
            ? SplashScreen(
                key: const ValueKey('splash_screen'),
                onFinish: () {
                  if (mounted) {
                    setState(() => _showSplash = false);
                  }
                },
              )
            : (auth.isLoggedIn
                ? const HomeScreen(key: ValueKey('home_screen'))
                : const ConnectScreen(key: ValueKey('connect_screen'))),
      ),
    );
  }
}
