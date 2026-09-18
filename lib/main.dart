import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'services/auth_state.dart';
import 'services/support_service.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

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
  // окно не показывается, приложение сидит в системном трее.
  final startMinimized = !kIsWeb && args.contains('--minimized');

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

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      windowManager.show();
      windowManager.focus();
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
