enum LogSeverity {
  success, // green
  info,    // blue
  warning, // orange
  error,   // red
}

class JourneyLog {
  final DateTime timestamp;
  final String message;
  final LogSeverity severity;

  JourneyLog({
    required this.timestamp,
    required this.message,
    required this.severity,
  });

  String get formattedTime {
    final hours = timestamp.hour.toString().padLeft(2, '0');
    final minutes = timestamp.minute.toString().padLeft(2, '0');
    final seconds = timestamp.second.toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}
