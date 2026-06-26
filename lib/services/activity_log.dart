// ActivityLog — lightweight on-device event log powering the Weekly Recap.
// Records reads + saves with a timestamp + a label (source/category) so we
// can show "You read 14 stories this week, mostly about EVs".
//
// Stored as a capped JSON list in SharedPreferences. No backend needed.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class WeekStats {
  final int reads;
  final int saves;
  final List<MapEntry<String, int>> topLabels; // most-read categories/sources
  const WeekStats({required this.reads, required this.saves, required this.topLabels});
  bool get isEmpty => reads == 0 && saves == 0;
}

class ActivityLog {
  ActivityLog._();
  static final ActivityLog instance = ActivityLog._();

  static const _key = 'activity_log';
  static const _cap = 500;

  /// Record an event. type = 'read' | 'save'. label = source or category.
  /// nowMs is passed in (callers use DateTime.now()) so this stays testable.
  Future<void> record(String type, String label, int nowMs) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? <String>[];
    list.add(jsonEncode({'t': type, 'l': label, 'ts': nowMs}));
    if (list.length > _cap) list.removeRange(0, list.length - _cap);
    await prefs.setStringList(_key, list);
  }

  /// Aggregate the last 7 days. `nowMs` = DateTime.now().millisecondsSinceEpoch.
  Future<WeekStats> weekStats(int nowMs) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? const <String>[];
    final cutoff = nowMs - const Duration(days: 7).inMilliseconds;
    int reads = 0, saves = 0;
    final labelCounts = <String, int>{};
    for (final raw in list) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final ts = (m['ts'] as num?)?.toInt() ?? 0;
        if (ts < cutoff) continue;
        final type = m['t'] as String? ?? '';
        final label = (m['l'] as String? ?? '').trim();
        if (type == 'read') reads++;
        if (type == 'save') saves++;
        if (label.isNotEmpty && label.toLowerCase() != 'uncategorized') {
          labelCounts[label] = (labelCounts[label] ?? 0) + 1;
        }
      } catch (_) {}
    }
    final top = labelCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return WeekStats(reads: reads, saves: saves, topLabels: top.take(3).toList());
  }
}
