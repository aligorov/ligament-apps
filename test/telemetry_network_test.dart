import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/services/telemetry_service.dart';
import 'package:ligament_authenticator/api/client.dart';

void main() {
  test('TelemetryService.collectNetworkInfo collects local IP and hostname', () async {
    final netInfo = await TelemetryService.collectNetworkInfo();
    expect(netInfo['hostname'], equals(Platform.localHostname));
    if (TelemetryService.cachedInternalIPs.isNotEmpty) {
      expect(netInfo['internal_ip'], equals(TelemetryService.cachedInternalIPs.first));
      expect(netInfo['internal_ips'], isNotEmpty);
      expect(ApiClient.clientInternalIP, equals(TelemetryService.cachedInternalIPs.first));
    }
  });
}
