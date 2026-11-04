import 'package:flutter/widgets.dart';

@immutable
class TicketPreset {
  final String code;
  final String title;
  final String iconEmoji;
  final String category;
  final String priority;
  final String targetGroup;
  final bool requiresPhoto;

  const TicketPreset({
    required this.code,
    required this.title,
    this.iconEmoji = '🎫',
    this.category = 'it',
    this.priority = 'normal',
    this.targetGroup = 'helpdesk',
    this.requiresPhoto = false,
  });

  factory TicketPreset.fromJson(Map<String, dynamic> json) {
    return TicketPreset(
      code: json['code'] as String? ?? '',
      title: json['title'] as String? ?? '',
      iconEmoji: json['icon_emoji'] as String? ?? '🎫',
      category: json['category'] as String? ?? 'it',
      priority: json['priority'] as String? ?? 'normal',
      targetGroup: json['target_group'] as String? ?? 'helpdesk',
      requiresPhoto: json['requires_photo'] as bool? ?? false,
    );
  }
}

@immutable
class TicketModel {
  final String id;
  final int ticketNumber;
  final String? presetCode;
  final String formType;
  final String title;
  final String description;
  final String category;
  final String status;
  final String priority;
  final String authorId;
  final String authorName;
  final String assigneeId;
  final String assigneeName;
  final String locationRoom;
  final String deviceName;
  final int affectedCount;
  final DateTime createdAt;

  const TicketModel({
    required this.id,
    required this.ticketNumber,
    this.presetCode,
    this.formType = 'it',
    required this.title,
    this.description = '',
    this.category = 'it',
    this.status = 'open',
    this.priority = 'normal',
    required this.authorId,
    this.authorName = '',
    this.assigneeId = '',
    this.assigneeName = '',
    this.locationRoom = '',
    this.deviceName = '',
    this.affectedCount = 1,
    required this.createdAt,
  });

  factory TicketModel.fromJson(Map<String, dynamic> json) {
    return TicketModel(
      id: json['id'] as String? ?? '',
      ticketNumber: (json['ticket_number'] as num?)?.toInt() ?? 0,
      presetCode: json['preset_code'] as String?,
      formType: json['form_type'] as String? ?? 'it',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      category: json['category'] as String? ?? 'it',
      status: json['status'] as String? ?? 'open',
      priority: json['priority'] as String? ?? 'normal',
      authorId: json['author_id'] as String? ?? '',
      authorName: json['author_name'] as String? ?? '',
      assigneeId: json['assignee_id'] as String? ?? '',
      assigneeName: json['assignee_name'] as String? ?? '',
      locationRoom: json['location_room'] as String? ?? '',
      deviceName: json['device_name'] as String? ?? '',
      affectedCount: (json['affected_count'] as num?)?.toInt() ?? 1,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

@immutable
class TicketItemModel {
  final String id;
  final String ticketId;
  final String title;
  final int quantity;
  final String unit;
  final String loggedBy;

  const TicketItemModel({
    required this.id,
    required this.ticketId,
    required this.title,
    this.quantity = 1,
    this.unit = 'шт',
    this.loggedBy = '',
  });

  factory TicketItemModel.fromJson(Map<String, dynamic> json) {
    return TicketItemModel(
      id: json['id'] as String? ?? '',
      ticketId: json['ticket_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
      unit: json['unit'] as String? ?? 'шт',
      loggedBy: json['logged_by'] as String? ?? '',
    );
  }
}
