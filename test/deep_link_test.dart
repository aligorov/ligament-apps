import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/deep_link_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deep-link ligament://rdp/<grant_id> (аудит RDP-11): единая точка разбора
/// Uri (scheme==ligament, host==rdp, pathSegment=grant UUID) и семантика
/// pending-ссылки в AuthState (не залогинен → сохранить, применить после
/// логина; logout → сброс). Чистые функции — без платформы и сети.
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
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), null);
  });

  const grantId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';

  group('parseLigamentDeepLink: валидные ссылки', () {
    test('базовый формат ligament://rdp/<uuid>', () {
      final link = parseLigamentDeepLink('ligament://rdp/$grantId');
      expect(link, isNotNull);
      expect(link!.grantId, grantId);
      expect(link.grantToken, isNull);
    });

    test('заглавные scheme/host и UUID нормализуются', () {
      final link =
          parseLigamentDeepLink('LIGAMENT://RDP/A1B2C3D4-E5F6-7890-ABCD-EF1234567890');
      expect(link, isNotNull);
      expect(link!.grantId, grantId);
    });

    test('опциональный токен гранта в query (t= / token=)', () {
      final a = parseLigamentDeepLink('ligament://rdp/$grantId?t=deadbeef');
      expect(a!.grantToken, 'deadbeef');
      final b = parseLigamentDeepLink('ligament://rdp/$grantId?token=cafebabe');
      expect(b!.grantToken, 'cafebabe');
      // Пустой токен = нет токена.
      final c = parseLigamentDeepLink('ligament://rdp/$grantId?t=');
      expect(c!.grantToken, isNull);
    });

    test('хвостовой слэш и пробелы вокруг', () {
      final link = parseLigamentDeepLink('  ligament://rdp/$grantId/ ');
      expect(link, isNotNull);
      expect(link!.grantId, grantId);
    });
  });

  group('parseLigamentDeepLink: невалидные и чужие ссылки', () {
    test('чужая схема', () {
      expect(parseLigamentDeepLink('https://rdp/$grantId'), isNull);
      expect(parseLigamentDeepLink('ligamentsec://rdp/$grantId'), isNull);
      expect(parseLigamentDeepLink('about:blank'), isNull);
    });

    test('чужой host', () {
      expect(parseLigamentDeepLink('ligament://sso/$grantId'), isNull);
      expect(parseLigamentDeepLink('ligament://evil.example.com/$grantId'), isNull);
      expect(parseLigamentDeepLink('ligament:///rdp/$grantId'), isNull); // host пуст
    });

    test('не-UUID в path', () {
      expect(parseLigamentDeepLink('ligament://rdp/not-a-uuid'), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/123'), isNull);
      expect(parseLigamentDeepLink('ligament://rdp/'), isNull);
    });

    test('более одного path-сегмента', () {
      expect(parseLigamentDeepLink('ligament://rdp/$grantId/extra'), isNull);
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
        ligamentUriFromArgs(['--minimized', 'ligament://rdp/$grantId']),
        'ligament://rdp/$grantId',
      );
    });

    test('нет ссылки — null', () {
      expect(ligamentUriFromArgs(['--minimized']), isNull);
      expect(ligamentUriFromArgs([]), isNull);
    });

    test('строчные/прописные схемы', () {
      expect(ligamentUriFromArgs(['LIGAMENT://rdp/$grantId']), isNotNull);
    });
  });

  group('AuthState: pending deep-link', () {
    test('некорректная ссылка игнорируется без pending', () {
      final auth = AuthState();
      auth.handleDeepLink('ligament://evil/x');
      expect(auth.pendingRdpDeepLink, isNull);
    });

    test('валидная ссылка сохраняется и потребляется один раз', () {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$grantId');
      expect(auth.pendingRdpDeepLink?.grantId, grantId);
      final taken = auth.consumePendingRdpDeepLink();
      expect(taken?.grantId, grantId);
      expect(auth.pendingRdpDeepLink, isNull); // повторно не срабатывает
      expect(auth.consumePendingRdpDeepLink(), isNull);
    });

    test('logout сбрасывает ожидание (грант одноразовый)', () async {
      final auth = AuthState();
      auth.handleDeepLink('ligament://rdp/$grantId');
      expect(auth.pendingRdpDeepLink, isNotNull);
      await auth.logout();
      expect(auth.pendingRdpDeepLink, isNull);
    });
  });
}
