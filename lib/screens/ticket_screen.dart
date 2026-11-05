import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../services/auth_state.dart';
import '../services/ticket_service.dart';

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key});

  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthState>();
      final client = auth.api;
      if (client != null) {
        TicketService.instance.loadPresets(client);
        TicketService.instance.loadTickets(client);
      }
    });
  }

  Future<void> _handleQuickPreset(ApiClient client, String code, String title) async {
    try {
      final res = await TicketService.instance.submitQuickTicket(client, code);
      if (!mounted) return;
      final isClustered = res['clustered'] == true;
      final msg = isClustered
          ? (res['message']?.toString() ?? 'Заявка по вашей локации уже в работе!')
          : 'Заявка на «$title» успешно создана!';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: isClustered
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка отправки заявки: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final auth = context.watch<AuthState>();
    final ticketService = context.watch<TicketService>();
    final presets = ticketService.presets;
    final tickets = ticketService.tickets;
    final client = auth.api;

    final filteredTickets = tickets.where((t) {
      if (_filter == 'open') return t.status == 'open' || t.status == 'in_progress';
      if (_filter == 'completed') return t.status == 'completed' || t.status == 'closed';
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Заявки и наряды'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
            onPressed: client != null ? () => ticketService.loadTickets(client) : null,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Блок быстрых кнопок в 1 клик
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Card(
              color: colorScheme.surfaceContainerHighest,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚡ Быстрый вызов в 1 клик',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Локация и имя ПК подставятся автоматически',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (presets.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Center(child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: presets.map((p) {
                          return ActionChip(
                            avatar: Text(p.iconEmoji, style: const TextStyle(fontSize: 16)),
                            label: Text(p.title),
                            backgroundColor: colorScheme.surface,
                            onPressed: client != null
                                ? () => _handleQuickPreset(client, p.code, p.title)
                                : null,
                          );
                        }).toList(),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // 2. Вкладки фильтрации
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('Все')),
                ButtonSegment(value: 'open', label: Text('В работе')),
                ButtonSegment(value: 'completed', label: Text('Завершённые')),
              ],
              selected: {_filter},
              onSelectionChanged: (val) {
                setState(() {
                  _filter = val.first;
                });
              },
            ),
          ),
          const SizedBox(height: 8),

          // 3. Список заявок
          Expanded(
            child: ticketService.isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredTickets.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.confirmation_number_outlined, size: 48, color: colorScheme.outline),
                            const SizedBox(height: 12),
                            Text('Заявок не найдено', style: theme.textTheme.bodyLarge?.copyWith(color: colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async {
                          if (client != null) {
                            await ticketService.loadTickets(client);
                          }
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.all(12),
                          itemCount: filteredTickets.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final ticket = filteredTickets[index];
                            final isOpen = ticket.status == 'open' || ticket.status == 'in_progress';

                            return Card(
                              elevation: 0,
                              color: colorScheme.surfaceContainerLow,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(color: colorScheme.outlineVariant),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isOpen
                                      ? colorScheme.primaryContainer
                                      : colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    isOpen ? Icons.build_outlined : Icons.check_circle_outline,
                                    color: isOpen ? colorScheme.primary : colorScheme.outline,
                                  ),
                                ),
                                title: Text(
                                  '#${ticket.ticketNumber}: ${ticket.title}',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  '${ticket.locationRoom.isNotEmpty ? 'Каб. ${ticket.locationRoom} • ' : ''}${ticket.authorName}',
                                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                                ),
                                trailing: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: isOpen
                                        ? colorScheme.primary.withValues(alpha: 0.15)
                                        : colorScheme.outline.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    _statusLabel(ticket.status),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isOpen ? colorScheme.primary : colorScheme.outline,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'open':
        return 'Новая';
      case 'in_progress':
        return 'В работе';
      case 'completed':
        return 'Выполнена';
      case 'closed':
        return 'Закрыта';
      default:
        return status;
    }
  }
}
