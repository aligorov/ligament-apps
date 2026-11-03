import 'package:flutter/material.dart';
import '../services/waveform_codec.dart';

/// Renders a voice message waveform bubble with dynamic playback progress
/// using a high-performance GPU Canvas [CustomPainter].
class WaveformBubble extends StatelessWidget {
  final List<int> samples;
  final double progress;
  final Color? activeColor;
  final Color? inactiveColor;
  final double? barWidth;
  final double? barGap;
  final double minBarHeight;
  final double height;
  final ValueChanged<double>? onSeek;

  const WaveformBubble({
    super.key,
    required this.samples,
    this.progress = 0.0,
    this.activeColor,
    this.inactiveColor,
    this.barWidth,
    this.barGap,
    this.minBarHeight = 3.0,
    this.height = 36.0,
    this.onSeek,
  });

  /// Factory constructor to unpack samples directly from a [base64Waveform] string.
  factory WaveformBubble.fromBase64({
    Key? key,
    required String base64Waveform,
    double progress = 0.0,
    Color? activeColor,
    Color? inactiveColor,
    double? barWidth,
    double? barGap,
    double minBarHeight = 3.0,
    double height = 36.0,
    ValueChanged<double>? onSeek,
  }) {
    return WaveformBubble(
      key: key,
      samples: WaveformCodec.unpack(base64Waveform),
      progress: progress,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      barWidth: barWidth,
      barGap: barGap,
      minBarHeight: minBarHeight,
      height: height,
      onSeek: onSeek,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveActiveColor = activeColor ?? theme.colorScheme.primary;
    final effectiveInactiveColor = inactiveColor ??
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4);

    Widget waveform = SizedBox(
      height: height,
      child: CustomPaint(
        painter: WaveformPainter(
          samples: samples,
          progress: progress.clamp(0.0, 1.0),
          activeColor: effectiveActiveColor,
          inactiveColor: effectiveInactiveColor,
          barWidth: barWidth,
          barGap: barGap,
          minBarHeight: minBarHeight,
        ),
        size: Size.infinite,
      ),
    );

    if (onSeek != null) {
      waveform = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => _handleSeek(context, details.localPosition),
        onHorizontalDragUpdate: (details) =>
            _handleSeek(context, details.localPosition),
        child: waveform,
      );
    }

    return waveform;
  }

  void _handleSeek(BuildContext context, Offset localPosition) {
    if (onSeek == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      final frac = (localPosition.dx / box.size.width).clamp(0.0, 1.0);
      onSeek!(frac);
    }
  }
}

/// Canvas painter drawing 5-bit discrete waveform bars with rounded capsule caps.
class WaveformPainter extends CustomPainter {
  final List<int> samples;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double? barWidth;
  final double? barGap;
  final double minBarHeight;

  const WaveformPainter({
    required this.samples,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    this.barWidth,
    this.barGap,
    this.minBarHeight = 3.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0 || size.height <= 0) return;

    final count = samples.length;
    final totalW = size.width;
    final totalH = size.height;

    final double computedBarWidth;
    final double computedGap;

    if (barWidth != null && barGap != null) {
      computedBarWidth = barWidth!;
      computedGap = barGap!;
    } else if (barWidth != null) {
      computedBarWidth = barWidth!;
      computedGap = count > 1
          ? (totalW - computedBarWidth * count) / (count - 1)
          : 0.0;
    } else {
      final slotWidth = totalW / count;
      computedBarWidth = (slotWidth * 0.6).clamp(1.5, 6.0);
      computedGap = count > 1
          ? (totalW - computedBarWidth * count) / (count - 1)
          : 0.0;
    }

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    for (int i = 0; i < count; i++) {
      final sample = samples[i].clamp(0, WaveformCodec.maxSampleValue);
      final normalized = sample / WaveformCodec.maxSampleValue;
      final barH = (minBarHeight + normalized * (totalH - minBarHeight))
          .clamp(minBarHeight, totalH);

      final left = i * (computedBarWidth + computedGap);
      final top = (totalH - barH) / 2.0;

      final barFraction = (i + 0.5) / count;
      final paint = barFraction <= progress ? activePaint : inactivePaint;

      final radius = Radius.circular(computedBarWidth / 2.0);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, computedBarWidth, barH),
        radius,
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.samples != samples ||
        oldDelegate.barWidth != barWidth ||
        oldDelegate.barGap != barGap ||
        oldDelegate.minBarHeight != minBarHeight;
  }
}
