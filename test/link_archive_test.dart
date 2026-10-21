import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/screens/link_catalog_screen.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:provider/provider.dart';

class _ArchiveApi extends ApiClient {
  _ArchiveApi() : super(baseUrl: 'https://example.test');
  int calls = 0;
  String? reason;
  bool denied = false;
  @override
  Future<void> archiveLinkHost(String agentId, {required String reason}) async {
    expect(agentId, 'test-agent');
    calls++;
    this.reason = reason;
    if (denied) throw ApiException(403, 'owner_unlink_denied');
  }
}

class _ArchiveAuth extends ChangeNotifier implements AuthState {
  _ArchiveAuth({bool admin = false, bool owner = false}) {
    linkHosts = [
      <String, dynamic>{
        'id': 'test-agent',
        'hostname': 'TEST-PC',
        'ad_ou': 'Finance',
        'group_name': 'Workstations',
        'is_online': false,
        'can_archive': admin,
        'can_unlink': owner,
      },
    ];
  }
  @override
  final _ArchiveApi api = _ArchiveApi();
  @override
  late List<Map<String, dynamic>> linkHosts;
  @override
  bool get linkFeatureAvailable => true;
  @override
  bool get linkHostsLoading => false;
  @override
  String? get linkHostsError => null;
  @override
  bool get isRu => true;
  @override
  String get localeCode => 'ru';
  @override
  Future<void> loadLinkHosts() async {
    if (api.calls > 0 && !api.denied) {
      linkHosts = [];
      notifyListeners();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> showHost(WidgetTester tester, _ArchiveAuth auth) async {
    await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
      value: auth,
      child: const MaterialApp(home: LinkCatalogScreen()),
    ));
    await tester.pump();
    await tester.tap(find.text('Finance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workstations'));
    await tester.pumpAndSettle();
  }

  testWidgets('connection access alone does not show removal', (tester) async {
    final auth = _ArchiveAuth();
    await showHost(tester, auth);
    expect(find.text('TEST-PC'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });

  testWidgets('administrator confirms removal and keeps history notice',
      (tester) async {
    final auth = _ArchiveAuth(admin: true);
    await showHost(tester, auth);
    await tester.tap(find.byTooltip('Удалить из LINK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('История сохранится'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Причина (необязательно)'), 'Замена ПК');
    await tester.tap(find.text('Подтвердить'));
    await tester.pumpAndSettle();
    expect(auth.api.calls, 1);
    expect(auth.api.reason, 'Замена ПК');
    expect(find.text('TEST-PC'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });

  testWidgets('owner can cancel unlink without sending a request',
      (tester) async {
    final auth = _ArchiveAuth(owner: true);
    await showHost(tester, auth);
    await tester.tap(find.byTooltip('Отвязать мой ПК'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(auth.api.calls, 0);
    expect(find.text('TEST-PC'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });

  testWidgets('server denial leaves PC in inventory', (tester) async {
    final auth = _ArchiveAuth(owner: true);
    auth.api.denied = true;
    await showHost(tester, auth);
    await tester.tap(find.byTooltip('Отвязать мой ПК'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подтвердить'));
    await tester.pumpAndSettle();
    expect(auth.api.calls, 1);
    expect(find.text('TEST-PC'), findsOneWidget);
    expect(find.textContaining('Не удалось удалить ПК.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
  });
}
