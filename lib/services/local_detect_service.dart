import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Локальный детект «умного 2FA» (этап D).
///
/// Десктоп-приложение слушает 127.0.0.1:8757 и отвечает веб-кабинету
/// (страница входа 2fa в браузере) идентификатором устройства:
/// если вход инициирован с ЭТОГО же ПК, сервер знает device_id сессии
/// приложения и запрещает подтверждение с этого рабочего места
/// (403 desktop_confirm_forbidden) — подтвердить можно только с телефона
/// или кодом. Контракт фиксирован с сервером 2fa:
///
/// - GET /ligament → 200 JSON {"v":1,"device_id":"<uuid>"}
///   + Access-Control-Allow-Origin: * + Cache-Control: no-store
/// - OPTIONS /ligament → 204 с CORS-заголовками, включая
///   Access-Control-Allow-Private-Network: true
///   (preflight Chrome Local Network Access)
/// - прочее → 404
/// - ошибка bind — warn, приложение живёт (детект не критичен для работы)
class LocalDetectService {
  static const String kDeviceIdPrefKey = 'device_id';

  /// Только десктопы: на мобильных нет смысла — браузер и приложение
  /// никогда не окажутся на одном хосте.
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  HttpServer? _server;
  String? _deviceId;

  /// A-04/A-05 (аудит 2026-10-10): колбэк доставки намерения запуска трансляции
  /// от второго экземпляра или endpoint-службы.
  void Function(String sessionId)? onAutoshare;

  bool get isRunning => _server != null;

  /// Поднять слушателя с текущим device_id сессии. Повторный вызов с тем же
  /// id — no-op; со сменённым id — перезапуск (новая сессия устройства).
  Future<void> start(String deviceId) async {
    if (!isSupported || deviceId.isEmpty) return;
    if (_server != null) {
      if (_deviceId == deviceId) return;
      await stop();
    }
    _deviceId = deviceId;
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        kLocalDetectPort,
      );
      _server = server;
      server.listen(_handle, onError: (Object e) {
        debugPrint('local_detect: ошибка слушателя: $e');
      });
      debugPrint('local_detect: слушаю 127.0.0.1:$kLocalDetectPort');
    } catch (e) {
      // Ошибка bind (например, порт занят) — warn и живём: локальный детект
      // деградирует до «вход с этого же ПК подтверждается как обычный».
      _server = null;
      debugPrint(
        'local_detect: WARN не удалось занять 127.0.0.1:$kLocalDetectPort ($e) — '
        'локальный детект отключён, приложение продолжает работу',
      );
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    try {
      await server?.close();
    } catch (e) {
      debugPrint('local_detect: ошибка остановки слушателя: $e');
    }
  }

  void _handle(HttpRequest request) async {
    // A-04/A-05: Доставка намерения autoshare работающему экземпляру
    if (request.uri.path == '/autoshare') {
      if (request.method == 'POST') {
        try {
          final content = await utf8.decoder.bind(request).join();
          final data = jsonDecode(content);
          final sid = data is Map ? data['session_id']?.toString() : null;
          if (sid != null && sid.isNotEmpty) {
            onAutoshare?.call(sid);
            final res = request.response;
            res.statusCode = 200;
            res.headers.set('Content-Type', 'application/json; charset=utf-8');
            res.write(jsonEncode({'ok': true, 'session_id': sid}));
            await res.close();
            return;
          }
        } catch (e) {
          debugPrint('local_detect: ошибка autoshare payload: $e');
        }
        final res = request.response;
        res.statusCode = 400;
        await res.close();
        return;
      }
      final res = request.response;
      res.statusCode = 405;
      await res.close();
      return;
    }

    final reply = localDetectResponse(
      request.method,
      request.uri.path,
      _deviceId ?? '',
    );
    final res = request.response;
    res.statusCode = reply.status;
    reply.headers.forEach(res.headers.set);
    try {
      if (reply.body.isNotEmpty) {
        res.write(reply.body);
      }
      await res.close();
    } catch (e) {
      debugPrint('local_detect: ошибка записи ответа: $e');
    }
  }
}

/// Порт и путь контракта с сервером 2fa (см. класс выше).
const int kLocalDetectPort = 8757;
const String kLocalDetectPath = '/ligament';

/// Иммутутабельный ответ локального детекта.
class LocalDetectReply {
  final int status;
  final Map<String, String> headers;
  final String body;

  const LocalDetectReply(this.status, this.headers, this.body);
}

/// Чистая логика ответа локального детекта — тестируется без сокета.
LocalDetectReply localDetectResponse(String method, String path, String deviceId) {
  if (path != kLocalDetectPath) {
    return const LocalDetectReply(404, {}, '');
  }
  switch (method) {
    case 'GET':
      return LocalDetectReply(
        200,
        const {
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'no-store',
          'Content-Type': 'application/json; charset=utf-8',
        },
        jsonEncode({'v': 1, 'device_id': deviceId}),
      );
    case 'OPTIONS':
      // Preflight Chrome Local Network Access: страница из публичного
      // интернета стучится к localhost — браузер требует явного
      // Access-Control-Allow-Private-Network в ответе preflight.
      return const LocalDetectReply(
        204,
        {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
          'Access-Control-Allow-Private-Network': 'true',
          'Access-Control-Max-Age': '86400',
          'Cache-Control': 'no-store',
        },
        '',
      );
    default:
      return const LocalDetectReply(404, {}, '');
  }
}
