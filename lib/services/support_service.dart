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

class SupportChatMessage {
  final String id;
  final String sender; // 'operator' | 'user'
  final String senderName;
  final String text;
  final DateTime timestamp;

  SupportChatMessage({
    required this.id,
    required this.sender,
    required this.senderName,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'type': 'chat_message',
    'id': id,
    'sender': sender,
    'sender_name': senderName,
    'text': text,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  factory SupportChatMessage.fromJson(Map<String, dynamic> json) {
    DateTime ts;
    if (json['timestamp'] != null) {
      if (json['timestamp'] is num) {
        ts = DateTime.fromMillisecondsSinceEpoch((json['timestamp'] as num).toInt());
      } else {
        ts = DateTime.tryParse(json['timestamp'].toString()) ?? DateTime.now();
      }
    } else if (json['created_at'] != null) {
      ts = DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }

    return SupportChatMessage(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      sender: json['sender']?.toString() ?? 'operator',
      senderName: json['sender_name']?.toString() ??
          (json['sender'] == 'operator' ? 'Инженер' : 'Пользователь'),
      text: json['text']?.toString() ?? '',
      timestamp: ts,
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

  const FileAssemblyResult.success(this.bytes)
      : error = null;

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
  if (expectedSize != null && expectedSize > 0 && bytes.length != expectedSize) {
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
/// Возвращает пустой список, если поле отсутствует/невалидно — вызывающий
/// код решает, использовать ли emergency-фолбэк.
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
      urls = urlsRaw.map((e) => e?.toString() ?? '').where((u) => _isValidIceUrl(u)).toList();
    } else if (urlsRaw is String && _isValidIceUrl(urlsRaw)) {
      urls = [urlsRaw];
    }
    if (urls.isEmpty) continue;
    result.add({
      'urls': urls,
      if (item['username'] != null) 'username': item['username'].toString(),
      if (item['credential'] != null) 'credential': item['credential'].toString(),
    });
  }
  return result;
}

bool _isValidIceUrl(String url) {
  return url.startsWith('stun:') || url.startsWith('turn:') || url.startsWith('turns:');
}

/// Сервис управления WebRTC экраном и вводом для удаленной поддержки (SOS).
class SupportService extends ChangeNotifier {
  /// Лимиты файловых передач (защита памяти/диска от нелимитированных закачек)
  static const int _maxFileTransferBytes = 50 * 1024 * 1024; // 50 МБ
  static const int _maxConcurrentDownloads = 2;
  static const Duration _downloadStallTimeout = Duration(seconds: 60);

  /// Emergency-фолбэк: публичные STUN Google/Cloudflare используются ТОЛЬКО
  /// если сервер не отдал ice_servers в /api/v1/app/config (или конфиг
  /// недоступен). TURN всегда должен приходить из корпоративного конфига.
  static const List<Map<String, dynamic>> emergencyIceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
  ];

  /// ICE-серверы из конфига сервера; null — конфиг еще не загружен.
  List<Map<String, dynamic>>? _iceServersFromConfig;

  /// Актуальный список ICE-серверов для RTCPeerConnection.
  List<Map<String, dynamic>> get effectiveIceServers =>
      (_iceServersFromConfig != null && _iceServersFromConfig!.isNotEmpty)
          ? _iceServersFromConfig!
          : emergencyIceServers;

  /// Устанавливает ICE-серверы из конфига (вызывается AuthState после
  /// /api/v1/app/config). Пустой список игнорируется — сохраняется фолбэк.
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

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  ApiClient? _api;

  List<Map<String, dynamic>> _screens = [];
  String? _currentScreenId;
  ScreenRect? _currentScreenRect;
  Timer? _telemetryTimer;
  final TelemetryService _telemetry = TelemetryService();

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
  String? get lastError => _lastError;

  /// Сброс ошибки последней сессии (кнопка «Закрыть» в баннере ошибки).
  void clearError() {
    if (_lastError != null) {
      _lastError = null;
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
    if (dl != null) {
      debugPrint('support_service: закачка "${dl.filename}" отменена ($reason)');
    }
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
      debugPrint('support_service: loadChatHistory error: $e');
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
    );
    _chatMessages.add(msg);
    notifyListeners();

    _sendSignalOrData(msg.toJson());

    if (_api != null && _activeSessionId != null && _activeSessionId!.isNotEmpty) {
      _api!.sendSupportChatMessage(
        sessionId: _activeSessionId!,
        text: msg.text,
        senderName: msg.senderName,
      ).catchError((e) {
        debugPrint('support_service: ошибка отправки сообщения через API: $e');
      });
    }
  }

  void _sendSignalOrData(Map<String, dynamic> data) {
    bool sent = false;
    if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode(data)));
        sent = true;
      } catch (e) {
        debugPrint('support_service: ошибка отправки через DataChannel: $e');
      }
    }
    if (!sent && _api != null && _activeSessionId != null) {
      // M-3: файловые передачи запрещены в HTTP-fallback (sendSupportSignal).
      // Чанки не проходят через сигнальный шлюз: утечка в чат-историю
      // сервера + отсутствие доставки по порядку.
      final type = data['type']?.toString() ?? '';
      if (type.startsWith('file_')) {
        throw StateError('Файловая передача требует открытый DataChannel ($type)');
      }
      _api!.sendSupportSignal(sessionId: _activeSessionId!, signal: data);
    }
  }

  Future<void> sendFile(File file) async {
    if (!await file.exists()) return;
    final filename = file.uri.pathSegments.last;
    final bytes = await file.readAsBytes();
    final totalSize = bytes.length;

    if (totalSize > _maxFileTransferBytes) {
      _addSystemMessage('⚠ Файл не отправлен: превышен лимит размера 50 МБ ($filename)');
      notifyListeners();
      return;
    }

    // M-3: файловые передачи идут ТОЛЬКО через DataChannel; HTTP-fallback
    // для file_* запрещен (см. _sendSignalOrData).
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      _addSystemMessage('⚠ Файл не отправлен: нет открытого соединения с инженером ($filename)');
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
        final start = i * chunkSize;
        final end = (start + chunkSize > totalSize) ? totalSize : start + chunkSize;
        final chunkBytes = bytes.sublist(start, end);
        final b64 = base64Encode(chunkBytes);

        _sendSignalOrData({
          'type': 'file_chunk',
          'transfer_id': transferId,
          'chunk_index': i,
          'data': b64,
        });
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
        text: '📎 Отправлен файл: $filename (${(totalSize / 1024).toStringAsFixed(1)} КБ)',
        timestamp: DateTime.now(),
      ));
      notifyListeners();
    } catch (e) {
      debugPrint('support_service: передача файла прервана: $e');
      _addSystemMessage('⚠ Передача файла "$filename" прервана (нет соединения)');
      notifyListeners();
    }
  }

  Future<void> _saveReceivedFile(_ActiveFileDownload dl, Uint8List bytes) async {
    try {
      final downloadsPath = await _resolveDownloadsDir();

      final dir = Directory(downloadsPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final safeName = dl.filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final targetPath = '${dir.path}${Platform.pathSeparator}$safeName';
      final file = File(targetPath);

      await file.writeAsBytes(bytes, flush: true);

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
        text: '📁 Получен файл: $safeName (${(bytes.length / 1024).toStringAsFixed(1)} КБ)',
        timestamp: DateTime.now(),
      ));
      _unreadChatCount++;
      notifyListeners();
    } catch (e) {
      debugPrint('support_service: ошибка сохранения переданного файла: $e');
    }
  }

  /// Каталог для сохранения полученных файлов.
  /// Desktop — Downloads/LigamentSupport; Android — через path_provider
  /// (M-7: не /sdcard напрямую), фолбэк — документы приложения.
  Future<String> _resolveDownloadsDir() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final dirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
        if (dirs != null && dirs.isNotEmpty) {
          return '${dirs.first.path}${Platform.pathSeparator}LigamentSupport';
        }
      } catch (e) {
        debugPrint('support_service: externalStorageDownloads недоступен: $e');
      }
      // Фолбэк: документы приложения
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}${Platform.pathSeparator}LigamentSupport';
    }
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'] ?? 'C:\\Users\\Default';
      return '$profile\\Downloads\\LigamentSupport';
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
    _state = SupportSessionState.requested;
    _lastError = null;
    _unreadChatCount = 0;
    _cancelAllDownloads();
    notifyListeners();
  }

  /// Установка состояния авторизации (когда оператор запросил подключение)
  void setAuthorizing({
    required String sessionId,
    String? category,
    String? problemSummary,
    String? accessMode,
    ApiClient? api,
  }) {
    _activeSessionId = sessionId;
    if (api != null) _api = api;
    if (category != null) _category = category;
    if (problemSummary != null) _problemSummary = problemSummary;
    if (accessMode != null && accessMode.isNotEmpty) _accessMode = accessMode;
    _state = SupportSessionState.authorizing;
    notifyListeners();
  }

  /// Инициализация P2P WebRTC захвата экрана и отправка SDP Offer оператору
  Future<void> startScreenSharing({
    required String sessionId,
    required ApiClient api,
    String accessMode = 'full_control',
  }) async {
    _activeSessionId = sessionId;
    _api = api;
    _accessMode = accessMode;

    try {
      // ICE-серверы берутся из конфига сервера (B-1); Google/Cloudflare STUN —
      // только emergency-фолбэк при недоступности конфига.
      if (_iceServersFromConfig == null) {
        try {
          final cfg = await api.getConfig();
          setIceServers(parseIceServersConfig(cfg));
        } catch (e) {
          debugPrint('support_service: конфиг недоступен, emergency STUN: $e');
        }
      }
      final rtcConfig = <String, dynamic>{
        'iceServers': effectiveIceServers,
        'sdpSemantics': 'unified-plan',
      };

      _peerConnection = await createPeerConnection(rtcConfig);

      // ICE кандидаты отправляются через серверный сигнальный шлюз оператору
      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
          _api?.sendSupportSignal(
            sessionId: _activeSessionId!,
            signal: {
              'candidate': {
                'candidate': candidate.candidate,
                'sdpMid': candidate.sdpMid,
                'sdpMLineIndex': candidate.sdpMLineIndex,
              },
            },
          ).catchError((err) {
            debugPrint('support_service: ошибка отправки ICE: $err');
          });
        }
      };

      _peerConnection!.onConnectionState = (state) {
        debugPrint('support_service: WebRTC connection state: $state');
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
              if (_state == SupportSessionState.active || _state == SupportSessionState.connecting) {
                _failSession('Соединение с инженером закрыто');
              }
            }
            break;
          default:
            break;
        }
      };

      // Канал данных для удаленного управления мышью и клавиатурой
      final dcInit = RTCDataChannelInit()..ordered = true;
      _dataChannel = await _peerConnection!.createDataChannel('input', dcInit);
      _setupDataChannel(_dataChannel!);

      _peerConnection!.onDataChannel = (channel) {
        _setupDataChannel(channel);
      };

      // Захват экрана: получение списка всех мониторов на десктопе
      MediaStream screenStream;
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
        if (sources.isEmpty) {
          throw Exception('Не найдены источники экрана для захвата');
        }
        _screens = sources.map((s) => _screenEntryForSource(s.id, s.name)).toList();
        final selectedSource = sources.first;
        _currentScreenId = selectedSource.id;
        _applyActiveScreenRect(selectedSource.id);

        debugPrint('support_service: найдено ${_screens.length} экранов, активен: ${selectedSource.name}');
        screenStream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': false,
          'video': {
            'deviceId': {'exact': selectedSource.id},
            'mandatory': {'frameRate': 25.0},
          },
        });
      } else {
        // Мобильные платформы и Web
        screenStream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
          'audio': false,
          'video': true,
        });
      }
      _localStream = screenStream;

      for (final track in _localStream!.getVideoTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // m-6: видео экрана — читаемость текста важнее плавности
      await _applyVideoSenderTuning();

      // m-1: на macOS без Accessibility-разрешения инъекции ввода молча
      // игнорируются — честно подсказываем пользователю до начала сеанса.
      if (!kIsWeb && Platform.isMacOS && InputInjector.instance.macAccessibilityTrusted == false) {
        _addSystemMessage('⚠ Для удаленного управления разрешите Ligament 2FA: '
            'Системные настройки → Конфиденциальность и безопасность → Универсальный доступ');
        notifyListeners();
      }

      // Создаем и отправляем SDP Offer (M-1: state=active только после
      // onConnectionState==connected)
      await _sendOffer();
      _state = SupportSessionState.connecting;
      _armEstablishmentTimeouts();
      notifyListeners();
    } catch (e) {
      debugPrint('support_service: ошибка инициализации захвата экрана: $e');
      stopScreenSharing();
      rethrow;
    }
  }

  /// m-6: приоритет разрешения над частотой кадров и целевой битрейт ~2.5 Мбит
  /// для видеопотока экрана (текст/1С должны оставаться читаемыми при
  /// просадке канала).
  Future<void> _applyVideoSenderTuning() async {
    final pc = _peerConnection;
    if (pc == null) return;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings != null && encodings.isNotEmpty) {
          encodings.first.maxBitrate = 2500000; // ~2.5 Мбит/с
          params.encodings = encodings;
        }
        params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
        await sender.setParameters(params);
        break;
      }
    } catch (e) {
      debugPrint('support_service: tuning видео-сендера не применился: $e');
    }
  }

  /// Создание и отправка SDP Offer тем же сигнальным путём (HTTP-гейт).
  /// При [iceRestart] предварительно вызывается pc.restartIce(), чтобы
  /// libwebrtc сгенерировал новые ICE-учётные данные.
  Future<void> _sendOffer({bool iceRestart = false}) async {
    final pc = _peerConnection;
    if (pc == null || _activeSessionId == null) return;
    try {
      if (iceRestart) {
        try {
          await pc.restartIce();
        } catch (e) {
          debugPrint('support_service: restartIce не поддержан: $e');
        }
      }
      final offer = await pc.createOffer({
        'offerToReceiveVideo': 0,
        'offerToReceiveAudio': 0,
      });
      await pc.setLocalDescription(offer);
      await _api?.sendSupportSignal(
        sessionId: _activeSessionId!,
        signal: {
          'sdp': offer.toMap(),
        },
      );
    } catch (e) {
      debugPrint('support_service: ошибка отправки offer (iceRestart=$iceRestart): $e');
    }
  }

  /// Таймауты установления: 30с с момента offer — повторный offer,
  /// 60с — завершение с ошибкой в UI.
  void _armEstablishmentTimeouts() {
    _establishmentTimer?.cancel();
    _establishmentTimer = Timer(const Duration(seconds: 30), () {
      if (_p2pConnected || _peerConnection == null) return;
      debugPrint('support_service: соединение не установилось за 30с — повторный offer');
      _attemptIceRestart();
    });
    _establishmentDeadlineTimer ??= Timer(const Duration(seconds: 60), () {
      if (_p2pConnected || _peerConnection == null) return;
      _failSession('Не удалось установить соединение с инженером (таймаут 60 с)');
    });
  }

  void _cancelResilienceTimers() {
    _establishmentTimer?.cancel();
    _establishmentTimer = null;
    _establishmentDeadlineTimer?.cancel();
    _establishmentDeadlineTimer = null;
    _disconnectedTimer?.cancel();
    _disconnectedTimer = null;
  }

  void _onP2pConnected() {
    _p2pConnected = true;
    _cancelResilienceTimers();
    _iceRestartAttempts = 0;
    _lastIceRestartAt = null;
    if (_state != SupportSessionState.active) {
      _state = SupportSessionState.active;
      _startPeriodicTelemetry();
      _setWakelock(true);
      notifyListeners();
    }
  }

  /// M-8: держим экран включенным, пока активна SOS-сессия (мобильные).
  void _setWakelock(bool enabled) {
    if (kIsWeb) return;
    try {
      if (enabled) {
        WakelockPlus.enable();
      } else {
        WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('support_service: wakelock ${enabled ? 'enable' : 'disable'} ошибка: $e');
    }
  }

  /// Disconnected: не убиваем шаринг сразу — транзиентные обрывы
  /// восстанавливаются сами; 10с без connected — ICE-рестарт.
  void _onP2pDisconnected() {
    _p2pConnected = false;
    if (_isStopping || _peerConnection == null) return;
    if (_state != SupportSessionState.active && _state != SupportSessionState.connecting) return;
    _disconnectedTimer?.cancel();
    _disconnectedTimer = Timer(const Duration(seconds: 10), () {
      if (_p2pConnected || _peerConnection == null || _isStopping) return;
      debugPrint('support_service: disconnected длится >10с — ICE-рестарт');
      _attemptIceRestart();
    });
  }

  /// Failed: pc.restartIce() + повторный offer тем же сигнальным путём,
  /// максимум 3 попытки с интервалом 5с, дальше — завершение с ошибкой.
  void _onP2pFailed() {
    _p2pConnected = false;
    if (_isStopping || _peerConnection == null) return;
    if (_state != SupportSessionState.active && _state != SupportSessionState.connecting) return;
    _disconnectedTimer?.cancel();
    _attemptIceRestart();
  }

  void _attemptIceRestart() {
    if (_isStopping || _peerConnection == null || _activeSessionId == null) return;
    if (_iceRestartAttempts >= 3) {
      _failSession('Не удалось восстановить P2P-соединение после 3 попыток');
      return;
    }
    final now = DateTime.now();
    final sinceLast = _lastIceRestartAt == null ? null : now.difference(_lastIceRestartAt!);
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
    _lastIceRestartAt = now;
    debugPrint('support_service: ICE-рестарт, попытка $_iceRestartAttempts/3');
    _sendOffer(iceRestart: true);
  }

  /// Терминальный отказ сессии: остановка трансляции + ошибка в UI/чат.
  Future<void> _failSession(String userError) async {
    if (_isStopping) return;
    debugPrint('support_service: $userError');
    _lastError = userError;
    _cancelResilienceTimers();
    await stopScreenSharing();
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

  /// Обработка сигнальных WebRTC пакетов от браузера оператора (Answer, Candidates)
  Future<void> handleRemoteSignal(Map<String, dynamic> signal) async {
    try {
      final payload = (signal['data'] is Map<String, dynamic>)
          ? signal['data'] as Map<String, dynamic>
          : signal;

      if (payload['type'] == 'chat_message' ||
          (payload['type'] == 'input_control' && (payload['data'] as Map?)?['type'] == 'chat_message')) {
        final chatData = payload['type'] == 'chat_message'
            ? payload
            : (payload['data'] as Map<String, dynamic>);
        _handleRemoteInput(chatData);
        return;
      }

      if (_peerConnection == null) return;

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
            debugPrint('support_service: ошибка flush ICE: $e');
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
        if (remoteDesc == null || remoteDesc.type == null || remoteDesc.type!.isEmpty) {
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
      debugPrint('support_service: ошибка обработки входящего сигнала: $e');
    }
  }

  void _setupDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (RTCDataChannelState st) {
      if (st == RTCDataChannelState.RTCDataChannelOpen) {
        _sendScreenList();
        _sendCurrentTelemetry();
      }
    };
    channel.onMessage = (RTCDataChannelMessage msg) {
      if (msg.isBinary) return;
      try {
        final data = jsonDecode(msg.text) as Map<String, dynamic>;
        _handleRemoteInput(data);
      } catch (e) {
        debugPrint('support_service: ошибка разбора команды ввода: $e');
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
    } catch (_) {
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
    debugPrint('support_service: активный экран $sourceId rect=$rect');
  }

  Future<void> _sendScreenList() async {
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        try {
          final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
          if (sources.isNotEmpty) {
            _screens = sources.map((s) => _screenEntryForSource(s.id, s.name)).toList();
            debugPrint('support_service: обновлен список экранов (${_screens.length}): $_screens');
          }
        } catch (e) {
          debugPrint('support_service: ошибка динамического обновления экранов: $e');
        }
      }
      _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
        'type': 'screen_list',
        'screens': _screens,
        'selected_id': _currentScreenId,
        if (_currentScreenRect != null) 'selected_rect': _currentScreenRect!.toJson(),
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          'virtual_desktop': InputInjector.instance.getVirtualDesktopRect().toJson(),
      })));
    } catch (_) {}
  }

  /// Переключение транслируемого монитора на лету
  Future<void> switchScreen(String screenId) async {
    if (kIsWeb || _peerConnection == null) return;
    try {
      final newStream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'audio': false,
        'video': {
          'deviceId': {'exact': screenId},
          'mandatory': {'frameRate': 25.0},
        },
      });

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

      _localStream?.getVideoTracks().forEach((t) => t.stop());
      _localStream?.dispose();
      _localStream = newStream;
      _currentScreenId = screenId;
      _applyActiveScreenRect(screenId);

      await _sendScreenList();
      notifyListeners();
    } catch (e) {
      debugPrint('support_service: ошибка переключения экрана: $e');
    }
  }

  void _startPeriodicTelemetry() {
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _sendCurrentTelemetry();
    });
  }

  Future<void> _sendCurrentTelemetry() async {
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) return;
    try {
      final cpu = await _telemetry.collectCpuMetrics();
      final disk = await _telemetry.collectDiskMetrics();
      final payload = {
        'type': 'telemetry',
        ...cpu,
        ...disk,
      };
      _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
    } catch (_) {}
  }

  /// Начало входящей файловой передачи: проверка лимитов размера и числа
  /// одновременных закачек, запуск таймаута ожидания первого чанка.
  void _handleFileStart(Map<String, dynamic> input) {
    final transferId = input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    if (transferId.isEmpty) return;
    final filename = input['filename']?.toString() ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
    final size = (input['size'] as num?)?.toInt() ?? 0;
    final totalChunks = (input['total_chunks'] as num?)?.toInt() ?? 1;

    if (size < 0 || size > _maxFileTransferBytes) {
      debugPrint('support_service: передача "$filename" отклонена: размер $size байт превышает лимит 50 МБ');
      return;
    }
    if (totalChunks <= 0) return;
    if (_activeDownloads.length >= _maxConcurrentDownloads) {
      debugPrint('support_service: передача "$filename" отклонена: превышен лимит одновременных закачек ($_maxConcurrentDownloads)');
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
      _abortDownload(transferId, 'таймаут ожидания данных ${_downloadStallTimeout.inSeconds}с');
    });
    _activeDownloads[transferId] = dl;
  }

  /// Прием чанка: валидация, контроль фактически полученного объема и
  /// перезапуск таймаута ожидания следующего чанка. Битый base64 —
  /// закачка отменяется с сообщением об ошибке (M-3).
  void _handleFileChunk(Map<String, dynamic> input) {
    final transferId = input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final chunkIndex = (input['chunk_index'] as num?)?.toInt() ?? 0;
    final base64Data = input['data']?.toString() ?? '';
    final dl = _activeDownloads[transferId];
    if (dl == null || base64Data.isEmpty) return;

    try {
      final bytes = base64Decode(base64Data);
      if (chunkIndex < 0 || chunkIndex >= dl.totalChunks) {
        debugPrint('support_service: чанк $chunkIndex вне диапазона — дропнут');
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
        _abortDownload(transferId, 'таймаут ожидания данных ${_downloadStallTimeout.inSeconds}с');
      });
    } catch (e) {
      debugPrint('support_service: битый base64 в чанке $chunkIndex передачи "$transferId": $e');
      _abortDownload(transferId, 'поврежденные данные (чанк $chunkIndex)');
      _notifyFileRejected(transferId, dl.filename, 'поврежденные данные при передаче');
      _addSystemMessage('⚠ Файл "${dl.filename}" не получен: поврежденные данные при передаче');
      notifyListeners();
    }
  }

  /// Завершение передачи: проверка полноты (все индексы 0..totalChunks-1)
  /// и целостности (sha256), только после этого — сохранение (M-3).
  void _handleFileEnd(Map<String, dynamic> input) {
    final transferId = input['transfer_id']?.toString() ?? input['id']?.toString() ?? '';
    final dl = _activeDownloads.remove(transferId);
    dl?.stallTimer?.cancel();
    if (dl == null) return;

    // file_end может нести checksum повторно — приоритет у него.
    final endChecksum = input['checksum']?.toString();
    final checksum = (endChecksum != null && endChecksum.isNotEmpty) ? endChecksum : dl.expectedChecksum;

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

    debugPrint('support_service: передача "${dl.filename}" отброшена: ${result.error}');
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
    } catch (_) {
      // DataChannel закрыт — уведомление не критично
    }
  }

  /// Эмуляция пользовательского ввода от оператора (мышь/клавиатура/хоткеи/буфер)
  void _handleRemoteInput(Map<String, dynamic> input) async {
    final type = (input['type'] ?? input['action'])?.toString();
    if (type == null) return;

    // Гейт режима «Только просмотр» (view_only): разрешены список экранов,
    // чат и ПЕРЕКЛЮЧЕНИЕ транслируемого монитора (m-5: просмотр нескольких
    // мониторов не дает управления). Ввод, буфер обмена и файловые передачи
    // блокируются ДО какой-либо обработки команды.
    if (_accessMode == 'view_only' &&
        type != 'screen_list' &&
        type != 'chat_message' &&
        type != 'switch_screen') {
      debugPrint('support_service: команда "$type" отклонена (view_only)');
      return;
    }

    if (type == 'screen_list') {
      await _sendScreenList();
      return;
    } else if (type == 'chat_message') {
      try {
        final chatMsg = SupportChatMessage.fromJson(input);
        final isDuplicate = _chatMessages.any((m) =>
            m.id == chatMsg.id ||
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
        debugPrint('support_service: ошибка разбора чат-сообщения: $e');
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
      if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
          'type': 'clipboard_data',
          'text': clip?.text ?? '',
        })));
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
    }

    if (_accessMode == 'view_only') {
      // Режим «Только просмотр» блокирует команды управления
      return;
    }

    try {
      debugPrint('support_service: remote input command: $type');
      switch (type) {
        case 'mouse_move':
          final x = (input['x'] as num?)?.toDouble() ?? 0.0;
          final y = (input['y'] as num?)?.toDouble() ?? 0.0;
          InputInjector.instance.moveMouse(x, y);
          break;
        case 'mouse_down':
        case 'mouse_up':
        case 'mouse_click':
        case 'click':
          final btn = (input['button'] as num?)?.toInt() ?? 0;
          final x = (input['x'] as num?)?.toDouble() ?? 0.0;
          final y = (input['y'] as num?)?.toDouble() ?? 0.0;
          final act = type == 'mouse_down' ? 'down' : (type == 'mouse_up' ? 'up' : 'click');
          InputInjector.instance.mouseAction(action: act, button: btn, normX: x, normY: y);
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
          final act = type == 'key_down' ? 'down' : 'up';
          InputInjector.instance.keyAction(action: act, key: key, keyCode: code);
          break;
        case 'block_input':
          final blocked = input['blocked'] == true || input['enabled'] == true;
          InputInjector.instance.setInputBlocked(blocked);
          break;
        case 'hotkey':
          final hotkey = (input['action'] ?? input['hotkey'] ?? input['key'])?.toString() ?? '';
          if (hotkey.isNotEmpty) {
            await InputInjector.instance.triggerHotkey(hotkey);
          }
          break;
      }
    } catch (e) {
      debugPrint('support_service: ошибка выполнения ввода: $e');
    }
  }

  bool _isStopping = false;

  /// Остановка трансляции экрана и освобождение ресурсов (асинхронно, с защитой от рекурсии)
  Future<void> stopScreenSharing() async {
    if (_isStopping) return;
    _isStopping = true;

    try {
      // 1. Немедленно освобождаем мышь и ввод пользователя
      InputInjector.instance.setInputBlocked(false);
      _setWakelock(false);

      _telemetryTimer?.cancel();
      _telemetryTimer = null;
      _cancelResilienceTimers();
      _p2pConnected = false;
      _iceRestartAttempts = 0;
      _lastIceRestartAt = null;

      _pendingCandidates.clear();

      // Немедленно переводим статус в idle, чтобы UI обновился мгновенно
      _state = SupportSessionState.idle;
      _activeSessionId = null;
      _category = null;
      _problemSummary = null;
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
          dc.onMessage = null;
          dc.onDataChannelState = null;
          await dc.close().timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        } catch (_) {}
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
          await pc.close().timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        } catch (_) {}
      }

      // 4. Останавливаем все медиатреки захвата экрана
      final stream = _localStream;
      _localStream = null;
      if (stream != null) {
        try {
          for (final track in stream.getTracks()) {
            try {
              await track.stop().timeout(const Duration(milliseconds: 300), onTimeout: () => null);
            } catch (_) {}
          }
        } catch (_) {}
      }

      // 5. Окончательное освобождение нативных дескрипторов производим в фоне (не блокируя UI)
      Future.microtask(() async {
        try {
          await stream?.dispose();
        } catch (_) {}
        try {
          await pc?.dispose();
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('support_service: ошибка при stopScreenSharing: $e');
    } finally {
      _isStopping = false;
      InputInjector.instance.setInputBlocked(false);
    }
  }

  @override
  void dispose() {
    stopScreenSharing();
    super.dispose();
  }
}
