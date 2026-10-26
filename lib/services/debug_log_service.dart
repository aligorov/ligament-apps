import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';

class DebugLogService extends ChangeNotifier {
  DebugLogService({
    MethodChannel? channel,
    bool? nativeWindows,
    Future<Directory> Function()? directory,
  })  : _channel = channel ?? const MethodChannel('com.ligament/diagnostics'),
        _nativeWindows = nativeWindows ?? (!kIsWeb && Platform.isWindows),
        _directory = directory ?? getApplicationSupportDirectory;

  static final instance = DebugLogService();
  static const preferenceKey = 'debug_logs_enabled';
  static const maxFileBytes = 2 * 1024 * 1024;
  static const maxPendingEntries = 1024;
  static final _eventPattern = RegExp(r'^[a-z0-9_.-]{1,80}$');
  static final _fieldPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
  static final _uuidPattern = RegExp(
      r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$');
  static final _numberPattern = RegExp(r'^-?[0-9]+(?:\.[0-9]+)?$');
  static final _secretPattern = RegExp(r'^[a-fA-F0-9]{32,}$');
  static const _numberFields = {
    'request_id',
    'attempt',
    'duration_ms',
    'elapsed_ms',
    'count',
    'bytes',
    'response_bytes',
    'sent_bytes',
    'received_bytes',
    'width',
    'height',
    'frames',
    'rtt_ms',
    'queue_bytes',
    'acked_seq',
    'seq',
    'cursor',
    'ice_servers',
    'candidates',
    'tracks',
    'timeout_ms',
    'code',
    'http_status',
  };
  static const _boolFields = {
    'connected',
    'frame_ready',
    'control_ready',
    'owner',
    'recorder_enabled',
    'mandatory',
    'first_frame_acked',
  };
  static const _labelFields = {
    'phase',
    'origin',
    'reason',
    'state',
    'ice_state',
    'pc_state',
    'dc_state',
    'message_type',
    'transport',
    'operation',
    'result',
  };

  static String protocolLabel(Object? value) => const {
        'unknown',
        'init',
        'chat',
        'waiting_consent',
        'owner_waiting',
        'ended_by_server',
        'session_ended',
        'pc_no_offer',
        'pc_no_track',
        'no_first_frame',
        'stage_retry',
        'pc_failed',
        'conn_error',
        'requesting_access',
        'req_error',
        'p2p_connected',
        'disconnected',
        'stream_active',
        'user_closed',
        'host_local_disconnect',
        'server_ended',
        'access_revoked',
        'user_access_killed',
        'closed_by_user',
        'terminated_by_admin',
        'lease_expired',
        'host_offline',
        'host_busy',
        'host_accessibility_permission_required',
        'host_screen_capture_unavailable',
        'host_wayland_control_unavailable',
        'host_linux_input_unavailable',
        'host_no_active_user',
        'host_session_ambiguous',
        'host_worker_not_installed',
        'host_worker_launch_failed',
        'host_worker_unavailable',
        'host_ready_timeout',
        'host_worker_failed',
        'host_ui_unavailable',
        'host_media_failed',
        'number_matching_failed',
        'number_matching_required',
        'recorder_insecure_ingest',
        'recorder_first_frame_unavailable',
        'recorder_first_frame_unacked',
        'recorder_ack_lag',
        'recorder_ack_lag_exceeded',
        'recorder_lease_expired',
        'recorder_tail_lost',
        'recorder_unreachable',
        'recorder_queue_overflow',
        'tail_lost',
        'normal',
        'access_denied',
        'access_check_failed',
        'unauthorized',
        'forbidden',
        'invalid_credentials',
        'bad_credentials',
        'bad_code',
        'user_disabled',
        'second_factor_required',
        'challenge_denied',
        'challenge_expired',
        'expired',
        'locked',
        'rate_limited',
        'too_many_requests',
        'cooldown',
        'internal',
        'db_error',
        'database_unavailable',
        'bad_request',
        'invalid_json',
        'not_found',
        'no_channel',
        'ldap_not_licensed',
        'webauthn_disabled',
        'bad_attempt',
        'no_credentials',
        'handle_required',
        'bind_invalid',
        'bad_assertion',
        'bad_passkey',
        'device_required',
        'bad_ticket',
        'ticket_expired',
        'ticket_used',
        'already_used',
        'machine_mismatch',
        'proof_not_stored',
        'sso_ticket_required',
        'feature_link_not_licensed',
        'link_admin_required',
        'link_agents_limit_exceeded',
        'link_sessions_limit_exceeded',
        'invalid_agent_id',
        'agent_not_found',
        'agent_not_editable',
        'agent_already_bound',
        'agent_archived',
        'agent_unreachable',
        'invalid_enrollment_token',
        'invalid_enrollment_token_limits',
        'invalid_public_key',
        'missing_agent_metadata',
        'missing_unattended_enabled',
        'invalid_session_id',
        'session_not_found',
        'session_not_active',
        'session_expired_or_not_found',
        'session_close_failed',
        'session_revoke_failed',
        'invalid_signal_cursor',
        'signal_delivery_failed',
        'invalid_relay_params',
        'invalid_relay_token',
        'invalid_access_mode',
        'invalid_action_id',
        'action_already_used',
        'invalid_id',
        'token_generation_failed',
        'code_generation_failed',
        'token_error',
        'master_key_unavailable',
        'box_error',
        'decrypt_error',
        'totp_not_configured',
        'invalid_totp_code',
        'attempt_id_required',
        'attempt_expired_or_invalid',
        'external_perimeter_stepup_required',
        'control_not_permitted_for_view_profile',
        'sos_requires_request',
        'owner_unlink_denied',
        'invalid_reason',
        'archive_failed',
        'reason_required',
        'invalid_profile',
        'invalid_user_id',
        'self_approval_forbidden',
        'invalid_assignment_id',
        'assignment_not_found',
        'assignment_revoke_forbidden',
        'not_a_session_participant',
        'failed_to_lookup_participant',
        'failed_to_register_participant',
        'failed_to_save_message',
        'failed_to_list_messages',
        'failed_to_list_participants',
        'duplicate_message_with_conflicting_body',
        'empty_message_body',
        'message_body_too_long',
        'missing_ingest_token',
        'invalid_ingest_token',
        'invalid_batch_body',
        'capture_unavailable',
        'control_unavailable',
        'api_unavailable',
        'stale_attempt',
        'cancelled_by_sender',
        'cancelled_by_operator',
        'insecure_ingest',
        'policy',
        'recorder_not_ready',
        'empty_capture',
        'invalid_file',
        'session_not_live',
        'signal_not_allowed',
        'invalid_frame',
        'transport_closed',
        'user_denied',
        'consent_denied',
        'consent_timeout',
        'worker_failed',
      }.contains(value)
          ? value as String
          : 'unknown';

  @visibleForTesting
  static Map<String, String> safeFields(Map<String, Object?> fields) {
    final result = <String, String>{};
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_numberFields.contains(key) && value is num && value.isFinite) {
        final text = value.toString();
        if (text.length <= 32 && _numberPattern.hasMatch(text)) {
          result[key] = text;
        }
      } else if (_boolFields.contains(key) && value is bool) {
        result[key] = value.toString();
      } else if ((key == 'session_id' || key == 'agent_id') &&
          value is String &&
          _uuidPattern.hasMatch(value)) {
        result[key] = value.toLowerCase();
      } else if (_labelFields.contains(key) &&
          value is String &&
          _fieldPattern.hasMatch(value) &&
          !_secretPattern.hasMatch(value)) {
        result[key] = value;
      } else if (key == 'method' &&
          const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'}
              .contains(value)) {
        result[key] = value as String;
      } else if (key == 'server' &&
          value is String &&
          RegExp(r'^[A-Za-z0-9.\[\]:-]{1,253}$').hasMatch(value)) {
        result[key] = value;
      } else if (key == 'route' &&
          value is String &&
          RegExp(r'^/[A-Za-z0-9_./{}:-]{0,239}$').hasMatch(value)) {
        result[key] = value;
      }
    }
    return result;
  }

  final MethodChannel _channel;
  final bool _nativeWindows;
  final Future<Directory> Function() _directory;
  Future<void>? _initialization;
  Future<void> _pendingWrites = Future<void>.value();
  bool _enabled = false;
  bool _available = !kIsWeb;
  bool _initialized = false;
  String? _path;
  int _requestSequence = 0;
  int _queuedWrites = 0;
  int _droppedWrites = 0;
  String? _writeFailure;
  bool _disposed = false;

  int nextRequestId() => ++_requestSequence;
  String? get writeFailure => _writeFailure;

  void _setWriteFailure(String? value) {
    if (_disposed || _writeFailure == value) return;
    _writeFailure = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool get enabled => _enabled;
  bool get available => _available;
  bool get initialized => _initialized;
  String? get path => _path;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (kIsWeb) {
      _initialized = true;
      notifyListeners();
      return;
    }
    try {
      if (_nativeWindows) {
        final state = await _channel
            .invokeMapMethod<String, dynamic>('getState')
            .timeout(const Duration(seconds: 2));
        if (state == null) throw StateError('debug_log_state_unavailable');
        _enabled = state['enabled'] == true;
        _path = state['path'] as String?;
      } else {
        final prefs = await SharedPreferences.getInstance();
        _enabled = prefs.getBool(preferenceKey) ?? false;
        if (_enabled) await _prepareDirectory();
      }
    } catch (_) {
      _enabled = false;
      _available = false;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _prepareDirectory() async {
    final base = await _directory();
    final logs = Directory('${base.path}${Platform.pathSeparator}logs');
    await logs.create(recursive: true);
    _path = '${logs.path}${Platform.pathSeparator}app-debug.log';
  }

  Future<void> setEnabled(bool value) async {
    await initialize();
    if (!_available) throw StateError('debug_log_unavailable');
    if (value == _enabled) return;
    if (_nativeWindows) {
      final state = await _channel
          .invokeMapMethod<String, dynamic>(
            'setEnabled',
            value,
          )
          .timeout(const Duration(seconds: 2));
      if (state == null || state['enabled'] != value) {
        throw StateError('debug_log_setting_failed');
      }
      _enabled = value;
      _path = state['path'] as String?;
    } else {
      if (value) await _prepareDirectory();
      final prefs = await SharedPreferences.getInstance();
      if (!value) {
        record('debug.disabled');
        await flush();
      }
      if (!await prefs.setBool(preferenceKey, value)) {
        throw StateError('debug_log_setting_failed');
      }
      _enabled = value;
      if (value) record('debug.enabled');
    }
    notifyListeners();
  }

  void record(
    String event, {
    Object? error,
    Map<String, Object?> fields = const {},
  }) {
    if (_disposed ||
        !_initialized ||
        !_available ||
        !_eventPattern.hasMatch(event)) {
      return;
    }
    if (!_nativeWindows && !_enabled) return;
    if (_queuedWrites >= maxPendingEntries) {
      _droppedWrites++;
      return;
    }
    _queuedWrites++;
    final entry = <String, Object>{'event': event};
    final context = safeFields(fields);
    if (context.isNotEmpty) {
      entry['context'] =
          context.entries.map((e) => '${e.key}=${e.value}').join(' ');
    }
    if (error != null) {
      final type = error.runtimeType.toString();
      if (_fieldPattern.hasMatch(type)) entry['error_type'] = type;
      if (error is PlatformException && _fieldPattern.hasMatch(error.code)) {
        entry['error_code'] = error.code;
      } else if (error is ApiException) {
        final code = 'http_${error.statusCode}.${protocolLabel(error.code)}';
        entry['error_code'] =
            _fieldPattern.hasMatch(code) ? code : 'http_${error.statusCode}';
      } else if (error is SocketException && error.osError != null) {
        entry['os_error'] = error.osError!.errorCode;
      } else if (error is FileSystemException && error.osError != null) {
        entry['os_error'] = error.osError!.errorCode;
      }
    }
    final now = DateTime.now();
    final operation = _pendingWrites.then((_) async {
      if (!_nativeWindows && !_enabled) return;
      if (_nativeWindows) {
        final written = await _channel
            .invokeMethod<bool>('write', entry)
            .timeout(const Duration(seconds: 1));
        if (written == true) _setWriteFailure(null);
      } else {
        final path = _path;
        if (path == null) return;
        final file = File(path);
        final offset = now.timeZoneOffset;
        final absoluteMinutes = offset.inMinutes.abs();
        final zone = '${offset.isNegative ? '-' : '+'}'
            '${(absoluteMinutes ~/ 60).toString().padLeft(2, '0')}:'
            '${(absoluteMinutes % 60).toString().padLeft(2, '0')}';
        final values = entry.entries
            .where((e) => e.key != 'context')
            .map((e) => '${e.key}=${e.value}')
            .join(' ');
        final details = entry['context'];
        final line = '${now.toIso8601String()}$zone pid=$pid $values'
            '${details == null ? '' : ' $details'}\n';
        if (await file.exists() &&
            await file.length() + utf8.encode(line).length > maxFileBytes) {
          final backup = File('$path.1');
          if (await backup.exists()) await backup.delete();
          await file.rename(backup.path);
        }
        await file.writeAsString(
          line,
          mode: FileMode.append,
          flush: true,
        );
        _setWriteFailure(null);
      }
    });
    _pendingWrites = operation.catchError((Object error) {
      final code = error is PlatformException && error.details is int
          ? 'win32_${error.details}'
          : error.runtimeType.toString();
      _setWriteFailure(_fieldPattern.hasMatch(code) ? code : 'write_failed');
    }).whenComplete(() {
      _queuedWrites--;
      if (_droppedWrites > 0) {
        final dropped = _droppedWrites;
        _droppedWrites = 0;
        record('debug.queue.dropped', fields: {'count': dropped});
      }
    });
  }

  Future<void> flush() async {
    while (true) {
      final pending = _pendingWrites;
      await pending;
      if (identical(pending, _pendingWrites)) return;
    }
  }
}
