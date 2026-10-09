import 'dart:collection';

// Deliberately never records USB packet bodies, device IDs or recipe names.
class DiagnosticLog {
  static final instance = DiagnosticLog();
  final _events = Queue<Map<String, String>>();
  final _secrets = <String>{};
  final camera = <String, String>{};

  void protect(String value) {
    if (value.trim().isNotEmpty) _secrets.add(value);
  }

  String redact(String text, {int max = 16000}) {
    var result = text;
    for (final secret
        in _secrets.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      result = result.replaceAll(secret, '[REDACTED]');
    }
    for (final pattern in [
      r'''(?:[A-Za-z]:[\\/]|/(?:Users|home|volume[0-9]+)/|\\\\)[^\r\n"<>]*''',
      r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
      r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
      r'''\b(?:USB|SWD|HID)[\\#][^\s"<>]+''',
      r'\b(?:serial(?:number)?|authorization|password|token)\s*[:=]\s*[^\s,;]+',
    ]) {
      result = result.replaceAll(
        RegExp(pattern, caseSensitive: false),
        '[REDACTED]',
      );
    }
    return result.length > max ? result.substring(0, max) : result;
  }

  void add(String kind, String message) {
    _events.add({
      'time': DateTime.now().toUtc().toIso8601String(),
      'kind': kind,
      'message': redact(message, max: 500),
    });
    while (_events.length > 120) {
      _events.removeFirst();
    }
  }

  List<Map<String, String>> snapshot() => [
    for (final event in _events)
      {...event, 'message': redact(event['message']!, max: 500)},
  ];
}
