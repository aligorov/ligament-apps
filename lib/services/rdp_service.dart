import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import '../api/client.dart';
import '../widgets/rdp_mfa_dialog.dart';
import 'telemetry_service.dart';

/// RDP-коннектор (этап 2.2 плана docs/rdp-client-stage2-plan.md §3):
/// grant → локальный loopback-слушатель → WS-мост до ядра → mstsc.
///
/// Последовательность:
///   POST /api/v1/app/rdp/grant {target_id, mode:"rdp"}
///     201 {grant_id, token, route, expires_in:60}
///   ServerSocket.bind(127.0.0.2, 0)              — случайный порт
///   IOWebSocketChannel wss://…/rdp/connect?grant=<grant_id>
///     (Authorization: Bearer <device-токен>; грант-токен — подпротоколом
///      Sec-WebSocket-Protocol: grant, <hex> — не в query, чтобы секрет
///      не оседал в логах/прокси)                      (бинарные кадры)
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
  int _connectGeneration = 0;

  bool get isBusy =>
      _phase == RdpTunnelPhase.grant ||
      _phase == RdpTunnelPhase.listener ||
      _phase == RdpTunnelPhase.tunnel ||
      _phase == RdpTunnelPhase.launching ||
      _phase == RdpTunnelPhase.waitingClient;
  bool get isActive => _phase == RdpTunnelPhase.active;

  void _setPhase(RdpTunnelPhase p, {String? detail}) {
    _phase = p;
    phaseDetail = detail;
    if (p != RdpTunnelPhase.failed) lastError = null;
    notifyListeners();
  }

  /// Тестируемый шов платформенного guard'а (flutter test на macOS/Linux).
  /// _grantWithInlineMfa — grant с инлайн-подтверждением кода или Passkey: 428
  /// mfa_required (или 401 invalid_code при повторе) запрашивает подтверждение через
  /// mfaPrompt (или mfaCodePrompt) и повторяет запрос. Пустая карта = отмена.
  static Future<Map<String, dynamic>> _grantWithInlineMfa(
    Future<Map<String, dynamic>> Function({String? code, String? attemptId}) grant,
    Future<RdpMfaResult?> Function(bool wrongCode)? mfaPrompt,
  ) async {
    String? code;
    String? attemptId;
    while (true) {
      try {
        return await grant(code: code, attemptId: attemptId);
      } on ApiException catch (e) {
        if (mfaPrompt == null) rethrow;
        if (e.statusCode != 428 && e.code != 'invalid_code' && e.code != 'mfa_required') rethrow;
        final res = await mfaPrompt(e.code == 'invalid_code');
        if (res == null) return const {};
        code = res.code;
        attemptId = res.attemptId;
        if ((code == null || code.isEmpty) && (attemptId == null || attemptId.isEmpty)) return const {};
      }
    }
  }

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
    String? actionId,
    String? sourceInstanceId,
    Future<RdpMfaResult?> Function(bool wrongCode)? mfaPrompt,
    Future<String?> Function(bool wrongCode)? mfaCodePrompt,
  }) async {
    if (isBusy || isActive) return;
    if (!_canRunMstsc) {
      _fail(isRu
          ? 'RDP-подключение доступно только на Windows'
          : 'RDP connection is available on Windows only');
      return;
    }
    final generation = ++_connectGeneration;
    targetName = name;
    _setPhase(RdpTunnelPhase.grant);

    // 1. Грант (ошибки 403/409/428 мапятся ниже в человеческий текст).
    // 428 mfa_required — инлайн-подтверждение кодом TOTP.
    // неверный код переспрашивается, отмена тихо останавливает подключение.
    final Map<String, dynamic> grant;
    final promptFn = mfaPrompt ??
        (mfaCodePrompt != null
            ? (wrong) async {
                final c = await mfaCodePrompt(wrong);
                return c != null ? RdpMfaResult(code: c) : null;
              }
            : null);
    final localIps = await TelemetryService.getLocalIPs();
    try {
      grant = await _grantWithInlineMfa(
        ({code, attemptId}) => api.rdpGrant(
          targetId: targetId,
          mode: 'rdp',
          code: code,
          attemptId: attemptId,
          actionId: actionId,
          sourceInstanceId: sourceInstanceId,
          clientLocalIps: localIps,
        ),
        promptFn,
      );
    } on ApiException catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    if (_connectGeneration != generation) return;
    if (grant.isEmpty) {
      // Пользователь отменил ввод кода — тихий отказ, без «ошибки».
      _setPhase(RdpTunnelPhase.idle);
      return;
    }
    final grantId = grant['grant_id']?.toString() ?? '';
    final token = grant['token']?.toString() ?? '';
    final expiresIn = int.tryParse(grant['expires_in']?.toString() ?? '') ?? 60;
    final targetHost = grant['target_host']?.toString();
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
    if (_connectGeneration != generation || _session != session) {
      try { await listener.close(); } catch (_) {}
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
    //    Device-токен — заголовком Authorization. Грант-токен — подпротоколом
    //    Sec-WebSocket-Protocol: grant, <hex> (формат согласован с сервером;
    //    поддержан и браузерным WebSocket API, и dart IOWebSocketChannel) —
    //    в query секрет не кладём: URL пишут в логи прокси/балансировщика.
    _setPhase(RdpTunnelPhase.tunnel);
    final wsUrl = rdpWsConnectUrl(baseUrl, grantId);
    IOWebSocketChannel ws;
    try {
      ws = IOWebSocketChannel.connect(
        wsUrl,
        protocols: rdpWsSubprotocols(token),
        headers: {
          if (api.token != null && api.token!.isNotEmpty)
            'Authorization': 'Bearer ${api.token}',
        },
        connectTimeout: const Duration(seconds: 10),
        pingInterval: const Duration(seconds: 20),
      );
      await ws.ready;
    } catch (e) {
      await _teardownListener(session);
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    if (_connectGeneration != generation || _session != session) {
      // close() успел отработать между await'ами — тихо выходим.
      await _quietTeardown(session, ws);
      return;
    }
    session.ws = ws;

    // 4. mstsc (только Windows: на остальных платформах этапа 2 — «Экран»).
    _setPhase(RdpTunnelPhase.launching);
    final tempRdp = _createTempRdpFile(
      grantId: grantId,
      host: host,
      port: port,
      targetHost: targetHost,
    );
    session.tempRdpFile = tempRdp;
    Process? mstsc;
    try {
      mstsc = await _startMstsc(host: host, port: port, tempRdpFile: tempRdp);
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

    // 5. Ожидание клиента (mstsc): слушатель принимает РОВНО одно loopback-соединение.
    _setPhase(RdpTunnelPhase.waitingClient, detail: '$host:$port');
    final Socket socket;
    try {
      socket = await listener.first.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException('mstsc connect timeout'),
      );
    } catch (e) {
      if (_session != session || _connectGeneration != generation) return; // уже закрыто
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardown(session, ws);
      return;
    }
    if (_session != session || _connectGeneration != generation) {
      // Закрыли, пока ждали соединение.
      try {
        socket.destroy();
      } catch (_) {}
      return;
    }
    final clientIp = socket.remoteAddress.address;
    if (clientIp != '127.0.0.1' && clientIp != '127.0.0.2' && !clientIp.startsWith('127.')) {
      try { socket.destroy(); } catch (_) {}
      _fail(isRu ? 'Отвергнуто внешнее подключение к порту RDP' : 'Rejected non-loopback connection to RDP port');
      await _quietTeardown(session, ws);
      return;
    }
    session.socket = socket;
    session.grantTtl?.cancel();

    // 6. Мост: TCP ↔ WS бинарными кадрами.
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
    _setPhase(RdpTunnelPhase.active, detail: '$host:$port');
  }

  /// Bridge Connector-helper (закрытие P1 #3 аудита 2026-10-08, план §4.3):
  /// подключение через одноразовый TCP-порт ядра для гранта чужого ПК.
  ///
  /// .rdp-файл несовместим с token-handshake моста (mstsc первым делом шлёт
  /// X.224 Connection Request, а не hex-токен гранта), поэтому приложение
  /// само выступает коннектором:
  ///
  ///   POST /api/v1/app/rdp/bridge-info {grant_id, token} → {host, port}
  ///   TCP connect host:port
  ///   → token + "\n" (hex; handshake порта, аудит #1 first-come-wins)
  ///   → окно подтверждения: порт не разорвал соединение (= токен принят;
  ///     подтверждения байтом нет — отказ порта это немедленный EOF)
  ///   → ServerSocket.bind(127.0.0.2, 0)
  ///   → mstsc /v:127.0.0.2:<localPort>
  ///   → мост: mstsc ↔ listener ↔ bridge-сокет ↔ ядро ↔ цель
  ///
  /// Грант+токен выдаёт вызывающая сторона (POST /rdp/grant mode=bridge);
  /// claim происходит на сервере в момент handshake порта.
  Future<void> connectBridge({
    required ApiClient api,
    required String grantId,
    required String token,
    String? name,
    bool isRu = true,
  }) async {
    if (isBusy || isActive) return;
    if (!_canRunMstsc) {
      _fail(isRu
          ? 'RDP-подключение доступно только на Windows'
          : 'RDP connection is available on Windows only');
      return;
    }
    if (grantId.isEmpty || token.isEmpty) {
      _fail(isRu
          ? 'Некорректный грант сессии'
          : 'Malformed session grant');
      return;
    }
    final generation = ++_connectGeneration;
    if (name != null && name.isNotEmpty) {
      targetName = name;
    }
    _setPhase(RdpTunnelPhase.grant);

    // 1. Адрес bridge-порта от сервера (токен — телом POST, не в query).
    final Map<String, dynamic> info;
    try {
      info = await api.rdpBridgeInfo(grantId: grantId, token: token);
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    if (_connectGeneration != generation) return;
    final endpoint = rdpBridgeEndpoint(info);
    if (endpoint == null) {
      _fail(isRu
          ? 'Сервер вернул некорректный адрес моста'
          : 'Server returned a malformed bridge endpoint');
      return;
    }
    final (bridgeHost, bridgePort) = endpoint;

    final session = _RdpTunnelSession(grantId: grantId);
    _session = session;

    // 2. TCP до bridge-порта ядра.
    _setPhase(RdpTunnelPhase.tunnel);
    Socket bridge;
    try {
      bridge = await Socket.connect(
        bridgeHost,
        bridgePort,
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      return;
    }
    if (_connectGeneration != generation || _session != session) {
      try { bridge.destroy(); } catch (_) {}
      return;
    }
    session.remote = bridge;

    // 3. Handshake: hex-токен + "\n" первыми байтами (формат openBridgePort).
    //    Подтверждения байтом в протоколе нет: отказ (неверный токен/
    //    недоступная цель) — немедленный разрыв порта, поэтому «первый ответ
    //    ≠ EOF» проверяем коротким окном живости сокета. Ранние байты цели
    //    (X.224 Connection Confirm) буферизуются в сокете и уходят mstsc
    //    после мостирования — не drain'им.
    bridge.add(utf8.encode('$token\n'));
    bool rejected;
    try {
      rejected = await bridge.done.then((_) => true).timeout(
            rdpBridgeHandshakeWindow,
            onTimeout: () => false,
          );
    } catch (_) {
      rejected = true;
    }
    if (_session != session || _connectGeneration != generation) {
      // close() успел отработать между await'ами — тихо выходим.
      await _quietTeardownBridge(session);
      return;
    }
    if (rejected) {
      _fail(isRu
          ? 'Сервер отклонил подключение к мосту: токен гранта не принят или цель недоступна'
          : 'The server rejected the bridge connection: grant token not accepted or target unreachable');
      await _quietTeardownBridge(session);
      return;
    }

    // 4. Loopback-слушатель на случайном порту (как в connect(): 127.0.0.2).
    _setPhase(RdpTunnelPhase.listener);
    ServerSocket listener;
    try {
      listener = await _bindLoopback();
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardownBridge(session);
      return;
    }
    if (_session != session || _connectGeneration != generation) {
      try { await listener.close(); } catch (_) {}
      return;
    }
    session.listener = listener;
    final port = listener.port;
    final host = listener.address.address;

    // 5. mstsc на локальный слушатель — мост мостит его до bridge-порта.
    _setPhase(RdpTunnelPhase.launching);
    Process? mstsc;
    try {
      mstsc = await _startMstsc(host: host, port: port);
    } catch (e) {
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardownBridge(session);
      return;
    }
    if (mstsc == null) {
      _fail(isRu
          ? 'Не удалось запустить удаленный рабочий стол (mstsc.exe)'
          : 'Failed to launch Remote Desktop (mstsc.exe)');
      await _quietTeardownBridge(session);
      return;
    }
    session.mstsc = mstsc;
    // Пользователь закрыл окно mstsc → сессия завершена (как в connect()).
    unawaited(mstsc.exitCode.then(
      (_) {
        if (_session == session) {
          _finish(session, reason: _TunnelEndReason.mstscExited, isRu: isRu);
        }
      },
    ));

    // 6. Ожидание клиента (mstsc): слушатель принимает РОВНО одно соединение.
    _setPhase(RdpTunnelPhase.waitingClient, detail: '$host:$port');
    final Socket socket;
    try {
      socket = await listener.first.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException('mstsc connect timeout'),
      );
    } catch (e) {
      if (_session != session || _connectGeneration != generation) return; // уже закрыто
      _fail(rdpConnectErrorText(e, isRu: isRu));
      await _quietTeardownBridge(session);
      return;
    }
    if (_session != session || _connectGeneration != generation) {
      try {
        socket.destroy();
      } catch (_) {}
      return;
    }
    final clientIp = socket.remoteAddress.address;
    if (clientIp != '127.0.0.1' && clientIp != '127.0.0.2' && !clientIp.startsWith('127.')) {
      try { socket.destroy(); } catch (_) {}
      _fail(isRu ? 'Отвергнуто внешнее подключение к порту RDP' : 'Rejected non-loopback connection to RDP port');
      await _quietTeardownBridge(session);
      return;
    }
    session.socket = socket;

    // 7. Мост TCP↔TCP: mstsc ↔ bridge-порт ядра.
    unawaited(
      socket.addStream(bridge).then(
            (_) => _finish(session, reason: _TunnelEndReason.socketClosed, isRu: isRu),
            onError: (Object e) =>
                _finish(session, reason: _TunnelEndReason.socketClosed, isRu: isRu),
          ),
    );
    unawaited(
      bridge.addStream(socket).then(
            (_) => _finish(session, reason: _TunnelEndReason.remoteClosed, isRu: isRu),
            onError: (Object e) =>
                _finish(session, reason: _TunnelEndReason.remoteClosed, isRu: isRu),
          ),
    );
    _setPhase(RdpTunnelPhase.active, detail: '$host:$port');
  }

  /// Завершить сессию (кнопка «Завершить»/«Отменить», logout, dispose).
  Future<void> close({bool isRu = true}) async {
    _connectGeneration++;
    final s = _session;
    if (s == null) {
      _setPhase(RdpTunnelPhase.idle);
      return;
    }
    await _finish(s, reason: _TunnelEndReason.user, isRu: isRu);
  }

  void _cleanupTempRdpFile(_RdpTunnelSession s) {
    if (s.tempRdpFile != null) {
      try {
        if (s.tempRdpFile!.existsSync()) {
          s.tempRdpFile!.deleteSync();
        }
      } catch (_) {}
      s.tempRdpFile = null;
    }
  }

  void _fail(String text) {
    _connectGeneration++;
    final s = _session;
    if (s != null) {
      _cleanupTempRdpFile(s);
    }
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
    _cleanupTempRdpFile(s);
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
    // Bridge-сокет (connectBridge): разрыв удалённой ноги гасит локальную.
    try {
      s.remote?.destroy();
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
      case _TunnelEndReason.remoteClosed:
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
    _cleanupTempRdpFile(s);
    try {
      ws?.sink.close();
    } catch (_) {}
    await _teardownListener(s);
  }

  /// Разнос bridge-сессии без смены фазы (ошибки запуска connectBridge):
  /// гасим удалённую ногу, локальный сокет и слушатель.
  Future<void> _quietTeardownBridge(_RdpTunnelSession s) async {
    s.grantTtl?.cancel();
    _cleanupTempRdpFile(s);
    try {
      s.socket?.destroy();
    } catch (_) {}
    try {
      s.remote?.destroy();
    } catch (_) {}
    await _teardownListener(s);
  }

  @override
  void dispose() {
    final s = _session;
    _session = null;
    s?.grantTtl?.cancel();
    if (s != null) {
      _cleanupTempRdpFile(s);
    }
    try {
      s?.mstsc?.kill();
    } catch (_) {}
    try {
      s?.socket?.destroy();
    } catch (_) {}
    try {
      s?.remote?.destroy();
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
  waitingClient,
  active,
  closed,
  failed,
}

enum _TunnelEndReason { user, mstscExited, socketClosed, wsClosed, remoteClosed, expired }

class _RdpTunnelSession {
  final String grantId;
  ServerSocket? listener;
  IOWebSocketChannel? ws;

  /// remote — TCP-нога до bridge-порта ядра (connectBridge); в connect()
  /// эту роль играет WS-труба [ws].
  Socket? remote;
  Socket? socket;
  Process? mstsc;
  File? tempRdpFile;
  Timer? grantTtl;

  _RdpTunnelSession({required this.grantId});
}

// ---- чистые функции (тестируются без сети/сокетов) ----

/// Окно подтверждения handshake bridge-порта (connectBridge): после отправки
/// hex-токена порт-мост либо жив (токен принят, цель дозванивается), либо
/// молча разрывает соединение (неверный токен) — подтверждения байтом в
/// протоколе нет, живость ждём не дольше этого окна.
const Duration rdpBridgeHandshakeWindow = Duration(seconds: 2);

/// Разбор ответа POST /api/v1/app/rdp/bridge-info: {host, port} →
/// (host, port). null — некорректный ответ (нет полей/вне диапазона портов).
/// Чистая функция — покрыта тестами (test/rdp_tunnel_test.dart).
(String, int)? rdpBridgeEndpoint(Map<String, dynamic> info) {
  final host = info['host']?.toString().trim() ?? '';
  final port = int.tryParse(info['port']?.toString() ?? '');
  if (host.isEmpty || port == null || port < 1 || port > 65535) {
    return null;
  }
  return (host, port);
}

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

/// URL WS-трубы: https-база → wss + /api/v1/app/rdp/connect?grant=<id>.
/// Грант-токен в URL НЕ передаётся (секрет в query оседает в логах
/// прокси/балансировщика) — он идёт подпротоколом handshake'а, см.
/// [rdpWsSubprotocols]. Device-токен клиент предъявляет заголовком
/// Authorization (см. connect()).
Uri rdpWsConnectUrl(String baseUrl, String grantId) {
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
  ).replace(queryParameters: {'grant': grantId});
}

/// Подпротоколы WS-handshake RDP-трубы: сервер ждёт грант-токен в
/// `Sec-WebSocket-Protocol: grant, <hex>` — браузерный WebSocket API не
/// умеет кастомные заголовки, а список подпротоколов склеивается в один
/// заголовок через запятую и в браузере, и в dart IOWebSocketChannel
/// (аргумент protocols). Идентификатор 'grant' отмечает назначение
/// второго значения — сам одноразовый токен гранта.
List<String> rdpWsSubprotocols(String grantToken) => ['grant', grantToken];

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
    case 'self_connection_prohibited':
      return isRu
          ? 'Подключение к своему компьютеру запрещено'
          : 'Connecting to your current computer is prohibited';
    case 'bridge_disabled':
      return isRu
          ? 'Прямой TCP-мост отключен администратором'
          : 'Direct TCP bridge is disabled by administrator';
    case 'target_unavailable':
      return isRu
          ? 'Рабочее место выключено или недоступно'
          : 'Workstation is disabled or unavailable';
    case 'target_access_denied':
      return isRu
          ? 'Доступ к рабочему месту запрещён'
          : 'Access to workstation is denied';
    case 'machine_mismatch':
      return isRu
          ? 'Несоответствие целевого компьютера'
          : 'Target computer mismatch';
    case 'user_disabled':
      return isRu
          ? 'Учётная запись пользователя заблокирована'
          : 'User account is disabled';
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
          ? 'Требуется свежее подтверждение входа — введите код второго фактора'
          : 'A recent sign-in confirmation is required — enter a second-factor code';
    case 'invalid_code':
      return isRu
          ? 'Код подтверждения не принят — проверьте и введите заново'
          : 'The confirmation code was rejected — check and try again';
    case 'target_busy':
      return isRu
          ? 'Все сессии рабочего места заняты — попробуйте позже'
          : 'All workstation sessions are busy — try again later';
    case 'unsupported_route':
      return isRu
          ? 'Маршрут цели не поддерживается: служба Ligament на рабочем месте не подключена'
          : 'Unsupported target route: the Ligament endpoint service is not connected';
    case 'bridge_already_open':
      return isRu
          ? 'Мост для этой сессии уже открыт — завершите текущее подключение и повторите'
          : 'A bridge for this session is already open — finish the current connection and try again';
    case 'screen_device_unbound':
      return isRu
          ? 'Целевой ПК не привязан к устройству. Обратитесь к администратору'
          : 'Target PC is not linked to a device. Please contact administrator';
  }
  switch (status) {
    case 409:
      return isRu
          ? 'Подключение отклонено: конфликт сессии или самоподключение'
          : 'Connection rejected: session conflict or self-connection';
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

/// Создание временного .rdp-файла с привязкой identity цели (SPN/сертификат)
/// и маршрутизацией через локальный bridge (127.0.0.2:port).
File? _createTempRdpFile({
  required String grantId,
  required String host,
  required int port,
  String? targetHost,
}) {
  if (targetHost == null || targetHost.trim().isEmpty) return null;
  try {
    final safeGrant = grantId.replaceAll(RegExp(r'[^a-zA-Z0-9\-]'), '');
    final tempDir = Directory.systemTemp;
    final file = File('${tempDir.path}${Platform.pathSeparator}ligament_rdp_$safeGrant.rdp');
    final buffer = StringBuffer();
    buffer.writeln('full address:s:$targetHost');
    buffer.writeln('alternate full address:s:$host:$port');
    buffer.writeln('server port:i:$port');
    buffer.writeln('prompt for credentials:i:1');
    buffer.writeln('authentication level:i:2');
    buffer.writeln('enablecredsspsupport:i:1');
    file.writeAsStringSync(buffer.toString(), flush: true);
    return file;
  } catch (e) {
    debugPrint('rdp: failed to create temporary .rdp file: $e');
    return null;
  }
}

/// Запуск mstsc с fallback-путём System32 (§3.5). null — не найден.
Future<Process?> _startMstsc({
  required String host,
  required int port,
  File? tempRdpFile,
}) async {
  if (tempRdpFile != null) {
    try {
      return await Process.start('mstsc', [tempRdpFile.path]);
    } catch (_) {
      try {
        return await Process.start(r'C:\Windows\System32\mstsc.exe', [tempRdpFile.path]);
      } catch (_) {
        // Fallback на обычный /v аргумент
      }
    }
  }
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
