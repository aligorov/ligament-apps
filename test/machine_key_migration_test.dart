import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A-10 (аудит 2026-10-12): machine_public_key (идентификатор машины для
/// серверного ON CONFLICT-пиннинга) хранится во flutter_secure_storage.
/// При загрузке старое plaintext-значение из SharedPreferences
/// мигрирует: само значение НЕ меняется (сервер считает его
/// идентификатором), plaintext-копия из prefs удаляется.
///
/// Secure storage мокается MethodChannel-хендлером (read/write/delete по
/// ключу) — тяжёлый платформенный микс не нужен.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};

  setUp(() {
    secureStore.clear();
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
          secureStore.remove(args?['key']);
          return null;
      }
      return null;
    });
    // AuthState() в конструкторе создаёт AlertService -> AudioPlayer(),
    // который дергает каналы audioplayers (см. desktop_confirm_test).
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
  });

  test(
      'миграция: легаси-значение переносится в secure storage без изменений и удаляется из prefs',
      () async {
    const legacy =
        'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';
    SharedPreferences.setMockInitialValues({'machine_public_key': legacy});

    final auth = AuthState();
    final key = await auth.ensureMachinePublicKey();

    // Значение НЕ поменяли — сервер держит на нём идентичность машины.
    expect(key, legacy);
    expect(secureStore['machine_public_key'], legacy);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('machine_public_key'), isNull,
        reason: 'plaintext-копия должна быть удалена из prefs');
  });

  test(
      'без легаси-значения ключ генерируется сразу в secure storage (64 hex), prefs не используется',
      () async {
    SharedPreferences.setMockInitialValues({});

    final auth = AuthState();
    final key = await auth.ensureMachinePublicKey();

    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(secureStore['machine_public_key'], key);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('machine_public_key'), isNull);
  });

  test(
      'уже мигрировавший ключ читается из secure storage, недоудалённая prefs-копия подчищается',
      () async {
    const migrated =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    secureStore['machine_public_key'] = migrated;
    // Имитация «недоудалённой» копии (например, после сбоя удаления).
    SharedPreferences.setMockInitialValues({'machine_public_key': migrated});

    final auth = AuthState();
    expect(await auth.ensureMachinePublicKey(), migrated);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('machine_public_key'), isNull);
  });
}
