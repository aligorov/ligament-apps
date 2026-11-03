import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/waveform_codec.dart';
import 'package:ligament_authenticator/widgets/waveform_bubble.dart';

void main() {
  group('WaveformCodec Tests', () {
    test('5-bit packing: 50 normalized samples (0..31) compress to 32 bytes Base64', () {
      // 50 samples in range 0..31
      final samples = List.generate(50, (i) => (i * 7) % 32);
      expect(samples.length, 50);

      // Pack to Base64
      final base64String = WaveformCodec.pack(samples);
      expect(base64String.isNotEmpty, isTrue);

      // The binary payload must be exactly 32 bytes (50 * 5 = 250 bits <= 256 bits = 32 bytes)
      final rawBytes = base64Decode(base64String);
      expect(rawBytes.length, 32);

      // Direct packToBytes helper also yields 32 bytes
      final directBytes = WaveformCodec.packToBytes(samples);
      expect(directBytes.length, 32);
      expect(directBytes, equals(rawBytes));
    });

    test('Unpack Base64 restores exact List<int> in range 0..31', () {
      final samples = List.generate(50, (i) => i % 32);
      final packed = WaveformCodec.pack(samples);
      final restored = WaveformCodec.unpack(packed);

      expect(restored.length, 50);
      expect(restored, equals(samples));

      for (final val in restored) {
        expect(val, greaterThanOrEqualTo(0));
        expect(val, lessThanOrEqualTo(31));
      }
    });

    test('Boundary sample values: all zeros and all maximum (31)', () {
      final allZeros = List.filled(50, 0);
      final packedZeros = WaveformCodec.pack(allZeros);
      expect(base64Decode(packedZeros).length, 32);
      expect(WaveformCodec.unpack(packedZeros), equals(allZeros));

      final allMax = List.filled(50, 31);
      final packedMax = WaveformCodec.pack(allMax);
      expect(base64Decode(packedMax).length, 32);
      expect(WaveformCodec.unpack(packedMax), equals(allMax));

      final alternating = List.generate(50, (i) => i.isEven ? 0 : 31);
      final packedAlt = WaveformCodec.pack(alternating);
      expect(WaveformCodec.unpack(packedAlt), equals(alternating));
    });

    test('Clamps out-of-range sample values to 0..31 during packing', () {
      final outOfRange = [-10, 0, 15, 31, 100];
      final packed = WaveformCodec.pack(outOfRange);
      final unpacked = WaveformCodec.unpack(packed, 5);

      expect(unpacked, equals([0, 0, 15, 31, 31]));
    });

    test('Protection against empty, whitespace, and corrupt strings', () {
      expect(WaveformCodec.unpack(''), isEmpty);
      expect(WaveformCodec.unpack('   '), isEmpty);
      expect(WaveformCodec.unpack('   \n\t  '), isEmpty);
      expect(WaveformCodec.unpack('not-a-valid-base64!@#%^&*()'), isEmpty);
      expect(WaveformCodec.unpack('==='), isEmpty);
      expect(WaveformCodec.pack([]), isEmpty);
    });

    test('Handles arbitrary length samples with optional sampleCount', () {
      const sampleCount = 20;
      final samples = List.generate(sampleCount, (i) => (i * 3) % 32);
      final packed = WaveformCodec.pack(samples);
      final unpacked = WaveformCodec.unpack(packed, sampleCount);

      expect(unpacked.length, sampleCount);
      expect(unpacked, equals(samples));
    });
  });

  group('WaveformBubble Widget Tests', () {
    testWidgets('renders waveform bars with semantic theme colors', (tester) async {
      final samples = List.generate(50, (i) => (i * 5) % 32);
      final base64Str = WaveformCodec.pack(samples);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF00FFCC),
              onSurfaceVariant: Color(0xFF888888),
            ),
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 40,
                child: WaveformBubble.fromBase64(
                  base64Waveform: base64Str,
                  progress: 0.5,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(WaveformBubble), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('renders directly from samples and handles tap seek', (tester) async {
      final samples = List.generate(50, (i) => 15);
      double? seekedProgress;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 40,
                child: WaveformBubble(
                  samples: samples,
                  progress: 0.25,
                  onSeek: (value) => seekedProgress = value,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(WaveformBubble), findsOneWidget);

      // Tap on the middle of the widget
      await tester.tap(find.byType(WaveformBubble));
      await tester.pump();

      expect(seekedProgress, isNotNull);
      expect(seekedProgress!, greaterThanOrEqualTo(0.0));
      expect(seekedProgress!, lessThanOrEqualTo(1.0));
    });
  });
}
