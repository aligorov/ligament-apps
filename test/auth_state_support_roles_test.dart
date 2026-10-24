import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/auth_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), null);
  });

  group('AuthState SOS Support Role Specialization', () {
    test('admin without support_roles is NOT an engineer', () {
      final auth = AuthState();
      auth.currentUser = {
        'id': 'u1',
        'username': 'admin_user',
        'role': 'admin',
        'support_roles': <dynamic>[],
      };

      expect(auth.isAdmin, isTrue);
      expect(auth.supportRoles, isEmpty);
      expect(auth.isEngineer, isFalse);
      expect(auth.isITEngineer, isFalse);
      expect(auth.is1CEngineer, isFalse);
      expect(auth.engineerBadge, contains('Администратор'));
    });

    test('admin with IT support_roles IS an IT engineer', () {
      final auth = AuthState();
      auth.currentUser = {
        'id': 'u2',
        'username': 'admin_it',
        'role': 'admin',
        'support_roles': ['it'],
      };

      expect(auth.isAdmin, isTrue);
      expect(auth.supportRoles, contains('it'));
      expect(auth.isEngineer, isTrue);
      expect(auth.isITEngineer, isTrue);
      expect(auth.is1CEngineer, isFalse);
      expect(auth.engineerBadge, contains('IT-инженер'));
    });

    test('user with 1C support_roles IS a 1C engineer', () {
      final auth = AuthState();
      auth.currentUser = {
        'id': 'u3',
        'username': 'user_1c',
        'role': 'user',
        'support_roles': ['1c'],
      };

      expect(auth.isAdmin, isFalse);
      expect(auth.supportRoles, contains('1c'));
      expect(auth.isEngineer, isTrue);
      expect(auth.isITEngineer, isFalse);
      expect(auth.is1CEngineer, isTrue);
      expect(auth.engineerBadge, contains('1С-инженер'));
    });

    test('user with all support_roles handles both IT and 1C', () {
      final auth = AuthState();
      auth.currentUser = {
        'id': 'u4',
        'username': 'user_all',
        'role': 'user',
        'support_roles': ['all'],
      };

      expect(auth.isAdmin, isFalse);
      expect(auth.supportRoles, contains('all'));
      expect(auth.isEngineer, isTrue);
      expect(auth.isITEngineer, isTrue);
      expect(auth.is1CEngineer, isTrue);
      expect(auth.engineerBadge, contains('IT / 1С-инженер'));
    });
  });
}
