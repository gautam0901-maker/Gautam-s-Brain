// Heuristic personalization: derives "what you like" from your saved vault,
// then biases the Discover shuffle toward similar items. No ML model — just
// frequency counts over sources + title keywords. Good enough at <100k cards
// and explainable enough to show users (see Settings "What we learned").

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class Affinity {
  /// Source-label → weight (0..1, normalized so the most-saved source = 1.0).
  final Map<String, double> sources;
  /// Stemmed title keyword → weight (0..1).
  final Map<String, double> keywords;
  /// Negative source signal from left-swipes — same shape as `sources`.
  final Map<String, double> dislikedSources;
  /// Negative keyword signal from left-swipes.
  final Map<String, double> dislikedKeywords;
  /// Total saves analyzed. Below the cold-start threshold (5), the shuffle
  /// stays uniform so new users still get broad exploration.
  final int saveCount;
  /// Total left-swipes analyzed.
  final int dislikeCount;

  const Affinity({
    required this.sources,
    required this.keywords,
    required this.dislikedSources,
    required this.dislikedKeywords,
    required this.saveCount,
    required this.dislikeCount,
  });

  static const Affinity empty = Affinity(
    sources: {},
    keywords: {},
    dislikedSources: {},
    dislikedKeywords: {},
    saveCount: 0,
    dislikeCount: 0,
  );

  static const int coldStartThreshold = 5;
  bool get isColdStart => saveCount < coldStartThreshold;

  /// Top-N as a sorted list of (label, weight) for display.
  List<MapEntry<String, double>> topSources(int n) {
    final list = sources.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(n).toList();
  }

  List<MapEntry<String, double>> topKeywords(int n) {
    final list = keywords.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(n).toList();
  }
}

class PersonalizationService {
  PersonalizationService._();
  static final PersonalizationService instance = PersonalizationService._();

  // Session-cached so we don't recompute on every fetch.
  Affinity? _cached;
  Affinity get cached => _cached ?? Affinity.empty;

  /// Re-derive affinity from the current saved_vault. Call after a new save
  /// or on app start. O(savesCount) — runs in microseconds for typical use.
  Future<Affinity> refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final saves = prefs.getStringList('saved_vault') ?? const [];
    final dislikes = prefs.getStringList('disliked_titles') ?? const [];

    final srcPos = <String, int>{};
    final kwPos = <String, int>{};
    final srcNeg = <String, int>{};
    final kwNeg = <String, int>{};

    void tally(String raw, Map<String, int> srcMap, Map<String, int> kwMap) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        final src = (d['source'] ?? '').toString();
        if (src.isNotEmpty) srcMap[src] = (srcMap[src] ?? 0) + 1;
        for (final tk in _tokenize((d['title'] ?? '').toString())) {
          kwMap[tk] = (kwMap[tk] ?? 0) + 1;
        }
      } catch (_) {}
    }

    for (final raw in saves) tally(raw, srcPos, kwPos);
    for (final raw in dislikes) tally(raw, srcNeg, kwNeg);

    Map<String, double> norm(Map<String, int> counts) {
      if (counts.isEmpty) return const {};
      final max = counts.values.reduce((a, b) => a > b ? a : b);
      return counts.map((k, v) => MapEntry(k, v / max));
    }

    _cached = Affinity(
      sources: norm(srcPos),
      keywords: norm(kwPos),
      dislikedSources: norm(srcNeg),
      dislikedKeywords: norm(kwNeg),
      saveCount: saves.length,
      dislikeCount: dislikes.length,
    );
    return _cached!;
  }

  /// Returns a personalization score for a feed item.
  ///
  /// Why the negative side is weaker (0.30 vs positive's 1.0):
  ///   - A right-swipe means "I want more like this" — strong, clear signal.
  ///   - A left-swipe can mean many things: accidental, momentarily not in
  ///     the mood, disliked one aspect, already saw it elsewhere. Treating
  ///     it as 1:1 negative leads to false-positive penalization.
  ///   - Source-weighted-higher for negative because "I keep skipping
  ///     GitHub" is reliable, while "I skipped one paper containing the
  ///     word neural" is not.
  ///   - Require ≥3 dislikes before applying negative at all — single
  ///     dislike is noise, not signal.
  ///
  /// Net effect: dislikes deprioritize, they don't censor.
  double scoreItem(Map<String, String> item) {
    final aff = _cached;
    if (aff == null || aff.isColdStart) return 0.0;

    final src = item['source'] ?? '';
    final tokens = _tokenize(item['title'] ?? '');

    /// 60/40 source/keyword split is what we use for the positive signal.
    double positiveScore() {
      final srcS = aff.sources[src] ?? 0.0;
      double kwS = 0.0;
      if (tokens.isNotEmpty) {
        double sum = 0;
        int hits = 0;
        for (final t in tokens) {
          final w = aff.keywords[t];
          if (w != null) {
            sum += w;
            hits++;
          }
        }
        if (hits > 0) kwS = sum / tokens.length;
      }
      return 0.6 * srcS + 0.4 * kwS;
    }

    /// Source-heavy 70/30 for negative — keyword negative is too noisy.
    /// Returns 0.0 below the evidence threshold so single accidental
    /// swipes don't affect anything.
    double negativeScore() {
      if (aff.dislikeCount < 3) return 0.0;
      final srcS = aff.dislikedSources[src] ?? 0.0;
      double kwS = 0.0;
      if (tokens.isNotEmpty) {
        // Only count keywords that appear in 2+ dislikes (weight > 1/maxCount).
        double sum = 0;
        int hits = 0;
        for (final t in tokens) {
          final w = aff.dislikedKeywords[t];
          if (w != null && w > 0.4) {
            sum += w;
            hits++;
          }
        }
        if (hits > 0) kwS = sum / tokens.length;
      }
      return 0.7 * srcS + 0.3 * kwS;
    }

    return positiveScore() - 0.30 * negativeScore();
  }

  /// Stop-words we skip when counting keywords — these are noise.
  static const _stop = {
    'the','a','an','of','for','to','in','on','with','and','or','at','by','as',
    'is','it','this','that','from','how','why','what','when','your','you','we',
    'i','my','our','their','its','be','are','was','were','will','can','has',
    'have','had','but','if','vs','not','about','using','use','new','more','than',
    'most','some','all','any','no','do','does','did','just','out','up','down',
    'into','over','under','off','via',
  };

  /// Lowercase, strip punctuation, drop short + stop words, keep alphanumeric.
  List<String> _tokenize(String text) {
    final tokens = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 4 && !_stop.contains(t))
        .toList();
    return tokens;
  }
}
