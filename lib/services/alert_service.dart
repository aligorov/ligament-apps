import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:window_manager/window_manager.dart';
import 'gpo_service.dart';
import 'web_platform.dart';

/// Сервис оповещений и вывода окна при входящих push-запросах.
class AlertService {
  static final AlertService instance = AlertService._();
  AlertService._();
  factory AlertService() => instance;

  final GPOService _gpo = GPOService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    // Локальные нотификации: iOS/Android — всегда; macOS — системный баннер
    // со звуком, когда окно скрыто в трей (фон) и вывод окна легко пропустить.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _localNotifications.initialize(
        const InitializationSettings(android: androidInit, iOS: darwinInit, macOS: darwinInit),
        onDidReceiveNotificationResponse: (response) async {
          if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
            try {
              if (await windowManager.isMinimized()) {
                await windowManager.restore();
              }
              await windowManager.show();
              await windowManager.focus();
            } catch (_) {}
          }
        },
      );

      // Android 13+ (API 33): POST_NOTIFICATIONS — runtime-разрешение (M-7).
      // Без него SOS-push и сообщения чата молча не показываются.
      if (Platform.isAndroid) {
        try {
          final androidImpl = _localNotifications
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
          await androidImpl?.requestNotificationsPermission();
        } catch (e) {
          debugPrint('alert_service: requestNotificationsPermission ошибка: $e');
        }
      }
    }

    _initialized = true;
  }

  /// Сигнализация о входящем запросе авторизации:
  /// 1. Вывод окна на передний план (только если разрешено bringToFront, без кражи фокуса по умолчанию).
  /// 2. AlwaysOnTop (только если включено настройкой/GPO, по умолчанию false).
  /// 3. Мигание на панели задач (FlashWindow).
  /// 4. Звуковой сигнал оповещения.
  /// 5. Системные уведомления (macOS, PWA, Android/iOS).
  Future<void> triggerAlert({
    required String title,
    required String body,
    String? challengeId,
    bool? alwaysOnTop,
    bool? bringToFront,
  }) async {
    await init();

    final shouldBringToFront = bringToFront ?? false;
    final shouldAlwaysOnTop = alwaysOnTop ?? _gpo.alwaysOnTop;

    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        if (shouldBringToFront) {
          if (await windowManager.isMinimized()) {
            await windowManager.restore();
          }
          await windowManager.show();
          await windowManager.focus();

          if (shouldAlwaysOnTop) {
            await windowManager.setAlwaysOnTop(true);
          }
        }

        if (_gpo.flashTaskbar && Platform.isWindows) {
          // Выделяем окно на панели задач Windows (progress indicator)
          await windowManager.setProgressBar(1.0);
        }
      } catch (e) {
        debugPrint('alert_service: ошибка управления окном: $e');
      }

      if (_gpo.playSound) {
        try {
          await _audioPlayer.play(AssetSource('sounds/alert.mp3'));
        } catch (_) {
          // Если файл звука недоступен, продолжаем без краша
        }
      }

      // macOS: всегда дублируем нативным системным баннером с текстом сообщения и звуком
      if (Platform.isMacOS) {
        await _showDarwinNotification(title, body, challengeId);
      }
    } else if (kIsWeb) {
      showWebNotification(title, body);
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      const androidDetails = AndroidNotificationDetails(
        'push_challenges_channel',
        'Входящие подтверждения входа',
        channelDescription: 'Срочные push-запросы 2FA с подтверждением доступа',
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      );
      await _localNotifications.show(
        0,
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: challengeId,
      );
    }
  }

  /// Системная нотификация macOS (баннер + звук): срабатывает, когда окно
  /// приложения скрыто в трей/фон и модалку не видно.
  Future<void> _showDarwinNotification(String title, String body, String? challengeId) async {
    try {
      const darwinDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      );
      await _localNotifications.show(
        0,
        title,
        body,
        const NotificationDetails(macOS: darwinDetails),
        payload: challengeId,
      );
    } catch (e) {
      debugPrint('alert_service: ошибка локального уведомления macOS: $e');
    }
  }

  /// Оповещение о новом сообщении в чате поддержки
  Future<void> triggerChatNotification({
    required String sender,
    required String message,
    bool? bringToFront,
  }) async {
    await init();

    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        if (bringToFront == true) {
          if (await windowManager.isMinimized()) {
            await windowManager.restore();
          }
          await windowManager.show();
          await windowManager.focus();
        }
        if (Platform.isWindows) {
          await windowManager.setProgressBar(1.0);
        }
      } catch (_) {}

      try {
        await _audioPlayer.play(AssetSource('sounds/alert.mp3'));
      } catch (_) {}

      if (Platform.isMacOS) {
        await _showDarwinNotification(
          sender.isNotEmpty ? 'Сообщение: $sender' : 'Новое сообщение в чате',
          message,
          null,
        );
      }
    } else if (kIsWeb) {
      showWebNotification(
        sender.isNotEmpty ? 'Сообщение: $sender' : 'Новое сообщение в чате',
        message,
      );
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      const androidDetails = AndroidNotificationDetails(
        'chat_messages_channel',
        'Чат технической поддержки',
        channelDescription: 'Сообщения от инженера поддержки',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      await _localNotifications.show(
        1001,
        sender.isNotEmpty ? 'Сообщение от: $sender' : 'Новое сообщение в чате',
        message,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    }
  }

  /// Оповещение о доступном обновлении приложения Ligament 2FA
  Future<void> triggerUpdateNotification({
    required String latestVersion,
    required String releaseUrl,
  }) async {
    await init();

    const title = 'Обновление Ligament 2FA';
    final body = 'Доступна новая версия $latestVersion. Нажмите для загрузки.';

    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      if (Platform.isMacOS) {
        await _showDarwinNotification(title, body, releaseUrl);
      } else if (Platform.isWindows) {
        try {
          if (await windowManager.isMinimized()) {
            await windowManager.setProgressBar(1.0);
          }
        } catch (_) {}
      }
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      const androidDetails = AndroidNotificationDetails(
        'app_updates_channel',
        'Обновления приложения',
        channelDescription: 'Уведомления о выходе новых версий Ligament 2FA',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      await _localNotifications.show(
        2001,
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: releaseUrl,
      );
    }
  }

  /// Оповещение о входящем аудио- или видеозвонке (P2P WebRTC)
  Future<void> triggerIncomingCallNotification({
    required String caller,
    required bool isVideo,
    required String chatId,
  }) async {
    await init();

    final title = isVideo ? '📹 Входящий видеовызов' : '📞 Входящий аудиовызов';
    final body = '$caller вызывает вас...';

    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        if (await windowManager.isMinimized()) {
          await windowManager.restore();
        }
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setAlwaysOnTop(true);
        if (Platform.isWindows) {
          await windowManager.setProgressBar(1.0);
        }
        if (Platform.isMacOS) {
          try {
            final sz = await windowManager.getSize();
            await windowManager.setSize(Size(sz.width + 1, sz.height));
            await Future.delayed(const Duration(milliseconds: 50));
            await windowManager.setSize(sz);
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('alert_service: error waking window for incoming call: $e');
      }

      try {
        await SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
      try {
        await _audioPlayer.play(AssetSource('sounds/alert.mp3'));
      } catch (_) {}

      if (Platform.isMacOS) {
        await _showDarwinNotification(title, body, chatId);
      }
    } else if (kIsWeb) {
      showWebNotification(title, body);
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      const androidDetails = AndroidNotificationDetails(
        'incoming_calls_channel',
        'Входящие звонки (P2P Call)',
        channelDescription: 'Срочные входящие аудио- и видеозвонки в корпоративном чате',
        importance: Importance.max,
        priority: Priority.max,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.call,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.critical,
      );
      await _localNotifications.show(
        3001,
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: chatId,
      );
    }
  }

  /// Сброс AlwaysOnTop и индикатора на таскбаре после завершения обработки запроса
  Future<void> resetWindowPriority() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        await windowManager.setAlwaysOnTop(false);
        if (Platform.isWindows) {
          await windowManager.setProgressBar(-1);
        }
      } catch (_) {}
    }
  }
}
