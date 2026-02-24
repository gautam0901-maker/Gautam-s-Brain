import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

// 🛑 1. PASTE YOUR API KEY RIGHT HERE!
const String globalApiKey = 'AIzaSyBmCLin6HPQ2x2u5drE7vbnB__SgFNTUCY';

final List<List<Color>> cardGradients = [
  [const Color(0xFF0f0c29), const Color(0xFF302b63), const Color(0xFF24243e)], 
  [const Color(0xFF141E30), const Color(0xFF243B55)], 
  [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)], 
  [const Color(0xFF000000), const Color(0xFF434343)], 
  [const Color(0xFF1F1C2C), const Color(0xFF928DAB)], 
];

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

    try {
      final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: globalApiKey);
      final prompt = "You are a tech futurist. Tell me exactly 3 hyper-niche, highly advanced, bleeding-edge AI subfields that are about to blow up, but aren't mainstream yet (e.g., Quantum Machine Learning, Liquid Neural Networks). Return ONLY a comma-separated list of the 3 topics. No intro, no bullet points, no extra text.";
      
      final response = await model.generateContent([Content.text(prompt)]);
      
      if (response.text != null) {
        setState(() {
          // Split the comma-separated list into a Flutter List!
          horizonTopics = response.text!.split(',').map((e) => e.trim()).toList();
          isScanning = false;
        });
      }
    } catch (e) {
      print("Horizon Scan Failed: $e");
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
    
    fetchLatestAITech(daysBack: 30); // We look 30 days back for super rare niche stuff!
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

  Future<void> fetchLatestAITech({int daysBack = 7}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> seenTitles = prefs.getStringList('seen_papers') ?? [];
      List<Map<String, String>> combinedFeed = [];

      // ARXIV (Dynamic Query!)
      final arxivUrl = 'https://export.arxiv.org/api/query?search_query=$arxivSearchQuery&sortBy=submittedDate&sortOrder=descending&max_results=20';
      final arxivRes = await http.get(Uri.parse(arxivUrl), headers: {"User-Agent": "HiddenAIApp/1.0"}).timeout(const Duration(seconds: 15));
      if (arxivRes.statusCode == 200) {
        final document = xml.XmlDocument.parse(arxivRes.body);
        final entries = document.findAllElements('entry');
        for (var entry in entries) {
          final title = entry.findElements('title').first.innerText.replaceAll('\n', ' ').trim();
          if (!seenTitles.contains(title)) {
            combinedFeed.add({
              'title': title,
              'summary': entry.findElements('summary').first.innerText.replaceAll('\n', ' ').trim(),
              'author': entry.findElements('author').first.findElements('name').first.innerText,
              'source': 'arXiv 📄',
              'url': entry.findElements('id').first.innerText.trim(),
            });
          }
        }
      }

      // GITHUB (Dynamic Query!)
      // Ensure spaces are formatted correctly for the web URL
      final safeGithubQuery = githubSearchQuery.replaceAll(' ', '+');
      final pastDate = DateTime.now().subtract(Duration(days: daysBack)).toIso8601String().split('T')[0];
      final githubUrl = 'https://api.github.com/search/repositories?q=$safeGithubQuery+created:>$pastDate&sort=stars&order=desc';
      
      final ghRes = await http.get(Uri.parse(githubUrl), headers: {"User-Agent": "HiddenAIApp/1.0"}).timeout(const Duration(seconds: 15));
      if (ghRes.statusCode == 200) {
        final data = jsonDecode(ghRes.body);
        final items = data['items'] as List;
        for (var i = 0; i < items.length && i < 20; i++) {
          final repo = items[i];
          final title = repo['name'].toString();
          if (!seenTitles.contains(title)) {
            final lang = repo['language'] ?? 'Mixed';
            final stars = repo['stargazers_count'].toString();
            final desc = repo['description']?.toString() ?? "No description.";
            combinedFeed.add({
              'title': title,
              'summary': "⭐ Trending with $stars Stars\n💻 Built in: $lang\n\n$desc",
              'author': repo['owner']['login'].toString(),
              'source': 'GitHub 💻',
              'url': repo['html_url'].toString(), 
            });
          }
        }
      }

      combinedFeed.shuffle();
      setState(() { papers = combinedFeed; isLoading = false; });
    } catch (e) {
      print("⚠️ ERROR: $e");
      setState(() => isLoading = false);
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

    try {
      final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: globalApiKey);
      final prompt = "Read this title and abstract. Reply with exactly ONE short category tag (max 2 words). Do not use hashtags or punctuation. \n\nTitle: ${paper['title']}\nAbstract: ${paper['summary']}";
      final response = await model.generateContent([Content.text(prompt)]);
      if (response.text != null && response.text!.isNotEmpty) {
        category = response.text!.trim().replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '');
      }
    } catch (e) {
      print("Categorization failed: $e");
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
      appBar: AppBar(
        title: Text('Gautam\'s Brain', style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _resetFeed, // Button to go back to normal feed
          ),
          IconButton(
            icon: const Icon(Icons.folder_special, color: Colors.blueAccent),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => const VaultScreen())).then((_) {
                setState(() => isLoading = true);
                fetchLatestAITech();
              });
            },
          )
        ],
      ),
      backgroundColor: Colors.black, 
      body: Column(
        children: [
          // 🔭 THE HORIZON SCANNER UI
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blueGrey[900]?.withOpacity(0.3),
              border: Border(bottom: BorderSide(color: Colors.cyanAccent.withOpacity(0.2), width: 1))
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(currentFeedTitle, style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    if (!isScanning)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent.withOpacity(0.1), foregroundColor: Colors.cyanAccent, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.cyanAccent.withOpacity(0.5)))),
                        icon: const Icon(Icons.radar, size: 18),
                        label: const Text("Scan Horizon"),
                        onPressed: _scanTheHorizon,
                      )
                    else
                      const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2)),
                  ],
                ),
                
                // Show the 3 Futuristic Topics generated by AI
                if (horizonTopics.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: horizonTopics.map((topic) => Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: ActionChip(
                            backgroundColor: Colors.black,
                            side: const BorderSide(color: Colors.purpleAccent),
                            labelStyle: const TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold),
                            label: Text("🚀 $topic"),
                            onPressed: () => _huntSpecificTopic(topic), // Tap to hack the APIs!
                          ),
                        )).toList(),
                      ),
                    ),
                  )
              ],
            ),
          ),

          // THE SWIPE DECK
          Expanded(
            child: isLoading 
              ? const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
              : papers.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.search_off, color: Colors.grey, size: 60),
                          const SizedBox(height: 16),
                          const Text("No intel found on this.", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 24),
                          ElevatedButton(onPressed: _resetFeed, child: const Text("Return to General Feed"))
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        const Padding(padding: EdgeInsets.symmetric(vertical: 12.0), child: Text("Swipe Right to Save ➡️ | ⬅️ Swipe Left to Skip", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500))),
                        Expanded(
                          child: CardSwiper(
                            controller: swiperController,
                            cardsCount: papers.length,
                            onSwipe: _onSwipe,
                            allowedSwipeDirection: const AllowedSwipeDirection.symmetric(horizontal: true),
                            numberOfCardsDisplayed: 3,
                            cardBuilder: (context, index, percentThresholdX, percentThresholdY) {
                              final paper = papers[index];
                              final currentGradient = cardGradients[index % cardGradients.length];

                              return GestureDetector(
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => DetailScreen(paper: paper, backgroundColors: currentGradient))),
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(24),
                                    gradient: LinearGradient(colors: currentGradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
                                    boxShadow: [BoxShadow(color: currentGradient.last.withOpacity(0.5), blurRadius: 15, offset: const Offset(0, 8))],
                                  ),
                                  padding: const EdgeInsets.all(24.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(color: paper['source']!.contains('GitHub') ? Colors.black54 : Colors.redAccent.withOpacity(0.6), borderRadius: BorderRadius.circular(8)),
                                        child: Text(paper['source']!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(paper['title']!, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white, height: 1.2)),
                                      const SizedBox(height: 12),
                                      Text("👤 ${paper['author']}", style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: Colors.lightBlueAccent)),
                                      const SizedBox(height: 20),
                                      Text(paper['summary']!, maxLines: 6, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: Colors.white.withOpacity(0.85), height: 1.5)),
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
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("My Intel Vault 🏦", style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.black, elevation: 0),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF141E30), Color(0xFF243B55)]), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.blueAccent.withOpacity(0.3))),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(children: [const Text("🔥 STREAK", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2)), const SizedBox(height: 8), Text("$currentStreak Days", style: const TextStyle(color: Colors.orangeAccent, fontSize: 24, fontWeight: FontWeight.bold))]),
                Container(height: 40, width: 1, color: Colors.white24), 
                Column(children: [const Text("🧠 INTEL", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, letterSpacing: 1.2)), const SizedBox(height: 8), Text("${savedPapers.length} Saved", style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 24, fontWeight: FontWeight.bold))]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(controller: searchController, onChanged: (val) => filterVault(), style: const TextStyle(color: Colors.white), decoration: InputDecoration(hintText: "Search your Second Brain...", hintStyle: const TextStyle(color: Colors.white54), prefixIcon: const Icon(Icons.search, color: Colors.blueAccent), filled: true, fillColor: Colors.white.withOpacity(0.1), border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 0))),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: availableCategories.length,
              itemBuilder: (context, index) {
                final category = availableCategories[index];
                final isSelected = category == selectedCategory;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(category, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
                    selected: isSelected, selectedColor: Colors.amberAccent, backgroundColor: Colors.white.withOpacity(0.1),
                    onSelected: (selected) { setState(() { selectedCategory = category; filterVault(); }); },
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: displayedPapers.isEmpty
                ? const Center(child: Text("No intel found in this folder.", style: TextStyle(color: Colors.grey, fontSize: 18)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12), itemCount: displayedPapers.length,
                    itemBuilder: (context, index) {
                      final paper = displayedPapers[index];
                      final aiTag = paper['category'] ?? 'Uncategorized';
                      return Card(
                        color: Colors.grey[900], margin: const EdgeInsets.only(bottom: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16), title: Text(paper['title']!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Row(children: [const Icon(Icons.sell, size: 14, color: Colors.amberAccent), const SizedBox(width: 4), Text(aiTag, style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)), const SizedBox(width: 8), Expanded(child: Text("• ${paper['source']}", style: const TextStyle(color: Colors.blueAccent, overflow: TextOverflow.ellipsis)))]),
                          ),
                          trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () => deleteFromVault(index)),
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => DetailScreen(paper: paper, backgroundColors: cardGradients[0]))),
                        ),
                      );
                    },
                  ),
          ),
        ],
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
  late ChatSession chatSession;

  @override
  void initState() {
    super.initState();
    _initAI();
  }

  void _initAI() {
    final model = GenerativeModel(model: 'gemini-2.5-flash', apiKey: globalApiKey, systemInstruction: Content.system("You are an expert AI coding and research assistant. Answer questions based ONLY on this context: ${widget.paper['summary']}. Keep your answers brief, punchy, and highly informative."));
    chatSession = model.startChat();
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    setState(() { chatHistory.add({'role': 'user', 'text': text}); isTyping = true; });
    _chatController.clear();
    FocusScope.of(context).unfocus();

    try {
      final response = await chatSession.sendMessage(Content.text(text));
      setState(() { chatHistory.add({'role': 'ai', 'text': response.text ?? "Error."}); isTyping = false; });
    } catch (e) {
      setState(() { chatHistory.add({'role': 'ai', 'text': "⚠️ Connection error."}); isTyping = false; });
    }
  }

  Future<void> _launchURL() async {
    final Uri url = Uri.parse(widget.paper['url']!);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) { print('Could not launch $url'); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, 
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 250.0, floating: false, pinned: true, backgroundColor: widget.backgroundColors.last, 
            actions: [IconButton(icon: const Icon(Icons.share, color: Colors.white), onPressed: () => Share.share("Just discovered this bleeding-edge AI intel:\n\n🤖 ${widget.paper['title']}\n\n🔗 Read it here: ${widget.paper['url']}\n\n(Found via my custom Hidden AI app)"))],
            flexibleSpace: FlexibleSpaceBar(titlePadding: const EdgeInsets.only(left: 20, bottom: 16, right: 20), title: const Text("Intelligence Report", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), background: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: widget.backgroundColors, begin: Alignment.topLeft, end: Alignment.bottomRight)), child: Center(child: Icon(Icons.memory, size: 100, color: Colors.white.withOpacity(0.1))))),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.paper['title']!, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, height: 1.2)),
                  const SizedBox(height: 16), Text("Source: ${widget.paper['source']}", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orangeAccent)), const SizedBox(height: 8), Text("By: ${widget.paper['author']!}", style: const TextStyle(fontSize: 16, fontStyle: FontStyle.italic, color: Colors.lightBlueAccent)),
                  const SizedBox(height: 24),
                  SizedBox(width: double.infinity, height: 55, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: widget.paper['source']!.contains('GitHub') ? Colors.white : Colors.redAccent, foregroundColor: widget.paper['source']!.contains('GitHub') ? Colors.black : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), icon: Icon(widget.paper['source']!.contains('GitHub') ? Icons.code : Icons.picture_as_pdf), label: Text(widget.paper['source']!.contains('GitHub') ? "OPEN REPOSITORY" : "READ FULL PAPER", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2)), onPressed: _launchURL)),
                  const SizedBox(height: 30),
                  Container(
                    width: double.infinity, padding: const EdgeInsets.all(20), decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.purple[900]!, Colors.deepPurple[800]!]), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.purpleAccent.withOpacity(0.5), width: 2), boxShadow: [BoxShadow(color: Colors.purple.withOpacity(0.3), blurRadius: 10, spreadRadius: 2)]),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(children: [Icon(Icons.auto_awesome, color: Colors.amberAccent), SizedBox(width: 8), Text("INTERROGATE THE INTEL", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.2))]),
                        const SizedBox(height: 16),
                        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [ActionChip(backgroundColor: Colors.amberAccent, labelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold), label: const Text("Explain Like I'm 5 🍼"), onPressed: () => _sendMessage("Explain this to me like I'm a 5-year-old.")), const SizedBox(width: 8), ActionChip(backgroundColor: Colors.white24, labelStyle: const TextStyle(color: Colors.white), label: const Text("Core Concept? 🎯"), onPressed: () => _sendMessage("What is the single core problem this solves?"))])),
                        const SizedBox(height: 16),
                        if (chatHistory.isNotEmpty) ListView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: chatHistory.length, itemBuilder: (context, index) { final msg = chatHistory[index]; final isUser = msg['role'] == 'user'; return Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: isUser ? Colors.blueAccent.withOpacity(0.2) : Colors.black45, borderRadius: BorderRadius.circular(12), border: Border.all(color: isUser ? Colors.blueAccent.withOpacity(0.5) : Colors.transparent)), child: Text("${isUser ? '👤 You: ' : 'Gautam"s Assistant: '}${msg['text']}", style: TextStyle(color: isUser ? Colors.lightBlueAccent : Colors.white, fontSize: 15, height: 1.4))); }),
                        if (isTyping) const Padding(padding: EdgeInsets.only(bottom: 12.0), child: CircularProgressIndicator(color: Colors.amberAccent)),
                        TextField(controller: _chatController, style: const TextStyle(color: Colors.white), decoration: InputDecoration(hintText: "Ask a question...", hintStyle: const TextStyle(color: Colors.white54), filled: true, fillColor: Colors.black45, suffixIcon: IconButton(icon: const Icon(Icons.send, color: Colors.amberAccent), onPressed: () => _sendMessage(_chatController.text)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)), onSubmitted: _sendMessage)
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),
                  Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("ORIGINAL ABSTRACT", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.5)), const SizedBox(height: 16), Text(widget.paper['summary']!, style: const TextStyle(fontSize: 16, color: Colors.white70, height: 1.8))])),
                  const SizedBox(height: 50), 
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}