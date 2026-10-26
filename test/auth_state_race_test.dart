import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  var failSecureDelete = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    failSecureDelete = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>();
      switch (call.method) {
        case 'read':
          return secureStore[args!['key'] as String];
        case 'write':
          secureStore[args!['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          if (failSecureDelete) throw PlatformException(code: 'delete_failed');
          secureStore.remove(args?['key']);
          return null;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => call.method == 'create' ? 'test-player' : null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => call.method == 'initialize' ? true : null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? data) async =>
          const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
  });

  AuthState makeAuth(_FakeApiClient client) {
    final auth = AuthState();
    auth.api = client;
    auth.serverUrl = client.baseUrl;
    auth.token = 'old-token';
    auth.currentUser = {'username': 'ivanov', 'support_roles': ['it']};
    addTearDown(() {
      auth.telemetry.stopReporting();
      auth.ws.disconnect();
    });
    return auth;
  }

  test('cancelled loginClaim не финализует старый Bearer token', () async {
    final client = _FakeApiClient(token: null);
    final auth = makeAuth(client);
    auth.token = null;
    auth.currentUser = null;
    client.token = null;
    final future = auth.loginClaim(challengeId: 'ch', claimToken: 'claim');
    await client.claimCalls.stream.first;

    auth.cancelLoginAttempts();
    client.claimRequests.single.complete({
      'token': 'stale-token',
      'user': {'username': 'ivanov'},
    });
    await future;

    expect(auth.token, isNull);
    expect(auth.currentUser, isNull);
    expect(client.token, isNull);
    expect(secureStore['auth_token'], isNot('stale-token'));
  });

  test('новый loginClaim отзывает право предыдущего на _finalizeLogin',
      () async {
    final client = _FakeApiClient();
    final auth = makeAuth(client);
    auth.token = null;
    auth.currentUser = null;
    client.token = null;
    final first = auth.loginClaim(challengeId: 'old', claimToken: 'old');
    await client.claimCalls.stream.first;
    final second = auth.loginClaim(challengeId: 'new', claimToken: 'new');
    await client.claimCalls.stream.firstWhere((count) => count == 2);

    client.claimRequests.first.complete({
      'token': 'stale-token',
      'user': {'username': 'old'},
    });
    await first;
    expect(auth.token, isNull);
    expect(client.token, isNull);

    client.claimRequests.last.complete({'status': 'pending'});
    expect((await second)['status'], 'pending');
  });

  test('stale loaders не перезаписывают состояние после logout/new token',
      () async {
    final client = _FakeApiClient()..deferLoaders = true;
    final auth = makeAuth(client);
    final loads = <Future<void>>[
      auth.loadSupportQueue(),
      auth.loadPendingChallenges(),
      auth.loadAllowedApps(),
      auth.loadHistory(),
      auth.loadNotifications(),
      auth.loadRdpTargets(),
      auth.refreshRelays(),
    ];
    await auth.logout();

    auth.api = _FakeApiClient(token: 'new-token');
    auth.token = 'new-token';
    auth.currentUser = {'username': 'new', 'support_roles': ['it']};
    auth.supportQueue = [
      {'id': 'new'}
    ];
    auth.pendingChallenges = [
      {'id': 'new'}
    ];
    auth.allowedApps = [
      {'id': 'new'}
    ];
    auth.history = [
      {'id': 'new'}
    ];
    auth.notifications = [
      {'id': 'new', 'is_read': true}
    ];
    auth.unreadNotificationsCount = 0;
    auth.rdpTargets = [
      {'id': 'new'}
    ];
    auth.relays = [
      {'name': 'new'}
    ];

    client.supportQueueResult.complete([
      {'id': 'stale'}
    ]);
    client.pendingResult.complete([
      {'id': 'stale', 'metadata': <String, dynamic>{}}
    ]);
    client.appsResult.complete([
      {'id': 'stale'}
    ]);
    client.historyResult.complete([
      {'id': 'stale'}
    ]);
    client.notificationsResult.complete([
      {'id': 'stale', 'is_read': false}
    ]);
    client.rdpTargetsResult.complete([
      {'id': 'stale'}
    ]);
    client.configResult.complete({
      'relays': [
        {'name': 'stale'}
      ]
    });
    await Future.wait(loads);

    expect(auth.supportQueue.single['id'], 'new');
    expect(auth.pendingChallenges.single['id'], 'new');
    expect(auth.allowedApps.single['id'], 'new');
    expect(auth.history.single['id'], 'new');
    expect(auth.notifications.single['id'], 'new');
    expect(auth.unreadNotificationsCount, 0);
    expect(auth.rdpTargets.single['id'], 'new');
    expect(auth.relays.single['name'], 'new');
  });

  test('browser SSO ошибка сохраняет prompt, success не закрывает другой',
      () async {
    final client = _FakeApiClient();
    final auth = makeAuth(client);
    final promptA = {'id': 'a', 'sp_name': 'A'};
    auth.activeBrowserSsoPrompt = promptA;

    final failed = auth.resolveBrowserSso(false);
    expect(auth.activeBrowserSsoPrompt, same(promptA));
    client.browserDecision.completeError(ApiException(500, 'db_error'));
    await failed;
    expect(auth.activeBrowserSsoPrompt?['id'], 'a');

    auth.activeBrowserSsoPrompt = null;
    client.pendingResponse = [
      {
        'id': 'a',
        'type': 'browser_sso',
        'purpose': 'browser_sso',
        'expires_at': DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      }
    ];
    await auth.loadPendingChallenges();
    expect(auth.activeBrowserSsoPrompt?['id'], 'a',
        reason: 'failed decision не добавляется в resolved');

    client.browserDecision = Completer<void>();
    final succeeded = auth.resolveBrowserSso(false);
    auth.activeBrowserSsoPrompt = {'id': 'b', 'sp_name': 'B'};
    client.browserDecision.complete();
    await succeeded;
    expect(auth.activeBrowserSsoPrompt?['id'], 'b');
  });

  test('submitDecision старого challenge не заменяет активный prompt',
      () async {
    final client = _FakeApiClient();
    client.pendingResponse = [
      {
        'id': 'b',
        'metadata': <String, dynamic>{},
        'expires_in_seconds': 100,
      }
    ];
    final auth = makeAuth(client);
    auth.activePrompt = {'challenge_id': 'a'};
    final future = auth.submitDecision(challengeId: 'a', approve: false);
    auth.activePrompt = {'challenge_id': 'b', 'expires_in_seconds': 90};
    client.challengeDecisionResult.complete();
    await future;

    expect(auth.activePrompt?['challenge_id'], 'b');
  });

  test('logout tombstone блокирует восстановление при failed secure delete',
      () async {
    final client = _FakeApiClient();
    final auth = makeAuth(client);
    secureStore['auth_token'] = 'persistent-secret';
    failSecureDelete = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', client.baseUrl);

    await auth.logout();
    expect(secureStore['auth_token'], 'persistent-secret');
    expect(prefs.getBool('auth_logged_out'), isTrue);

    final restarted = AuthState();
    await restarted.init();
    expect(restarted.token, isNull);
    expect(restarted.currentUser, isNull);
    expect(restarted.isLoggedIn, isFalse);
    expect(prefs.getBool('auth_logged_out'), isTrue);
  });
}

class _FakeApiClient extends ApiClient {
  _FakeApiClient({String? token})
      : super(baseUrl: 'https://test.example', token: token ?? 'old-token');

  bool deferLoaders = false;
  List<Map<String, dynamic>> pendingResponse = const [];

  final claimRequests = <Completer<Map<String, dynamic>>>[];
  final claimCalls = StreamController<int>.broadcast(sync: true);
  var supportQueueResult = Completer<List<Map<String, dynamic>>>();
  var pendingResult = Completer<List<Map<String, dynamic>>>();
  var appsResult = Completer<List<Map<String, dynamic>>>();
  var historyResult = Completer<List<Map<String, dynamic>>>();
  var notificationsResult = Completer<List<Map<String, dynamic>>>();
  var rdpTargetsResult = Completer<List<Map<String, dynamic>>>();
  var configResult = Completer<Map<String, dynamic>>();
  var browserDecision = Completer<void>();
  var challengeDecisionResult = Completer<void>();

  @override
  Future<Map<String, dynamic>> loginClaim({
    required String challengeId,
    required String claimToken,
    required String deviceName,
    required String platform,
    String osVersion = '',
    String appVersion = '',
    String pushToken = '',
    Map<String, dynamic>? securityPosture,
    Map<String, dynamic>? windowsIdentity,
    bool updateToken = true,
  }) {
    final request = Completer<Map<String, dynamic>>();
    claimRequests.add(request);
    claimCalls.add(claimRequests.length);
    return request.future;
  }

  @override
  Future<void> logout() async {
    token = null;
  }

  @override
  Future<List<Map<String, dynamic>>> getSupportQueue({String? category}) =>
      deferLoaders ? supportQueueResult.future : Future.value(const []);

  @override
  Future<List<Map<String, dynamic>>> getPendingChallenges() => deferLoaders
      ? pendingResult.future
      : Future.value(pendingResponse);

  @override
  Future<List<Map<String, dynamic>>> getAllowedApps() =>
      deferLoaders ? appsResult.future : Future.value(const []);

  @override
  Future<List<Map<String, dynamic>>> getHistory() =>
      deferLoaders ? historyResult.future : Future.value(const []);

  @override
  Future<List<Map<String, dynamic>>> getNotifications({int limit = 50}) =>
      deferLoaders ? notificationsResult.future : Future.value(const []);

  @override
  Future<List<Map<String, dynamic>>> getRdpTargets({String? instanceId}) =>
      deferLoaders ? rdpTargetsResult.future : Future.value(const []);

  @override
  Future<Map<String, dynamic>> getConfig() => deferLoaders
      ? configResult.future
      : Future.value(const {'relays': <Map<String, dynamic>>[]});

  @override
  Future<List<Map<String, dynamic>>> getIceServers() async => const [];

  @override
  Future<void> browserSsoDecision({
    required String challengeId,
    required bool approve,
    String? ssoTicket,
  }) =>
      browserDecision.future;

  @override
  Future<void> challengeDecision({
    required String challengeId,
    required String decision,
    String? numberMatch,
    String? code,
    bool? passkey,
  }) =>
      challengeDecisionResult.future;
}
