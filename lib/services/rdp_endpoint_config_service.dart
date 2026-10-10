import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// Статус локальной службы хоста RDP (LigamentEndpointService)
enum RdpEndpointServiceStatus {
  running,
  stopped,
  notInstalled,
  unsupported,
  unknown,
}

/// Сервис управления локальной RDP-службой на целевом ПК (§8 плана ремедиации).
class RdpEndpointConfigService {
  static const String _registrySubkey = r'SOFTWARE\Ligament\2FA';
  static const String _serviceName = 'LigamentEndpointService';

  static const String _registryPoliciesSubkey = r'SOFTWARE\Policies\Ligament\2FA';

  bool get isWindows => !kIsWeb && Platform.isWindows;

  /// Имя текущей машины
  String get localHostname => kIsWeb ? 'WebClient' : Platform.localHostname;

  /// Проверка текущего статуса службы Windows LigamentEndpointService
  Future<RdpEndpointServiceStatus> getServiceStatus() async {
    if (!isWindows) return RdpEndpointServiceStatus.unsupported;
    try {
      final res = await Process.run('sc', ['query', _serviceName])
          .timeout(const Duration(seconds: 4));
      final out = res.stdout.toString().toUpperCase();
      if (out.contains('RUNNING')) {
        return RdpEndpointServiceStatus.running;
      } else if (out.contains('STOPPED')) {
        return RdpEndpointServiceStatus.stopped;
      } else if (out.contains('1060') || out.contains('FAILED 1060')) {
        return RdpEndpointServiceStatus.notInstalled;
      }
      return RdpEndpointServiceStatus.unknown;
    } catch (_) {
      return RdpEndpointServiceStatus.unknown;
    }
  }

  /// Проверка, настроен ли агент в реестре HKLM (Policies или SOFTWARE)
  bool isAgentConfigured() {
    if (!isWindows) return false;
    for (final path in [_registryPoliciesSubkey, _registrySubkey]) {
      try {
        final key = Registry.openPath(RegistryHive.localMachine, path: path);
        final enabled = key.getValueAsInt('RdpAgentEnabled');
        final agentKey = key.getValueAsString('RdpAgentKey');
        key.close();
        if (enabled == 1 && agentKey != null && agentKey.isNotEmpty) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Текущий процесс уже повышен (high integrity / роль Administrator)?
  /// Под elevated-процессом RunAs-оркестрация не нужна (инцидент
  /// 2026-10-10 «agent_key не добавляется под администратором»).
  Future<bool> isProcessElevated() async {
    if (!isWindows) return false;
    try {
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[bool](([System.Security.Principal.WindowsPrincipal]'
            '[System.Security.Principal.WindowsIdentity]::GetCurrent())'
            '.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))',
      ]).timeout(const Duration(seconds: 6));
      return res.exitCode == 0 &&
          res.stdout.toString().trim().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Настройка agent_key через привилегированный запуск (UAC RunAs).
  /// Записывает ServerURL, RdpAgentKey, RdpAgentEnabled=1 в HKLM\SOFTWARE\Ligament\2FA
  /// и HKLM\SOFTWARE\Policies\Ligament\2FA (резервный ключ против затирания MSI),
  /// и запускает/перезапускает службу LigamentEndpointService.
  /// Ключ передаётся через временный файл JSON и НЕ светится в argv (A-08, A-09).
  Future<bool> configureEndpointService({
    required String agentKey,
    String? serverUrl,
  }) async {
    if (!isWindows) return false;
    final trimmedKey = agentKey.trim();
    if (trimmedKey.isEmpty) return false;

    // A-09 (аудит 2026-10-10): строгая валидация формата ключа и URL без интерполяции
    final keyRegExp = RegExp(r'^[0-9a-fA-F\-]{36}:[0-9a-fA-F]{32,128}$');
    if (!keyRegExp.hasMatch(trimmedKey)) {
      debugPrint('rdp_endpoint_config_service: неверный формат agentKey');
      return false;
    }

    String? validServerUrl;
    if (serverUrl != null && serverUrl.trim().isNotEmpty) {
      final u = Uri.tryParse(serverUrl.trim());
      if (u == null || !u.hasScheme || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) {
        debugPrint('rdp_endpoint_config_service: неверный формат serverUrl');
        return false;
      }
      validServerUrl = u.toString();
    }

    // A-08 / A-09 / A-10: Передача параметров через временный файл JSON, а не argv.
    // Секрет не светится в журнале процессов или WMI Win32_Process.
    // -PassThru гарантирует передачу реального ExitCode дочернего процесса.
    final tempDir = Directory.systemTemp;
    final randomSuffix = '${DateTime.now().microsecondsSinceEpoch}_$pid';
    final tempCfgFile = File('${tempDir.path}\\ligament_cfg_$randomSuffix.json');
    final tempScriptFile = File('${tempDir.path}\\ligament_apply_$randomSuffix.ps1');

    try {
      final payload = jsonEncode({
        'key': trimmedKey,
        'serverUrl': validServerUrl ?? '',
      });
      await tempCfgFile.writeAsString(payload, flush: true);

      final psCode = '''
\$ErrorActionPreference = 'Stop'
\$cfgPath = '${tempCfgFile.path.replaceAll("'", "''")}'
if (-not (Test-Path -LiteralPath \$cfgPath)) { exit 2 }
try {
  \$data = Get-Content -LiteralPath \$cfgPath -Raw | ConvertFrom-Json
  Remove-Item -LiteralPath \$cfgPath -Force -ErrorAction SilentlyContinue
  foreach (\$root in @('HKLM:\\SOFTWARE\\Ligament\\2FA', 'HKLM:\\SOFTWARE\\Policies\\Ligament\\2FA')) {
    if (-not (Test-Path -LiteralPath \$root)) {
      New-Item -Path \$root -Force | Out-Null
    }
    Set-ItemProperty -Path \$root -Name 'RdpAgentKey' -Value \$data.key -Type String
    Set-ItemProperty -Path \$root -Name 'RdpAgentEnabled' -Value 1 -Type DWord
    if (\$data.serverUrl -and \$data.serverUrl.Length -gt 0) {
      Set-ItemProperty -Path \$root -Name 'ServerURL' -Value \$data.serverUrl -Type String
    }
  }
  # Ключи записаны — это успех. Перезапуск службы — best-effort: сбой
  # перезапуска (служба отключена/занята) не должен ронять конфигурацию
  # и показывать юзеру ложное «требуются права администратора».
  if (Get-Service -Name '$_serviceName' -ErrorAction SilentlyContinue) {
    try {
      if ((Get-Service -Name '$_serviceName').Status -ne 'Running') {
        Start-Service -Name '$_serviceName' -ErrorAction SilentlyContinue
      } else {
        Restart-Service -Name '$_serviceName' -ErrorAction SilentlyContinue
      }
    } catch { }
  }
  exit 0
} catch {
  exit 1
}
''';
      await tempScriptFile.writeAsString(psCode, flush: true);

      // Инцидент 2026-10-10 «не могу добавить agent_key под администратором»:
      // если процесс УЖЕ elevated — RunAs-оркестрация не нужна и вредна
      // (UAC-промпт/таймаут/PassThru-код). Пишем скрипт напрямую.
      final elevated = await isProcessElevated();
      debugPrint('rdp_endpoint_config_service: elevated=$elevated');
      ProcessResult proc;
      if (elevated) {
        proc = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            tempScriptFile.path,
          ],
        ).timeout(const Duration(seconds: 30));
      } else {
        // UAC-промпт может ждать юзера — таймаут 120с, не 35
        // (при таймауте finally удалял cfg-файл до прочтения дочерним
        // процессом — гарантированный exit 2).
        proc = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            'Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList \'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${tempScriptFile.path.replaceAll('"', '`"')'}\' | ForEach-Object { exit \$_.ExitCode }',
          ],
        ).timeout(const Duration(seconds: 120));
      }
      debugPrint('rdp_endpoint_config_service: exitCode=${proc.exitCode} '
          'stdout=${(proc.stdout ?? '').toString().trim().isNotEmpty ? "<есть>" : "<пусто>"} '
          'stderr=${(proc.stderr ?? '').toString().trim()}');
      return proc.exitCode == 0;
    } catch (e) {
      debugPrint('rdp_endpoint_config_service: ошибка настройки: $e');
      return false;
    } finally {
      if (await tempCfgFile.exists()) {
        try {
          await tempCfgFile.delete();
        } catch (_) {}
      }
      if (await tempScriptFile.exists()) {
        try {
          await tempScriptFile.delete();
        } catch (_) {}
      }
    }
  }
}
