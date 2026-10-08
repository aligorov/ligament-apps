import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../api/client.dart';

/// RDP-коннектор (этап 2.2 плана docs/rdp-client-stage2-plan.md §3):
/// grant → локальный loopback-слушатель → WS-мост до ядра → mstsc.
///
/// Последовательность:
///   POST /api/v1/app/rdp/grant {target_id, mode:"rdp"}
///     201 {grant_id, token, route, expires_in:60}
///   ServerSocket.bind(127.0.0.2, 0)              — случайный порт
///   IOWebSocketChannel wss://…/rdp/connect?grant=&token= (бинарные кадры)
///   Process.start mstsc /v:127.0.0.2:<port>       — Windows only
///   слушатель принимает РОВНО одно соединение (грант одноразовый, R2)
///   байты: mstsc ↔ listener ↔ WS ↔ ядро ↔ цель
///   mstsc закрыт / WS оборван / close() → listener+WS вниз, /rdp/close.
///
/// Мост — пара addStream (план §3.3): честный backpressure в обе стороны,
/// без ручного listen/add (смешение с addStream на StreamSink запрещено).
/// Один main-isolate: RDP-интерактив — единицы Мбит/с, замер jank — риск R1.
class RdpConnectorService extends ChangeNotifier {
  RdpTunnelPhase _phase = RdpTunnelPhase.idle;
  RdpTunnelPhase get phase => _phase;

  /// Человеческое пояснение текущего шага (RU/EN выбирает владелец-экран).
  String? phaseDetail;
  String? lastError;
  String? targetName;

  _RdpTunnelSession? _session;

  bool get isBusy =>
      _phase == RdpTunnelPhase.grant ||
      _phase == RdpTunnelPhase.listener ||
      _phase == RdpTunnelPhase.tunnel ||
      _phase == RdpTunnelPhase.launching;
  bool get isActive => _phase == RdpTunnelPhase.active;

  void _setPhase(RdpTunnelPhase p, {String? detail}) {
    _phase = p;
    phaseDetail = detail;
    if (p != RdpTunnelPhase.failed) lastError = null;
    notifyListeners();
  }

  /// Тестируемый шов платформенного guard'а (flutter test на macOS/Linux).
  @visibleForTesting
  static bool? windowsOverride;

  bool get _canRunMstsc => windowsOverride ?? (!kIsWeb && Platform.isWindows);

  /// Запуск туннеля до цели. Владелец — AuthState (одиночка на приложение).
  /// Только Windows (mstsc): на остальных платформах этапа 2 — режим
  /// «Экран» (§5), RDP-кнопка на плитке не рисуется; guard ниже — защита.
  Future<void> connect({
    required ApiClient api,
    required String baseUrl,
    required String targetId,
    required String name,
    bool isRu = true,
  }) async {
    if (isBusy || isActive) return;
    if (!_canRunMstsc) {
      _fail(isRu
          ? 'RDP-подключение доступно только на Windows'
          : 'RDP connection is available on Windows only');
      return;
    }
    targetName = name;
    _setPhase(RdpTunnelPhase.grant);

    // 1. Грант (ошибки 403/409/428 мапятся ниже в человеческий текст).
    final Map<String, dynamic> grant;
    try {
      grant = await api.rdpGrant(targetId: targetId, mode: 'rdp');
    } on ApiException catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    final grantId = grant['grant_id']?.toString() ?? '';
    final token = grant['token']?.toString() ?? '';
    final expiresIn = int.tryParse(grant['expires_in']?.toString() ?? '') ?? 60;
    if (grantId.isEmpty || token.isEmpty) {
      _fail(isRu ? 'Сервер вернул некорректный грант' : 'Server returned a malformed grant');
      return;
    }

    final session = _RdpTunnelSession(grantId: grantId);
    _session = session;

    // 2. Loopback-слушатель на случайном порту (127.0.0.2 — не конфликтует
    // с localhost-сервисами клиента, весь 127/8 маршрутизируется на loopback;
    // fallback на 127.0.0.1 для экзотических стеков).
    _setPhase(RdpTunnelPhase.listener);
    ServerSocket listener;
    try {
      listener = await _bindLoopback();
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    session.listener = listener;
    final port = listener.port;
    final host = listener.address.address;

    // TTL-гранта: если туннель не активен к моменту истечения — отмена.
    session.grantTtl = Timer(Duration(seconds: expiresIn), () {
      if (_session == session && !isActive) {
        _finish(session, reason: _TunnelEndReason.expired, isRu: isRu);
      }
    });

    // 3. WS-труба до ядра (claim на сервере: grant→active, session создана).
    _setPhase(RdpTunnelPhase.tunnel);
    final wsUrl = rdpWsConnectUrl(baseUrl, grantId, token);
    IOWebSocketChannel ws;
    try {
      ws = IOWebSocketChannel.connect(
        wsUrl,
        connectTimeout: const Duration(seconds: 10),
        pingInterval: const Duration(seconds: 20),
      );
      await ws.ready;
    } catch (e) {
      await _teardownListener(session);
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    if (_session != session) {
      // close() успел отработать между await'ами — тихо выходим.
      await _quietTeardown(session, ws);
      return;
    }
    session.ws = ws;

    // 4. mstsc (только Windows: на остальных платформах этапа 2 — «Экран»).
    _setPhase(RdpTunnelPhase.launching);
    Process? mstsc;
    try {
      mstsc = await _startMstsc(host, port);
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardown(session, ws);
      return;
    }

    // 4b. mstsc не найден — туннель не нужен.
    if (mstsc == null) {
      _fail(isRu
          ? 'Не удалось запустить удалённый рабочий стол (mstsc.exe)'
          : 'Failed to launch Remote Desktop (mstsc.exe)');
      await _quietTeardown(session, ws);
      return;
    }
    session.mstsc = mstsc;
    // Пользователь закрыл окно mstsc → сессия завершена (§3.5).
    unawaited(mstsc.exitCode.then(
      (_) {
        if (_session == session) {
          _finish(session, reason: _TunnelEndReason.mstscExited, isRu: isRu);
        }
      },
    ));

    // 5. Одно TCP-соединение на грант: слушатель умирает вместе с ним (R2 —
    // автопереподключение mstsc после микроразрыва отвергается, новый
    // запуск = новая плитка/новый грант).
    _setPhase(RdpTunnelPhase.active, detail: '$host:$port');
    final Socket socket;
    try {
      socket = await listener.first.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException('mstsc connect timeout'),
      );
    } catch (e) {
      if (_session != session) return; // уже закрыто параллельным путём
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardown(session, ws);
      return;
    }
    if (_session != session) {
      // Закрыли, пока ждали соединение.
      try {
        socket.destroy();
      } catch (_) {}
      return;
    }
    session.socket = socket;
    session.grantTtl?.cancel();

    // 6. Мост: TCP ↔ WS бинарными кадрами. addStream в обе стороны —
    // backpressure без ручной буферизации (§3.3); завершение любой стороны
    // завершает сессию:
    //   - ws.sink.addStream(socket) завершится, когда mstsc закроет сокет;
    //   - socket.addStream(ws.stream) завершится, когда ядро разорвёт WS
    //     (kill-switch, ревок, сеть) — это и есть детектор обрыва трубы.
    unawaited(
      ws.sink.addStream(socket.cast<Uint8List>()).then(
            (_) => _finish(session, reason: _TunnelEndReason.socketClosed, isRu: isRu),
            onError: (Object e) =>
                _finish(session, reason: _TunnelEndReason.socketClosed, isRu: isRu),
          ),
    );
    unawaited(
      socket.addStream(ws.stream.cast<List<int>>()).then(
            (_) => _finish(session, reason: _TunnelEndReason.wsClosed, isRu: isRu),
            onError: (Object e) =>
                _finish(session, reason: _TunnelEndReason.wsClosed, isRu: isRu),
          ),
    );
  }

  /// Завершить сессию (кнопка «Завершить»/«Отменить», logout, dispose).
  Future<void> close({bool isRu = true}) async {
    final s = _session;
    if (s == null) {
      _setPhase(RdpTunnelPhase.idle);
      return;
    }
    _finish(s, reason: _TunnelEndReason.user, isRu: isRu);
  }

  void _fail(String text) {
    _session = null; // мёртвая сессия не должна блокировать следующий заход
    lastError = text;
    _phase = RdpTunnelPhase.failed;
    notifyListeners();
  }

  Future<void> _finish(_RdpTunnelSession s,
      {required _TunnelEndReason reason, required bool isRu}) async {
    if (_session != s) return;
    _session = null;
    s.grantTtl?.cancel();
    // mstsc рвём всегда, КРОМЕ случая «пользователь сам закрыл mstsc» —
    // там процесс уже завершился.
    if (reason != _TunnelEndReason.mstscExited) {
      try {
        s.mstsc?.kill();
      } catch (_) {}
    }
    try {
      s.socket?.destroy();
    } catch (_) {}
    try {
      await s.ws?.sink.close();
    } catch (_) {}
    await _teardownListener(s);
    // Идемпотентное закрытие гранта: сервер уже закрыл его по разрыву
    // трубы — повторный close безвреден (§3.4).
    final gid = s.grantId;
    if (gid.isNotEmpty) {
      unawaited(_closeGrantQuietly(gid));
    }

    switch (reason) {
      case _TunnelEndReason.user:
      case _TunnelEndReason.mstscExited:
      case _TunnelEndReason.socketClosed:
      case _TunnelEndReason.wsClosed:
        _setPhase(RdpTunnelPhase.closed);
        break;
      case _TunnelEndReason.expired:
        _fail(isRu
            ? 'Время гранта истекло до установления сессии — попробуйте ещё раз'
            : 'Grant expired before the session was established — try again');
        break;
    }
  }

  Future<void> _closeGrantQuietly(String grantId) async {
    // Держатель api не хранится в сессии сознательно: close может прийти
    // из dispose/logout. Ссылку берём через владельца (AuthState) в
    // closeGrantHook — см. setCloseGrantHandler.
    final hook = closeGrantHandler;
    if (hook == null) return;
    try {
      await hook(grantId).timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// Хук закрытия гранта (api.rdpClose) — ставит AuthState при создании
  /// сессии; отвязка при logout.
  Future<void> Function(String grantId)? closeGrantHandler;

  Future<void> _teardownListener(_RdpTunnelSession s) async {
    try {
      await s.listener?.close();
    } catch (_) {}
    s.listener = null;
  }

  Future<void> _quietTeardown(_RdpTunnelSession s, IOWebSocketChannel? ws) async {
    s.grantTtl?.cancel();
    try {
      ws?.sink.close();
    } catch (_) {}
    await _teardownListener(s);
  }

  @override
  void dispose() {
    final s = _session;
    _session = null;
    s?.grantTtl?.cancel();
    try {
      s?.mstsc?.kill();
    } catch (_) {}
    try {
      s?.socket?.destroy();
    } catch (_) {}
    try {
      s?.ws?.sink.close();
    } catch (_) {}
    try {
      s?.listener?.close();
    } catch (_) {}
    super.dispose();
  }
}

enum RdpTunnelPhase {
  idle,
  grant,
  listener,
  tunnel,
  launching,
  active,
  closed,
  failed,
}

enum _TunnelEndReason { user, mstscExited, socketClosed, wsClosed, expired }

class _RdpTunnelSession {
  final String grantId;
  ServerSocket? listener;
  IOWebSocketChannel? ws;
  Socket? socket;
  Process? mstsc;
  Timer? grantTtl;

  _RdpTunnelSession({required this.grantId});
}

// ---- чистые функции (тестируются без сети/сокетов) ----

/// Адрес локального слушателя: 127.0.0.2 — весь 127/8 это loopback, адрес
/// не конфликтует с занятыми портами других localhost-сервисов клиента
/// (local-detect на 127.0.0.1:8757) и лишает Windows «оптимизаций»
/// loopback-RDP на 127.0.0.1 (план §3.6).
InternetAddress rdpLoopbackBindAddress() => InternetAddress('127.0.0.2');

Future<ServerSocket> _bindLoopback() async {
  try {
    return await ServerSocket.bind(rdpLoopbackBindAddress(), 0);
  } on SocketException {
    // Экзотический стек без 127/8 — деградируем на стандартный loopback.
    return await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  }
}

/// URL WS-трубы: https-база → wss + /api/v1/app/rdp/connect?grant&token.
/// Токен в query — единственный реализованный сервером способ предъявления
/// (расхождение с дизайн-доком §5 зафиксировано в плане §1.1).
Uri rdpWsConnectUrl(String baseUrl, String grantId, String token) {
  var base = baseUrl.trim();
  if (base.startsWith('https://')) {
    base = 'wss://${base.substring(8)}';
  } else if (base.startsWith('http://')) {
    base = 'ws://${base.substring(7)}';
  }
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  return Uri.parse(
    '$base/api/v1/app/rdp/connect',
  ).replace(queryParameters: {'grant': grantId, 'token': token});
}

/// HTTP-статус из ошибки WS-handshake (best effort — dart:io не даёт
/// типизированного статуса; паттерн ws_service._isUnauthorized).
int? rdpWsHandshakeStatus(Object error) {
  final s = error.toString();
  final m = RegExp(r'(^|[^0-9])(410|400|502|503|409|401)([^0-9]|$)').firstMatch(s);
  return m == null ? null : int.tryParse(m.group(2)!);
}

/// Человеческий текст ошибки подключения по кодам сервера (план §3.1).
/// Чистая функция — покрыта тестами (test/rdp_tunnel_test.dart).
String rdpConnectErrorText(Object error, {required bool isRu}) {
  String srvCode = '';
  int status = 0;
  if (error is ApiException) {
    status = error.statusCode;
    srvCode = error.code;
  } else {
    final wsStatus = rdpWsHandshakeStatus(error);
    if (wsStatus != null) status = wsStatus;
  }
  switch (srvCode) {
    case 'target_not_assigned':
      return isRu
          ? 'Рабочее место не назначено вашей учётной записи'
          : 'This workstation is not assigned to your account';
    case 'passkey_required':
      return isRu
          ? 'Для этой цели требуется вход по passkey — подтвердите вход ключом доступа'
          : 'This target requires a passkey — confirm sign-in with your security key';
    case 'mfa_required':
      return isRu
          ? 'Требуется свежее подтверждение входа: войдите в приложение заново с кодом второго фактора или выполните вход в веб-кабинете (действует 10 минут)'
          : 'A recent sign-in confirmation is required: re-login with a second-factor code or sign in to the web portal (valid for 10 minutes)';
    case 'target_busy':
      return isRu
          ? 'Все сессии рабочего места заняты — попробуйте позже'
          : 'All workstation sessions are busy — try again later';
    case 'unsupported_route':
      return isRu
          ? 'Маршрут цели не поддерживается: служба Ligament на рабочем месте не подключена'
          : 'Unsupported target route: the Ligament endpoint service is not connected';
  }
  switch (status) {
    case 410:
      return isRu
          ? 'Время гранта истекло — повторите подключение'
          : 'Grant expired — please reconnect';
    case 502:
      return isRu
          ? 'Рабочее место недоступно: цель не отвечает'
          : 'Workstation unreachable: the target is not responding';
    case 503:
      return isRu
          ? 'Релей недоступен — попробуйте позже'
          : 'Relay unavailable — try again later';
  }
  if (error is TimeoutException) {
    return isRu
        ? 'Превышено время ожидания подключения'
        : 'Connection timed out';
  }
  if (error is SocketException) {
    return isRu ? 'Нет связи с сервером' : 'No connection to the server';
  }
  return isRu ? 'Ошибка подключения: $error' : 'Connection error: $error';
}

/// Запуск mstsc с fallback-путём System32 (§3.5). null — не найден.
Future<Process?> _startMstsc(String host, int port) async {
  final arg = '/v:$host:$port';
  try {
    return await Process.start('mstsc', [arg]);
  } catch (_) {
    try {
      return await Process.start(r'C:\Windows\System32\mstsc.exe', [arg]);
    } catch (_) {
      return null;
    }
  }
}
