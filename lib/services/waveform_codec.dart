import 'dart:convert';
import 'dart:typed_data';

/// High-performance 5-bit audio waveform codec for voice messages.
///
/// Encodes audio amplitude samples (normalized to [0..31]) into packed binary
/// streams (50 samples -> 250 bits -> 32 bytes) and Base64 strings for compact
/// transport in message metadata.
abstract final class WaveformCodec {
  static const int bitsPerSample = 5;
  static const int maxSampleValue = 31;
  static const int defaultSampleCount = 50;
  static const int packedByteLength = 32;

  /// Compresses a list of [samples] (range 0..31) into a packed [Uint8List].
  ///
  /// For 50 samples, this produces exactly 32 bytes.
  static Uint8List packToBytes(List<int> samples) {
    if (samples.isEmpty) return Uint8List(0);

    final bitCount = samples.length * bitsPerSample;
    final byteCount = (bitCount + 7) ~/ 8;
    final result = Uint8List(byteCount);

    int bitOffset = 0;
    for (final rawSample in samples) {
      final sample = rawSample.clamp(0, maxSampleValue);
      for (int b = bitsPerSample - 1; b >= 0; b--) {
        final bit = (sample >> b) & 1;
        if (bit == 1) {
          final byteIndex = bitOffset ~/ 8;
          final bitIndex = 7 - (bitOffset % 8);
          result[byteIndex] |= (1 << bitIndex);
        }
        bitOffset++;
      }
    }

    return result;
  }

  /// Compresses [samples] into a Base64-encoded string.
  ///
  /// For 50 samples, the resulting Base64 decodes into exactly 32 bytes.
  static String pack(List<int> samples) {
    if (samples.isEmpty) return '';
    return base64Encode(packToBytes(samples));
  }

  /// Decodes packed binary [bytes] into a list of 5-bit sample integers [0..31].
  ///
  /// If [sampleCount] is not specified:
  /// - Defaults to 50 samples if [bytes.length] is 32.
  /// - Otherwise extracts all available 5-bit samples from the byte stream.
  static List<int> unpackFromBytes(List<int> bytes, [int? sampleCount]) {
    if (bytes.isEmpty) return <int>[];

    final totalBits = bytes.length * 8;
    final count = sampleCount ??
        (bytes.length == packedByteLength ? defaultSampleCount : totalBits ~/ bitsPerSample);
    final maxPossible = totalBits ~/ bitsPerSample;
    final effectiveCount = count > maxPossible ? maxPossible : count;

    if (effectiveCount <= 0) return <int>[];

    final samples = List<int>.filled(effectiveCount, 0);
    int bitOffset = 0;

    for (int i = 0; i < effectiveCount; i++) {
      int val = 0;
      for (int b = bitsPerSample - 1; b >= 0; b--) {
        final byteIndex = bitOffset ~/ 8;
        final bitIndex = 7 - (bitOffset % 8);
        final bit = (bytes[byteIndex] >> bitIndex) & 1;
        val = (val << 1) | bit;
        bitOffset++;
      }
      samples[i] = val;
    }

    return samples;
  }

  /// Decodes a Base64 string into a list of 5-bit sample integers [0..31].
  ///
  /// Gracefully returns an empty list if [base64Str] is empty, invalid,
  /// or corrupt.
  static List<int> unpack(String base64Str, [int? sampleCount]) {
    final clean = base64Str.trim();
    if (clean.isEmpty) return <int>[];

    try {
      final normalized = clean.length % 4 == 0
          ? clean
          : clean.padRight(clean.length + (4 - clean.length % 4), '=');
      final bytes = base64Decode(normalized);
      return unpackFromBytes(bytes, sampleCount);
    } catch (_) {
      return <int>[];
    }
  }
}
