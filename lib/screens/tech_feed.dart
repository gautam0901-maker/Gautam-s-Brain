import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

// AI brain now runs on Pollinations (keyless public endpoint) — see PollinationsAI below.
class PollinationsAI {
  static const String _endpoint = 'https://text.pollinations.ai/';

  static Future<String?> generate(String prompt, {String model = 'openai'}) async {
    return chat([
      {'role': 'user', 'content': prompt},
    ], model: model);
  }

  static Future<String?> chat(
    List<Map<String, String>> messages, {
    String model = 'openai',
  }) async {
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
          .timeout(const Duration(seconds: 45));
      if (response.statusCode == 200) {
        return response.body.trim();
      }
      print('Pollinations HTTP ${response.statusCode}: ${response.body}');
    } catch (e) {
      print('Pollinations error: $e');
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

const List<Map<String, String>> _rssFeeds = [
  {'url': 'https://huggingface.co/blog/feed.xml', 'label': 'HuggingFace 🤗'},
  {'url': 'https://techcrunch.com/feed/', 'label': 'TechCrunch 🚀'},
  {'url': 'https://www.theverge.com/rss/index.xml', 'label': 'The Verge 📰'},
  {'url': 'https://feeds.arstechnica.com/arstechnica/index', 'label': 'Ars Technica 🔬'},
  {'url': 'https://www.wired.com/feed/tag/ai/latest/rss', 'label': 'Wired AI 🔌'},
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
    final palette = widget.palette ??
        const [
          Color(0xFF05060F),
          Color(0xFF0B1A3F),
          Color(0xFF1C0B40),
          Color(0xFF03040A),
        ];
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
    final t = tint ?? Colors.white;
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
                color: borderColor ?? Colors.white.withOpacity(0.14),
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
  final double pressedScale;
  const SpringScale({super.key, required this.child, this.onTap, this.pressedScale = 0.93});
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
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
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
  
  // Default Search Queries
  String arxivSearchQuery = 'cat:cs.AI';
  String githubSearchQuery = 'topic:artificial-intelligence';

  @override
  void initState() {
    super.initState();
    _updateStreak();
    fetchLatestAITech();
  }

  // 🔮 THE AI HORIZON SCANNER FUNCTION
  Future<void> _scanTheHorizon() async {
    setState(() {
      isScanning = true;
      horizonTopics = []; // Clear old topics
    });

    const prompt =
        "You are a tech futurist. Tell me exactly 3 hyper-niche, highly advanced, bleeding-edge AI subfields that are about to blow up, but aren't mainstream yet (e.g., Quantum Machine Learning, Liquid Neural Networks). Return ONLY a comma-separated list of the 3 topics. No intro, no bullet points, no extra text.";

    final result = await PollinationsAI.generate(prompt);

    if (!mounted) return;
    if (result != null && result.isNotEmpty) {
      setState(() {
        horizonTopics = result
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(3)
            .toList();
        isScanning = false;
      });
    } else {
      setState(() => isScanning = false);
    }
  }

  // 🎯 HUNT DOWN THE UNKNOWN TECH
  void _huntSpecificTopic(String topic) {
    setState(() {
      isLoading = true;
      currentFeedTitle = "Hunting: $topic";
      // 🚀 Rewrite the API URLs to search for the specific AI topic!
      arxivSearchQuery = 'all:"$topic"';
      githubSearchQuery = '"$topic"';
      horizonTopics = []; // Hide the chips once we start searching
    });

    // Pass topic through so HN + Reddit also search; 30-day window for arXiv/GitHub.
    fetchLatestAITech(daysBack: 30, topic: topic);
  }

  Future<void> _updateStreak() async {
    final prefs = await SharedPreferences.getInstance();
    String? lastDate = prefs.getString('last_opened_date');
    int streak = prefs.getInt('current_streak') ?? 0;
    String today = DateTime.now().toIso8601String().split('T')[0];
    
    if (lastDate == null) {
      streak = 1;
    } else if (lastDate != today) {
      DateTime last = DateTime.parse(lastDate);
      DateTime current = DateTime.parse(today);
      if (current.difference(last).inDays == 1) {
        streak += 1;
      } else {
        streak = 1;
      }
    }
    await prefs.setString('last_opened_date', today);
    await prefs.setInt('current_streak', streak);
  }

  Future<void> fetchLatestAITech({int daysBack = 7, String? topic}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenTitles = (prefs.getStringList('seen_papers') ?? <String>[]).toSet();
      final isTopicMode = topic != null && topic.isNotEmpty;

      // Fire all sources in parallel — slowest wins.
      final batches = await Future.wait<List<Map<String, String>>>([
        _fetchArxiv(),
        _fetchGithub(daysBack: daysBack),
        _fetchHackerNews(topic: topic),
        _fetchReddit(topic: topic),
        // RSS doesn't support search, so skip it in topic-hunt mode.
        if (!isTopicMode) _fetchAllRss() else Future.value(<Map<String, String>>[]),
      ]);

      final combined = <Map<String, String>>[];
      final localSeen = <String>{};
      for (final batch in batches) {
        for (final item in batch) {
          final title = item['title'] ?? '';
          if (title.isEmpty) continue;
          if (seenTitles.contains(title)) continue;
          if (!localSeen.add(title)) continue;
          combined.add(item);
        }
      }

      combined.shuffle();
      if (!mounted) return;
      setState(() {
        papers = combined;
        isLoading = false;
      });
    } catch (e) {
      print("⚠️ fetchLatestAITech error: $e");
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  // ---------------- SOURCE FETCHERS ----------------

  Future<List<Map<String, String>>> _fetchArxiv() async {
    try {
      final url =
          'https://export.arxiv.org/api/query?search_query=$arxivSearchQuery&sortBy=submittedDate&sortOrder=descending&max_results=20';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final doc = xml.XmlDocument.parse(res.body);
      return doc.findAllElements('entry').map<Map<String, String>>((entry) {
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

  Future<List<Map<String, String>>> _fetchGithub({required int daysBack}) async {
    try {
      final safeQuery = githubSearchQuery.replaceAll(' ', '+');
      final pastDate = DateTime.now().subtract(Duration(days: daysBack)).toIso8601String().split('T')[0];
      final url =
          'https://api.github.com/search/repositories?q=$safeQuery+created:>$pastDate&sort=stars&order=desc';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final items = (jsonDecode(res.body)['items'] as List?) ?? [];
      return items.take(20).map<Map<String, String>>((repo) {
        final lang = repo['language'] ?? 'Mixed';
        final stars = repo['stargazers_count'].toString();
        final desc = repo['description']?.toString() ?? 'No description.';
        return {
          'title': repo['name'].toString(),
          'summary': "⭐ Trending with $stars Stars\n💻 Built in: $lang\n\n$desc",
          'author': repo['owner']['login'].toString(),
          'source': 'GitHub 💻',
          'url': repo['html_url'].toString(),
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
      final query = hasTopic ? '&query=${Uri.encodeQueryComponent(topic)}' : '';
      // search_by_date for freshness; tags=story to skip comments.
      final url = 'https://hn.algolia.com/api/v1/search_by_date?tags=story$query&hitsPerPage=15';
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
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
      return children.map<Map<String, String>>((c) {
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
            ? (selftext.length > 400 ? '${selftext.substring(0, 400)}…' : selftext)
            : "⬆️ $ups upvotes • 💬 $comments comments\n\nDiscussion on $sub.";
        return {
          'title': title,
          'summary': summary,
          'author': '$sub • u/$author',
          'source': 'Reddit 🔴',
          'url': isSelf ? permalink : (externalUrl.isNotEmpty ? externalUrl : permalink),
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (e) {
      print('Reddit JSON parse failed: $e');
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
      // Try RSS 2.0 <item> first, then Atom <entry>.
      final rssItems = doc.findAllElements('item').toList();
      if (rssItems.isNotEmpty) {
        return rssItems.take(8).map<Map<String, String>>((item) {
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
          };
        }).where((m) => m['title']!.isNotEmpty).toList();
      }
      // Atom fallback.
      return doc.findAllElements('entry').take(8).map<Map<String, String>>((entry) {
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("🤖 AI is categorizing this intel..."), duration: Duration(seconds: 1)));
    String category = "Uncategorized";

    final prompt =
        "Read this title and abstract. Reply with exactly ONE short category tag (max 2 words). Do not use hashtags or punctuation.\n\nTitle: ${paper['title']}\nAbstract: ${paper['summary']}";
    final result = await PollinationsAI.generate(prompt);
    if (result != null && result.isNotEmpty) {
      final cleaned = result.trim().replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '').trim();
      if (cleaned.isNotEmpty) {
        category = cleaned.length > 30 ? cleaned.substring(0, 30) : cleaned;
      }
    }

    paper['category'] = category;
    final prefs = await SharedPreferences.getInstance();
    List<String> savedItems = prefs.getStringList('saved_vault') ?? [];
    savedItems.add(jsonEncode(paper));
    await prefs.setStringList('saved_vault', savedItems);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("📁 Saved to folder: $category"), backgroundColor: Colors.green, duration: const Duration(seconds: 2)));
    }
  }

  bool _onSwipe(int previousIndex, int? currentIndex, CardSwiperDirection direction) {
    final paper = papers[previousIndex];
    markAsSeen(paper['title']!);
    if (direction == CardSwiperDirection.right) saveToVault(paper); 
    return true; 
  }

  // Reset to the general feed
  void _resetFeed() {
    setState(() {
      isLoading = true;
      currentFeedTitle = "General AI Feed";
      arxivSearchQuery = 'cat:cs.AI';
      githubSearchQuery = 'topic:artificial-intelligence';
      horizonTopics = [];
    });
    fetchLatestAITech();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text("Gautam's Brain", style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          SpringScale(
            onTap: _resetFeed,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.refresh, color: Colors.white70),
            ),
          ),
          SpringScale(
            onTap: () {
              Navigator.push(context, springRoute(const VaultScreen())).then((_) {
                setState(() => isLoading = true);
                fetchLatestAITech();
              });
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.folder_special, color: Colors.lightBlueAccent),
            ),
          ),
        ],
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              // 🔭 HORIZON SCANNER — frosted glass header
              GlassPanel(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                tint: Colors.cyanAccent,
                tintOpacity: 0.08,
                borderColor: Colors.cyanAccent.withOpacity(0.25),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            currentFeedTitle,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.cyanAccent,
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
                                color: Colors.cyanAccent.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.radar, size: 16, color: Colors.cyanAccent),
                                  SizedBox(width: 6),
                                  Text("Scan Horizon",
                                      style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          )
                        else
                          const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2),
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

              // THE SWIPE DECK
              Expanded(
                child: isLoading
                    ? const Center(child: CircularProgressIndicator(color: Colors.lightBlueAccent))
                    : papers.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.search_off, color: Colors.grey, size: 60),
                                const SizedBox(height: 16),
                                const Text("No intel found on this.",
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
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
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text("Swipe Right to Save  →   ←   Swipe Left to Skip",
                                    style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w500, letterSpacing: 0.4)),
                              ),
                              Expanded(
                                child: CardSwiper(
                                  controller: swiperController,
                                  cardsCount: papers.length,
                                  onSwipe: _onSwipe,
                                  allowedSwipeDirection: const AllowedSwipeDirection.symmetric(horizontal: true),
                                  numberOfCardsDisplayed: 3,
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
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                              decoration: BoxDecoration(
                                                color: paper['source']!.contains('GitHub')
                                                    ? Colors.black54
                                                    : Colors.redAccent.withOpacity(0.6),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Text(paper['source']!,
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 12)),
                                            ),
                                            const SizedBox(height: 16),
                                            Text(paper['title']!,
                                                style: const TextStyle(
                                                    fontSize: 24,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                    height: 1.2)),
                                            const SizedBox(height: 12),
                                            Text("👤 ${paper['author']}",
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    fontStyle: FontStyle.italic,
                                                    color: Colors.lightBlueAccent)),
                                            const SizedBox(height: 20),
                                            Text(paper['summary']!,
                                                maxLines: 6,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 15,
                                                    color: Colors.white.withOpacity(0.85),
                                                    height: 1.5)),
                                          ],
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
            ],
          ),
        ),
      ),
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
  int currentStreak = 0; 
  final TextEditingController searchController = TextEditingController();
  List<String> availableCategories = ['All'];
  String selectedCategory = 'All';

  @override
  void initState() {
    super.initState();
    loadVault();
  }

  Future<void> loadVault() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> savedItems = prefs.getStringList('saved_vault') ?? [];
    int streak = prefs.getInt('current_streak') ?? 1;
    
    Set<String> uniqueCategories = {'All'};
    List<Map<String, String>> loadedPapers = [];

    for (var item in savedItems) {
      final decoded = jsonDecode(item) as Map<String, dynamic>;
      final paper = decoded.map((key, value) => MapEntry(key, value.toString()));
      loadedPapers.add(paper);
      uniqueCategories.add(paper['category'] ?? 'Uncategorized');
    }

    setState(() {
      currentStreak = streak;
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
        title: const Text("My Intel Vault 🏦", style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: AnimatedAuroraBackground(
        palette: const [
          Color(0xFF02050E),
          Color(0xFF12224A),
          Color(0xFF1E1336),
          Color(0xFF03040A),
        ],
        child: SafeArea(
          child: Column(
            children: [
              GlassPanel(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(20),
                tint: Colors.lightBlueAccent,
                tintOpacity: 0.08,
                borderColor: Colors.blueAccent.withOpacity(0.30),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(children: [
                      const Text("🔥 STREAK",
                          style: TextStyle(
                              color: Colors.white60, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      const SizedBox(height: 8),
                      Text("$currentStreak Days",
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                    ]),
                    Container(height: 40, width: 1, color: Colors.white24),
                    Column(children: [
                      const Text("🧠 INTEL",
                          style: TextStyle(
                              color: Colors.white60, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                      const SizedBox(height: 8),
                      Text("${savedPapers.length} Saved",
                          style: const TextStyle(
                              color: Colors.lightBlueAccent, fontSize: 24, fontWeight: FontWeight.bold)),
                    ]),
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
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: "Search your Second Brain...",
                      hintStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(Icons.search, color: Colors.lightBlueAccent),
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
                                ? Colors.amberAccent
                                : Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.amberAccent
                                  : Colors.white.withOpacity(0.14),
                            ),
                          ),
                          child: Text(
                            category,
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white,
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
                    ? const Center(
                        child: Text("No intel found in this folder.",
                            style: TextStyle(color: Colors.white54, fontSize: 18)))
                    : ListView.builder(
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
                                              style: const TextStyle(
                                                  color: Colors.white, fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 8),
                                          Row(children: [
                                            const Icon(Icons.sell, size: 14, color: Colors.amberAccent),
                                            const SizedBox(width: 4),
                                            Text(aiTag,
                                                style: const TextStyle(
                                                    color: Colors.amberAccent,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12)),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text("• ${paper['source']}",
                                                  style: const TextStyle(
                                                      color: Colors.lightBlueAccent,
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
  List<Map<String, String>> chatHistory = [];
  bool isTyping = false;
  late List<Map<String, String>> _conversation;

  @override
  void initState() {
    super.initState();
    _conversation = [
      {
        'role': 'system',
        'content':
            "You are an expert AI coding and research assistant. Answer questions based ONLY on this context: ${widget.paper['summary']}. Keep your answers brief, punchy, and highly informative.",
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
    final response = await PollinationsAI.chat(_conversation);

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

  @override
  Widget build(BuildContext context) {
    final isGithub = widget.paper['source']!.contains('GitHub');
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: AnimatedAuroraBackground(
        palette: widget.backgroundColors.length >= 2
            ? [
                widget.backgroundColors.first,
                widget.backgroundColors[widget.backgroundColors.length ~/ 2],
                widget.backgroundColors.last,
                const Color(0xFF03040A),
              ]
            : null,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 250,
              floating: false,
              pinned: true,
              backgroundColor: widget.backgroundColors.last.withOpacity(0.7),
              elevation: 0,
              actions: [
                SpringScale(
                  onTap: () => Share.share(
                    "Just discovered this bleeding-edge AI intel:\n\n🤖 ${widget.paper['title']}\n\n🔗 Read it here: ${widget.paper['url']}\n\n(Found via my custom Hidden AI app)",
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Icon(Icons.share, color: Colors.white),
                  ),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsets.only(left: 20, bottom: 16, right: 20),
                title: const Text("Intelligence Report",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                background: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: widget.backgroundColors,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: Icon(Icons.memory, size: 100, color: Colors.white.withOpacity(0.1)),
                  ),
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
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, height: 1.2)),
                    const SizedBox(height: 16),
                    Text("Source: ${widget.paper['source']}",
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                    const SizedBox(height: 8),
                    Text("By: ${widget.paper['author']!}",
                        style: const TextStyle(
                            fontSize: 16, fontStyle: FontStyle.italic, color: Colors.lightBlueAccent)),
                    const SizedBox(height: 24),
                    SpringScale(
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
                            Icon(isGithub ? Icons.code : Icons.picture_as_pdf,
                                color: isGithub ? Colors.black : Colors.white),
                            const SizedBox(width: 10),
                            Text(
                              isGithub ? "OPEN REPOSITORY" : "READ FULL PAPER",
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                  color: isGithub ? Colors.black : Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    GlassPanel(
                      padding: const EdgeInsets.all(20),
                      borderRadius: 18,
                      blurSigma: 16,
                      tint: Colors.purpleAccent,
                      tintOpacity: 0.10,
                      borderColor: Colors.purpleAccent.withOpacity(0.45),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(children: [
                            Icon(Icons.auto_awesome, color: Colors.amberAccent),
                            SizedBox(width: 8),
                            Text("INTERROGATE THE INTEL",
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    letterSpacing: 1.2)),
                          ]),
                          const SizedBox(height: 16),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: [
                              SpringScale(
                                onTap: () => _sendMessage("Explain this to me like I'm a 5-year-old."),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.amberAccent,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text("Explain Like I'm 5 🍼",
                                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SpringScale(
                                onTap: () => _sendMessage("What is the single core problem this solves?"),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.16),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white.withOpacity(0.25)),
                                  ),
                                  child: const Text("Core Concept? 🎯",
                                      style: TextStyle(color: Colors.white)),
                                ),
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
                                return AnimatedSlide(
                                  offset: Offset.zero,
                                  duration: const Duration(milliseconds: 320),
                                  curve: Curves.fastEaseInToSlowEaseOut,
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isUser
                                          ? Colors.blueAccent.withOpacity(0.20)
                                          : Colors.black.withOpacity(0.40),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: isUser
                                            ? Colors.blueAccent.withOpacity(0.5)
                                            : Colors.white.withOpacity(0.08),
                                      ),
                                    ),
                                    child: Text(
                                      "${isUser ? '👤 You: ' : '🤖 Assistant: '}${msg['text']}",
                                      style: TextStyle(
                                          color: isUser ? Colors.lightBlueAccent : Colors.white,
                                          fontSize: 15,
                                          height: 1.4),
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (isTyping)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: CircularProgressIndicator(color: Colors.amberAccent),
                            ),
                          TextField(
                            controller: _chatController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: "Ask a question...",
                              hintStyle: const TextStyle(color: Colors.white54),
                              filled: true,
                              fillColor: Colors.black.withOpacity(0.40),
                              suffixIcon: SpringScale(
                                onTap: () => _sendMessage(_chatController.text),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 12),
                                  child: Icon(Icons.send, color: Colors.amberAccent),
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
                    ),
                    const SizedBox(height: 30),
                    GlassPanel(
                      padding: const EdgeInsets.all(18),
                      borderRadius: 14,
                      blurSigma: 12,
                      tintOpacity: 0.06,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("ORIGINAL ABSTRACT",
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white60,
                                  letterSpacing: 1.5)),
                          const SizedBox(height: 16),
                          Text(widget.paper['summary']!,
                              style: const TextStyle(fontSize: 16, color: Colors.white70, height: 1.8)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 50),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}