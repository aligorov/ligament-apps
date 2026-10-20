import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class LinkAgentBindingService {
  static const MethodChannel _channel = MethodChannel('ligament/link_agent');

  Future<String> bindHost({
    required String serverUrl,
    required String enrollmentToken,
  }) async {
    final uri = Uri.tryParse(serverUrl.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        serverUrl.length > 2048) {
      throw const FormatException('Invalid Link server URL');
    }
    if (enrollmentToken.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(enrollmentToken)) {
      throw const FormatException('Invalid Link enrollment token');
    }
    final fingerprint = Platform.isWindows
        ? await _bindWindows(
            serverUrl.trim(),
            enrollmentToken,
          )
        : (Platform.isLinux || Platform.isMacOS)
            ? await _bindUnix(serverUrl.trim(), enrollmentToken)
            : throw UnsupportedError('Link host binding is not supported here');
    if (fingerprint == null ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('Link agent returned an invalid fingerprint');
    }
    return fingerprint;
  }

  Future<String?> _bindWindows(String serverUrl, String enrollmentToken) =>
      _channel.invokeMethod<String>(
        'bindHost',
        <String, Object>{
          'server_url': serverUrl,
          'enrollment_token': enrollmentToken,
        },
      );

  Future<String?> _bindUnix(String serverUrl, String enrollmentToken) async {
    final uid = await _currentUnixUID();
    final socketPath = linkAgentBindingSocketPath(uid);
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 10),
    );
    try {
      final payload =
          Uint8List.fromList(utf8.encode(jsonEncode(<String, Object>{
        'version': 1,
        'server_url': serverUrl,
        'enrollment_token': enrollmentToken,
      })));
      if (payload.isEmpty || payload.length > _bindingFrameLimit) {
        throw const FormatException('Link binding request exceeds size limit');
      }
      final frame = Uint8List(payload.length + 4);
      ByteData.sublistView(frame).setUint32(0, payload.length, Endian.big);
      frame.setRange(4, frame.length, payload);
      socket.add(frame);
      await socket.flush();

      final reader = _UnixBindingFrameReader(socket);
      final responseBytes = await reader.readFrame().timeout(
            const Duration(seconds: 35),
          );
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map || decoded['ok'] != true) {
        throw StateError('Link agent rejected the local binding request');
      }
      final fingerprint = decoded['fingerprint'];
      if (fingerprint is! String) {
        throw const FormatException('Invalid Link binding response');
      }
      return fingerprint;
    } finally {
      await socket.close();
    }
  }

  Future<int> _currentUnixUID() async {
    final result = await Process.run('/usr/bin/id', const ['-u']);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw StateError('Could not resolve the current user ID');
    }
    final uid = int.tryParse((result.stdout as String).trim());
    if (uid == null || uid < 0) {
      throw StateError('The current user ID is invalid');
    }
    return uid;
  }
}

const _bindingFrameLimit = 4096;

String linkAgentBindingSocketPath(int uid) {
  if (uid < 0) throw ArgumentError.value(uid, 'uid');
  return '/tmp/ligament-agent-$uid/bind.sock';
}

class _UnixBindingFrameReader {
  _UnixBindingFrameReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<Uint8List> readFrame() async {
    final header = await _readExactly(4);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (length == 0 || length > _bindingFrameLimit) {
      throw const FormatException('Invalid Link binding response size');
    }
    return _readExactly(length);
  }

  Future<Uint8List> _readExactly(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _chunk.length) {
        if (!await _iterator.moveNext()) {
          throw const FormatException('Link agent closed the binding socket');
        }
        _chunk = _iterator.current;
        _offset = 0;
      }
      final count = (_chunk.length - _offset).clamp(0, length - written);
      result.setRange(written, written + count, _chunk, _offset);
      written += count;
      _offset += count;
    }
    return result;
  }
}
