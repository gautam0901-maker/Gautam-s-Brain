// Tab-feed cache. Each tab key (discover, trending, news_US, etc.) gets a
// JSON-encoded payload + timestamp in SharedPreferences. Consumers read the
// cache first (instant render) then trigger a fresh fetch in the background.
//
// Why SharedPreferences and not Hive/sqflite:
//   - Total payload is tiny (~50 items × ~1KB each = 50KB per tab)
//   - SharedPreferences is already in the app; no new dependency
//   - One synchronous-feeling write per refresh is fine
//
// Stale data behavior: `read()` returns the cached list even if it's past
// `maxAge` — TTL is just metadata via `isStale`. Caller decides whether to
// show stale-and-refresh or show-spinner-and-wait.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CachedFeed {
  final List<Map<String, String>> items;
  final DateTime? savedAt;
  const CachedFeed({required this.items, this.savedAt});
  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  Duration get age => savedAt == null
      ? const Duration(days: 365)
      : DateTime.now().difference(savedAt!);
}

class FeedCache {
  FeedCache._();
  static const String _prefix = 'feed_cache_';

  /// Returns the cached items even when older than `maxAge`. The caller
  /// inspects `cached.age` to decide whether to also kick a refresh.
  static Future<CachedFeed> read(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix${key}_data');
      final ts = prefs.getInt('$_prefix${key}_ts');
      if (raw == null) return const CachedFeed(items: []);
      final list = jsonDecode(raw) as List;
      final items = list
          .whereType<Map>()
          .map<Map<String, String>>(
              (m) => m.map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
          .toList();
      return CachedFeed(
        items: items,
        savedAt: ts != null ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
      );
    } catch (_) {
      return const CachedFeed(items: []);
    }
  }

  static Future<void> write(String key, List<Map<String, String>> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // V.6: 300/feed cap. Bigger surface = more instant offline content
      // on cold launch and during flaky-network moments.
      final capped = items.length > 300 ? items.sublist(0, 300) : items;
      await prefs.setString('$_prefix${key}_data', jsonEncode(capped));
      await prefs.setInt('$_prefix${key}_ts', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Helper: word count of summary → estimated read time at 250 wpm.
  static int readMinutes(String summary) {
    if (summary.isEmpty) return 1;
    final words = summary.trim().split(RegExp(r'\s+')).length;
    final mins = (words / 250).ceil();
    return mins.clamp(1, 30);
  }

  /// Every item across all cached feed keys, de-duplicated by title.
  /// Powers global search — the user can find anything they've recently
  /// seen in Discover/Trending/News without a network call.
  static Future<List<Map<String, String>>> allCachedItems() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <Map<String, String>>[];
    final seen = <String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix) || !key.endsWith('_data')) continue;
      try {
        final raw = prefs.getString(key);
        if (raw == null) continue;
        final list = jsonDecode(raw) as List;
        for (final e in list) {
          final m = (e as Map).map((k, v) => MapEntry('$k', '${v ?? ''}'));
          final title = m['title'] ?? '';
          if (title.isEmpty || seen.contains(title)) continue;
          seen.add(title);
          out.add(m);
        }
      } catch (_) {}
    }
    return out;
  }
}
