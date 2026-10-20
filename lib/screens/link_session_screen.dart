import 'package:flutter/material.dart';

import 'support_operator_screen.dart';

/// Screen adapter forwarding to the unified [SupportOperatorScreen].
/// Unifies Ligament Link and Console SOS into a single battle-tested operator console.
class LinkSessionScreen extends StatelessWidget {
  final String agentId;
  final String hostname;
  final String accessMode;
  final Map<String, dynamic>? hostData;

  const LinkSessionScreen({
    super.key,
    required this.agentId,
    required this.hostname,
    required this.accessMode,
    this.hostData,
  });

  @override
  Widget build(BuildContext context) {
    return SupportOperatorScreen(
      sessionId: 'link_$agentId',
      isLink: true,
      linkAgentId: agentId,
      linkAccessMode: accessMode,
      ownerMode: true,
      sessionData: {
        'id': 'link_$agentId',
        'agent_id': agentId,
        'hostname': hostname,
        'employee_name': hostname,
        'access_mode': accessMode,
        'is_link': true,
        if (hostData != null) ...hostData!,
      },
    );
  }
}
