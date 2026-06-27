// Trending tab (last-24h, sorted by engagement) and Breaking News tab
// (country-pickable RSS). Both reuse visual primitives + DetailScreen
// from tech_feed.dart, so we import that file rather than re-implementing.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart' as xml;
import 'tech_feed.dart';
import '../widgets/skeleton.dart';
import '../services/feed_cache.dart';
import '../services/location_service.dart';
import '../theme.dart';

/// Shared bookmark button used by both Trending and News rows. Calls into
/// the same saveItemToVault flow as the swipe-right gesture on Discover, so
/// the personalization signal includes saves from these tabs too.
class _BookmarkButton extends StatefulWidget {
  final Map<String, String> item;
  const _BookmarkButton({required this.item});
  @override
  State<_BookmarkButton> createState() => _BookmarkButtonState();
}

class _BookmarkButtonState extends State<_BookmarkButton> {
  bool _saved = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    isInVault(widget.item['title'] ?? '').then((v) {
      if (mounted) setState(() => _saved = v);
    });
  }

  Future<void> _onTap() async {
    if (_busy || _saved) return;
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      await saveItemToVault(widget.item);
      if (!mounted) return;
      setState(() {
        _saved = true;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Saved to Vault'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 90, left: 16, right: 16),
          duration: const Duration(seconds: 2),
          backgroundColor: glintAccent(context).withOpacity(0.9),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SpringScale(
      onTap: _onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: _busy
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    color: glintAccent(context), strokeWidth: 2),
              )
            : Icon(
                _saved ? Icons.bookmark : Icons.bookmark_border,
                color: _saved ? glintAccent(context) : glintText(context, 0.55),
                size: 22,
              ),
      ),
    );
  }
}

const String _userAgent = 'HiddenAIApp/1.0 (Flutter)';

// SpringIn lives in tech_feed.dart (shared utility).

// ============================================================
// TRENDING SCREEN — top items across our sources in the last
// 24h, sorted by an engagement metric (stars, points, upvotes,
// reactions). List UI, not swipe deck.
// ============================================================
class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});
  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  List<Map<String, String>> items = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFromCacheThenFetch();
  }

  /// Reacts to a long-press card action. Mute/skip drop the row from view;
  /// all show a confirmation toast.
  void _afterCardAction(String result) {
    if (!mounted) return;
    if (result == 'muted' || result == 'skipped') {
      setState(() => items = items.where((it) => !isSourceMuted(it)).toList());
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cardActionLabel(result)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  Future<void> _loadFromCacheThenFetch() async {
    final cached = await FeedCache.read('trending');
    if (!mounted) return;
    if (cached.isNotEmpty) {
      setState(() {
        items = cached.items;
        isLoading = false;
      });
    }
    // Always refresh — cached is shown immediately, fresh comes in behind.
    _fetchTrending();
  }

  Future<void> _fetchTrending() async {
    if (!mounted) return;
    setState(() => isLoading = true);
    try {
      // Pull trending NEWS for the user's pinned topics so non-developers
      // don't get a wall of "how I built X in Rust". Dev sources still load,
      // but the user's interests lead the list.
      final subs = await loadSubscriptions();
      final topicTopics = subs.take(4).toList();
      final batches = await Future.wait<List<Map<String, String>>>([
        ...topicTopics.map((t) => googleNewsTopic(t, take: 6)),
        // Dev sources only get prominence if the user has tech interests
        // (or no topics at all). Otherwise we still fetch a little for variety.
        _trendingGithub(),
        _trendingHN(),
        _trendingReddit(),
        _trendingDevto(),
      ]);
      // News (from topic queries) leads; dev items follow, engagement-sorted.
      final topicNews = <Map<String, String>>[];
      for (int i = 0; i < topicTopics.length; i++) {
        topicNews.addAll(batches[i]);
      }
      final devItems = batches
          .skip(topicTopics.length)
          .expand((b) => b)
          .toList()
        ..sort((a, b) => _engagement(b).compareTo(_engagement(a)));
      // De-dupe by title, news first.
      final seen = <String>{};
      final merged = <Map<String, String>>[];
      for (final it in [...topicNews, ...devItems]) {
        final t = it['title'] ?? '';
        if (t.isEmpty || !seen.add(t)) continue;
        if (isSourceMuted(it)) continue;
        merged.add(it);
      }
      if (!mounted) return;
      final taken = merged.take(50).toList();
      setState(() {
        items = taken;
        isLoading = false;
      });
      FeedCache.write('trending', taken);
    } catch (e) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  /// Pulls a numeric engagement score out of the source-specific summary blob.
  int _engagement(Map<String, String> item) {
    final summary = item['summary'] ?? '';
    final match = RegExp(r'(\d[\d,]*)').firstMatch(summary);
    if (match == null) return 0;
    return int.tryParse(match.group(1)!.replaceAll(',', '')) ?? 0;
  }

  Future<List<Map<String, String>>> _trendingGithub() async {
    try {
      // 3 days back catches more high-star repos (created:>yesterday was
      // missing repos that hadn't accumulated stars yet).
      final since = DateTime.now()
          .subtract(const Duration(days: 3))
          .toIso8601String()
          .split('T')[0];
      final url = Uri.https('api.github.com', '/search/repositories', {
        'q': 'stars:>10 created:>$since',
        'sort': 'stars',
        'order': 'desc',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final list = (jsonDecode(res.body)['items'] as List?) ?? [];
      // Cap to ~5 per source so trending isn't dominated by GitHub.
      return list.take(6).map<Map<String, String>>((r) {
        final stars = r['stargazers_count'].toString();
        final lang = r['language'] ?? 'Mixed';
        final desc = r['description']?.toString() ?? 'No description.';
        final fullName = r['full_name']?.toString() ?? '';
        return {
          'title': r['name'].toString(),
          'summary': '$stars stars in 24h • Built in $lang\n\n$desc',
          'author': r['owner']['login'].toString(),
          'source': 'GitHub 💻',
          'url': r['html_url'].toString(),
          'image': fullName.isNotEmpty
              ? 'https://opengraph.githubassets.com/1/$fullName'
              : '',
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, String>>> _trendingHN() async {
    try {
      // 48h window so we have a substantive popularity-sorted list.
      final cutoffTs = DateTime.now()
              .subtract(const Duration(hours: 48))
              .millisecondsSinceEpoch ~/
          1000;
      final url = Uri.https('hn.algolia.com', '/api/v1/search', {
        'tags': 'story',
        'numericFilters': 'created_at_i>$cutoffTs,points>20',
        'hitsPerPage': '6',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final hits = (jsonDecode(res.body)['hits'] as List?) ?? [];
      return hits.map<Map<String, String>>((h) {
        final title = (h['title'] ?? h['story_title'] ?? '').toString().trim();
        final points = h['points']?.toString() ?? '0';
        final comments = h['num_comments']?.toString() ?? '0';
        final author = (h['author'] ?? 'anon').toString();
        final external = (h['url'] ?? '').toString();
        return {
          'title': title,
          'summary':
              '$points points • $comments comments\n\nTrending on Hacker News today.',
          'author': '@$author on HN',
          'source': 'Hacker News 🟠',
          'url': external.isNotEmpty
              ? external
              : 'https://news.ycombinator.com/item?id=${h['objectID']}',
          'image': '',
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, String>>> _trendingReddit() async {
    try {
      final url = Uri.https(
          'www.reddit.com', '/r/all/top.json', {'t': 'day', 'limit': '8'});
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final children = ((jsonDecode(res.body)['data']?['children']) as List?) ?? [];
      return children.map<Map<String, String>>((c) {
        final d = c['data'] as Map<String, dynamic>;
        final title = (d['title'] ?? '').toString().trim();
        final ups = d['ups']?.toString() ?? '0';
        final comments = d['num_comments']?.toString() ?? '0';
        final sub = (d['subreddit_name_prefixed'] ?? 'r/?').toString();
        final author = (d['author'] ?? 'anon').toString();
        final external = (d['url'] ?? '').toString();
        final permalink = 'https://www.reddit.com${d['permalink'] ?? ''}';
        final isSelf = (d['is_self'] ?? false) == true;
        // Reuse the same preview-image extraction logic by inlining: try preview.
        String image = '';
        try {
          final imgs = d['preview']?['images'] as List?;
          if (imgs != null && imgs.isNotEmpty) {
            image = ((imgs[0]['source']?['url'] as String?) ?? '')
                .replaceAll('&amp;', '&');
          }
        } catch (_) {}
        return {
          'title': title,
          'summary': '$ups upvotes • $comments comments\n\nTop on $sub today.',
          'author': '$sub • u/$author',
          'source': 'Reddit 🔴',
          'url': isSelf ? permalink : (external.isNotEmpty ? external : permalink),
          'image': image,
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, String>>> _trendingDevto() async {
    try {
      final url = Uri.https('dev.to', '/api/articles', {
        'top': '1',
        'per_page': '6',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent, 'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final list = (jsonDecode(res.body) as List?) ?? [];
      return list.map<Map<String, String>>((a) {
        final reactions = a['public_reactions_count']?.toString() ?? '0';
        final readMin = a['reading_time_minutes']?.toString() ?? '?';
        final username = (a['user']?['username'] ?? 'anon').toString();
        return {
          'title': (a['title'] ?? '').toString().trim(),
          'summary':
              '$reactions reactions • $readMin min read\n\n${(a['description'] ?? '').toString().trim()}',
          'author': '@$username on Dev.to',
          'source': 'Dev.to 👩‍💻',
          'url': (a['url'] ?? '').toString(),
          'image': (a['cover_image'] ?? a['social_image'] ?? '').toString(),
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Trending', style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          SpringScale(
            onTap: _fetchTrending,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Icon(Icons.refresh, color: Colors.white70),
            ),
          ),
        ],
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: isLoading
              ? const ListSkeleton(count: 6)
              : items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.cloud_off, color: glintText(context, 0.30), size: 56),
                          const SizedBox(height: 16),
                          Text("No trending items right now.",
                              style: TextStyle(color: glintText(context, 0.7), fontSize: 16)),
                          const SizedBox(height: 6),
                          Text("Check your connection or try again.",
                              style: TextStyle(color: glintText(context, 0.45), fontSize: 13)),
                          const SizedBox(height: 22),
                          SpringScale(
                            onTap: _fetchTrending,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 12),
                              decoration: BoxDecoration(
                                color: glintAccent(context).withOpacity(0.18),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: glintAccent(context).withOpacity(0.55)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.refresh, color: glintAccent(context), size: 18),
                                  const SizedBox(width: 8),
                                  Text("Retry",
                                      style: TextStyle(
                                          color: glintAccent(context),
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _fetchTrending,
                      color: glintAccent(context),
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SpringIn(
                              delayMs: (index * 60).clamp(0, 600),
                              child: SpringScale(
                                onTap: () => Navigator.push(
                                  context,
                                  springRoute(DetailScreen(
                                    paper: item,
                                    backgroundColors: const [
                                      Color(0xFF141E30),
                                      Color(0xFF243B55),
                                    ],
                                  )),
                                ),
                                onLongPress: () async {
                                  final r = await showCardActionSheet(context, item);
                                  if (r == null || !context.mounted) return;
                                  if (r == 'listen') {
                                    await startLiveListen(context, item);
                                  } else {
                                    _afterCardAction(r);
                                  }
                                },
                                child: _TrendingRow(item: item, rank: index + 1),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ),
    );
  }
}

class _TrendingRow extends StatelessWidget {
  final Map<String, String> item;
  final int rank;
  const _TrendingRow({required this.item, required this.rank});

  static const _gradient = [Color(0xFF141E30), Color(0xFF243B55)];

  @override
  Widget build(BuildContext context) {
    // No BackdropFilter on list rows — list rows cover what's behind them
    // anyway, and 7 BackdropFilters visible at 120Hz = guaranteed jank.
    // Use a simple tinted Container instead. IntrinsicHeight lets the row
    // size to its content (variable title length) without overflowing.
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: glintMuted(context, 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: glintMuted(context, 0.10)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 110,
                child: CardThumbnail(
                  key: ValueKey('${item['title'] ?? ''}|${item['url'] ?? ''}'),
                  imageUrl: item['image'] ?? '',
                  articleUrl: item['url'] ?? '',
                  fallbackPrompt: item['title'] ?? '',
                  source: item['source'] ?? '',
                  gradient: _gradient,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('#$rank',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item['source'] ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                  color: glintText(context, 0.6),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.2),
                            ),
                          ),
                          _BookmarkButton(item: item),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item['title'] ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: glintText(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.25),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 12, color: glintText(context, 0.45)),
                          const SizedBox(width: 4),
                          Text(
                            '${FeedCache.readMinutes(item['summary'] ?? '')} min read',
                            style: TextStyle(
                                color: glintText(context, 0.55), fontSize: 11),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              (item['summary'] ?? '').split('\n').first,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: glintAccent(context), fontSize: 12),
                            ),
                          ),
                        ],
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
  }
}

// ============================================================
// BREAKING NEWS SCREEN — country-pickable RSS aggregator.
// Default: WORLD. Country choice persists in SharedPreferences.
// ============================================================
const String _countryKey = 'breaking_country';

class CountryOption {
  final String code;
  final String label;
  final List<Map<String, String>> feeds;
  const CountryOption(this.code, this.label, this.feeds);
}

// Special marker for the location-based "Nearby" chip — feeds list is
// empty because we build the Google News query dynamically from the
// user's resolved city/country.
const String kNearbyCode = 'NEARBY';

// All URLs verified live as of 2026. Reuters RSS was retired in 2020 — gone.
const List<CountryOption> kBreakingCountries = [
  CountryOption(kNearbyCode, '📍 Nearby', []),
  CountryOption('WORLD', '🌍 World', [
    {'url': 'https://feeds.bbci.co.uk/news/world/rss.xml', 'label': 'BBC World'},
    {'url': 'https://feeds.npr.org/1004/rss.xml', 'label': 'NPR World'},
    {'url': 'https://www.aljazeera.com/xml/rss/all.xml', 'label': 'Al Jazeera'},
    {'url': 'https://feeds.skynews.com/feeds/rss/world.xml', 'label': 'Sky News'},
  ]),
  CountryOption('US', '🇺🇸 US', [
    {'url': 'https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml', 'label': 'BBC US'},
    {'url': 'https://feeds.npr.org/1001/rss.xml', 'label': 'NPR US'},
    {'url': 'https://feeds.washingtonpost.com/rss/national', 'label': 'Washington Post'},
  ]),
  CountryOption('IN', '🇮🇳 India', [
    {'url': 'https://feeds.bbci.co.uk/news/world/asia/india/rss.xml', 'label': 'BBC India'},
    {'url': 'https://www.thehindu.com/news/national/feeder/default.rss', 'label': 'The Hindu'},
    {'url': 'https://indianexpress.com/feed/', 'label': 'Indian Express'},
    {'url': 'https://www.ndtv.com/rss/latest', 'label': 'NDTV'},
  ]),
  CountryOption('UK', '🇬🇧 UK', [
    {'url': 'https://feeds.bbci.co.uk/news/uk/rss.xml', 'label': 'BBC UK'},
    {'url': 'https://www.theguardian.com/uk/rss', 'label': 'Guardian UK'},
    {'url': 'https://feeds.skynews.com/feeds/rss/uk.xml', 'label': 'Sky News UK'},
  ]),
];

class BreakingNewsScreen extends StatefulWidget {
  const BreakingNewsScreen({super.key});
  @override
  State<BreakingNewsScreen> createState() => _BreakingNewsScreenState();
}

class _BreakingNewsScreenState extends State<BreakingNewsScreen> {
  String _countryCode = 'WORLD';
  List<Map<String, String>> items = [];
  bool isLoading = true;

  /// Set when 📍 Nearby is selected but location is unavailable. Drives
  /// the empty-state UI ('Allow location' button).
  String _nearbyMessage = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _afterCardAction(String result) {
    if (!mounted) return;
    if (result == 'muted' || result == 'skipped') {
      setState(() => items = items.where((it) => !isSourceMuted(it)).toList());
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cardActionLabel(result)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final code = prefs.getString(_countryKey) ?? 'WORLD';
    setState(() => _countryCode = code);
    // Show cached items for this country instantly, then refresh.
    final cached = await FeedCache.read('news_$code');
    if (!mounted) return;
    if (cached.isNotEmpty) {
      setState(() {
        items = cached.items;
        isLoading = false;
      });
    }
    _fetch();
  }

  CountryOption get _country =>
      kBreakingCountries.firstWhere((c) => c.code == _countryCode,
          orElse: () => kBreakingCountries.first);

  Future<void> _setCountry(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_countryKey, code);
    if (!mounted) return;
    // Show cached items for the new country instantly while fresh fetch runs.
    final cached = await FeedCache.read('news_$code');
    if (!mounted) return;
    setState(() {
      _countryCode = code;
      _nearbyMessage = '';
      if (cached.isNotEmpty) {
        items = cached.items;
        isLoading = false;
      } else {
        items = [];
        isLoading = true;
      }
    });
    _fetch();
  }

  Future<void> _fetch() async {
    if (_countryCode == kNearbyCode) {
      await _fetchNearby();
      return;
    }
    try {
      final batches = await Future.wait(
          _country.feeds.map((f) => _fetchRss(f['url']!, f['label']!)));
      final merged = batches.expand((e) => e).toList();
      final seen = <String>{};
      final unique = <Map<String, String>>[];
      for (final m in merged) {
        final t = m['title'] ?? '';
        if (t.isEmpty || !seen.add(t)) continue;
        if (isSourceMuted(m)) continue; // W.6: respect muted publishers
        unique.add(m);
      }
      if (!mounted) return;
      setState(() {
        items = unique;
        isLoading = false;
      });
      FeedCache.write('news_$_countryCode', unique);
    } catch (_) {
      if (!mounted) return;
      setState(() => isLoading = false);
    }
  }

  Future<void> _fetchNearby() async {
    // Try cache first to avoid prompting on every tab switch.
    Locality? loc = await LocationService.instance.readCached();
    loc ??= await LocationService.instance.resolveLocality();
    if (!mounted) return;
    if (loc == null) {
      setState(() {
        items = [];
        _nearbyMessage = 'Allow location access so we can show news from where you are.';
        isLoading = false;
      });
      return;
    }
    try {
      // City news via Google News RSS — keyless, accepts any query.
      final iso = loc.iso.isNotEmpty ? loc.iso : 'US';
      final query = loc.city.isNotEmpty ? loc.city : (loc.state.isNotEmpty ? loc.state : loc.country);
      final url = Uri.https('news.google.com', '/rss/search', {
        'q': query,
        'hl': 'en-$iso',
        'gl': iso,
        'ceid': '$iso:en',
      });
      final res = await http
          .get(url, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          items = [];
          _nearbyMessage = 'Google News returned ${res.statusCode}. Try again later.';
          isLoading = false;
        });
        return;
      }
      final doc = xml.XmlDocument.parse(res.body);
      String stripHtml(String s) => s
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final parsed = doc.findAllElements('item').take(25).map<Map<String, String>>((item) {
        final title = item.findElements('title').isEmpty
            ? ''
            : item.findElements('title').first.innerText.trim();
        final desc = item.findElements('description').isEmpty
            ? ''
            : item.findElements('description').first.innerText;
        final link = item.findElements('link').isEmpty
            ? ''
            : item.findElements('link').first.innerText.trim();
        final source = item.findElements('source').isEmpty
            ? '📍 ${loc!.city}'
            : item.findElements('source').first.innerText.trim();
        return {
          'title': title,
          'summary': stripHtml(desc),
          'author': '📍 ${loc!.city}',
          'source': source,
          'url': link,
          'image': '',
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
      if (!mounted) return;
      setState(() {
        items = parsed;
        _nearbyMessage = '';
        isLoading = false;
      });
      FeedCache.write('news_NEARBY', parsed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        items = [];
        _nearbyMessage = 'Failed to load news for ${loc?.city ?? "your area"}.';
        isLoading = false;
      });
    }
  }

  Future<void> _retryWithPermission() async {
    setState(() => isLoading = true);
    final loc = await LocationService.instance.resolveLocality();
    if (!mounted) return;
    if (loc == null) {
      setState(() {
        items = [];
        _nearbyMessage =
            'Location permission still off. Enable it in Settings → Apps → Hidden AI → Permissions.';
        isLoading = false;
      });
      return;
    }
    await _fetchNearby();
  }

  Future<List<Map<String, String>>> _fetchRss(String url, String label) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];
      final doc = xml.XmlDocument.parse(res.body);
      final rssItems = doc.findAllElements('item').toList();
      String stripHtml(String s) => s
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      String? firstImg(xml.XmlElement el) {
        for (final t in el.findAllElements('thumbnail')) {
          final u = t.getAttribute('url');
          if (u != null && u.isNotEmpty) return u;
        }
        for (final enc in el.findAllElements('enclosure')) {
          final type = enc.getAttribute('type') ?? '';
          final u = enc.getAttribute('url');
          if (u != null && type.startsWith('image/')) return u;
        }
        for (final tag in ['description', 'encoded']) {
          for (final n in el.findAllElements(tag)) {
            final m = RegExp(r'''<img[^>]+src=["']([^"']+)["']''',
                    caseSensitive: false)
                .firstMatch(n.innerText);
            if (m != null) return m.group(1);
          }
        }
        return null;
      }

      return rssItems.take(15).map<Map<String, String>>((item) {
        final title = item.findElements('title').isEmpty
            ? ''
            : item.findElements('title').first.innerText.trim();
        final desc = item.findElements('description').isEmpty
            ? ''
            : item.findElements('description').first.innerText;
        final link = item.findElements('link').isEmpty
            ? ''
            : item.findElements('link').first.innerText.trim();
        return {
          'title': title,
          'summary': stripHtml(desc),
          'author': label,
          'source': label,
          'url': link,
          'image': firstImg(item) ?? '',
        };
      }).where((m) => m['title']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Breaking', style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          SpringScale(
            onTap: _fetch,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Icon(Icons.refresh, color: Colors.white70),
            ),
          ),
        ],
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: kBreakingCountries.map((c) {
                    final selected = c.code == _countryCode;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SpringScale(
                        onTap: () => _setCountry(c.code),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 240),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: selected
                                ? glintAccent(context).withOpacity(0.18)
                                : glintMuted(context, 0.05),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color: selected
                                    ? glintAccent(context).withOpacity(0.55)
                                    : glintMuted(context, 0.12)),
                          ),
                          child: Text(
                            c.label,
                            style: TextStyle(
                              color: selected ? glintAccent(context) : glintText(context, 0.75),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: isLoading
                    ? const ListSkeleton(count: 6)
                    : items.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 32),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _countryCode == kNearbyCode
                                        ? Icons.location_off
                                        : Icons.cloud_off,
                                    color: glintText(context, 0.30),
                                    size: 56,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _countryCode == kNearbyCode
                                        ? 'Nearby news needs location'
                                        : 'No news right now.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: glintText(context, 0.7), fontSize: 16),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _nearbyMessage.isNotEmpty
                                        ? _nearbyMessage
                                        : 'Try a different country or retry.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: glintText(context, 0.45), fontSize: 13),
                                  ),
                                  const SizedBox(height: 22),
                                  SpringScale(
                                    onTap: _countryCode == kNearbyCode
                                        ? _retryWithPermission
                                        : _fetch,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 22, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: glintAccent(context).withOpacity(0.18),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                            color: glintAccent(context).withOpacity(0.55)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _countryCode == kNearbyCode
                                                ? Icons.location_on_outlined
                                                : Icons.refresh,
                                            color: glintAccent(context),
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _countryCode == kNearbyCode
                                                ? 'Allow location'
                                                : 'Retry',
                                            style: TextStyle(
                                                color: glintAccent(context),
                                                fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _fetch,
                            color: glintAccent(context),
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(14, 4, 14, 100),
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                final item = items[index];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: SpringIn(
                                    delayMs: (index * 60).clamp(0, 600),
                                    child: SpringScale(
                                      onTap: () => Navigator.push(
                                        context,
                                        springRoute(DetailScreen(
                                          paper: item,
                                          backgroundColors: const [
                                            Color(0xFF141E30),
                                            Color(0xFF243B55),
                                          ],
                                        )),
                                      ),
                                      onLongPress: () async {
                                        final r = await showCardActionSheet(context, item);
                                        if (r == null || !context.mounted) return;
                                        if (r == 'listen') {
                                          await startLiveListen(context, item);
                                        } else {
                                          _afterCardAction(r);
                                        }
                                      },
                                      child: _NewsRow(item: item),
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

class _NewsRow extends StatelessWidget {
  final Map<String, String> item;
  const _NewsRow({required this.item});

  static const _gradient = [Color(0xFF0A0E1F), Color(0xFF112C4A)];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: glintMuted(context, 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: glintMuted(context, 0.10)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 110,
                child: CardThumbnail(
                  key: ValueKey('${item['title'] ?? ''}|${item['url'] ?? ''}'),
                  imageUrl: item['image'] ?? '',
                  articleUrl: item['url'] ?? '',
                  fallbackPrompt: item['title'] ?? '',
                  source: item['source'] ?? '',
                  gradient: _gradient,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (item['source'] ?? '').toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: glintAccent(context),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8),
                            ),
                          ),
                          _BookmarkButton(item: item),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item['title'] ?? '',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: glintText(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.25),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 12, color: glintText(context, 0.45)),
                          const SizedBox(width: 4),
                          Text(
                            '${FeedCache.readMinutes(item['summary'] ?? '')} min read',
                            style: TextStyle(
                                color: glintText(context, 0.55), fontSize: 11),
                          ),
                        ],
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
  }
}
