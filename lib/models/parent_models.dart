import 'package:flutter/material.dart';

enum JourneyState {
  idle,
  atSchool,
  enRoute,
  approaching,
  arrived,
}

class JourneyAlert {
  final String id;
  final String message;
  final String type; // 'info', 'warning', 'proximity', 'emergency'
  final DateTime timestamp;

  JourneyAlert({
    required this.id,
    required this.message,
    required this.type,
    required this.timestamp,
  });

  factory JourneyAlert.fromMap(String id, Map<dynamic, dynamic> map) {
    final rawTimestamp = map['timestamp'];
    final DateTime time = rawTimestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp as int)
        : DateTime.now();

    return JourneyAlert(
      id: id,
      message: (map['message'] ?? '').toString(),
      type: (map['type'] ?? 'info').toString(),
      timestamp: time,
    );
  }

  Color get indicatorColor {
    switch (type) {
      case 'emergency':
        return const Color(0xFFEF4444); // red-500
      case 'warning':
        return const Color(0xFFF59E0B); // amber-500
      case 'proximity':
        return const Color(0xFF10B981); // green-500
      case 'info':
      default:
        return const Color(0xFF3B82F6); // blue-500
    }
  }
}
