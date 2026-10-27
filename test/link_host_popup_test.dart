import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_host_overlay.dart';
import 'package:ligament_authenticator/screens/support_approval_modal.dart';
import 'package:ligament_authenticator/services/link_host_session.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const _id = '10000000-0000-4000-8000-000000000001';
const _nextId = '20000000-0000-4000-8000-000000000002';
const _pipe = r'\\.\pipe\LigamentLinkHost-0123456789abcdef0123456789abcdef';

// Return the actual plugin contracts, not null for typed native queries.
class _NativeWindow {
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? intercept;
  bool minimized = false;
  Size size = const Size(580, 780);

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (call) async {
      calls.add(call);
      await intercept?.call(call);
      if (call.method == 'isMinimized') return minimized;
      if (call.method == 'restore') minimized = false;
      if (call.method == 'getBounds') {
        return {'x': 0.0, 'y': 0.0, 'width': size.width, 'height': size.height};
      }
      if (call.method == 'setBounds') {
        final args = call.arguments as Map;
        if (args['width'] != null) {
          size = Size(args['width'] as double, args['height'] as double);
        }
      }
      return null;
    });
    const display = {
      'id': 1,
      'name': 'test',
      'size': {'width': 1200.0, 'height': 900.0},
      'visiblePosition': {'x': 0.0, 'y': 0.0},
      'visibleSize': {'width': 1200.0, 'height': 900.0},
      'scaleFactor': 1.0,
    };
    messenger.setMockMethodCallHandler(const MethodChannel('screen_retriever'),
        (call) async {
      if (call.method == 'getPrimaryDisplay') return display;
      if (call.method == 'getAllDisplays') return {'displays': [display]};
      if (call.method == 'getCursorScreenPoint') return {'x': 0.0, 'y': 0.0};
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'), (_) async => null);
    addTearDown(() {
      for (final name in ['window_manager', 'screen_retriever', 'tray_manager']) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });
  }

  List<String> get methods => calls.map((call) => call.method).toList();
}

Future<void> _mount(WidgetTester tester, LinkHostWorkerState state) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(LinkHostOverlay(state: state));
  await tester.pump();
}

void main() {
  testWidgets('minimized consent window sizes, centers, restores, shows and focuses',
      (tester) async {
    final native = _NativeWindow()..minimized = true;
    native.install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    expect(native.size, const Size(580, 780));
    expect(native.methods, containsAllInOrder([
      'setPreventClose', 'setMinimumSize', 'setBounds', 'getBounds',
      'setBounds', 'isMinimized', 'restore', 'show', 'focus',
    ]));
    expect(state.phase, LinkHostWorkerPhase.awaitingConsent);
    expect(state.confirmationCode, isEmpty);
    native.calls.clear();
    state.clearUnreadChat();
    await tester.pump();
    expect(native.calls, isEmpty);
    state.markClosed();
    expect(await decision, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new request with the same size clears code and refocuses popup',
      (tester) async {
    final native = _NativeWindow()..install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Первый');
    final oldDecision = state.awaitConsent();
    bool? oldResult;
    unawaited(oldDecision.then((value) => oldResult = value));
    await _mount(tester, state);
    await tester.enterText(
        find.byKey(const Key('support-number-match-code')), '27');
    native.calls.clear();
    state.showSession(_nextId, 'control', 'Второй');
    final newDecision = state.awaitConsent();
    await tester.pump();
    expect(native.methods, containsAllInOrder(['show', 'focus']));
    expect(oldResult, false);
    expect(find.text('27'), findsNothing);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);
    state.denyConsent();
    expect(await newDecision, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final end in ['close', 'dispose', 'approval']) {
    testWidgets('pending native layout stops after $end', (tester) async {
      final gate = Completer<Object?>();
      final native = _NativeWindow()
        ..intercept = (call) => call.method == 'setMinimumSize'
            ? gate.future
            : Future.value(null);
      native.install();
      final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
      final decision = state.awaitConsent();
      await _mount(tester, state);
      expect(native.methods, contains('setMinimumSize'));
      if (end == 'dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        if (end == 'approval') {
          state.approveConsent('27');
        } else {
          state.markClosed();
        }
        await tester.pump();
      }
      native.calls.clear();
      gate.complete(null);
      await tester.pump();
      if (end == 'approval') {
        expect(native.size, const Size(740, 104));
        expect(native.methods, isNot(contains('focus')));
        expect(native.methods.where((method) => method == 'show'), hasLength(1));
      } else {
        expect(native.calls, isEmpty);
      }
      state.markClosed();
      expect(await decision, end == 'approval');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final failingMethod in ['setBounds', 'show', 'focus']) {
    testWidgets('$failingMethod failure retries exactly three times and denies',
        (tester) async {
      var failures = 0;
      final native = _NativeWindow()
        ..intercept = (call) async {
          if (call.method == failingMethod) {
            failures++;
            throw PlatformException(code: 'native_failure');
          }
          return null;
        };
      native.install();
      final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
      final decision = state.awaitConsent();
      await _mount(tester, state);
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump(const Duration(milliseconds: 750));
      expect(failures, 3);
      expect(await decision, false);
      expect(state.consentUiAvailable, false);
      expect(state.phase, LinkHostWorkerPhase.closing);
      await tester.pump(const Duration(seconds: 2));
      expect(failures, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('transient show failure recovers without granting consent',
      (tester) async {
    var shows = 0;
    final native = _NativeWindow()
      ..intercept = (call) async {
        if (call.method == 'show' && ++shows == 1) {
          throw PlatformException(code: 'transient');
        }
        return null;
      };
    native.install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    await tester.pump(const Duration(milliseconds: 750));
    expect(shows, 2);
    expect(native.methods.last, 'focus');
    expect(state.consentUiAvailable, true);
    expect(state.phase, LinkHostWorkerPhase.awaitingConsent);
    state.markClosed();
    expect(await decision, false);
    await tester.pumpWidget(const SizedBox.shrink());
    native.calls.clear();
    await tester.pump(const Duration(seconds: 2));
    expect(native.calls, isEmpty);
  });

  testWidgets('setPreventClose failure is caught and denies consent',
      (tester) async {
    final native = _NativeWindow()
      ..intercept = (call) async {
        if (call.method == 'setPreventClose') {
          throw PlatformException(code: 'prevent_close_failed');
        }
        return null;
      };
    native.install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    expect(tester.takeException(), isNull);
    expect(state.consentUiAvailable, false);
    expect(await decision, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native minimize, tray restore and close use production listeners',
      (tester) async {
    final native = _NativeWindow()..install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    final listener = tester.state(find.byType(LinkHostOverlay));
    native.calls.clear();
    (listener as WindowListener).onWindowMinimize();
    await tester.pump();
    expect(native.methods, ['hide']);
    native.calls.clear();
    native.minimized = true;
    (listener as TrayListener).onTrayIconMouseDown();
    await tester.pump();
    expect(native.methods, containsAllInOrder(['restore', 'show', 'focus']));
    (listener as WindowListener).onWindowClose();
    await tester.pump();
    expect(await decision, false);
    expect(state.phase, LinkHostWorkerPhase.closing);
    expect(find.byType(SupportApprovalModal), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('repeated consent wait observes one decision', (tester) async {
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final first = state.awaitConsent();
    bool? firstResult;
    unawaited(first.then((value) => firstResult = value));
    final second = state.awaitConsent();
    state.approveConsent('27');
    expect(await second, true);
    await tester.pump();
    expect(firstResult, true);
    state.markClosed();
  });

  testWidgets('consent timeout closes popup and rejects late approval',
      (tester) async {
    _NativeWindow().install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    await tester.pump(const Duration(seconds: 46));
    expect(await decision, false);
    expect(state.phase, LinkHostWorkerPhase.closing);
    expect(find.byType(SupportApprovalModal), findsNothing);
    state.approveConsent('27');
    expect(state.confirmationCode, isEmpty);
    expect(state.phase, LinkHostWorkerPhase.closing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('denied consent cannot be reopened by another waiter',
      (tester) async {
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    state.denyConsent();
    expect(await decision, false);
    final repeated = state.awaitConsent();
    expect(state.phase, LinkHostWorkerPhase.closing);
    expect(await repeated, false);
    state.approveConsent('27');
    expect(state.confirmationCode, isEmpty);
  });

  testWidgets('obsolete pending native failure cannot deny a new request',
      (tester) async {
    final gate = Completer<Object?>();
    var attempts = 0;
    final native = _NativeWindow()
      ..intercept = (call) async {
        if (call.method == 'setMinimumSize') {
          attempts++;
          if (attempts == 1) return gate.future;
          throw PlatformException(code: 'new_request_failure');
        }
        return null;
      };
    native.install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Первый');
    final first = state.awaitConsent();
    await _mount(tester, state);
    state.showSession(_nextId, 'control', 'Второй');
    final second = state.awaitConsent();
    gate.completeError(PlatformException(code: 'obsolete_failure'));
    await tester.pump();
    expect(await first, false);
    expect(attempts, 2);
    expect(state.consentUiAvailable, true);
    await tester.pump(const Duration(milliseconds: 750));
    expect(attempts, 3);
    expect(state.consentUiAvailable, true);
    await tester.pump(const Duration(milliseconds: 750));
    expect(attempts, 4);
    expect(state.consentUiAvailable, false);
    expect(await second, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposal cancels a scheduled failed-layout retry',
      (tester) async {
    final native = _NativeWindow()
      ..intercept = (call) async {
        if (call.method == 'show') throw PlatformException(code: 'show_failed');
        return null;
      };
    native.install();
    final state = LinkHostWorkerState()..showSession(_id, 'view', 'Оператор');
    final decision = state.awaitConsent();
    await _mount(tester, state);
    await tester.pumpWidget(const SizedBox.shrink());
    native.calls.clear();
    await tester.pump(const Duration(seconds: 2));
    expect(native.calls, isEmpty);
    state.markClosed();
    expect(await decision, false);
  });

  for (final ending in ['denial', 'revoke', 'ipc_failure', 'ui_unavailable']) {
    testWidgets('autonomous worker with no GUI fails closed on $ending',
        (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const host = MethodChannel('ligament/link_host');
      const rtc = MethodChannel('FlutterWebRTC.Method');
      final calls = <String>[];
      final rtcCalls = <String>[];
      final sent = <Map<String, dynamic>>[];
      final incoming = Completer<String>();
      messenger.setMockMethodCallHandler(host, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'bootstrap':
            expect(call.arguments, _pipe);
            return jsonEncode({
              'type': 'session_offer',
              'payload': {
                'session_id': _id,
                'access_mode': 'view',
                'operator_name': 'Оператор',
                'access_type': 'attended',
                'confirmation_required': true,
                'confirmation_digits': 2,
                'sdp': 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96',
                'ice_servers': [],
              },
            });
          case 'receive':
            return incoming.future;
          case 'send':
            sent.add(Map<String, dynamic>.from(
                jsonDecode(call.arguments as String) as Map));
            return true;
          case 'close':
            if (!incoming.isCompleted) incoming.complete('');
            return null;
        }
        fail('Unexpected native worker call: ${call.method}');
      });
      messenger.setMockMethodCallHandler(rtc, (call) async {
        rtcCalls.add(call.method);
        throw PlatformException(code: 'media_must_not_start');
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(host, null);
        messenger.setMockMethodCallHandler(rtc, null);
      });
      final state = LinkHostWorkerState();
      final worker = runLinkHostWorker(_pipe, state: state);
      await tester.pump();
      expect(state.phase, LinkHostWorkerPhase.awaitingConsent);
      expect(sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 10));
      switch (ending) {
        case 'denial':
          state.denyConsent();
        case 'ui_unavailable':
          state.markConsentUiUnavailable();
        case 'revoke':
          incoming.complete(jsonEncode({'type': 'session_revoke', 'session_id': _id}));
        case 'ipc_failure':
          incoming.completeError(PlatformException(code: 'pipe_closed'));
      }
      await tester.pump(const Duration(milliseconds: 10));
      await worker;
      expect(state.phase, LinkHostWorkerPhase.closed);
      expect(state.confirmationCode, isEmpty);
      expect(calls, contains('close'));
      expect(rtcCalls, isEmpty);
      expect(sent.where((frame) => (frame['payload'] as Map?)?['accepted'] == true),
          isEmpty);
      if (ending == 'denial' || ending == 'ui_unavailable') {
        expect((sent.first['payload'] as Map)['reason'],
            ending == 'denial' ? 'host_consent_denied' : 'host_ui_unavailable');
      }
    });
  }
}
