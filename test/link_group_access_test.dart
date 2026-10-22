import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_catalog_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';

class _FakeAuth extends ChangeNotifier implements AuthState {
  _FakeAuth({this.linkAdmin = true});

  final bool linkAdmin;

  @override
  bool get linkFeatureAvailable => true;

  @override
  bool get isLinkAdmin => linkAdmin;

  @override
  bool get isLinkOperator => true;

  @override
  bool get isRu => true;

  @override
  List<Map<String, dynamic>> get linkHosts => [
        {
          'id': 'agent-1',
          'hostname': 'PC-BUH-01',
          'ad_ou': 'OU=Accounting,DC=corp',
          'group_name': 'Бухгалтерия',
          'is_online': true,
          'unattended_enabled': false,
        },
      ];

  @override
  bool get linkHostsLoading => false;

  @override
  String? get linkHostsError => null;

  @override
  Future<void> loadLinkHosts() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('LinkCatalogScreen displays operator access button for LinkAdmin',
      (tester) async {
    final auth = _FakeAuth(linkAdmin: true);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const LinkCatalogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // OU folder should have the folder-access button
    final ouAccessBtn = find.byKey(const ValueKey('folder-access-OU=Accounting,DC=corp'));
    expect(ouAccessBtn, findsOneWidget);

    // Tap the OU folder to expand it and reveal sub-groups
    await tester.tap(find.text('OU=Accounting,DC=corp'));
    await tester.pumpAndSettle();

    final groupAccessBtn = find.byKey(const ValueKey('folder-access-Бухгалтерия'));
    expect(groupAccessBtn, findsOneWidget);
  });

  testWidgets('LinkCatalogScreen hides operator access button for non-admin',
      (tester) async {
    final auth = _FakeAuth(linkAdmin: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: const LinkCatalogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ouAccessBtn = find.byKey(const ValueKey('folder-access-OU=Accounting,DC=corp'));
    expect(ouAccessBtn, findsNothing);
  });
}
