import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/deep_link_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deep-link ligament://rdp/<uuid> (аудит RDP-11 + контракт T6): единая
/// точка разбора Uri (scheme==ligament, host==rdp, pathSegment=UUID) и
/// семантика pending-ссылки в AuthState (не залогинен → сохранить,
/// применить после логина; logout → сброс). Контракты различаются по
/// наличию grant-токена в query: без токена — target UUID (приложение
/// само вызывает POST /rdp/grant), с токеном — легаси bridge-грант.
/// Чистые функции — без платформы и сети.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // AudioPlayer() создаётся в конструкторе AuthState -> дергает каналы.
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
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    // wakelock_plus (pigeon BasicMessageChannel, вызывается из
    // SupportService.stopScreenSharing при logout): без мока повторная
    // AuthState.logout в файле валит тест channel-error'ом — отвечаем
    // пустым success-envelope.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? data) async =>
          const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
  });

  const grantId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
  const targetId = '01234567-89ab-cdef-0123-456789abcdef';

  group('parseLigamentDeepLink: контракт T6 ligament://rdp/<target_uuid>', () {
    test('без query — target-режим (намерение подключиться)', () {
      final link = parseLigamentDeepLink('ligament://rdp/$targetId');
      expect(link, isNotNull);
      expect(link!.kind, LigamentDeepLinkKind.target);
      expect(link.targetId, targetId);
      expect(link.grantId, isNull); // это НЕ грант
      expect(link.grantToken, isNull); // токенов в URI нет НИКОГДА
      expect(link.uuid, targetId);
    });

    test('заглавные scheme/host и UUID нормализуются (target)', () {
      final link = parseLigamentDeepLink(
          'LIGAMENT://RDP/01234567-89AB-CDEF-0123-456789ABCDEF');
      expect(link, isNotNull);
      expect(link!.kind, LigamentDeepLinkKind.target);
      expect(link.targetId, targetId);
    });

    test('пустой query-токен (t=) трактуется как target', () {
      final link = parseLigamentDeepLink('ligament://rdp/$targetId?t=');
      expect(link!.kind, LigamentDeepLinkKind.target);
      expect(link.grantToken, isNull);
      final b = parseLigamentDeepLink('ligament://rdp/$targetId?token=');
      expect(b!.kind, LigamentDeepLinkKind.target);
    });

    test('хвостовой слэш и пробелы вокруг (target)', () {
      final link = parseLigamentDeepLink('  ligament://rdp/$targetId/ ');
      expect(link, isNotNull);
      expect(link!.targetId, targetId);
    });

    test('мусорные query-параметры не превращают target в грант', () {
      final link = parseLigamentDeepLink('ligament://rdp/$targetId?src=web');
      expect(link!.kind, LigamentDeepLinkKind.target);
      expect(link.grantToken, isNull);
    });
  });

  group('parseLigamentDeepLink: легаси ligament://rdp/<grant_id>?t=…', () {
    test('базовый формат с токеном — grant-режим сохраняется', () {
      final link = parseLigamentDeepLink('ligament://rdp/$grantId?t=deadbeef');
      expect(link, isNotNull);
      expect(link!.kind, LigamentDeepLinkKind.grant);
      expect(link.grantId, grantId);
      expect(link.grantToken, 'deadbeef');
      expect(link.targetId, isNull); // это НЕ цель
    });

    test('заглавные scheme/host и UUID нормализуются (grant)', () {
      final link =
          parseLigamentDeepLink('LIGAMENT://RDP/A1B2C3D4-E5F6-7890-ABCD-EF1234567890?t=x');
      expect(link, isNotNull);
      expect(link!.grantId, grantId);
      expect(link.kind, LigamentDeepLinkKind.grant);
    });

    test('опциональный токен гранта в query (t= / token=)', () {
      final a = parseLigamentDeepLink('ligament://rdp/$grantId?t=deadbeef');
      expect(a!.grantToken, 'deadbeef');
      final b = parseLigamentDeepLink('ligament://rdp/$grantId?token=cafebabe');
      expect(b!.grantToken, 'cafebabe');
    });

    test('хвостовой слэш и пробелы вокруг (grant с токеном)', () {
      final link = parseLigamentDeepLink('  ligament://rdp/$grantId/?t=aa ');
      expect(link, isNotNull);
      expect(link!.grantId, grantId);
      expect(link.grantToken, 'aa');
    });
  });

  group('parseLigamentDeepLink: невалидные и чужие ссылки', () {
    test('чужая схема', () {
      expect(parseLigamentDeepLink('https://rdp/$targetId'), isNull);
      expect(parseLigamentDeepLink('ligamentsec://rdp/$targetId'), isNull);
      expect(parseLigamentDeepLink('about:blank'), isNull);
    });

    test('чужой host', () {
      expect(parseLigamentDeepLink('ligament://sso/$targetId'), isNull);
      expect(parseLigamentDeepLink('ligament://evil.example.com/$targetId'), isNull);
      expect(parseLigamentDeepLink('ligament:///rdp/$targetId'), isNull); // host пуст
    });

    test('не-UUID в path', () {
      expect(parseLigamentDeepLink('ligament://rdp/not-a-uuid'), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/123'), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/'), isNull);
      // UUID-подобный, но с мусорными hex-символами
      expect(parseLigamentDeepLink('ligament://rdp/zz234567-89ab-cdef-0123-456789abcdef'), isNull);
    });

    test('более одного path-сегмента', () {
      expect(parseLigamentDeepLink('ligament://rdp/$targetId/extra'), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/target/$grantId'), isNull);
    });

    test('мусор: пустая строка и не-URI', () {
      expect(parseLigamentDeepLink(''), isNull);
      expect(parseLigamentDeepLink('   '), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/%zz'), isNull);
    });
  });

  group('ligamentUriFromArgs (холодный старт Windows: URI в argv)', () {
    test('выделяет ссылку среди аргументов', () {
      expect(
        ligamentUriFromArgs(['--minimized', 'ligament://rdp/$targetId']),
        'ligament://rdp/$targetId',
      );
    });

    test('нет ссылки — null', () {
      expect(ligamentUriFromArgs(['--minimized']), isNull);
      expect(ligamentUriFromArgs([]), isNull);
    });

    test('строчные/прописные схемы', () {
      expect(ligamentUriFromArgs(['LIGAMENT://rdp/$targetId']), isNotNull);
    });
  });

  group('AuthState: pending deep-link', () {
    test('некорректная ссылка игнорируется без pending', () {
      final auth = AuthState();
      auth.handleDeepLink('ligament://evil/x');
      expect(auth.pendingRdpDeepLink, isNull);
    });

    test('target-ссылка сохраняется и потребляется один раз', () {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$targetId');
      final pending = auth.pendingRdpDeepLink;
      expect(pending?.kind, LigamentDeepLinkKind.target);
      expect(pending?.targetId, targetId);
      final taken = auth.consumePendingRdpDeepLink();
      expect(taken?.targetId, targetId);
      expect(auth.pendingRdpDeepLink, isNull); // повторно не срабатывает
      expect(auth.consumePendingRdpDeepLink(), isNull);
    });

    test('легаси grant-ссылка сохраняется и потребляется один раз', () {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$grantId?t=deadbeef');
      expect(auth.pendingRdpDeepLink?.grantId, grantId);
      final taken = auth.consumePendingRdpDeepLink();
      expect(taken?.grantId, grantId);
      expect(taken?.grantToken, 'deadbeef');
      expect(auth.pendingRdpDeepLink, isNull);
      expect(auth.consumePendingRdpDeepLink(), isNull);
    });

    test('logout сбрасывает ожидание (грант одноразовый)', () async {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$grantId?t=deadbeef');
      expect(auth.pendingRdpDeepLink, isNotNull);
      await auth.logout();
      expect(auth.pendingRdpDeepLink, isNull);
    });

    test('logout сбрасывает и target-ожидание (UUID не переживёт разлогин)',
        () async {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$targetId');
      expect(auth.pendingRdpDeepLink, isNotNull);
      await auth.logout();
      expect(auth.pendingRdpDeepLink, isNull);
    });
  });
}
