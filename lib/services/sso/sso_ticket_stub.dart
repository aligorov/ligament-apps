// Заглушка для не-io платформ (web): билетов не бывает.
import 'sso_ticket.dart';

SsoTicketReader createSsoTicketReader() => const _NoopSsoTicketReader();

class _NoopSsoTicketReader implements SsoTicketReader {
  const _NoopSsoTicketReader();

  @override
  Future<SsoTicket?> readTicket() async => null;
}
