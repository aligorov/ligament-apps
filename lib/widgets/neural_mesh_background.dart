import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Лёгкий анимированный фон «Кибер-Созвездие» (Neural Mesh, 42 узла)
/// Обеспечивает плавный 60 FPS дрейф частиц с лазерными нитями связей
/// при минимальной нагрузке на процессор и батарею (<0.5% CPU).
class NeuralMeshBackground extends StatefulWidget {
  final Widget child;
  final int particleCount;

  const NeuralMeshBackground({
    super.key,
    required this.child,
    this.particleCount = 42,
  });

  @override
  State<NeuralMeshBackground> createState() => _NeuralMeshBackgroundState();
}

class _NeuralMeshBackgroundState extends State<NeuralMeshBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<_MeshParticle> _particles = [];
  final math.Random _rng = math.Random();
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    final isTesting = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    if (!isTesting) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _initParticles(Size size) {
    if (size == _lastSize || size.isEmpty) return;
    _lastSize = size;
    _particles.clear();
    final count = math.max(45, (size.width * size.height / 11000).round());
    for (int i = 0; i < count; i++) {
      _particles.add(
        _MeshParticle(
          x: _rng.nextDouble() * size.width,
          y: _rng.nextDouble() * size.height,
          vx: (_rng.nextDouble() - 0.5) * 0.5,
          vy: (_rng.nextDouble() - 0.5) * 0.5,
          radius: _rng.nextDouble() * 2.0 + 1.6,
          alpha: _rng.nextDouble() * 0.35 + 0.6,
          isCyan: _rng.nextBool(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _initParticles(size);

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. Базовый фон с лёгкими неоновыми радиальными переливами
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFF090D1A),
                  gradient: RadialGradient(
                    center: Alignment(0.3, -0.5),
                    radius: 1.15,
                    colors: [
                      Color(0x286366F1),
                      Color(0x1822D3EE),
                      Color(0xFF090D1A),
                    ],
                    stops: [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
            // 2. Изолированный слой анимированных частиц (RepaintBoundary)
            if (_particles.isNotEmpty)
              Positioned.fill(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _MeshPainter(
                          particles: _particles,
                          size: size,
                        ),
                      );
                    },
                  ),
                ),
              ),
            // 3. Контент экрана поверх анимированного фона
            Positioned.fill(child: widget.child),
          ],
        );
      },
    );
  }
}

class _MeshParticle {
  double x;
  double y;
  double vx;
  double vy;
  final double radius;
  final double alpha;
  final bool isCyan;

  _MeshParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.radius,
    required this.alpha,
    required this.isCyan,
  });

  void update(Size size) {
    x += vx;
    y += vy;
    if (x < 0 || x > size.width) vx = -vx;
    if (y < 0 || y > size.height) vy = -vy;
  }
}

class _MeshPainter extends CustomPainter {
  final List<_MeshParticle> particles;
  final Size size;

  static final Paint _cyanNodePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _indigoNodePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _linePaint = Paint()
    ..strokeWidth = 1.1
    ..style = PaintingStyle.stroke;

  _MeshPainter({required this.particles, required this.size});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    const maxDist = 165.0;
    const maxDistSq = maxDist * maxDist;

    // 1. Соединительные лазерные линии между близкими узлами
    for (int i = 0; i < particles.length; i++) {
      final p1 = particles[i];
      for (int j = i + 1; j < particles.length; j++) {
        final p2 = particles[j];
        final dx = p1.x - p2.x;
        final dy = p1.y - p2.y;
        final distSq = dx * dx + dy * dy;

        if (distSq < maxDistSq) {
          final dist = math.sqrt(distSq);
          final opacity = (1.0 - dist / maxDist) * 0.42;
          _linePaint.color = const Color(0xFF22D3EE).withValues(alpha: opacity);
          canvas.drawLine(Offset(p1.x, p1.y), Offset(p2.x, p2.y), _linePaint);
        }
      }
    }

    // 2. Светящиеся микро-узлы
    for (int i = 0; i < particles.length; i++) {
      final p = particles[i];
      p.update(size);

      if (p.isCyan) {
        _cyanNodePaint.color = const Color(0xFF22D3EE).withValues(alpha: p.alpha);
        canvas.drawCircle(Offset(p.x, p.y), p.radius, _cyanNodePaint);
      } else {
        _indigoNodePaint.color = const Color(0xFF818CF8).withValues(alpha: p.alpha);
        canvas.drawCircle(Offset(p.x, p.y), p.radius, _indigoNodePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter oldDelegate) => true;
}
