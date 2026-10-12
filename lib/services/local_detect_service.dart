import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальный детект «умного 2FA» (этап D).
///
/// Десктоп-приложение слушает 127.0.0.1:8757 и отвечает веб-кабинету
/// (страница входа 2fa в браузере) идентификатором устройства:
/// если вход инициирован с ЭТОГО же ПК, сервер знает device_id сессии
/// приложения и запрещает подтверждение с этого рабочего места
/// (403 desktop_confirm_forbidden) — подтвердить можно только с телефона
/// или кодом. Контракт фиксирован с сервером 2fa:
///
/// - GET /ligament → 200 JSON {"v":1,"device_id":"<uuid>"} + no-store.
///   A-8 (аудит 2026-10-12): device_id отдаётся только при Origin,
///   отсутствующем (CLI/нативные клиенты), localhost либо совпадающем
///   с origin настроенного сервера (server_url); прочие Origin → 403
///   без тела. CORS-заголовок эхом отдаёт только проверенный origin
///   (никакого `*`).
/// - POST /autoshare → доставка намерения трансляции вторым экземпляром
///   приложения. A-2 (аудит 2026-10-12): требуется wake-токен
///   (X-Wake-Token или поле wake_token) — случайный, генерируется при
///   старте слушателя и доступен локальным вызывающим через файл в
///   пер-пользовательском каталоге temp; без токена/с чужим Origin → 403.
/// - OPTIONS /ligament → 204 только для проверенного origin;
///   Access-Control-Allow-Private-Network удалён (CORS для публичных
///   страниц больше не открываем).
/// - прочее → 404
/// - ошибка bind — warn, приложение живёт (детект не критичен для работы)
class LocalDetectService {
  static const String kDeviceIdPrefKey = 'device_id';

  /// Ключ SharedPreferences с адресом настроенного сервера — его origin
  /// единственный «внешний», которому разрешён GET /ligament (A-8).
  static const String kServerUrlPrefKey = 'server_url';

  /// Имя файла wake-токена в пер-пользовательском temp-каталоге (A-2).
  /// %TEMP% (Windows) и /tmp-каталоги (macOS/Linux) изолированы правами
  /// пользователя: другие локальные пользователи файл не прочитают.
  static const String wakeTokenFileName = 'ligament-2fa-wake-token';

  /// Только десктопы: на мобильных нет смысла — браузер и приложение
  /// никогда не окажутся на одном хосте.
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  HttpServer? _server;
  String? _deviceId;

  /// Wake-токен текущего слушателя (hex, 64 символа = 32 байта энтропии).
  String? _wakeToken;

  /// Текущий wake-токен (для диагностики/тестов; наружу не отдаётся).
  @visibleForTesting
  String? get wakeTokenForTest => _wakeToken;

  /// A-04/A-05 (аудит 2026-10-10): колбэк доставки намерения запуска
  /// трансляции от второго экземпляра или endpoint-службы.
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
      // A-2: новый случайный wake-токен на каждый подъём слушателя.
      _wakeToken = _generateWakeToken();
      await _publishWakeToken(_wakeToken!);
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
    _wakeToken = null;
    try {
      await server?.close();
    } catch (e) {
      debugPrint('local_detect: ошибка остановки слушателя: $e');
    }
    // Токен больше не действует — файл убираем (best-effort).
    try {
      final f = File(_wakeTokenFilePath());
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Криптослучайный wake-токен: 32 байта через OS-генератор, hex.
  static String _generateWakeToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _wakeTokenFilePath() =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$wakeTokenFileName';

  /// Запись wake-токена для локальных вызывающих /autoshare (второй
  /// экземпляр приложения). Каталог пер-пользовательский; на POSIX
  /// дополнительно сужаем права до 0600 (best-effort).
  static Future<void> _publishWakeToken(String token) async {
    try {
      final path = _wakeTokenFilePath();
      final file = File(path);
      await file.writeAsString(token, flush: true);
      if (!kIsWeb && (Platform.isLinux || Platform.isMacOS)) {
        try {
          final res = await Process.run('chmod', ['600', path]);
          if (res.exitCode != 0) {
            debugPrint('local_detect: chmod 600 wake-токена не удался');
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('local_detect: WARN не удалось опубликовать wake-токен: $e');
    }
  }

  /// Прочитать действующий wake-токен (для вызывающих /autoshare, например
  /// второго экземпляра приложения — lib/main.dart). null — токена нет
  /// (слушатель не поднят/недоступен): вызывающий получит 403.
  static Future<String?> readWakeToken() async {
    if (kIsWeb) return null;
    try {
      final file = File(_wakeTokenFilePath());
      if (!await file.exists()) return null;
      final token = (await file.readAsString()).trim();
      return RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ? token : null;
    } catch (_) {
      return null;
    }
  }

  void _handle(HttpRequest request) async {
    final origin = request.headers.value('origin');

    // A-04/A-02: доставка намерения autoshare работающему экземпляру.
    // Только локальные вызывающие: Origin отсутствует (нативный сокет/CLI),
    // 'null' или localhost. Браузерный Origin (веб-кабинет и тем более
    // произвольный сайт) не допускается — плюс обязательный wake-токен.
    if (request.uri.path == '/autoshare') {
      if (request.method == 'POST') {
        String? bodyToken;
        String? sid;
        try {
          final content = await utf8.decoder.bind(request).join();
          final data = jsonDecode(content);
          sid = data is Map ? data['session_id']?.toString() : null;
          bodyToken = data is Map ? data['wake_token']?.toString() : null;
        } catch (e) {
          debugPrint('local_detect: ошибка autoshare payload: $e');
        }
        final presented = request.headers.value('x-wake-token') ?? bodyToken;
        // A-2: Origin только локальный + обязательный wake-токен.
        if (!autoshareAuthorized(origin, presented, _wakeToken)) {
          debugPrint(
              'local_detect: /autoshare отклонён (Origin=${origin ?? '—'}, токен)');
          final res = request.response;
          res.statusCode = 403;
          await res.close();
          return;
        }
        if (sid != null && sid.isNotEmpty) {
          onAutoshare?.call(sid);
          final res = request.response;
          res.statusCode = 200;
          res.headers.set('Content-Type', 'application/json; charset=utf-8');
          res.write(jsonEncode({'ok': true, 'session_id': sid}));
          await res.close();
          return;
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

    // A-8: детект отвечает только «своим». Настройки клиента уже хранят
    // адрес сервера (server_url) — веб-кабинет живёт на его origin.
    String? serverOrigin;
    try {
      final prefs = await SharedPreferences.getInstance();
      serverOrigin = prefs.getString(kServerUrlPrefKey);
    } catch (_) {}

    final reply = localDetectResponse(
      request.method,
      request.uri.path,
      _deviceId ?? '',
      origin: origin,
      serverOrigin: serverOrigin,
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

/// A-2: чистая логика авторизации POST /autoshare.
///
/// Разрешены только локальные вызывающие: Origin отсутствует (нативный
/// сокет/CLI), literal 'null' или localhost; origin настроенного сервера
/// НЕ допускается — веб-кабинет не должен будить трансляцию из браузера.
/// Wake-токен обязан совпадать с токеном слушателя (сравнение постоянного
/// времени); [expectedToken] == null — слушатель не поднял токен, отказ.
bool autoshareAuthorized(
    String? origin, String? presentedToken, String? expectedToken) {
  if (origin != null && !localDetectOriginAllowed(origin, null)) {
    return false;
  }
  if (expectedToken == null || presentedToken == null) {
    return false;
  }
  // сравнение постоянного времени (защита от timing-оракала на токене)
  if (presentedToken.length != expectedToken.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < presentedToken.length; i++) {
    diff |= presentedToken.codeUnitAt(i) ^ expectedToken.codeUnitAt(i);
  }
  return diff == 0;
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

/// Эффективный порт origin-а с подстановкой порта по умолчанию.
int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  switch (uri.scheme) {
    case 'http':
    case 'ws':
      return 80;
    case 'https':
    case 'wss':
      return 443;
  }
  return -1;
}

/// Нормализация origin-а к виду scheme://host:port (регистр хоста — lower).
String? _normalizedOrigin(Uri uri) {
  if (uri.host.isEmpty) return null;
  return '${uri.scheme}://${uri.host.toLowerCase()}:${_effectivePort(uri)}';
}

/// A-8: разрешён ли Origin запроса к локальному детекту.
///
/// Разрешены:
/// - null/пустой (CLI и нативные клиенты без Origin);
/// - literal 'null' (строка «null» из песочниц/файловых страниц);
/// - localhost / 127.0.0.1 / [::1] на любом порту;
/// - [serverOrigin] — origin настроенного сервера (только для GET /ligament:
///   вызывающий сам решает, передавать ли его; /autoshare передаёт null).
/// Всё прочее (в т.ч. любые публичные сайты) — запрещено.
bool localDetectOriginAllowed(String origin, String? serverOrigin) {
  final trimmed = origin.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase() == 'null') return true;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]') {
    return true;
  }
  if (serverOrigin != null && serverOrigin.trim().isNotEmpty) {
    final serverUri = Uri.tryParse(serverOrigin.trim());
    if (serverUri != null) {
      final a = _normalizedOrigin(uri);
      final b = _normalizedOrigin(serverUri);
      return a != null && a == b;
    }
  }
  return false;
}

/// Чистая логика ответа локального детекта — тестируется без сокета.
///
/// [origin] — заголовок Origin запроса (null — отсутствует);
/// [serverOrigin] — origin настроенного сервера (server_url), может быть
/// null, если настройки недоступны: тогда браузерные origin не проходят.
LocalDetectReply localDetectResponse(
  String method,
  String path,
  String deviceId, {
  String? origin,
  String? serverOrigin,
}) {
  if (path != kLocalDetectPath) {
    return const LocalDetectReply(404, {}, '');
  }
  // A-8: чужой Origin — молча 403 без тела (фингерпринтинг не собираем).
  if (origin != null && !localDetectOriginAllowed(origin, serverOrigin)) {
    return const LocalDetectReply(403, {}, '');
  }
  // CORS-заголовки нужны только браузерному (проверенному) origin —
  // эхо конкретного значения вместо дикого `*` (A-8).
  final corsHeaders = <String, String>{
    if (origin != null && origin.trim().isNotEmpty)
      'Access-Control-Allow-Origin': origin.trim(),
  };
  switch (method) {
    case 'GET':
      return LocalDetectReply(
        200,
        {
          ...corsHeaders,
          'Cache-Control': 'no-store',
          'Content-Type': 'application/json; charset=utf-8',
        },
        jsonEncode({'v': 1, 'device_id': deviceId}),
      );
    case 'OPTIONS':
      // Preflight только для проверенного origin. Access-Control-
      // Allow-Private-Network удалён (A-2/A-8): публичные страницы больше
      // не получают доступ к localhost-детекту.
      return LocalDetectReply(
        204,
        {
          ...corsHeaders,
          'Access-Control-Allow-Methods': 'GET, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
          'Cache-Control': 'no-store',
        },
        '',
      );
    default:
      return const LocalDetectReply(404, {}, '');
  }
}
