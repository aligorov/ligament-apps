import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/client.dart';
import 'input_injector.dart';
import 'telemetry_service.dart';
import 'link_host_recorder.dart';
import 'debug_log_service.dart';

/// Fixed protocol labels only: never echo arbitrary wire values or contents.
String supportDebugMessageType(Object? value) => const {
      'candidate',
      'signal',
      'sdp',
      'offer',
      'answer',
      'request_offer',
      'renegotiate',
      'ice_restart',
      'session_offer',
      'session_answer',
      'session_terminate',
      'session_close',
      'session_revoke',
      'consent_decision',
      'session_ended',
      'support_ended',
      'console_end',
      'console_ready',
      'console_error',
      'lease',
      'input_control',
      'screen_list',
      'switch_screen',
      'chat_message',
      'chat_sync',
      'chat_ack',
      'ping',
      'pong',
      'mouse_move',
      'mouse_down',
      'mouse_up',
      'mouse_click',
      'click',
      'wheel',
      'mouse_wheel',
      'key_down',
      'key_up',
      'block_input',
      'block_input_ack',
      'hotkey',
      'text_input',
      'clipboard_set',
      'clipboard_get',
      'clipboard_data',
      'clipboard_error',
      'input_error',
      'reboot',
      'video_quality',
      'file_start',
      'file_chunk',
      'file_end',
      'file_ack',
      'file_reject',
      'telemetry',
      'screen_lock_state',
      'challenge_prompt',
      'push_prompt',
      'browser_sso',
      'support_prompt',
      'support_signal',
      'support_incoming_request',
      'support_queue_update',
      'notification',
      'notify_delivered',
      'support_incoming',
    }.contains(value)
        ? value as String
        : 'unknown';

class SupportChatMessage {
  final String id;
  final String sender; // 'operator' | 'user'
  final String senderName;
  final String text;
  final DateTime timestamp;
  // Идемпотентный ключ отправителя: одинаков в DC-копии и REST-записи —
  // сервер (миграция 0074) дедупит пару (session_id, client_id) в одну
  // строку, приёмник глушит эхо DC↔история независимо от расхождения часов.
  final String clientId;

  SupportChatMessage({
    required this.id,
    required this.sender,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.clientId = '',
  });

  Map<String, dynamic> toJson() => {
        'type': 'chat_message',
        'id': id,
        'sender': sender,
        'sender_name': senderName,
        'text': text,
        'timestamp': timestamp.millisecondsSinceEpoch,
        if (clientId.isNotEmpty) 'client_id': clientId,
      };

  factory SupportChatMessage.fromJson(Map<String, dynamic> json) {
    DateTime ts;
    if (json['timestamp'] != null) {
      if (json['timestamp'] is num) {
        ts = DateTime.fromMillisecondsSinceEpoch(
            (json['timestamp'] as num).toInt());
      } else {
        ts = DateTime.tryParse(json['timestamp'].toString()) ?? DateTime.now();
      }
    } else if (json['created_at'] != null) {
      ts = DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }

    return SupportChatMessage(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      sender: json['sender']?.toString() ??
          (json['sender_role'] == 'operator' ? 'operator' : 'user'),
      senderName: json['sender_name']?.toString() ??
          (json['sender'] == 'operator' || json['sender_role'] == 'operator'
              ? 'Инженер'
              : 'Пользователь'),
      text: json['text']?.toString() ?? json['body']?.toString() ?? '',
      timestamp: ts,
      clientId: json['client_id']?.toString() ??
          json['client_message_id']?.toString() ??
          '',
    );
  }
}

class ReceivedFileItem {
  final String id;
  final String filename;
  final String localPath;
  final int size;
  final DateTime receivedAt;

  ReceivedFileItem({
    required this.id,
    required this.filename,
    required this.localPath,
    required this.size,
    required this.receivedAt,
  });
}

class _ActiveFileDownload {
  final String id;
  final String filename;
  final int totalSize;
  final int totalChunks;
  final String? expectedChecksum;
  final Map<int, List<int>> chunks = {};

  /// Фактически получено байт (защита от заниженного totalSize)
  int receivedBytes = 0;

  /// Таймаут ожидания следующего чанка: истек — закачка отменяется
  Timer? stallTimer;

  _ActiveFileDownload({
    required this.id,
    required this.filename,
    required this.totalSize,
    required this.totalChunks,
    this.expectedChecksum,
  });
}

/// Результат сборки файловой передачи из чанков (M-3).
class FileAssemblyResult {
  final Uint8List? bytes;

  /// null — сборка успешна; иначе код/описание ошибки
  /// ('incomplete' | 'checksum_mismatch' | 'size_mismatch').
  final String? error;

  const FileAssemblyResult.success(this.bytes) : error = null;

  const FileAssemblyResult.failure(this.error) : bytes = null;

  bool get isOk => error == null && bytes != null;
}

/// Сборка чанков файловой передачи с проверкой полноты и целостности.
/// Чистая функция — покрыта юнит-тестами:
/// - все индексы 0..totalChunks-1 обязаны присутствовать;
/// - контрольная сумма sha256 (если передана) обязана совпасть;
/// - фактический размер (если file_start передал size>0) обязан совпасть.
FileAssemblyResult assembleFileChunks(
  Map<int, List<int>> chunks,
  int totalChunks, {
  int? expectedSize,
  String? expectedChecksum,
}) {
  if (totalChunks <= 0) {
    return const FileAssemblyResult.failure('incomplete');
  }
  for (int i = 0; i < totalChunks; i++) {
    if (!chunks.containsKey(i)) {
      return const FileAssemblyResult.failure('incomplete');
    }
  }
  // Чанки вне диапазона игнорируют целостность по индексам — отбрасываем их.
  final builder = BytesBuilder(copy: false);
  for (int i = 0; i < totalChunks; i++) {
    builder.add(chunks[i]!);
  }
  final bytes = builder.takeBytes();
  if (expectedSize != null &&
      expectedSize > 0 &&
      bytes.length != expectedSize) {
    return const FileAssemblyResult.failure('size_mismatch');
  }
  if (expectedChecksum != null && expectedChecksum.isNotEmpty) {
    final actual = crypto.sha256.convert(bytes).toString();
    if (actual != expectedChecksum.toLowerCase()) {
      return const FileAssemblyResult.failure('checksum_mismatch');
    }
  }
  return FileAssemblyResult.success(bytes);
}

/// Разрешение уникального пути файла с предотвращением коллизий (name (1).ext) (B2.3).
/// [fileExists] опционально передается для юнит-тестирования без обращения к файловой системе.
String resolveNonCollidingFilePath(
  String dirPath,
  String filename, {
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? (p) => File(p).existsSync();
  final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final separator = Platform.pathSeparator;
  final directPath = '$dirPath$separator$safeName';
  if (!exists(directPath)) return directPath;

  final dotIndex = safeName.lastIndexOf('.');
  final baseName = dotIndex > 0 ? safeName.substring(0, dotIndex) : safeName;
  final ext = dotIndex > 0 ? safeName.substring(dotIndex) : '';
  int index = 1;
  while (true) {
    final candidate = '$dirPath$separator$baseName ($index)$ext';
    if (!exists(candidate)) return candidate;
    index++;
  }
}

enum SupportSessionState {
  idle,
  requested,
  authorizing,
  connecting,
  active,
  ended,
}

/// Разбор ICE-серверов из ответа /api/v1/app/config.
///
/// Ожидаемый формат поля ice_servers:
///   [{"urls": ["turn:host:3478", "stun:..."], "username": "...", "credential": "..."}, ...]
/// urls может быть строкой или массивом; username/credential опциональны.
/// Возвращает пустой список, если поле отсутствует/невалидно — пустой список
/// и используется (A-3: никаких публичных emergency-фолбэков, fail-closed).
List<Map<String, dynamic>> parseIceServersConfig(Map<String, dynamic>? config) {
  if (config == null) return const [];
  final raw = config['ice_servers'];
  if (raw is! List) return const [];
  final result = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final urlsRaw = item['urls'];
    List<String> urls = const [];
    if (urlsRaw is List) {
      urls = urlsRaw
          .map((e) => e?.toString() ?? '')
          .where((u) => _isValidIceUrl(u))
          .toList();
    } else if (urlsRaw is String && _isValidIceUrl(urlsRaw)) {
      urls = [urlsRaw];
    }
    if (urls.isEmpty) continue;
    result.add({
      'urls': urls,
      if (item['username'] != null) 'username': item['username'].toString(),
      if (item['credential'] != null)
        'credential': item['credential'].toString(),
    });
  }
  return result;
}

bool _isValidIceUrl(String url) {
  return url.startsWith('stun:') ||
      url.startsWith('turn:') ||
      url.startsWith('turns:');
}

/// Сервис управления WebRTC экраном и вводом для удаленной поддержки (SOS).
class SupportService extends ChangeNotifier {
  SupportService({
    this.serviceHost = false,
    this.serviceInput,
    this.serviceReleaseInput,
  });

  /// SYSTEM workers expose only screen and input. They must never inherit
  /// ordinary SOS file/chat features with SYSTEM privileges. Clipboard is
  /// permitted only after the native worker verifies the Default desktop.
  final bool serviceHost;
  final Future<void> Function(Map<String, dynamic>)? serviceInput;
  final Future<void> Function()? serviceReleaseInput;

  static bool serviceHostCommandAllowed(String type) => const {
        'screen_list',
        'switch_screen',
        'mouse_move',
        'mouse_down',
        'mouse_up',
        'mouse_click',
        'click',
        'wheel',
        'mouse_wheel',
        'key_down',
        'key_up',
        'block_input',
        'hotkey',
        'text_input',
        'clipboard_set',
        'clipboard_get',
        'session_ended',
        'support_ended',
        'console_end',
        'video_quality',
        'reboot',
        'file_start',
        'file_chunk',
        'file_end',
        'file_reject',
      }.contains(type);

  int _captureEpoch = 0;
  Future<void> _captureStartQueue = Future<void>.value();
  DateTime _lastMouseCheck = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInputError = DateTime.fromMillisecondsSinceEpoch(0);

  void _requireCaptureEpoch(int epoch) {
    if (epoch != _captureEpoch || _isStopping) {
      throw StateError('capture_cancelled');
    }
  }

  /// Лимиты файловых передач (защита памяти/диска от нелимитированных закачек)
  static const int _maxFileTransferBytes = 50 * 1024 * 1024; // 50 МБ
  static const int _maxConcurrentDownloads = 2;
  static const Duration _downloadStallTimeout = Duration(seconds: 60);

  /// A-3 (аудит 2026-10-12): публичные STUN-фолбэки удалены (fail-closed).
  /// ICE-серверы приходят только с корпоративного сервера
  /// (/api/v1/app/ice-servers или /api/v1/app/config); пусто — значит пусто:
  /// утечка IP сотрудников на публичную инфраструктуру недопустима.

  /// ICE-серверы из конфига сервера; null — конфиг еще не загружен.
  List<Map<String, dynamic>>? _iceServersFromConfig;

  /// Актуальный список ICE-серверов для RTCPeerConnection (только серверные).
  List<Map<String, dynamic>> get effectiveIceServers =>
      _iceServersFromConfig ?? const [];

  /// Устанавливает ICE-серверы из корпоративного конфига/ядра.
  void setIceServers(List<Map<String, dynamic>>? servers) {
    if (servers != null && servers.isNotEmpty) {
      _iceServersFromConfig = servers;
    }
  }

  SupportSessionState _state = SupportSessionState.idle;
  String? _activeSessionId;
  String? _category;
  String? _problemSummary;
  String _accessMode = 'full_control';

  /// Режим «Экран» (этап 2.4): трансляция инициирована ВЛАДЕЛЬЦЕМ с его
  /// другого устройства (grant mode=screen, support_prompt с owner:true).
  /// Отличается от обычного SOS: не было accept-диалога, «инженера» нет —
  /// на другой стороне сам владелец. Влияет на тексты ошибок/баннера.
  bool _ownerSession = false;

  /// Имя/идентификатор устройства-инициатора (с кого открыли «Экран») —
  /// для баннера на цели «Ваш экран открыт вам с устройства X».
  String? _ownerInitiatorDevice;

  /// SOS через Link-агент ПК: экран и ввод ведёт агент, а не это приложение.
  bool _linkHosted = false;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _audioStream;
  Timer? _desktopSwitchTimer;
  Timer? _desktopRecoveryTimer;
  bool _switchingScreen = false;
  RTCDataChannel? _dataChannel;
  ApiClient? _api;

  List<Map<String, dynamic>> _screens = [];
  String? _currentScreenId;
  ScreenRect? _currentScreenRect;
  Timer? _telemetryTimer;
  Timer? _leaseWatchdogTimer;
  final TelemetryService _telemetry = TelemetryService();

  LinkHostRecorder? _recorder;
  Timer? _recorderSnapshotTimer;
  bool _capturingRecorderFrame = false;

  final List<SupportChatMessage> _chatMessages = [];
  int _unreadChatCount = 0;
  final List<ReceivedFileItem> _receivedFiles = [];
  final Map<String, _ActiveFileDownload> _activeDownloads = {};

  // === Живучесть P2P (M-1) ===
  /// Таймаут установления соединения: 30с с момента offer — повторный offer,
  /// 60с — завершение с ошибкой.
  Timer? _establishmentTimer;
  Timer? _establishmentDeadlineTimer;

  /// Disconnected: ждем 10с перед ICE-рестартом (транзиентные обрывы).
  Timer? _disconnectedTimer;

  /// Максимум ICE-рестартов с повторным offer (интервал 5с).
  int _iceRestartAttempts = 0;
  DateTime? _lastIceRestartAt;
  bool _p2pConnected = false;

  /// Последняя ошибка сессии для UI (null — сессия завершилась без ошибок).
  String? _lastError;

  SupportSessionState get state => _state;
  String? get activeSessionId => _activeSessionId;
  String? get category => _category;
  String? get problemSummary => _problemSummary;
  String get accessMode => _accessMode;
  bool get isSharing => _state == SupportSessionState.active;
  bool get ownerSession => _ownerSession;
  bool get linkHosted => _linkHosted;
  String? get ownerInitiatorDevice => _ownerInitiatorDevice;
  String? get lastError => _lastError;

  void _logSupport(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    DebugLogService.instance.record(event, error: error, fields: {
      'session_id': _activeSessionId,
      'attempt': _captureEpoch,
      'state': _state.name,
      'owner': _ownerSession,
      'connected': _p2pConnected,
      'control_ready':
          _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen,
      'tracks': _localStream?.getTracks().length ?? 0,
      'recorder_enabled': _recorder?.config.enabled ?? false,
      ...fields,
      if (fields.containsKey('reason'))
        'reason': DebugLogService.protocolLabel(fields['reason']),
    });
  }

  /// Сброс ошибки последней сессии (кнопка «Закрыть» в баннере ошибки).
  void clearError() {
    if (_lastError != null || _state == SupportSessionState.ended) {
      _lastError = null;
      if (_state == SupportSessionState.ended) {
        _state = SupportSessionState.idle;
      }
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> get screens => _screens;
  String? get currentScreenId => _currentScreenId;

  List<SupportChatMessage> get chatMessages => List.unmodifiable(_chatMessages);
  int get unreadChatCount => _unreadChatCount;
  List<ReceivedFileItem> get receivedFiles => List.unmodifiable(_receivedFiles);
  void Function(SupportChatMessage message)? onChatMessageReceived;

  /// Отмена конкретной закачки (таймаут, превышение лимита)
  void _abortDownload(String transferId, String reason) {
    final dl = _activeDownloads.remove(transferId);
    dl?.stallTimer?.cancel();
    if (dl != null) {}
  }

  /// Отмена всех активных закачек с очисткой таймеров
  void _cancelAllDownloads() {
    for (final dl in _activeDownloads.values) {
      dl.stallTimer?.cancel();
    }
    _activeDownloads.clear();
  }

  void setApi(ApiClient api) {
    _api = api;
  }

  void markChatAsRead() {
    _unreadChatCount = 0;
    notifyListeners();
  }

  void clearChat() {
    _chatMessages.clear();
    _unreadChatCount = 0;
    notifyListeners();
  }

  Future<void> loadChatHistory([String? sessId]) async {
    final sId = sessId ?? _activeSessionId;
    if (_api == null || sId == null || sId.isEmpty) return;
    try {
      final list = await _api!.getSupportMessages(sId);
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
        notifyListeners();
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'load_chat_history', 'result': 'failed'});
    }
  }

  void sendChatMessage(String text, {String? senderName}) {
    if (text.trim().isEmpty) return;
    final msg = SupportChatMessage(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      sender: 'user',
      senderName: senderName ?? 'Пользователь',
      text: text.trim(),
      timestamp: DateTime.now(),
      clientId: 'user-msg_${DateTime.now().millisecondsSinceEpoch}',
    );
    _chatMessages.add(msg);
    notifyListeners();

    _sendSignalOrData(msg.toJson());

    if (_api != null &&
        _activeSessionId != null &&
        _activeSessionId!.isNotEmpty) {
      _api!
          .sendSupportChatMessage(
        sessionId: _activeSessionId!,
        text: msg.text,
        senderName: msg.senderName,
        clientId: msg.clientId,
      )
          .catchError((Object e) {
        _logSupport('support.async.failed',
            error: e, fields: {'operation': 'async_request'});
      });
    }
  }

  final Map<String, int> _mouseDiagnosticCounts = {};
  Timer? _mouseDiagnosticTimer;
  void _logMessage(Object? type, String phase, String result, {int? bytes}) {
    final label = supportDebugMessageType(type);
    if (label == 'mouse_move') {
      final key = '$phase.$result';
      _mouseDiagnosticCounts[key] = (_mouseDiagnosticCounts[key] ?? 0) + 1;
      _mouseDiagnosticTimer ??=
          Timer(const Duration(seconds: 1), _flushMouseDiagnostics);
      return;
    }
    _logSupport('support.message', fields: {
      'message_type': label,
      'phase': phase,
      'result': result,
      if (bytes != null) 'bytes': bytes
    });
  }

  void _flushMouseDiagnostics() {
    _mouseDiagnosticTimer?.cancel();
    _mouseDiagnosticTimer = null;
    for (final entry in _mouseDiagnosticCounts.entries) {
      final parts = entry.key.split('.');
      _logSupport('support.mouse.summary', fields: {
        'message_type': 'mouse_move',
        'phase': parts[0],
        'result': parts[1],
        'count': entry.value
      });
    }
    _mouseDiagnosticCounts.clear();
  }

  void _observeDataEnqueue(Future<void> send, Object? type, int bytes) {
    _logMessage(type, 'outbound_dc', 'requested', bytes: bytes);
    unawaited(send.then((_) {
      _logMessage(type, 'outbound_dc', 'queued', bytes: bytes);
    }).catchError((Object error) {
      _logSupport('support.data.send_failed', error: error, fields: {
        'message_type': supportDebugMessageType(type),
        'bytes': bytes,
        'result': 'failed'
      });
    }));
  }

  void _sendSignalOrData(Map<String, dynamic> data) {
    bool sent = false;
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        final text = jsonEncode(data);
        _observeDataEnqueue(_dataChannel!.send(RTCDataChannelMessage(text)),
            data['type'], utf8.encode(text).length);
        sent = true;
      } catch (e) {
        _logSupport('support.exception',
            error: e,
            fields: {'phase': 'send_signal_or_data', 'result': 'failed'});
      }
    }
    if (!sent && _api != null && _activeSessionId != null) {
      // M-3: файловые передачи запрещены в HTTP-fallback (sendSupportSignal).
      // Чанки не проходят через сигнальный шлюз: утечка в чат-историю
      // сервера + отсутствие доставки по порядку.
      final type = data['type']?.toString() ?? '';
      if (type.startsWith('file_')) {
        _logMessage(type, 'outbound_http', 'blocked');
        throw StateError(
            'Файловая передача требует открытый DataChannel ($type)');
      }
      _logMessage(type, 'outbound_http', 'requested');
      _api!.sendSupportSignal(sessionId: _activeSessionId!, signal: data);
    }
  }

  Future<void> sendFile(
    File file, {
    void Function(int sentBytes, int totalBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!await file.exists()) return;
    final filename = file.uri.pathSegments.last;
    final totalSize = await file.length();

    if (totalSize > _maxFileTransferBytes) {
      _addSystemMessage(
          '⚠ Файл не отправлен: превышен лимит размера 50 МБ ($filename)');
      notifyListeners();
      return;
    }

    final bytes = await file.readAsBytes();

    // M-3: файловые передачи идут ТОЛЬКО через DataChannel; HTTP-fallback
    // для file_* запрещен (см. _sendSignalOrData).
    if (_dataChannel == null ||
        _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      _addSystemMessage(
          '⚠ Файл не отправлен: нет открытого соединения с инженером ($filename)');
      notifyListeners();
      return;
    }

    const chunkSize = 32768; // 32 KB
    final totalChunks = (totalSize / chunkSize).ceil();
    final transferId = 'file_${DateTime.now().millisecondsSinceEpoch}';
    // Контрольная сумма целого файла: получатель сверяет при сборке (M-3).
    final checksum = crypto.sha256.convert(bytes).toString();

    try {
      _sendSignalOrData({
        'type': 'file_start',
        'transfer_id': transferId,
        'filename': filename,
        'size': totalSize,
        'total_chunks': totalChunks,
        'checksum': checksum,
        'sender': 'user',
      });

      for (int i = 0; i < totalChunks; i++) {
        if (isCancelled?.call() == true) {
          _sendSignalOrData({
            'type': 'file_reject',
            'transfer_id': transferId,
            'filename': filename,
            'reason': 'cancelled_by_sender',
          });
          _addSystemMessage('⚠ Передача файла "$filename" отменена');
          notifyListeners();
          return;
        }

        final start = i * chunkSize;
        final end =
            (start + chunkSize > totalSize) ? totalSize : start + chunkSize;
        final chunkBytes = bytes.sublist(start, end);
        final b64 = base64Encode(chunkBytes);

        _sendSignalOrData({
          'type': 'file_chunk',
          'transfer_id': transferId,
          'chunk_index': i,
          'data': b64,
        });
        onProgress?.call(end, totalSize);
        if (i % 10 == 0) {
          await Future.delayed(const Duration(milliseconds: 15));
        }
      }

      _sendSignalOrData({
        'type': 'file_end',
        'transfer_id': transferId,
        'checksum': checksum,
      });

      _chatMessages.add(SupportChatMessage(
        id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'user',
        senderName: 'Пользователь',
        text:
            '📎 Отправлен файл: $filename (${(totalSize / 1024).toStringAsFixed(1)} КБ)',
        timestamp: DateTime.now(),
      ));
      notifyListeners();
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'function', 'result': 'failed'});

      _addSystemMessage(
          '⚠ Передача файла "$filename" прервана (нет соединения)');
      notifyListeners();
    }
  }

  Future<void> _saveReceivedFile(
      _ActiveFileDownload dl, Uint8List bytes) async {
    String? targetPath;
    try {
      final downloadsPath = await _resolveDownloadsDir();

      final dir = Directory(downloadsPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // B2.3: Защита от конфликта имён (автопереименование name (1).ext)
      targetPath = resolveNonCollidingFilePath(dir.path, dl.filename);
      final safeName = targetPath.split(Platform.pathSeparator).last;

      // B2.2: Атомарная запись (сначала в .part, затем переименование)
      final partPath = '$targetPath.part';
      final partFile = File(partPath);
      await partFile.writeAsBytes(bytes, flush: true);
      await partFile.rename(targetPath);

      // B2.1: Mark-of-the-Web (Zone.Identifier=3) на Windows
      if (!kIsWeb && Platform.isWindows) {
        try {
          final zoneFile = File('$targetPath:Zone.Identifier');
          await zoneFile.writeAsString('[ZoneTransfer]\r\nZoneId=3\r\n');
        } catch (e) {
          _logSupport('support.exception',
              error: e,
              fields: {'phase': 'save_received_file', 'result': 'failed'});
        }
      }

      final item = ReceivedFileItem(
        id: dl.id,
        filename: safeName,
        localPath: targetPath,
        size: bytes.length,
        receivedAt: DateTime.now(),
      );
      _receivedFiles.insert(0, item);

      _chatMessages.add(SupportChatMessage(
        id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'operator',
        senderName: 'Система',
        text:
            '📁 Получен файл: $safeName (${(bytes.length / 1024).toStringAsFixed(1)} КБ)',
        timestamp: DateTime.now(),
      ));
      _unreadChatCount++;
      notifyListeners();

      // file_ack: консоль оператора ждёт подтверждения доставки (30 с)
      // после file_end — без него успешная передача выглядит ошибкой.
      _sendFileAck(dl.id, ok: true);
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'save_received_file', 'result': 'failed'});

      if (targetPath != null) {
        try {
          final partFile = File('$targetPath.part');
          if (await partFile.exists()) {
            await partFile.delete();
          }
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'save_received_file', 'result': 'failed'});
        }
      }
      _sendFileAck(dl.id, ok: false);
    }
  }

  /// Подтверждение приёма файла отправителю (консоль/приложение):
  /// {ok:true} — сохранён, {ok:false} — ошибка сохранения.
  void _sendFileAck(String transferId, {required bool ok}) {
    try {
      _sendSignalOrData({
        'type': 'file_ack',
        'transfer_id': transferId,
        'ok': ok,
      });
    } catch (error) {
      _logSupport('support.exception',
          error: error, fields: {'phase': 'send_file_ack', 'result': 'failed'});
      // Канал закрыт — отправитель узнает по таймауту
    }
  }

  /// Каталог для сохранения полученных файлов.
  /// Desktop — Downloads/LigamentSupport; Android — через path_provider
  /// (M-7: не /sdcard напрямую), фолбэк — документы приложения.
  Future<String> _resolveDownloadsDir() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final dirs = await getExternalStorageDirectories(
            type: StorageDirectory.downloads);
        if (dirs != null && dirs.isNotEmpty) {
          return '${dirs.first.path}${Platform.pathSeparator}LigamentSupport';
        }
      } catch (e) {
        _logSupport('support.exception',
            error: e,
            fields: {'phase': 'resolve_downloads_dir', 'result': 'failed'});
      }
      // Фолбэк: документы приложения
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}${Platform.pathSeparator}LigamentSupport';
    }
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ?? '';
      final isSystemProfile = profile.isEmpty ||
          profile.toLowerCase().contains('systemprofile') ||
          profile.toLowerCase().startsWith('c:\\windows');

      if (isSystemProfile) {
        // Процесс запущен под учетной записью SYSTEM (фоновая служба консоли).
        // Проверяем наличие профилей реальных пользователей в C:\Users\
        try {
          final usersDir = Directory('C:\\Users');
          if (usersDir.existsSync()) {
            final userFolders = usersDir
                .listSync()
                .whereType<Directory>()
                .map((d) => d.path)
                .where((p) {
              final name = p.split(Platform.pathSeparator).last.toLowerCase();
              return name != 'default' &&
                  name != 'default user' &&
                  name != 'public' &&
                  name != 'all users';
            }).toList();

            for (final userPath in userFolders) {
              final dlDir = Directory('$userPath\\Downloads');
              if (dlDir.existsSync()) {
                return '$userPath\\Downloads\\LigamentSupport';
              }
            }
          }
        } catch (e) {
          _logSupport('support.exception',
              error: e,
              fields: {'phase': 'resolve_downloads_dir', 'result': 'failed'});
        }

        // Надежный fallback для службы: Общие загрузки (Public Downloads)
        final publicDir = Platform.environment['PUBLIC'] ?? 'C:\\Users\\Public';
        return '$publicDir\\Downloads\\LigamentSupport';
      }

      final targetProfile = profile.isNotEmpty ? profile : 'C:\\Users\\Default';
      return '$targetProfile\\Downloads\\LigamentSupport';
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/Downloads/LigamentSupport';
    }
    return '/tmp/LigamentSupport';
  }

  /// Установка локального состояния запроса
  void setRequested({
    required String sessionId,
    required String category,
    required String problemSummary,
    String accessMode = 'full_control',
    ApiClient? api,
  }) {
    _activeSessionId = sessionId;
    if (api != null) _api = api;
    _category = category;
    _problemSummary = problemSummary;
    _accessMode = accessMode;
    _ownerSession = false;
    _ownerInitiatorDevice = null;
    _linkHosted = false;
    _state = SupportSessionState.requested;
    _lastError = null;
    _unreadChatCount = 0;
    _cancelAllDownloads();
    notifyListeners();
  }

  /// Установка состояния авторизации (когда оператор запросил подключение).
  /// [owner] — owner-режим «Экрана» (этап 2.4): сессию инициировал сам
  /// владелец с другого устройства; accept-диалог не показывается.
  void setAuthorizing({
    required String sessionId,
    String? category,
    String? problemSummary,
    String? accessMode,
    ApiClient? api,
    bool owner = false,
    String? initiatorDevice,
  }) {
    _activeSessionId = sessionId;
    if (api != null) _api = api;
    if (category != null) _category = category;
    if (problemSummary != null) _problemSummary = problemSummary;
    if (accessMode != null && accessMode.isNotEmpty) _accessMode = accessMode;
    _ownerSession = owner;
    _ownerInitiatorDevice = owner ? initiatorDevice : null;
    _linkHosted = false;
    _state = SupportSessionState.authorizing;
    notifyListeners();
  }

  /// SOS через Link-агент ПК: этапы заявки без захвата экрана приложением.
  void setLinkHostedSession({required String sessionId, required bool active}) {
    final next =
        active ? SupportSessionState.active : SupportSessionState.authorizing;
    if (_linkHosted && _activeSessionId == sessionId && _state == next) return;
    _activeSessionId = sessionId;
    _ownerSession = false;
    _ownerInitiatorDevice = null;
    _linkHosted = true;
    _state = next;
    notifyListeners();
  }

  /// Инициализация P2P WebRTC захвата экрана и отправка SDP Offer оператору
  Future<void> startScreenSharing({
    required String sessionId,
    required ApiClient api,
    String accessMode = 'full_control',
  }) {
    final expectedEpoch = _captureEpoch;
    final operation = _captureStartQueue.then((_) async {
      while (_isStopping) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (expectedEpoch != _captureEpoch) {
        throw StateError('capture_start_cancelled');
      }
      await _startScreenSharing(
        sessionId: sessionId,
        api: api,
        accessMode: accessMode,
      );
    });
    _captureStartQueue = operation.catchError((Object error) {
      _logSupport('support.async.failed',
          error: error, fields: {'operation': 'async_request'});
    });
    return operation;
  }

  Future<void> _startScreenSharing({
    required String sessionId,
    required ApiClient api,
    String accessMode = 'full_control',
  }) async {
    final epoch = ++_captureEpoch;
    _activeSessionId = sessionId;
    _api = api;
    _accessMode = accessMode;
    final watch = Stopwatch()..start();
    var phase = 'ice';
    _logSupport('support.capture.start', fields: {'result': 'begin'});

    try {
      // ICE-серверы берутся только с корпоративного сервера
      // (/api/v1/app/ice-servers или конфиг): захардкоженные публичные
      // STUN-фолбэки удалены (A-3, аудит 2026-10-12, fail-closed).
      if (_iceServersFromConfig == null || _iceServersFromConfig!.isEmpty) {
        try {
          final iceRaw = await api.getIceServers();
          final parsed = parseIceServersConfig({'ice_servers': iceRaw});
          if (parsed.isNotEmpty) {
            setIceServers(parsed);
          }
        } catch (e) {
          _logSupport('support.capture.failed', error: e, fields: {
            'phase': phase,
            'duration_ms': watch.elapsedMilliseconds,
            'result': 'failed'
          });
        }
        if (_iceServersFromConfig == null || _iceServersFromConfig!.isEmpty) {
          try {
            final cfg = await api.getConfig();
            final parsed = parseIceServersConfig(cfg);
            if (parsed.isNotEmpty) {
              setIceServers(parsed);
            }
          } catch (e) {
            _logSupport('support.capture.failed', error: e, fields: {
              'phase': phase,
              'duration_ms': watch.elapsedMilliseconds,
              'result': 'failed'
            });
          }
        }
      }
      final rtcConfig = <String, dynamic>{
        'iceServers': effectiveIceServers,
        'sdpSemantics': 'unified-plan',
      };

      _requireCaptureEpoch(epoch);
      phase = 'peer_create';
      _logSupport('support.capture.step', fields: {
        'phase': phase,
        'result': 'begin',
        'ice_servers': effectiveIceServers.length
      });
      _peerConnection = await createPeerConnection(rtcConfig);
      _logSupport('support.capture.step', fields: {
        'phase': phase,
        'result': 'ready',
        'elapsed_ms': watch.elapsedMilliseconds
      });
      _peerConnection!.onIceGatheringState = (state) => _logSupport(
          'support.ice.gathering',
          fields: {'ice_state': state.name});
      _peerConnection!.onIceConnectionState = (state) =>
          _logSupport('support.ice.state', fields: {'ice_state': state.name});
      _peerConnection!.onTrack =
          (event) => _logSupport('support.track.remote', fields: {
                'phase': event.track.kind == 'audio'
                    ? 'audio'
                    : event.track.kind == 'video'
                        ? 'video'
                        : 'unknown',
                'count': event.streams.length
              });
      _requireCaptureEpoch(epoch);

      // ICE кандидаты отправляются через серверный сигнальный шлюз оператору
      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
          _logSupport('support.candidate.local',
              fields: {'candidates': 1, 'result': 'generated'});
          _api?.sendSupportSignal(
            sessionId: _activeSessionId!,
            signal: {
              'candidate': {
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
              },
            },
          ).catchError((Object err) {
            _logSupport('support.async.failed',
                error: err, fields: {'operation': 'async_request'});
          });
        }
      };

      _peerConnection!.onConnectionState = (state) {
        _logSupport('support.pc.state', fields: {'pc_state': state.name});

        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _onP2pConnected();
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _onP2pDisconnected();
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _onP2pFailed();
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            // Активная сессия закрыта не нами (stopScreenSharing сам снимает
            // колбэки перед pc.close) — терминируем с ошибкой в UI.
            if (!_isStopping) {
              _p2pConnected = false;
              if (_state == SupportSessionState.active ||
                  _state == SupportSessionState.connecting) {
                _failSession(
                    _ownerSession
                        ? 'Соединение с вашим устройством закрыто'
                        : 'Соединение с инженером закрыто',
                    reason: 'pc_closed',
                    origin: 'pc_state');
              }
            }
            break;
          default:
            break;
        }
      };

      // Целевой узел является Offerer в WebRTC. Чтобы SDP Offer содержал
      // секцию m=application (SCTP), DataChannel обязан быть создан до вызова createOffer().
      try {
        final dcInit = RTCDataChannelInit()..ordered = true;
        final dc = await _peerConnection!.createDataChannel('control', dcInit);
        _requireCaptureEpoch(epoch);
        _setupDataChannel(dc);
      } catch (e) {
        _logSupport('support.capture.failed', error: e, fields: {
          'phase': phase,
          'duration_ms': watch.elapsedMilliseconds,
          'result': 'failed'
        });
      }
      _requireCaptureEpoch(epoch);

      _peerConnection!.onDataChannel = (channel) {
        _setupDataChannel(channel);
      };

      // Захват экрана: получение списка всех мониторов на десктопе.
      // Любой шаг захвата — с таймаутом 45с: на Linux XDG-portal (и после
      // закрытия TCC-диалога на macOS) getDisplayMedia-фьючерс может не
      // резолвиться и не падать неограниченно долго — сеанс висел
      // «подключение» часами (инцидент 2026-10-10, SOS к Linux).
      phase = 'capture_sources';
      _logSupport('support.capture.step',
          fields: {'phase': phase, 'result': 'begin'});
      MediaStream screenStream;
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        List<DesktopCapturerSource> sources = [];
        try {
          sources = await desktopCapturer.getSources(
              types: [SourceType.Screen]).timeout(const Duration(seconds: 45));
        } catch (e) {
          _logSupport('support.capture.failed', error: e, fields: {
            'phase': phase,
            'duration_ms': watch.elapsedMilliseconds,
            'result': 'failed'
          });
        }
        _requireCaptureEpoch(epoch);
        _logSupport('support.capture.sources',
            fields: {'count': sources.length});
        phase = 'get_display_media';
        if (sources.isNotEmpty) {
          _screens =
              sources.map((s) => _screenEntryForSource(s.id, s.name)).toList();
          final selectedSource = sources.first;
          _currentScreenId = selectedSource.id;
          _applyActiveScreenRect(selectedSource.id);

          const captureTimeout = Duration(seconds: 45);
          final wantLoopbackAudio =
              !kIsWeb && (Platform.isWindows || Platform.isLinux);
          try {
            screenStream =
                await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
              'audio': wantLoopbackAudio,
              'video': {
                'deviceId': {'exact': selectedSource.id},
                'cursor': 'always',
              },
            }).timeout(captureTimeout);
          } catch (error) {
            _logSupport('support.exception',
                error: error,
                fields: {'phase': 'start_screen_sharing', 'result': 'failed'});
            try {
              screenStream = await navigator.mediaDevices
                  .getDisplayMedia(<String, dynamic>{
                'audio': false,
                'video': {
                  'deviceId': {'exact': selectedSource.id},
                  'cursor': 'always',
                },
              }).timeout(captureTimeout);
            } catch (error) {
              _logSupport('support.exception', error: error, fields: {
                'phase': 'start_screen_sharing',
                'result': 'failed'
              });
              try {
                screenStream = await navigator.mediaDevices
                    .getDisplayMedia(<String, dynamic>{
                  'audio': false,
                  'video': {
                    'deviceId': selectedSource.id,
                    'cursor': 'always',
                  },
                }).timeout(captureTimeout);
              } catch (error) {
                _logSupport('support.exception', error: error, fields: {
                  'phase': 'start_screen_sharing',
                  'result': 'failed'
                });
                screenStream = await navigator.mediaDevices
                    .getDisplayMedia(<String, dynamic>{
                  'audio': false,
                  'video': true,
                }).timeout(captureTimeout);
              }
            }
          }
        } else {
          screenStream =
              await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
            'audio': false,
            'video': true,
          }).timeout(const Duration(seconds: 45));
        }
      } else {
        // Мобильные платформы и Web
        screenStream =
            await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': false,
          'video': true,
        }).timeout(const Duration(seconds: 60));
      }
      if (!kIsWeb && screenStream.getAudioTracks().isEmpty) {
        try {
          final micStream = await navigator.mediaDevices
              .getUserMedia(<String, dynamic>{
            'audio': true,
            'video': false
          }).timeout(const Duration(seconds: 5));
          for (final track in micStream.getAudioTracks()) {
            await screenStream.addTrack(track);
          }
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'start_screen_sharing', 'result': 'failed'});
        }
      }
      _localStream = screenStream;
      _logSupport('support.capture.ready', fields: {
        'tracks': screenStream.getTracks().length,
        'elapsed_ms': watch.elapsedMilliseconds,
        'width': _currentScreenRect?.width,
        'height': _currentScreenRect?.height
      });
      phase = 'add_tracks';
      _requireCaptureEpoch(epoch);

      for (final track in _localStream!.getVideoTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // m-6: видео экрана — читаемость текста важнее плавности
      await _applyVideoSenderTuning();
      _requireCaptureEpoch(epoch);

      // m-1: на macOS без Accessibility-разрешения инъекции ввода молча
      // игнорируются — честно подсказываем пользователю до начала сеанса.
      if (!kIsWeb &&
          Platform.isMacOS &&
          InputInjector.instance.macAccessibilityTrusted == false) {
        _addSystemMessage('⚠ Для удаленного управления разрешите Ligament 2FA: '
            'Системные настройки → Конфиденциальность и безопасность → Универсальный доступ');
        notifyListeners();
      }

      // Создаем и отправляем SDP Offer (M-1: state=active только после
      // onConnectionState==connected)
      phase = 'send_offer';
      await _sendOffer();
      _requireCaptureEpoch(epoch);
      _state = SupportSessionState.connecting;
      _armEstablishmentTimeouts();
      notifyListeners();
    } catch (e) {
      _logSupport('support.capture.failed', error: e, fields: {
        'phase': phase,
        'duration_ms': watch.elapsedMilliseconds,
        'result': 'failed'
      });

      await stopScreenSharing(reason: 'capture_failed', origin: 'capture');
      rethrow;
    }
  }

  int? _currentVideoBitrate;

  /// Применение битрейта к видео-потоку (B3.3).
  Future<void> _applyVideoBitrate(int bitrate) async {
    _currentVideoBitrate = bitrate;
    final pc = _peerConnection;
    if (pc == null) return;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings != null && encodings.isNotEmpty) {
          encodings.first.maxBitrate = bitrate;
          params.encodings = encodings;
        }
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        await sender.setParameters(params);

        break;
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'apply_video_bitrate', 'result': 'failed'});
    }
  }

  /// m-6: приоритет разрешения над частотой кадров и целевой битрейт ~2.5 Мбит
  /// для видеопотока экрана (текст/1С должны оставаться читаемыми при
  /// просадке канала).
  Future<void> _applyVideoSenderTuning() async {
    await _applyVideoBitrate(_currentVideoBitrate ?? 2500000);
  }

  /// Создание и отправка SDP Offer тем же сигнальным путём (HTTP-гейт).
  /// При [iceRestart] предварительно вызывается pc.restartIce(), чтобы
  /// libwebrtc сгенерировал новые ICE-учётные данные.
  Future<void> _sendOffer({bool iceRestart = false}) async {
    final watch = Stopwatch()..start();
    var phase = iceRestart ? 'ice_restart' : 'offer_create';
    _logSupport('support.offer', fields: {'phase': phase, 'result': 'begin'});
    final pc = _peerConnection;
    if (pc == null || _activeSessionId == null) return;
    try {
      if (iceRestart) {
        try {
          await pc.restartIce();
        } catch (e) {
          _logSupport('support.offer.failed', error: e, fields: {
            'phase': phase,
            'result': 'failed',
            'duration_ms': watch.elapsedMilliseconds
          });
        }
      }
      final offer = await pc.createOffer({
        'offerToReceiveVideo': 0,
        'offerToReceiveAudio': 0,
      });
      phase = 'set_local';
      await pc.setLocalDescription(offer);
      _logSupport('support.offer', fields: {
        'phase': phase,
        'result': 'ready',
        'elapsed_ms': watch.elapsedMilliseconds
      });
      phase = 'send_offer';
      await _api?.sendSupportSignal(
        sessionId: _activeSessionId!,
        signal: {
          'sdp': offer.toMap(),
        },
      );
      _logSupport('support.offer', fields: {
        'phase': phase,
        'result': _api == null ? 'blocked' : 'request_complete',
        'duration_ms': watch.elapsedMilliseconds
      });
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'send_offer', 'result': 'failed'});
    }
  }

  /// Таймауты установления: 30с с момента offer — повторный offer,
  /// 60с — завершение с ошибкой в UI.
  void _armEstablishmentTimeouts() {
    _establishmentTimer?.cancel();
    _establishmentTimer = Timer(const Duration(seconds: 30), () {
      if (_p2pConnected || _peerConnection == null) return;

      _attemptIceRestart();
    });
    _establishmentDeadlineTimer ??= Timer(const Duration(seconds: 60), () {
      if (_p2pConnected || _peerConnection == null) return;
      _failSession(
          _ownerSession
              ? 'Не удалось подключиться к вашему устройству (таймаут 60 с)'
              : 'Не удалось установить соединение с инженером (таймаут 60 с)',
          reason: 'establishment_timeout',
          origin: 'timeout');
    });
  }

  DateTime? _localLeaseDeadline;

  void _cancelEstablishmentTimers() {
    _establishmentTimer?.cancel();
    _establishmentTimer = null;
    _establishmentDeadlineTimer?.cancel();
    _establishmentDeadlineTimer = null;
    _disconnectedTimer?.cancel();
    _disconnectedTimer = null;
  }

  void _cancelResilienceTimers() {
    _cancelEstablishmentTimers();
    _leaseWatchdogTimer?.cancel();
    _leaseWatchdogTimer = null;
    _localLeaseDeadline = null;
    _desktopSwitchTimer?.cancel();
    _desktopSwitchTimer = null;
    _desktopRecoveryTimer?.cancel();
    _desktopRecoveryTimer = null;
  }

  void _startLeaseWatchdog() {
    _leaseWatchdogTimer?.cancel();
    // A-03: локальный предельный срок аренды на хосте (монотонное время).
    // При потере связи с сервером Core сессия принудительно прекращается.
    _localLeaseDeadline = DateTime.now().add(const Duration(seconds: 60));
    _leaseWatchdogTimer =
        Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_state != SupportSessionState.active ||
          _activeSessionId == null ||
          _api == null) {
        return;
      }

      if (_localLeaseDeadline != null &&
          DateTime.now().isAfter(_localLeaseDeadline!)) {
        _failSession(
            'Связь с сервером Ligament потеряна, срок аренды сеанса истёк',
            reason: 'lease_expired',
            origin: 'lease');
        return;
      }

      try {
        final sess = await _api!.getCurrentSupportSession();
        if (sess == null) {
          _failSession('Срок действия сеанса удаленного доступа истёк',
              reason: 'session_missing', origin: 'lease');
          return;
        }
        final status = sess['status']?.toString();
        if (status == 'completed' ||
            status == 'cancelled' ||
            status == 'rejected') {
          _failSession('Сеанс удаленной помощи завершен сервером',
              reason: 'server_ended', origin: 'lease');
          return;
        }
        // Подтверждение аренды успешно получено — продлеваем локальный дедлайн
        _localLeaseDeadline = DateTime.now().add(const Duration(seconds: 60));
      } catch (e) {
        _logSupport('support.exception',
            error: e,
            fields: {'phase': 'start_lease_watchdog', 'result': 'failed'});

        if (_localLeaseDeadline != null &&
            DateTime.now().isAfter(_localLeaseDeadline!)) {
          _failSession(
              'Связь с сервером Ligament потеряна, срок аренды сеанса истёк',
              reason: 'lease_expired',
              origin: 'lease');
        }
      }
    });
  }

  void _onP2pConnected() {
    _p2pConnected = true;
    _cancelEstablishmentTimers();
    _iceRestartAttempts = 0;
    _lastIceRestartAt = null;
    if (_state != SupportSessionState.active) {
      _state = SupportSessionState.active;
      _startPeriodicTelemetry();
      _startLeaseWatchdog();
      _startRecorder();
      _setWakelock(true);
      if (!kIsWeb && Platform.isWindows) {
        _startDesktopSwitchWatchdog();
      }
      notifyListeners();
    }
  }

  void _startDesktopSwitchWatchdog() {
    _desktopSwitchTimer?.cancel();
    _desktopSwitchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_p2pConnected &&
          _peerConnection != null &&
          !_isStopping &&
          !_switchingScreen) {
        if (InputInjector.instance.consumeDesktopChanged()) {
          final screenId = _currentScreenId ?? '0';
          _desktopRecoveryTimer?.cancel();
          _desktopRecoveryTimer = Timer(const Duration(milliseconds: 600), () {
            if (_p2pConnected && _peerConnection != null && !_isStopping) {
              unawaited(switchScreen(_currentScreenId ?? screenId));
            }
          });
        }
      }
    });
  }

  /// M-8: держим экран включенным, пока активна SOS-сессия (мобильные).
  void _setWakelock(bool enabled) {
    if (serviceHost) return;
    if (kIsWeb) return;
    try {
      if (enabled) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'set_wakelock', 'result': 'failed'});
    }
  }

  /// Disconnected: не убиваем шаринг сразу — транзиентные обрывы
  /// восстанавливаются сами; 10с без connected — ICE-рестарт.
  void _onP2pDisconnected() {
    _p2pConnected = false;
    if (_isStopping || _peerConnection == null) return;
    if (_state != SupportSessionState.active &&
        _state != SupportSessionState.connecting) {
      return;
    }
    _disconnectedTimer?.cancel();
    _disconnectedTimer = Timer(const Duration(seconds: 10), () {
      if (_p2pConnected || _peerConnection == null || _isStopping) return;

      _attemptIceRestart();
    });
  }

  /// Failed: pc.restartIce() + повторный offer тем же сигнальным путём,
  /// максимум 3 попытки с интервалом 5с, дальше — завершение с ошибкой.
  void _onP2pFailed() {
    _p2pConnected = false;
    if (_isStopping || _peerConnection == null) return;
    if (_state != SupportSessionState.active &&
        _state != SupportSessionState.connecting) {
      return;
    }
    _disconnectedTimer?.cancel();
    _attemptIceRestart();
  }

  void _attemptIceRestart({bool force = false, bool iceRestart = true}) {
    if (_isStopping || _peerConnection == null || _activeSessionId == null) {
      return;
    }
    if (force) {
      _iceRestartAttempts = 0;
      _lastIceRestartAt = DateTime.now();

      _sendOffer(iceRestart: iceRestart);
      _armEstablishmentTimeouts();
      return;
    }
    if (_iceRestartAttempts >= 3) {
      _failSession('Не удалось восстановить P2P-соединение после 3 попыток',
          reason: 'restart_exhausted', origin: 'ice_state');
      return;
    }
    final now = DateTime.now();
    final sinceLast =
        _lastIceRestartAt == null ? null : now.difference(_lastIceRestartAt!);
    if (sinceLast != null && sinceLast < const Duration(seconds: 5)) {
      final wait = const Duration(seconds: 5) - sinceLast;
      Timer(wait, () {
        if (!_p2pConnected && !_isStopping && _peerConnection != null) {
          _attemptIceRestart();
        }
      });
      return;
    }
    _iceRestartAttempts++;
    _logSupport('support.ice.restart',
        fields: {'attempt': _iceRestartAttempts, 'result': 'begin'});
    _lastIceRestartAt = now;

    _sendOffer(iceRestart: iceRestart);
  }

  /// Терминальный отказ сессии: остановка трансляции + ошибка в UI/чат.
  Future<void> _failSession(String userError,
      {String reason = 'unknown', String origin = 'unknown'}) async {
    _logSupport('support.session.failed',
        fields: {'reason': reason, 'origin': origin, 'result': 'stopping'});
    if (_isStopping) return;

    _lastError = userError;
    _cancelResilienceTimers();
    await stopScreenSharing(reason: reason, origin: origin);
    _state = SupportSessionState.ended;
    _addSystemMessage('⚠ $userError');
    notifyListeners();
  }

  void _addSystemMessage(String text, {String senderName = 'Система'}) {
    _chatMessages.add(SupportChatMessage(
      id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
      sender: 'user',
      senderName: senderName,
      text: text,
      timestamp: DateTime.now(),
    ));
    _unreadChatCount++;
    notifyListeners();
  }

  final List<RTCIceCandidate> _pendingCandidates = [];

  /// A-1 (аудит 2026-10-12, регрессия v1.1.38): типы команд, которые
  /// разрешено получать через сигнальный WS-канал (HTTP-шлюз сервера).
  /// Управление вводом (mouse_*/key_*/hotkey/text_input/block_input),
  /// буфер обмена, файловые передачи и reboot исполняются ТОЛЬКО из
  /// DTLS DataChannel — компрометация сигнального канала/сервера не
  /// должна давать RAT над рабочей станцией. Служебные WebRTC-кадры
  /// (sdp/offer/answer/candidate) сигналингу принадлежат по определению.
  /// Завершение сессии (session_ended/support_ended/console_end) —
  /// исключение fail-safe: команда только останавливает трансляцию
  /// (управления не даёт), а консоль шлёт её через WS при закрытии
  /// сессии — иначе экран транслировался бы ещё до 15с до срабатывания
  /// lease-watchdog.
  static const Set<String> signalingAllowedTypes = {
    'screen_list',
    'switch_screen',
    'chat_message',
    'session_ended',
    'support_ended',
    'console_end',
  };

  /// A-1: типы, которые handleRemoteInput реально исполняет (ввод/буфер/
  /// файлы/питание). Приход таких типов через сигналинг — попытка обойти
  /// транспортный гейт: игнорируем с warn-логом.
  static const Set<String> dataChannelOnlyTypes = {
    'mouse_move',
    'mouse_down',
    'mouse_up',
    'mouse_click',
    'click',
    'wheel',
    'mouse_wheel',
    'key_down',
    'key_up',
    'block_input',
    'hotkey',
    'text_input',
    'clipboard_set',
    'clipboard_get',
    'file_start',
    'file_chunk',
    'file_end',
    'file_reject',
    'file_ack',
    'video_quality',
    'reboot',
    'input_control',
  };

  /// Обработка сигнальных WebRTC пакетов от браузера оператора (Answer, Candidates)
  Future<void> handleRemoteSignal(Map<String, dynamic> signal) async {
    try {
      final payload = (signal['data'] is Map<String, dynamic>)
          ? signal['data'] as Map<String, dynamic>
          : signal;
      _logMessage(
          payload['type'] ??
              (payload.containsKey('candidate')
                  ? 'candidate'
                  : payload.containsKey('sdp')
                      ? 'sdp'
                      : null),
          'inbound_signal',
          'received');

      if (payload['type'] == 'chat_message') {
        handleRemoteInput(payload, origin: 'host_signal');
        return;
      }

      if (payload['type'] == 'input_control') {
        // A-1: обёртка input_control historically несёт команды управления.
        // Через сигналинг из неё разрешены только информационные типы;
        // ввод исполняется исключительно из DataChannel (DTLS).
        final inputData = (payload['data'] is Map<String, dynamic>)
            ? payload['data'] as Map<String, dynamic>
            : payload;
        final subType = inputData['type']?.toString();
        if (subType != null && signalingAllowedTypes.contains(subType)) {
          handleRemoteInput(inputData, origin: 'host_signal');
        } else {
          _logMessage(subType, 'signaling_gate', 'blocked');
        }
        return;
      }

      if (payload['type'] == 'screen_list' ||
          payload['type'] == 'switch_screen') {
        handleRemoteInput(payload, origin: 'host_signal');
        return;
      }

      // A-1: прочие сигнально-разрешённые типы (завершение сессии) —
      // маршрутизируем как раньше, они не дают управления.
      final directType = payload['type']?.toString();
      if (directType != null && signalingAllowedTypes.contains(directType)) {
        handleRemoteInput(payload, origin: 'host_signal');
        return;
      }

      // A-1: прямые команды управления через сигналинг — игнор + warn.
      // (мышка/клавиатура/буфер/файлы/reboot — только из DataChannel)
      if (directType != null && dataChannelOnlyTypes.contains(directType)) {
        _logMessage(directType, 'signaling_gate', 'blocked');

        return;
      }

      if (_peerConnection == null) return;

      if (payload['type'] == 'request_offer' ||
          payload['type'] == 'renegotiate') {
        if (_dataChannel == null ||
            _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
          try {
            final dcInit = RTCDataChannelInit()..ordered = true;
            final dc =
                await _peerConnection!.createDataChannel('control', dcInit);
            _setupDataChannel(dc);
          } catch (e) {
            _logSupport('support.exception',
                error: e,
                fields: {'phase': 'handle_remote_signal', 'result': 'failed'});
          }
        }
        final iceRestart = payload['iceRestart'] == true;
        _attemptIceRestart(force: true, iceRestart: iceRestart);
        return;
      }

      if (payload.containsKey('sdp')) {
        final sdpMap = payload['sdp'] as Map<String, dynamic>;
        final desc = RTCSessionDescription(
          sdpMap['sdp']?.toString(),
          sdpMap['type']?.toString(),
        );
        await _peerConnection!.setRemoteDescription(desc);
        while (_pendingCandidates.isNotEmpty) {
          final c = _pendingCandidates.removeAt(0);
          try {
            await _peerConnection!.addCandidate(c);
          } catch (e) {
            _logSupport('support.exception',
                error: e,
                fields: {'phase': 'handle_remote_signal', 'result': 'failed'});
          }
        }
      } else if (payload.containsKey('candidate')) {
        final cMap = payload['candidate'] as Map<String, dynamic>;
        final candidate = RTCIceCandidate(
          cMap['candidate']?.toString(),
          cMap['sdpMid']?.toString(),
          cMap['sdpMLineIndex'] as int?,
        );
        final remoteDesc = await _peerConnection!.getRemoteDescription();
        if (remoteDesc == null ||
            remoteDesc.type == null ||
            remoteDesc.type!.isEmpty) {
          _pendingCandidates.add(candidate);
        } else {
          await _peerConnection!.addCandidate(candidate);
        }
      }
      // Команды управления вводом (mouse_*/key_*/hotkey/block_input/
      // clipboard_*/file_*/switch_screen) исполняются ТОЛЬКО из WebRTC
      // DataChannel (DTLS) — см. _setupDataChannel. Серверный сигнальный
      // канал не является доверенным транспортом для инъекций ввода:
      // его компрометация не должна давать управление рабочей станцией.
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'handle_remote_signal', 'result': 'failed'});
    }
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    void handleState(RTCDataChannelState st) {
      _logSupport('support.dc.state', fields: {'dc_state': st.name});
      if (st == RTCDataChannelState.RTCDataChannelOpen) {
        _sendScreenList();
        _sendCurrentTelemetry();
      }
    }

    channel.onDataChannelState = handleState;
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      handleState(RTCDataChannelState.RTCDataChannelOpen);
    }
    channel.onMessage = (RTCDataChannelMessage msg) {
      if (msg.isBinary) return;
      try {
        final data = jsonDecode(msg.text) as Map<String, dynamic>;
        _logMessage(data['type'], 'inbound_dc', 'received',
            bytes: utf8.encode(msg.text).length);
        handleRemoteInput(data, origin: 'data_channel');
      } catch (e) {
        _logSupport('support.exception',
            error: e, fields: {'phase': 'handle_state', 'result': 'failed'});
      }
    };
  }

  /// Запись списка экранов с геометрией каждого монитора (rect в координатах
  /// виртуального рабочего стола), если она разрешается по id источника.
  Map<String, dynamic> _screenEntryForSource(String id, String name) {
    final entry = <String, dynamic>{'id': id, 'name': name};
    final rect = _resolveScreenRect(id);
    if (rect != null) {
      entry['rect'] = rect.toJson();
    }
    return entry;
  }

  ScreenRect? _resolveScreenRect(String sourceId) {
    try {
      return InputInjector.instance.getMonitorRectForSource(sourceId);
    } catch (error) {
      _logSupport('support.exception',
          error: error,
          fields: {'phase': 'screen_entry_for_source', 'result': 'failed'});
      return null;
    }
  }

  /// Устанавливает геометрию активного транслируемого монитора в инжекторе
  /// ввода: нормализованные координаты оператора маппятся в этот rect,
  /// а не в primary-монитор.
  void _applyActiveScreenRect(String sourceId) {
    final rect = _resolveScreenRect(sourceId);
    _currentScreenRect = rect;
    InputInjector.instance.setActiveMonitorRect(rect);
  }

  Future<void> _sendScreenList() async {
    try {
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        try {
          final sources =
              await desktopCapturer.getSources(types: [SourceType.Screen]);
          if (sources.isNotEmpty) {
            _screens = sources
                .map((s) => _screenEntryForSource(s.id, s.name))
                .toList();
          }
        } catch (e) {
          _logSupport('support.exception',
              error: e,
              fields: {'phase': 'send_screen_list', 'result': 'failed'});
        }
      }
      final payload = {
        'type': 'screen_list',
        'screens': _screens,
        'selected_id': _currentScreenId,
        if (_currentScreenRect != null)
          'selected_rect': _currentScreenRect!.toJson(),
        if (!kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          'virtual_desktop':
              InputInjector.instance.getVirtualDesktopRect().toJson(),
      };
      if (_dataChannel != null &&
          _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        final text = jsonEncode(payload);
        _observeDataEnqueue(_dataChannel!.send(RTCDataChannelMessage(text)),
            payload['type'], utf8.encode(text).length);
      }
      if (_activeSessionId != null && _api != null) {
        _api!
            .sendSupportSignal(
          sessionId: _activeSessionId!,
          signal: payload,
        )
            .catchError((Object error) {
          _logSupport('support.async.failed',
              error: error, fields: {'operation': 'send_signal'});
          return null;
        });
      }
    } catch (error) {
      _logSupport('support.exception',
          error: error,
          fields: {'phase': 'send_screen_list', 'result': 'failed'});
    }
  }

  /// Переключение транслируемого монитора на лету с сохранением аудио и защитой от падений
  Future<void> switchScreen(String screenId) async {
    if (kIsWeb || _peerConnection == null || _switchingScreen) return;
    _switchingScreen = true;
    try {
      MediaStream? newStream;
      for (var attempt = 0; attempt < 6; attempt++) {
        if (_peerConnection == null || _isStopping) return;
        try {
          try {
            newStream =
                await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
              'audio': false,
              'video': {
                'deviceId': {'exact': screenId},
                'cursor': 'always',
              },
            }).timeout(const Duration(seconds: 4));
          } catch (error) {
            _logSupport('support.exception',
                error: error,
                fields: {'phase': 'switch_screen', 'result': 'failed'});
            newStream =
                await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
              'audio': false,
              'video': {
                'deviceId': screenId,
                'cursor': 'always',
              },
            }).timeout(const Duration(seconds: 4));
          }
          if (newStream.getVideoTracks().isNotEmpty) {
            break;
          }
        } catch (e) {
          _logSupport('support.exception',
              error: e, fields: {'phase': 'switch_screen', 'result': 'failed'});

          if (attempt < 5) {
            await Future<void>.delayed(
                Duration(milliseconds: 200 * (attempt + 1)));
          }
        }
      }

      if (newStream == null) {
        _desktopRecoveryTimer?.cancel();
        _desktopRecoveryTimer = Timer(const Duration(milliseconds: 1500), () {
          if (_p2pConnected && _peerConnection != null && !_isStopping) {
            unawaited(switchScreen(screenId));
          }
        });
        return;
      }

      final newVideoTracks = newStream.getVideoTracks();
      if (newVideoTracks.isEmpty) return;
      final newTrack = newVideoTracks.first;

      final senders = await _peerConnection!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(newTrack);
          break;
        }
      }

      final oldStream = _localStream;
      final existingAudioTracks = oldStream?.getAudioTracks() ?? [];

      oldStream?.getVideoTracks().forEach((t) {
        try {
          t.stop();
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'switch_screen', 'result': 'failed'});
        }
      });

      // Сохраняем аудиотрек системы, не вызывая dispose() у потока с аудио
      if (existingAudioTracks.isNotEmpty) {
        _audioStream ??= oldStream;
      } else {
        try {
          oldStream?.dispose();
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'switch_screen', 'result': 'failed'});
        }
      }

      _localStream = newStream;
      _currentScreenId = screenId;
      _applyActiveScreenRect(screenId);

      // Если аудио изначально не было получено (на экране блокировки/Winlogon),
      // пытаемся захватить loopback после входа в сессию пользователя
      final hasAudio = existingAudioTracks.isNotEmpty ||
          (_audioStream != null && _audioStream!.getAudioTracks().isNotEmpty);
      if (!hasAudio && !kIsWeb && (Platform.isWindows || Platform.isLinux)) {
        try {
          final loopback =
              await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
            'audio': true,
            'video': false,
          }).timeout(const Duration(seconds: 3));
          final newAudios = loopback.getAudioTracks();
          if (newAudios.isNotEmpty && _peerConnection != null) {
            final curSenders = await _peerConnection!.getSenders();
            RTCRtpSender? audioSender;
            for (final s in curSenders) {
              if (s.track?.kind == 'audio') {
                audioSender = s;
                await s.replaceTrack(newAudios.first);
                break;
              }
            }
            if (audioSender == null) {
              await _peerConnection!.addTrack(newAudios.first, loopback);
            }
            _audioStream = loopback;
          }
        } catch (e) {
          _logSupport('support.exception',
              error: e, fields: {'phase': 'switch_screen', 'result': 'failed'});
        }
      }

      await _sendScreenList();
      notifyListeners();
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'switch_screen', 'result': 'failed'});
    } finally {
      _switchingScreen = false;
    }
  }

  void _startPeriodicTelemetry() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _sendCurrentTelemetry();
    });
  }

  Future<void> _sendCurrentTelemetry() async {
    if (serviceHost) return;
    if (_dataChannel == null ||
        _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    try {
      final cpu = await _telemetry.collectCpuMetrics();
      final disk = await _telemetry.collectDiskMetrics();
      final payload = {
        'type': 'telemetry',
        ...cpu,
        ...disk,
      };
      final text = jsonEncode(payload);
      _observeDataEnqueue(_dataChannel!.send(RTCDataChannelMessage(text)),
          payload['type'], utf8.encode(text).length);
    } catch (error) {
      _logSupport('support.exception',
          error: error,
          fields: {'phase': 'send_current_telemetry', 'result': 'failed'});
    }
  }

  void _startRecorder() {
    final sid = _activeSessionId;
    final api = _api;
    if (sid == null || sid.isEmpty || api == null) return;
    try {
      final base = api.baseUrl;
      final ingestUrl = '$base/api/v1/link/sessions/$sid/recorder/batch';
      _recorder?.stop(reason: 'restarted');
      _recorder = LinkHostRecorder(
        sessionId: sid,
        config: LinkRecordingConfig(
          enabled: true,
          effectiveMode: 'record+AI',
          ingestUrl: ingestUrl,
          ingestToken: api.token ?? '',
          leaseTtl: const Duration(seconds: 45),
          maxAckLag: const Duration(seconds: 30),
        ),
      );
      _recorder?.start();

      unawaited(_captureRecorderSnapshot('keyframe'));
      _recorderSnapshotTimer?.cancel();
      _recorderSnapshotTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => unawaited(_captureRecorderSnapshot('periodic')),
      );
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'start_recorder', 'result': 'failed'});
    }
  }

  void _stopRecorder() {
    _recorderSnapshotTimer?.cancel();
    _recorderSnapshotTimer = null;
    final rec = _recorder;
    _recorder = null;
    if (rec != null) {
      unawaited(rec.stop(reason: 'session_ended'));
    }
  }

  Future<void> _captureRecorderSnapshot(String frameKind) async {
    final rec = _recorder;
    if (rec == null ||
        _capturingRecorderFrame ||
        _state != SupportSessionState.active) {
      return;
    }
    _capturingRecorderFrame = true;
    try {
      final srcId = _currentScreenId ?? '0';
      Uint8List? bytes;

      // 1. Приоритетный захват на Windows через Win32 GDI (не конфликтует с DXGI)
      if (!kIsWeb && Platform.isWindows) {
        try {
          bytes = InputInjector.instance
              .captureDesktopBmp(maxWidth: 1280, maxHeight: 720);
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'capture_recorder_snapshot_gdi', 'result': 'failed'});
        }
      }

      // 2. Штатный запрос миниатюры через WebRTC (macOS/Linux или фоллбэк)
      if (bytes == null) {
        try {
          final raw = await WebRTC.invokeMethod(
            'getDesktopSourceThumbnail',
            <String, dynamic>{
              'sourceId': srcId,
              'thumbnailSize': {'width': 1280, 'height': 720},
            },
          ).timeout(const Duration(seconds: 2));
          if (raw is Uint8List && raw.isNotEmpty) {
            bytes = raw;
          }
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'capture_recorder_snapshot', 'result': 'failed'});
        }
      }
      if (bytes != null &&
          bytes.isNotEmpty &&
          _state == SupportSessionState.active) {
        final frameInfo = await prepareRecordedFrame(bytes);
        if (frameInfo != null) {
          rec.enqueueFrame(
            frameKind: frameKind,
            payload: frameInfo.payload,
            monitorId: srcId,
            width: frameInfo.width,
            height: frameInfo.height,
            codec: frameInfo.codec,
          );
        }
      }
    } catch (error) {
      _logSupport('support.exception',
          error: error,
          fields: {'phase': 'capture_recorder_snapshot', 'result': 'failed'});
    } finally {
      _capturingRecorderFrame = false;
    }
  }

  /// Начало входящей файловой передачи: проверка лимитов размера и числа
  /// одновременных закачек, запуск таймаута ожидания первого чанка.
  void _handleFileStart(Map<String, dynamic> input) {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    if (transferId.isEmpty) return;
    final filename = input['filename']?.toString() ??
        'file_${DateTime.now().millisecondsSinceEpoch}';
    final size = (input['size'] as num?)?.toInt() ?? 0;
    final totalChunks = (input['total_chunks'] as num?)?.toInt() ?? 1;

    if (size < 0 || size > _maxFileTransferBytes) {
      return;
    }
    if (totalChunks <= 0) return;
    if (_activeDownloads.length >= _maxConcurrentDownloads) {
      return;
    }

    // Повторный file_start с тем же transferId перезаписывает предыдущую попытку
    _activeDownloads.remove(transferId)?.stallTimer?.cancel();

    final dl = _ActiveFileDownload(
      id: transferId,
      filename: filename,
      totalSize: size,
      totalChunks: totalChunks,
      expectedChecksum: input['checksum']?.toString(),
    );
    dl.stallTimer = Timer(_downloadStallTimeout, () {
      _abortDownload(transferId,
          'таймаут ожидания данных ${_downloadStallTimeout.inSeconds}с');
    });
    _activeDownloads[transferId] = dl;
  }

  /// Прием чанка: валидация, контроль фактически полученного объема и
  /// перезапуск таймаута ожидания следующего чанка. Битый base64 —
  /// закачка отменяется с сообщением об ошибке (M-3).
  void _handleFileChunk(Map<String, dynamic> input) {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final chunkIndex = (input['chunk_index'] as num?)?.toInt() ?? 0;
    final base64Data = input['data']?.toString() ?? '';
    final dl = _activeDownloads[transferId];
    if (dl == null || base64Data.isEmpty) return;

    try {
      final bytes = base64Decode(base64Data);
      if (chunkIndex < 0 || chunkIndex >= dl.totalChunks) {
        return;
      }
      if (!dl.chunks.containsKey(chunkIndex)) {
        dl.receivedBytes += bytes.length;
      }
      // Защита от заниженного size в file_start
      if (dl.receivedBytes > _maxFileTransferBytes) {
        _abortDownload(transferId, 'фактический объем превысил лимит 50 МБ');
        return;
      }
      dl.chunks[chunkIndex] = bytes;

      dl.stallTimer?.cancel();
      dl.stallTimer = Timer(_downloadStallTimeout, () {
        _abortDownload(transferId,
            'таймаут ожидания данных ${_downloadStallTimeout.inSeconds}с');
      });
    } catch (e) {
      _logSupport('support.exception',
          error: e, fields: {'phase': 'handle_file_chunk', 'result': 'failed'});

      _abortDownload(transferId, 'поврежденные данные (чанк $chunkIndex)');
      _notifyFileRejected(
          transferId, dl.filename, 'поврежденные данные при передаче');
      _addSystemMessage(
          '⚠ Файл "${dl.filename}" не получен: поврежденные данные при передаче');
      notifyListeners();
    }
  }

  /// Завершение передачи: проверка полноты (все индексы 0..totalChunks-1)
  /// и целостности (sha256), только после этого — сохранение (M-3).
  void _handleFileEnd(Map<String, dynamic> input) {
    final transferId =
        input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final dl = _activeDownloads.remove(transferId);
    dl?.stallTimer?.cancel();
    if (dl == null) return;

    // file_end может нести checksum повторно — приоритет у него.
    final endChecksum = input['checksum']?.toString();
    final checksum = (endChecksum != null && endChecksum.isNotEmpty)
        ? endChecksum
        : dl.expectedChecksum;

    final result = assembleFileChunks(
      dl.chunks,
      dl.totalChunks,
      expectedSize: dl.totalSize > 0 ? dl.totalSize : null,
      expectedChecksum: checksum,
    );
    if (result.isOk) {
      _saveReceivedFile(dl, result.bytes!);
      return;
    }

    String reason;
    switch (result.error) {
      case 'incomplete':
        reason = 'передача неполная (не все чанки дошли)';
        break;
      case 'size_mismatch':
        reason = 'несовпадение размера файла';
        break;
      case 'checksum_mismatch':
        reason = 'несовпадение контрольной суммы';
        break;
      default:
        reason = result.error ?? 'неизвестная ошибка';
    }
    // Сообщение об ошибке обеим сторонам: локально + обратно отправителю.
    _addSystemMessage('⚠ Файл "${dl.filename}" не сохранен: $reason');
    _sendFileAck(transferId, ok: false);
    _notifyFileRejected(transferId, dl.filename, reason);
    notifyListeners();
  }

  /// Уведомляет отправителя (консоль оператора / приложение) об отбраковке
  /// файла, чтобы и у него в чате появилось сообщение об ошибке.
  void _notifyFileRejected(String transferId, String filename, String reason) {
    try {
      _sendSignalOrData({
        'type': 'file_reject',
        'transfer_id': transferId,
        'filename': filename,
        'reason': reason,
      });
    } catch (error) {
      _logSupport('support.exception',
          error: error,
          fields: {'phase': 'notify_file_rejected', 'result': 'failed'});
      // DataChannel закрыт — уведомление не критично
    }
  }

  /// Эмуляция пользовательского ввода от оператора (мышь/клавиатура/хоткеи/буфер)
  ///
  /// A-1: вызывается ТОЛЬКО из доверенных транспортов — DataChannel
  /// (DTLS, см. _setupDataChannel) и сигнального канала после фильтра
  /// handleRemoteSignal (signalingAllowedTypes). Публичное имя нужно
  /// только тестам транспортного гейта.
  @visibleForTesting
  Future<void> handleRemoteInput(Map<String, dynamic> input,
      {String origin = 'unknown'}) async {
    final type = (input['type'] ?? input['action'])?.toString();
    _logMessage(type, 'input_dispatch', 'received');
    if (type != 'mouse_move') {
      _logSupport('support.input.origin', fields: {
        'origin': origin,
        'message_type': supportDebugMessageType(type)
      });
    }
    if (type == null) return;
    if (serviceHost && !serviceHostCommandAllowed(type)) {
      _logMessage(type, 'service_gate', 'blocked');
      return;
    }

    if (type == 'session_ended' ||
        type == 'support_ended' ||
        type == 'console_end') {
      await stopScreenSharing(reason: 'remote_ended', origin: origin);
      return;
    }

    // Гейт режима «Только просмотр» (view_only): разрешены список экранов,
    // чат и ПЕРЕКЛЮЧЕНИЕ транслируемого монитора (m-5: просмотр нескольких
    // мониторов не дает управления). Ввод, буфер обмена и файловые передачи
    // блокируются ДО какой-либо обработки команды.
    final isViewOnly = _accessMode.toLowerCase().trim() == 'view_only';
    if (isViewOnly &&
        type != 'screen_list' &&
        type != 'chat_message' &&
        type != 'switch_screen') {
      _logMessage(type, 'view_only_gate', 'blocked');
      return;
    }

    _recorder?.observeControlInput(input);
    if (type == 'mouse_down' || type == 'key_down' || type == 'text_input') {
      unawaited(_captureRecorderSnapshot('activity'));
    }

    if (serviceHost && (type == 'clipboard_set' || type == 'clipboard_get')) {
      try {
        await serviceInput?.call({'type': 'clipboard_probe'});
      } catch (error) {
        _logSupport('support.exception',
            error: error,
            fields: {'phase': 'handle_remote_input', 'result': 'failed'});
        _sendSignalOrData(
            {'type': 'clipboard_error', 'reason': 'secure_desktop'});
        return;
      }
    }

    if (type == 'screen_list') {
      await _sendScreenList();
      return;
    } else if (type == 'chat_message') {
      try {
        final chatMsg = SupportChatMessage.fromJson(input);
        final isDuplicate = _chatMessages.any((m) =>
            m.id == chatMsg.id ||
            (chatMsg.clientId.isNotEmpty && m.clientId == chatMsg.clientId) ||
            (m.sender == chatMsg.sender &&
                m.text == chatMsg.text &&
                m.timestamp.difference(chatMsg.timestamp).abs().inSeconds < 5));
        if (!isDuplicate) {
          _chatMessages.add(chatMsg);
          _chatMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          if (chatMsg.sender != 'user') {
            _unreadChatCount++;
          }
          notifyListeners();
          if (chatMsg.sender != 'user') {
            onChatMessageReceived?.call(chatMsg);
          }
        }
      } catch (e) {
        _logSupport('support.exception',
            error: e,
            fields: {'phase': 'handle_remote_input', 'result': 'failed'});
      }
      return;
    } else if (type == 'switch_screen') {
      final sId = input['screen_id']?.toString();
      if (sId != null && sId.isNotEmpty) {
        await switchScreen(sId);
      }
      return;
    } else if (type == 'clipboard_set') {
      final text = input['text']?.toString() ?? '';
      if (text.length > 65536) return;
      await Clipboard.setData(ClipboardData(text: text));
      final sysMsg = SupportChatMessage(
        id: 'sys_clip_${DateTime.now().millisecondsSinceEpoch}',
        sender: 'operator',
        senderName: 'Система',
        text: '📋 Оператор вставил текст в буфер обмена',
        timestamp: DateTime.now(),
      );
      _chatMessages.add(sysMsg);
      _unreadChatCount++;
      notifyListeners();
      return;
    } else if (type == 'clipboard_get') {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (_dataChannel != null &&
          _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        final encoded =
            jsonEncode({'type': 'clipboard_data', 'text': clip?.text ?? ''});
        _observeDataEnqueue(_dataChannel!.send(RTCDataChannelMessage(encoded)),
            'clipboard_data', utf8.encode(encoded).length);
        final sysMsg = SupportChatMessage(
          id: 'sys_clip_${DateTime.now().millisecondsSinceEpoch}',
          sender: 'operator',
          senderName: 'Система',
          text: '📋 Оператор скопировал текст из буфера обмена',
          timestamp: DateTime.now(),
        );
        _chatMessages.add(sysMsg);
        _unreadChatCount++;
        notifyListeners();
      }
      return;
    } else if (type == 'file_start') {
      _handleFileStart(input);
      return;
    } else if (type == 'file_chunk') {
      _handleFileChunk(input);
      return;
    } else if (type == 'file_end') {
      _handleFileEnd(input);
      return;
    } else if (type == 'file_reject') {
      // M-3: получатель отбраковал файл (неполный/битый) — ошибка в чат
      // отправителю (обе стороны видят один и тот же инцидент).
      final filename = input['filename']?.toString() ?? 'файл';
      final reason = input['reason']?.toString() ?? 'передача не удалась';
      _addSystemMessage('⚠ Файл "$filename" не доставлен: $reason');
      notifyListeners();
      return;
    } else if (type == 'video_quality') {
      final quality = input['quality']?.toString() ?? 'balanced';
      final int bitrate;
      switch (quality) {
        case 'best':
          bitrate = 4000000;
          break;
        case 'low':
          bitrate = 800000;
          break;
        case 'balanced':
        default:
          bitrate = (input['bitrate'] as num?)?.toInt() ?? 2500000;
          break;
      }
      _applyVideoBitrate(bitrate);
      return;
    } else if (type == 'reboot') {
      _handleRemoteReboot();
      return;
    }

    if (serviceHost) {
      final inject = serviceInput;
      if (inject == null) return;
      try {
        final now = DateTime.now();
        final checkMouse = type == 'mouse_move' &&
            now.difference(_lastMouseCheck).inMilliseconds >= 500;
        if (checkMouse) _lastMouseCheck = now;
        await inject({
          ...input,
          if (checkMouse) 'ack': true,
          'type': type,
          if (input['screen_rect'] != null)
            'screen_rect': input['screen_rect']
          else if (_currentScreenRect != null)
            'screen_rect': _currentScreenRect!.toJson(),
        });
        if (type == 'block_input') {
          _sendSignalOrData(
              {'type': 'block_input_ack', 'blocked': input['blocked'] == true});
        }
      } catch (error) {
        _logSupport('support.exception',
            error: error,
            fields: {'phase': 'handle_remote_input', 'result': 'failed'});
        if (type == 'block_input') {
          _sendSignalOrData({
            'type': 'block_input_ack',
            'blocked': false,
            'error': 'input_rejected'
          });
          return;
        }
        final now = DateTime.now();
        if (now.difference(_lastInputError).inSeconds >= 3) {
          _lastInputError = now;
          _sendSignalOrData({
            'type': 'input_error',
            'command': type,
            'reason': 'windows_input_rejected'
          });
        }
      }
      return;
    }

    try {
      switch (type) {
        case 'text_input':
          final text = input['text'];
          if (text is! String || text.length > 4096) return;
          if (!kIsWeb && Platform.isWindows) {
            for (int i = 0; i < text.length; i++) {
              InputInjector.instance
                  .keyAction(action: 'down', key: text[i], char: text[i]);
              InputInjector.instance
                  .keyAction(action: 'up', key: text[i], char: text[i]);
            }
          } else if (!kIsWeb && Platform.isMacOS) {
            await Clipboard.setData(ClipboardData(text: text));
            await InputInjector.instance.triggerHotkey('cmd_v');
          } else if (!kIsWeb && Platform.isLinux) {
            Process.run('xdotool', ['type', '--', text]);
          } else {
            await Clipboard.setData(ClipboardData(text: text));
            await InputInjector.instance.triggerHotkey('ctrl_v');
          }
          break;
        case 'mouse_move':
          final x = (input['x'] as num?)?.toDouble() ?? 0.0;
          final y = (input['y'] as num?)?.toDouble() ?? 0.0;
          final explicitRect = input['screen_rect'] is Map
              ? ScreenRect.fromJson(
                  Map<String, dynamic>.from(input['screen_rect'] as Map))
              : null;
          InputInjector.instance.moveMouse(x, y, screenRect: explicitRect);
          break;
        case 'mouse_down':
        case 'mouse_up':
        case 'mouse_click':
        case 'click':
          final btn = (input['button'] as num?)?.toInt() ?? 0;
          final x = (input['x'] as num?)?.toDouble() ?? 0.0;
          final y = (input['y'] as num?)?.toDouble() ?? 0.0;
          final act = type == 'mouse_down'
              ? 'down'
              : (type == 'mouse_up' ? 'up' : 'click');
          final explicitRect = input['screen_rect'] is Map
              ? ScreenRect.fromJson(
                  Map<String, dynamic>.from(input['screen_rect'] as Map))
              : null;
          InputInjector.instance.mouseAction(
              action: act,
              button: btn,
              normX: x,
              normY: y,
              screenRect: explicitRect);
          break;
        case 'wheel':
        case 'mouse_wheel':
          final dy = (input['deltaY'] as num?)?.toDouble() ?? 0.0;
          InputInjector.instance.mouseWheel(dy);
          break;
        case 'key_down':
        case 'key_up':
          final key = input['key']?.toString() ?? '';
          final code = (input['keyCode'] as num?)?.toInt();
          final char = input['char']?.toString();
          final act = type == 'key_down' ? 'down' : 'up';
          InputInjector.instance
              .keyAction(action: act, key: key, keyCode: code, char: char);
          break;
        case 'block_input':
          final blocked = input['blocked'] == true || input['enabled'] == true;
          InputInjector.instance.setInputBlocked(blocked);
          _sendSignalOrData({'type': 'block_input_ack', 'blocked': blocked});
          break;
        case 'hotkey':
          final hotkey = (input['action'] ?? input['hotkey'] ?? input['key'])
                  ?.toString() ??
              '';
          if (hotkey.isNotEmpty) {
            await InputInjector.instance.triggerHotkey(hotkey);
          }
          break;
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'handle_remote_input', 'result': 'failed'});

      final now = DateTime.now();
      if (now.difference(_lastInputError).inSeconds >= 3) {
        _lastInputError = now;
        _sendSignalOrData(
            {'type': 'input_error', 'command': type, 'reason': e.toString()});
      }
    }
  }

  void _handleRemoteReboot() {
    try {
      if (!kIsWeb && Platform.isWindows) {
        Process.run('shutdown', [
          '/r',
          '/t',
          '5',
          '/f',
          '/c',
          'Reboot requested by remote operator'
        ]);
      } else if (!kIsWeb && Platform.isLinux) {
        Process.run('systemctl', ['reboot']).catchError((Object error) {
          _logSupport('support.async.failed',
              error: error, fields: {'operation': 'async_request'});
          return Process.run('shutdown', ['-r', 'now']);
        });
      } else if (!kIsWeb && Platform.isMacOS) {
        Process.run('shutdown', ['-r', 'now']);
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'handle_remote_reboot', 'result': 'failed'});
    }
  }

  bool _isStopping = false;

  /// Остановка трансляции экрана и освобождение ресурсов (асинхронно, с защитой от рекурсии)
  Future<void> stopScreenSharing(
      {String reason = 'unknown', String origin = 'unknown'}) async {
    _flushMouseDiagnostics();
    _logSupport('support.capture.stop', fields: {
      'reason': reason,
      'origin': origin,
      'result': _isStopping ? 'ignored' : 'begin'
    });
    ++_captureEpoch;
    if (_isStopping) return;
    _isStopping = true;
    final endedSessionId = _activeSessionId;
    final api = _api;

    try {
      // 1. Немедленно освобождаем мышь и ввод пользователя
      if (serviceHost) {
        try {
          await serviceReleaseInput?.call();
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      } else {
        InputInjector.instance.setInputBlocked(false);
        InputInjector.instance.releaseAllPressed();
      }
      _setWakelock(false);

      _telemetryTimer?.cancel();
      _telemetryTimer = null;
      _cancelResilienceTimers();
      _p2pConnected = false;
      _iceRestartAttempts = 0;
      _lastIceRestartAt = null;

      _stopRecorder();

      _pendingCandidates.clear();

      // Немедленно переводим статус в idle, чтобы UI обновился мгновенно
      _state = SupportSessionState.idle;
      _activeSessionId = null;
      _category = null;
      _problemSummary = null;
      _ownerSession = false;
      _ownerInitiatorDevice = null;
      _linkHosted = false;
      _screens.clear();
      _currentScreenId = null;
      _currentScreenRect = null;
      InputInjector.instance.setActiveMonitorRect(null);
      _cancelAllDownloads();
      notifyListeners();

      // 2. Закрываем DataChannel и снимаем его обработчики
      final dc = _dataChannel;
      _dataChannel = null;
      if (dc != null) {
        try {
          if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
            final text = jsonEncode({'type': 'session_ended'});
            final send = dc.send(RTCDataChannelMessage(text));
            final fields = <String, Object?>{
              'session_id': endedSessionId,
              'message_type': 'session_ended',
              'bytes': utf8.encode(text).length
            };
            _logSupport('support.session.end_send',
                fields: {...fields, 'result': 'requested'});
            unawaited(send.then((_) {
              _logSupport('support.session.end_send',
                  fields: {...fields, 'result': 'queued'});
            }).catchError((Object error) {
              _logSupport('support.session.end_send',
                  error: error, fields: {...fields, 'result': 'failed'});
            }));
          }
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
        try {
          dc.onMessage = null;
          dc.onDataChannelState = null;
          await dc.close().timeout(const Duration(milliseconds: 300),
              onTimeout: () {
            _logSupport('support.cleanup.timeout',
                fields: {'operation': 'cleanup', 'result': 'timeout'});
            return null;
          });
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }
      if (endedSessionId != null && api != null) {
        try {
          unawaited(api.sendSupportSignal(
            sessionId: endedSessionId,
            signal: const {'type': 'session_ended'},
          ).catchError((Object error) {
            _logSupport('support.async.failed',
                error: error, fields: {'operation': 'async_request'});
          }));
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }

      // 3. Закрываем PeerConnection ПЕРЕД остановкой треков, чтобы остановить RTP sender threads в libwebrtc
      final pc = _peerConnection;
      _peerConnection = null;
      if (pc != null) {
        try {
          pc.onIceCandidate = null;
          pc.onConnectionState = null;
          pc.onTrack = null;
          pc.onDataChannel = null;
          pc.onIceConnectionState = null;
          pc.onRenegotiationNeeded = null;
          await pc.close().timeout(const Duration(milliseconds: 300),
              onTimeout: () {
            _logSupport('support.cleanup.timeout',
                fields: {'operation': 'cleanup', 'result': 'timeout'});
            return null;
          });
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }

      // 4. Останавливаем все медиатреки захвата экрана и аудио
      _desktopSwitchTimer?.cancel();
      _desktopSwitchTimer = null;
      _desktopRecoveryTimer?.cancel();
      _desktopRecoveryTimer = null;

      final stream = _localStream;
      _localStream = null;
      if (stream != null) {
        try {
          for (final track in stream.getTracks()) {
            try {
              await track.stop().timeout(const Duration(milliseconds: 300),
                  onTimeout: () {
                _logSupport('support.cleanup.timeout',
                    fields: {'operation': 'cleanup', 'result': 'timeout'});
                return null;
              });
            } catch (error) {
              _logSupport('support.exception',
                  error: error,
                  fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
            }
          }
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }

      final audioStr = _audioStream;
      _audioStream = null;
      if (audioStr != null) {
        try {
          for (final track in audioStr.getTracks()) {
            try {
              await track.stop().timeout(const Duration(milliseconds: 300),
                  onTimeout: () {
                _logSupport('support.cleanup.timeout',
                    fields: {'operation': 'cleanup', 'result': 'timeout'});
                return null;
              });
            } catch (error) {
              _logSupport('support.exception',
                  error: error,
                  fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
            }
          }
          await audioStr.dispose().timeout(const Duration(milliseconds: 300),
              onTimeout: () {
            _logSupport('support.cleanup.timeout',
                fields: {'operation': 'cleanup', 'result': 'timeout'});
            return null;
          });
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }

      // 5. Окончательное освобождение нативных дескрипторов
      try {
        await stream?.dispose().timeout(const Duration(milliseconds: 300),
            onTimeout: () {
          _logSupport('support.cleanup.timeout',
              fields: {'operation': 'cleanup', 'result': 'timeout'});
          return null;
        });
      } catch (error) {
        _logSupport('support.exception',
            error: error,
            fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
      }
      try {
        await pc?.dispose().timeout(const Duration(milliseconds: 300),
            onTimeout: () {
          _logSupport('support.cleanup.timeout',
              fields: {'operation': 'cleanup', 'result': 'timeout'});
          return null;
        });
      } catch (error) {
        _logSupport('support.exception',
            error: error,
            fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
      }
    } catch (e) {
      _logSupport('support.exception',
          error: e,
          fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
    } finally {
      _isStopping = false;
      if (serviceHost) {
        try {
          serviceReleaseInput?.call();
        } catch (error) {
          _logSupport('support.exception',
              error: error,
              fields: {'phase': 'stop_screen_sharing', 'result': 'failed'});
        }
      }
      InputInjector.instance.setInputBlocked(false);
      InputInjector.instance.releaseAllPressed();
    }
  }

  @override
  void dispose() {
    stopScreenSharing();
    super.dispose();
  }
}
