import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/screens/link_catalog_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';

class _CatalogAuthState extends ChangeNotifier implements AuthState {
  _CatalogAuthState(this.linkHosts);

  @override
  final List<Map<String, dynamic>> linkHosts;

  @override
  bool linkFeatureAvailable = true;

  @override
  bool linkHostsLoading = false;

  @override
  String? linkHostsError;

  @override
  String get localeCode => 'ru';

  @override
  bool get isRu => true;

  @override
  Future<void> loadLinkHosts() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('OU and group host rows are lazily rendered by SliverList',
      (tester) async {
    final hosts = List<Map<String, dynamic>>.generate(
      1000,
      (index) => <String, dynamic>{
        'hostname': 'HOST-${index.toString().padLeft(4, '0')}',
        'ad_ou': 'OU=Finance',
        'group_name': 'Workstations',
        'is_online': true,
        'os_family': 'windows',
      },
      growable: false,
    );
    final auth = _CatalogAuthState(hosts);
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: const MaterialApp(home: LinkCatalogScreen()),
    ));
    await tester.pump();

    await tester.tap(find.text('OU=Finance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workstations'));
    await tester.pumpAndSettle();

    expect(find.text('HOST-0000'), findsOneWidget);
    expect(find.text('HOST-0999'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });
}
