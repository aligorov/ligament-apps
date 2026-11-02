import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/auth_state.dart';

/// Конфигурация темы фона «Созвездие»
class _ThemeMeshConfig {
  final Color backgroundColor;
  final RadialGradient gradient;
  final Color cyanColor;
  final Color indigoColor;
  final Color lineColor;
  final double lineOpacityMultiplier;

  const _ThemeMeshConfig({
    required this.backgroundColor,
    required this.gradient,
    required this.cyanColor,
    required this.indigoColor,
    required this.lineColor,
    required this.lineOpacityMultiplier,
  });

  static const slateMinimal = _ThemeMeshConfig(
    backgroundColor: Color(0xFF0F172A),
    gradient: RadialGradient(
      center: Alignment(0.2, -0.4),
      radius: 1.2,
      colors: [
        Color(0x1F38BDF8),
        Color(0x0F1E293B),
        Color(0xFF0F172A),
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    cyanColor: Color(0xFF38BDF8),
    indigoColor: Color(0xFF64748B),
    lineColor: Color(0xFF38BDF8),
    lineOpacityMultiplier: 0.22,
  );

  static const deepCyber = _ThemeMeshConfig(
    backgroundColor: Color(0xFF060913),
    gradient: RadialGradient(
      center: Alignment(0.3, -0.5),
      radius: 1.15,
      colors: [
        Color(0x286366F1),
        Color(0x1822D3EE),
        Color(0xFF060913),
      ],
      stops: [0.0, 0.45, 1.0],
    ),
    cyanColor: Color(0xFF22D3EE),
    indigoColor: Color(0xFF818CF8),
    lineColor: Color(0xFF22D3EE),
    lineOpacityMultiplier: 0.40,
  );

  static const midnightBlack = _ThemeMeshConfig(
    backgroundColor: Color(0xFF050507),
    gradient: RadialGradient(
      center: Alignment(0.0, -0.6),
      radius: 1.35,
      colors: [
        Color(0x2438BDF8),
        Color(0x0A0F172A),
        Color(0xFF050507),
      ],
      stops: [0.0, 0.5, 1.0],
    ),
    cyanColor: Color(0xFF60A5FA),
    indigoColor: Color(0xFF475569),
    lineColor: Color(0xFF94A3B8),
    lineOpacityMultiplier: 0.25,
  );

  static const emeraldMatrix = _ThemeMeshConfig(
    backgroundColor: Color(0xFF04100E),
    gradient: RadialGradient(
      center: Alignment(0.2, -0.5),
      radius: 1.25,
      colors: [
        Color(0x28059669),
        Color(0x14047857),
        Color(0xFF04100E),
      ],
      stops: [0.0, 0.45, 1.0],
    ),
    cyanColor: Color(0xFF34D399),
    indigoColor: Color(0xFF059669),
    lineColor: Color(0xFF10B981),
    lineOpacityMultiplier: 0.35,
  );

  static const nordicAurora = _ThemeMeshConfig(
    backgroundColor: Color(0xFF090E1A),
    gradient: RadialGradient(
      center: Alignment(-0.2, -0.5),
      radius: 1.3,
      colors: [
        Color(0x280EA5E9),
        Color(0x1E14B8A6),
        Color(0xFF090E1A),
      ],
      stops: [0.0, 0.45, 1.0],
    ),
    cyanColor: Color(0xFF38BDF8),
    indigoColor: Color(0xFF2DD4BF),
    lineColor: Color(0xFF2DD4BF),
    lineOpacityMultiplier: 0.32,
  );

  static _ThemeMeshConfig fromTheme(String theme) {
    switch (theme) {
      case 'deep_cyber':
        return deepCyber;
      case 'midnight_black':
        return midnightBlack;
      case 'emerald_matrix':
        return emeraldMatrix;
      case 'nordic_aurora':
      case 'nordic_frost':
        return nordicAurora;
      case 'slate_minimal':
      default:
        return slateMinimal;
    }
  }
}

/// Адаптивный фон со стилями тем оформления (Slate Minimal, Deep Cyber, Midnight Black, Emerald Matrix, Nordic Aurora)
/// и режимами энергосбережения:
/// - animated: плавная фоновая динамика с автоматической паузой при потере фокуса / минимизации
/// - static: статичное фиксированное созвездие (0% CPU / без таймеров и нагрузки на VDI)
/// - off: лаконичный градиент без частиц
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
    with SingleTickerProviderStateMixin, WindowListener, WidgetsBindingObserver {
  late final AnimationController _controller;
  final List<_MeshParticle> _particles = [];
  final math.Random _rng = math.Random();
  Size _lastSize = Size.zero;
  String _activeAnimationMode = 'static';
  bool _isWindowFocused = true;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      windowManager.addListener(this);
    }

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimationState();
  }

  void _syncAnimationState() {
    AuthState? auth;
    try {
      auth = context.watch<AuthState?>();
    } catch (_) {
      try {
        auth = context.watch<AuthState>();
      } catch (_) {}
    }

    String mode = 'static';
    try {
      mode = auth?.bgAnimation ?? 'static';
    } catch (_) {
      mode = 'static';
    }
    _activeAnimationMode = mode;

    final isTesting =
        !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

    if (isTesting || mode != 'animated' || !_isWindowFocused) {
      if (_controller.isAnimating) {
        _controller.stop();
      }
    } else {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    }
  }

  @override
  void onWindowMinimize() {
    _isWindowFocused = false;
    if (_controller.isAnimating) _controller.stop();
  }

  @override
  void onWindowRestore() {
    _isWindowFocused = true;
    _syncAnimationState();
  }

  @override
  void onWindowFocus() {
    _isWindowFocused = true;
    _syncAnimationState();
  }

  @override
  void onWindowBlur() {
    _isWindowFocused = false;
    if (_controller.isAnimating) _controller.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isWindowFocused = true;
      _syncAnimationState();
    } else {
      _isWindowFocused = false;
      if (_controller.isAnimating) _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _controller.dispose();
    super.dispose();
  }

  void _initParticles(Size size) {
    if (size == _lastSize || size.isEmpty) return;
    _lastSize = size;
    _particles.clear();
    final count = math.max(36, (size.width * size.height / 12500).round());
    for (int i = 0; i < count; i++) {
      _particles.add(
        _MeshParticle(
          x: _rng.nextDouble() * size.width,
          y: _rng.nextDouble() * size.height,
          vx: (_rng.nextDouble() - 0.5) * 0.4,
          vy: (_rng.nextDouble() - 0.5) * 0.4,
          radius: _rng.nextDouble() * 1.8 + 1.4,
          alpha: _rng.nextDouble() * 0.35 + 0.55,
          isCyan: _rng.nextBool(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    AuthState? auth;
    try {
      auth = context.watch<AuthState?>();
    } catch (_) {
      try {
        auth = context.watch<AuthState>();
      } catch (_) {}
    }

    String themeName = 'slate_minimal';
    try {
      themeName = auth?.appTheme ?? 'slate_minimal';
    } catch (_) {
      themeName = 'slate_minimal';
    }
    final config = _ThemeMeshConfig.fromTheme(themeName);
    String animMode = _activeAnimationMode;
    try {
      animMode = auth?.bgAnimation ?? _activeAnimationMode;
    } catch (_) {
      animMode = _activeAnimationMode;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (animMode != 'off') {
          _initParticles(size);
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. Обязательная непрозрачная подложка темы (100% непрозрачный базовый цвет)
            Positioned.fill(
              child: ColoredBox(color: config.backgroundColor),
            ),

            // 2. Тематический радиальный градиент поверх непрозрачной подложки
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: config.gradient,
                ),
              ),
            ),

            // 3. Слой частиц со связями (если не отключен)
            if (animMode != 'off' && _particles.isNotEmpty)
              Positioned.fill(
                child: RepaintBoundary(
                  child: animMode == 'animated'
                      ? AnimatedBuilder(
                          animation: _controller,
                          builder: (context, _) {
                            return CustomPaint(
                              painter: _MeshPainter(
                                particles: _particles,
                                size: size,
                                config: config,
                                animatePositions: true,
                              ),
                            );
                          },
                        )
                      : CustomPaint(
                          painter: _MeshPainter(
                            particles: _particles,
                            size: size,
                            config: config,
                            animatePositions: false,
                          ),
                        ),
                ),
              ),

            // 3. Контент экрана
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
  final _ThemeMeshConfig config;
  final bool animatePositions;

  static final Paint _cyanNodePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _indigoNodePaint = Paint()..style = PaintingStyle.fill;
  static final Paint _linePaint = Paint()
    ..strokeWidth = 1.0
    ..style = PaintingStyle.stroke;

  _MeshPainter({
    required this.particles,
    required this.size,
    required this.config,
    required this.animatePositions,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    const maxDist = 160.0;
    const maxDistSq = maxDist * maxDist;

    // 1. Соединительные линии
    for (int i = 0; i < particles.length; i++) {
      final p1 = particles[i];
      for (int j = i + 1; j < particles.length; j++) {
        final p2 = particles[j];
        final dx = p1.x - p2.x;
        final dy = p1.y - p2.y;
        final distSq = dx * dx + dy * dy;

        if (distSq < maxDistSq) {
          final dist = math.sqrt(distSq);
          final opacity =
              (1.0 - dist / maxDist) * config.lineOpacityMultiplier;
          _linePaint.color = config.lineColor.withValues(alpha: opacity);
          canvas.drawLine(Offset(p1.x, p1.y), Offset(p2.x, p2.y), _linePaint);
        }
      }
    }

    // 2. Светящиеся микро-узлы
    for (int i = 0; i < particles.length; i++) {
      final p = particles[i];
      if (animatePositions) {
        p.update(size);
      }

      if (p.isCyan) {
        _cyanNodePaint.color =
            config.cyanColor.withValues(alpha: p.alpha);
        canvas.drawCircle(Offset(p.x, p.y), p.radius, _cyanNodePaint);
      } else {
        _indigoNodePaint.color =
            config.indigoColor.withValues(alpha: p.alpha);
        canvas.drawCircle(Offset(p.x, p.y), p.radius, _indigoNodePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter oldDelegate) {
    return animatePositions || oldDelegate.config != config;
  }
}
