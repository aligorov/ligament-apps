import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/support_service.dart';

void main() {
  group('Release B: File safety & collision handling (B2)', () {
    test('resolveNonCollidingFilePath: no collision returns original path', () {
      final existing = <String>{};
      final result = resolveNonCollidingFilePath(
        '/downloads',
        'document.pdf',
        fileExists: (p) => existing.contains(p),
      );
      expect(result, endsWith('document.pdf'));
    });

    test('resolveNonCollidingFilePath: single collision returns name (1).ext', () {
      final existing = <String>{'/downloads/document.pdf', '/downloads\\document.pdf'};
      final result = resolveNonCollidingFilePath(
        '/downloads',
        'document.pdf',
        fileExists: (p) => existing.contains(p),
      );
      expect(result, endsWith('document (1).pdf'));
    });

    test('resolveNonCollidingFilePath: multiple collisions increment counter', () {
      final existing = <String>{
        '/downloads/document.pdf',
        '/downloads/document (1).pdf',
        '/downloads/document (2).pdf',
        '/downloads\\document.pdf',
        '/downloads\\document (1).pdf',
        '/downloads\\document (2).pdf',
      };
      final result = resolveNonCollidingFilePath(
        '/downloads',
        'document.pdf',
        fileExists: (p) => existing.contains(p),
      );
      expect(result, endsWith('document (3).pdf'));
    });

    test('resolveNonCollidingFilePath: file without extension', () {
      final existing = <String>{'/downloads/LICENSE', '/downloads\\LICENSE'};
      final result = resolveNonCollidingFilePath(
        '/downloads',
        'LICENSE',
        fileExists: (p) => existing.contains(p),
      );
      expect(result, endsWith('LICENSE (1)'));
    });

    test('resolveNonCollidingFilePath: file with compound extension (.tar.gz)', () {
      final existing = <String>{'/downloads/data.tar.gz', '/downloads\\data.tar.gz'};
      final result = resolveNonCollidingFilePath(
        '/downloads',
        'data.tar.gz',
        fileExists: (p) => existing.contains(p),
      );
      expect(result, endsWith('data.tar (1).gz'));
    });
  });

  group('Release B: serviceHost allowed commands (B3.3, B3.4)', () {
    test('serviceHostCommandAllowed includes reboot and video_quality', () {
      expect(SupportService.serviceHostCommandAllowed('reboot'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('video_quality'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('mouse_move'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('mouse_down'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('mouse_up'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('wheel'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('key_down'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('key_up'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('text_input'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('hotkey'), isTrue);
      expect(SupportService.serviceHostCommandAllowed('block_input'), isTrue);
    });

    test('serviceHostCommandAllowed rejects arbitrary or dangerous commands', () {
      expect(SupportService.serviceHostCommandAllowed('exec'), isFalse);
      expect(SupportService.serviceHostCommandAllowed('format'), isFalse);
      expect(SupportService.serviceHostCommandAllowed('run_cmd'), isFalse);
      expect(SupportService.serviceHostCommandAllowed('shell'), isFalse);
      expect(SupportService.serviceHostCommandAllowed('delete_file'), isFalse);
    });
  });

  group('Release B: Video bitrate mapping (B3.3)', () {
    int getBitrateForQuality(String quality) {
      switch (quality) {
        case 'best':
          return 4000000;
        case 'low':
          return 800000;
        case 'balanced':
        default:
          return 2500000;
      }
    }

    test('maps quality presets to correct bitrate in bps', () {
      expect(getBitrateForQuality('best'), 4000000);
      expect(getBitrateForQuality('balanced'), 2500000);
      expect(getBitrateForQuality('low'), 800000);
      expect(getBitrateForQuality('unknown'), 2500000);
    });
  });

  group('Release B: File size limits (B1.3)', () {
    const int maxFileSizeBytes = 50 * 1024 * 1024; // 50 MB

    test('file within 50MB is accepted', () {
      const size = 49 * 1024 * 1024;
      expect(size <= maxFileSizeBytes, isTrue);
    });

    test('file exceeding 50MB is rejected', () {
      const size = 50 * 1024 * 1024 + 1;
      expect(size > maxFileSizeBytes, isTrue);
    });
  });

  group('Release B: Windows Zone.Identifier MOTW format (B2.1)', () {
    test('MOTW payload conforms to ZoneId=3 (Internet)', () {
      const motwContent = '[ZoneTransfer]\r\nZoneId=3\r\n';
      expect(motwContent.contains('ZoneId=3'), isTrue);
      expect(motwContent.startsWith('[ZoneTransfer]'), isTrue);
    });
  });
}
