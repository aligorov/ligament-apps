import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/service_console_host.dart';

class _FakeCapture implements ServiceConsoleCapture {
  bool started = false;
  bool stopped = false;
  String? accessMode;
  String? sessionId;
  void Function()? failureHandler;
  final List<Map<String, dynamic>> signals = [];

  @override
  void setFailureHandler(void Function() handler) {
    failureHandler = handler;
  }

  @override
  Future<void> start({
    required String sessionId,
    required String accessMode,
    required ApiClient api,
  }) async {
    this.sessionId = sessionId;
    this.accessMode = accessMode;
    started = true;
  }

  @override
  Future<void> handleSignal(Map<String, dynamic> signal) async {
    signals.add(signal);
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

void main() {
  group('serviceConsolePipeFromArgs', () {
    test('извлекает валидный pipe', () {
      final pipe = serviceConsolePipeFromArgs([
        '--other-flag',
        r'--service-console=\\.\pipe\LigamentConsole-12345678-1234-1234-1234-123456789abc',
      ]);
      expect(pipe, r'\\.\pipe\LigamentConsole-12345678-1234-1234-1234-123456789abc');
    });

    test('возвращает null если флага нет', () {
      expect(serviceConsolePipeFromArgs(['--minimized']), isNull);
    });

    test('бросает FormatException если uuid невалиден', () {
      expect(
        () => serviceConsolePipeFromArgs([r'--service-console=\\.\pipe\LigamentConsole-invalid-uuid']),
        throwsFormatException,
      );
    });
  });

  group('ServiceConsoleBootstrap', () {
    test('парсит корректный bootstrap payload', () {
      final bootstrap = ServiceConsoleBootstrap.fromNative({
        'session_id': '12345678-1234-1234-1234-123456789abc',
        'server_url': 'https://auth.example.com',
        'host_token': '0123456789abcdef0123456789abcdef0123456789abcdef',
      });
      expect(bootstrap.sessionId, '12345678-1234-1234-1234-123456789abc');
      expect(bootstrap.serverUrl.toString(), 'https://auth.example.com');
      expect(
        bootstrap.websocketUrl.toString(),
        'wss://auth.example.com/api/v1/endpoint/console/12345678-1234-1234-1234-123456789abc/ws',
      );
    });

    test('отклоняет http схему', () {
      expect(
        () => ServiceConsoleBootstrap.fromNative({
          'session_id': '12345678-1234-1234-1234-123456789abc',
          'server_url': 'http://auth.example.com',
          'host_token': '0123456789abcdef0123456789abcdef0123456789abcdef',
        }),
        throwsFormatException,
      );
    });
  });

  group('ServiceConsoleLease', () {
    test('монотонный дедлайн и проверка активности', () {
      int fakeTime = 1000;
      final lease = ServiceConsoleLease(elapsedMilliseconds: () => fakeTime);
      expect(lease.isLive, isFalse);

      lease.update(5000);
      expect(lease.isLive, isTrue);
      expect(lease.remainingMilliseconds, 5000 - ServiceConsoleLease.safetyMarginMilliseconds);

      fakeTime += 4800; // превысили deadline (5000 - 250 = 4750)
      expect(lease.isLive, isFalse);
    });
  });

  group('ServiceConsoleController', () {
    test('receive console_ready запускает capture', () async {
      final capture = _FakeCapture();
      final sentFrames = <Map<String, dynamic>>[];
      String? stopReason;

      final controller = ServiceConsoleController(
        sessionId: '12345678-1234-1234-1234-123456789abc',
        capture: capture,
        send: (frame) => sentFrames.add(frame),
        onStopped: (reason) async {
          stopReason = reason;
        },
      );

      controller.receive('{"type":"console_ready","session_id":"12345678-1234-1234-1234-123456789abc","access_mode":"full_control","lease_remaining_ms":30000,"ice_servers":[]}');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(capture.started, isTrue);
      expect(capture.accessMode, 'full_control');
      expect(stopReason, isNull);

      // сигнал от сервера пересылается в capture
      controller.receive('{"type":"signal","signal":{"type":"offer","sdp":"fake"}}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(capture.signals.length, 1);
      expect(capture.signals.first['type'], 'offer');

      // console_end останавливает сессию
      controller.receive('{"type":"console_end"}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.isStopped, isTrue);
      expect(capture.stopped, isTrue);
      expect(stopReason, 'server_ended');
    });
  });
}
