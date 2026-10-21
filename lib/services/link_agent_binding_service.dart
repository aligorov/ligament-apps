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
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('ensureMacAgentRunning');
    } else if (Platform.isLinux) {
      await _ensureLinuxAgentRunning();
    }
    final uid = await _currentUnixUID();
    final socketPath = linkAgentBindingSocketPath(uid);
    final socket = await _connectUnixBindingSocket(socketPath);
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

  Future<void> _ensureLinuxAgentRunning() async {
    ProcessResult result;
    try {
      result = await Process.run(
        'systemctl',
        const ['--user', 'enable', '--now', 'ligament-link-agent.service'],
      ).timeout(const Duration(seconds: 15));
    } on Object catch (error) {
      throw LinkAgentBindingFailure(
          'link_agent_linux_systemd_unavailable', error);
    }
    if (result.exitCode != 0) {
      throw LinkAgentBindingFailure(
        'link_agent_linux_service_unavailable',
        result.stderr,
      );
    }
  }

  Future<Socket> _connectUnixBindingSocket(String socketPath) async {
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        return await Socket.connect(address, 0,
            timeout: const Duration(seconds: 1));
      } on SocketException {
        if (!DateTime.now().isBefore(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
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

String linkAgentBindingErrorMessage(Object error, {required bool isRu}) {
  final code = error is PlatformException
      ? error.code
      : error is LinkAgentBindingFailure
          ? error.code
          : '';
  final message = switch (code) {
    'link_agent_missing' => isRu
        ? 'В этой копии приложения не найден Link Agent. Установите Ligament 2FA в папку Applications и попробуйте снова.'
        : 'Link Agent is missing from this app bundle. Install Ligament 2FA in Applications and try again.',
    'link_agent_launchd_failed' => isRu
        ? 'Не удалось запустить macOS Link Agent. Проверьте, что приложение находится в Applications, и повторите попытку.'
        : 'Could not start the macOS Link Agent. Make sure the app is in Applications and try again.',
    'link_agent_service_not_running' => isRu
        ? 'Служба Ligament Link Agent не запущена. Проверьте её состояние в «Службах» Windows.'
        : 'Ligament Link Agent service is not running. Check its status in Windows Services.',
    'link_agent_linux_systemd_unavailable' => isRu
        ? 'Не удалось запустить службу Link через systemd --user. Установите Linux-пакет Ligament и войдите в пользовательскую графическую сессию.'
        : 'Could not start Link through systemd --user. Install the Ligament Linux package and use a logged-in desktop session.',
    'link_agent_linux_service_unavailable' => isRu
        ? 'Служба Link не найдена или не запустилась. Для tar.gz выполните ./install.sh --enable-link-agent от имени пользователя; проверьте systemctl --user status ligament-link-agent.'
        : 'Link service is missing or failed to start. For tar.gz, run ./install.sh --enable-link-agent as your user; check systemctl --user status ligament-link-agent.',
    'link_agent_pipe_unavailable' => isRu
        ? 'Не удаётся подключиться к службе Ligament Link Agent. Проверьте установку и состояние службы.'
        : 'Cannot connect to Ligament Link Agent. Check that the service is installed and running.',
    'link_agent_service_untrusted' => isRu
        ? 'Не удалось подтвердить службу Link как системную. Проверьте, что служба LigamentLinkAgent установлена от имени LocalSystem и запущена.'
        : 'Could not verify Link as a system service. Check that LigamentLinkAgent is installed as LocalSystem and running.',
    'link_agent_pipe_server_pid_failed' => isRu
        ? 'Windows не смогла определить процесс службы Link. Перезапустите службу и повторите привязку.'
        : 'Windows could not identify the Link service process. Restart the service and try binding again.',
    'link_agent_service_process_open_failed' => isRu
        ? 'Windows запретила проверить процесс службы Link. Проверьте права и журнал службы.'
        : 'Windows denied access to inspect the Link service process. Check permissions and the service log.',
    'link_agent_service_sid_mismatch' => isRu
        ? 'Служба Link запущена не от LocalSystem. Проверьте учётную запись службы LigamentLinkAgent.'
        : 'Link is not running as LocalSystem. Check the LigamentLinkAgent service account.',
    'link_agent_service_session_check_failed' => isRu
        ? 'Не удалось проверить сессию Named Pipe службы Link. Проверьте версию приложения и службы; перезапуск сам по себе может не устранить ошибку.'
        : 'Could not verify the Link service named-pipe session. Check the app and service versions; restarting alone may not fix this error.',
    'link_agent_service_not_session0' => isRu
        ? 'Служба Link запущена не в системной Session 0. Проверьте тип запуска службы Windows.'
        : 'Link is not running in system Session 0. Check the Windows service configuration.',
    'link_agent_server_mismatch' => isRu
        ? 'Адрес сервера в настройках службы Windows не совпадает с сервером приложения. Проверьте параметр SERVERURL установщика.'
        : 'The server URL configured for the Windows service differs from the app. Check the installer SERVERURL setting.',
    'link_agent_host_already_enrolled' => isRu
        ? 'Этот компьютер уже зарегистрирован. Сначала отзовите его в каталоге Ligament Link.'
        : 'This computer is already enrolled. Revoke it from the Ligament Link inventory first.',
    'link_agent_identity_store_failed' => isRu
        ? 'Служба Link не смогла сохранить защищённый ключ компьютера. Проверьте журнал %ProgramData%\\Ligament\\Link\\agent.log.'
        : 'Link service could not save the protected host identity. Check %ProgramData%\\Ligament\\Link\\agent.log.',
    'link_agent_enrollment_rejected' => isRu
        ? 'Сервер отклонил регистрацию компьютера. Проверьте срок токена и журнал %ProgramData%\\Ligament\\Link\\agent.log.'
        : 'The server rejected host enrollment. Check the token expiry and %ProgramData%\\Ligament\\Link\\agent.log.',
    'link_agent_pipe_communication_failed' => isRu
        ? 'Связь со службой Link прервалась. Проверьте, что служба запущена, и повторите попытку.'
        : 'The connection to Link service was interrupted. Check that it is running and try again.',
    'link_agent_invalid_response' => isRu
        ? 'Служба Link вернула некорректный ответ. Проверьте журнал службы.'
        : 'Link service returned an invalid response. Check the service log.',
    _ => isRu
        ? 'Не удалось привязать компьютер. Проверьте, что служба Ligament Link Agent запущена.'
        : 'Could not link this computer. Check that Ligament Link Agent service is running.',
  };
  // Retain only the numeric OS diagnostic, never raw native error details or
  // enrollment credentials. It distinguishes access denial from a missing PID.
  final nativeMessage = error is PlatformException ? error.message : null;
  final win32 = RegExp(r'Win32 error (\d+)').firstMatch(nativeMessage ?? '');
  return win32 == null ? message : '$message (Win32: ${win32.group(1)})';
}

class LinkAgentBindingFailure implements Exception {
  const LinkAgentBindingFailure(this.code, this.details);

  final String code;
  final Object details;

  @override
  String toString() => '$code: $details';
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
