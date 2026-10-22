import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';

class _InventoryClient extends ApiClient {
  _InventoryClient() : super(baseUrl: 'https://example.invalid');
  Object? failure;
  @override
  Future<List<Map<String, dynamic>>> getLinkHosts() async {
    if (failure != null) throw failure!;
    return [
      {'hostname': 'PC', 'is_online': true}
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed inventory refresh invalidates online, recovery restores it',
      () async {
    final client = _InventoryClient();
    final state = AuthState()
      ..token = 'test'
      ..currentUser = {'username': 'test'}
      ..api = client;
    await state.loadLinkHosts();
    expect(state.linkHosts.single['is_online'], true);
    client.failure = ApiException(503, 'server_unavailable');
    await state.loadLinkHosts();
    expect(state.linkHosts.single['is_online'], null);
    expect(state.linkHostsError, 'server_unavailable');
    client.failure = null;
    await state.loadLinkHosts();
    expect(state.linkHosts.single['is_online'], true);
    expect(state.linkHostsError, null);
    client.failure = StateError('network unavailable');
    await state.loadLinkHosts();
    expect(state.linkHosts.single['is_online'], null);
    expect(state.linkHostsError, isNotNull);
    state.dispose();
  });
}
