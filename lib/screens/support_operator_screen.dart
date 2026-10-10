import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:window_manager/window_manager.dart';

import '../api/client.dart';
import '../services/remote_keyboard.dart';
import '../services/auth_state.dart';
import '../services/support_service.dart';
import '../services/ws_service.dart';
import '../i18n/app_strings.dart';

enum OperatorZoomMode {
  fit,
  original,
  zoomIn,
}

enum MouseClickMode {
  left,
  right,
}

/// Кнопка мыши для протокола агента (0 — левая, 1 — средняя, 2 — правая)
/// по полю buttons из PointerDownEvent с учетом принудительного режима ПКМ.
/// Чистая функция — покрыта юнит-тестами (M-4).
int pointerDownButton(int buttons, bool rightModeForced) {
  if (rightModeForced || buttons == kSecondaryButton) return 2;
  if (buttons == kMiddleMouseButton) return 1;
  return 0;
}

/// Ш4 (Д6): сигнал завершения сессии приходит в одном из двух видов —
/// верхний data['type'] или нормализованный payload['type'] (как SDP).
/// Матчится оба уровня. Чистая функция — покрыта юнит-тестами.
bool isSessionTerminatedMessage(Map<String, dynamic> data) {
  final payload = (data['data'] is Map<String, dynamic>)
      ? data['data'] as Map<String, dynamic>
      : const <String, dynamic>{};
  final top = data['type']?.toString();
  final inner = payload['type']?.toString();
  return top == 'session_ended' ||
      top == 'support_ended' ||
      top == 'console_end' ||
      inner == 'session_ended' ||
      inner == 'support_ended' ||
      inner == 'console_end';
}

/// Ш3 (§4.3): статус соединения по стадийным признакам — «Трансляция
/// активна» только при кадре И P2P; track без кадра остаётся промежуточным
/// «Подключено (P2P)». Чистая функция — покрыта юнит-тестами.
String consoleConnectionStatusKey(bool connected, bool frameReady) {
  if (connected && frameReady) return 'stream_active';
  if (connected) return 'p2p_connected';
  return 'init';
}

/// Ш4: Failed/Closed — завершение через grace-таймер; Disconnected —
/// временный статус (ICE restart должен работать), таймер не запускает.
/// Чистая функция — покрыта юнит-тестами.
bool pcStateRequiresGraceTermination(RTCPeerConnectionState state) =>
    state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
    state == RTCPeerConnectionState.RTCPeerConnectionStateClosed;

class SupportOperatorScreen extends StatefulWidget {
  final String sessionId;
  final String? numberMatch;
  final Map<String, dynamic> sessionData;
  final bool isChatOnly;

  /// Режим «Экран» (этап 2.4, план §5.2): viewer — ВЛАДЕЛЕЦ ПК, а не
  /// инженер поддержки. Отличия: заголовок «Мой ПК», нет number-match и
  /// инженерных атрибутов SOS (бейдж категории), статус-тексты про своё
  /// устройство. Доступ не требует роли инженера — подключение к сессии
  /// разрешено владельцу (серверная склейка S3).
  final bool ownerMode;

  const SupportOperatorScreen({
    super.key,
    required this.sessionId,
    this.numberMatch,
    required this.sessionData,
    this.isChatOnly = false,
    this.ownerMode = false,
  });

  @override
  State<SupportOperatorScreen> createState() => _SupportOperatorScreenState();
}

class _SupportOperatorScreenState extends State<SupportOperatorScreen> {
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  WebSocketChannel? _wsChannel;
  final List<RTCIceCandidate> _pendingCandidates = [];

  late bool _isChatOnly;
  String? _currentNumberMatch;
  String _statusKey = 'init';
  String? _statusArg;
  // Ш3 (§4.3): готовность консоли — независимые признаки. WS-открытие НЕ
  // означает «подключено»: _isConnected поднимается только P2P/track,
  // _frameReady — нативным onFirstFrameRendered (трек ≠ кадр).
  bool _signalReady = false;
  bool _isConnected = false;
  bool _frameReady = false;
  bool _isInputBlocked = false;
  bool _isControlEnabled = true;
  MouseClickMode _mouseClickMode = MouseClickMode.left;

  /// Ш3: управление готово = DataChannel открыт И управление не выключено.
  bool get _controlReady =>
      _isControlEnabled &&
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Ш3: активна ошибка стадии с кнопкой «Повторить».
  bool get _stageRetryActive =>
      _statusKey == 'pc_no_offer' ||
      _statusKey == 'pc_no_track' ||
      _statusKey == 'no_first_frame';

  void _setStatus(String key, [String? arg]) {
    setState(() {
      _statusKey = key;
      _statusArg = arg;
    });
  }

  String _getStatusText(AppStrings strings) {
    switch (_statusKey) {
      case 'init':
        return strings.initStatus;
      case 'chat':
        return strings.chatModeStatus;
      case 'waiting_consent':
        return strings.waitingUserConsent(_statusArg ?? '2FA');
      case 'owner_waiting':
        // Этап 2.4: цель получила support_prompt(owner:true) и стартует
        // трансляцию без accept-диалога — ждём первый кадр.
        return strings.ownerScreenWaiting;
      case 'ended_by_server':
        return strings.sessionEndedByServer;
      case 'session_ended':
        return strings.sessionEndedByUser;
      case 'pc_no_offer':
      case 'pc_no_track':
        // Ш3/A-06: owner-режим ждёт ответа приложения хозяина —
        // подсказываем проверить, что оно запущено.
        return widget.ownerMode
            ? strings.consoleOfferTimeoutOwner
            : strings.consolePcNotResponding;
      case 'no_first_frame':
        return strings.consoleNoFirstFrame;
      case 'stage_retry':
        return strings.consoleStageReconnecting;
      case 'pc_failed':
        return strings.consolePcConnectionLost;
      case 'conn_error':
        return '${strings.connErrorPrefix} ${_statusArg ?? ''}';
      case 'requesting_access':
        return strings.requestingScreenAccess;
      case 'req_error':
        return '${strings.reqErrorPrefix} ${_statusArg ?? ''}';
      case 'p2p_connected':
        return strings.p2pConnected;
      case 'disconnected':
        return '${strings.isRu ? 'Отключено' : 'Disconnected'} (${_statusArg ?? ''})';
      case 'stream_active':
        return strings.streamActive;
      default:
        return _statusKey;
    }
  }

  List<Map<String, dynamic>> _screens = [];
  String? _selectedScreenId;

  int _cpuPercent = 0;
  bool _cpuWarning = false;
  int _diskPercent = 0;
  int _diskFreeGb = 0;
  bool _diskWarning = false;

  OperatorZoomMode _zoomMode = OperatorZoomMode.fit;
  double _zoomScale = 1.0;
  final TransformationController _videoTransform = TransformationController();

  void _applyVideoZoom(double scale) {
    _zoomScale = scale.clamp(1.0, 8.0);
    _videoTransform.value =
        Matrix4.diagonal3Values(_zoomScale, _zoomScale, 1.0);
  }

  final FocusNode _keyboardFocus = FocusNode();
  final GlobalKey _videoKey = GlobalKey();

  /// Кнопка, нажатая в парном PointerDownEvent, по pointer id (M-4):
  /// в PointerUpEvent поле buttons уже 0, поэтому up обязан слать ту же
  /// кнопку, что была нажата (иначе middle/right клики залипают на агенте).
  final Map<int, int> _pointerDownButtons = {};

  /// Гарантированное освобождение всех зажатых кнопок мыши при потере фокуса или выходе

  /// Backoff реконнекта операторского WS (M-5).
  final ReconnectBackoff _wsBackoff = ReconnectBackoff();
  Timer? _wsReconnectTimer;
  Timer? _leaseTimer;

  // Ш3: единая система стадийных таймеров (Д5). Отдельного owner-таймера
  // больше нет — ожидание ответа хозяина ПК влито в offer-стадию.
  static const Duration _offerStageTimeout = Duration(seconds: 20);
  static const Duration _trackStageTimeout = Duration(seconds: 20);
  static const Duration _firstFrameTimeout = Duration(seconds: 15);
  // Ш4: grace-окно перед завершением по Failed/Closed P2P.
  static const Duration _pcGraceTimeout = Duration(seconds: 5);
  Timer? _offerStageTimer;
  Timer? _trackStageTimer;
  Timer? _firstFrameStageTimer;
  Timer? _pcGraceTimer;

  final RemoteKeyboard _remoteKeyboard = RemoteKeyboard();

  void _startLeaseRenewal() {
    _leaseTimer?.cancel();
    final auth = context.read<AuthState>();
    // Немедленное первое продление при открытии консоли (защита от истечения initial lease)
    auth.api
        ?.renewSupportLease(widget.sessionId)
        .catchError((_) => <String, dynamic>{});
    _leaseTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted || _isCleanedUp) return;
      try {
        await auth.api?.renewSupportLease(widget.sessionId);
      } on ApiException catch (e) {
        if (e.statusCode == 410 ||
            e.statusCode == 404 ||
            e.statusCode == 403 ||
            e.code == 'session_ended') {
          _leaseTimer?.cancel();
          _leaseTimer = null;
          // Ш4: lease 410/404/403 — единое завершение с корректным выходом
          if (mounted && !_isCleanedUp) {
            _onSessionTerminated('ended_by_server');
          }
        }
      } catch (_) {}
    });
  }

  /// Ш3: таймаут offer-стадии — после WS-open+request_offer нет offer/track.
  /// Только owner-режим (Консоль ПК): в SOS перед offer лежит человеческая
  /// стадия согласия без таймаута. ICE restart не мешает: таймер снимается
  /// приходом offer/track, а re-request при рестарте его не перезапускает.
  /// Guard — только жизненный цикл (Д5), готовность его НЕ гасит.
  void _startOfferStageTimer() {
    _offerStageTimer?.cancel();
    _offerStageTimer = null;
    if (!widget.ownerMode || _isCleanedUp) return;
    _offerStageTimer = Timer(_offerStageTimeout, () {
      if (!mounted || _isCleanedUp) return;
      _setStatus('pc_no_offer');
    });
  }

  void _cancelOfferStageTimer() {
    _offerStageTimer?.cancel();
    _offerStageTimer = null;
  }

  /// A-06 (аудит 2026-10-10): таймаут ожидания WebRTC track после получения offer
  void _startTrackStageTimer() {
    _trackStageTimer?.cancel();
    _trackStageTimer = null;
    if (_isCleanedUp) return;
    _trackStageTimer = Timer(_trackStageTimeout, () {
      if (!mounted || _isCleanedUp || _frameReady || _isConnected) return;
      _setStatus('pc_no_track');
    });
  }

  void _cancelTrackStageTimer() {
    _trackStageTimer?.cancel();
    _trackStageTimer = null;
  }

  /// Ш3: таймаут первого кадра — после onTrack нет onFirstFrameRendered.
  void _startFirstFrameStageTimer() {
    _firstFrameStageTimer?.cancel();
    _firstFrameStageTimer = null;
    if (_isCleanedUp) return;
    _firstFrameStageTimer = Timer(_firstFrameTimeout, () {
      if (!mounted || _isCleanedUp) return;
      // Страховка от потери нативного события: размеры текстуры обновились —
      // кадры реально идут, считаем кадр полученным.
      if (_remoteRenderer.videoWidth > 0 && _remoteRenderer.videoHeight > 0) {
        _markFrameReady();
        return;
      }
      _setStatus('no_first_frame');
    });
  }

  void _cancelFirstFrameStageTimer() {
    _firstFrameStageTimer?.cancel();
    _firstFrameStageTimer = null;
  }

  void _cancelStageTimers() {
    _cancelOfferStageTimer();
    _cancelTrackStageTimer();
    _cancelFirstFrameStageTimer();
  }

  /// A-22 (аудит 2026-10-10): безопасное освобождение всех зажатых кнопок мыши и клавиш
  void _releaseAllPressedInputs() {
    for (final btn in _pointerDownButtons.values.toList()) {
      _sendDataMessage({'type': 'mouse_up', 'button': btn, 'x': 0.0, 'y': 0.0});
    }
    _pointerDownButtons.clear();
    for (final message in _remoteKeyboard.releaseAll()) {
      _sendDataMessage(message);
    }
  }

  bool get _isViewOnlySession =>
      widget.sessionData['access_mode']?.toString() == 'view_only';

  /// Ш3/A-20: сброс стадийной готовности при переподключении (§4.3).
  void _resetStageReadiness() {
    _isConnected = false;
    _frameReady = false;
    _cancelStageTimers();
    _releaseAllPressedInputs();
  }

  /// Ш3: кадр реально отрисован — граница «изображение появилось».
  void _markFrameReady() {
    _cancelFirstFrameStageTimer();
    if (!mounted || _isCleanedUp) return;
    setState(() {
      _frameReady = true;
      if (_isConnected) {
        _statusKey = consoleConnectionStatusKey(_isConnected, _frameReady);
        _statusArg = null;
      }
    });
  }

  /// Ш3: повтор зависшей стадии — повторный request_offer и перезапуск
  /// стадийных таймеров; сигнальный канал потерян — реконнект WS.
  void _retryConnectionStage() {
    if (!mounted || _isCleanedUp) return;
    _cancelStageTimers();
    _resetStageReadiness();
    _setStatus('stage_retry');
    if (_signalReady) {
      _sendWsSignal({'type': 'request_offer'});
      _startOfferStageTimer();
    } else {
      _wsReconnectTimer?.cancel();
      try {
        _wsChannel?.sink.close();
      } catch (_) {}
      _wsChannel = null;
      _connectWebSocket();
    }
  }

  /// Ш4: grace-таймер завершения по Failed/Closed; отменяется при
  /// восстановлении (Connected) и перезапускается на Disconnected —
  /// ICE restart должен успеть отработать.
  void _schedulePcGraceTermination() {
    if (!mounted || _isCleanedUp) return;
    _pcGraceTimer?.cancel();
    _pcGraceTimer = Timer(_pcGraceTimeout, () {
      if (!mounted || _isCleanedUp) return;
      _onSessionTerminated('pc_failed');
    });
  }

  /// Ш4: единое завершение — полный teardown, корректный выход со страницы
  /// (закрывая открытые диалоги/чаты) и уведомление. Повторный вызов
  /// безопасен — guard по _isCleanedUp.
  void _onSessionTerminated(String reasonKey) {
    if (!mounted || _isCleanedUp) return;
    final messenger = ScaffoldMessenger.of(context);
    final strings = context.stringsRead;
    _cancelStageTimers();
    _pcGraceTimer?.cancel();
    _pcGraceTimer = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _setStatus(reasonKey);
    _isControlEnabled = false;
    _cleanupResources();
    _restoreWindowSize(delay: const Duration(milliseconds: 300));
    // Закрыть маршруты поверх консоли (диалоги/чат/модалки), затем саму
    // консоль: pop верхнего route оставлял бы открытый чат (Д6).
    final consoleRoute = ModalRoute.of(context);
    if (consoleRoute != null && !consoleRoute.isCurrent) {
      Navigator.of(context).popUntil((r) => r == consoleRoute);
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFEF4444),
        content: Text(_terminationNotice(strings, reasonKey)),
      ),
    );
  }

  String _terminationNotice(AppStrings strings, String reasonKey) {
    switch (reasonKey) {
      case 'session_ended':
        return strings.sessionEndedByUser;
      case 'pc_failed':
        return strings.consolePcConnectionLost;
      default:
        return strings.sessionEndedByServer;
    }
  }

  final List<SupportChatMessage> _chatMessages = [];
  late final ValueNotifier<List<SupportChatMessage>> _chatMessagesNotifier;
  int _unreadChatCount = 0;

  Size? _previousWindowSize;

  Future<void> _expandWindowForOperator() async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        _previousWindowSize = await windowManager.getSize();
        await windowManager.setMinimumSize(const Size(800, 600));
        await windowManager.setSize(const Size(1280, 820));
        await windowManager.setResizable(true);
      } catch (_) {}
    }
  }

  Future<void> _restoreWindowSize({Duration? delay}) async {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        if (delay != null) {
          await Future.delayed(delay);
        }
        final targetSize = _previousWindowSize ?? const Size(440, 720);
        await windowManager.setMinimumSize(const Size(380, 600));
        await windowManager.setSize(targetSize);
      } catch (_) {}
    }
  }

  Future<void> _loadChatHistory() async {
    if (widget.ownerMode || widget.sessionData['owner'] == true) return;
    final auth = context.read<AuthState>();
    if (auth.api == null || widget.sessionId.isEmpty) return;
    try {
      final list = await auth.api!.getSupportMessages(widget.sessionId);
      bool changed = false;
      for (final item in list) {
        final chatMsg = SupportChatMessage.fromJson(item);
        final idx = _chatMessages.indexWhere((m) =>
            m.id == chatMsg.id ||
            (chatMsg.clientId.isNotEmpty && m.clientId == chatMsg.clientId) ||
            (m.sender == chatMsg.sender &&
                m.text == chatMsg.text &&
                m.timestamp.difference(chatMsg.timestamp).abs().inSeconds < 5));
        if (idx == -1) {
          _chatMessages.add(chatMsg);
          changed = true;
        } else if (_chatMessages[idx].id != chatMsg.id) {
          _chatMessages[idx] = chatMsg;
          changed = true;
        }
      }
      if (changed) {
        _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _chatMessagesNotifier.value = List.of(_chatMessages);
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('support_operator: _loadChatHistory error: $e');
    }
  }

  AuthState? _auth;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<AuthState>();
  }

  @override
  void initState() {
    super.initState();
    _chatMessagesNotifier =
        ValueNotifier<List<SupportChatMessage>>(_chatMessages);
    _expandWindowForOperator();
    _isChatOnly = widget.isChatOnly;
    _currentNumberMatch = widget.numberMatch;
    final accessMode = widget.sessionData['access_mode']?.toString();
    _isControlEnabled = accessMode != 'view_only';
    _loadChatHistory();
    if (_isChatOnly) {
      _statusKey = 'chat';
      _connectWebSocket();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showOperatorChatModal();
      });
    } else {
      _initRendererAndWebRTC();
    }
  }

  Future<void> _initRendererAndWebRTC() async {
    _startLeaseRenewal();
    // Этап 2.4: в owner-режиме consent не нужен — цель стартует шаринг
    // сама по support_prompt(owner:true); number-match отсутствует.
    // Ш3: ожидание ответа хозяина ПК покрывает единый offer-таймер,
    // запускаемый при WS-open+request_offer.
    if (widget.ownerMode) {
      _setStatus('owner_waiting');
    } else {
      _setStatus('waiting_consent', _currentNumberMatch ?? '2FA');
    }
    await _remoteRenderer.initialize();
    // Ш3 (Д5): граница «изображение появилось» — нативный колбэк первого
    // кадра; трек ≠ кадр, чёрный экран больше не считается готовностью.
    _remoteRenderer.onFirstFrameRendered = () {
      _markFrameReady();
    };
    _connectWebSocket();
    await _setupPeerConnection();
  }

  void _connectWebSocket() {
    if (_isCleanedUp || _wsChannel != null) return;
    final auth = context.read<AuthState>();
    var serverUrl = auth.serverUrl ?? '';
    // M-5: принудительный wss. ws:// (в т.ч. из http:// адреса сервера)
    // запрещён: Bearer-токен не должен уходить в открытом канале.
    if (serverUrl.startsWith('https://')) {
      serverUrl = 'wss://${serverUrl.substring(8)}';
    } else {
      _setStatus(
          'conn_error',
          auth.isRu
              ? 'Требуется https/wss адрес сервера (открытый ws:// запрещён)'
              : 'https/wss server URL required (plain ws:// is forbidden)');
      return;
    }
    if (serverUrl.endsWith('/')) {
      serverUrl = serverUrl.substring(0, serverUrl.length - 1);
    }
    // M-5: токен — в Authorization-заголовке, а не в ?token= (токен в URL
    // попадает в логи прокси/сервера).
    final wsUrl = '$serverUrl/api/v1/support/ws/${widget.sessionId}';

    try {
      final uri = Uri.parse(wsUrl);
      if (uri.scheme != 'wss') {
        _setStatus('conn_error', 'ws:// forbidden: $wsUrl');
        return;
      }
      _wsChannel = IOWebSocketChannel.connect(
        uri,
        headers: {
          if (auth.token != null && auth.token!.isNotEmpty)
            'Authorization': 'Bearer ${auth.token}',
        },
        connectTimeout: const Duration(seconds: 12),
        pingInterval: const Duration(seconds: 20),
      );

      _wsChannel!.ready.then((_) {
        _wsBackoff.reset();
        if (mounted) {
          setState(() {
            // Ш3 (Д5): WS-открытие — только сигнальный канал, НЕ «подключено»
            _signalReady = true;
            if (_statusKey == 'disconnected') {
              _statusKey =
                  consoleConnectionStatusKey(_isConnected, _frameReady);
              _statusArg = null;
            }
          });
        }
        _sendWsSignal({'type': 'request_offer'});
        _sendWsSignal({'type': 'screen_list'});
        // Ш3: перезапуск стадийных таймеров (повторный request_offer ушёл).
        _startOfferStageTimer();
        if (!_frameReady && _remoteRenderer.srcObject != null) {
          _startFirstFrameStageTimer();
        }
      }).catchError((Object e) {
        debugPrint('support_operator: WS handshake не удался: $e');
        final str = e.toString();
        if (str.contains('409') || str.contains('invalid_transition')) {
          // Ш4: сервер закрыл сессию — единое завершение с выходом
          _onSessionTerminated('ended_by_server');
        } else {
          _scheduleWsReconnect();
        }
      });

      _wsChannel!.stream.listen(
        (message) {
          _handleWsMessage(message);
        },
        onDone: () {
          _wsChannel = null;
          if (!mounted || _isCleanedUp) return;
          if (_statusKey == 'ended_by_server') return;
          // Ш3 (§4.3): при реконнекте WS стадийная готовность сбрасывается
          _cancelStageTimers();
          setState(() {
            _signalReady = false;
            _resetStageReadiness();
            _currentNumberMatch = null;
            _statusKey = 'disconnected';
            _statusArg = 'ws';
          });
          _scheduleWsReconnect();
        },
        onError: (err) {
          _wsChannel = null;
          if (!mounted || _isCleanedUp) return;
          final errStr = err.toString();
          if (errStr.contains('409') || errStr.contains('invalid_transition')) {
            // Ш4: сервер закрыл сессию — единое завершение с выходом
            _onSessionTerminated('ended_by_server');
            return;
          }
          _cancelStageTimers();
          setState(() {
            _signalReady = false;
            _resetStageReadiness();
          });
          _setStatus('conn_error', errStr);
          _scheduleWsReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (mounted) {
        final errStr = e.toString();
        if (errStr.contains('409') || errStr.contains('invalid_transition')) {
          // Ш4: сервер закрыл сессию — единое завершение с выходом
          _onSessionTerminated('ended_by_server');
        } else {
          _setStatus('conn_error', errStr);
        }
      }
    }
  }

  /// M-5: реконнект операторского WS с экспоненциальным backoff
  /// (как в ws_service: 1с -> 2с -> ... -> 30с c джиттером).
  void _scheduleWsReconnect() {
    if (!mounted || _isCleanedUp) return;
    _wsReconnectTimer?.cancel();
    final delay = _wsBackoff.nextDelay();
    debugPrint(
        'support_operator: WS реконнект через ${delay.inMilliseconds}мс');
    _wsReconnectTimer = Timer(delay, () {
      if (mounted && !_isCleanedUp) {
        _connectWebSocket();
      }
    });
  }

  Future<void> _requestScreenAccess() async {
    _setStatus('requesting_access');
    final auth = context.read<AuthState>();
    try {
      final res = await auth.connectToSupportSession(widget.sessionId);
      if (mounted) {
        setState(() {
          _isChatOnly = false;
          _currentNumberMatch = res['number_match']?.toString();
        });
        await _initRendererAndWebRTC();
      }
    } catch (e) {
      if (mounted) {
        _setStatus('req_error', e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFEF4444),
            content: Text('${context.stringsRead.reqScreenErrorPrefix} $e'),
          ),
        );
      }
    }
  }

  Future<void> _setupPeerConnection() async {
    final auth = context.read<AuthState>();
    final config = <String, dynamic>{
      // ICE-серверы из /api/v1/app/config (B-1); emergency-фолбэк на
      // публичные STUN — только если конфиг не отдал ice_servers.
      'iceServers': auth.iceServers.isNotEmpty
          ? auth.iceServers
          : SupportService.emergencyIceServers,
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(config);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        _sendWsSignal({
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      }
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('support_operator: connection state: $state');
      if (mounted) {
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          // Ш4: восстановление отменяет grace-завершение
          _pcGraceTimer?.cancel();
          _pcGraceTimer = null;
          setState(() {
            _isConnected = true;
            _currentNumberMatch = null;
            _statusKey = consoleConnectionStatusKey(_isConnected, _frameReady);
            _statusArg = null;
          });
        } else if (pcStateRequiresGraceTermination(state)) {
          // Ш4 (Д6): Failed/Closed — завершение после grace-окна
          setState(() {
            _isConnected = false;
            _currentNumberMatch = null;
            _statusKey = 'disconnected';
            _statusArg = state.name;
          });
          _schedulePcGraceTermination();
        } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Ш4: Disconnected — временный статус, сессию НЕ завершаем;
          // идущий grace-таймер перезапускаем, чтобы ICE restart успел.
          setState(() {
            _isConnected = false;
            _currentNumberMatch = null;
            _statusKey = 'disconnected';
            _statusArg = state.name;
          });
          if (_pcGraceTimer != null) _schedulePcGraceTermination();
        }
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('support_operator: ice connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _sendWsSignal({'type': 'request_offer', 'iceRestart': true});
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) async {
      debugPrint(
          'support_operator: remote track received: ${event.track.kind}');
      if (mounted) {
        // Ш3/A-06: трек пришёл — offer/track стадии пройдены (Д5: трек ≠ кадр)
        _cancelOfferStageTimer();
        _cancelTrackStageTimer();
        MediaStream? stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams[0];
        } else {
          try {
            stream = await createLocalMediaStream('remote_stream');
            await stream.addTrack(event.track);
          } catch (e) {
            debugPrint('support_operator: fallback media stream error: $e');
          }
        }
        if (mounted && stream != null) {
          setState(() {
            _remoteRenderer.srcObject = stream;
            _isConnected = true;
            _currentNumberMatch = null;
            // Ш3: «Трансляция активна» — только после первого кадра
            _statusKey = consoleConnectionStatusKey(_isConnected, _frameReady);
            _statusArg = null;
          });
          if (!_frameReady) _startFirstFrameStageTimer();
          _sendDataMessage({'type': 'screen_list'});
        }
      }
    };

    _peerConnection!.onDataChannel = (channel) {
      debugPrint(
          'support_operator: received remote data channel: ${channel.label}');
      _setupDataChannel(channel);
    };
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (mounted) {
          setState(() {
            _currentNumberMatch = null;
            // Ш3 (§6 плана): открытый канал НЕ включает управление сам по
            // себе — view_only остаётся без управления; _controlReady
            // вычисляется из состояния канала и _isControlEnabled.
          });
        }
        _sendDataMessage({'type': 'screen_list'});
      }
    };

    channel.onMessage = (RTCDataChannelMessage msg) {
      if (msg.isBinary) return;
      try {
        final data = jsonDecode(msg.text) as Map<String, dynamic>;
        _handleDataChannelMessage(data);
      } catch (_) {}
    };
  }

  void _handleDataChannelMessage(Map<String, dynamic> data) {
    if (isSessionTerminatedMessage(data)) {
      _onSessionTerminated('session_ended');
      return;
    }
    final type = data['type']?.toString();
    if (type == 'screen_list') {
      final list = data['screens'] as List<dynamic>? ?? [];
      final sel = data['selected_id']?.toString();
      if (mounted) {
        setState(() {
          _screens = list.cast<Map<String, dynamic>>();
          _selectedScreenId = sel ??
              (_screens.isNotEmpty ? _screens.first['id']?.toString() : null);
        });
      }
    } else if (type == 'clipboard_error') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.stringsRead.isRu
              ? 'Буфер обмена недоступен на защищённом экране Windows'
              : 'Clipboard unavailable on the Windows secure desktop'),
        ));
      }
    } else if (type == 'block_input_ack') {
      final ack = data['blocked'] == true;
      if (mounted) {
        setState(() {
          _isInputBlocked = ack;
        });
      }
    } else if (type == 'screen_lock_state') {
      // Игнорируем: консоль предоставляет прямой доступ к экрану
    } else if (type == 'telemetry') {
      if (mounted) {
        setState(() {
          _cpuPercent = (data['cpu_percent'] as num?)?.toInt() ?? _cpuPercent;
          _cpuWarning = data['cpu_warning'] == true || _cpuPercent >= 90;
          _diskPercent =
              (data['disk_percent'] as num?)?.toInt() ?? _diskPercent;
          _diskFreeGb = (data['disk_free_gb'] as num?)?.toInt() ?? _diskFreeGb;
          _diskWarning = data['disk_warning'] == true;
        });
      }
    } else if (type == 'clipboard_data') {
      final text = data['text']?.toString() ?? '';
      _showRemoteClipboardDialog(text);
    } else if (type == 'chat_message') {
      try {
        final msg = SupportChatMessage.fromJson(data);
        final isDuplicate = _chatMessages.any((m) =>
            m.id == msg.id ||
            (msg.clientId.isNotEmpty && m.clientId == msg.clientId) ||
            (m.sender == msg.sender &&
                m.text == msg.text &&
                m.timestamp.difference(msg.timestamp).abs().inSeconds < 5));
        if (!isDuplicate) {
          _chatMessages.add(msg);
          _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          _chatMessagesNotifier.value = List.of(_chatMessages);
          if (mounted) {
            setState(() {
              if (msg.sender != 'operator') {
                _unreadChatCount++;
              }
            });
            if (msg.sender != 'operator' && !widget.ownerMode) {
              context.read<AuthState>().alert.triggerChatNotification(
                    sender: msg.senderName,
                    message: msg.text,
                  );
            }
          }
        }
      } catch (_) {}
    }
  }

  void _handleWsMessage(dynamic message) async {
    try {
      final text =
          message is String ? message : utf8.decode(message as List<int>);
      final data = jsonDecode(text) as Map<String, dynamic>;

      final payload = (data['data'] is Map<String, dynamic>)
          ? data['data'] as Map<String, dynamic>
          : data;

      if (payload.containsKey('sdp')) {
        final sdpMap = payload['sdp'] as Map<String, dynamic>;
        final type = sdpMap['type']?.toString();
        final desc = RTCSessionDescription(sdpMap['sdp']?.toString(), type);

        if (_peerConnection != null) {
          await _peerConnection!.setRemoteDescription(desc);
          while (_pendingCandidates.isNotEmpty) {
            final c = _pendingCandidates.removeAt(0);
            try {
              await _peerConnection!.addCandidate(c);
            } catch (_) {}
          }

          if (type == 'offer') {
            // Ш3: offer пришёл — стадия пройдена, таймаут снимается
            _cancelOfferStageTimer();
            // A-06 (аудит 2026-10-10): запускаем таймаут ожидания трека
            _startTrackStageTimer();
            final answer = await _peerConnection!.createAnswer({
              'offerToReceiveVideo': 1,
              'offerToReceiveAudio': 0,
            });
            await _peerConnection!.setLocalDescription(answer);
            _sendWsSignal({'sdp': answer.toMap()});
          }
        }
      } else if (payload.containsKey('candidate')) {
        final cMap = payload['candidate'] as Map<String, dynamic>;
        final candidate = RTCIceCandidate(
          cMap['candidate']?.toString(),
          cMap['sdpMid']?.toString(),
          cMap['sdpMLineIndex'] as int?,
        );
        final remoteDesc = await _peerConnection?.getRemoteDescription();
        if (remoteDesc == null ||
            remoteDesc.type == null ||
            remoteDesc.type!.isEmpty) {
          _pendingCandidates.add(candidate);
        } else {
          await _peerConnection?.addCandidate(candidate);
        }
      } else if (isSessionTerminatedMessage(data)) {
        // Ш4 (Д6): завершение матчится и в верхнем data['type'], и в
        // нормализованном payload['type'] (как SDP)
        _onSessionTerminated('session_ended');
      } else {
        final innerType = payload['type'] ?? data['type'];
        if (innerType != null &&
            innerType != 'offer' &&
            innerType != 'answer' &&
            innerType != 'candidate') {
          _handleDataChannelMessage(payload['type'] != null ? payload : data);
        }
      }
    } catch (e) {
      debugPrint('support_operator: ошибка обработки WS: $e');
    }
  }

  void _sendChatMessage(String text) {
    if (text.trim().isEmpty) return;
    final auth = context.read<AuthState>();
    final operatorName = auth.displayName.isNotEmpty
        ? auth.displayName
        : context.stringsRead.defaultEngineerName;
    final ms = DateTime.now().millisecondsSinceEpoch;
    final msg = SupportChatMessage(
      id: 'msg_$ms',
      sender: 'operator',
      senderName: operatorName,
      text: text.trim(),
      timestamp: DateTime.now(),
      // Один client_id в DC/WS/REST-копиях: сервер (0074) пишет одну
      // строку, эхо глушится приёмником по ключу.
      clientId: 'operator-msg_$ms',
    );

    if (!_chatMessages.any((m) => m.id == msg.id)) {
      _chatMessages.add(msg);
      _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _chatMessagesNotifier.value = List.of(_chatMessages);
      if (mounted) setState(() {});
    }

    _sendDataMessage(msg.toJson());
    _sendWsSignal(msg.toJson());

    auth.api
        ?.sendSupportChatMessage(
      sessionId: widget.sessionId,
      text: msg.text,
      senderName: operatorName,
      clientId: msg.clientId,
    )
        .catchError((e) {
      debugPrint('support_operator: ошибка отправки сообщения через API: $e');
    });
  }

  void _showOperatorChatModal() {
    setState(() {
      _unreadChatCount = 0;
    });
    _loadChatHistory();

    final textController = TextEditingController();
    final scrollController = ScrollController();

    Timer? historyPoller;
    historyPoller = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadChatHistory();
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final strings = ctx.strings;
        return ValueListenableBuilder<List<SupportChatMessage>>(
          valueListenable: _chatMessagesNotifier,
          builder: (context, messages, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (scrollController.hasClients) {
                scrollController.animateTo(
                  scrollController.position.maxScrollExtent,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              }
            });

            final clientDisplayName = widget.sessionData['employee_name'] ??
                widget.sessionData['username'] ??
                strings.defaultClientName;
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.chat,
                            color: Color(0xFF38BDF8), size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            strings.chatWithUser(clientDisplayName),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close,
                              color: Color(0xFF94A3B8), size: 20),
                          onPressed: () => Navigator.of(ctx).pop(),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Color(0xFF1E293B), height: 1),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        _buildOperatorChatChip(strings.isRu
                            ? '👋 Здравствуйте! Подключился к экрану.'
                            : '👋 Hello! Connected to screen.'),
                        _buildOperatorChatChip(strings.isRu
                            ? '📁 Пожалуйста, сохраните открытые файлы.'
                            : '📁 Please save your open files.'),
                        _buildOperatorChatChip(strings.isRu
                            ? '🔄 Сейчас потребуется перезагрузить систему.'
                            : '🔄 System reboot will be needed now.'),
                        _buildOperatorChatChip(strings.isRu
                            ? '✅ Проблема устранена, проверяйте!'
                            : '✅ Issue is resolved, please check!'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: messages.isEmpty
                        ? Center(
                            child: Text(
                              strings.chatEmptyPrompt,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFF64748B), fontSize: 13),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            itemCount: messages.length,
                            itemBuilder: (c, i) {
                              final msg = messages[i];
                              final isOperator = msg.sender == 'operator';
                              final timeStr =
                                  DateFormat('HH:mm').format(msg.timestamp);

                              return Align(
                                alignment: isOperator
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.of(context).size.width *
                                            0.75,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isOperator
                                        ? const Color(0xFF2563EB)
                                        : const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isOperator
                                          ? const Color(0xFF3B82F6)
                                          : const Color(0xFF334155),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: isOperator
                                        ? CrossAxisAlignment.end
                                        : CrossAxisAlignment.start,
                                    children: [
                                      if (!isOperator)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 2),
                                          child: Text(
                                            msg.senderName,
                                            style: const TextStyle(
                                                color: Color(0xFF38BDF8),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      Text(msg.text,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13)),
                                      const SizedBox(height: 2),
                                      Text(
                                        timeStr,
                                        style: TextStyle(
                                            color: isOperator
                                                ? Colors.white70
                                                : const Color(0xFF64748B),
                                            fontSize: 9),
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
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: strings.chatInputHint,
                              hintStyle: const TextStyle(
                                  color: Color(0xFF64748B), fontSize: 13),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onSubmitted: (val) {
                              if (val.trim().isNotEmpty) {
                                _sendChatMessage(val.trim());
                                textController.clear();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon:
                              const Icon(Icons.send, color: Color(0xFF38BDF8)),
                          onPressed: () {
                            final val = textController.text.trim();
                            if (val.isNotEmpty) {
                              _sendChatMessage(val);
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

  Widget _buildOperatorChatChip(String text) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          _sendChatMessage(text);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Text(text,
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
        ),
      ),
    );
  }

  void _sendWsSignal(Map<String, dynamic> signal) {
    try {
      _wsChannel?.sink.add(jsonEncode(signal));
    } catch (_) {}
  }

  void _sendDataMessage(Map<String, dynamic> msg) {
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode(msg)));
        return;
      } catch (_) {}
    }
    // A-17/A-18: вводные команды (мышь, клавиатура, hotkey, block_input)
    // отправляются ТОЛЬКО через DataChannel (DTLS). Через WS fallback
    // разрешены только информационные команды (screen_list, switch_screen).
    final type = msg['type']?.toString();
    if (type == 'screen_list' || type == 'switch_screen') {
      _sendWsSignal({'type': 'input_control', 'data': msg});
    }
  }

  void _sendPointerEvent(String action, PointerEvent event, int button) {
    if (!_controlReady) return;
    final renderBox =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final localPos = renderBox.globalToLocal(event.position);
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return;

    double videoW = _remoteRenderer.videoWidth.toDouble();
    double videoH = _remoteRenderer.videoHeight.toDouble();
    if (videoW <= 0) videoW = 1920;
    if (videoH <= 0) videoH = 1080;

    final containerW = size.width;
    final containerH = size.height;
    final videoAspect = videoW / videoH;
    final containerAspect = containerW / containerH;

    double renderW = containerW;
    double renderH = containerH;
    double offsetX = 0.0;
    double offsetY = 0.0;

    {
      if (containerAspect > videoAspect) {
        // Черные полосы по бокам (left / right)
        renderW = containerH * videoAspect;
        offsetX = (containerW - renderW) / 2.0;
      } else {
        // Черные полосы сверху / снизу (top / bottom)
        renderH = containerW / videoAspect;
        offsetY = (containerH - renderH) / 2.0;
      }
    }

    final relX = (localPos.dx - offsetX) / renderW;
    final relY = (localPos.dy - offsetY) / renderH;

    final isOutside = relX < 0.0 || relX > 1.0 || relY < 0.0 || relY > 1.0;

    // Щелчки по чёрным полосам вокруг изображения игнорировать (не начинать нажатие вне экрана).
    // Но отпускание (mouse_up) ОБЯЗАНО отправляться с clamp-координатами, чтобы не допустить залипания кнопки.
    if (isOutside && action != 'mouse_up') {
      // Если ни одна кнопка не зажата, игнорируем обычное перемещение вне кадра
      if (_pointerDownButtons.isEmpty) {
        return;
      }
    }

    final normX = relX.clamp(0.0, 1.0);
    final normY = relY.clamp(0.0, 1.0);

    if (action == 'move') {
      _sendDataMessage({'type': 'mouse_move', 'x': normX, 'y': normY});
    } else {
      _sendDataMessage({
        'type': action,
        'button': button,
        'x': normX,
        'y': normY,
      });
    }
  }

  void _showTextInputDialog() {
    final controller = TextEditingController();
    final strings = context.stringsRead;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            const Icon(Icons.keyboard_alt_outlined,
                color: Color(0xFF38BDF8), size: 20),
            const SizedBox(width: 8),
            Text(strings.textInputTitle,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.textInputPrompt,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: strings.textInputPlaceholder,
                  hintStyle: const TextStyle(color: Color(0xFF64748B)),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onSubmitted: (val) {
                  Navigator.of(ctx).pop();
                  _sendTextToRemote(val);
                },
              ),
              const SizedBox(height: 14),
              Text(strings.quickKeys,
                  style:
                      const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildQuickKeyButton('Enter', () => _sendSpecialKey('Enter')),
                  _buildQuickKeyButton('Tab', () => _sendSpecialKey('Tab')),
                  _buildQuickKeyButton('Esc', () => _sendSpecialKey('Escape')),
                  _buildQuickKeyButton(
                      'Backspace', () => _sendSpecialKey('Backspace')),
                  _buildQuickKeyButton('Win+R', () => _sendHotkey('win_r')),
                  _buildQuickKeyButton(
                      strings.isRu ? 'Диспетчер задач' : 'Task Manager',
                      () => _sendHotkey('task_mgr')),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.cancel),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final text = controller.text;
              Navigator.of(ctx).pop();
              _sendTextToRemote(text);
            },
            icon: const Icon(Icons.send, size: 14),
            label: Text(strings.send),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7)),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickKeyButton(String label, VoidCallback onPressed) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF475569)),
        ),
        child: Text(
          label,
          style: const TextStyle(
              color: Color(0xFF38BDF8),
              fontSize: 11,
              fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _sendSpecialKey(String key) {
    _sendDataMessage({'type': 'key_down', 'key': key});
    _sendDataMessage({'type': 'key_up', 'key': key});
    final isRu = context.stringsRead.isRu;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isRu ? 'Отправлена клавиша $key' : 'Key sent: $key'),
        duration: const Duration(milliseconds: 600),
      ),
    );
  }

  void _sendTextToRemote(String text) {
    if (text.isEmpty) return;
    if (!_controlReady) return;
    if (text.length > 4096) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Maximum: 4096 UTF-16 characters')));
      return;
    }
    _sendDataMessage({'type': 'text_input', 'text': text});
    final isRu = context.stringsRead.isRu;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isRu
            ? 'Текст отправлен на удалённый ПК'
            : 'Text sent to remote PC'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _toggleBlockInput() {
    if (!_controlReady) return;
    setState(() {
      _isInputBlocked = !_isInputBlocked;
    });
    _sendDataMessage({'type': 'block_input', 'blocked': _isInputBlocked});
  }

  void _sendHotkey(String action) {
    if (!_controlReady) return;
    _sendDataMessage({'type': 'hotkey', 'action': action});
    final isRu = context.stringsRead.isRu;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            isRu ? 'Отправлена комбинация: $action' : 'Shortcut sent: $action'),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  void _switchScreen(String screenId) {
    setState(() => _selectedScreenId = screenId);
    _sendDataMessage({'type': 'switch_screen', 'screen_id': screenId});
  }

  void _sendLocalClipboardToRemote() async {
    final strings = context.stringsRead;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.localClipboardEmpty)),
        );
      }
      return;
    }
    _sendDataMessage({'type': 'clipboard_set', 'text': text});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.clipboardSentNotice(text.length))),
      );
    }
  }

  void _requestRemoteClipboard() {
    _sendDataMessage({'type': 'clipboard_get'});
  }

  void _showRemoteClipboardDialog(String text) {
    final strings = context.stringsRead;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(strings.clientClipboardTitle,
            style: const TextStyle(color: Colors.white)),
        content: SelectableText(
          text.isNotEmpty ? text : strings.clipboardEmpty,
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          if (text.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(strings.copiedToLocalClipboard)),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: Text(strings.copyToMyself),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(strings.close),
          ),
        ],
      ),
    );
  }

  bool _isCleanedUp = false;

  void _cleanupResources() {
    if (_isCleanedUp) return;
    _isCleanedUp = true;
    // Ш3/Ш4: единая отмена стадийных и grace-таймеров
    _cancelStageTimers();
    _pcGraceTimer?.cancel();
    _pcGraceTimer = null;
    _leaseTimer?.cancel();
    _leaseTimer = null;

    // Сначала сбрасываем зажатые кнопки мыши, пока DataChannel ещё активен
    _releaseAllPressedInputs();

    // Ш3/Ш4 (Д6): полный сброс признаков готовности
    _signalReady = false;
    _isConnected = false;
    _frameReady = false;
    _remoteRenderer.onFirstFrameRendered = null;

    try {
      _remoteRenderer.srcObject = null;
    } catch (_) {}

    final dc = _dataChannel;
    _dataChannel = null;
    if (dc != null) {
      try {
        dc.onMessage = null;
        dc.onDataChannelState = null;
      } catch (_) {}
    }

    final pc = _peerConnection;
    _peerConnection = null;
    if (pc != null) {
      try {
        pc.onConnectionState = null;
        pc.onIceCandidate = null;
        pc.onTrack = null;
        pc.onDataChannel = null;
      } catch (_) {}
    }

    try {
      _wsChannel?.sink.close();
      _wsChannel = null;
    } catch (_) {}
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;

    // Освобождение нативных текстур рендерера и WebRTC-соединения.
    // На macOS: unregister текстуры (renderer.dispose) во время pop-анимации/resize
    // ловит raster-поток Flutter на живом кадре -> дедлок (черный экран).
    // Поэтому srcObject=null синхронно (стоп кадров), а нативный dispose рендерера
    // на macOS откладываем на 3 секунды, когда raster-поток уже гарантированно спокоен.
    void disposeNative() {
      try {
        _remoteRenderer.dispose();
      } catch (_) {}
      try {
        pc?.dispose();
      } catch (_) {}
    }

    if (!kIsWeb && Platform.isMacOS) {
      Future.delayed(const Duration(seconds: 3), disposeNative);
    } else {
      Future.delayed(const Duration(milliseconds: 350), disposeNative);
    }
  }

  void _endSession() async {
    final strings = context.stringsRead;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(strings.confirmEndSessionTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          strings.confirmEndSessionDesc,
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(strings.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444)),
            child: Text(strings.endSession),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final auth = context.read<AuthState>();
      final sessId = widget.sessionId;
      final isOwner = widget.ownerMode || widget.sessionData['owner'] == true;
      _releaseAllPressedInputs();
      try {
        // Оператор SOS бьёт в operator-маршрут (app-токен + роль инженера):
        // прежний /app/.../end для него всегда 403 — сессия не закрывалась.
        if (isOwner) {
          await auth.api?.endSupportSession(sessionId: sessId).timeout(
                const Duration(seconds: 2),
              );
        } else {
          await auth.api
              ?.endSupportSessionAsOperator(sessionId: sessId)
              .timeout(
                const Duration(seconds: 2),
              );
        }
      } catch (e) {
        debugPrint('support_operator: endSupportSession error/timeout: $e');
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    _releaseAllPressedInputs();
    _chatMessagesNotifier.dispose();
    _keyboardFocus.dispose();
    _videoTransform.dispose();
    _cleanupResources();
    _restoreWindowSize(delay: const Duration(milliseconds: 300));
    final auth = _auth;
    final sessId = widget.sessionId;
    if (auth != null && auth.api != null && sessId.isNotEmpty) {
      final isOwner = widget.ownerMode || widget.sessionData['owner'] == true;
      try {
        // dispose() у оператора — тоже корректный конец сессии (окно
        // закрыли = сеанс завершён), иначе она висит active в очереди.
        if (isOwner) {
          auth.api!
              .endSupportSession(sessionId: sessId)
              .catchError((_) => null);
        } else {
          auth.api!
              .endSupportSessionAsOperator(sessionId: sessId)
              .catchError((_) => null);
        }
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final isOwner = widget.ownerMode || widget.sessionData['owner'] == true;
    final String clientName;
    final String pcName;
    final bool is1C;
    if (isOwner) {
      // Этап 2.4: заголовок окна — «Мой ПК», а не «Помощь»: на другой
      // стороне экран самого владельца, категория SOS не показывается.
      clientName = widget.sessionData['name']?.toString() ??
          widget.sessionData['device_name']?.toString() ??
          strings.ownerScreenTitle;
      pcName = widget.sessionData['endpoint']?.toString() ??
          widget.sessionData['device_name']?.toString() ??
          strings.ownerScreenTitle;
      is1C = false;
    } else {
      clientName = (widget.sessionData['display_name'] ??
              widget.sessionData['employee_name'] ??
              widget.sessionData['username'] ??
              strings.clientFallback)
          .toString();
      pcName = widget.sessionData['device_name'] ??
          widget.sessionData['pc_name'] ??
          'PC';
      is1C = widget.sessionData['category'] == '1c';
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: Column(
        children: [
          // Верхняя панель управления (Toolbar)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1E293B),
              border: Border(bottom: BorderSide(color: Color(0xFF334155))),
            ),
            child: SafeArea(
              bottom: false,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  // Информация о клиенте и статус
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 20),
                        tooltip: strings.backTooltip,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      if (isOwner)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.home_work_outlined,
                                  size: 12, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(
                                strings.ownerScreenBadge,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11),
                              ),
                            ],
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: is1C
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF0284C7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            is1C ? (strings.isRu ? '1С' : '1C') : 'IT',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$clientName ($pcName)',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13),
                          ),
                          Text(
                            _getStatusText(strings),
                            style: TextStyle(
                              // Ш3: «зелёный» статус — только P2P И кадр
                              color: (_isConnected && _frameReady)
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFFF59E0B),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Выбор монитора
                  if (_screens.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButton<String>(
                          value: _screens.any((s) =>
                                  s['id']?.toString() == _selectedScreenId)
                              ? _selectedScreenId
                              : (_screens.isNotEmpty
                                  ? _screens.first['id']?.toString()
                                  : null),
                          dropdownColor: const Color(0xFF1E293B),
                          underline: const SizedBox(),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          items: _screens.map((s) {
                            return DropdownMenuItem<String>(
                              value: s['id']?.toString(),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.desktop_windows,
                                      size: 14, color: Color(0xFF38BDF8)),
                                  const SizedBox(width: 4),
                                  Text(s['name']?.toString() ?? strings.monitor,
                                      overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) _switchScreen(val);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh,
                              size: 16, color: Color(0xFF94A3B8)),
                          tooltip: strings.refreshScreensTooltip,
                          onPressed: () {
                            _sendDataMessage({'type': 'screen_list'});
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                duration: const Duration(seconds: 2),
                                content: Text(strings.refreshScreensSent),
                              ),
                            );
                          },
                        ),
                      ],
                    ),

                  // Масштабирование
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _zoomMode == OperatorZoomMode.fit
                              ? Icons.fit_screen
                              : Icons.aspect_ratio,
                          color: const Color(0xFF38BDF8),
                          size: 18,
                        ),
                        tooltip: _zoomMode == OperatorZoomMode.fit
                            ? strings.zoomFitTooltip
                            : strings.zoom1to1Tooltip,
                        onPressed: () {
                          setState(() {
                            if (_zoomMode == OperatorZoomMode.fit) {
                              _zoomMode = OperatorZoomMode.original;
                              final box = _videoKey.currentContext
                                  ?.findRenderObject() as RenderBox?;
                              _applyVideoZoom(box == null
                                  ? 1
                                  : math.max(
                                      _remoteRenderer.videoWidth /
                                          box.size.width,
                                      _remoteRenderer.videoHeight /
                                          box.size.height));
                            } else {
                              _zoomMode = OperatorZoomMode.fit;
                              _applyVideoZoom(1);
                            }
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.zoom_in,
                            color: Colors.white, size: 18),
                        tooltip: strings.zoomInTooltip,
                        onPressed: () {
                          setState(() {
                            _zoomMode = OperatorZoomMode.zoomIn;
                            _applyVideoZoom(_zoomScale + 0.25);
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.zoom_out,
                            color: Colors.white, size: 18),
                        tooltip: strings.zoomOutTooltip,
                        onPressed: () {
                          setState(() {
                            _applyVideoZoom(_zoomScale - 0.25);
                            if (_zoomScale <= 1.0) {
                              _zoomMode = OperatorZoomMode.fit;
                            }
                          });
                        },
                      ),
                    ],
                  ),

                  // Блокировка ввода
                  IconButton(
                    icon: Icon(
                      _isInputBlocked ? Icons.lock : Icons.lock_open,
                      color: _isInputBlocked
                          ? const Color(0xFFEF4444)
                          : const Color(0xFF94A3B8),
                      size: 18,
                    ),
                    tooltip: _isInputBlocked
                        ? strings.unblockClientInputTooltip
                        : strings.blockClientInputTooltip,
                    onPressed: _controlReady ? _toggleBlockInput : null,
                  ),

                  // Горячие клавиши
                  PopupMenuButton<String>(
                    enabled: _controlReady,
                    icon: const Icon(Icons.keyboard,
                        color: Color(0xFF38BDF8), size: 20),
                    tooltip: strings.hotkeysTooltip,
                    color: const Color(0xFF1E293B),
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                          value: 'win_space',
                          child: Text(
                              strings.isRu
                                  ? 'Переключить язык (Win+Space)'
                                  : 'Switch language (Win+Space)',
                              style: const TextStyle(color: Colors.white))),
                      const PopupMenuItem(
                          value: 'alt_shift',
                          child: Text('Alt+Shift',
                              style: TextStyle(color: Colors.white))),
                      const PopupMenuItem(
                          value: 'ctrl_shift',
                          child: Text('Ctrl+Shift',
                              style: TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_key',
                          child: Text(strings.hotkeyWin,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_r',
                          child: Text(strings.hotkeyWinR,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_e',
                          child: Text(strings.hotkeyWinE,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_x',
                          child: Text(strings.hotkeyWinX,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_d',
                          child: Text(strings.hotkeyWinD,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'win_l',
                          child: Text(
                              strings.isRu
                                  ? 'Заблокировать Windows (Win+L)'
                                  : 'Lock Windows (Win+L)',
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'task_mgr',
                          child: Text(
                              strings.isRu ? 'Диспетчер задач' : 'Task Manager',
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'alt_tab',
                          child: Text(
                              strings.isRu
                                  ? 'Переключить окно (Alt+Tab)'
                                  : 'Switch Window (Alt+Tab)',
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'alt_f4',
                          child: Text(
                              strings.isRu
                                  ? 'Закрыть окно (Alt+F4)'
                                  : 'Close Window (Alt+F4)',
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'esc',
                          child: Text(
                              strings.isRu
                                  ? 'Отмена (Escape)'
                                  : 'Cancel (Escape)',
                              style: const TextStyle(color: Colors.white))),
                    ],
                    onSelected: _sendHotkey,
                  ),

                  // Буфер обмена
                  PopupMenuButton<String>(
                    enabled: _controlReady,
                    icon: const Icon(Icons.content_paste,
                        color: Color(0xFF38BDF8), size: 20),
                    tooltip: strings.clipboardTooltip,
                    color: const Color(0xFF1E293B),
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                          value: 'send',
                          child: Text(strings.sendLocalBuffer,
                              style: const TextStyle(color: Colors.white))),
                      PopupMenuItem(
                          value: 'get',
                          child: Text(strings.readRemoteBuffer,
                              style: const TextStyle(color: Colors.white))),
                    ],
                    onSelected: (val) {
                      if (val == 'send') _sendLocalClipboardToRemote();
                      if (val == 'get') _requestRemoteClipboard();
                    },
                  ),

                  // Чат с пользователем (скрыт для владельца консоли ПК)
                  if (!isOwner)
                    IconButton(
                      icon: Badge(
                        isLabelVisible: _unreadChatCount > 0,
                        label: Text('$_unreadChatCount'),
                        child: const Icon(Icons.chat_bubble_outline,
                            color: Color(0xFF38BDF8), size: 20),
                      ),
                      tooltip: strings.chatWithUserTooltip,
                      onPressed: _showOperatorChatModal,
                    ),

                  // Бейджи телеметрии (CPU, Диск)
                  if (_cpuPercent > 0 || _diskPercent > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _cpuWarning
                                ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                                : const Color(0xFF334155),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: _cpuWarning
                                    ? const Color(0xFFEF4444)
                                    : const Color(0xFF475569)),
                          ),
                          child: Text(
                            '⚡ CPU: $_cpuPercent%',
                            style: TextStyle(
                              color: _cpuWarning
                                  ? const Color(0xFFEF4444)
                                  : Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _diskWarning
                                ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                                : const Color(0xFF334155),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: _diskWarning
                                    ? const Color(0xFFEF4444)
                                    : const Color(0xFF475569)),
                          ),
                          child: Text(
                            '💾 $_diskFreeGb ${strings.gbUnit} ($_diskPercent%)',
                            style: TextStyle(
                              color: _diskWarning
                                  ? const Color(0xFFEF4444)
                                  : Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),

                  // Переключатель управления / просмотра
                  IconButton(
                    icon: Icon(
                      _isControlEnabled
                          ? Icons.sports_esports
                          : Icons.visibility,
                      color: _isViewOnlySession
                          ? const Color(0xFF64748B)
                          : (_isControlEnabled
                              ? const Color(0xFF10B981)
                              : const Color(0xFF94A3B8)),
                      size: 20,
                    ),
                    tooltip: _isViewOnlySession
                        ? (strings.isRu
                            ? 'Режим только просмотр (управление запрещено)'
                            : 'View-only mode (control disabled)')
                        : (_isControlEnabled
                            ? strings.controlEnabledTooltip
                            : strings.controlDisabledTooltip),
                    onPressed: _isViewOnlySession
                        ? null
                        : () {
                            final next = !_isControlEnabled;
                            if (!next) {
                              _sendDataMessage(
                                  {'type': 'block_input', 'blocked': false});
                              _isInputBlocked = false;
                              _releaseAllPressedInputs();
                            }
                            setState(() => _isControlEnabled = next);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(_isControlEnabled
                                    ? strings.controlEnabledNotice
                                    : strings.controlDisabledNotice),
                                duration: const Duration(milliseconds: 800),
                              ),
                            );
                          },
                  ),

                  // Ввод текста на удаленный ПК
                  IconButton(
                    icon: const Icon(Icons.keyboard_alt_outlined,
                        color: Color(0xFF38BDF8), size: 20),
                    tooltip: strings.enterTextTooltip,
                    onPressed: _controlReady ? _showTextInputDialog : null,
                  ),

                  // Режим клика мыши (ЛКМ / ПКМ)
                  IconButton(
                    icon: Icon(
                      _mouseClickMode == MouseClickMode.right
                          ? Icons.mouse
                          : Icons.touch_app,
                      color: _mouseClickMode == MouseClickMode.right
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF94A3B8),
                      size: 18,
                    ),
                    tooltip: _mouseClickMode == MouseClickMode.right
                        ? strings.rightClickModeTooltip
                        : strings.leftClickModeTooltip,
                    onPressed: () {
                      setState(() {
                        _mouseClickMode = _mouseClickMode == MouseClickMode.left
                            ? MouseClickMode.right
                            : MouseClickMode.left;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(_mouseClickMode == MouseClickMode.right
                              ? strings.rightClickNotice
                              : strings.leftClickNotice),
                          duration: const Duration(milliseconds: 800),
                        ),
                      );
                    },
                  ),

                  // Кнопка запроса экрана в режиме чата
                  if (_isChatOnly)
                    ElevatedButton.icon(
                      onPressed: _requestScreenAccess,
                      icon: const Icon(Icons.desktop_windows, size: 14),
                      label: Text(strings.requestScreen2fa,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),

                  // Кнопка завершения сеанса
                  ElevatedButton.icon(
                    onPressed: _endSession,
                    icon: const Icon(Icons.call_end, size: 14),
                    label: Text(strings.endSession,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Карточка с контрольным числом (если сеанс еще авторизуется клиентом).
          // В owner-режиме контрольного числа нет (§5.2: без number-match).
          if (!isOwner &&
              !_isConnected &&
              !_isChatOnly &&
              _currentNumberMatch != null &&
              _statusKey == 'waiting_consent')
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF38BDF8), width: 2),
              ),
              child: Column(
                children: [
                  Text(
                    strings.numberMatchForClient,
                    style:
                        const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _currentNumberMatch!,
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.numberMatchHintClient,
                    style:
                        const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                  ),
                ],
              ),
            ),

          // Область удаленного экрана
          Expanded(
            child: Focus(
              focusNode: _keyboardFocus,
              autofocus: true,
              onFocusChange: (hasFocus) {
                if (!hasFocus) {
                  _releaseAllPressedInputs();
                }
              },
              onKeyEvent: (node, event) {
                if (!_controlReady) return KeyEventResult.ignored;
                _sendDataMessage(_remoteKeyboard.message(event));
                return KeyEventResult.handled;
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerHover: (ev) => _sendPointerEvent('move', ev, 0),
                onPointerMove: (ev) => _sendPointerEvent('move', ev, 0),
                onPointerDown: (ev) {
                  if (!_controlReady) return;
                  _keyboardFocus.requestFocus();
                  final btn = pointerDownButton(
                      ev.buttons, _mouseClickMode == MouseClickMode.right);
                  _pointerDownButtons[ev.pointer] = btn;
                  _sendPointerEvent('mouse_down', ev, btn);
                },
                onPointerUp: (ev) {
                  if (!_controlReady) return;
                  // M-4: up шлёт кнопку из парного down (в up buttons == 0)
                  final btn = _pointerDownButtons.remove(ev.pointer) ?? 0;
                  _sendPointerEvent('mouse_up', ev, btn);
                  if (_mouseClickMode == MouseClickMode.right) {
                    setState(() => _mouseClickMode = MouseClickMode.left);
                  }
                },
                onPointerCancel: (ev) {
                  final btn = _pointerDownButtons.remove(ev.pointer);
                  if (btn != null && _controlReady) {
                    _sendPointerEvent('mouse_up', ev, btn);
                  }
                },
                onPointerSignal: (signal) {
                  if (!_controlReady) return;
                  if (signal is PointerScrollEvent) {
                    _sendDataMessage(
                        {'type': 'wheel', 'deltaY': signal.scrollDelta.dy});
                  }
                },
                child: Center(
                  child: _isChatOnly
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0284C7)
                                    .withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.chat_outlined,
                                  size: 48, color: Color(0xFF38BDF8)),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              strings.chatModeTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(
                                strings.chatModeDesc,
                                style: const TextStyle(
                                    color: Color(0xFF94A3B8), fontSize: 13),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: _requestScreenAccess,
                              icon: const Icon(Icons.desktop_windows, size: 18),
                              label: Text(strings.requestScreenAccessBtn,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _showOperatorChatModal,
                              icon: const Icon(Icons.chat_bubble_outline,
                                  size: 16),
                              label: Text(_chatMessages.isEmpty
                                  ? strings.openChatWindowBtn
                                  : '💬 ${strings.chatTitle} (${_chatMessages.length})'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF38BDF8),
                                side:
                                    const BorderSide(color: Color(0xFF0284C7)),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ],
                        )
                      : _remoteRenderer.srcObject == null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(
                                    color: Color(0xFF38BDF8)),
                                const SizedBox(height: 16),
                                Text(
                                  _getStatusText(strings),
                                  style: const TextStyle(
                                      color: Color(0xFF94A3B8), fontSize: 14),
                                  textAlign: TextAlign.center,
                                ),
                                // Ш3: повтор зависшей стадии подключения
                                if (_stageRetryActive) ...[
                                  const SizedBox(height: 16),
                                  ElevatedButton.icon(
                                    onPressed: _retryConnectionStage,
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: Text(strings.retry),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF0284C7),
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ],
                            )
                          : _statusKey == 'no_first_frame'
                              // Ш3: трек есть, кадра нет — вместо чёрного экрана
                              // понятная ошибка и повтор
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.videocam_off_outlined,
                                        size: 48, color: Color(0xFFF59E0B)),
                                    const SizedBox(height: 16),
                                    Text(
                                      _getStatusText(strings),
                                      style: const TextStyle(
                                          color: Color(0xFF94A3B8),
                                          fontSize: 14),
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      onPressed: _retryConnectionStage,
                                      icon: const Icon(Icons.refresh, size: 16),
                                      label: Text(strings.retry),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF0284C7),
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ],
                                )
                              : InteractiveViewer(
                                  transformationController: _videoTransform,
                                  scaleEnabled:
                                      _zoomMode == OperatorZoomMode.zoomIn,
                                  minScale: 1.0,
                                  maxScale: 8.0,
                                  onInteractionEnd: (_) {
                                    _zoomScale = _videoTransform.value
                                        .getMaxScaleOnAxis();
                                  },
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.basic,
                                    child: Container(
                                      key: _videoKey,
                                      child: RTCVideoView(
                                        _remoteRenderer,
                                        objectFit: RTCVideoViewObjectFit
                                            .RTCVideoViewObjectFitContain,
                                      ),
                                    ),
                                  ),
                                ),
                ),
              ),
            ),
          ),

          // Быстрая панель действий для оператора (скролл, режим клика, ввод текста)
          // Ш3: панель управления — только при готовом канале управления
          if (_controlReady)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                border: Border(top: BorderSide(color: Color(0xFF334155))),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _mouseClickMode =
                              _mouseClickMode == MouseClickMode.left
                                  ? MouseClickMode.right
                                  : MouseClickMode.left;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                _mouseClickMode == MouseClickMode.right
                                    ? strings.rightClickNotice
                                    : strings.leftClickNotice),
                            duration: const Duration(milliseconds: 700),
                          ),
                        );
                      },
                      icon: Icon(
                        _mouseClickMode == MouseClickMode.right
                            ? Icons.mouse
                            : Icons.touch_app,
                        size: 16,
                        color: _mouseClickMode == MouseClickMode.right
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF38BDF8),
                      ),
                      label: Text(
                        _mouseClickMode == MouseClickMode.right
                            ? strings.rightClickModeShort
                            : strings.leftClickModeShort,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _mouseClickMode == MouseClickMode.right
                              ? const Color(0xFFF59E0B)
                              : Colors.white,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          _sendDataMessage({'type': 'wheel', 'deltaY': -180}),
                      icon: const Icon(Icons.arrow_upward,
                          size: 14, color: Color(0xFF38BDF8)),
                      label: Text(strings.scrollUp,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          _sendDataMessage({'type': 'wheel', 'deltaY': 180}),
                      icon: const Icon(Icons.arrow_downward,
                          size: 14, color: Color(0xFF38BDF8)),
                      label: Text(strings.scrollDown,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                    ),
                    TextButton.icon(
                      onPressed: _controlReady ? _showTextInputDialog : null,
                      icon: const Icon(Icons.keyboard_alt_outlined,
                          size: 16, color: Color(0xFF38BDF8)),
                      label: Text(strings.enterTextBtn,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                    ),
                    if (!isOwner)
                      TextButton.icon(
                        onPressed: _showOperatorChatModal,
                        icon: Badge(
                          isLabelVisible: _unreadChatCount > 0,
                          label: Text('$_unreadChatCount'),
                          child: const Icon(Icons.chat_bubble_outline,
                              size: 16, color: Color(0xFF38BDF8)),
                        ),
                        label: Text(
                          _unreadChatCount > 0
                              ? '${strings.chatTitle} ($_unreadChatCount)'
                              : strings.chatTitle,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
