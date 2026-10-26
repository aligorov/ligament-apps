import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/debug_log_service.dart';
import 'package:ligament_authenticator/widgets/debug_action_scope.dart';

class _ActionLogs extends DebugLogService {
  final entries = <Map<String, Object?>>[];

  @override
  void record(String event,
      {Object? error, Map<String, Object?> fields = const {}}) {
    entries.add({'event': event, ...fields});
  }

  String get text => entries
      .map((entry) =>
          entry.entries.map((field) => '${field.key}=${field.value}').join(' '))
      .join('\n');
}

void main() {
  late _ActionLogs logs;
  setUp(() => logs = _ActionLogs());

  testWidgets(
      'pointer intent and scroll are recorded without labels or position',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: DebugActionScope(
        debugLogs: logs,
        child: Scaffold(
            body: TextButton(
          onPressed: () => tapped++,
          child: const Text('private-button-label'),
        )),
      ),
    ));
    await tester.tap(find.text('private-button-label'));
    final position = tester.getCenter(find.text('private-button-label'));
    tester.binding.handlePointerEvent(PointerScrollEvent(
      position: position,
      scrollDelta: const Offset(0, 10),
    ));
    expect(tapped, 1);
    expect(logs.text, contains('event=ui.pointer.down'));
    expect(logs.text, contains('event=ui.pointer.up'));
    expect(logs.text, contains('operation=scroll'));
    expect(logs.text, isNot(contains('private-button-label')));
    expect(logs.text, isNot(contains('position=')));
    expect(logs.text, isNot(contains('scrollDelta=')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard diagnostics redact characters and detach on disposal',
      (tester) async {
    await tester.pumpWidget(DebugActionScope(
      debugLogs: logs,
      child: const SizedBox(),
    ));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ, character: 'q');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    final text = logs.text;
    expect(text, contains('operation=key_down phase=key_redacted'));
    expect(text, contains('operation=key_up phase=key_redacted'));
    expect(text, contains('phase=enter'));
    expect(text, isNot(contains('character=')));
    expect(text, isNot(contains('keyQ')));
    await tester.pumpWidget(const SizedBox());
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(logs.text, text);
  });

  testWidgets('navigation logs anonymous route IDs without names or arguments',
      (tester) async {
    final observer = DebugNavigationObserver(debugLogs: logs);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: const SizedBox(),
    ));
    navigator.currentState!.push(MaterialPageRoute<void>(
      settings: const RouteSettings(
        name: '/private-token',
        arguments: {'password': 'private-password'},
      ),
      builder: (_) => const Scaffold(body: Text('private-page-text')),
    ));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(logs.text, contains('event=ui.navigation'));
    expect(logs.text, contains('operation=push'));
    expect(logs.text, contains('operation=pop'));
    expect(logs.text, matches(RegExp(r'request_id=\d+')));
    for (final secret in [
      'private-token',
      'private-password',
      'private-page-text'
    ]) {
      expect(logs.text, isNot(contains(secret)));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
