import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

enum RdpEndpointServiceStatus {
  running,
  stopped,
  notInstalled,
  unsupported,
  unknown,
}

enum RdpEndpointConfigResult {
  success,
  unsupported,
  invalidKey,
  invalidServerUrl,
  serviceNotInstalled,
  serviceDisabled,
  serviceStartFailed,
  registryWriteFailed,
  permissionDenied,
  timedOut,
  failed,
}

typedef EndpointProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  String? input,
  Duration timeout,
);
typedef EndpointRegistryReader = Object? Function(String path, String name);

/// Configures the independently running Windows endpoint service.
class RdpEndpointConfigService {
  RdpEndpointConfigService({
    EndpointProcessRunner? processRunner,
    EndpointRegistryReader? registryReader,
    String? powershellPath,
  })  : _processRunner = processRunner ?? _runProcess,
        _registryReader = registryReader ?? _readRegistry64,
        _powershellPath = powershellPath;

  static const _registrySubkey = r'SOFTWARE\Ligament\2FA';
  static const _registryPoliciesSubkey = r'SOFTWARE\Policies\Ligament\2FA';
  static final _agentKeyPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  final EndpointProcessRunner _processRunner;
  final EndpointRegistryReader _registryReader;
  final String? _powershellPath;

  bool get isWindows => !kIsWeb && Platform.isWindows;
  String get localHostname => kIsWeb ? 'WebClient' : Platform.localHostname;

  // The native service reads the 64-bit registry and applies Policies per value.
  static Object? _readRegistry64(String path, String name) {
    final subkey = path.toNativeUtf16();
    final handle = calloc<IntPtr>();
    RegistryKey? key;
    try {
      if (RegOpenKeyEx(HKEY_LOCAL_MACHINE, subkey, 0,
              KEY_READ | KEY_WOW64_64KEY, handle) !=
          0) {
        return null;
      }
      key = RegistryKey(handle.value);
      final value = key.getValue(name);
      return value?.type == RegistryValueType.string ||
              value?.type == RegistryValueType.int32
          ? value?.data
          : null;
    } finally {
      key?.close();
      calloc.free(handle);
      calloc.free(subkey);
    }
  }

  Object? _effectiveValue(String name) {
    final integer = name == 'RdpAgentEnabled' || name == 'AllowHttp';
    for (final path in [_registryPoliciesSubkey, _registrySubkey]) {
      try {
        final value = _registryReader(path, name);
        if ((integer && value is int) || (!integer && value is String)) {
          return value;
        }
      } catch (_) {/* A missing value may fall back to the local key. */}
    }
    return null;
  }

  bool _validServerUrl(String value) {
    final url = Uri.tryParse(value);
    return value.length < 1024 &&
        !value.contains(RegExp(r'[\x00-\x20\x7f]')) &&
        url != null &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        !url.hasQuery &&
        !url.hasFragment &&
        (url.scheme == 'https' ||
            (url.scheme == 'http' &&
                _effectiveValue('AllowHttp') is int &&
                _effectiveValue('AllowHttp') != 0));
  }

  bool isAgentConfigured() {
    if (!isWindows) return false;
    final enabled = _effectiveValue('RdpAgentEnabled');
    final key = _effectiveValue('RdpAgentKey');
    final url = _effectiveValue('ServerURL');
    return enabled is int &&
        enabled != 0 &&
        key is String &&
        _agentKeyPattern.hasMatch(key) &&
        url is String &&
        _validServerUrl(url);
  }

  String get _powershell {
    if (_powershellPath != null) return _powershellPath;
    final buffer = calloc<Uint16>(32768).cast<Utf16>();
    try {
      final length = GetSystemDirectory(buffer, 32768);
      if (length == 0 || length >= 32768) {
        throw const FileSystemException('Windows system directory unavailable');
      }
      return '${buffer.toDartString()}\\WindowsPowerShell\\v1.0\\powershell.exe';
    } finally {
      calloc.free(buffer);
    }
  }

  static String _encodeCommand(String script) => base64Encode([
        for (final unit in script.codeUnits) ...[unit & 255, unit >> 8],
      ]);

  Future<ProcessResult> _runPowerShell(
    String script, {
    String? input,
    Duration timeout = const Duration(seconds: 8),
  }) =>
      _processRunner(
          _powershell,
          [
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            _encodeCommand(script),
          ],
          input,
          timeout);

  static Future<ProcessResult> _runProcess(String executable,
      List<String> arguments, String? input, Duration timeout) async {
    final process = await Process.start(executable, arguments);
    const decoder = Utf8Decoder(allowMalformed: true);
    final output = process.stdout.transform(decoder).join();
    final errors = process.stderr.transform(decoder).join();
    try {
      return await (() async {
        if (input != null) process.stdin.write(input);
        await process.stdin.close();
        final code = await process.exitCode;
        return ProcessResult(process.pid, code, await output, await errors);
      })()
          .timeout(timeout);
    } on TimeoutException {
      process.kill();
      rethrow;
    } finally {
      // Drain both pipes even if the process times out; never log their content.
      unawaited(output.then<void>((_) {}, onError: (Object _) {}));
      unawaited(errors.then<void>((_) {}, onError: (Object _) {}));
    }
  }

  Future<RdpEndpointServiceStatus> getServiceStatus() async {
    if (!isWindows) return RdpEndpointServiceStatus.unsupported;
    try {
      final result = await _runPowerShell(r'''
$s = Get-Service -Name 'LigamentEndpointService' -ErrorAction SilentlyContinue
if ($null -eq $s) { exit 20 }
if ($s.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) { exit 0 }
exit 1
''');
      return switch (result.exitCode) {
        0 => RdpEndpointServiceStatus.running,
        1 => RdpEndpointServiceStatus.stopped,
        20 => RdpEndpointServiceStatus.notInstalled,
        _ => RdpEndpointServiceStatus.unknown,
      };
    } catch (_) {
      return RdpEndpointServiceStatus.unknown;
    }
  }

  Future<bool> isProcessElevated() async {
    if (!isWindows) return false;
    try {
      return (await _runPowerShell(r'''
$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 }
exit 1
''')).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> configureEndpointService(
          {required String agentKey, String? serverUrl}) async =>
      await configure(agentKey: agentKey, serverUrl: serverUrl) ==
      RdpEndpointConfigResult.success;

  Future<RdpEndpointConfigResult> configure(
      {required String agentKey, String? serverUrl}) async {
    if (!isWindows) return RdpEndpointConfigResult.unsupported;
    final key = agentKey.trim();
    // RdpEndpointUpsert issues a UUID bearer secret, not "endpoint:hex".
    if (!_agentKeyPattern.hasMatch(key)) {
      return RdpEndpointConfigResult.invalidKey;
    }
    final url =
        (serverUrl ?? _effectiveValue('ServerURL') as String? ?? '').trim();
    if (!_validServerUrl(url)) return RdpEndpointConfigResult.invalidServerUrl;

    final random = Random.secure();
    final suffix = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final folder =
        Directory('${Directory.systemTemp.path}\\ligament_config_$suffix');
    final configPath = '${folder.path}\\config.json';
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final apply = '\$cfgPath = ${quote(configPath)}\n$_applyScript';
    final applyEncoded = _encodeCommand(apply);
    final bootstrap = '''
\$ErrorActionPreference = 'Stop'
\$folder = ${quote(folder.path)}
\$cfgPath = ${quote(configPath)}
\$code = 30
try {
  # Create with a protected ACL BEFORE writing the bearer secret.
  if ([IO.Directory]::Exists(\$folder)) { exit 30 }
  \$acl = New-Object Security.AccessControl.DirectorySecurity
  \$acl.SetAccessRuleProtection(\$true, \$false)
  \$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  foreach (\$id in @(\$sid, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
    \$rule = New-Object Security.AccessControl.FileSystemAccessRule(\$id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    \$acl.AddAccessRule(\$rule)
  }
  [IO.Directory]::CreateDirectory(\$folder, \$acl) | Out-Null
  \$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd()))
  [IO.File]::WriteAllText(\$cfgPath, \$json, (New-Object Text.UTF8Encoding(\$false)))
  \$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  \$ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\\v1.0\\powershell.exe'
  \$childArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $applyEncoded'
  if (\$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    \$p = Start-Process -FilePath \$ps -ArgumentList \$childArguments -Wait -PassThru -WindowStyle Hidden
  } else {
    \$p = Start-Process -FilePath \$ps -Verb RunAs -ArgumentList \$childArguments -Wait -PassThru -WindowStyle Hidden
  }
  \$p.WaitForExit()
  if (\$null -eq \$p.ExitCode) { \$code = 30 } else { \$code = [int]\$p.ExitCode }
} catch {
  \$code = 30
  if (\$_.Exception.NativeErrorCode -in @(5,1223) -or \$_.Exception.InnerException.NativeErrorCode -in @(5,1223)) { \$code = 24 }
} finally {
  Remove-Item -LiteralPath \$folder -Recurse -Force -ErrorAction SilentlyContinue
}
exit \$code
''';
    try {
      final result = await _runPowerShell(bootstrap,
          input: base64Encode(
              utf8.encode(jsonEncode({'key': key, 'serverUrl': url}))),
          timeout: const Duration(seconds: 120));
      return switch (result.exitCode) {
        0 => RdpEndpointConfigResult.success,
        20 => RdpEndpointConfigResult.serviceNotInstalled,
        21 => RdpEndpointConfigResult.serviceDisabled,
        22 => RdpEndpointConfigResult.serviceStartFailed,
        23 => RdpEndpointConfigResult.registryWriteFailed,
        24 => RdpEndpointConfigResult.permissionDenied,
        _ => RdpEndpointConfigResult.failed,
      };
    } on TimeoutException {
      return RdpEndpointConfigResult.timedOut;
    } catch (_) {
      return RdpEndpointConfigResult.failed;
    } finally {
      // Also cover a killed bootstrap or a UAC dialog answered after timeout.
      try {
        if (await folder.exists()) await folder.delete(recursive: true);
      } catch (_) {/* The elevated child also removes its secret in finally. */}
    }
  }

  static const _applyScript = r'''
$ErrorActionPreference = 'Stop'
$code = 23
$base = $null
try {
  $data = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
  if ($data.key -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { exit 23 }
  $service = Get-Service -Name 'LigamentEndpointService' -ErrorAction SilentlyContinue
  if ($null -eq $service) { exit 20 }
  if ($service.StartType -eq 'Disabled') { exit 21 }
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
  foreach ($path in @('SOFTWARE\Ligament\2FA', 'SOFTWARE\Policies\Ligament\2FA')) {
    $reg = $base.CreateSubKey($path)
    try {
      $reg.SetValue('RdpAgentKey', [string]$data.key, [Microsoft.Win32.RegistryValueKind]::String)
      $reg.SetValue('ServerURL', [string]$data.serverUrl, [Microsoft.Win32.RegistryValueKind]::String)
      $reg.SetValue('RdpAgentEnabled', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
      if ($reg.GetValue('RdpAgentKey') -cne $data.key -or $reg.GetValue('ServerURL') -cne $data.serverUrl -or $reg.GetValue('RdpAgentEnabled') -ne 1) { throw 'Registry verification failed' }
    } finally { $reg.Dispose() }
  }
  $code = 22
  if ($service.Status -ne 'Stopped') {
    Stop-Service -Name 'LigamentEndpointService' -ErrorAction Stop
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
  }
  Start-Service -Name 'LigamentEndpointService' -ErrorAction Stop
  $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
  $code = 0
} catch {
  if ($_.Exception -is [UnauthorizedAccessException] -or $_.Exception -is [Security.SecurityException]) { $code = 24 }
} finally {
  if ($null -ne $base) { $base.Dispose() }
  Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
}
exit $code
''';
}
