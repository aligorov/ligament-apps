import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/support_service.dart';

void main() {
  group('assembleFileChunks (M-3: полнота и целостность)', () {
    test('полный набор чанков с верной checksum собирается', () {
      final bytes = utf8.encode('hello remote support file transfer');
      final checksum = crypto.sha256.convert(bytes).toString();
      final chunks = <int, List<int>>{
        0: bytes.sublist(0, 10),
        1: bytes.sublist(10, 20),
        2: bytes.sublist(20),
      };
      final res = assembleFileChunks(chunks, 3, expectedSize: bytes.length, expectedChecksum: checksum);
      expect(res.isOk, isTrue);
      expect(res.bytes, bytes);
    });

    test('неполный набор (нет чанка 0..total-1) не собирается', () {
      final chunks = <int, List<int>>{
        0: [1, 2, 3],
        2: [7, 8, 9], // пропущен индекс 1
      };
      final res = assembleFileChunks(chunks, 3);
      expect(res.isOk, isFalse);
      expect(res.error, 'incomplete');
    });

    test('порченый байт ловится checksum_mismatch', () {
      final bytes = utf8.encode('corrupt me');
      final checksum = crypto.sha256.convert(bytes).toString();
      bytes[3] = 0xFF; // портим после подсчёта эталонной суммы
      final res = assembleFileChunks({0: bytes}, 1, expectedChecksum: checksum);
      expect(res.isOk, isFalse);
      expect(res.error, 'checksum_mismatch');
    });

    test('несовпадение размера ловится size_mismatch', () {
      final res = assembleFileChunks({0: [1, 2, 3]}, 1, expectedSize: 10);
      expect(res.isOk, isFalse);
      expect(res.error, 'size_mismatch');
    });

    test('лишние чанки вне диапазона игнорируются, но не роняют сборку', () {
      final bytes = [1, 2, 3, 4];
      final res = assembleFileChunks({
        0: [1, 2],
        1: [3, 4],
        7: [9, 9], // вне диапазона
      }, 2);
      expect(res.isOk, isTrue);
      expect(res.bytes, bytes);
    });

    test('checksum в верхнем регистре принимается', () {
      final bytes = utf8.encode('case');
      final checksum = crypto.sha256.convert(bytes).toString().toUpperCase();
      final res = assembleFileChunks({0: bytes}, 1, expectedChecksum: checksum);
      expect(res.isOk, isTrue);
    });

    test('без checksum (легаси-отправитель) собирается по полноте', () {
      final res = assembleFileChunks({0: [1], 1: [2]}, 2);
      expect(res.isOk, isTrue);
    });

    test('totalChunks <= 0 — ошибка incomplete', () {
      expect(assembleFileChunks(const {}, 0).error, 'incomplete');
    });

    test('пустой checksum не считается проверкой', () {
      final res = assembleFileChunks({0: [1, 2, 3]}, 1, expectedChecksum: '');
      expect(res.isOk, isTrue);
    });
  });

  group('parseIceServersConfig (B-1)', () {
    test('полный формат: urls массив + username/credential', () {
      final cfg = {
        'ice_servers': [
          {
            'urls': ['turn:turn.corp.local:3478?transport=udp', 'turn:turn.corp.local:3479?transport=tcp'],
            'username': 'ligament',
            'credential': 'secret',
          },
          {'urls': 'stun:stun.corp.local:3478'},
        ],
      };
      final res = parseIceServersConfig(cfg);
      expect(res, hasLength(2));
      expect(res[0]['urls'], isA<List<String>>());
      expect(res[0]['username'], 'ligament');
      expect(res[0]['credential'], 'secret');
      expect(res[1]['urls'], ['stun:stun.corp.local:3478']);
      expect(res[1].containsKey('username'), isFalse);
    });

    test('поле отсутствует -> пустой список (фолбэк решает вызывающий)', () {
      expect(parseIceServersConfig({}), isEmpty);
      expect(parseIceServersConfig(null), isEmpty);
      expect(parseIceServersConfig({'ice_servers': null}), isEmpty);
    });

    test('невалидные urls отбрасываются', () {
      final cfg = {
        'ice_servers': [
          {'urls': 'http://evil.example.com'},
          {'urls': ['ftp://nope', 'stun:ok.local:3478']},
          {'urls': ''},
          'not-a-map',
        ],
      };
      final res = parseIceServersConfig(cfg);
      expect(res, hasLength(1));
      expect(res[0]['urls'], ['stun:ok.local:3478']);
    });
  });
}
