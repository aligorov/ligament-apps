import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api/client.dart';
import '../models/ticket_models.dart';
import '../services/auth_state.dart';
import '../services/ticket_service.dart';

class TicketScreen extends StatefulWidget {
  const TicketScreen({super.key});

  @override
  State<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends State<TicketScreen> {
  String _filter = 'all';

  static const List<TicketPreset> _defaultPresets = [
    TicketPreset(code: 'printer_toner', title: 'Кончился картридж', iconEmoji: '🖨️', category: 'it'),
    TicketPreset(code: 'power_outage', title: 'Выключился свет', iconEmoji: '💡', category: 'facility', priority: 'high'),
    TicketPreset(code: 'water_leak', title: 'Течёт кран / вода', iconEmoji: '🚰', category: 'facility', priority: 'urgent'),
    TicketPreset(code: 'network_down', title: 'Пропал интернет', iconEmoji: '🌐', category: 'it', priority: 'high'),
    TicketPreset(code: 'pc_freeze', title: 'Завис компьютер', iconEmoji: '💻', category: 'it'),
  ];

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

  Future<void> _showCreateTicketDialog(ApiClient client) async {
    final titleController = TextEditingController();
    final roomController = TextEditingController();
    final descController = TextEditingController();
    String category = 'it';

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final theme = Theme.of(ctx);
            return AlertDialog(
              title: const Text('Новая заявка'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Тема проблемы *',
                        hintText: 'Напр., Завис монитор или не печатает',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(labelText: 'Категория'),
                      items: const [
                        DropdownMenuItem(value: 'it', child: Text('💻 ИТ и компьютеры')),
                        DropdownMenuItem(value: 'hardware', child: Text('🖨️ Оргтехника и картриджи')),
                        DropdownMenuItem(value: 'facility', child: Text('⚡ АХО / Электрика / Вода')),
                        DropdownMenuItem(value: '1c', child: Text('📊 1С и учетные базы')),
                        DropdownMenuItem(value: 'network', child: Text('🌐 Сеть и интернет')),
                        DropdownMenuItem(value: 'access', child: Text('🔑 Доступ и пропуска')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => category = val);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: roomController,
                      decoration: const InputDecoration(
                        labelText: 'Кабинет / Локация',
                        hintText: 'Каб. 204',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Подробное описание',
                        hintText: 'Что именно произошло...',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () async {
                    final t = titleController.text.trim();
                    if (t.isEmpty) return;
                    try {
                      await client.createTicket(
                        title: t,
                        category: category,
                        locationRoom: roomController.text.trim(),
                        description: descController.text.trim(),
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    } catch (err) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text('Ошибка создания: $err'),
                            backgroundColor: theme.colorScheme.error,
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Создать'),
                ),
              ],
            );
          },
        );
      },
    );

    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заявка успешно зарегистрирована!')),
      );
      TicketService.instance.loadTickets(client);
    }
  }

  void _showTicketDetails(TicketModel t, ApiClient client) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isOpen = t.status == 'open' || t.status == 'in_progress';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '#${t.ticketNumber}: ${t.title}',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Автор: ${t.authorName.isNotEmpty ? t.authorName : t.authorId}${t.locationRoom.isNotEmpty ? ' • Каб. ${t.locationRoom}' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isOpen
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _statusLabel(t.status),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isOpen ? colorScheme.primary : colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
              if (t.description.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colorScheme.outlineVariant),
                  ),
                  child: Text(
                    t.description,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.end,
                children: [
                  if (t.status == 'open')
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Взять в работу'),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        try {
                          await client.updateTicketStatus(t.id, 'in_progress');
                          TicketService.instance.loadTickets(client);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка обновления статуса: $e')),
                            );
                          }
                        }
                      },
                    ),
                  if (t.status == 'in_progress')
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: colorScheme.tertiary),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Завершить работу'),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        try {
                          await client.updateTicketStatus(t.id, 'completed');
                          TicketService.instance.loadTickets(client);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка завершения наряда: $e')),
                            );
                          }
                        }
                      },
                    ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Закрыть'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final auth = context.watch<AuthState>();
    final ticketService = context.watch<TicketService>();
    final presets = ticketService.presets;
    final activePresets = presets.isNotEmpty ? presets : _defaultPresets;
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: client != null ? () => _showCreateTicketDialog(client) : null,
        icon: const Icon(Icons.add),
        label: const Text('Новая заявка'),
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
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: activePresets.map((p) {
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
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
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
                                onTap: client != null ? () => _showTicketDetails(ticket, client) : null,
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
