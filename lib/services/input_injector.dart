import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// CoreGraphics struct for macOS
final class _CGPoint extends ffi.Struct {
  @ffi.Double()
  external double x;
  @ffi.Double()
  external double y;
}

// Win32 RECT struct for ClipCursor / MONITORINFO
final class _RECT extends ffi.Struct {
  @ffi.Int32()
  external int left;
  @ffi.Int32()
  external int top;
  @ffi.Int32()
  external int right;
  @ffi.Int32()
  external int bottom;
}

// macOS CGRect / CGSize for CGDisplayBounds
final class _CGSize extends ffi.Struct {
  @ffi.Double()
  external double width;
  @ffi.Double()
  external double height;
}

final class _CGRect extends ffi.Struct {
  external _CGPoint origin;
  external _CGSize size;
}

// Win32 MONITORINFO for GetMonitorInfoW
final class _MONITORINFO extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;
  external _RECT rcMonitor;
  external _RECT rcWork;
  @ffi.Uint32()
  external int dwFlags;
}

/// Геометрия монитора в координатах виртуального рабочего стола
/// (absolute desktop coordinates: x/y — смещение левого верхнего угла).
class ScreenRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const ScreenRect(this.x, this.y, this.width, this.height);

  factory ScreenRect.fromLTRB(int left, int top, int right, int bottom) =>
      ScreenRect(left, top, right - left, bottom - top);

  int get right => x + width;
  int get bottom => y + height;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};

  @override
  String toString() => 'ScreenRect($x, $y, ${width}x$height)';

  @override
  bool operator ==(Object other) =>
      other is ScreenRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// Сервис внедрения пользовательского ввода (мышь и клавиатура) на Windows, macOS и Linux.
class InputInjector {
  static final InputInjector instance = InputInjector._();
  InputInjector._() {
    _initMacCG();
    _initWinUser32();
  }

  // macOS CoreGraphics FFI handles
  ffi.DynamicLibrary? _cgLib;
  ffi.DynamicLibrary? _cfLib;
  int Function()? _cgMainDisplayID;
  int Function(int)? _cgDisplayPixelsWide;
  int Function(int)? _cgDisplayPixelsHigh;
  int Function(_CGPoint)? _cgWarpMouseCursorPosition;
  int Function(int)? _cgAssociateMouse;
  void Function(ffi.Pointer<ffi.Void>)? _cfRelease;
  ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, _CGPoint, int)? _cgEventCreateMouseEvent;
  ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, bool)? _cgEventCreateKeyboardEvent;
  ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, int)? _cgEventCreateScrollWheelEvent;
  void Function(int, ffi.Pointer<ffi.Void>)? _cgEventPost;
  int Function(int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>)? _cgGetActiveDisplayList;
  _CGRect Function(int)? _cgDisplayBounds;
  bool Function()? _axIsProcessTrusted;

  // Windows User32 FFI handles
  ffi.DynamicLibrary? _user32Lib;
  int Function(int, int)? _winSetCursorPos;
  void Function(int, int, int, int, int)? _winMouseEvent;
  void Function(int, int, int, int)? _winKeybdEvent;
  int Function(int)? _winBlockInput;
  int Function(ffi.Pointer<_RECT>)? _winClipCursor;
  int Function()? _winLockWorkStation;
  int Function(int)? _winGetSystemMetrics;
  int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_MONITORINFO>)? _winGetMonitorInfo;

  // Windows LL-хуки блокировки физического ввода: колбэки и message loop
  // живут в нативном input_block.cpp (runner, экспорт из exe) — из чистого
  // Dart LL-хуки недостижимы (NativeCallable.listener не возвращает
  // значение, а хук требует message pump потока-постановщика).
  // BlockInput требует админа и молча отказывает; LL-хуки работают без
  // повышения и пропускают инъекции агента (см. input_block.cpp).
  int Function()? _nativeInstallBlock;
  int Function()? _nativeRemoveBlock;

  void _initMacCG() {
    if (kIsWeb || !Platform.isMacOS) return;
    try {
      _cgLib = ffi.DynamicLibrary.open('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
      _cfLib = ffi.DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

      _cgMainDisplayID = _cgLib!.lookupFunction<ffi.Uint32 Function(), int Function()>('CGMainDisplayID');
      _cgDisplayPixelsWide = _cgLib!.lookupFunction<ffi.IntPtr Function(ffi.Uint32), int Function(int)>('CGDisplayPixelsWide');
      _cgDisplayPixelsHigh = _cgLib!.lookupFunction<ffi.IntPtr Function(ffi.Uint32), int Function(int)>('CGDisplayPixelsHigh');
      _cgWarpMouseCursorPosition = _cgLib!.lookupFunction<ffi.Int32 Function(_CGPoint), int Function(_CGPoint)>('CGWarpMouseCursorPosition');
      _cgAssociateMouse = _cgLib!.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>('CGAssociateMouseAndMouseCursorPosition');
      _cfRelease = _cfLib!.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>), void Function(ffi.Pointer<ffi.Void>)>('CFRelease');

      _cgEventCreateMouseEvent = _cgLib!.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32, _CGPoint, ffi.Uint32),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, _CGPoint, int)>('CGEventCreateMouseEvent');

      _cgEventCreateKeyboardEvent = _cgLib!.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint16, ffi.Bool),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, bool)>('CGEventCreateKeyboardEvent');

      // Вариадик CGEventCreateScrollWheelEvent(source, units, wheelCount, wheel1, ...)
      _cgEventCreateScrollWheelEvent = _cgLib!.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32,
              ffi.VarArgs<(ffi.Int32,)>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, int)>(
          'CGEventCreateScrollWheelEvent');

      _cgGetActiveDisplayList = _cgLib!.lookupFunction<
          ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>),
          int Function(int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>)>(
              'CGGetActiveDisplayList');

      _cgDisplayBounds = _cgLib!.lookupFunction<
          _CGRect Function(ffi.Uint32),
          _CGRect Function(int)>('CGDisplayBounds');

      _cgEventPost = _cgLib!.lookupFunction<
          ffi.Void Function(ffi.Uint32, ffi.Pointer<ffi.Void>),
          void Function(int, ffi.Pointer<ffi.Void>)>('CGEventPost');

      // AXIsProcessTrusted (HIServices): без Accessibility-разрешения
      // инъекции мыши/клавиатуры молча игнорируются macOS.
      try {
        final axLib = ffi.DynamicLibrary.open(
            '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
        _axIsProcessTrusted = axLib.lookupFunction<
            ffi.Bool Function(),
            bool Function()>('AXIsProcessTrusted');
      } catch (e) {
        debugPrint('input_injector: AXIsProcessTrusted недоступен: $e');
      }
    } catch (e) {
      debugPrint('input_injector: ошибка загрузки macOS CoreGraphics: $e');
    }
  }

  void _initWinUser32() {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      _user32Lib = ffi.DynamicLibrary.open('user32.dll');
      _winSetCursorPos = _user32Lib!.lookupFunction<
          ffi.Int32 Function(ffi.Int32, ffi.Int32),
          int Function(int, int)>('SetCursorPos');
      _winMouseEvent = _user32Lib!.lookupFunction<
          ffi.Void Function(ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.IntPtr),
          void Function(int, int, int, int, int)>('mouse_event');
      _winKeybdEvent = _user32Lib!.lookupFunction<
          ffi.Void Function(ffi.Uint8, ffi.Uint8, ffi.Uint32, ffi.IntPtr),
          void Function(int, int, int, int)>('keybd_event');
      _winBlockInput = _user32Lib!.lookupFunction<
          ffi.Int32 Function(ffi.Int32),
          int Function(int)>('BlockInput');
      _winClipCursor = _user32Lib!.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<_RECT>),
          int Function(ffi.Pointer<_RECT>)>('ClipCursor');
      _winLockWorkStation = _user32Lib!.lookupFunction<
          ffi.Int32 Function(),
          int Function()>('LockWorkStation');
      _winGetSystemMetrics = _user32Lib!.lookupFunction<
          ffi.Int32 Function(ffi.Int32),
          int Function(int)>('GetSystemMetrics');
      _winGetMonitorInfo = _user32Lib!.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_MONITORINFO>),
          int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_MONITORINFO>)>('GetMonitorInfoW');
      // Нативный хелпер блокировки: экспорт из собственного exe
      // (windows/runner/input_block.cpp, dllexport).
      try {
        final exe = ffi.DynamicLibrary.executable();
        _nativeInstallBlock = exe.lookupFunction<ffi.Int32 Function(), int Function()>(
            'ligament_install_input_block');
        _nativeRemoveBlock = exe.lookupFunction<ffi.Int32 Function(), int Function()>(
            'ligament_remove_input_block');
      } catch (e) {
        debugPrint('input_injector: нативный блокировщик ввода недоступен: $e');
      }
    } catch (e) {
      debugPrint('input_injector: ошибка загрузки user32.dll: $e');
    }
  }

  // === Мультимониторная геометрия (B-2) ===

  // Windows GetSystemMetrics codes
  static const int _smXVirtualScreen = 76;
  static const int _smYVirtualScreen = 77;
  static const int _smCxVirtualScreen = 78;
  static const int _smCyVirtualScreen = 79;

  // mouse_event flags
  static const int _mouseEventfVirtualDesk = 0x4000;
  static const int _mouseEventfAbsolute = 0x8000;

  /// Геометрия АКТИВНОГО транслируемого монитора (в координатах виртуального
  /// рабочего стола). Оператор присылает нормализованные координаты 0..1
  /// относительно видеопотока; инъекция маппится в этот rect, чтобы клик
  /// попадал на правильный монитор, а не всегда в primary.
  ScreenRect? _activeMonitorRect;

  ScreenRect? get activeMonitorRect => _activeMonitorRect;

  void setActiveMonitorRect(ScreenRect? rect) {
    _activeMonitorRect = (rect != null && rect.width > 0 && rect.height > 0) ? rect : null;
  }

  /// Поддерживается ли инъекция ввода на текущей платформе.
  /// На Android/iOS/Web InputInjector — no-op: UI должен честно показывать
  /// режим «Просмотр» вместо «Полный контроль».
  bool get isInputInjectionSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// macOS: выдано ли приложению Accessibility-разрешение
  /// (Системные настройки → Конфиденциальность → Универсальный доступ).
  /// Без него CGEventPost молча отбрасывает события.
  bool? get macAccessibilityTrusted {
    if (kIsWeb || !Platform.isMacOS) return null;
    try {
      return _axIsProcessTrusted?.call() ?? false;
    } catch (_) {
      return null;
    }
  }

  /// Нормализованные 0..1 координаты -> абсолютные координаты внутри rect.
  /// Чистая функция (тестируемая без устройства).
  static (int, int) mapNormToRect(double normX, double normY, ScreenRect rect) {
    final nx = normX.isFinite ? normX.clamp(0.0, 1.0) : 0.0;
    final ny = normY.isFinite ? normY.clamp(0.0, 1.0) : 0.0;
    final px = (rect.x + nx * (rect.width - 1)).round().clamp(rect.x, rect.right - 1);
    final py = (rect.y + ny * (rect.height - 1)).round().clamp(rect.y, rect.bottom - 1);
    return (px, py);
  }

  /// Абсолютная координата виртуального рабочего стола -> 0..65535 в границах
  /// виртуального стола (нормализация для MOUSEEVENTF_ABSOLUTE|VIRTUALDESK).
  /// Формула по MSDN: (pos - virtMin) * 65535 / (virtSize - 1).
  static int normalizeVirtualDeskAxis(int pos, int virtMin, int virtSize) {
    if (virtSize <= 1) return 0;
    final v = ((pos - virtMin) * 65535) ~/ (virtSize - 1);
    return v.clamp(0, 65535);
  }

  /// Rect всего виртуального рабочего стола (объединение всех мониторов).
  ScreenRect getVirtualDesktopRect() {
    if (kIsWeb) return const ScreenRect(0, 0, 1920, 1080);
    if (Platform.isWindows) {
      final vx = _winGetSystemMetrics?.call(_smXVirtualScreen) ?? 0;
      final vy = _winGetSystemMetrics?.call(_smYVirtualScreen) ?? 0;
      final vw = _winGetSystemMetrics?.call(_smCxVirtualScreen) ?? 0;
      final vh = _winGetSystemMetrics?.call(_smCyVirtualScreen) ?? 0;
      if (vw > 0 && vh > 0) return ScreenRect(vx, vy, vw, vh);
      final (w, h) = getScreenSize();
      return ScreenRect(0, 0, w, h);
    }
    if (Platform.isMacOS) {
      // Объединение bounds всех активных дисплеев (CG, координаты top-left).
      final displays = <int>[];
      try {
        const maxDisplays = 16;
        final buf = calloc<ffi.Uint32>(maxDisplays);
        final count = calloc<ffi.Uint32>();
        final err = _cgGetActiveDisplayList?.call(maxDisplays, buf, count) ?? -1;
        if (err == 0 && count.value > 0) {
          for (int i = 0; i < count.value && i < maxDisplays; i++) {
            displays.add(buf[i]);
          }
        }
        calloc.free(buf);
        calloc.free(count);
      } catch (_) {}
      if (displays.isNotEmpty && _cgDisplayBounds != null) {
        int minX = 1 << 30, minY = 1 << 30, maxX = -(1 << 30), maxY = -(1 << 30);
        for (final d in displays) {
          final b = _cgDisplayBounds!(d);
          final l = b.origin.x.round();
          final t = b.origin.y.round();
          final r = l + b.size.width.round();
          final bt = t + b.size.height.round();
          if (l < minX) minX = l;
          if (t < minY) minY = t;
          if (r > maxX) maxX = r;
          if (bt > maxY) maxY = bt;
        }
        if (maxX > minX && maxY > minY) {
          return ScreenRect(minX, minY, maxX - minX, maxY - minY);
        }
      }
      final (w, h) = getScreenSize();
      return ScreenRect(0, 0, w, h);
    }
    final (w, h) = getScreenSize();
    return ScreenRect(0, 0, w, h);
  }

  /// Геометрия primary-монитора (фолбэк, когда rect активного монитора
  /// определить не удалось — прежнее поведение).
  ScreenRect _fallbackInputRect() {
    if (!kIsWeb && Platform.isWindows) {
      final vw = _winGetSystemMetrics?.call(0) ?? 0; // SM_CXSCREEN
      final vh = _winGetSystemMetrics?.call(1) ?? 0; // SM_CYSCREEN
      if (vw > 0 && vh > 0) return ScreenRect(0, 0, vw, vh);
    }
    final (w, h) = getScreenSize();
    return ScreenRect(0, 0, w, h);
  }

  /// Извлекает числовые идентификаторы из id источника desktopCapturer.
  /// Форматы зависят от платформы/версии webrtc ("screen:123", "123",
  /// "screen:0:0") — возвращаются все найденные числа, валидация делается
  /// дальше через GetMonitorInfoW/CGDisplayBounds.
  static List<int> _parseSourceHandles(String sourceId) {
    final handles = <int>[];
    for (final m in RegExp(r'\d+').allMatches(sourceId)) {
      final v = int.tryParse(m.group(0)!);
      if (v != null && v > 0) handles.add(v);
    }
    return handles;
  }

  /// Геометрия монитора по id источника desktopCapturer.
  /// Windows: id трактуется как HMONITOR (валидируется GetMonitorInfoW);
  /// macOS: как CGDirectDisplayID (CGDisplayBounds).
  /// Возвращает null, если платформа не поддерживается или id не resolves.
  ScreenRect? getMonitorRectForSource(String sourceId) {
    if (kIsWeb) return null;
    final handles = _parseSourceHandles(sourceId);
    if (handles.isEmpty) return null;

    if (Platform.isWindows && _winGetMonitorInfo != null) {
      final mi = calloc<_MONITORINFO>();
      try {
        for (final h in handles) {
          mi.ref.cbSize = ffi.sizeOf<_MONITORINFO>();
          final rc = _winGetMonitorInfo!(ffi.Pointer.fromAddress(h), mi);
          if (rc != 0) {
            final r = mi.ref.rcMonitor;
            if (r.right > r.left && r.bottom > r.top) {
              return ScreenRect.fromLTRB(r.left, r.top, r.right, r.bottom);
            }
          }
        }
      } catch (_) {
        // невалидный handle — фолбэк на primary
      } finally {
        calloc.free(mi);
      }
      return null;
    }

    if (Platform.isMacOS && _cgDisplayBounds != null) {
      for (final h in handles) {
        if (h <= 0 || h > 0xFFFFFFFF) continue;
        try {
          final b = _cgDisplayBounds!(h);
          final w = b.size.width.round();
          final ht = b.size.height.round();
          if (w > 0 && ht > 0) {
            return ScreenRect(b.origin.x.round(), b.origin.y.round(), w, ht);
          }
        } catch (_) {}
      }
      return null;
    }

    return null;
  }

  /// Абсолютные координаты в виртуальном рабочем столе из нормализованных 0..1
  /// координат оператора: маппинг в геометрию активного монитора, при её
  /// отсутствии — в primary (прежнее поведение).
  (int, int) absoluteFromNorm(double normX, double normY) {
    final rect = _activeMonitorRect ?? _fallbackInputRect();
    return mapNormToRect(normX, normY, rect);
  }

  /// Получение физических размеров основного экрана (пиксели)
  (int width, int height) getScreenSize() {
    if (kIsWeb) return (1920, 1080);
    if (Platform.isMacOS) {
      if (_cgMainDisplayID != null && _cgDisplayPixelsWide != null && _cgDisplayPixelsHigh != null) {
        final disp = _cgMainDisplayID!();
        final w = _cgDisplayPixelsWide!(disp);
        final h = _cgDisplayPixelsHigh!(disp);
        return (w > 0 ? w : 1920, h > 0 ? h : 1080);
      }
    } else if (Platform.isWindows) {
      final w = _winGetSystemMetrics?.call(0) ?? 1920; // SM_CXSCREEN = 0
      final h = _winGetSystemMetrics?.call(1) ?? 1080; // SM_CYSCREEN = 1
      return (w > 0 ? w : 1920, h > 0 ? h : 1080);
    }
    return (1920, 1080);
  }

  /// Перемещение курсора мыши в абсолютные координаты 0..1 относительно
  /// активного транслируемого монитора.
  void moveMouse(double normX, double normY) {
    if (kIsWeb) return;

    if (Platform.isMacOS) {
      final (px, py) = absoluteFromNorm(normX, normY);
      final pt = calloc<_CGPoint>();
      pt.ref.x = px.toDouble();
      pt.ref.y = py.toDouble();
      _cgWarpMouseCursorPosition?.call(pt.ref);
      calloc.free(pt);
      _postMacMouseEvent(5, px.toDouble(), py.toDouble(), 0); // 5 = kCGEventMouseMoved
    } else if (Platform.isWindows) {
      final (px, py) = absoluteFromNorm(normX, normY);
      final virt = getVirtualDesktopRect();
      _winSetCursorPos?.call(px, py);
      const mouseEventfMove = 0x0001;
      final absX = normalizeVirtualDeskAxis(px, virt.x, virt.width);
      final absY = normalizeVirtualDeskAxis(py, virt.y, virt.height);
      _winMouseEvent?.call(
          mouseEventfMove | _mouseEventfAbsolute | _mouseEventfVirtualDesk, absX, absY, 0, 0);
    } else if (Platform.isLinux) {
      final (px, py) = absoluteFromNorm(normX, normY);
      Process.run('xdotool', ['mousemove', px.toString(), py.toString()]);
    }
  }

  /// Нажатие или отпускание кнопки мыши (0: Left, 1: Middle, 2: Right)
  void mouseAction({
    required String action, // 'down' | 'up' | 'click'
    required int button,
    required double normX,
    required double normY,
  }) {
    if (kIsWeb) return;

    if (Platform.isMacOS) {
      final (px, py) = absoluteFromNorm(normX, normY);
      final pt = calloc<_CGPoint>();
      pt.ref.x = px.toDouble();
      pt.ref.y = py.toDouble();
      _cgWarpMouseCursorPosition?.call(pt.ref);
      calloc.free(pt);

      int eventDown = 1; // kCGEventLeftMouseDown
      int eventUp = 2;   // kCGEventLeftMouseUp
      int mouseBtn = 0;  // kCGMouseButtonLeft

      if (button == 2) {
        eventDown = 3; // kCGEventRightMouseDown
        eventUp = 4;   // kCGEventRightMouseUp
        mouseBtn = 1;  // kCGMouseButtonRight
      } else if (button == 1) {
        eventDown = 25; // kCGEventOtherMouseDown
        eventUp = 26;   // kCGEventOtherMouseUp
        mouseBtn = 2;   // kCGMouseButtonCenter
      }

      if (action == 'down') {
        _postMacMouseEvent(eventDown, px.toDouble(), py.toDouble(), mouseBtn);
      } else if (action == 'up') {
        _postMacMouseEvent(eventUp, px.toDouble(), py.toDouble(), mouseBtn);
      } else {
        _postMacMouseEvent(eventDown, px.toDouble(), py.toDouble(), mouseBtn);
        _postMacMouseEvent(eventUp, px.toDouble(), py.toDouble(), mouseBtn);
      }
    } else if (Platform.isWindows) {
      final (px, py) = absoluteFromNorm(normX, normY);
      final virt = getVirtualDesktopRect();
      _winSetCursorPos?.call(px, py);
      const leftDown = 0x0002;
      const leftUp = 0x0004;
      const rightDown = 0x0008;
      const rightUp = 0x0010;
      const midDown = 0x0020;
      const midUp = 0x0040;
      final absX = normalizeVirtualDeskAxis(px, virt.x, virt.width);
      final absY = normalizeVirtualDeskAxis(py, virt.y, virt.height);

      int flagDown = leftDown;
      int flagUp = leftUp;

      if (button == 2) {
        flagDown = rightDown;
        flagUp = rightUp;
      } else if (button == 1) {
        flagDown = midDown;
        flagUp = midUp;
      }

      if (action == 'down') {
        _winMouseEvent?.call(flagDown | _mouseEventfAbsolute | _mouseEventfVirtualDesk, absX, absY, 0, 0);
      } else if (action == 'up') {
        _winMouseEvent?.call(flagUp | _mouseEventfAbsolute | _mouseEventfVirtualDesk, absX, absY, 0, 0);
      } else {
        _winMouseEvent?.call(flagDown | _mouseEventfAbsolute | _mouseEventfVirtualDesk, absX, absY, 0, 0);
        _winMouseEvent?.call(flagUp | _mouseEventfAbsolute | _mouseEventfVirtualDesk, absX, absY, 0, 0);
      }
    } else if (Platform.isLinux) {
      final (px, py) = absoluteFromNorm(normX, normY);
      _ensureLinuxPointerAt(px, py);
      final btnStr = button == 2 ? '3' : (button == 1 ? '2' : '1');
      if (action == 'down') {
        Process.run('xdotool', ['mousedown', btnStr]);
      } else if (action == 'up') {
        Process.run('xdotool', ['mouseup', btnStr]);
      } else {
        Process.run('xdotool', ['click', btnStr]);
      }
    }
  }

  /// Перемещение курсора перед кликом на Linux (клик исполняется в текущей
  /// позиции курсора, поэтому координаты важны и для down/up).
  void _ensureLinuxPointerAt(int px, int py) {
    Process.run('xdotool', ['mousemove', px.toString(), py.toString()]);
  }

  void _postMacMouseEvent(int type, double x, double y, int button) {
    if (_cgEventCreateMouseEvent == null || _cgEventPost == null || _cfRelease == null) return;
    final pt = calloc<_CGPoint>();
    pt.ref.x = x;
    pt.ref.y = y;
    final event = _cgEventCreateMouseEvent!(ffi.Pointer.fromAddress(0), type, pt.ref, button);
    calloc.free(pt);
    if (event.address != 0) {
      _cgEventPost!(0, event); // 0 = kCGHIDEventTap
      _cgEventPost!(1, event); // 1 = kCGSessionEventTap
      _cfRelease!(event);
    }
  }

  /// Прокрутка колеса мыши
  void mouseWheel(double deltaY) {
    if (kIsWeb) return;
    if (Platform.isMacOS) {
      // m-1: корректный scroll через CGEventCreateScrollWheelEvent
      // (units = kCGScrollEventUnitLine = 1, wheelCount = 1).
      // Положительное значение прокручивает ВВЕРХ, у оператора deltaY>0 — вниз.
      final ticks = (-deltaY).round().clamp(-50, 50);
      if (ticks == 0) return;
      final ev = _cgEventCreateScrollWheelEvent?.call(ffi.Pointer.fromAddress(0), 1, 1, ticks);
      if (ev != null && ev.address != 0 && _cgEventPost != null && _cfRelease != null) {
        _cgEventPost!(0, ev); // kCGHIDEventTap
        _cgEventPost!(1, ev); // kCGSessionEventTap
        _cfRelease!(ev);
      }
    } else if (Platform.isWindows) {
      final dy = (-deltaY * 40).round();
      _winMouseEvent?.call(0x0800, 0, 0, dy, 0); // 0x0800 = MOUSEEVENTF_WHEEL
    } else if (Platform.isLinux) {
      final click = deltaY > 0 ? '5' : '4';
      Process.run('xdotool', ['click', click]);
    }
  }

  /// Ввод клавиши (key down / up)
  void keyAction({required String action, required String key, int? keyCode}) {
    if (kIsWeb) return;
    final isDown = action == 'down';

    if (Platform.isMacOS) {
      final macCode = _mapToMacKeyCode(key, keyCode);
      if (macCode != null && _cgEventCreateKeyboardEvent != null && _cgEventPost != null && _cfRelease != null) {
        final ev = _cgEventCreateKeyboardEvent!(ffi.Pointer.fromAddress(0), macCode, isDown);
        if (ev.address != 0) {
          _cgEventPost!(0, ev); // 0 = kCGHIDEventTap
          _cgEventPost!(1, ev); // 1 = kCGSessionEventTap
          _cfRelease!(ev);
        }
      }
    } else if (Platform.isWindows) {
      final winCode = _mapToWinKeyCode(key, keyCode);
      if (winCode != 0) {
        final flags = isDown ? 0 : 0x0002; // 0x0002 = KEYEVENTF_KEYUP
        _winKeybdEvent?.call(winCode, 0, flags, 0);
      }
    } else if (Platform.isLinux) {
      final act = isDown ? 'keydown' : 'keyup';
      Process.run('xdotool', [act, key]);
    }
  }

  /// Блокировка или разблокировка ввода у локального пользователя (мышь/клавиатура).
  ///
  /// Windows: низкоуровневые хуки WH_KEYBOARD_LL/WH_MOUSE_LL — работают БЕЗ
  /// прав администратора (BlockInput молча отказывает в юзер-процессе) и
  /// пропускают инъекции самого агента (LLKHF/LLMHF_INJECTED), чтобы инженер
  /// сохранял управление. ClipCursor+BlockInput остаются как усиление (для
  /// процессов с правами).
  void setInputBlocked(bool blocked) {
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        if (blocked) {
          final rc = _nativeInstallBlock?.call() ?? -1;
          debugPrint('input_injector: install_input_block rc=$rc '
              '(0=LL-хуки активны, -1=хуки не встали, -2=исключение)');

          // Дополнительно: курсор в точку 0,0 (без прав) и BlockInput
          // (сработает только при повышенных правах процесса).
          final rect = calloc<_RECT>();
          rect.ref.left = 0;
          rect.ref.top = 0;
          rect.ref.right = 1;
          rect.ref.bottom = 1;
          _winClipCursor?.call(rect);
          calloc.free(rect);
          _winBlockInput?.call(1);
        } else {
          _nativeRemoveBlock?.call();
          _winClipCursor?.call(ffi.Pointer.fromAddress(0));
          _winBlockInput?.call(0);
        }
      } else if (Platform.isMacOS) {
        // CGAssociateMouseAndMouseCursorPosition: 0 отключает физическое движение курсора мышью
        _cgAssociateMouse?.call(blocked ? 0 : 1);
      }
    } catch (e) {
      debugPrint('input_injector: ошибка изменения блокировки ввода: $e');
    }
  }

  /// Вызов системных горячих клавиш (Пуск, Ctrl+Alt+Del, Alt+Tab и т.д.)
  Future<void> triggerHotkey(String hotkey) async {
    if (kIsWeb) return;

    if (Platform.isWindows) {
      const vkTab = 0x09;
      const vkShift = 0x10;
      const vkControl = 0x11;
      const vkMenu = 0x12; // Alt
      const vkEscape = 0x1B;
      const vkLWin = 0x5B;
      const vkF4 = 0x73;
      const keyUp = 0x0002;

      switch (hotkey) {
        case 'win_key':
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_r':
          final vkR = 'R'.codeUnitAt(0);
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkR, 0, 0, 0);
          _winKeybdEvent?.call(vkR, 0, keyUp, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_d':
          final vkD = 'D'.codeUnitAt(0);
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkD, 0, 0, 0);
          _winKeybdEvent?.call(vkD, 0, keyUp, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_e':
          final vkE = 'E'.codeUnitAt(0);
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkE, 0, 0, 0);
          _winKeybdEvent?.call(vkE, 0, keyUp, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_x':
          final vkX = 'X'.codeUnitAt(0);
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkX, 0, 0, 0);
          _winKeybdEvent?.call(vkX, 0, keyUp, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_i':
          final vkI = 'I'.codeUnitAt(0);
          _winKeybdEvent?.call(vkLWin, 0, 0, 0);
          _winKeybdEvent?.call(vkI, 0, 0, 0);
          _winKeybdEvent?.call(vkI, 0, keyUp, 0);
          _winKeybdEvent?.call(vkLWin, 0, keyUp, 0);
          break;
        case 'win_l':
          _winLockWorkStation?.call();
          break;
        case 'ctrl_c':
          final vkC = 'C'.codeUnitAt(0);
          _winKeybdEvent?.call(vkControl, 0, 0, 0);
          _winKeybdEvent?.call(vkC, 0, 0, 0);
          _winKeybdEvent?.call(vkC, 0, keyUp, 0);
          _winKeybdEvent?.call(vkControl, 0, keyUp, 0);
          break;
        case 'ctrl_v':
          final vkV = 'V'.codeUnitAt(0);
          _winKeybdEvent?.call(vkControl, 0, 0, 0);
          _winKeybdEvent?.call(vkV, 0, 0, 0);
          _winKeybdEvent?.call(vkV, 0, keyUp, 0);
          _winKeybdEvent?.call(vkControl, 0, keyUp, 0);
          break;
        case 'ctrl_a':
          final vkA = 'A'.codeUnitAt(0);
          _winKeybdEvent?.call(vkControl, 0, 0, 0);
          _winKeybdEvent?.call(vkA, 0, 0, 0);
          _winKeybdEvent?.call(vkA, 0, keyUp, 0);
          _winKeybdEvent?.call(vkControl, 0, keyUp, 0);
          break;
        case 'task_mgr':
        case 'ctrl_alt_del':
        case 'ctrl_shift_esc':
          // Ctrl+Shift+Esc гарантированно открывает Диспетчер задач без требования SAS
          _winKeybdEvent?.call(vkControl, 0, 0, 0);
          _winKeybdEvent?.call(vkShift, 0, 0, 0);
          _winKeybdEvent?.call(vkEscape, 0, 0, 0);
          _winKeybdEvent?.call(vkEscape, 0, keyUp, 0);
          _winKeybdEvent?.call(vkShift, 0, keyUp, 0);
          _winKeybdEvent?.call(vkControl, 0, keyUp, 0);
          break;
        case 'alt_tab':
          _winKeybdEvent?.call(vkMenu, 0, 0, 0);
          _winKeybdEvent?.call(vkTab, 0, 0, 0);
          _winKeybdEvent?.call(vkTab, 0, keyUp, 0);
          _winKeybdEvent?.call(vkMenu, 0, keyUp, 0);
          break;
        case 'alt_f4':
          _winKeybdEvent?.call(vkMenu, 0, 0, 0);
          _winKeybdEvent?.call(vkF4, 0, 0, 0);
          _winKeybdEvent?.call(vkF4, 0, keyUp, 0);
          _winKeybdEvent?.call(vkMenu, 0, keyUp, 0);
          break;
        case 'esc':
          _winKeybdEvent?.call(vkEscape, 0, 0, 0);
          _winKeybdEvent?.call(vkEscape, 0, keyUp, 0);
          break;
      }
    } else if (Platform.isMacOS) {
      switch (hotkey) {
        case 'win_key':
        case 'spotlight':
        case 'cmd_space':
          // Cmd + Space (Spotlight)
          _postMacKey(55, true); // Cmd
          _postMacKey(49, true); // Space
          _postMacKey(49, false);
          _postMacKey(55, false);
          break;
        case 'task_mgr':
        case 'ctrl_alt_del':
        case 'cmd_opt_esc':
          // Cmd + Option + Escape (Завершить принудительно)
          _postMacKey(55, true); // Cmd
          _postMacKey(58, true); // Option
          _postMacKey(53, true); // Esc
          _postMacKey(53, false);
          _postMacKey(58, false);
          _postMacKey(55, false);
          break;
        case 'alt_tab':
        case 'cmd_tab':
          // Cmd + Tab
          _postMacKey(55, true);
          _postMacKey(48, true);
          _postMacKey(48, false);
          _postMacKey(55, false);
          break;
        case 'alt_f4':
          // Cmd + Q
          _postMacKey(55, true);
          _postMacKey(12, true);
          _postMacKey(12, false);
          _postMacKey(55, false);
          break;
        case 'ctrl_c':
        case 'cmd_c':
          _postMacKey(55, true);
          _postMacKey(8, true);
          _postMacKey(8, false);
          _postMacKey(55, false);
          break;
        case 'ctrl_v':
        case 'cmd_v':
          _postMacKey(55, true);
          _postMacKey(9, true);
          _postMacKey(9, false);
          _postMacKey(55, false);
          break;
        case 'ctrl_a':
        case 'cmd_a':
          _postMacKey(55, true);
          _postMacKey(0, true);
          _postMacKey(0, false);
          _postMacKey(55, false);
          break;
        case 'esc':
          _postMacKey(53, true);
          _postMacKey(53, false);
          break;
      }
    }
  }

  void _postMacKey(int code, bool down) {
    if (_cgEventCreateKeyboardEvent == null || _cgEventPost == null || _cfRelease == null) return;
    final ev = _cgEventCreateKeyboardEvent!(ffi.Pointer.fromAddress(0), code, down);
    if (ev.address != 0) {
      _cgEventPost!(0, ev);
      _cfRelease!(ev);
    }
  }

  int? _mapToMacKeyCode(String key, int? code) {
    if (code != null && code > 0) return code;
    switch (key.toLowerCase()) {
      case 'enter':
      case 'return': return 36;
      case 'tab': return 48;
      case 'space':
      case ' ': return 49;
      case 'backspace':
      case 'delete': return 51;
      case 'escape':
      case 'esc': return 53;
      case 'command':
      case 'meta': return 55;
      case 'shift': return 56;
      case 'option':
      case 'alt': return 58;
      case 'control':
      case 'ctrl': return 59;
      case 'arrowleft': return 123;
      case 'arrowright': return 124;
      case 'arrowdown': return 125;
      case 'arrowup': return 126;
      case 'a': return 0;
      case 's': return 1;
      case 'd': return 2;
      case 'f': return 3;
      case 'h': return 4;
      case 'g': return 5;
      case 'z': return 6;
      case 'x': return 7;
      case 'c': return 8;
      case 'v': return 9;
      case 'b': return 11;
      case 'q': return 12;
      case 'w': return 13;
      case 'e': return 14;
      case 'r': return 15;
      case 'y': return 16;
      case 't': return 17;
      default:
        if (key.length == 1) {
          final cu = key.toUpperCase().codeUnitAt(0);
          if (cu >= 65 && cu <= 90) {
            const macLetters = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6];
            return macLetters[cu - 65];
          }
        }
        return null;
    }
  }

  int _mapToWinKeyCode(String key, int? code) {
    if (code != null && code > 0) return code;
    switch (key.toLowerCase()) {
      case 'enter': return 0x0D; // VK_RETURN
      case 'tab': return 0x09;   // VK_TAB
      case 'space':
      case ' ': return 0x20;     // VK_SPACE
      case 'backspace': return 0x08; // VK_BACK
      case 'delete': return 0x2E; // VK_DELETE
      case 'escape':
      case 'esc': return 0x1B;    // VK_ESCAPE
      case 'control':
      case 'ctrl': return 0x11;   // VK_CONTROL
      case 'alt': return 0x12;    // VK_MENU
      case 'shift': return 0x10;  // VK_SHIFT
      case 'meta':
      case 'win': return 0x5B;    // VK_LWIN
      case 'arrowleft': return 0x25; // VK_LEFT
      case 'arrowright': return 0x27; // VK_RIGHT
      case 'arrowup': return 0x26;   // VK_UP
      case 'arrowdown': return 0x28; // VK_DOWN
      default:
        if (key.isNotEmpty) {
          return key.toUpperCase().codeUnitAt(0);
        }
        return 0;
    }
  }
}
