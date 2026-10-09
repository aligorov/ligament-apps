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

  /// Проверка, настроен ли агент в реестре HKLM
  bool isAgentConfigured() {
    if (!isWindows) return false;
    try {
      final key = Registry.openPath(RegistryHive.localMachine, path: _registrySubkey);
      final enabled = key.getValueAsInt('RdpAgentEnabled');
      final agentKey = key.getValueAsString('RdpAgentKey');
      key.close();
      return enabled == 1 && agentKey != null && agentKey.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Настройка agent_key через привилегированный запуск (UAC RunAs).
  /// Записывает ServerURL, RdpAgentKey, RdpAgentEnabled=1 в HKLM\SOFTWARE\Ligament\2FA
  /// и запускает/перезапускает службу LigamentEndpointService.
  /// Ключ передаётся строго в процесс и очищается вызывающей стороной.
  Future<bool> configureEndpointService({
    required String agentKey,
    String? serverUrl,
  }) async {
    if (!isWindows) return false;
    final trimmedKey = agentKey.trim();
    if (trimmedKey.isEmpty) return false;

    // Защита от инъекций спецсимволов командной строки
    if (trimmedKey.contains('"') ||
        trimmedKey.contains("'") ||
        trimmedKey.contains('\n') ||
        trimmedKey.contains('\r') ||
        trimmedKey.contains(';')) {
      return false;
    }

    try {
      final commands = <String>[];
      commands.add('New-Item -Path "HKLM:\\SOFTWARE\\Ligament\\2FA" -Force | Out-Null');
      commands.add('Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Ligament\\2FA" -Name "RdpAgentKey" -Value "$trimmedKey" -Type String');
      commands.add('Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Ligament\\2FA" -Name "RdpAgentEnabled" -Value 1 -Type DWord');
      if (serverUrl != null && serverUrl.isNotEmpty) {
        final sanitizedUrl = serverUrl.replaceAll('"', '').replaceAll("'", '').replaceAll(';', '');
        commands.add('Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Ligament\\2FA" -Name "ServerURL" -Value "$sanitizedUrl" -Type String');
      }
      // Запуск/перезапуск службы
      commands.add('if (Get-Service "$_serviceName" -ErrorAction SilentlyContinue) { Restart-Service "$_serviceName" -ErrorAction SilentlyContinue }');

      final scriptBlock = commands.join('; ');
      final proc = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList \'-NoProfile -NonInteractive -Command "$scriptBlock"\'',
        ],
      ).timeout(const Duration(seconds: 30));

      return proc.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
