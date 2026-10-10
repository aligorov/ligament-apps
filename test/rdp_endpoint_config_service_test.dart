import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/rdp_endpoint_config_service.dart';

const _key = 'b394d946-d3b0-4b8e-84f4-c1d1df89e1bf';
const _local = r'SOFTWARE\Ligament\2FA';
const _policy = r'SOFTWARE\Policies\Ligament\2FA';

class _WindowsConfig extends RdpEndpointConfigService {
  _WindowsConfig({super.processRunner, super.registryReader})
      : super(
            powershellPath:
                r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
  @override
  bool get isWindows => true;
}

void main() {
  test('accepts the server UUID; the secret is passed only through stdin',
      () async {
    var calls = 0;
    final service =
        _WindowsConfig(processRunner: (exe, args, input, timeout) async {
      calls++;
      expect(exe, contains('System32'));
      expect(jsonDecode(utf8.decode(base64Decode(input!))),
          {'key': _key, 'serverUrl': 'https://auth.example.com'});
      expect(args.join(' '), isNot(contains(_key)));
      expect(args.last.length, lessThan(30000));
      final bytes = base64Decode(args.last);
      final script = String.fromCharCodes([
        for (var i = 0; i < bytes.length; i += 2)
          bytes[i] | (bytes[i + 1] << 8),
      ]);
      expect(script, isNot(contains(_key)));
      expect(script.indexOf('CreateDirectory'),
          lessThan(script.indexOf('WriteAllText')));
      expect(timeout, const Duration(seconds: 120));
      return ProcessResult(1, 0, '', '');
    });
    expect(
        await service.configure(
            agentKey: ' $_key ', serverUrl: 'https://auth.example.com'),
        RdpEndpointConfigResult.success);
    expect(calls, 1);
  });

  test('invalid keys and URLs never request elevation', () async {
    final service = _WindowsConfig(
        processRunner: (_, __, ___, ____) async =>
            throw StateError('must not run'));
    expect(
        await service.configure(
            agentKey: '$_key:abcdef', serverUrl: 'https://host'),
        RdpEndpointConfigResult.invalidKey);
    for (final url in [
      'http://host',
      'file:///C:/host',
      'https://user:secret@host',
      'https://host?token=x',
      ''
    ]) {
      expect(await service.configure(agentKey: _key, serverUrl: url),
          RdpEndpointConfigResult.invalidServerUrl);
    }
  });

  test('each elevation/service failure remains an error', () async {
    const results = {
      20: RdpEndpointConfigResult.serviceNotInstalled,
      21: RdpEndpointConfigResult.serviceDisabled,
      22: RdpEndpointConfigResult.serviceStartFailed,
      23: RdpEndpointConfigResult.registryWriteFailed,
      24: RdpEndpointConfigResult.permissionDenied,
      30: RdpEndpointConfigResult.failed,
    };
    for (final entry in results.entries) {
      final service = _WindowsConfig(
          processRunner: (_, __, ___, ____) async =>
              ProcessResult(1, entry.key, '', ''));
      expect(await service.configure(agentKey: _key, serverUrl: 'https://host'),
          entry.value);
      expect(
          await service.configureEndpointService(
              agentKey: _key, serverUrl: 'https://host'),
          isFalse);
    }
    final service = _WindowsConfig(
        processRunner: (_, __, ___, ____) async =>
            throw TimeoutException('UAC'));
    expect(await service.configure(agentKey: _key, serverUrl: 'https://host'),
        RdpEndpointConfigResult.timedOut);
  });

  test('configuration follows native per-value Policies precedence', () {
    final values = <String, Object>{
      '$_policy/RdpAgentEnabled': 1,
      '$_local/RdpAgentKey': _key,
      '$_local/ServerURL': 'https://host',
    };
    final service =
        _WindowsConfig(registryReader: (path, name) => values['$path/$name']);
    expect(service.isAgentConfigured(), isTrue);
    values['$_policy/RdpAgentEnabled'] = 0;
    values['$_local/RdpAgentEnabled'] = 1;
    expect(service.isAgentConfigured(), isFalse);
    values['$_policy/RdpAgentEnabled'] = 1;
    values['$_policy/RdpAgentKey'] =
        ''; // Empty policy value also overrides local.
    expect(service.isAgentConfigured(), isFalse);
    values['$_policy/RdpAgentKey'] = 123; // Wrong native type falls back.
    expect(service.isAgentConfigured(), isTrue);
    values.remove('$_local/ServerURL');
    expect(service.isAgentConfigured(), isFalse);
  });

  test('HTTP requires the existing explicit policy, never enables it',
      () async {
    final service = _WindowsConfig(
      registryReader: (_, name) => name == 'AllowHttp' ? 1 : null,
      processRunner: (_, __, ___, ____) async => ProcessResult(1, 0, '', ''),
    );
    expect(await service.configure(agentKey: _key, serverUrl: 'http://host'),
        RdpEndpointConfigResult.success);
  });

  test('status uses exit codes independent of Windows display language',
      () async {
    for (final entry in {
      0: RdpEndpointServiceStatus.running,
      1: RdpEndpointServiceStatus.stopped,
      20: RdpEndpointServiceStatus.notInstalled,
      7: RdpEndpointServiceStatus.unknown,
    }.entries) {
      final service = _WindowsConfig(
          processRunner: (_, __, ___, ____) async =>
              ProcessResult(1, entry.key, 'локализованный вывод', ''));
      expect(await service.getServiceStatus(), entry.value);
    }
  });
}
