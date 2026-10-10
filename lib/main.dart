import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'services/auth_state.dart';
import 'services/autoshare_service.dart';
import 'services/deep_link_service.dart';
import 'services/local_detect_service.dart';
import 'services/support_service.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'app_version.dart';

Future<bool> _tryForwardAutoshareToRunningInstance(String sessionId) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1500);
    final req = await client.post('127.0.0.1', kLocalDetectPort, '/autoshare');
    req.headers.contentType = ContentType.json;
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
  await initAppVersion();

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
    final delivered = await _tryForwardAutoshareToRunningInstance(autoshareSessionId);
    if (delivered) {
      debugPrint('main: autoshare-сессия успешно доставлена запущенному экземпляру — выходим');
      exit(0);
    }

    final singleInstance = AutoshareSingleInstance();
    final locked = await singleInstance.acquire();
    if (!locked) {
      debugPrint('main: autoshare-лок занят другим экземпляром — выходим');
      exit(0);
    }
  }

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Flutter Unhandled Error: ${details.exception}');
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF0F172A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 48),
              const SizedBox(height: 16),
              const Text(
                'Ligament 2FA',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
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
  final startMinimized = !kIsWeb &&
      (args.contains('--minimized') || autoshareSessionId != null);

  // Инициализация оконного менеджера для Windows, macOS и Linux
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
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
  }

  final authState = AuthState();
  try {
    await authState.init();
  } catch (e, st) {
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

  runApp(
    ChangeNotifierProvider.value(
      value: authState,
      child: const LigamentApp(),
    ),
  );
}

class LigamentApp extends StatefulWidget {
  const LigamentApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  State<LigamentApp> createState() => _LigamentAppState();
}

class _LigamentAppState extends State<LigamentApp> with TrayListener, WindowListener {
  String? _lastTrayLocale;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      trayManager.addListener(this);
      windowManager.addListener(this);
      _initTray();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
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

      await trayManager.setIcon(
        Platform.isWindows ? 'assets/icons/app_icon.ico' : 'assets/icons/app_icon.png',
      );

      final menu = Menu(
        items: [
          MenuItem(key: 'show', label: isRu ? 'Открыть Ligament 2FA' : 'Open Ligament 2FA'),
          MenuItem.separator(),
          MenuItem(
            key: 'exit',
            label: isRu ? 'Выход' : 'Exit',
            disabled: !allowExit, // GPO политика PreventExit
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('Ligament 2FA Authenticator');
    } catch (_) {}
  }

  void _updateTrayIfNeeded(AuthState auth) {
    if (_lastTrayLocale != auth.localeCode) {
      _lastTrayLocale = auth.localeCode;
      _initTray();
    }
  }

  /// Возврат окна из трея. Порядок как в AlertService.triggerAlert
  /// (проверен на проде): hide() мог застать окно свёрнутым — тогда
  /// show() без restore() возвращает его в панель задач, но не на экран,
  /// что выглядело как «из трея не разворачивается».
  Future<void> _restoreWindowFromTray() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('tray: ошибка восстановления окна: $e');
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Левый клик по иконке трея разворачивает окно (Windows/Linux). На macOS
    // клик по иконке открывает контекстное меню — там работает пункт меню.
    if (Platform.isWindows || Platform.isLinux) {
      _restoreWindowFromTray();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      _restoreWindowFromTray();
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

    // m-8: при активной SOS-сессии закрытие окна требует подтверждения —
    // случайный клик по крестику не должен молча рвать сеанс помощи.
    if (auth.support.state == SupportSessionState.active) {
      final confirmed = await _confirmCloseDuringSupport(auth);
      if (!confirmed) {
        // Пользователь передумал — окно остается открытым.
        return;
      }
      await auth.endSupport();
    }

    // При закрытии окна не убиваем процесс, а сворачиваем в системный трей
    final isPreventExit = !auth.gpo.allowExit;
    if (isPreventExit) {
      await windowManager.hide();
    } else {
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
          isRu ? 'Идет сеанс удаленной помощи' : 'Remote support session in progress',
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
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
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
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _updateTrayIfNeeded(auth);
    }

    return MaterialApp(
      navigatorKey: LigamentApp.navigatorKey,
      title: 'Ligament 2FA',
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
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        useMaterial3: true,
      ),
      home: auth.isLoggedIn ? const HomeScreen() : const ConnectScreen(),
    );
  }
}
