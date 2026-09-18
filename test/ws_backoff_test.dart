import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/ws_service.dart';

void main() {
  group('ReconnectBackoff (M-2)', () {
    test('без джиттера: экспонента 1с -> 2с -> 4с -> ... -> капа 30с', () {
      final b = ReconnectBackoff(random: Random(1), jitterFraction: 0);
      expect(b.nextDelay(), const Duration(seconds: 1));
      expect(b.nextDelay(), const Duration(seconds: 2));
      expect(b.nextDelay(), const Duration(seconds: 4));
      expect(b.nextDelay(), const Duration(seconds: 8));
      expect(b.nextDelay(), const Duration(seconds: 16));
      // 32с выше капы — остается 30с и дальше не растет
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.attempt, 7);
    });

    test('с джиттером: задержка в пределах +-20% от базовой', () {
      final b = ReconnectBackoff(random: Random(42), jitterFraction: 0.2);
      for (final expected in [1000, 2000, 4000, 8000, 16000, 30000, 30000]) {
        final d = b.nextDelay().inMilliseconds;
        expect(d, greaterThanOrEqualTo((expected * 0.8).floor()));
        expect(d, lessThanOrEqualTo((expected * 1.2).ceil()));
      }
    });

    test('reset возвращает к 1с', () {
      final b = ReconnectBackoff(random: Random(1), jitterFraction: 0);
      b.nextDelay();
      b.nextDelay();
      b.nextDelay(); // следующая была бы 8с
      b.reset();
      expect(b.attempt, 0);
      expect(b.nextDelay(), const Duration(seconds: 1));
    });

    test('кастомные base/max уважаются', () {
      final b = ReconnectBackoff(baseMs: 500, maxMs: 2000, jitterFraction: 0, random: Random(1));
      expect(b.nextDelay(), const Duration(milliseconds: 500));
      expect(b.nextDelay(), const Duration(seconds: 1));
      expect(b.nextDelay(), const Duration(seconds: 2)); // 2000 == капа
      expect(b.nextDelay(), const Duration(seconds: 2));
    });
  });
}
