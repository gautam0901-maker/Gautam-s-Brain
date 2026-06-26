import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'onboarding_screen.dart';
import '../main.dart' show tabTapTicker;
import '../services/ai_service.dart';
import '../services/auth_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/deep_link_service.dart';
import '../services/feed_cache.dart';
import '../services/personalization_service.dart';
import '../services/tts_service.dart';
import '../services/user_profile_service.dart';
import '../theme.dart';
import '../widgets/coachmark_overlay.dart';
import '../widgets/comments_section.dart';

// ============================================================
// OG META SCRAPER — one HTML fetch, two outputs: image (og:image
// / twitter:image) and description (og:description / meta name=description).
// In-memory cache + inflight-dedup so each URL is hit at most once.
// ============================================================
class OgMeta {
  final String? title;
  final String? image;
  final String? description;
  /// Cleaned text content scraped from the page's &lt;article&gt; or &lt;main&gt; tag.
  /// Typically 1000-3000 chars of actual article prose. Null when we can't
  /// find a recognizable content container.
  final String? bodyExcerpt;
  const OgMeta({this.title, this.image, this.description, this.bodyExcerpt});
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (image == null || image!.isEmpty) &&
      (description == null || description!.isEmpty) &&
      (bodyExcerpt == null || bodyExcerpt!.isEmpty);
}

class OgImageService {
  static final Map<String, OgMeta> _cache = {};
  static final Map<String, Future<OgMeta>> _inflight = {};

  /// Back-compat shortcut: image only.
  static Future<String?> fetch(String articleUrl) async {
    final m = await fetchMeta(articleUrl);
    return m.image;
  }

  static Future<OgMeta> fetchMeta(String articleUrl) async {
    if (articleUrl.isEmpty) return const OgMeta();
    if (_cache.containsKey(articleUrl)) return _cache[articleUrl]!;
    if (_inflight.containsKey(articleUrl)) return _inflight[articleUrl]!;
    final f = _doFetch(articleUrl);
    _inflight[articleUrl] = f;
    final result = await f;
    _cache[articleUrl] = result;
    _inflight.remove(articleUrl);
    return result;
  }

  static Future<OgMeta> _doFetch(String url) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; HiddenAIApp) AppleWebKit/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const OgMeta();
      final body = res.body;

      String? extractMeta(List<RegExp> patterns) {
        for (final p in patterns) {
          final m = p.firstMatch(body);
          if (m == null) continue;
          final v = (m.group(1) ?? '').trim();
          if (v.isNotEmpty) return v;
        }
        return null;
      }

      String? image = extractMeta([
        RegExp(r'''<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image["']''',
            caseSensitive: false),
      ]);
      if (image != null) {
        if (image.startsWith('//')) {
          image = 'https:$image';
        } else if (image.startsWith('/')) {
          final base = Uri.parse(url);
          image = '${base.scheme}://${base.host}$image';
        }
      }

      String? title = extractMeta([
        RegExp(r'''<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+name=["']twitter:title["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
      ]);
      title ??= RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
          .firstMatch(body)
          ?.group(1)
          ?.trim();

      final description = extractMeta([
        RegExp(r'''<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:description["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+name=["']twitter:description["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
        RegExp(r'''<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']''',
            caseSensitive: false),
      ]);

      // Article body excerpt — try <article> first, then <main>, then the
      // whole <body>. Strip script/style, pull <p> contents, drop short
      // paragraphs (menus/captions), concatenate up to 3000 chars.
      String? bodyExcerpt;
      try {
        final articleMatch = RegExp(r'<article[^>]*>([\s\S]*?)</article>',
                caseSensitive: false)
            .firstMatch(body);
        String content;
        if (articleMatch != null) {
          content = articleMatch.group(1) ?? '';
        } else {
          final mainMatch = RegExp(r'<main[^>]*>([\s\S]*?)</main>',
                  caseSensitive: false)
              .firstMatch(body);
          content = mainMatch?.group(1) ?? body;
        }
        content = content
            .replaceAll(
                RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
            .replaceAll(
                RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
            .replaceAll(
                RegExp(r'<noscript[^>]*>[\s\S]*?</noscript>', caseSensitive: false),
                '');
        final pRegex = RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false);
        final paras = pRegex
            .allMatches(content)
            .map((m) => _stripHtml(m.group(1) ?? ''))
            .where((p) => p.length > 40)
            .join('\n\n');
        if (paras.isNotEmpty) {
          bodyExcerpt =
              paras.length > 3000 ? '${paras.substring(0, 3000)}…' : paras;
        }
      } catch (_) {}

      String? decodeEntities(String? s) => s == null
          ? null
          : s
              .replaceAll('&amp;', '&')
              .replaceAll('&quot;', '"')
              .replaceAll('&#39;', "'")
              .replaceAll('&#x27;', "'")
              .replaceAll('&apos;', "'")
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>');

      return OgMeta(
        title: decodeEntities(title),
        image: image,
        description: decodeEntities(description),
        bodyExcerpt: decodeEntities(bodyExcerpt),
      );
    } catch (_) {}
    return const OgMeta();
  }
}

// Pollinations keyless API — but they cap anonymous users at ONE concurrent
// request per IP. We serialize calls through a tiny queue + retry-on-429
// with exponential backoff so user-visible failures are rare.
class PollinationsAI {
  static const String _endpoint = 'https://text.pollinations.ai/';

  // Chain of pending requests. New calls wait for the previous one to finish.
  static Future<void> _gate = Future.value();

  static Future<String?> generate(String prompt, {String model = 'openai'}) async {
    return chat([
      {'role': 'user', 'content': prompt},
    ], model: model);
  }

  static Future<String?> chat(
    List<Map<String, String>> messages, {
    String model = 'openai',
  }) async {
    // Wait for any in-flight call to drain before starting.
    final myTurn = _gate;
    final completer = Completer<void>();
    _gate = completer.future;
    try {
      await myTurn;
      return await _chatWithRetry(messages, model);
    } finally {
      completer.complete();
    }
  }

  static Future<String?> _chatWithRetry(
    List<Map<String, String>> messages,
    String model,
  ) async {
    // Fail fast: 20s per try, 2 tries. The serial gate means a slow call
    // blocks everything queued behind it, so we'd rather error quickly and
    // let the UI fall back than hang the whole AI pipeline.
    const maxAttempts = 2;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse(_endpoint),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'messages': messages,
                'model': model,
                'private': true,
              }),
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          return response.body.trim();
        }
        // Anonymous queue full: wait + retry.
        if (response.statusCode == 429 && attempt < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 800 * attempt * attempt));
          continue;
        }
        print('Pollinations HTTP ${response.statusCode}');
        return null;
      } catch (e) {
        if (attempt == maxAttempts) {
          print('Pollinations error after $attempt attempts: $e');
          return null;
        }
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return null;
  }
}

final List<List<Color>> cardGradients = [
  [const Color(0xFF0f0c29), const Color(0xFF302b63), const Color(0xFF24243e)],
  [const Color(0xFF141E30), const Color(0xFF243B55)],
  [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)],
  [const Color(0xFF000000), const Color(0xFF434343)],
  [const Color(0xFF1F1C2C), const Color(0xFF928DAB)],
];

// Free, keyless content sources. RSS feeds only run in General mode (RSS has no search).
const String _userAgent = 'HiddenAIApp/1.0 (Flutter)';

// 22 keyless RSS feeds. Per-feed cap is intentionally small (3) because
// the same big stories repeat across sources — at 3*22=66 items + APIs,
// we already have plenty of variety in the shuffle.
const List<Map<String, String>> _rssFeeds = [
  // Big tech news
  {'url': 'https://techcrunch.com/feed/', 'label': 'TechCrunch 🚀'},
  {'url': 'https://www.theverge.com/rss/index.xml', 'label': 'The Verge 📰'},
  {'url': 'https://feeds.arstechnica.com/arstechnica/index', 'label': 'Ars Technica 🔬'},
  {'url': 'https://www.wired.com/feed/tag/ai/latest/rss', 'label': 'Wired AI 🔌'},
  {'url': 'https://www.engadget.com/rss.xml', 'label': 'Engadget 🎧'},
  {'url': 'https://www.theregister.com/headlines.atom', 'label': 'The Register 🧙'},
  // Apple + Google ecosystem
  {'url': 'https://9to5mac.com/feed/', 'label': '9to5Mac 🍎'},
  {'url': 'https://9to5google.com/feed/', 'label': '9to5Google 🅖'},
  // Business + startups
  {'url': 'https://venturebeat.com/feed/', 'label': 'VentureBeat 💼'},
  {'url': 'https://www.fastcompany.com/latest/rss', 'label': 'Fast Company ⚡'},
  {'url': 'https://news.crunchbase.com/feed/', 'label': 'Crunchbase 💰'},
  {'url': 'https://sifted.eu/feed/', 'label': 'Sifted 🇪🇺'},
  // Deep / research / AI / science
  {'url': 'https://www.technologyreview.com/feed/', 'label': 'MIT Tech Review 🎓'},
  {'url': 'https://www.quantamagazine.org/feed/', 'label': 'Quanta Magazine 🔭'},
  {'url': 'https://spectrum.ieee.org/feeds/feed.rss', 'label': 'IEEE Spectrum ⚡'},
  {'url': 'https://www.nature.com/nature.rss', 'label': 'Nature 🧬'},
  {'url': 'https://huggingface.co/blog/feed.xml', 'label': 'HuggingFace 🤗'},
  {'url': 'https://blog.google/technology/ai/rss/', 'label': 'Google AI 🧠'},
  {'url': 'https://deepmind.google/blog/rss.xml', 'label': 'DeepMind 🧠'},
  // Dev community + product + nerd-culture
  {'url': 'https://lobste.rs/rss', 'label': 'Lobsters 🦞'},
  {'url': 'https://www.producthunt.com/feed', 'label': 'Product Hunt 🏹'},
  {'url': 'https://rss.slashdot.org/Slashdot/slashdotMain', 'label': 'Slashdot ⌨️'},
];

const List<String> _defaultSubreddits = [
  'MachineLearning',
  'artificial',
  'singularity',
  'LocalLLaMA',
];

String _stripHtml(String input) =>
    input.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

// ============================================================
// CATEGORIZATION — fixed taxonomy + keyword heuristic.
// Used by both: (a) saveToVault to label saved items, and (b) as
// fallback when Pollinations is rate-limited or returns garbage.
// ============================================================

const List<String> kCategoryList = [
  'AI & ML', 'Web Dev', 'Mobile Dev', 'DevOps & Cloud', 'Data Science',
  'Security', 'Blockchain', 'Hardware', 'Startups', 'Business',
  'Design & UX', 'Education', 'Science', 'Quantum', 'Robotics',
  'Gaming', 'Health Tech', 'FinTech', 'Open Source', 'Research',
];

// Lower-cased keyword → category. Match against the title primarily.
// Order matters: first hit wins, so put specific tokens before generic.
const Map<String, String> _kKeywordToCategory = {
  // AI / ML (most specific first)
  'transformer': 'AI & ML', 'attention': 'AI & ML', 'diffusion': 'AI & ML',
  'llm': 'AI & ML', 'gpt': 'AI & ML', 'claude': 'AI & ML', 'gemini': 'AI & ML',
  'neural network': 'AI & ML', 'machine learning': 'AI & ML',
  'deep learning': 'AI & ML', 'reinforcement learning': 'AI & ML',
  'embedding': 'AI & ML', 'fine-tun': 'AI & ML', 'prompt': 'AI & ML',
  'rag ': 'AI & ML', 'agent': 'AI & ML', 'multimodal': 'AI & ML',
  // Web Dev
  'react': 'Web Dev', 'vue': 'Web Dev', 'svelte': 'Web Dev', 'angular': 'Web Dev',
  'typescript': 'Web Dev', 'javascript': 'Web Dev', 'next.js': 'Web Dev',
  'nextjs': 'Web Dev', 'tailwind': 'Web Dev', 'css': 'Web Dev',
  'webassembly': 'Web Dev', 'wasm': 'Web Dev', 'browser': 'Web Dev',
  // Mobile
  'flutter': 'Mobile Dev', 'dart': 'Mobile Dev', 'swift': 'Mobile Dev',
  'swiftui': 'Mobile Dev', 'kotlin': 'Mobile Dev', 'jetpack': 'Mobile Dev',
  'android': 'Mobile Dev', 'iphone': 'Mobile Dev', 'ipad': 'Mobile Dev',
  'react native': 'Mobile Dev',
  // DevOps / Cloud
  'kubernetes': 'DevOps & Cloud', 'k8s': 'DevOps & Cloud', 'docker': 'DevOps & Cloud',
  'aws': 'DevOps & Cloud', 'gcp': 'DevOps & Cloud', 'azure': 'DevOps & Cloud',
  'terraform': 'DevOps & Cloud', 'cloudflare': 'DevOps & Cloud',
  'kafka': 'DevOps & Cloud', 'serverless': 'DevOps & Cloud',
  // Data
  'database': 'Data Science', 'postgres': 'Data Science', 'sql': 'Data Science',
  'analytics': 'Data Science', 'data pipeline': 'Data Science',
  'duckdb': 'Data Science', 'pandas': 'Data Science',
  // Security
  'vulnerability': 'Security', 'cve': 'Security', 'breach': 'Security',
  'ransomware': 'Security', 'malware': 'Security', 'phishing': 'Security',
  'zero-day': 'Security', 'zero day': 'Security', 'exploit': 'Security',
  'encryption': 'Security', 'cybersecurity': 'Security',
  // Crypto / Blockchain
  'bitcoin': 'Blockchain', 'ethereum': 'Blockchain', 'crypto': 'Blockchain',
  'web3': 'Blockchain', 'defi': 'Blockchain', 'nft': 'Blockchain',
  // Hardware
  'chip': 'Hardware', 'gpu': 'Hardware', 'tpu': 'Hardware', 'nvidia': 'Hardware',
  'apple silicon': 'Hardware', 'arm': 'Hardware', 'risc-v': 'Hardware',
  'semiconductor': 'Hardware', 'lithography': 'Hardware',
  // Startups / Business
  'funding': 'Startups', 'seed round': 'Startups', 'series a': 'Startups',
  'series b': 'Startups', 'ipo': 'Business', 'acquisition': 'Business',
  'startup': 'Startups', 'founder': 'Startups',
  // Quantum
  'quantum': 'Quantum',
  // Robotics
  'robot': 'Robotics', 'humanoid': 'Robotics', 'drone': 'Robotics',
  'autonomous': 'Robotics', 'self-driving': 'Robotics',
  // Gaming
  'unity': 'Gaming', 'unreal engine': 'Gaming', 'game engine': 'Gaming',
  'steam': 'Gaming',
  // Health
  'alzheimer': 'Health Tech', 'cancer': 'Health Tech', 'vaccine': 'Health Tech',
  'crispr': 'Health Tech', 'genome': 'Health Tech', 'clinical': 'Health Tech',
  // FinTech
  'stripe': 'FinTech', 'visa': 'FinTech', 'paypal': 'FinTech',
  // Design / UX
  'figma': 'Design & UX', 'sketch': 'Design & UX', 'typography': 'Design & UX',
  // Open Source / generic dev
  'github': 'Open Source', 'open source': 'Open Source', 'open-source': 'Open Source',
  // Science (catch-all for academic-sounding things)
  'physics': 'Science', 'biology': 'Science', 'chemistry': 'Science',
  'astronomy': 'Science', 'evolution': 'Science',
  // Education
  'university': 'Education', 'student': 'Education', 'teacher': 'Education',
  'curriculum': 'Education',
  // Generic AI (lowest priority, broad match)
  ' ai ': 'AI & ML', ' ai.': 'AI & ML',
};

/// Picks a category from kCategoryList. Tries Pollinations-returned text
/// first (when valid), then falls back to keyword heuristics. Last resort
/// is the source-based default.
String guessCategory(String title, String summary, String sourceLabel) {
  final text = '$title $summary'.toLowerCase();
  for (final entry in _kKeywordToCategory.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  // Source-based default. arXiv → Research, GitHub → Open Source, etc.
  if (sourceLabel.contains('arXiv')) return 'Research';
  if (sourceLabel.contains('GitHub') || sourceLabel.contains('Lobsters')) return 'Open Source';
  if (sourceLabel.contains('Hacker News')) return 'Startups';
  if (sourceLabel.contains('Reddit')) return 'AI & ML';
  if (sourceLabel.contains('Dev.to')) return 'Web Dev';
  if (sourceLabel.contains('Product Hunt')) return 'Startups';
  if (sourceLabel.contains('Nature') || sourceLabel.contains('Quanta')) return 'Science';
  return 'Tech';
}

/// Validates whatever Pollinations returned. Accepts exact match,
/// case-insensitive match, or substring-of-allowed match.
String? validatePollinationsCategory(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'''^["'`*]+|["'`*]+$'''), '')
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .trim();
  if (cleaned.isEmpty || cleaned.length > 40) return null;
  for (final cat in kCategoryList) {
    if (cleaned.toLowerCase() == cat.toLowerCase()) return cat;
  }
  for (final cat in kCategoryList) {
    if (cleaned.toLowerCase().contains(cat.toLowerCase()) ||
        cat.toLowerCase().contains(cleaned.toLowerCase())) {
      return cat;
    }
  }
  return null;
}

/// Differentiation: this app shows ONLY bleeding-edge intel from the past week.
const Duration _freshnessWindow = Duration(days: 7);

DateTime get _freshnessCutoff => DateTime.now().subtract(_freshnessWindow);

bool _isFresh(DateTime? when) {
  if (when == null) return true; // keep when we can't tell
  return when.isAfter(_freshnessCutoff);
}

// ============================================================
// SUBSCRIPTIONS — user's pinned topics. Discover aggregates
// across these by default; if empty we fall back to general AI.
// ============================================================
const String _subsKey = 'subscribed_topics';

Future<List<String>> loadSubscriptions() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_subsKey) ?? const [];
}

Future<bool> addSubscription(String topic) async {
  final t = topic.trim();
  if (t.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_subsKey) ?? <String>[];
  if (list.any((e) => e.toLowerCase() == t.toLowerCase())) return false;
  list.add(t);
  await prefs.setStringList(_subsKey, list);
  unawaited(CloudSyncService.instance.pushSubs(list));
  return true;
}

Future<void> removeSubscription(String topic) async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_subsKey) ?? <String>[];
  list.removeWhere((e) => e.toLowerCase() == topic.toLowerCase());
  await prefs.setStringList(_subsKey, list);
  unawaited(CloudSyncService.instance.pushSubs(list));
}

/// Cross-screen signal: Settings increments this after subs change,
/// the Discover tab listens and re-fetches its feed.
final ValueNotifier<int> subscriptionsTicker = ValueNotifier<int>(0);
void notifySubsChanged() => subscriptionsTicker.value++;

// ============================================================
// MUTED SOURCES — the user can silence a publisher entirely.
// Items whose 'source' contains a muted string are dropped from
// every feed (Discover/Trending/News) and search.
// ============================================================
const String _mutedKey = 'muted_sources';

/// In-memory mirror so synchronous filters (inside fetch loops) are cheap.
/// Loaded at app start + refreshed on every mute/unmute.
Set<String> mutedSourcesCache = <String>{};

Future<List<String>> loadMutedSources() async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_mutedKey) ?? const [];
  mutedSourcesCache = list.map((e) => e.toLowerCase()).toSet();
  return list;
}

Future<void> addMutedSource(String source) async {
  final s = source.trim();
  if (s.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_mutedKey) ?? <String>[];
  if (list.any((e) => e.toLowerCase() == s.toLowerCase())) return;
  list.add(s);
  await prefs.setStringList(_mutedKey, list);
  mutedSourcesCache = list.map((e) => e.toLowerCase()).toSet();
}

Future<void> removeMutedSource(String source) async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_mutedKey) ?? <String>[];
  list.removeWhere((e) => e.toLowerCase() == source.toLowerCase());
  await prefs.setStringList(_mutedKey, list);
  mutedSourcesCache = list.map((e) => e.toLowerCase()).toSet();
}

/// True if this item's source matches any muted entry.
bool isSourceMuted(Map<String, String> item) {
  if (mutedSourcesCache.isEmpty) return false;
  final src = (item['source'] ?? '').toLowerCase();
  if (src.isEmpty) return false;
  for (final m in mutedSourcesCache) {
    if (src.contains(m)) return true;
  }
  return false;
}

// ============================================================
// DAILY BRIEF — once-a-day AI summary of what's hot in the
// user's topics. Cached by date so we don't re-burn Pollinations.
// ============================================================
class BriefService {
  static String _todayKey() {
    final n = DateTime.now();
    return 'daily_brief_${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static Future<String?> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_todayKey());
  }

  /// Builds a 100-word brief from the current card pool. Caches by date.
  static Future<String?> generate({
    required List<Map<String, String>> cards,
    required List<String> topics,
  }) async {
    if (cards.isEmpty) return null;
    final sample = cards.take(20).map((c) {
      final t = (c['title'] ?? '').replaceAll('\n', ' ');
      return '- $t  [${c['source'] ?? ''}]';
    }).join('\n');
    final topicLine = topics.isEmpty ? 'AI and frontier tech' : topics.join(', ');
    final prompt =
        "You are a senior tech analyst writing one daily briefing for someone tracking: $topicLine.\n\n"
        "Today's freshest items across the feed:\n$sample\n\n"
        "Write a 100-word punchy brief: the biggest story, the second-biggest, and one sleeper to watch. "
        "Confident, conversational voice. No markdown. No headers. No numbering. Plain prose.";

    final result = await AIService.instance.generate(pollinationsFallback: PollinationsAI.generate, prompt:prompt);
    if (result == null || result.trim().isEmpty) return null;
    final cleaned = result.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_todayKey(), cleaned);
    return cleaned;
  }
}

/// Pulls a Reddit thumbnail/preview URL out of a post's `data` blob. Returns
/// null when the post has no usable image (self-text, deleted, NSFW placeholder).
String? _extractRedditImage(Map<String, dynamic> d) {
  try {
    final imgs = d['preview']?['images'] as List?;
    if (imgs != null && imgs.isNotEmpty) {
      final source = imgs[0]['source']?['url'] as String?;
      if (source != null && source.isNotEmpty) {
        return source.replaceAll('&amp;', '&');
      }
    }
  } catch (_) {}
  final thumb = (d['thumbnail'] ?? '').toString();
  if (thumb.startsWith('http')) return thumb;
  final urlOver = (d['url_overridden_by_dest'] ?? '').toString().toLowerCase();
  if (urlOver.endsWith('.jpg') ||
      urlOver.endsWith('.jpeg') ||
      urlOver.endsWith('.png') ||
      urlOver.endsWith('.webp') ||
      urlOver.endsWith('.gif')) {
    return d['url_overridden_by_dest'].toString();
  }
  return null;
}

/// Walks an RSS/Atom <item>/<entry> looking for an image: media:thumbnail,
/// media:content, enclosure type=image/*, or first <img> in body HTML.
String? _extractRssImage(xml.XmlElement el) {
  for (final t in el.findAllElements('thumbnail')) {
    final u = t.getAttribute('url');
    if (u != null && u.isNotEmpty) return u;
  }
  for (final c in el.findAllElements('content')) {
    final medium = c.getAttribute('medium');
    final type = c.getAttribute('type') ?? '';
    final u = c.getAttribute('url');
    if (u != null && (medium == 'image' || type.startsWith('image/'))) return u;
  }
  for (final enc in el.findAllElements('enclosure')) {
    final type = enc.getAttribute('type') ?? '';
    final u = enc.getAttribute('url');
    if (u != null && type.startsWith('image/')) return u;
  }
  final imgRegex = RegExp(r'''<img[^>]+src=["']([^"']+)["']''', caseSensitive: false);
  for (final tag in ['description', 'summary', 'encoded']) {
    for (final node in el.findAllElements(tag)) {
      final match = imgRegex.firstMatch(node.innerText);
      if (match != null) return match.group(1);
    }
  }
  return null;
}

// ============================================================
// VISUAL PRIMITIVES — aurora bg, frosted glass, spring scale,
// spring page route. Used across every screen.
// ============================================================

/// Slowly-drifting multi-radial gradient. Lives behind every Scaffold.
class AnimatedAuroraBackground extends StatefulWidget {
  final List<Color>? palette;
  final Widget? child;
  const AnimatedAuroraBackground({super.key, this.palette, this.child});
  @override
  State<AnimatedAuroraBackground> createState() => _AnimatedAuroraBackgroundState();
}

class _AnimatedAuroraBackgroundState extends State<AnimatedAuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 22))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pull palette from the active theme so the aurora switches when the
    // user toggles Light/Dark. Explicit `palette:` still wins when caller
    // wants a per-screen accent.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = widget.palette ?? (isDark ? glintAuroraDark : glintAuroraLight);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final a1 = Alignment(math.cos(t * 2 * math.pi) * 0.8, math.sin(t * 2 * math.pi) * 0.6);
          final a2 = Alignment(math.cos((t + 0.5) * 2 * math.pi) * 0.7, math.sin((t + 0.5) * 2 * math.pi) * 0.8);
          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: palette,
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: a1,
                    radius: 0.95,
                    colors: [palette[1].withOpacity(0.55), Colors.transparent],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: a2,
                    radius: 1.0,
                    colors: [palette[2].withOpacity(0.45), Colors.transparent],
                  ),
                ),
              ),
              if (widget.child != null) widget.child!,
            ],
          );
        },
      ),
    );
  }
}

/// Frosted-glass surface: backdrop blur + translucent tint + thin border.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blurSigma;
  final double tintOpacity;
  final Color? tint;
  final Color? borderColor;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 20,
    this.blurSigma = 14,
    this.tintOpacity = 0.10,
    this.tint,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    // In dark mode tint defaults to white (translucent over dark aurora).
    // In light mode tint defaults to black (translucent over light surface).
    // Explicit `tint:` from the caller still wins for accent panels.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final t = tint ?? (isDark ? Colors.white : Colors.black);
    final defaultBorder = isDark
        ? Colors.white.withOpacity(0.14)
        : Colors.black.withOpacity(0.10);
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [t.withOpacity(tintOpacity), t.withOpacity(tintOpacity * 0.35)],
              ),
              border: Border.all(
                color: borderColor ?? defaultBorder,
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Tap-press feedback with a real spring rebound (elastic-out on release).
class SpringScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  const SpringScale({super.key, required this.child, this.onTap, this.onLongPress, this.pressedScale = 0.93});
  @override
  State<SpringScale> createState() => _SpringScaleState();
}

class _SpringScaleState extends State<SpringScale> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      reverseDuration: const Duration(milliseconds: 520),
    );
    _scale = Tween<double>(begin: 1.0, end: widget.pressedScale).animate(
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _c.forward(),
      onTapUp: (_) {
        _c.reverse();
        widget.onTap?.call();
      },
      onTapCancel: () => _c.reverse(),
      onLongPress: widget.onLongPress,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// Fades + slides up its child once with an optional delay. Spring-y
/// emphasized curve, Safari/macOS feel. Reused across Discover header,
/// DetailScreen sections, Trending and News list rows.
class SpringIn extends StatefulWidget {
  final Widget child;
  final int delayMs;
  final Duration duration;
  const SpringIn({
    super.key,
    required this.child,
    this.delayMs = 0,
    this.duration = const Duration(milliseconds: 520),
  });
  @override
  State<SpringIn> createState() => _SpringInState();
}

class _SpringInState extends State<SpringIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration);
    _anim = CurvedAnimation(parent: _c, curve: Curves.fastEaseInToSlowEaseOut);
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.10),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}

/// Save an arbitrary item to the vault from outside TechFeedScreen
/// (used by Trending/News row bookmark buttons). Runs the same
/// categorization pipeline as the swipe-right flow.
Future<void> saveItemToVault(Map<String, String> paper) async {
  final title = paper['title'] ?? '';
  final summary = paper['summary'] ?? '';
  final source = paper['source'] ?? '';
  String? category;
  try {
    final prompt =
        "Pick the BEST single category for this content from this list:\n"
        "${kCategoryList.join(', ')}\n\n"
        "Title: $title\n"
        "Abstract: ${summary.length > 600 ? summary.substring(0, 600) : summary}\n\n"
        "Reply with ONLY the category name from the list above. No punctuation, no explanation.";
    final result = await AIService.instance.generate(pollinationsFallback: PollinationsAI.generate, prompt:prompt);
    if (result != null && result.isNotEmpty) {
      category = validatePollinationsCategory(result);
    }
  } catch (_) {}
  category ??= guessCategory(title, summary, source);

  final stored = Map<String, String>.from(paper);
  stored['category'] = category;
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList('saved_vault') ?? <String>[];
  saved.add(jsonEncode(stored));
  await prefs.setStringList('saved_vault', saved);
  await PersonalizationService.instance.refresh();
  unawaited(CloudSyncService.instance.pushVault(saved));
  unawaited(CloudSyncService.instance.pushBehavior(saves: saved.length));
}

// ============================================================
// GLINT AI VOICE + LIVE LISTEN SCRIPTS
// ============================================================

/// Shared identity prepended to every user-facing AI call so the answer
/// reads as ONE assistant ("Glint AI") regardless of which provider
/// (Gemini / Cerebras / Groq) actually served it. Users never see a
/// provider name — it's all Glint AI, one consistent voice.
const String kGlintPersona =
    "You are Glint AI, the friendly built-in assistant of the Glint news app. "
    "Always speak in one consistent, warm, clear voice. Never mention which "
    "model, company, or provider you are — you are simply Glint AI.";

/// Builds a lively spoken-word script for ONE article (Live Listen).
/// Online → Glint AI summary, clean and detailed. Offline/failure →
/// cleaned abstract so it still plays something sensible.
Future<String> buildArticleListenScript(Map<String, String> item) async {
  final title = item['title'] ?? '';
  final body = item['summary'] ?? '';
  final prompt = "$kGlintPersona\n\n"
      "Turn this article into a natural, lively spoken-word audio summary a "
      "listener can comfortably follow. STRICT rules: plain spoken sentences "
      "only — NO markdown, NO URLs, NO symbols (no slashes, asterisks, hashes), "
      "no headings, no bullet points, no lists. Begin by naming the story, then "
      "explain what happened and why it matters, in about 120-160 words. Warm, "
      "engaging radio-host tone.\n\n"
      "Title: $title\n\nContent: ${body.length > 1500 ? body.substring(0, 1500) : body}";
  final ai = await AIService.instance.generate(
    prompt: prompt,
    pollinationsFallback: PollinationsAI.generate,
    maxTokens: 400,
  );
  if (ai != null && ai.trim().length > 40) {
    return TtsService.cleanForSpeech(ai);
  }
  // Offline / AI failed → read the cleaned abstract.
  final fallback = '$title. ${body.isEmpty ? 'No summary is available for this story yet.' : body}';
  return TtsService.cleanForSpeech(fallback);
}

/// Builds a radio-style briefing across several Discover cards:
/// "Here are your top stories. Story one… Story two…". Online → Glint AI
/// host script; offline → simple titles read in order.
Future<String> buildDeckListenScript(List<Map<String, String>> items) async {
  final picks = items.take(6).toList();
  if (picks.isEmpty) return '';
  final raw = <String>[];
  for (int i = 0; i < picks.length; i++) {
    final t = picks[i]['title'] ?? '';
    final s = picks[i]['summary'] ?? '';
    raw.add("Story ${i + 1}: $t. ${s.length > 300 ? s.substring(0, 300) : s}");
  }
  final prompt = "$kGlintPersona\n\n"
      "You are hosting a short audio news roundup for the Glint app. Read these "
      "${picks.length} stories as one smooth, lively spoken-word briefing. "
      "Announce each as 'Story one', 'Story two', and so on. STRICT rules: plain "
      "spoken sentences only — NO markdown, NO URLs, NO symbols. Open with a "
      "quick friendly intro, give each story a sentence or two, and close with a "
      "short sign-off.\n\n${raw.join('\n\n')}";
  final ai = await AIService.instance.generate(
    prompt: prompt,
    pollinationsFallback: PollinationsAI.generate,
    maxTokens: 700,
  );
  if (ai != null && ai.trim().length > 60) {
    return TtsService.cleanForSpeech(ai);
  }
  // Offline fallback — read titles in order.
  final fb = StringBuffer("Here are your top stories from Glint. ");
  for (int i = 0; i < picks.length; i++) {
    fb.write("Story ${i + 1}. ${picks[i]['title'] ?? ''}. ");
  }
  fb.write("That's your briefing.");
  return TtsService.cleanForSpeech(fb.toString());
}

/// Adds an item's title to the dislikes list (negative signal). Shared by
/// the long-press "Skip" action and the swipe-left flow.
Future<void> markItemDisliked(Map<String, String> item) async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getStringList('disliked_titles') ?? <String>[];
  stored.add(jsonEncode({
    'title': item['title'] ?? '',
    'source': item['source'] ?? '',
  }));
  if (stored.length > 200) stored.removeRange(0, stored.length - 200);
  await prefs.setStringList('disliked_titles', stored);
  PersonalizationService.instance.refresh();
  unawaited(CloudSyncService.instance.pushDislikes(stored));
}

/// Starts Live Listen for a single item from anywhere (long-press menus).
/// Shows a "preparing" toast, builds the Glint AI script, then plays. The
/// global player bar (MainShell) surfaces the controls.
Future<void> startLiveListen(BuildContext context, Map<String, String> item) async {
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    content: Text('🎧 Glint AI is preparing your audio…'),
    duration: Duration(seconds: 2),
  ));
  final script = await buildArticleListenScript(item);
  await TtsService.instance.start(script);
}

/// Long-press action sheet for any feed card (Discover/Trending/News).
/// Live Listen · Save · Share · Mute source · Skip. Returns a label of
/// what happened so the caller can react.
Future<String?> showCardActionSheet(
    BuildContext context, Map<String, String> item) async {
  HapticFeedback.mediumImpact();
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final source = item['source'] ?? '';
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: isDark ? const Color(0xFF0C1622) : Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (sheetCtx) {
      Widget action(IconData icon, String label, String sub, Color color,
          VoidCallback onTap) {
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(label,
              style: TextStyle(
                  color: glintText(sheetCtx), fontWeight: FontWeight.w600)),
          subtitle: sub.isEmpty
              ? null
              : Text(sub, style: TextStyle(color: glintText(sheetCtx, 0.5), fontSize: 12)),
          onTap: onTap,
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(item['title'] ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: glintText(sheetCtx),
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
            const Divider(height: 18),
            action(Icons.headset_mic, 'Live Listen', 'Hear a Glint AI summary',
                glintAccent(sheetCtx), () {
              Navigator.pop(sheetCtx, 'listen');
            }),
            action(Icons.bookmark_add_outlined, 'Save to Vault', '',
                glintAccent(sheetCtx), () async {
              await saveItemToVault(item);
              if (sheetCtx.mounted) Navigator.pop(sheetCtx, 'saved');
            }),
            action(Icons.share_outlined, 'Share', '', glintText(sheetCtx),
                () {
              final url = item['url'] ?? '';
              final deep = url.isEmpty ? '' : DeepLinkService.encodeShareUrl(url);
              Share.share(
                  '${item['title']}\n\n${deep.isNotEmpty ? deep : url}',
                  subject: item['title']);
              Navigator.pop(sheetCtx, 'shared');
            }),
            if (source.isNotEmpty)
              action(Icons.block, 'Mute $source',
                  'Stop showing this publisher', Colors.orangeAccent, () async {
                await addMutedSource(source);
                if (sheetCtx.mounted) Navigator.pop(sheetCtx, 'muted');
              }),
            action(Icons.thumb_down_outlined, 'Not interested',
                'Show fewer like this', Colors.redAccent, () async {
              await markItemDisliked(item);
              if (sheetCtx.mounted) Navigator.pop(sheetCtx, 'skipped');
            }),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// Returns true if the item is already in the vault (by title match).
Future<bool> isInVault(String title) async {
  if (title.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getStringList('saved_vault') ?? const <String>[];
  for (final raw in saved) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if ((m['title'] ?? '') == title) return true;
    } catch (_) {}
  }
  return false;
}

/// Open an arbitrary article URL as a synthetic DetailScreen card.
/// Used by the deep-link handler when someone taps a shared link.
/// Shows a brief loading shimmer while we scrape OG metadata.
Future<void> openUrlAsDetail(BuildContext context, String url) async {
  // Show a tiny loading overlay so the cold-start isn't a black void.
  showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const Center(
      child: SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(color: Colors.lightBlueAccent),
      ),
    ),
  );
  final meta = await OgImageService.fetchMeta(url);
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // close loader

  final host = Uri.tryParse(url)?.host ?? 'shared link';
  final paper = <String, String>{
    'title': (meta.title ?? '').isNotEmpty ? meta.title! : host,
    'summary': (meta.bodyExcerpt ?? meta.description ?? 'Shared via Glint.').trim(),
    'author': host,
    'source': '🔗 Shared',
    'url': url,
    'image': meta.image ?? '',
  };
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).push(
    springRoute(DetailScreen(paper: paper, backgroundColors: cardGradients[0])),
  );
}

/// iOS-style spring page transition: fade + slide-up + subtle scale.
Route<T> springRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 520),
    reverseTransitionDuration: const Duration(milliseconds: 360),
    opaque: true,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.fastEaseInToSlowEaseOut,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

// ---------------------------------------------------------
// MAIN FEED SCREEN (NOW WITH HORIZON SCANNER 🔭)
// ---------------------------------------------------------
class TechFeedScreen extends StatefulWidget {
  const TechFeedScreen({super.key});
  @override
  State<TechFeedScreen> createState() => _TechFeedScreenState();
}

class _TechFeedScreenState extends State<TechFeedScreen> {
  List<Map<String, String>> papers = [];
  bool isLoading = true;
  final CardSwiperController swiperController = CardSwiperController();

  // 🔭 HORIZON SCANNER VARIABLES
  List<String> horizonTopics = [];
  bool isScanning = false;
  String currentFeedTitle = "General AI Feed";

  // Subscribed topics — Discover aggregates across these when non-empty.
  List<String> subscribedTopics = [];

  // Daily Brief state
  String? _todayBrief;
  bool _briefLoading = false;

  // First-launch coachmark gate.
  bool _showCoachmark = false;

  // Live Listen (deck briefing) loading state.
  bool _preparingDeckAudio = false;

  Future<void> _deckListen() async {
    HapticFeedback.mediumImpact();
    if (TtsService.instance.isPlaying.value) {
      await TtsService.instance.pause();
      setState(() {});
      return;
    }
    if (TtsService.instance.sentences.isNotEmpty) {
      await TtsService.instance.resume();
      setState(() {});
      return;
    }
    if (papers.isEmpty) return;
    setState(() => _preparingDeckAudio = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🎙️ Glint AI is preparing your news briefing…'),
        duration: Duration(seconds: 2),
      ));
    }
    final script = await buildDeckListenScript(papers);
    if (!mounted) return;
    await TtsService.instance.start(script);
    setState(() => _preparingDeckAudio = false);
  }

  @override
  void initState() {
    super.initState();
    subscriptionsTicker.addListener(_onSubsChanged);
    _initialLoad();
    BriefService.loadCached().then((b) {
      if (mounted) setState(() => _todayBrief = b);
    });
    shouldShowCoachmark().then((show) {
      if (mounted && show) setState(() => _showCoachmark = true);
    });
  }

  Future<void> _openOrGenerateBrief() async {
    String? brief = _todayBrief ?? await BriefService.loadCached();
    if (brief == null) {
      setState(() => _briefLoading = true);
      brief = await BriefService.generate(cards: papers, topics: subscribedTopics);
      if (!mounted) return;
      setState(() {
        _briefLoading = false;
        _todayBrief = brief;
      });
      if (brief == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't generate brief. Try again in a moment."), backgroundColor: Colors.orange),
        );
        return;
      }
    } else if (_todayBrief == null) {
      setState(() => _todayBrief = brief);
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _BriefSheet(brief: brief!),
    );
  }

  @override
  void dispose() {
    subscriptionsTicker.removeListener(_onSubsChanged);
    super.dispose();
  }

  void _onSubsChanged() {
    if (!mounted) return;
    refreshFromSubscriptions();
  }

  Future<void> _initialLoad() async {
    // Warm the profile cache so the very first fetch's profession filter
    // is correct (the _RootGate stream usually beats us, but be safe).
    await UserProfileService.instance.loadOnce();
    // Warm personalization affinity from saved_vault.
    await PersonalizationService.instance.refresh();
    final subs = await loadSubscriptions();
    if (!mounted) return;

    // Cache key reflects whether we're in subscribed mode (and which subs).
    final cacheKey = subs.isEmpty
        ? 'discover_general'
        : 'discover_subs_${subs.map((s) => s.toLowerCase()).toList().join('|').hashCode}';

    // Show cached items instantly if we have any — no loading spinner.
    final cached = await FeedCache.read(cacheKey);
    if (!mounted) return;
    setState(() {
      subscribedTopics = subs;
      currentFeedTitle =
          subs.isEmpty ? "General AI Feed" : "Your ${subs.length} Topics";
      if (cached.isNotEmpty) {
        papers = cached.items;
        isLoading = false;
      } else {
        isLoading = true;
      }
    });

    // Always kick a fresh fetch in the background. If cache was empty we
    // were showing a spinner; if it had items we silently refresh.
    if (subs.isEmpty) {
      fetchLatestAITech();
    } else {
      fetchSubscribedFeed(subs);
    }
  }

  /// Called by Settings (via the MainShell tab switch) when subs change,
  /// and also by our own refresh button.
  Future<void> refreshFromSubscriptions() async {
    final subs = await loadSubscriptions();
    if (!mounted) return;
    setState(() {
      subscribedTopics = subs;
      isLoading = true;
      horizonTopics = [];
      currentFeedTitle =
          subs.isEmpty ? "General AI Feed" : "Your ${subs.length} Topics";
    });
    if (subs.isEmpty) {
      fetchLatestAITech();
    } else {
      fetchSubscribedFeed(subs);
    }
  }

  // 🔮 THE AI HORIZON SCANNER FUNCTION
  Future<void> _scanTheHorizon() async {
    setState(() {
      isScanning = true;
      horizonTopics = [];
    });

    const prompt =
        "Name exactly 3 bleeding-edge AI subfields that aren't yet mainstream (examples: Liquid Neural Networks, Neuromorphic Computing, Quantum Machine Learning). Reply with ONLY the 3 names separated by commas. No numbering. No introduction. No quotes. No markdown.";

    final result = await AIService.instance.generate(pollinationsFallback: PollinationsAI.generate, prompt:prompt);

    if (!mounted) return;
    if (result == null || result.isEmpty) {
      setState(() => isScanning = false);
      return;
    }
    setState(() {
      horizonTopics = _parseHorizonTopics(result);
      isScanning = false;
    });
  }

  /// Pollinations sometimes returns "Sure! Here are 3 topics: 1. Foo, 2. Bar, 3. Baz"
  /// or markdown bullets. Strip preamble + numbering + bullets + wrapping quotes.
  List<String> _parseHorizonTopics(String raw) {
    String text = raw.trim();
    // Drop intro before the first ":" (handles "Here are 3 topics: ...")
    final colonIdx = text.indexOf(':');
    if (colonIdx > 0 && colonIdx < 80) {
      text = text.substring(colonIdx + 1).trim();
    }
    return text
        .split(RegExp(r'[,\n]'))
        .map((s) => s
            .trim()
            .replaceAll(RegExp(r'^\d+[\.\)]\s*'), '')
            .replaceAll(RegExp(r'^[-*•]\s*'), '')
            .replaceAll(RegExp(r'''^["'`]+|["'`]+$'''), '')
            .replaceAll(RegExp(r'\*+'), '')
            .trim())
        .where((s) => s.isNotEmpty && s.length >= 3 && s.length <= 60)
        .take(3)
        .toList();
  }

  // 🎯 HUNT DOWN THE UNKNOWN TECH
  void _huntSpecificTopic(String topic) {
    setState(() {
      isLoading = true;
      currentFeedTitle = "Hunting: $topic";
      // Keep horizonTopics visible so the user can switch topics without re-scanning.
    });
    fetchLatestAITech(topic: topic);
  }

  Future<void> fetchLatestAITech({int daysBack = 7, String? topic}) async {
    final results = await _fetchForOneTopic(topic: topic, daysBack: daysBack);
    if (!mounted) return;
    final dedup = await _dedupAndShuffle(results);
    setState(() {
      papers = dedup;
      isLoading = false;
    });
  }

  /// Multi-topic fan-out: fetch each subscribed topic's sources in parallel,
  /// merge, then dedup against seen.
  Future<void> fetchSubscribedFeed(List<String> topics) async {
    try {
      final batches = await Future.wait(topics.map((t) => _fetchForOneTopic(topic: t)));
      final merged = batches.expand((b) => b).toList();
      if (!mounted) return;
      final dedup = await _dedupAndShuffle(merged);
      setState(() {
        papers = dedup;
        isLoading = false;
      });
    } catch (e) {
      print('⚠️ fetchSubscribedFeed error: $e');
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  /// Hits every source for a single topic (or general if topic is null).
  /// Returns raw results — no dedup, no setState — for the caller to merge.
  Future<List<Map<String, String>>> _fetchForOneTopic({
    String? topic,
    int daysBack = 7,
  }) async {
    try {
      final isTopicMode = topic != null && topic.isNotEmpty;
      final batches = await Future.wait<List<Map<String, String>>>([
        _fetchArxiv(topic: topic),
        _fetchGithub(topic: topic, daysBack: daysBack),
        _fetchHackerNews(topic: topic),
        _fetchReddit(topic: topic),
        _fetchDevto(topic: topic),
        // RSS has no search, so skip in topic mode.
        if (!isTopicMode) _fetchAllRss() else Future.value(<Map<String, String>>[]),
      ]);
      return batches.expand((b) => b).toList();
    } catch (e) {
      print('⚠️ _fetchForOneTopic error: $e');
      return [];
    }
  }

  /// Pipeline:
  ///   1. Drop already-seen + within-batch duplicates.
  ///   2. Apply the profession source filter (Stage I).
  ///   3. Affinity-weighted partial sort (Stage L): top quartile sorted by
  ///      personalization score so favorites bubble up; remaining items
  ///      shuffled so the deck still feels fresh.
  Future<List<Map<String, String>>> _dedupAndShuffle(List<Map<String, String>> raw) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = (prefs.getStringList('seen_papers') ?? const <String>[]).toSet();
    final allowed = UserProfileService.instance.cached?.allowedSourceCategories;
    final localSeen = <String>{};
    final out = <Map<String, String>>[];
    for (final item in raw) {
      final title = item['title'] ?? '';
      if (title.isEmpty) continue;
      if (seen.contains(title)) continue;
      if (!localSeen.add(title)) continue;
      if (isSourceMuted(item)) continue; // W.6: drop muted publishers
      if (allowed != null) {
        final cat = sourceCategoryByLabel[item['source'] ?? ''];
        if (cat != null && !allowed.contains(cat)) continue;
      }
      out.add(item);
    }

    final aff = PersonalizationService.instance.cached;
    if (aff.isColdStart || out.length < 8) {
      // Cold start (< 5 saves) → uniform shuffle, broad exploration.
      out.shuffle();
    } else {
      // Score everything, sort top quartile, shuffle the rest. Keeps the
      // top of the deck personalized but the middle/bottom unpredictable.
      out.sort((a, b) => PersonalizationService.instance
          .scoreItem(b)
          .compareTo(PersonalizationService.instance.scoreItem(a)));
      final boundary = (out.length * 0.25).round().clamp(3, out.length);
      final top = out.sublist(0, boundary);
      final rest = out.sublist(boundary)..shuffle();
      out
        ..clear()
        ..addAll(top)
        ..addAll(rest);
    }

    _prefetchOgMeta(out);
    // Persist for instant render on next app start / tab return.
    final cacheKey = subscribedTopics.isEmpty
        ? 'discover_general'
        : 'discover_subs_${subscribedTopics.map((s) => s.toLowerCase()).toList().join('|').hashCode}';
    FeedCache.write(cacheKey, out);
    return out;
  }

  /// Fire-and-forget: warm the OG cache for the first N cards so that by
  /// the time the user swipes to them, the image is already resolved.
  /// Prevents "all cards show same image" when network is slow.
  void _prefetchOgMeta(List<Map<String, String>> cards) {
    for (final c in cards.take(10)) {
      final hasImage = (c['image'] ?? '').isNotEmpty;
      final url = c['url'] ?? '';
      if (!hasImage && url.isNotEmpty) {
        // Don't await — let it run in background.
        OgImageService.fetchMeta(url);
      }
    }
  }

  // ---------------- SOURCE FETCHERS ----------------

  Future<List<Map<String, String>>> _fetchArxiv({String? topic}) async {
    try {
      final hasTopic = topic != null && topic.isNotEmpty;
      // Quoted phrase for exact match in topic mode; default category otherwise.
      final searchQuery = hasTopic ? 'all:"$topic"' : 'cat:cs.AI';
      // Uri.https handles all encoding (spaces, quotes, etc.) automatically.
      // Capped at 8 so news sources (15 RSS feeds) get the larger share of
      // the shuffle. Most users prefer news over raw papers.
      final url = Uri.https('export.arxiv.org', '/api/query', {
        'search_query': searchQuery,
        'sortBy': 'submittedDate',
        'sortOrder': 'descending',
        'max_results': '8',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final doc = xml.XmlDocument.parse(res.body);
      return doc.findAllElements('entry').where((entry) {
        final pub = entry.findElements('published');
        if (pub.isEmpty) return true;
        return _isFresh(DateTime.tryParse(pub.first.innerText));
      }).map<Map<String, String>>((entry) {
        final title = entry.findElements('title').first.innerText.replaceAll('\n', ' ').trim();
        return {
          'title': title,
          'summary': entry.findElements('summary').first.innerText.replaceAll('\n', ' ').trim(),
          'author': entry.findElements('author').first.findElements('name').first.innerText,
          'source': 'arXiv 📄',
          'url': entry.findElements('id').first.innerText.trim(),
        };
      }).toList();
    } catch (e) {
      print('arXiv fetch failed: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchGithub({String? topic, int daysBack = 7}) async {
    try {
      final hasTopic = topic != null && topic.isNotEmpty;
      // Niche topics need a much wider time window; otherwise we get 0 hits.
      final effectiveDays = hasTopic ? 365 : daysBack;
      final pastDate = DateTime.now().subtract(Duration(days: effectiveDays)).toIso8601String().split('T')[0];
      final baseQuery = hasTopic ? '"$topic"' : 'topic:artificial-intelligence';
      final url = Uri.https('api.github.com', '/search/repositories', {
        'q': '$baseQuery created:>$pastDate',
        'sort': 'stars',
        'order': 'desc',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final items = (jsonDecode(res.body)['items'] as List?) ?? [];
      // Cap at 8 so code repos don't drown out news. Most users prefer news.
      return items.take(8).map<Map<String, String>>((repo) {
        final lang = repo['language'] ?? 'Mixed';
        final stars = repo['stargazers_count'].toString();
        final desc = repo['description']?.toString() ?? 'No description.';
        final fullName = repo['full_name']?.toString() ?? '';
        // GitHub's social-card endpoint — any path segment works as cache key.
        final image = fullName.isNotEmpty
            ? 'https://opengraph.githubassets.com/1/$fullName'
            : (repo['owner']?['avatar_url']?.toString() ?? '');
        return {
          'title': repo['name'].toString(),
          'summary': "⭐ Trending with $stars Stars\n💻 Built in: $lang\n\n$desc",
          'author': repo['owner']['login'].toString(),
          'source': 'GitHub 💻',
          'url': repo['html_url'].toString(),
          'image': image,
        };
      }).toList();
    } catch (e) {
      print('GitHub fetch failed: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchHackerNews({String? topic}) async {
    try {
      final hasTopic = topic != null && topic.isNotEmpty;
      final weekAgoTs = _freshnessCutoff.millisecondsSinceEpoch ~/ 1000;
      final url = Uri.https('hn.algolia.com', '/api/v1/search_by_date', {
        'tags': 'story',
        if (hasTopic) 'query': topic,
        'numericFilters': 'created_at_i>$weekAgoTs',
        'hitsPerPage': '15',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final hits = (jsonDecode(res.body)['hits'] as List?) ?? [];
      return hits.map<Map<String, String>>((hit) {
        final title = (hit['title'] ?? hit['story_title'] ?? '').toString().trim();
        final author = (hit['author'] ?? 'anonymous').toString();
        final points = hit['points']?.toString() ?? '0';
        final comments = hit['num_comments']?.toString() ?? '0';
        final externalUrl = (hit['url'] ?? '').toString();
        final hnUrl = 'https://news.ycombinator.com/item?id=${hit['objectID']}';
        return {
          'title': title,
          'summary': "🔥 $points points • 💬 $comments comments\n\nDiscussed on Hacker News. Tap to open the original article.",
          'author': '@$author on HN',
          'source': 'Hacker News 🟠',
          'url': externalUrl.isNotEmpty ? externalUrl : hnUrl,
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (e) {
      print('HN fetch failed: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchReddit({String? topic}) async {
    final hasTopic = topic != null && topic.isNotEmpty;
    try {
      if (hasTopic) {
        final url =
            'https://www.reddit.com/search.json?q=${Uri.encodeQueryComponent(topic)}&sort=new&limit=15';
        return _parseRedditJson(await _redditGet(url));
      }
      // General mode: pull hot from each default subreddit in parallel.
      final results = await Future.wait(_defaultSubreddits.map((sub) async {
        final url = 'https://www.reddit.com/r/$sub/hot.json?limit=6';
        return _parseRedditJson(await _redditGet(url));
      }));
      return results.expand((e) => e).toList();
    } catch (e) {
      print('Reddit fetch failed: $e');
      return [];
    }
  }

  Future<String?> _redditGet(String url) async {
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    return res.body;
  }

  List<Map<String, String>> _parseRedditJson(String? body) {
    if (body == null) return [];
    try {
      final children = ((jsonDecode(body)['data']?['children']) as List?) ?? [];
      final weekAgoTs = _freshnessCutoff.millisecondsSinceEpoch / 1000.0;
      return children
          .where((c) {
            final created = (c['data']?['created_utc'] as num?)?.toDouble() ?? 0.0;
            return created >= weekAgoTs;
          })
          .map<Map<String, String>>((c) {
        final d = c['data'] as Map<String, dynamic>;
        final title = (d['title'] ?? '').toString().trim();
        final selftext = (d['selftext'] ?? '').toString().trim();
        final sub = (d['subreddit_name_prefixed'] ?? 'r/?').toString();
        final author = (d['author'] ?? 'anon').toString();
        final ups = d['ups']?.toString() ?? '0';
        final comments = d['num_comments']?.toString() ?? '0';
        final permalink = 'https://www.reddit.com${d['permalink'] ?? ''}';
        final externalUrl = (d['url'] ?? '').toString();
        final isSelf = (d['is_self'] ?? false) == true;
        final summary = selftext.isNotEmpty
            ? (selftext.length > 2000 ? '${selftext.substring(0, 2000)}…' : selftext)
            : "⬆️ $ups upvotes • 💬 $comments comments\n\nDiscussion on $sub.";
        return {
          'title': title,
          'summary': summary,
          'author': '$sub • u/$author',
          'source': 'Reddit 🔴',
          'url': isSelf ? permalink : (externalUrl.isNotEmpty ? externalUrl : permalink),
          'image': _extractRedditImage(d) ?? '',
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (e) {
      print('Reddit JSON parse failed: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchDevto({String? topic}) async {
    try {
      final hasTopic = topic != null && topic.isNotEmpty;
      // Dev.to tags are single lowercase tokens — collapse multi-word topics.
      final tag = hasTopic
          ? topic.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')
          : 'ai';
      final url = Uri.https('dev.to', '/api/articles', {
        'tag': tag,
        'top': '7',
        'per_page': '15',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent, 'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final list = (jsonDecode(res.body) as List?) ?? [];
      return list.where((a) {
        final published = DateTime.tryParse((a['published_at'] ?? '').toString());
        return _isFresh(published);
      }).map<Map<String, String>>((a) {
        final title = (a['title'] ?? '').toString().trim();
        final desc = (a['description'] ?? '').toString().trim();
        final reactions = a['public_reactions_count']?.toString() ?? '0';
        final tagsCsv = (a['tag_list'] is List) ? (a['tag_list'] as List).join(', ') : '';
        final image = (a['cover_image'] ?? a['social_image'] ?? '').toString();
        final username = (a['user']?['username'] ?? 'anon').toString();
        final readMin = a['reading_time_minutes']?.toString() ?? '?';
        return {
          'title': title,
          'summary': "📖 $readMin min read • ❤️ $reactions reactions"
              "${tagsCsv.isEmpty ? '' : '\n🏷 $tagsCsv'}\n\n$desc",
          'author': '@$username on Dev.to',
          'source': 'Dev.to 👩‍💻',
          'url': (a['url'] ?? '').toString(),
          'image': image,
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (e) {
      print('Dev.to fetch failed: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _fetchAllRss() async {
    final results = await Future.wait(_rssFeeds.map((feed) => _fetchRss(feed['url']!, feed['label']!)));
    return results.expand((e) => e).toList();
  }

  Future<List<Map<String, String>>> _fetchRss(String url, String sourceLabel) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final doc = xml.XmlDocument.parse(res.body);
      // Try RSS 2.0 <item> first, then Atom <entry>. Per-feed cap is small
      // (3) because we have 22 RSS feeds — 3 * 22 = 66 items, plenty.
      final rssItems = doc.findAllElements('item').toList();
      if (rssItems.isNotEmpty) {
        return rssItems.take(3).map<Map<String, String>>((item) {
          final title = item.findElements('title').isEmpty
              ? ''
              : item.findElements('title').first.innerText.trim();
          final desc = item.findElements('description').isEmpty
              ? ''
              : item.findElements('description').first.innerText;
          final link = item.findElements('link').isEmpty
              ? ''
              : item.findElements('link').first.innerText.trim();
          String author = sourceLabel;
          final creators = item.findAllElements('dc:creator');
          if (creators.isNotEmpty) author = creators.first.innerText.trim();
          return {
            'title': title,
            'summary': _stripHtml(desc),
            'author': author,
            'source': sourceLabel,
            'url': link,
            'image': _extractRssImage(item) ?? '',
          };
        }).where((m) => m['title']!.isNotEmpty).toList();
      }
      // Atom fallback.
      return doc.findAllElements('entry').take(3).map<Map<String, String>>((entry) {
        final title = entry.findElements('title').isEmpty
            ? ''
            : entry.findElements('title').first.innerText.trim();
        final summary = entry.findElements('summary').isNotEmpty
            ? entry.findElements('summary').first.innerText
            : (entry.findElements('content').isNotEmpty
                ? entry.findElements('content').first.innerText
                : '');
        String link = '';
        final links = entry.findElements('link');
        if (links.isNotEmpty) {
          link = links.first.getAttribute('href') ?? links.first.innerText.trim();
        }
        String author = sourceLabel;
        final authorEls = entry.findElements('author');
        if (authorEls.isNotEmpty) {
          final names = authorEls.first.findElements('name');
          if (names.isNotEmpty) author = names.first.innerText.trim();
        }
        return {
          'title': title,
          'summary': _stripHtml(summary),
          'author': author,
          'source': sourceLabel,
          'url': link,
          'image': _extractRssImage(entry) ?? '',
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (e) {
      print('RSS fetch failed for $url: $e');
      return [];
    }
  }

  Future<void> markAsSeen(String title) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> seenTitles = prefs.getStringList('seen_papers') ?? [];
    if (!seenTitles.contains(title)) {
      seenTitles.add(title);
      await prefs.setStringList('seen_papers', seenTitles);
    }
  }

  Future<void> saveToVault(Map<String, String> paper) async {
    // No "categorizing..." snackbar — the swipe undo snackbar is the
    // primary confirmation, and a follow-up "Saved to folder X" would
    // dismiss its UNDO button mid-window.

    // Pipeline:
    //   1. Ask Pollinations to pick from a known list (better than free-form).
    //   2. Validate response against kCategoryList.
    //   3. If invalid OR Pollinations failed → keyword heuristic.
    //   4. Last resort → source-based default ("Tech").
    // No more "Uncategorized" for things with obvious keywords.
    final title = paper['title'] ?? '';
    final summary = paper['summary'] ?? '';
    final source = paper['source'] ?? '';
    final prompt =
        "Pick the BEST single category for this content from this list:\n"
        "${kCategoryList.join(', ')}\n\n"
        "Title: $title\n"
        "Abstract: ${summary.length > 600 ? summary.substring(0, 600) : summary}\n\n"
        "Reply with ONLY the category name from the list above. No punctuation, no explanation.";
    final result = await AIService.instance.generate(pollinationsFallback: PollinationsAI.generate, prompt:prompt);
    String? category;
    if (result != null && result.isNotEmpty) {
      category = validatePollinationsCategory(result);
    }
    category ??= guessCategory(title, summary, source);

    paper['category'] = category;
    final prefs = await SharedPreferences.getInstance();
    List<String> savedItems = prefs.getStringList('saved_vault') ?? [];
    savedItems.add(jsonEncode(paper));
    await prefs.setStringList('saved_vault', savedItems);
    // Re-learn what the user likes (cheap; runs in microseconds).
    await PersonalizationService.instance.refresh();
  }

  bool _onSwipe(int previousIndex, int? currentIndex, CardSwiperDirection direction) {
    final paper = papers[previousIndex];
    HapticFeedback.mediumImpact();
    markAsSeen(paper['title']!);
    if (direction == CardSwiperDirection.right) {
      saveToVault(paper);
      _showSwipeUndo(paper: paper, wasSave: true);
    } else if (direction == CardSwiperDirection.left) {
      // Negative signal: this is the supervised "downvote" we use to
      // penalize similar items in future feed shuffles.
      _markDisliked(paper);
      _showSwipeUndo(paper: paper, wasSave: false);
      _maybeShowFirstSkipHint();
    }
    return true;
  }

  /// One-time discoverability hint shown on the very first left-swipe so
  /// the user knows they haven't lost the item — it lives in Settings.
  Future<void> _maybeShowFirstSkipHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('skipped_hint_shown') ?? false) return;
    await prefs.setBool('skipped_hint_shown', true);
    // Delay so it doesn't overlap with the swipe-toast.
    await Future.delayed(const Duration(milliseconds: 2200));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Skipped news lives in Settings → Recently Skipped. You can bring them back any time.',
          style: TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        backgroundColor: glintAccent(context).withOpacity(0.95),
      ),
    );
  }

  Future<void> _markDisliked(Map<String, String> paper) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('disliked_titles') ?? <String>[];
    stored.add(jsonEncode({
      'title': paper['title'] ?? '',
      'source': paper['source'] ?? '',
    }));
    if (stored.length > 200) {
      stored.removeRange(0, stored.length - 200);
    }
    await prefs.setStringList('disliked_titles', stored);
    PersonalizationService.instance.refresh();
    unawaited(CloudSyncService.instance.pushDislikes(stored));
    unawaited(CloudSyncService.instance.pushBehavior(skips: stored.length));
  }

  /// Compact swipe toast with UNDO — short window (1.8s) so it doesn't
  /// camp on the screen. Floats above the nav bar; auto-dismissable.
  void _showSwipeUndo({required Map<String, String> paper, required bool wasSave}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasSave ? '✓ Saved' : '✕ Skipped',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        // 1.8s = quick toast that doesn't camp.
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
        // Margin lifts it above the floating nav bar; narrow horizontal
        // padding keeps it compact.
        margin: const EdgeInsets.only(bottom: 110, left: 80, right: 80),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: glintAccent(context),
          onPressed: () => _undoSwipe(paper, wasSave),
        ),
      ),
    );
  }

  Future<void> _undoSwipe(Map<String, String> paper, bool wasSave) async {
    HapticFeedback.mediumImpact();
    final prefs = await SharedPreferences.getInstance();
    final title = paper['title'] ?? '';
    // Reverse the seen-tracking so it can resurface in future fetches.
    final seen = prefs.getStringList('seen_papers') ?? <String>[];
    seen.remove(title);
    await prefs.setStringList('seen_papers', seen);
    if (wasSave) {
      final saved = prefs.getStringList('saved_vault') ?? <String>[];
      // Remove the most recently appended matching entry (avoids deleting an
      // older save with the same title).
      for (int i = saved.length - 1; i >= 0; i--) {
        try {
          final m = jsonDecode(saved[i]) as Map<String, dynamic>;
          if ((m['title'] ?? '') == title) {
            saved.removeAt(i);
            break;
          }
        } catch (_) {}
      }
      await prefs.setStringList('saved_vault', saved);
      unawaited(CloudSyncService.instance.pushVault(saved));
    } else {
      final dis = prefs.getStringList('disliked_titles') ?? <String>[];
      for (int i = dis.length - 1; i >= 0; i--) {
        try {
          final m = jsonDecode(dis[i]) as Map<String, dynamic>;
          if ((m['title'] ?? '') == title) {
            dis.removeAt(i);
            break;
          }
        } catch (_) {}
      }
      await prefs.setStringList('disliked_titles', dis);
      unawaited(CloudSyncService.instance.pushDislikes(dis));
    }
    await PersonalizationService.instance.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Undone'), duration: Duration(seconds: 1)),
    );
  }

  // Reset: subscribed feed if user has subs, else general feed.
  void _resetFeed() {
    setState(() {
      isLoading = true;
      horizonTopics = [];
      currentFeedTitle = subscribedTopics.isEmpty
          ? "General AI Feed"
          : "Your ${subscribedTopics.length} Topics";
    });
    if (subscribedTopics.isEmpty) {
      fetchLatestAITech();
    } else {
      fetchSubscribedFeed(subscribedTopics);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text("Discover", style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          SpringScale(
            onTap: _resetFeed,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Icon(Icons.refresh, color: Colors.white70),
            ),
          ),
        ],
      ),
      body: Stack(children: [
        AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              // 👋 Welcome row — name + photo when signed in. Stagger 0ms.
              SpringIn(
                delayMs: 0,
                child: StreamBuilder<User?>(
                  stream: AuthService.instance.authStateChanges,
                  initialData: AuthService.instance.currentUser,
                  builder: (context, snapshot) {
                    final user = snapshot.data;
                    if (user == null) return const SizedBox.shrink();
                    final name = (user.displayName ?? 'there').split(' ').first;
                    final photo = user.photoURL;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Row(
                        children: [
                          if (photo != null && photo.isNotEmpty)
                            CircleAvatar(
                              radius: 18,
                              backgroundImage: CachedNetworkImageProvider(photo),
                              backgroundColor: Colors.white12,
                            )
                          else
                            const CircleAvatar(
                              radius: 18,
                              backgroundColor: Colors.white12,
                              child: Icon(Icons.person, color: Colors.white70, size: 20),
                            ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Hey $name 👋',
                              style: TextStyle(
                                color: glintText(context),
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // 🔍 Search entry + 🎧 Live Listen — always visible row.
              SpringIn(
                delayMs: 40,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: SpringScale(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const SearchScreen()),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            decoration: BoxDecoration(
                              color: glintMuted(context, 0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: glintMuted(context, 0.10)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.search, size: 19, color: glintText(context, 0.55)),
                                const SizedBox(width: 10),
                                Text('Search anything…',
                                    style: TextStyle(
                                        color: glintText(context, 0.45), fontSize: 14)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // 🎧 Live Listen — Glint AI reads your top stories aloud.
                      SpringScale(
                        onTap: _preparingDeckAudio ? () {} : _deckListen,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          decoration: BoxDecoration(
                            color: glintAccent(context).withOpacity(0.16),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: glintAccent(context).withOpacity(0.45)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _preparingDeckAudio
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: glintAccent(context)))
                                  : Icon(Icons.headset_mic,
                                      size: 18, color: glintAccent(context)),
                              const SizedBox(width: 7),
                              Text('Live Listen',
                                  style: TextStyle(
                                      color: glintAccent(context),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ✨ Daily Brief banner — only when subs exist (relevance gate). Stagger 80ms.
              if (subscribedTopics.isNotEmpty)
                SpringIn(
                  delayMs: 80,
                  child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: SpringScale(
                    onTap: _briefLoading ? () {} : _openOrGenerateBrief,
                    child: GlassPanel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      tint: glintWarmAccent(context),
                      tintOpacity: 0.10,
                      borderColor: glintWarmAccent(context).withOpacity(0.40),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome, color: glintWarmAccent(context), size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Today's Brief",
                                    style: TextStyle(
                                        color: glintWarmAccent(context),
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.3)),
                                Text(
                                  _todayBrief != null
                                      ? "Tap to read the 60-second recap"
                                      : "Tap to generate today's recap",
                                  style: TextStyle(color: glintText(context, 0.65), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          if (_briefLoading)
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: glintWarmAccent(context), strokeWidth: 2),
                            )
                          else
                            Icon(Icons.chevron_right, color: glintWarmAccent(context)),
                        ],
                      ),
                    ),
                  ),
                  ),
                ),
              // 🔭 HORIZON SCANNER — frosted glass header. Stagger 160ms.
              SpringIn(
                delayMs: 160,
                child: GlassPanel(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                tint: glintAccent(context),
                tintOpacity: 0.10,
                borderColor: glintAccent(context).withOpacity(0.32),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            currentFeedTitle,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: glintAccent(context),
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (!isScanning)
                          SpringScale(
                            onTap: _scanTheHorizon,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: glintAccent(context).withOpacity(0.14),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: glintAccent(context).withOpacity(0.55)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.radar, size: 16, color: glintAccent(context)),
                                  const SizedBox(width: 6),
                                  Text("Scan Horizon",
                                      style: TextStyle(color: glintAccent(context), fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          )
                        else
                          SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(color: glintAccent(context), strokeWidth: 2),
                          ),
                      ],
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 380),
                      switchInCurve: Curves.fastEaseInToSlowEaseOut,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SizeTransition(sizeFactor: anim, child: child),
                      ),
                      child: horizonTopics.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              key: ValueKey(horizonTopics.join('|')),
                              padding: const EdgeInsets.only(top: 12),
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: horizonTopics
                                      .map((topic) => Padding(
                                            padding: const EdgeInsets.only(right: 8),
                                            child: SpringScale(
                                              onTap: () => _huntSpecificTopic(topic),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withOpacity(0.35),
                                                  borderRadius: BorderRadius.circular(20),
                                                  border: Border.all(color: Colors.purpleAccent.withOpacity(0.8)),
                                                ),
                                                child: Text(
                                                  "🚀 $topic",
                                                  style: const TextStyle(
                                                      color: Colors.purpleAccent, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              ),

              // THE SWIPE DECK — stagger 240ms.
              Expanded(
                child: SpringIn(
                delayMs: 240,
                child: isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.lightBlueAccent))
                    : papers.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.search_off, color: glintText(context, 0.4), size: 60),
                                const SizedBox(height: 16),
                                Text("No intel found on this.",
                                    style: TextStyle(
                                        color: glintText(context), fontSize: 20, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 24),
                                SpringScale(
                                  onTap: _resetFeed,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFF243B55), Color(0xFF141E30)],
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Text("Return to General Feed",
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  "Swipe Right to Save  →   ←   Swipe Left to Skip",
                                  style: TextStyle(
                                      color: glintText(context, 0.55),
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.4),
                                ),
                              ),
                              Expanded(
                                child: CardSwiper(
                                  controller: swiperController,
                                  cardsCount: papers.length,
                                  onSwipe: _onSwipe,
                                  allowedSwipeDirection: const AllowedSwipeDirection.symmetric(horizontal: true),
                                  numberOfCardsDisplayed: papers.length < 3 ? papers.length : 3,
                                  cardBuilder: (context, index, _, __) {
                                    final paper = papers[index];
                                    final currentGradient = cardGradients[index % cardGradients.length];
                                    return GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        springRoute(
                                          DetailScreen(paper: paper, backgroundColors: currentGradient),
                                        ),
                                      ),
                                      onLongPress: () async {
                                        final r = await showCardActionSheet(context, paper);
                                        if (r == null || !mounted) return;
                                        if (r == 'listen') {
                                          await startLiveListen(context, paper);
                                          if (mounted) setState(() {});
                                          return;
                                        }
                                        // Mute/skip → drop from the deck immediately.
                                        if (r == 'muted' || r == 'skipped') {
                                          setState(() => papers.removeWhere(
                                              (p) => p['title'] == paper['title']));
                                        }
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(r == 'muted'
                                                  ? 'Source muted'
                                                  : r == 'skipped'
                                                      ? 'Fewer like this'
                                                      : r == 'saved'
                                                          ? 'Saved to Vault'
                                                          : 'Shared'),
                                              behavior: SnackBarBehavior.floating,
                                              duration: const Duration(milliseconds: 1500),
                                            ),
                                          );
                                        }
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(24),
                                          gradient: LinearGradient(
                                            colors: currentGradient,
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: currentGradient.last.withOpacity(0.5),
                                              blurRadius: 22,
                                              offset: const Offset(0, 12),
                                            ),
                                          ],
                                          border: Border.all(color: Colors.white.withOpacity(0.08), width: 1),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(24),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              // Thumbnail strip — image fades into card body, no harsh rectangle.
                                              SizedBox(
                                                height: 200,
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    // ShaderMask makes the bottom 35% of the image
                                                    // fade to transparent so it dissolves into the
                                                    // card gradient below — no boxy seam.
                                                    ShaderMask(
                                                      shaderCallback: (rect) {
                                                        return const LinearGradient(
                                                          begin: Alignment.topCenter,
                                                          end: Alignment.bottomCenter,
                                                          colors: [
                                                            Colors.black,
                                                            Colors.black,
                                                            Colors.transparent,
                                                          ],
                                                          stops: [0.0, 0.65, 1.0],
                                                        ).createShader(rect);
                                                      },
                                                      blendMode: BlendMode.dstIn,
                                                      child: CardThumbnail(
                                                        key: ValueKey(
                                                            '${paper['title'] ?? ''}|${paper['url'] ?? ''}'),
                                                        imageUrl: paper['image'] ?? '',
                                                        articleUrl: paper['url'] ?? '',
                                                        fallbackPrompt: paper['title'] ?? '',
                                                        source: paper['source'] ?? '',
                                                        gradient: currentGradient,
                                                      ),
                                                    ),
                                                    Positioned(
                                                      left: 14,
                                                      top: 14,
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(
                                                            horizontal: 10, vertical: 5),
                                                        decoration: BoxDecoration(
                                                          color: paper['source']!.contains('GitHub')
                                                              ? Colors.black.withOpacity(0.55)
                                                              : Colors.redAccent.withOpacity(0.7),
                                                          borderRadius: BorderRadius.circular(8),
                                                        ),
                                                        child: Text(
                                                          paper['source']!,
                                                          style: const TextStyle(
                                                              color: Colors.white,
                                                              fontWeight: FontWeight.bold,
                                                              fontSize: 12),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              // Text content
                                              Expanded(
                                                child: Padding(
                                                  padding: const EdgeInsets.all(22),
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    mainAxisAlignment: MainAxisAlignment.start,
                                                    children: [
                                                      Text(paper['title']!,
                                                          maxLines: 3,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: const TextStyle(
                                                              fontSize: 22,
                                                              fontWeight: FontWeight.bold,
                                                              color: Colors.white,
                                                              height: 1.2)),
                                                      const SizedBox(height: 10),
                                                      Text("👤 ${paper['author']}",
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: const TextStyle(
                                                              fontSize: 13,
                                                              fontStyle: FontStyle.italic,
                                                              color: Colors.lightBlueAccent)),
                                                      const SizedBox(height: 6),
                                                      Row(
                                                        children: [
                                                          const Icon(Icons.schedule,
                                                              size: 12,
                                                              color: Colors.white54),
                                                          const SizedBox(width: 4),
                                                          Text(
                                                            '${FeedCache.readMinutes(paper['summary'] ?? '')} min read',
                                                            style: const TextStyle(
                                                                color: Colors.white60,
                                                                fontSize: 11),
                                                          ),
                                                        ],
                                                      ),
                                                      const SizedBox(height: 14),
                                                      Expanded(
                                                        child: Text(paper['summary']!,
                                                            overflow: TextOverflow.fade,
                                                            style: TextStyle(
                                                                fontSize: 14,
                                                                color: Colors.white.withOpacity(0.85),
                                                                height: 1.5)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 30),
                            ],
                          ),
              ),
              ),
            ],
          ),
        ),
      ),
        // Coachmark sits on top, dismisses self via SharedPreferences flip.
        if (_showCoachmark)
          CoachmarkOverlay(
            onDone: () => setState(() => _showCoachmark = false),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------
// SMART FOLDER VAULT SCREEN (Unchanged)
// ---------------------------------------------------------
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  List<Map<String, String>> savedPapers = [];
  List<Map<String, String>> displayedPapers = [];
  final TextEditingController searchController = TextEditingController();
  List<String> availableCategories = ['All'];
  String selectedCategory = 'All';

  @override
  void initState() {
    super.initState();
    tabTapTicker.addListener(_onTabTap);
    loadVault();
  }

  @override
  void dispose() {
    tabTapTicker.removeListener(_onTabTap);
    searchController.dispose();
    super.dispose();
  }

  void _onTabTap() {
    // Vault lives at MainShell index 3.
    if (tabTapTicker.value == 3 && mounted) loadVault();
  }

  Future<void> loadVault() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> savedItems = prefs.getStringList('saved_vault') ?? [];

    Set<String> uniqueCategories = {'All'};
    List<Map<String, String>> loadedPapers = [];

    for (var item in savedItems) {
      final decoded = jsonDecode(item) as Map<String, dynamic>;
      final paper = decoded.map((key, value) => MapEntry(key, value.toString()));
      loadedPapers.add(paper);
      uniqueCategories.add(paper['category'] ?? 'Uncategorized');
    }

    setState(() {
      savedPapers = loadedPapers;
      displayedPapers = savedPapers;
      availableCategories = uniqueCategories.toList();
    });
  }

  void filterVault() {
    final query = searchController.text.toLowerCase();
    setState(() {
      displayedPapers = savedPapers.where((paper) {
        final title = paper['title']!.toLowerCase();
        final summary = paper['summary']!.toLowerCase();
        final category = paper['category'] ?? 'Uncategorized';
        final matchesSearch = title.contains(query) || summary.contains(query);
        final matchesCategory = selectedCategory == 'All' || category == selectedCategory;
        return matchesSearch && matchesCategory;
      }).toList();
    });
  }

  Future<void> deleteFromVault(int index) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> savedItems = prefs.getStringList('saved_vault') ?? [];
    final paperToDelete = displayedPapers[index];
    final originalIndex = savedPapers.indexOf(paperToDelete);
    savedItems.removeAt(originalIndex);
    await prefs.setStringList('saved_vault', savedItems);
    setState(() {
      savedPapers.removeAt(originalIndex);
      filterVault();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text("Vault", style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              GlassPanel(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(20),
                tint: glintAccent(context),
                tintOpacity: 0.10,
                borderColor: glintAccent(context).withOpacity(0.35),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("🧠 INTEL",
                        style: TextStyle(
                            color: glintText(context, 0.6),
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2)),
                    const SizedBox(width: 16),
                    Text("${savedPapers.length} Saved",
                        style: TextStyle(
                            color: glintAccent(context),
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GlassPanel(
                  borderRadius: 30,
                  blurSigma: 10,
                  tintOpacity: 0.06,
                  child: TextField(
                    controller: searchController,
                    onChanged: (_) => filterVault(),
                    style: TextStyle(color: glintText(context)),
                    decoration: InputDecoration(
                      hintText: "Search your Second Brain...",
                      hintStyle: TextStyle(color: glintText(context, 0.55)),
                      prefixIcon: Icon(Icons.search, color: glintAccent(context)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 44,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: availableCategories.length,
                  itemBuilder: (context, index) {
                    final category = availableCategories[index];
                    final isSelected = category == selectedCategory;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SpringScale(
                        onTap: () => setState(() {
                          selectedCategory = category;
                          filterVault();
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.fastEaseInToSlowEaseOut,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? glintWarmAccent(context)
                                : glintMuted(context, 0.08),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? glintWarmAccent(context)
                                  : glintMuted(context, 0.14),
                            ),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(
                              color: isSelected ? Colors.black : glintText(context),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: displayedPapers.isEmpty
                    ? Center(
                        child: Text("No intel found in this folder.",
                            style: TextStyle(color: glintText(context, 0.55), fontSize: 18)))
                    : RefreshIndicator(
                        onRefresh: loadVault,
                        color: glintAccent(context),
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: displayedPapers.length,
                          itemBuilder: (context, index) {
                          final paper = displayedPapers[index];
                          final aiTag = paper['category'] ?? 'Uncategorized';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SpringScale(
                              onTap: () => Navigator.push(
                                context,
                                springRoute(DetailScreen(paper: paper, backgroundColors: cardGradients[0])),
                              ),
                              child: GlassPanel(
                                padding: const EdgeInsets.all(16),
                                borderRadius: 16,
                                tintOpacity: 0.07,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(paper['title']!,
                                              style: TextStyle(
                                                  color: glintText(context), fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 8),
                                          Row(children: [
                                            Icon(Icons.sell, size: 14, color: glintWarmAccent(context)),
                                            const SizedBox(width: 4),
                                            Text(aiTag,
                                                style: TextStyle(
                                                    color: glintWarmAccent(context),
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12)),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text("• ${paper['source']}",
                                                  style: TextStyle(
                                                      color: glintAccent(context),
                                                      overflow: TextOverflow.ellipsis)),
                                            ),
                                          ]),
                                        ],
                                      ),
                                    ),
                                    SpringScale(
                                      onTap: () => deleteFromVault(index),
                                      child: const Padding(
                                        padding: EdgeInsets.only(left: 8),
                                        child: Icon(Icons.delete_outline, color: Colors.redAccent),
                                      ),
                                    ),
                                  ],
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
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// THE AI INTERROGATOR DETAIL SCREEN (Unchanged)
// ---------------------------------------------------------
class DetailScreen extends StatefulWidget {
  final Map<String, String> paper;
  final List<Color> backgroundColors;
  const DetailScreen({super.key, required this.paper, required this.backgroundColors});
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  List<Map<String, String>> chatHistory = [];
  bool isTyping = false;
  late List<Map<String, String>> _conversation;

  /// Reading progress 0..1, derived from scroll position.
  double _readingProgress = 0.0;

  // Long-form article content scraped from the publisher's page. Shown
  // as "FULL ARTICLE" when we got something substantial. Replaces the old
  // Publisher Summary panel.
  String? _articleBody;

  // Whether the user has manually scrolled yet — once they do, we stop
  // auto-restoring so we don't yank them back.
  bool _userScrolled = false;
  double _savedOffset = 0;

  String get _scrollKey {
    final u = widget.paper['url'] ?? widget.paper['title'] ?? '';
    return 'scrollpos_${u.hashCode}';
  }

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    _restoreScrollPosition();
    final url = widget.paper['url'] ?? '';
    if (url.isNotEmpty) {
      OgImageService.fetchMeta(url).then((meta) {
        if (!mounted) return;
        // Prefer the long body excerpt; fall back to og:description if
        // body scrape failed (some sites use heavy SPA frameworks).
        final body = (meta.bodyExcerpt ?? '').trim();
        final desc = (meta.description ?? '').trim();
        final src = (widget.paper['summary'] ?? '').toLowerCase();
        String? chosen;
        if (body.length > 200) {
          chosen = body;
        } else if (desc.length > 80 &&
            !src.contains(desc.toLowerCase().substring(0, desc.length.clamp(0, 40)))) {
          chosen = desc;
        }
        if (chosen != null) setState(() => _articleBody = chosen);
      });
    }

    _conversation = [
      {
        'role': 'system',
        'content':
            "$kGlintPersona\n\n"
                "Act as an expert tech analyst and educator. Help the user genuinely understand the content below. "
                "Treat it as primary source, but bring in well-known related knowledge when it adds clarity.\n\n"
                "Title: ${widget.paper['title'] ?? ''}\n"
                "Source: ${widget.paper['source'] ?? ''}\n"
                "Content: ${widget.paper['summary'] ?? ''}\n\n"
                "When you answer:\n"
                "- Be thorough but readable — short paragraphs separated by blank lines.\n"
                "- Use concrete examples and analogies for hard concepts.\n"
                "- Define jargon the first time you use it.\n"
                "- Don't pad with disclaimers. Don't use markdown headers (just prose).\n"
                "- If the user's question can't be answered from the content, say so and offer what you can answer.",
      }
    ];
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      chatHistory.add({'role': 'user', 'text': text});
      isTyping = true;
    });
    _chatController.clear();
    FocusScope.of(context).unfocus();

    _conversation.add({'role': 'user', 'content': text});
    final response = await AIService.instance.chat(
      _conversation,
      pollinationsFallback: PollinationsAI.chat,
    );

    if (!mounted) return;
    if (response != null && response.isNotEmpty) {
      _conversation.add({'role': 'assistant', 'content': response});
      setState(() {
        chatHistory.add({'role': 'ai', 'text': response});
        isTyping = false;
      });
    } else {
      setState(() {
        chatHistory.add({'role': 'ai', 'text': "⚠️ Connection error."});
        isTyping = false;
      });
    }
  }

  Future<void> _launchURL() async {
    final Uri url = Uri.parse(widget.paper['url']!);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) { print('Could not launch $url'); }
  }

  bool _preparingAudio = false;

  Future<void> _toggleListen() async {
    HapticFeedback.mediumImpact();
    if (TtsService.instance.isPlaying.value) {
      await TtsService.instance.pause();
      setState(() {});
      return;
    }
    // Resume an already-built queue for this article.
    if (TtsService.instance.sentences.isNotEmpty) {
      await TtsService.instance.resume();
      setState(() {});
      return;
    }
    // First play → Glint AI writes a clean spoken summary (offline falls
    // back to the cleaned abstract inside buildArticleListenScript).
    setState(() => _preparingAudio = true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('🎧 Glint AI is preparing your audio…'),
        duration: Duration(seconds: 2),
      ));
    }
    // Prefer the scraped full article when we have it.
    final item = Map<String, String>.from(widget.paper);
    if (_articleBody != null && _articleBody!.length > 200) {
      item['summary'] = _articleBody!;
    }
    final script = await buildArticleListenScript(item);
    if (!mounted) return;
    await TtsService.instance.start(script);
    setState(() => _preparingAudio = false);
  }

  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    if (_scrollCtl.position.pixels > 4) _userScrolled = true;
    final max = _scrollCtl.position.maxScrollExtent;
    if (max <= 0) return;
    final p = (_scrollCtl.position.pixels / max).clamp(0.0, 1.0);
    // Only setState if change is visible (avoid 60+ rebuilds per scroll frame).
    if ((p - _readingProgress).abs() > 0.005) {
      setState(() => _readingProgress = p);
    }
  }

  /// Load the last offset for this article and gently scroll there once
  /// the layout settles. Skips if the user scrolls first or the saved
  /// position is near the top.
  Future<void> _restoreScrollPosition() async {
    final prefs = await SharedPreferences.getInstance();
    _savedOffset = prefs.getDouble(_scrollKey) ?? 0;
    if (_savedOffset < 80) return;
    // Wait for content (incl. article body) to lay out, then jump.
    for (final delay in [400, 900, 1600]) {
      await Future.delayed(Duration(milliseconds: delay));
      if (!mounted || _userScrolled || !_scrollCtl.hasClients) return;
      final max = _scrollCtl.position.maxScrollExtent;
      final target = _savedOffset.clamp(0.0, max);
      if (target > 80 && !_userScrolled) {
        _scrollCtl.jumpTo(target);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('↩ Resumed where you left off'),
              duration: Duration(milliseconds: 1400),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
    }
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollCtl.hasClients) return;
    final prefs = await SharedPreferences.getInstance();
    final px = _scrollCtl.position.pixels;
    if (px < 80) {
      await prefs.remove(_scrollKey);
    } else {
      await prefs.setDouble(_scrollKey, px);
    }
  }

  @override
  void dispose() {
    _saveScrollPosition();
    // NOTE: we deliberately do NOT stop TTS here — Live Listen keeps
    // playing as you leave the article and browse other tabs (the global
    // player bar in MainShell takes over the controls). Stop it from the
    // player bar's close button.
    _scrollCtl.removeListener(_onScroll);
    _scrollCtl.dispose();
    _chatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isGithub = widget.paper['source']!.contains('GitHub');
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      // Aurora follows theme (no per-card palette override) so DetailScreen
      // properly switches Light/Dark like every other screen.
      body: AnimatedAuroraBackground(
        child: Stack(children: [
          CustomScrollView(
          controller: _scrollCtl,
          slivers: [
            SliverAppBar(
              expandedHeight: 250,
              floating: false,
              pinned: true,
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? widget.backgroundColors.last.withOpacity(0.7)
                  : Colors.white.withOpacity(0.85),
              elevation: 0,
              actions: [
                SpringScale(
                  onTap: _preparingAudio ? () {} : _toggleListen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _preparingAudio
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: glintAccent(context)),
                          )
                        : ValueListenableBuilder<bool>(
                            valueListenable: TtsService.instance.isPlaying,
                            builder: (_, playing, __) => Icon(
                              playing ? Icons.headset : Icons.headset_outlined,
                              color: playing ? glintAccent(context) : glintText(context),
                            ),
                          ),
                  ),
                ),
                SpringScale(
                  onTap: () {
                    // Markdown-shaped output — pastes cleanly into Notion,
                    // Pocket, Obsidian, Apple Notes, etc. Title is H1,
                    // abstract as blockquote, both source link + Glint
                    // deep link included.
                    final title = widget.paper['title'] ?? '';
                    final source = widget.paper['source'] ?? '';
                    final author = widget.paper['author'] ?? '';
                    final summary = (widget.paper['summary'] ?? '').trim();
                    final url = widget.paper['url'] ?? '';
                    final deep = url.isEmpty ? '' : DeepLinkService.encodeShareUrl(url);
                    final short = summary.length > 400
                        ? '${summary.substring(0, 400)}…'
                        : summary;
                    final lines = <String>[
                      '# $title',
                      if (source.isNotEmpty || author.isNotEmpty)
                        '_${[source, author].where((s) => s.isNotEmpty).join(' · ')}_',
                      '',
                      if (short.isNotEmpty) '> ${short.replaceAll('\n', '\n> ')}',
                      '',
                      if (url.isNotEmpty) 'Source: $url',
                      if (deep.isNotEmpty) 'Open in Glint: $deep',
                      '',
                      '— shared via Glint',
                    ];
                    Share.share(lines.join('\n'), subject: title);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Icon(Icons.share, color: glintText(context)),
                  ),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsets.only(left: 20, bottom: 16, right: 20),
                // Always white over the cover image (image is dark-tinted by
                // the scrim); FlexibleSpaceBar handles the collapse fade.
                title: const Text("Intelligence Report",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
                background: _CoverImage(
                  imageUrl: widget.paper['image'] ?? '',
                  fallbackColors: widget.backgroundColors,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.paper['title']!,
                        style: TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold, color: glintText(context), height: 1.2)),
                    const SizedBox(height: 16),
                    Text("Source: ${widget.paper['source']}",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold, color: glintWarmAccent(context))),
                    const SizedBox(height: 8),
                    Text("By: ${widget.paper['author']!}",
                        style: TextStyle(
                            fontSize: 16, fontStyle: FontStyle.italic, color: glintAccent(context))),
                    const SizedBox(height: 24),
                    // 1. ORIGINAL ABSTRACT (was at the bottom — now first).
                    SpringIn(delayMs: 0, child: _abstractPanel(widget.paper['summary'] ?? '')),
                    // 2. FULL ARTICLE — only when scrape gave us something.
                    if (_articleBody != null) ...[
                      const SizedBox(height: 16),
                      SpringIn(delayMs: 100, child: _fullArticlePanel(_articleBody!)),
                    ],
                    const SizedBox(height: 24),
                    // 3. AI INTERROGATE.
                    SpringIn(delayMs: 200, child: _interrogatePanel()),
                    const SizedBox(height: 24),
                    // 4. OPEN button.
                    SpringIn(delayMs: 300, child: _openSourceButton(isGithub)),
                    const SizedBox(height: 28),
                    // 5. COMMENTS.
                    SpringIn(
                      delayMs: 400,
                      child: CommentsSection(articleUrl: widget.paper['url'] ?? ''),
                    ),
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Reading progress bar pinned to the top edge — hides at 0,
        // fills to right as user scrolls.
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 3,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: _readingProgress,
                  child: Container(
                    decoration: BoxDecoration(
                      color: glintAccent(context),
                      boxShadow: [
                        BoxShadow(
                          color: glintAccent(context).withOpacity(0.6),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 🎧 TTS player bar — slides up from the bottom while listening.
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: TtsService.instance.isPlaying,
            builder: (context, playing, _) {
              final hasQueue = TtsService.instance.sentences.isNotEmpty;
              if (!hasQueue) return const SizedBox.shrink();
              return TtsPlayerBar(
                onSearchHeard: _searchCurrentlyHeard,
                onClose: () async {
                  await TtsService.instance.stop();
                  setState(() {});
                },
                onToggle: _toggleListen,
              );
            },
          ),
        ),
        ]),
      ),
    );
  }

  /// "I just heard something interesting — find the full story." Takes the
  /// currently-spoken sentence and opens global search pre-filled with it.
  Future<void> _searchCurrentlyHeard() async {
    final heard = TtsService.instance.currentSentenceText();
    if (heard.trim().isEmpty) return;
    // Pause so the user can read results in silence.
    await TtsService.instance.pause();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: heard)),
    );
  }

  // -------- DetailScreen section builders --------

  Widget _abstractPanel(String text) => GlassPanel(
        padding: const EdgeInsets.all(18),
        borderRadius: 14,
        blurSigma: 12,
        tintOpacity: 0.06,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("ORIGINAL ABSTRACT",
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: glintText(context, 0.6),
                    letterSpacing: 1.5)),
            const SizedBox(height: 16),
            Text(text,
                style: TextStyle(
                    fontSize: 16, color: glintText(context, 0.85), height: 1.8)),
          ],
        ),
      );

  Widget _fullArticlePanel(String text) => GlassPanel(
        padding: const EdgeInsets.all(18),
        borderRadius: 14,
        blurSigma: 12,
        tint: glintWarmAccent(context),
        tintOpacity: 0.08,
        borderColor: glintWarmAccent(context).withOpacity(0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.article_outlined, color: glintWarmAccent(context), size: 18),
              const SizedBox(width: 6),
              Text("FULL ARTICLE",
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: glintWarmAccent(context),
                      letterSpacing: 1.5)),
            ]),
            const SizedBox(height: 12),
            Text(text,
                style: TextStyle(fontSize: 16, color: glintText(context), height: 1.7)),
          ],
        ),
      );

  Widget _interrogatePanel() => GlassPanel(
        padding: const EdgeInsets.all(20),
        borderRadius: 18,
        blurSigma: 16,
        tint: Colors.purpleAccent,
        tintOpacity: 0.10,
        borderColor: Colors.purpleAccent.withOpacity(0.45),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.auto_awesome, color: glintWarmAccent(context)),
              const SizedBox(width: 8),
              Text("INTERROGATE THE INTEL",
                  style: TextStyle(
                      color: glintText(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 1.2)),
            ]),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _aiChip(
                  label: "Explain Simply 🍼",
                  bg: glintWarmAccent(context),
                  textColor: Colors.black,
                  prompt:
                      "Explain the core idea of this content like I'm 12 years old. Use analogies, plain language, and 3–4 short paragraphs. No jargon.",
                ),
                const SizedBox(width: 8),
                _aiChip(
                  label: "Core Concept 🎯",
                  bg: glintMuted(context, 0.14),
                  textColor: glintText(context),
                  border: glintMuted(context, 0.22),
                  prompt:
                      "What problem does this solve, what is the key innovation that makes the solution work, and why does it matter? Be specific and concrete.",
                ),
                const SizedBox(width: 8),
                _aiChip(
                  label: "Deep Dive 🔬",
                  bg: glintAccent(context).withOpacity(0.18),
                  textColor: glintAccent(context),
                  border: glintAccent(context).withOpacity(0.5),
                  prompt:
                      "Give me a thorough technical deep-dive of how this works. Cover the mechanism, the key trade-offs, the assumptions, and the most important details. Use 4–6 paragraphs separated by blank lines.",
                ),
              ]),
            ),
            const SizedBox(height: 16),
            if (chatHistory.isNotEmpty)
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: chatHistory.length,
                itemBuilder: (context, index) {
                  final msg = chatHistory[index];
                  final isUser = msg['role'] == 'user';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser
                          ? glintAccent(context).withOpacity(0.20)
                          : glintMuted(context, 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isUser
                            ? glintAccent(context).withOpacity(0.5)
                            : glintMuted(context, 0.10),
                      ),
                    ),
                    child: Text(
                      "${isUser ? '👤 You: ' : '🤖 Assistant: '}${msg['text']}",
                      style: TextStyle(
                          color: isUser ? glintAccent(context) : glintText(context),
                          fontSize: 15,
                          height: 1.4),
                    ),
                  );
                },
              ),
            if (isTyping)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: CircularProgressIndicator(color: glintWarmAccent(context)),
              ),
            TextField(
              controller: _chatController,
              style: TextStyle(color: glintText(context)),
              decoration: InputDecoration(
                hintText: "Ask a question...",
                hintStyle: TextStyle(color: glintText(context, 0.55)),
                filled: true,
                fillColor: glintMuted(context, 0.10),
                suffixIcon: SpringScale(
                  onTap: () => _sendMessage(_chatController.text),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.send, color: glintWarmAccent(context)),
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: _sendMessage,
            ),
          ],
        ),
      );

  Widget _aiChip({
    required String label,
    required Color bg,
    required Color textColor,
    required String prompt,
    Color? border,
  }) =>
      SpringScale(
        onTap: () => _sendMessage(prompt),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: border == null ? null : Border.all(color: border),
          ),
          child: Text(label,
              style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
        ),
      );

  Widget _openSourceButton(bool isGithub) => SpringScale(
        onTap: _launchURL,
        child: Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color: isGithub ? Colors.white : Colors.redAccent,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: (isGithub ? Colors.white : Colors.redAccent).withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isGithub ? Icons.code : Icons.open_in_new,
                  color: isGithub ? Colors.black : Colors.white),
              const SizedBox(width: 10),
              Text(
                isGithub ? "OPEN REPOSITORY" : "READ FULL ON SOURCE",
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: isGithub ? Colors.black : Colors.white),
              ),
            ],
          ),
        ),
      );
}

// ============================================================
// CARD THUMBNAIL — try real image → fall back to Pollinations
// image generation (keyless) → final fallback is source emoji
// on a translucent panel. Used at top of every swipe card.
// ============================================================
/// Public so trending_and_news.dart can reuse the exact same thumbnail logic.
class CardThumbnail extends StatefulWidget {
  /// The source-provided image URL (e.g. GitHub social card, Reddit preview).
  final String imageUrl;

  /// The article's actual URL. We scrape og:image from this when imageUrl is empty.
  final String articleUrl;

  /// Used only as the Picsum seed for the final-fallback gradient swap.
  final String fallbackPrompt;
  final String source;
  final List<Color> gradient;
  const CardThumbnail({
    super.key,
    required this.imageUrl,
    required this.articleUrl,
    required this.fallbackPrompt,
    required this.source,
    required this.gradient,
  });
  @override
  State<CardThumbnail> createState() => _CardThumbnailState();
}

class _CardThumbnailState extends State<CardThumbnail> {
  String? _currentUrl;
  bool _ogTried = false;
  bool _picsumTried = false;

  /// Lorem Picsum — real Unsplash photos keyed by seed. Only used as the
  /// LAST resort when there's no source image AND og:image scrape fails.
  static String _picsumImage(String prompt) {
    final seed = prompt.hashCode.abs() % 1000000;
    return 'https://picsum.photos/seed/$seed/500/280';
  }

  @override
  void initState() {
    super.initState();
    _resolveFor(widget);
  }

  /// CardSwiper reuses widget instances when scrolling — same State, new props.
  /// Without this hook, the first card's image stays on every subsequent card
  /// because initState() only runs once. Resync whenever props change.
  @override
  void didUpdateWidget(covariant CardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.articleUrl != widget.articleUrl ||
        oldWidget.fallbackPrompt != widget.fallbackPrompt;
    if (changed) {
      _ogTried = false;
      _picsumTried = false;
      _currentUrl = null;
      _resolveFor(widget);
    }
  }

  void _resolveFor(CardThumbnail w) {
    if (w.imageUrl.isNotEmpty) {
      setState(() => _currentUrl = w.imageUrl);
    } else if (w.articleUrl.isNotEmpty) {
      _kickOgScrape();
    } else {
      _useFinalFallback();
    }
  }

  Future<void> _kickOgScrape() async {
    _ogTried = true;
    final og = await OgImageService.fetch(widget.articleUrl);
    if (!mounted) return;
    if (og != null && og.isNotEmpty) {
      setState(() => _currentUrl = og);
    } else {
      _useFinalFallback();
    }
  }

  void _useFinalFallback() {
    _picsumTried = true;
    final next = _picsumImage(widget.fallbackPrompt);
    if (mounted) setState(() => _currentUrl = next);
  }

  void _onError() {
    if (!_ogTried && widget.articleUrl.isNotEmpty) {
      _kickOgScrape();
    } else if (!_picsumTried) {
      _useFinalFallback();
    } else {
      setState(() => _currentUrl = null);
    }
  }

  Widget _placeholder() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: widget.gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_currentUrl == null) return _placeholder();
    // CachedNetworkImage = disk cache. Same image on revisit loads instantly.
    return CachedNetworkImage(
      imageUrl: _currentUrl!,
      key: ValueKey(_currentUrl),
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 220),
      placeholder: (_, __) => _placeholder(),
      errorWidget: (_, __, ___) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onError();
        });
        return _placeholder();
      },
    );
  }
}

// ============================================================
// COVER IMAGE for DetailScreen header — Image.network with
// graceful fallback to the gradient palette + scrim overlay.
// ============================================================
class _CoverImage extends StatelessWidget {
  final String imageUrl;
  final List<Color> fallbackColors;
  const _CoverImage({required this.imageUrl, required this.fallbackColors});

  Widget _fallback() => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: fallbackColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Icon(Icons.memory, size: 100, color: Colors.white.withOpacity(0.10)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (imageUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 220),
            placeholder: (_, __) => _fallback(),
            errorWidget: (_, __, ___) => _fallback(),
          )
        else
          _fallback(),
        // Bottom-to-top dark scrim so the title stays legible.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withOpacity(0.55),
              ],
              stops: const [0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// SETTINGS SCREEN — stats, destructive actions, about.
// Third tab of MainShell.
// ============================================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _seenCount = 0;
  int _vaultCount = 0;
  List<String> _subs = [];
  final TextEditingController _addTopicController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadSubs();
  }

  @override
  void dispose() {
    _addTopicController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _seenCount = (prefs.getStringList('seen_papers') ?? const []).length;
      _vaultCount = (prefs.getStringList('saved_vault') ?? const []).length;
    });
  }

  Future<void> _loadSubs() async {
    final subs = await loadSubscriptions();
    if (!mounted) return;
    setState(() => _subs = subs);
  }

  Future<void> _showAddTopicDialog() async {
    _addTopicController.clear();
    final added = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF14172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Pin a topic',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Discover will pull fresh news, papers and repos on this topic from all sources.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _addTopicController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g. Quantum Machine Learning',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (v) => Navigator.pop(c, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, null),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, _addTopicController.text),
            child: const Text('Pin',
                style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    final raw = added?.trim();
    if (raw == null || raw.isEmpty) return;
    // AI-normalize: handles "machin lerning" → "Machine Learning" and
    // "I want news about gravity" → "Gravity". Falls back to raw input
    // if Pollinations is rate-limited or returns garbage.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🤖 Understanding your topic…'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    String topic = raw;
    try {
      final result = await AIService.instance.generate(pollinationsFallback: PollinationsAI.generate, prompt:
        "Extract the main topic from this text. Fix any spelling. Use Title Case. "
        "Reply with ONLY the topic name (1-4 words). No quotes, no punctuation, no explanation.\n\n"
        "Input: \"$raw\"\n\nTopic:",
      );
      if (result != null && result.trim().isNotEmpty) {
        final cleaned = result
            .trim()
            .replaceAll(RegExp(r'''^["'`*]+|["'`*]+$'''), '')
            .replaceAll(RegExp(r'[.!?]+$'), '')
            .trim();
        // Only accept if the response is short + sane (Pollinations sometimes
        // returns a full sentence even when asked not to).
        if (cleaned.length >= 2 && cleaned.length <= 40 && !cleaned.contains('\n')) {
          topic = cleaned;
        }
      }
    } catch (_) {}

    final ok = await addSubscription(topic);
    if (!mounted) return;
    if (ok) {
      notifySubsChanged();
      await _loadSubs();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pinned "$topic"'), backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already pinned'), backgroundColor: Colors.orange),
      );
    }
  }

  Future<void> _removeSub(String topic) async {
    await removeSubscription(topic);
    notifySubsChanged();
    await _loadSubs();
  }

  Future<void> _doSignIn() async {
    try {
      final user = await AuthService.instance.signInWithGoogle();
      if (!mounted || user == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Welcome, ${user.displayName ?? 'friend'}!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sign-in failed: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _doSignOut() async {
    await AuthService.instance.signOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signed out')),
    );
  }

  String _themeSubtitle(ThemeMode mode) => switch (mode) {
        ThemeMode.system => 'Follow system',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  Future<void> _pickThemeMode() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? const Color(0xFF14172A) : const Color(0xFFF3F8F8);
    final chosen = await showModalBottomSheet<ThemeMode>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: glintMuted(c, 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Appearance',
                    style: TextStyle(
                        color: glintText(c),
                        fontWeight: FontWeight.w800,
                        fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            _themeOption(c, ThemeMode.system, Icons.brightness_auto, 'Follow system',
                'Match your phone setting'),
            _themeOption(c, ThemeMode.light, Icons.light_mode_outlined, 'Light',
                'Soft cream + teal'),
            _themeOption(c, ThemeMode.dark, Icons.dark_mode_outlined, 'Dark',
                'Deep aurora, the signature look'),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await saveThemeModePref(chosen);
      if (mounted) setState(() {});
    }
  }

  Widget _themeOption(BuildContext c, ThemeMode mode, IconData icon, String label, String desc) {
    final selected = themeModeNotifier.value == mode;
    return InkWell(
      onTap: () => Navigator.pop(c, mode),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: selected ? glintAccent(c) : glintText(c, 0.70)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: selected ? glintAccent(c) : glintText(c),
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  Text(desc, style: TextStyle(color: glintText(c, 0.55), fontSize: 12)),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle, color: glintAccent(c)),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditProfile() async {
    final current = UserProfileService.instance.cached ??
        await UserProfileService.instance.loadOnce();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OnboardingScreen(initial: current, isEdit: true),
      ),
    );
  }

  Future<void> _confirmAndClear({
    required String title,
    required String body,
    required String prefsKey,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF14172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Text(body, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Clear',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsKey);
    await _loadStats();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$title cleared'), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              // 🔐 ACCOUNT — sign in / out + profile preview.
              StreamBuilder<User?>(
                stream: AuthService.instance.authStateChanges,
                initialData: AuthService.instance.currentUser,
                builder: (context, snapshot) {
                  final user = snapshot.data;
                  return GlassPanel(
                    padding: const EdgeInsets.all(20),
                    tint: Colors.lightBlueAccent,
                    tintOpacity: 0.08,
                    child: user == null ? _signInCard() : _profileCard(user),
                  );
                },
              ),
              const SizedBox(height: 16),
              GlassPanel(
                padding: const EdgeInsets.all(20),
                tint: Colors.purpleAccent,
                tintOpacity: 0.10,
                borderColor: Colors.purpleAccent.withOpacity(0.40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('MY TOPICS',
                            style: TextStyle(
                                color: Colors.white60,
                                letterSpacing: 1.4,
                                fontWeight: FontWeight.bold)),
                        SpringScale(
                          onTap: _showAddTopicDialog,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.purpleAccent.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.purpleAccent.withOpacity(0.5)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add, size: 16, color: Colors.purpleAccent),
                                SizedBox(width: 4),
                                Text('Pin Topic',
                                    style: TextStyle(
                                        color: Colors.purpleAccent,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (_subs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No topics pinned yet. Discover shows general AI feed.\nPin topics to make Discover yours.',
                          style: TextStyle(
                              color: glintText(context, 0.55),
                              fontSize: 13,
                              height: 1.5),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _subs
                            .map((t) => SpringScale(
                                  onTap: () => _removeSub(t),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.35),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                          color: Colors.purpleAccent.withOpacity(0.6)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(t,
                                            style: const TextStyle(
                                                color: Colors.purpleAccent,
                                                fontWeight: FontWeight.w600)),
                                        const SizedBox(width: 6),
                                        const Icon(Icons.close,
                                            size: 14, color: Colors.purpleAccent),
                                      ],
                                    ),
                                  ),
                                ))
                            .toList(),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassPanel(
                padding: const EdgeInsets.all(20),
                tint: Colors.lightBlueAccent,
                tintOpacity: 0.08,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('STATS',
                        style: TextStyle(
                            color: Colors.white60,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),
                    _statRow('🧠 Vault', '$_vaultCount saved'),
                    _statRow('👀 Seen', '$_seenCount cards'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _personalizationPanel(),
              const SizedBox(height: 16),
              GlassPanel(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    if (AuthService.instance.isSignedIn)
                      _settingsTile(
                        icon: Icons.tune,
                        title: 'Edit Profile',
                        subtitle: 'Change profession, interests, country',
                        onTap: _openEditProfile,
                      ),
                    if (AuthService.instance.isSignedIn)
                      const Divider(height: 1, color: Colors.white12, indent: 56),
                    _settingsTile(
                      icon: Icons.history,
                      title: 'Recently Skipped',
                      subtitle: 'See cards you left-swiped — bring them back',
                      onTap: _openSkipped,
                    ),
                    const Divider(height: 1, color: Colors.white12, indent: 56),
                    _settingsTile(
                      icon: Icons.block,
                      title: 'Muted Sources',
                      subtitle: mutedSourcesCache.isEmpty
                          ? 'Hide publishers you never want to see'
                          : '${mutedSourcesCache.length} source(s) hidden',
                      onTap: _openMuted,
                    ),
                    const Divider(height: 1, color: Colors.white12, indent: 56),
                    FutureBuilder<bool>(
                      future: AIService.instance.hasAnyKey(),
                      builder: (context, snap) {
                        final on = snap.data ?? false;
                        return _settingsTile(
                          icon: on ? Icons.bolt : Icons.bolt_outlined,
                          title: 'AI Engines',
                          subtitle: on
                              ? '⚡ Fast AI enabled — Gemini → Cerebras → Groq'
                              : 'AI slow? Add free keys to make it instant',
                          onTap: _openAiEngines,
                        );
                      },
                    ),
                    const Divider(height: 1, color: Colors.white12, indent: 56),
                    _settingsTile(
                      icon: Icons.palette_outlined,
                      title: 'Appearance',
                      subtitle: _themeSubtitle(themeModeNotifier.value),
                      onTap: _pickThemeMode,
                    ),
                    const Divider(height: 1, color: Colors.white12, indent: 56),
                    _settingsTile(
                      icon: Icons.visibility_off_outlined,
                      title: 'Clear Seen History',
                      subtitle: 'Lets already-swiped cards reappear',
                      onTap: () => _confirmAndClear(
                        title: 'Seen History',
                        body: 'Cards you previously swiped will start showing again. This cannot be undone.',
                        prefsKey: 'seen_papers',
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12, indent: 56),
                    _settingsTile(
                      icon: Icons.delete_sweep_outlined,
                      title: 'Empty Intel Vault',
                      subtitle: 'Deletes everything you saved',
                      danger: true,
                      onTap: () => _confirmAndClear(
                        title: 'Intel Vault',
                        body: 'All saved cards and their AI categories will be permanently deleted.',
                        prefsKey: 'saved_vault',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassPanel(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ABOUT',
                        style: TextStyle(
                            color: Colors.white60,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),
                    _statRow('Version', '1.0.0'),
                    _statRow('AI brain', 'Gemini → Cerebras → Groq → Pollinations'),
                    _statRow('Sources', 'arXiv • GitHub • HN • Reddit • RSS'),
                    const SizedBox(height: 14),
                    Text(
                      'Crafted by Gautam',
                      style: TextStyle(
                          color: glintText(context, 0.55), fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: glintText(context, 0.7), fontSize: 15)),
            Text(value,
                style: TextStyle(
                    color: glintText(context), fontWeight: FontWeight.w600, fontSize: 15)),
          ],
        ),
      );

  /// Transparency panel — shows the user what we learned from their saves.
  /// Builds trust ("the app isn't a black box") and lets them sanity-check.
  Widget _personalizationPanel() {
    return FutureBuilder<Affinity>(
      future: PersonalizationService.instance.refresh(),
      builder: (context, snap) {
        final aff = snap.data ?? PersonalizationService.instance.cached;
        return GlassPanel(
          padding: const EdgeInsets.all(20),
          tint: Colors.cyanAccent,
          tintOpacity: 0.07,
          borderColor: Colors.cyanAccent.withOpacity(0.30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.auto_graph, color: Colors.cyanAccent, size: 18),
                SizedBox(width: 8),
                Text('WHAT WE LEARNED',
                    style: TextStyle(
                        color: Colors.white60,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 12),
              if (aff.isColdStart)
                Text(
                  aff.saveCount == 0
                      ? "Swipe right to save (positive signal), left to dislike (negative). After a few swipes the feed starts tuning itself."
                      : "${aff.saveCount} of ${Affinity.coldStartThreshold} saves needed before personalization kicks in.",
                  style: TextStyle(color: glintText(context, 0.75), height: 1.5),
                )
              else ...[
                Text(
                  "Learned from ${aff.saveCount} saves and ${aff.dislikeCount} dislikes. "
                  "Liked-looking items bubble up; disliked-looking items get deprioritized.",
                  style: TextStyle(color: glintText(context, 0.65), fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 14),
                Text('Top sources',
                    style: TextStyle(
                        color: glintText(context, 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: aff
                      .topSources(5)
                      .map((e) => _affChip(e.key, e.value, glintAccent(context)))
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text('Top keywords',
                    style: TextStyle(
                        color: glintText(context, 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: aff
                      .topKeywords(8)
                      .map((e) => _affChip(e.key, e.value, Colors.purpleAccent))
                      .toList(),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _affChip(String label, double weight, Color color) {
    // Weight maps to opacity so visually-stronger interests stand out.
    final alpha = (0.20 + weight * 0.45).clamp(0.20, 0.65);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(alpha * 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(alpha)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12)),
    );
  }

  Widget _signInCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ACCOUNT',
            style: TextStyle(
                color: glintText(context, 0.6), letterSpacing: 1.4, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        Text(
          'Sign in to sync your topics, comment on posts, and get personalized recommendations.',
          style: TextStyle(color: glintText(context, 0.75), fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 16),
        SpringScale(
          onTap: _doSignIn,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.login, color: Colors.black87, size: 20),
                SizedBox(width: 10),
                Text(
                  'Sign in with Google',
                  style: TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _profileCard(User user) {
    final photo = user.photoURL;
    final name = user.displayName ?? 'Friend';
    final email = user.email ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ACCOUNT',
            style: TextStyle(
                color: glintText(context, 0.6), letterSpacing: 1.4, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        Row(
          children: [
            if (photo != null && photo.isNotEmpty)
              CircleAvatar(
                radius: 28,
                backgroundImage: CachedNetworkImageProvider(photo),
                backgroundColor: Colors.white12,
              )
            else
              const CircleAvatar(
                radius: 28,
                backgroundColor: Colors.white12,
                child: Icon(Icons.person, color: Colors.white70),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: TextStyle(
                          color: glintText(context),
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                  if (email.isNotEmpty)
                    Text(email,
                        style: TextStyle(color: glintText(context, 0.55), fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            SpringScale(
              onTap: _doSignOut,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: glintMuted(context, 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: glintMuted(context, 0.18)),
                ),
                child: Text('Sign out',
                    style: TextStyle(color: glintText(context, 0.75), fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openSkipped() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SkippedScreen()),
    );
    // Affinity may have changed if user un-skipped items.
    await PersonalizationService.instance.refresh();
  }

  /// Manage muted publishers — unmute by tapping the ×. Mutes are added
  /// from the long-press card menu, not here (here is just review/undo).
  Future<void> _openMuted() async {
    await loadMutedSources();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0C1622)
          : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (sheetCtx, setSheet) {
          final muted = mutedSourcesCache.toList()..sort();
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Muted Sources',
                    style: TextStyle(
                        color: glintText(sheetCtx),
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  muted.isEmpty
                      ? "You haven't muted anything. Long-press a card to mute its source."
                      : 'Tap × to start seeing a source again.',
                  style: TextStyle(color: glintText(sheetCtx, 0.6), fontSize: 13),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: muted.map((m) {
                    return Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      decoration: BoxDecoration(
                        color: glintMuted(sheetCtx, 0.08),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: glintMuted(sheetCtx, 0.14)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(m,
                            style: TextStyle(
                                color: glintText(sheetCtx), fontSize: 13)),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () async {
                            await removeMutedSource(m);
                            setSheet(() {});
                          },
                          child: Icon(Icons.close,
                              size: 16, color: glintText(sheetCtx, 0.6)),
                        ),
                      ]),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        });
      },
    );
    if (mounted) setState(() {}); // refresh subtitle count
  }

  /// Opens the AI Engines manager — paste keys for Gemini, Cerebras, Groq.
  /// The app tries them in that order, falling back to keyless Pollinations.
  Future<void> _openAiEngines() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AiEnginesScreen()),
    );
    if (mounted) setState(() {});
  }

  Widget _settingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final accent = danger ? Colors.redAccent : Colors.lightBlueAccent;
    return SpringScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: accent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: danger ? Colors.redAccent : glintText(context),
                          fontWeight: FontWeight.w600,
                          fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: glintText(context, 0.55), fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// DAILY BRIEF bottom sheet — shows the generated 100-word recap.
// ============================================================
class _BriefSheet extends StatelessWidget {
  final String brief;
  const _BriefSheet({required this.brief});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF15173A), Color(0xFF05060F)]
                : const [Color(0xFFF6FBFC), Color(0xFFE1F1F0)],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 40),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: glintMuted(context, 0.24),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Icon(Icons.auto_awesome, color: glintWarmAccent(context), size: 26),
                const SizedBox(width: 10),
                Text("Today's Brief",
                    style: TextStyle(
                        color: glintText(context),
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "AI-distilled signal across your pinned topics",
              style: TextStyle(color: glintText(context, 0.55), fontSize: 13),
            ),
            const SizedBox(height: 22),
            Text(
              brief,
              style: TextStyle(
                color: glintText(context),
                fontSize: 17,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// RECENTLY SKIPPED — shows left-swiped items. Each row has a
// "Bring back" button that removes it from disliked_titles AND
// from seen_papers so the card can resurface in future fetches.
// ============================================================
class SkippedScreen extends StatefulWidget {
  const SkippedScreen({super.key});
  @override
  State<SkippedScreen> createState() => _SkippedScreenState();
}

class _SkippedScreenState extends State<SkippedScreen> {
  List<Map<String, String>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('disliked_titles') ?? const [];
    final out = <Map<String, String>>[];
    for (final r in raw.reversed) {
      try {
        final m = jsonDecode(r) as Map<String, dynamic>;
        out.add(m.map((k, v) => MapEntry(k, v?.toString() ?? '')));
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _items = out;
      _loading = false;
    });
  }

  Future<void> _bringBack(int index) async {
    HapticFeedback.mediumImpact();
    final prefs = await SharedPreferences.getInstance();
    final title = _items[index]['title'] ?? '';
    final disliked = prefs.getStringList('disliked_titles') ?? <String>[];
    for (int i = disliked.length - 1; i >= 0; i--) {
      try {
        final m = jsonDecode(disliked[i]) as Map<String, dynamic>;
        if ((m['title'] ?? '') == title) {
          disliked.removeAt(i);
          break;
        }
      } catch (_) {}
    }
    await prefs.setStringList('disliked_titles', disliked);
    // Also remove from seen so the card can re-appear in feed.
    final seen = prefs.getStringList('seen_papers') ?? <String>[];
    seen.remove(title);
    await prefs.setStringList('seen_papers', seen);
    await PersonalizationService.instance.refresh();
    unawaited(CloudSyncService.instance.pushDislikes(disliked));
    if (!mounted) return;
    setState(() => _items.removeAt(index));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Brought back — will resurface in your feed'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Recently Skipped',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: glintAccent(context)))
              : _items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history,
                                size: 56, color: glintText(context, 0.30)),
                            const SizedBox(height: 16),
                            Text("Nothing skipped yet.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: glintText(context, 0.7),
                                    fontSize: 16)),
                            const SizedBox(height: 6),
                            Text(
                              "Swipe left on a card to dismiss it. You can always bring it back from here.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: glintText(context, 0.45), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final it = _items[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: glintMuted(context, 0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: glintMuted(context, 0.10)),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(it['title'] ?? '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: glintText(context),
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text(it['source'] ?? '',
                                          style: TextStyle(
                                              color: glintText(context, 0.55),
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SpringScale(
                                  onTap: () => _bringBack(index),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color:
                                          glintAccent(context).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                          color: glintAccent(context)
                                              .withOpacity(0.45)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.undo,
                                            size: 14,
                                            color: glintAccent(context)),
                                        const SizedBox(width: 4),
                                        Text('Bring back',
                                            style: TextStyle(
                                                color: glintAccent(context),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}

// ============================================================
// TTS PLAYER BAR — floats at the bottom of DetailScreen while
// listening. Shows the current sentence, transport controls, and a
// "Find this" button that searches whatever was just spoken.
// ============================================================
class TtsPlayerBar extends StatelessWidget {
  final VoidCallback onSearchHeard;
  final VoidCallback onClose;
  final VoidCallback onToggle;
  const TtsPlayerBar({
    super.key,
    required this.onSearchHeard,
    required this.onClose,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassPanel(
          borderRadius: 22,
          blurSigma: 24,
          tint: glintAccent(context),
          tintOpacity: 0.14,
          borderColor: glintAccent(context).withOpacity(0.4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Live sentence being read.
              ValueListenableBuilder<int>(
                valueListenable: TtsService.instance.currentSentence,
                builder: (context, idx, _) {
                  final s = TtsService.instance.currentSentenceText();
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.graphic_eq, size: 16, color: glintAccent(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.isEmpty ? 'Listening…' : s,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: glintText(context),
                              fontSize: 13,
                              height: 1.35),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _ctrl(context, Icons.skip_previous,
                      () => TtsService.instance.previous()),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<bool>(
                    valueListenable: TtsService.instance.isPlaying,
                    builder: (context, playing, _) => _ctrl(
                      context,
                      playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      onToggle,
                      big: true,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _ctrl(context, Icons.skip_next, () => TtsService.instance.next()),
                  const Spacer(),
                  // "I heard something — find the full story."
                  SpringScale(
                    onTap: onSearchHeard,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: glintAccent(context).withOpacity(0.18),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: glintAccent(context).withOpacity(0.5)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.search, size: 15, color: glintAccent(context)),
                        const SizedBox(width: 5),
                        Text('Find this',
                            style: TextStyle(
                                color: glintAccent(context),
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _ctrl(context, Icons.close, onClose),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ctrl(BuildContext context, IconData icon, VoidCallback onTap,
      {bool big = false}) {
    return SpringScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(icon,
            size: big ? 38 : 26,
            color: big ? glintAccent(context) : glintText(context, 0.8)),
      ),
    );
  }
}

// ============================================================
// GLOBAL SEARCH — searches all cached feed items + Vault. If nothing
// local matches, falls back to a live Google News RSS query. This is
// also where the TTS "Find this" button lands.
// ============================================================
// ============================================================
// AI ENGINES — paste free API keys for the failover chain.
// Order tried: Gemini → Cerebras → Groq → Pollinations (keyless).
// More keys = more reliable; the app uses whichever is available.
// ============================================================
class AiEnginesScreen extends StatefulWidget {
  const AiEnginesScreen({super.key});
  @override
  State<AiEnginesScreen> createState() => _AiEnginesScreenState();
}

class _AiEnginesScreenState extends State<AiEnginesScreen> {
  // provider id → loaded key (or '')
  final Map<String, String> _keys = {'gemini': '', 'cerebras': '', 'groq': ''};
  bool _loading = true;

  static const _meta = [
    {
      'id': 'gemini',
      'name': 'Gemini 2.0 Flash',
      'rank': '1st choice',
      'limit': '1,500 req/day · most reliable',
      'url': 'aistudio.google.com/app/apikey',
      'hint': 'AIza...',
    },
    {
      'id': 'cerebras',
      'name': 'Cerebras',
      'rank': '2nd choice',
      'limit': '~1M tokens/day · fastest',
      'url': 'cloud.cerebras.ai',
      'hint': 'csk-...',
    },
    {
      'id': 'groq',
      'name': 'Groq',
      'rank': '3rd choice',
      'limit': '1,000 req/day · very fast',
      'url': 'console.groq.com/keys',
      'hint': 'gsk_...',
    },
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final id in _keys.keys.toList()) {
      _keys[id] = (await AIService.instance.getKey(id)) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(String id, String name, String hint) async {
    final ctl = TextEditingController(text: _keys[id]);
    final result = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Theme.of(dctx).brightness == Brightness.dark
            ? const Color(0xFF0C1622)
            : Colors.white,
        title: Text(name, style: TextStyle(color: glintText(dctx), fontSize: 18)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: TextStyle(color: glintText(dctx), fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: glintText(dctx, 0.4)),
            filled: true,
            fillColor: glintMuted(dctx, 0.06),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          if ((_keys[id] ?? '').isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dctx, '__CLEAR__'),
              child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text('Cancel', style: TextStyle(color: glintText(dctx, 0.6))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: glintAccent(dctx)),
            child: const Text('Save', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    if (result == null) return;
    final value = result == '__CLEAR__' ? '' : result;
    await AIService.instance.setKey(id, value);
    if (mounted) setState(() => _keys[id] = value);
  }

  @override
  Widget build(BuildContext context) {
    final anyOn = _keys.values.any((v) => v.isNotEmpty);
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('AI Engines', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: glintAccent(context)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    GlassPanel(
                      padding: const EdgeInsets.all(16),
                      tint: anyOn ? glintAccent(context) : glintWarmAccent(context),
                      tintOpacity: 0.10,
                      borderColor: (anyOn ? glintAccent(context) : glintWarmAccent(context))
                          .withOpacity(0.4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(anyOn ? Icons.bolt : Icons.info_outline,
                                color: anyOn ? glintAccent(context) : glintWarmAccent(context),
                                size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                anyOn ? 'Fast AI is on' : 'Add at least one key',
                                style: TextStyle(
                                    color: glintText(context),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Text(
                            'The app tries each engine top-to-bottom. If one is busy or out of quota, the next answers in seconds — no more long waits. Add as many as you like (all free, no card). Pollinations is the keyless last resort.',
                            style: TextStyle(
                                color: glintText(context, 0.7), fontSize: 13, height: 1.5),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (final m in _meta) _engineTile(m),
                    const SizedBox(height: 6),
                    _lastResortTile(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _engineTile(Map<String, String> m) {
    final id = m['id']!;
    final on = (_keys[id] ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SpringScale(
        onTap: () => _edit(id, m['name']!, m['hint']!),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: glintMuted(context, 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: on
                    ? glintAccent(context).withOpacity(0.5)
                    : glintMuted(context, 0.12)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: on
                      ? glintAccent(context).withOpacity(0.18)
                      : glintMuted(context, 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(on ? Icons.check : Icons.add,
                    color: on ? glintAccent(context) : glintText(context, 0.5),
                    size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(m['name']!,
                          style: TextStyle(
                              color: glintText(context),
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: glintMuted(context, 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(m['rank']!,
                            style: TextStyle(
                                color: glintText(context, 0.6), fontSize: 10)),
                      ),
                    ]),
                    const SizedBox(height: 3),
                    Text(m['limit']!,
                        style: TextStyle(color: glintText(context, 0.55), fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(on ? 'Key set — tap to change' : 'Get free at ${m['url']}',
                        style: TextStyle(
                            color: on ? glintAccent(context) : glintText(context, 0.4),
                            fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lastResortTile() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: glintMuted(context, 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glintMuted(context, 0.08)),
      ),
      child: Row(children: [
        Icon(Icons.cloud_off_outlined, size: 18, color: glintText(context, 0.4)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pollinations (keyless)',
                  style: TextStyle(
                      color: glintText(context, 0.6),
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              Text('Always-on last resort — slow but needs no key',
                  style: TextStyle(color: glintText(context, 0.4), fontSize: 11)),
            ],
          ),
        ),
      ]),
    );
  }
}

class SearchScreen extends StatefulWidget {
  final String initialQuery;
  const SearchScreen({super.key, this.initialQuery = ''});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _ctl = TextEditingController();
  List<Map<String, String>> _results = [];
  bool _loading = false;
  bool _searchedWeb = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) {
      // The TTS sentence is long — distill it to keywords for a good query.
      _ctl.text = _distill(widget.initialQuery);
      _run();
    }
  }

  /// Turns a spoken sentence into a tight query: drop stopwords, keep the
  /// most distinctive ~6 words.
  String _distill(String sentence) {
    const stop = {
      'the','a','an','and','or','but','of','to','in','on','for','with','is',
      'are','was','were','be','been','will','would','could','should','that',
      'this','it','as','at','by','from','about','into','than','then','they',
      'their','its','has','have','had','not','no','you','your','we','our',
    };
    final words = sentence
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !stop.contains(w))
        .toList();
    return words.take(6).join(' ');
  }

  Future<void> _run() async {
    final q = _ctl.text.trim().toLowerCase();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _searchedWeb = false;
    });
    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    // 1) Search local caches + vault.
    final pool = await FeedCache.allCachedItems();
    final prefs = await SharedPreferences.getInstance();
    for (final raw in prefs.getStringList('saved_vault') ?? const <String>[]) {
      try {
        final m = (jsonDecode(raw) as Map)
            .map((k, v) => MapEntry('$k', '${v ?? ''}'));
        pool.add(m);
      } catch (_) {}
    }

    int score(Map<String, String> it) {
      final hay =
          '${it['title'] ?? ''} ${it['source'] ?? ''} ${it['summary'] ?? ''}'
              .toLowerCase();
      int s = 0;
      for (final t in terms) {
        if (hay.contains(t)) s++;
      }
      return s;
    }

    final scored = pool
        .map((it) => MapEntry(it, score(it)))
        .where((e) => e.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    var local = scored.map((e) => e.key).take(40).toList();

    // 2) If too few local hits, hit Google News RSS live.
    if (local.length < 3) {
      final web = await _searchGoogleNews(_ctl.text.trim());
      _searchedWeb = true;
      // Merge, dedupe by title.
      final seen = local.map((e) => e['title']).toSet();
      for (final w in web) {
        if (!seen.contains(w['title'])) local.add(w);
      }
    }

    if (!mounted) return;
    setState(() {
      _results = local;
      _loading = false;
    });
  }

  Future<List<Map<String, String>>> _searchGoogleNews(String query) async {
    try {
      final uri = Uri.parse(
          'https://news.google.com/rss/search?q=${Uri.encodeQueryComponent(query)}&hl=en-US&gl=US&ceid=US:en');
      final resp =
          await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return [];
      final doc = xml.XmlDocument.parse(resp.body);
      final items = doc.findAllElements('item').take(20);
      final out = <Map<String, String>>[];
      for (final it in items) {
        String tag(String n) =>
            it.findElements(n).isEmpty ? '' : it.findElements(n).first.innerText;
        final title = tag('title');
        final link = tag('link');
        if (title.isEmpty || link.isEmpty) continue;
        out.add({
          'title': title,
          'url': link,
          'source': tag('source').isEmpty ? 'Google News' : tag('source'),
          'summary': tag('description')
              .replaceAll(RegExp(r'<[^>]*>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        });
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Search', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: TextField(
                  controller: _ctl,
                  autofocus: widget.initialQuery.isEmpty,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _run(),
                  style: TextStyle(color: glintText(context)),
                  decoration: InputDecoration(
                    hintText: 'Search news, topics, sources…',
                    hintStyle: TextStyle(color: glintText(context, 0.45)),
                    prefixIcon: Icon(Icons.search, color: glintText(context, 0.6)),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.arrow_forward, color: glintAccent(context)),
                      onPressed: _run,
                    ),
                    filled: true,
                    fillColor: glintMuted(context, 0.06),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              if (_loading)
                Expanded(
                  child: Center(
                      child: CircularProgressIndicator(color: glintAccent(context))),
                )
              else if (_results.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      _searchedWeb
                          ? 'No results. Try different words.'
                          : 'Type to search across your feeds + the web.',
                      style: TextStyle(color: glintText(context, 0.5)),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final it = _results[i];
                      return SpringScale(
                        onTap: () {
                          final url = it['url'] ?? '';
                          if (url.isNotEmpty) openUrlAsDetail(context, url);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: glintMuted(context, 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: glintMuted(context, 0.10)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(it['title'] ?? '',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: glintText(context),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      height: 1.3)),
                              const SizedBox(height: 6),
                              Text(it['source'] ?? '',
                                  style: TextStyle(
                                      color: glintAccent(context), fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
