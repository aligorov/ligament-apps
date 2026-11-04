import 'dart:async';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../models/ticket_models.dart';
import 'debug_log_service.dart';

class TicketService extends ChangeNotifier {
  static final TicketService instance = TicketService._();
  TicketService._();

  List<TicketPreset> _presets = const [];
  List<TicketModel> _tickets = const [];
  bool _isLoading = false;

  List<TicketPreset> get presets => _presets;
  List<TicketModel> get tickets => _tickets;
  bool get isLoading => _isLoading;

  Future<void> loadPresets(ApiClient client) async {
    try {
      final list = await client.getTicketPresets();
      _presets = list.map(TicketPreset.fromJson).toList();
      notifyListeners();
    } catch (e) {
      DebugLogService.instance.record('tickets.presets.failed', error: e);
    }
  }

  Future<void> loadTickets(ApiClient client, {String? status, String? authorId}) async {
    _isLoading = true;
    notifyListeners();
    try {
      final list = await client.getTickets(status: status, authorId: authorId);
      _tickets = list.map(TicketModel.fromJson).toList();
    } catch (e) {
      DebugLogService.instance.record('tickets.load.failed', error: e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> submitQuickTicket(
    ApiClient client,
    String presetCode, {
    String? room,
    String? device,
  }) async {
    try {
      final res = await client.createTicket(
        presetCode: presetCode,
        locationRoom: room,
        deviceName: device,
      );
      // Перезагружаем список
      unawaited(loadTickets(client));
      return res;
    } catch (e) {
      DebugLogService.instance.record('tickets.submit_quick.failed', error: e);
      rethrow;
    }
  }
}
