import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'gpo_service.dart';
import 'web_platform.dart';
import 'windows_identity.dart';
import '../api/client.dart';

/// Сигнатура kernel32!GetDiskFreeSpaceExW (public — для тестов Windows-веток).
typedef WinGetDiskFreeSpaceExWFn = int Function(
  ffi.Pointer<Utf16> lpDirectoryName,
  ffi.Pointer<ffi.Uint64> lpFreeBytesAvailableToCaller,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfBytes,
  ffi.Pointer<ffi.Uint64> lpTotalNumberOfFreeBytes,
);

/// Сигнатура kernel32!GetSystemTimes (public — для тестов Windows-веток).
typedef WinGetSystemTimesFn = int Function(
  ffi.Pointer<ffi.Uint64> lpIdleTime,
  ffi.Pointer<ffi.Uint64> lpKernelTime,
  ffi.Pointer<ffi.Uint64> lpUserTime,
);

/// Снимок счётчиков GetSystemTimes — база дельта-расчёта загрузки CPU.
@visibleForTesting
class WinCpuCounters {
  final int idle;
  final int kernel;
  final int user;
  const WinCpuCounters(this.idle, this.kernel, this.user);
}

/// Сервис сбора телеметрии устройства и контроля соответствия политикам (GPO).
class TelemetryService {
  final GPOService _gpo = GPOService();
  final LocalAuthentication _localAuth = LocalAuthentication();

  Timer? _timer;
  int _consecutiveHighCpuCount = 0;

  // Кеширование профиля безопасности
  Map<String, dynamic>? _cachedPosture;
  DateTime? _lastPostureCheck;

  // Сетевые параметры клиента (LAN IP, интерфейсы, WAN IP)
  static List<String> cachedInternalIPs = [];
  static String? cachedHostname;
  static String? cachedExternalIP;

  /// Сбор реальных сетевых адресов устройства (LAN IP, сетевые адаптеры, имя хоста)
  static Future<Map<String, dynamic>> collectNetworkInfo() async {
    final netInfo = <String, dynamic>{};
    if (kIsWeb) return netInfo;
    try {
      cachedHostname = Platform.localHostname;
      netInfo['hostname'] = Platform.localHostname;
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final ips = <String>[];
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal && addr.address.isNotEmpty) {
            ips.add(addr.address);
          }
        }
      }
      cachedInternalIPs = ips;
      if (ips.isNotEmpty) {
        netInfo['internal_ip'] = ips.first;
        netInfo['internal_ips'] = ips;
        ApiClient.clientInternalIP = ips.first;
      }
      if (cachedHostname != null) {
        ApiClient.clientHostname = cachedHostname;
      }
    } catch (e) {
      debugPrint('telemetry_service: collectNetworkInfo error: $e');
    }
    return netInfo;
  }

  // Windows Kernel32 FFI дескрипторы для мгновенного сбора метрик без запуска
  // процессов. Могут ОСТАТЬСЯ NULL (не-Windows платформа или kernel32.dll
  // не открылась — catch в _initWinKernel32): все обращения идут через
  // nullable-параметры чистых функций ниже, БЕЗ `!`-разыменований —
  // краш-репорт входа v0.8.133 («Null check operator used on a null value»)
  // был именно на этих указателях.
  WinGetDiskFreeSpaceExWFn? _winGetDiskFreeSpaceExW;
  WinGetSystemTimesFn? _winGetSystemTimes;

  WinCpuCounters? _winPrevCpuCounters;

  TelemetryService() {
    _initWinKernel32();
  }

  void _initWinKernel32() {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      final lib = ffi.DynamicLibrary.open('kernel32.dll');
      _winGetDiskFreeSpaceExW = lib.lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<Utf16>,
            ffi.Pointer<ffi.Uint64>,
            ffi.Pointer<ffi.Uint64>,
            ffi.Pointer<ffi.Uint64>,
          ),
          WinGetDiskFreeSpaceExWFn>('GetDiskFreeSpaceExW');

      _winGetSystemTimes = lib.lookupFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Uint64>,
            ffi.Pointer<ffi.Uint64>,
            ffi.Pointer<ffi.Uint64>,
          ),
          WinGetSystemTimesFn>('GetSystemTimes');
    } catch (e) {
      // Загрузка сорвалась (экзотическое окружение) — указатели остаются
      // null, метрики деградируют до дефолтов; телеметрия НЕ роняет вход.
      debugPrint('telemetry_service: ошибка загрузки kernel32.dll: $e');
    }
  }

  /// Запуск периодического сбора и отправки снимка телеметрии
  void startReporting(ApiClient api) {
    _timer?.cancel();
    // Первый сбор сразу
    reportTelemetry(api);

    final interval = Duration(seconds: _gpo.telemetryIntervalSeconds);
    _timer = Timer.periodic(interval, (_) => reportTelemetry(api));
  }

  void stopReporting() {
    _timer?.cancel();
    _timer = null;
  }

  /// Сбор текущего профиля безопасности устройства и телеметрии ресурсов
  Future<Map<String, dynamic>> collectPosture({bool forceRefresh = false}) async {
    final now = DateTime.now();
    // Кешируем тяжелые системные проверки безопасности (BitLocker, Defender, Firewall) на 5 минут
    final cached = _cachedPosture;
    final lastCheck = _lastPostureCheck;
    if (!forceRefresh && cached != null && lastCheck != null &&
        now.difference(lastCheck).inMinutes < 5) {
      final posture = Map<String, dynamic>.from(cached);
      posture['timestamp'] = now.toUtc().toIso8601String();
      if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        final disk = await collectDiskMetrics();
        posture.addAll(disk);
        final cpu = await collectCpuMetrics();
        posture.addAll(cpu);
      }
      return posture;
    }

    final posture = <String, dynamic>{
      'platform': _platformName(),
      'timestamp': now.toUtc().toIso8601String(),
    };

    // 0. Аттестация Windows-сессии: истинный пользователь/машина за клиентом
    // (Win32 API, не env) — мониторинг «кто где» на сервере. Не-Windows →
    // полей нет вовсе.
    final winIdentity = WindowsIdentity.snapshot();
    if (winIdentity != null) {
      posture.addAll(winIdentity);
    }

    // 0b. Сетевые адреса устройства (LAN IP, адаптеры, имя хоста)
    final netInfo = await collectNetworkInfo();
    posture.addAll(netInfo);

    // 1. Биометрия
    try {
      final canAuth = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      posture['biometrics_enrolled'] = canAuth || isDeviceSupported;
    } catch (_) {
      posture['biometrics_enrolled'] = false;
    }

    // 2. Специфика Windows: BitLocker, Defender, Firewall, GPO
    if (!kIsWeb && Platform.isWindows) {
      posture['bitlocker'] = await _checkWindowsBitLocker();
      posture['defender'] = await _checkWindowsDefender();
      posture['firewall'] = await _checkWindowsFirewall();

      posture['policy_require_bitlocker'] = _gpo.requireBitLocker;
      posture['policy_require_antivirus'] = _gpo.requireAntivirus;
      posture['policy_require_firewall'] = _gpo.requireFirewall;
      posture['policy_require_hello'] = _gpo.requireWindowsHello;
    }

    // 2b. Специфика macOS: FileVault, Gatekeeper, Firewall, Touch ID (без чуждых терминов Windows)
    if (!kIsWeb && Platform.isMacOS) {
      final fv = await _checkMacOSFileVault();
      posture['filevault'] = fv;
      final gk = await _checkMacOSGatekeeper();
      posture['gatekeeper'] = gk;
      posture['firewall'] = await _checkMacOSFirewall();
      posture['touch_id'] = posture['biometrics_enrolled'] == true;

      posture['policy_require_bitlocker'] = _gpo.requireBitLocker;
      posture['policy_require_antivirus'] = _gpo.requireAntivirus;
      posture['policy_require_firewall'] = _gpo.requireFirewall;
      posture['policy_require_hello'] = _gpo.requireWindowsHello;
    }

    // 3. Специфика Android / iOS: Root & Jailbreak обнаружение
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      posture['rooted'] = await _checkRootOrJailbreak();
      posture['jailbroken'] = posture['rooted'];
    }

    // 4. Метрики диска и нагрузки CPU
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      final disk = await collectDiskMetrics();
      posture.addAll(disk);

      final cpu = await collectCpuMetrics();
      posture.addAll(cpu);
    }

    // 5. Оценка общего соответствия (is_compliant)
    bool compliant = true;
    if (posture['rooted'] == true || posture['jailbroken'] == true) {
      compliant = false;
    }
    if (_gpo.requireBitLocker) {
      if (!kIsWeb && Platform.isMacOS) {
        if (posture['filevault'] != 'encrypted') compliant = false;
      } else {
        if (posture['bitlocker'] != 'encrypted') compliant = false;
      }
    }
    if (_gpo.requireAntivirus) {
      if (!kIsWeb && Platform.isMacOS) {
        if (posture['gatekeeper'] != 'active') compliant = false;
      } else {
        if (posture['defender'] != 'active') compliant = false;
      }
    }
    if (_gpo.requireFirewall && posture['firewall'] != 'active') {
      compliant = false;
    }
    if (_gpo.requireWindowsHello && posture['biometrics_enrolled'] != true) {
      compliant = false;
    }

    posture['is_compliant'] = compliant;
    _cachedPosture = Map<String, dynamic>.from(posture);
    _lastPostureCheck = now;
    return posture;
  }

  /// Отправка телеметрии на сервер Ligament
  Future<bool> reportTelemetry(ApiClient api) async {
    if (!_gpo.collectTelemetry) return true;
    try {
      final start = DateTime.now();
      final posture = await collectPosture();
      posture['latency_ms'] = DateTime.now().difference(start).inMilliseconds;

      // Определение внешнего IP через бэкенд
      if (cachedExternalIP == null) {
        try {
          final myIpData = await api.getMyIP();
          if (myIpData['ip'] != null && myIpData['ip'].toString().isNotEmpty) {
            cachedExternalIP = myIpData['ip'].toString();
          }
        } catch (_) {}
      }
      if (cachedExternalIP != null) {
        posture['external_ip'] = cachedExternalIP;
      }

      final isCompliant = await api.sendTelemetry(posture);
      return isCompliant;
    } catch (e) {
      debugPrint('telemetry_service: ошибка отправки: $e');
      return false;
    }
  }

  /// Сбор метрик дискового пространства (Win32 FFI без накладных расходов)
  Future<Map<String, dynamic>> collectDiskMetrics() async {
    final metrics = <String, dynamic>{
      'disk_percent': 0,
      'disk_free_gb': 0,
      'disk_total_gb': 0,
      'disk_warning': false,
      'disk_details': '',
    };

    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final res = await Process.run('df', ['-k', '/']).timeout(
          const Duration(seconds: 2),
          onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
        );
        if (res.exitCode == 0) {
          final lines = res.stdout.toString().trim().split('\n');
          if (lines.length >= 2) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 5) {
              final totalKb = int.tryParse(parts[1]) ?? 0;
              final freeKb = int.tryParse(parts[3]) ?? 0;
              final capStr = parts[4].replaceAll('%', '');
              final usedPercent = int.tryParse(capStr) ?? 0;

              final totalGb = (totalKb / (1024 * 1024)).round();
              final freeGb = (freeKb / (1024 * 1024)).round();

              metrics['disk_percent'] = usedPercent;
              metrics['disk_free_gb'] = freeGb;
              metrics['disk_total_gb'] = totalGb;
              metrics['disk_details'] = '$freeGb ГБ свободно из $totalGb ГБ ($usedPercent% занято)';
              metrics['disk_warning'] = usedPercent >= 90 || (freeGb < 10 && totalGb > 0);
            }
          }
        }
      } else if (Platform.isWindows) {
        // FFI-указатель может быть null (kernel32 не загрузился) — чистая
        // функция сама вернёт дефолтные метрики, без `!`-разыменований.
        return windowsDiskMetrics(_winGetDiskFreeSpaceExW);
      }
    } catch (e) {
      debugPrint('telemetry_service: ошибка сбора диска: $e');
    }

    return metrics;
  }

  /// Windows-метрики диска через GetDiskFreeSpaceExW — чистая функция от
  /// nullable FFI-указателя (тестируется без Windows: null → дефолт).
  @visibleForTesting
  static Map<String, dynamic> windowsDiskMetrics(
      WinGetDiskFreeSpaceExWFn? getDiskFreeSpaceExW) {
    final metrics = <String, dynamic>{
      'disk_percent': 0,
      'disk_free_gb': 0,
      'disk_total_gb': 0,
      'disk_warning': false,
      'disk_details': '',
    };
    final fn = getDiskFreeSpaceExW;
    if (fn == null) return metrics; // ранний return с дефолтными метриками

    final dirPtr = 'C:\\'.toNativeUtf16();
    final freeCallerPtr = calloc<ffi.Uint64>();
    final totalBytesPtr = calloc<ffi.Uint64>();
    final totalFreeBytesPtr = calloc<ffi.Uint64>();
    try {
      final ok = fn(dirPtr, freeCallerPtr, totalBytesPtr, totalFreeBytesPtr);
      if (ok != 0) {
        final total = totalBytesPtr.value;
        final free = freeCallerPtr.value;
        if (total > 0) {
          final totalGb = (total / (1024 * 1024 * 1024)).round();
          final freeGb = (free / (1024 * 1024 * 1024)).round();
          final usedGb = totalGb - freeGb;
          final usedPercent = (usedGb / totalGb * 100).round();

          metrics['disk_percent'] = usedPercent;
          metrics['disk_free_gb'] = freeGb;
          metrics['disk_total_gb'] = totalGb;
          metrics['disk_details'] = '$freeGb ГБ свободно из $totalGb ГБ ($usedPercent% занято)';
          metrics['disk_warning'] = usedPercent >= 90 || freeGb < 10;
        }
      }
    } catch (e) {
      debugPrint('telemetry_service: ошибка сбора диска (FFI): $e');
    } finally {
      calloc.free(dirPtr);
      calloc.free(freeCallerPtr);
      calloc.free(totalBytesPtr);
      calloc.free(totalFreeBytesPtr);
    }
    return metrics;
  }

  /// Сбор метрик процессора (CPU) через GetSystemTimes без запуска дочерних процессов
  Future<Map<String, dynamic>> collectCpuMetrics() async {
    final metrics = <String, dynamic>{
      'cpu_percent': 0,
      'cpu_warning': false,
      'cpu_spike_100': false,
    };

    try {
      if (Platform.isMacOS) {
        final res = await Process.run('top', ['-l', '1', '-n', '0']).timeout(
          const Duration(seconds: 2),
          onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
        );
        if (res.exitCode == 0) {
          final out = res.stdout.toString();
          final match = RegExp(r'CPU usage:\s+([0-9.]+)%\s+user,\s+([0-9.]+)%\s+sys,\s+([0-9.]+)%\s+idle').firstMatch(out);
          if (match != null) {
            final idle = double.tryParse(match.group(3) ?? '') ?? 100.0;
            final usage = (100.0 - idle).clamp(0.0, 100.0).round();
            metrics['cpu_percent'] = usage;
          }
        }
      } else if (Platform.isWindows) {
        // FFI-указатель может быть null — чистая функция вернёт (null, null),
        // метрики остаются дефолтными; `!`-разыменований нет вовсе.
        final (usage, counters) =
            windowsCpuUsage(_winGetSystemTimes, _winPrevCpuCounters);
        _winPrevCpuCounters = counters ?? _winPrevCpuCounters;
        if (usage != null) {
          metrics['cpu_percent'] = usage;
        }
      } else if (Platform.isLinux) {
        final usage = await _readLinuxCpuPercent();
        if (usage != null) {
          metrics['cpu_percent'] = usage;
        } else {
          // Провал чтения/парсинга — не подставляем фиктивное число
          metrics.remove('cpu_percent');
        }
      }

      final cpu = metrics['cpu_percent'] as int?;
      if (cpu != null) {
        if (cpu >= 90) {
          _consecutiveHighCpuCount++;
        } else {
          _consecutiveHighCpuCount = 0;
        }
      }

      metrics['cpu_warning'] = cpu != null && cpu >= 90;
      metrics['cpu_spike_100'] =
          cpu != null && (cpu >= 98 || _consecutiveHighCpuCount >= 3);
    } catch (e) {
      debugPrint('telemetry_service: ошибка сбора CPU: $e');
    }

    return metrics;
  }

  /// Дельта-расчёт загрузки CPU по GetSystemTimes — чистая функция от
  /// nullable FFI-указателя (тестируется без Windows). Возвращает
  /// (usage, свежие счётчики): usage null — базы для дельты ещё нет либо
  /// вызов сорвался; счётчики null — указатель null или вызов не прошёл
  /// (предыдущую базу не трогаем).
  @visibleForTesting
  static (int?, WinCpuCounters?) windowsCpuUsage(
      WinGetSystemTimesFn? getSystemTimes, WinCpuCounters? prev) {
    final fn = getSystemTimes;
    if (fn == null) return (null, null); // ранний return — дефолтные метрики

    final idleTimePtr = calloc<ffi.Uint64>();
    final kernelTimePtr = calloc<ffi.Uint64>();
    final userTimePtr = calloc<ffi.Uint64>();
    try {
      final ok = fn(idleTimePtr, kernelTimePtr, userTimePtr);
      if (ok == 0) return (null, null);
      final cur = WinCpuCounters(idleTimePtr.value, kernelTimePtr.value, userTimePtr.value);
      final base = prev;
      if (base == null || base.idle == 0 || base.kernel == 0 || base.user == 0) {
        return (null, cur); // первый замер — только запоминаем базу
      }
      final idleDelta = cur.idle - base.idle;
      final kernelDelta = cur.kernel - base.kernel;
      final userDelta = cur.user - base.user;

      // В Windows GetSystemTimes kernelTime уже включает в себя idleTime
      final totalSys = kernelDelta + userDelta;
      if (totalSys <= 0) return (null, cur);
      final idleFraction = (idleDelta / totalSys).clamp(0.0, 1.0);
      final usage = ((1.0 - idleFraction) * 100).clamp(0.0, 100.0).round();
      return (usage, cur);
    } catch (e) {
      debugPrint('telemetry_service: ошибка сбора CPU (FFI): $e');
      return (null, null);
    } finally {
      calloc.free(idleTimePtr);
      calloc.free(kernelTimePtr);
      calloc.free(userTimePtr);
    }
  }

  /// Два замера агрегированной cpu-строки /proc/stat с интервалом 250 мс:
  /// доля занятости = 1 - idle_delta / total_delta (idle — 4-й числовой
  /// столбец, total — сумма всех столбцов). При провале чтения/парсинга
  /// возвращает null — фиктивное число не подставляется.
  Future<int?> _readLinuxCpuPercent() async {
    (int, int)? readIdleTotal() {
      try {
        final stat = File('/proc/stat').readAsStringSync();
        for (final line in stat.split('\n')) {
          if (!line.startsWith('cpu ')) continue; // только агрегированная строка
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 5) return null;
          final values = <int>[];
          for (final p in parts.skip(1)) {
            final v = int.tryParse(p);
            if (v == null) return null;
            values.add(v);
          }
          var total = 0;
          for (final v in values) {
            total += v;
          }
          return (values[3], total); // (idle, total)
        }
      } catch (_) {}
      return null;
    }

    final first = readIdleTotal();
    if (first == null) return null;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final second = readIdleTotal();
    if (second == null) return null;

    final idleDelta = second.$1 - first.$1;
    final totalDelta = second.$2 - first.$2;
    if (totalDelta <= 0) return null;
    final busyFraction = 1.0 - idleDelta / totalDelta;
    return (busyFraction * 100).clamp(0.0, 100.0).round();
  }

  String _platformName() {
    // Инцидент 2026-10-08: плоский 'web' прятал PWA-телефон от пуш-ступени
    // каскада — детектим честный web-ios/web-android по UA.
    if (kIsWeb) {
      return detectWebPlatform(webUserAgent(), maxTouchPoints: webMaxTouchPoints());
    }
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  Future<String> _checkWindowsBitLocker() async {
    try {
      final result = await Process.run('manage-bde', ['-status', 'C:']).timeout(
        const Duration(seconds: 3),
        onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
      );
      if (result.stdout.toString().contains('Percentage Encrypted:   100%') ||
          result.stdout.toString().contains('Процент зашифрованного места: 100%') ||
          result.stdout.toString().contains('Protection On') ||
          result.stdout.toString().contains('Защита включена')) {
        return 'encrypted';
      }
    } catch (_) {}
    return 'off';
  }

  Future<String> _checkWindowsDefender() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-MpComputerStatus | Select-Object -ExpandProperty RealTimeProtectionEnabled'
      ]).timeout(
        const Duration(seconds: 3),
        onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
      );
      final out = result.stdout.toString().trim();
      if (out == 'True') {
        return 'active';
      }
      if (out == 'False') {
        return 'off';
      }
    } catch (_) {}
    // Ошибка / таймаут / нераспознанный вывод — честно 'unknown',
    // чтобы серверные политики не строились на фиктивном 'active'
    // (прежний фолбэк 'active' был из-за ограниченных прав обычного юзера).
    return 'unknown';
  }

  Future<String> _checkWindowsFirewall() async {
    try {
      final result = await Process.run('netsh', ['advfirewall', 'show', 'allprofiles']).timeout(
        const Duration(seconds: 3),
        onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
      );
      final out = result.stdout.toString();
      if (out.contains('ON') || out.contains('ВКЛ')) {
        return 'active';
      }
      if (out.contains('OFF') || out.contains('ВЫКЛ')) {
        return 'off';
      }
    } catch (_) {}
    // Не распознано / ошибка / таймаут — честно 'unknown'
    return 'unknown';
  }

  Future<bool> _checkRootOrJailbreak() async {
    if (Platform.isAndroid) {
      // Проверка типовых путей su и Superuser
      final paths = [
        '/system/app/Superuser.apk',
        '/sbin/su',
        '/system/bin/su',
        '/system/xbin/su',
        '/data/local/xbin/su',
        '/data/local/bin/su',
        '/system/sd/xbin/su',
        '/system/bin/failsafe/su',
        '/data/local/su',
      ];
      for (final p in paths) {
        if (File(p).existsSync()) return true;
      }
    } else if (Platform.isIOS) {
      final paths = [
        '/Applications/Cydia.app',
        '/Library/MobileSubstrate/MobileSubstrate.dylib',
        '/bin/bash',
        '/usr/sbin/sshd',
        '/etc/apt',
      ];
      for (final p in paths) {
        if (File(p).existsSync()) return true;
      }
    }
    return false;
  }

  Future<String> _checkMacOSFileVault() async {
    try {
      final result = await Process.run('fdesetup', ['status']);
      if (result.stdout.toString().contains('FileVault is On.')) {
        return 'encrypted';
      }
    } catch (_) {}
    return 'off';
  }

  Future<String> _checkMacOSGatekeeper() async {
    try {
      final result = await Process.run('spctl', ['--status']);
      final out = result.stdout.toString();
      if (out.contains('assessments enabled')) {
        return 'active';
      }
      if (out.contains('assessments disabled')) {
        return 'off';
      }
    } catch (_) {}
    // Ошибка / нераспознанный вывод — честно 'unknown'
    return 'unknown';
  }

  Future<String> _checkMacOSFirewall() async {
    try {
      final result = await Process.run(
        '/usr/libexec/ApplicationFirewall/socketfilterfw',
        ['--getglobalstate'],
      );
      if (result.stdout.toString().contains('State = 1') ||
          result.stdout.toString().contains('Firewall is enabled')) {
        return 'active';
      }
    } catch (_) {}
    return 'off';
  }
}
