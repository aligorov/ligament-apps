import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/ws_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('ReconnectBackoff (M-2)', () {
    test('без джиттера: экспонента 1с -> 2с -> 4с -> ... -> капа 30с', () {
      final b = ReconnectBackoff(random: Random(1), jitterFraction: 0);
      expect(b.nextDelay(), const Duration(seconds: 1));
      expect(b.nextDelay(), const Duration(seconds: 2));
      expect(b.nextDelay(), const Duration(seconds: 4));
      expect(b.nextDelay(), const Duration(seconds: 8));
      expect(b.nextDelay(), const Duration(seconds: 16));
      // 32с выше капы — остается 30с и дальше не растет
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.attempt, 7);
    });

    test('с джиттером: задержка в пределах +-20% от базовой', () {
      final b = ReconnectBackoff(random: Random(42), jitterFraction: 0.2);
      for (final expected in [1000, 2000, 4000, 8000, 16000, 30000, 30000]) {
        final d = b.nextDelay().inMilliseconds;
        expect(d, greaterThanOrEqualTo((expected * 0.8).floor()));
        expect(d, lessThanOrEqualTo((expected * 1.2).ceil()));
      }
    });

    test('reset возвращает к 1с', () {
      final b = ReconnectBackoff(random: Random(1), jitterFraction: 0);
      b.nextDelay();
      b.nextDelay();
      b.nextDelay(); // следующая была бы 8с
      b.reset();
      expect(b.attempt, 0);
      expect(b.nextDelay(), const Duration(seconds: 1));
    });

    test('кастомные base/max уважаются', () {
      final b = ReconnectBackoff(baseMs: 500, maxMs: 2000, jitterFraction: 0, random: Random(1));
      expect(b.nextDelay(), const Duration(milliseconds: 500));
      expect(b.nextDelay(), const Duration(seconds: 1));
      expect(b.nextDelay(), const Duration(seconds: 2)); // 2000 == капа
      expect(b.nextDelay(), const Duration(seconds: 2));
    });
  });

  group('WebSocketService channel generation', () {
    test('callbacks прежнего channel не трогают новое соединение', () async {
      final channels = <_FakeWebSocketChannel>[];
      final service = WebSocketService(channelFactory: (uri, headers) {
        final channel = _FakeWebSocketChannel();
        channels.add(channel);
        return channel;
      });
      addTearDown(service.disconnect);
      var connected = 0;
      var disconnected = 0;
      var prompts = 0;
      service.onConnected = () => connected++;
      service.onDisconnected = () => disconnected++;
      service.onPrompt = (_) => prompts++;

      service.connect(baseUrl: 'https://old.example', token: 'old');
      final oldChannel = channels.single;
      service.connect(baseUrl: 'https://new.example', token: 'new');
      final newChannel = channels.last;
      expect(oldChannel.fakeSink.isClosed, isTrue);

      newChannel.readyCompleter.complete();
      await Future<void>.delayed(Duration.zero);
      expect(connected, 1);
      expect(service.currentEndpoint, 'https://new.example');

      oldChannel.readyCompleter.complete();
      oldChannel.controller.add('{"type":"challenge_prompt"}');
      await oldChannel.controller.close();
      await Future<void>.delayed(Duration.zero);

      expect(connected, 1);
      expect(disconnected, 0);
      expect(prompts, 0);
      expect(service.isConnected, isTrue);
      expect(service.currentEndpoint, 'https://new.example');
    });
  });
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final controller = StreamController<dynamic>();
  final readyCompleter = Completer<void>();
  final _FakeWebSocketSink _sink = _FakeWebSocketSink();
  _FakeWebSocketSink get fakeSink => _sink;

  @override
  Future<void> get ready => readyCompleter.future;
  @override
  Stream<dynamic> get stream => controller.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  final Completer<void> _done = Completer<void>();
  bool isClosed = false;

  @override
  void add(dynamic data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }
  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    isClosed = true;
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }
  @override
  Future<void> get done => _done.future;
}
