import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Инновационный экран запуска (Quantum Lock Splash Screen) для Ligament 2FA:
/// - Кинематическое схождение двух звеньев цепи (индиго и бирюзовый) в 3D пространстве.
/// - Момент сцепки («Связка») сопровождается квантовой ударной волной и световой вспышкой.
/// - Бегущие лазерные световые импульсы по контурам звеньев.
/// - Плавное проявление высокотехнологичной типографики и неонового сканера готовности.
class SplashScreen extends StatefulWidget {
  final VoidCallback onFinish;
  final Duration duration;

  const SplashScreen({
    super.key,
    required this.onFinish,
    this.duration = const Duration(milliseconds: 1600),
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _link1Progress;
  late final Animation<double> _link2Progress;
  late final Animation<double> _shockwaveProgress;
  late final Animation<double> _flashProgress;
  late final Animation<double> _titleProgress;
  late final Animation<double> _scannerProgress;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    // Схождение первого звена (индиго) 0.0 -> 0.52
    _link1Progress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.52, curve: Curves.easeOutBack),
    );

    // Схождение второго звена (бирюзовый) 0.08 -> 0.54
    _link2Progress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.06, 0.54, curve: Curves.easeOutBack),
    );

    // Силовая ударная волна в точке сцепки 0.48 -> 0.85
    _shockwaveProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.48, 0.85, curve: Curves.easeOut),
    );

    // Вспышка в момент сцепки 0.46 -> 0.65
    _flashProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.46, 0.65, curve: Curves.easeOut),
    );

    // Раскрытие названия и бейджа 0.52 -> 0.85
    _titleProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.52, 0.85, curve: Curves.easeOutCubic),
    );

    // Индикатор готовности 0.65 -> 0.98
    _scannerProgress = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.65, 0.98, curve: Curves.easeOutCubic),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _triggerFinish();
      }
    });

    _controller.forward();
  }

  void _triggerFinish() {
    if (_finished) return;
    _finished = true;
    widget.onFinish();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (!_finished) {
          _controller.stop();
          _triggerFinish();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF090D1A),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.15),
              radius: 1.1,
              colors: [
                Color(0xFF1E293B),
                Color(0xFF0F172A),
                Color(0xFF070B14),
              ],
            ),
          ),
          child: Stack(
            children: [
              // Фоновая кибер-сетка и частицы
              Positioned.fill(
                child: CustomPaint(
                  painter: _CyberBackgroundPainter(time: _controller.value),
                ),
              ),

              // Центр: анимированная связка и типографика
              Center(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Векторная кинематическая связка
                        SizedBox(
                          width: 140,
                          height: 140,
                          child: CustomPaint(
                            painter: _KineticLinkPainter(
                              p1: _link1Progress.value,
                              p2: _link2Progress.value,
                              wave: _shockwaveProgress.value,
                              flash: _flashProgress.value,
                              animTime: _controller.value,
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Типографика: LIGAMENT + 2FA
                        Opacity(
                          opacity: _titleProgress.value,
                          child: Transform.translate(
                            offset: Offset(0, 14 * (1.0 - _titleProgress.value)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  'LIGAMENT',
                                  style: TextStyle(
                                    color: const Color(0xFFF8FAFC),
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 4.5 * _titleProgress.value + 1.0,
                                    shadows: [
                                      Shadow(
                                        color: const Color(0xFF38BDF8)
                                            .withValues(alpha: 0.35 * _titleProgress.value),
                                        blurRadius: 16,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2.5),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        const Color(0xFF0284C7).withValues(alpha: 0.25),
                                        const Color(0xFF06B6D4).withValues(alpha: 0.25),
                                      ],
                                    ),
                                    border: Border.all(
                                      color: const Color(0xFF38BDF8),
                                      width: 1.3,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF06B6D4)
                                            .withValues(alpha: 0.4 * _titleProgress.value),
                                        blurRadius: 12,
                                      ),
                                    ],
                                  ),
                                  child: const Text(
                                    '2FA',
                                    style: TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // Саблайн протокола
                        Opacity(
                          opacity: _titleProgress.value,
                          child: const Text(
                            'ZERO TRUST PROTOCOL',
                            style: TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 3.2,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),

                        const SizedBox(height: 28),

                        // Неоновый сканер готовности
                        Container(
                          width: 150,
                          height: 3,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 150 * _scannerProgress.value,
                              height: 3,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(2),
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF6366F1),
                                    Color(0xFF38BDF8),
                                    Color(0xFF22D3EE),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF22D3EE)
                                        .withValues(alpha: 0.6 * _scannerProgress.value),
                                    blurRadius: 10,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Высокопроизводительный CustomPainter для отрисовки кинематической сцепки звеньев
class _KineticLinkPainter extends CustomPainter {
  final double p1;
  final double p2;
  final double wave;
  final double flash;
  final double animTime;

  _KineticLinkPainter({
    required this.p1,
    required this.p2,
    required this.wave,
    required this.flash,
    required this.animTime,
  });

  static final Path _link1 = Path()
    ..moveTo(116, 94)
    ..lineTo(104, 82)
    ..quadraticBezierTo(86, 64, 68, 82)
    ..lineTo(30, 120)
    ..quadraticBezierTo(12, 138, 30, 156)
    ..lineTo(44, 170)
    ..quadraticBezierTo(62, 188, 80, 170)
    ..lineTo(94, 156);

  static final Path _link2 = Path()
    ..moveTo(84, 106)
    ..lineTo(96, 118)
    ..quadraticBezierTo(114, 136, 132, 118)
    ..lineTo(170, 80)
    ..quadraticBezierTo(188, 62, 170, 44)
    ..lineTo(156, 30)
    ..quadraticBezierTo(138, 12, 120, 30)
    ..lineTo(106, 44);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = size.width / 200.0;

    // 1. Ударная квантовая волна при защёлкивании звеньев
    if (wave > 0.0 && wave < 1.0) {
      final waveRadius = 20.0 + wave * 65.0;
      final waveOpacity = (1.0 - wave) * 0.75;
      final wavePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * (1.0 - wave * 0.5)
        ..color = const Color(0xFF22D3EE).withValues(alpha: waveOpacity);
      canvas.drawCircle(center, waveRadius, wavePaint);
    }

    // 2. Вспышка в центре контакта
    if (flash > 0.0 && flash < 1.0) {
      final flashOpacity = math.sin(flash * math.pi) * 0.85;
      final flashPaint = Paint()
        ..color = Colors.white.withValues(alpha: flashOpacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
      canvas.drawCircle(center, 18 * flash, flashPaint);
    }

    // 3. Звено 1: Индиго (#6366F1 / #818CF8)
    {
      canvas.save();
      canvas.translate(center.dx, center.dy);

      // Смещение и поворот при схождении
      final dx = -40.0 * (1.0 - p1);
      final dy = -40.0 * (1.0 - p1);
      final angle = -0.45 * (1.0 - p1);

      canvas.translate(dx, dy);
      canvas.rotate(angle);
      canvas.scale(scale);
      canvas.translate(-100, -100);

      // Неоновый ореол
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF6366F1).withValues(alpha: 0.35 * p1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawPath(_link1, glowPaint);

      // Основной градиентный контур звена
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = const LinearGradient(
          colors: [Color(0xFF818CF8), Color(0xFF4F46E5)],
        ).createShader(const Rect.fromLTWH(0, 0, 200, 200))
        ..color = Colors.white.withValues(alpha: p1);
      canvas.drawPath(_link1, strokePaint);

      // Бегущий лазерный луч
      _drawLaserRay(canvas, _link1, animTime, const Color(0xFFFFFFFF));

      canvas.restore();
    }

    // 4. Звено 2: Бирюзовый (#22D3EE / #06B6D4)
    {
      canvas.save();
      canvas.translate(center.dx, center.dy);

      // Смещение и поворот при схождении
      final dx = 40.0 * (1.0 - p2);
      final dy = 40.0 * (1.0 - p2);
      final angle = 0.45 * (1.0 - p2);

      canvas.translate(dx, dy);
      canvas.rotate(angle);
      canvas.scale(scale);
      canvas.translate(-100, -100);

      // Неоновый ореол
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF22D3EE).withValues(alpha: 0.38 * p2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawPath(_link2, glowPaint);

      // Основной градиентный контур звена
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 20.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = const LinearGradient(
          colors: [Color(0xFF67E8F9), Color(0xFF0891B2)],
        ).createShader(const Rect.fromLTWH(0, 0, 200, 200))
        ..color = Colors.white.withValues(alpha: p2);
      canvas.drawPath(_link2, strokePaint);

      // Бегущий лазерный луч
      _drawLaserRay(canvas, _link2, animTime + 0.3, const Color(0xFFE0F2FE));

      canvas.restore();
    }
  }

  void _drawLaserRay(Canvas canvas, Path path, double progress, Color color) {
    for (final metric in path.computeMetrics()) {
      final totalLen = metric.length;
      final rayLen = totalLen * 0.28;
      final start = ((progress * 1.5) % 1.0) * totalLen;
      final end = (start + rayLen);

      Path ray;
      if (end <= totalLen) {
        ray = metric.extractPath(start, end);
      } else {
        ray = metric.extractPath(start, totalLen)
          ..addPath(metric.extractPath(0, end - totalLen), Offset.zero);
      }

      final rayPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawPath(ray, rayPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _KineticLinkPainter oldDelegate) => true;
}

/// Фоновые квантовые частицы и сетка
class _CyberBackgroundPainter extends CustomPainter {
  final double time;

  _CyberBackgroundPainter({required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..color = const Color(0xFF38BDF8).withValues(alpha: 0.08);

    // Сетка точек
    const step = 28.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.0, dotPaint);
      }
    }

    // Несколько плавающих светящихся узлов
    final nodePaint = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    const count = 8;
    for (int i = 0; i < count; i++) {
      final phase = i * (math.pi / 4);
      final x = (size.width * 0.15) + (size.width * 0.7) * (0.5 + 0.45 * math.sin(time * 2 * math.pi + phase));
      final y = (size.height * 0.2) + (size.height * 0.6) * (0.5 + 0.45 * math.cos(time * 2 * math.pi + phase * 1.5));
      final color = i.isEven ? const Color(0xFF22D3EE) : const Color(0xFF818CF8);
      nodePaint.color = color.withValues(alpha: 0.25);
      canvas.drawCircle(Offset(x, y), 2.2, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CyberBackgroundPainter oldDelegate) => true;
}
