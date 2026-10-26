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
  static final _eventPattern = RegExp(r'^[a-z0-9_.-]{1,80}$');
  static final _fieldPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

  final MethodChannel _channel;
  final bool _nativeWindows;
  final Future<Directory> Function() _directory;
  Future<void>? _initialization;
  Future<void> _pendingWrites = Future<void>.value();
  bool _enabled = false;
  bool _available = !kIsWeb;
  bool _initialized = false;
  String? _path;

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
      final state = await _channel.invokeMapMethod<String, dynamic>(
        'setEnabled',
        value,
      ).timeout(const Duration(seconds: 2));
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

  void record(String event, {Object? error}) {
    if (!_available || !_eventPattern.hasMatch(event)) return;
    if (!_nativeWindows && !_enabled) return;
    final entry = <String, Object>{'event': event};
    if (error != null) {
      final type = error.runtimeType.toString();
      if (_fieldPattern.hasMatch(type)) entry['error_type'] = type;
      if (error is PlatformException && _fieldPattern.hasMatch(error.code)) {
        entry['error_code'] = error.code;
      } else if (error is ApiException) {
        entry['error_code'] = 'http_${error.statusCode}';
      } else if (error is SocketException && error.osError != null) {
        entry['os_error'] = error.osError!.errorCode;
      } else if (error is FileSystemException && error.osError != null) {
        entry['os_error'] = error.osError!.errorCode;
      }
    }
    final operation = _pendingWrites.then((_) async {
      if (!_nativeWindows && !_enabled) return;
      if (_nativeWindows) {
        await _channel.invokeMethod<bool>('write', entry)
            .timeout(const Duration(seconds: 1));
      } else {
        final path = _path;
        if (path == null) return;
        final file = File(path);
        final now = DateTime.now();
        final offset = now.timeZoneOffset;
        final absoluteMinutes = offset.inMinutes.abs();
        final zone = '${offset.isNegative ? '-' : '+'}'
            '${(absoluteMinutes ~/ 60).toString().padLeft(2, '0')}:'
            '${(absoluteMinutes % 60).toString().padLeft(2, '0')}';
        final fields = entry.entries.map((e) => '${e.key}=${e.value}').join(' ');
        final line = '${now.toIso8601String()}$zone pid=$pid $fields\n';
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
      }
    });
    _pendingWrites = operation.catchError((_) {});
  }

  Future<void> flush() => _pendingWrites;
}
