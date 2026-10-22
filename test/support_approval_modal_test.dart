import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/i18n/app_strings.dart';
import 'package:ligament_authenticator/screens/support_approval_modal.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';

class _ApprovalAuth extends ChangeNotifier implements AuthState {
  @override
  String get localeCode => 'ru';
  @override
  bool get isLinkAdmin => false;
  @override
  bool get isLinkOperator => false;
  @override
  Map<String, dynamic>? activeSupportPrompt = {
    'session_id': 'sos-test',
    'number_match': '27',
    'access_mode': 'full_control',
  };
  int approvals = 0;
  String? approvedCode;
  @override
  Future<void> confirmSupport(
      {required String sessionId, String? numberMatch}) async {
    expect(sessionId, 'sos-test');
    approvals++;
    approvedCode = numberMatch;
    activeSupportPrompt = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('SOS keeps its existing confirmation path and checks digits',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = _ApprovalAuth();
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                      body: TextButton(
                    child: const Text('open'),
                    onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => SupportApprovalModal(
                            prompt: auth.activeSupportPrompt!)),
                  )))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('support-number-match-code'));
    final approve = find.widgetWithText(ElevatedButton, 'Разрешить доступ');
    expect(tester.widget<ElevatedButton>(approve).onPressed, isNull);
    await tester.enterText(field, '28');
    await tester.pump();
    expect(tester.widget<ElevatedButton>(approve).onPressed, isNotNull);
    await tester.tap(approve);
    await tester.pump();
    expect(auth.approvals, 0);
    expect(find.textContaining('Неверное контрольное число'), findsOneWidget);
    await tester.enterText(field, '27');
    await tester.pump();
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(auth.approvals, 1);
    expect(auth.approvedCode, '27');
    expect(find.byType(SupportApprovalModal), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });

  testWidgets(
      'standalone Link prompt expires without reading SOS account state',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var denied = 0;
    await tester.pumpWidget(MaterialApp(
        home: SupportApprovalModal(
      prompt: const {'session_id': 'link-test', 'expires_in_seconds': 1},
      stringsOverride: AppStrings('ru'),
      numberMatchLength: 2,
      onApprove: (_) async {
        fail('expired prompt approved');
      },
      onDeny: () async {
        denied++;
      },
    )));
    await tester.pump(const Duration(seconds: 2));
    expect(denied, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
