import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/server_url_validator.dart';

void main() {
  group('validateServerUrl (VULN-27 / L-16 / K-4)', () {
    test('https-адреса допустимы для любого хоста', () {
      expect(validateServerUrl('https://2fa.corp.local'), isNull);
      expect(validateServerUrl('https://2fa.corp.local:8443/base'), isNull);
      expect(validateServerUrl('  HTTPS://2fa.corp.local  '), isNull);
      expect(validateServerUrl('https://127.evil.example'), isNull);
    });

    test('http допустим только для loopback', () {
      expect(validateServerUrl('http://localhost'), isNull);
      expect(validateServerUrl('http://localhost:8080'), isNull);
      expect(validateServerUrl('http://127.0.0.1'), isNull);
      expect(validateServerUrl('http://127.0.0.1:3000'), isNull);
      expect(validateServerUrl('http://[::1]:8080'), isNull);
      // Весь диапазон 127.0.0.0/8 — loopback
      expect(validateServerUrl('http://127.1.2.3'), isNull);
      expect(validateServerUrl('http://127.255.255.254'), isNull);
    });

    test('http вне loopback отклоняется (регрессия 127.evil.example)', () {
      // Раньше host.startsWith('127.') пропускал поддомены атакующего
      expect(validateServerUrl('http://127.evil.example'),
          equals(ServerUrlError.insecureHttp));
      expect(validateServerUrl('http://127.evil.example:8080'),
          equals(ServerUrlError.insecureHttp));
      expect(validateServerUrl('http://2fa.corp.local'),
          equals(ServerUrlError.insecureHttp));
      // 128.x — уже не loopback
      expect(validateServerUrl('http://128.0.0.1'),
          equals(ServerUrlError.insecureHttp));
      expect(validateServerUrl('http://0.0.0.0'),
          equals(ServerUrlError.insecureHttp));
    });

    test('localhost с портом/суффиксом хоста не проходит', () {
      // localhost.evil.example — чужой домен, а не localhost
      expect(validateServerUrl('http://localhost.evil.example'),
          equals(ServerUrlError.insecureHttp));
    });

    test('прочие схемы и мусор отклоняются', () {
      expect(validateServerUrl('ftp://2fa.corp.local'),
          equals(ServerUrlError.unsupportedScheme));
      expect(validateServerUrl('file:///etc/passwd'),
          equals(ServerUrlError.unsupportedScheme));
      expect(validateServerUrl('intent://example/#Intent'),
          equals(ServerUrlError.unsupportedScheme));
      expect(validateServerUrl(''), equals(ServerUrlError.empty));
      expect(validateServerUrl('   '), equals(ServerUrlError.empty));
      expect(validateServerUrl('https://'), equals(ServerUrlError.empty));
      expect(validateServerUrl('http://'), equals(ServerUrlError.empty));
      expect(validateServerUrl('2fa.corp.local'), equals(ServerUrlError.invalid));
      // «localhost:8443» Dart разбирает как схему localhost — это именно
      // ошибка схемы (нет https://), а не «некорректный URL».
      expect(validateServerUrl('localhost:8443'),
          equals(ServerUrlError.unsupportedScheme));
    });
  });

  group('isLoopbackHost', () {
    test('точные литералы и 127/8', () {
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('LOCALHOST'), isTrue);
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.200.3.9'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('[::1]'), isTrue);
    });

    test('чужие хосты и адреса', () {
      expect(isLoopbackHost('127.evil.example'), isFalse);
      expect(isLoopbackHost('localhost.evil.example'), isFalse);
      expect(isLoopbackHost('128.0.0.1'), isFalse);
      expect(isLoopbackHost('::2'), isFalse);
      expect(isLoopbackHost('0.0.0.0'), isFalse);
      expect(isLoopbackHost(''), isFalse);
    });
  });
}
