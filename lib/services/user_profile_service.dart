// Per-user profile (profession, interest domains, country) stored at
// users/{uid} in Firestore. Drives feed personalization.
//
// Required Firestore rules (paste alongside the comments rules):
//   match /users/{uid} {
//     allow read, write: if request.auth != null && request.auth.uid == uid;
//   }

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bumped after onboarding completes so RootGate re-evaluates and leaves the
/// onboarding screen even when the Firestore write is slow/denied.
final ValueNotifier<int> profileGateTicker = ValueNotifier<int>(0);

/// Source categories — each fetched item carries one. Profession picks
/// determine which categories show in Discover.
enum SourceCategory { code, news, research, social, product }

/// Map from our source labels to a category. Keep in sync with the
/// label strings we use in tech_feed.dart fetchers.
const Map<String, SourceCategory> sourceCategoryByLabel = {
  'arXiv 📄': SourceCategory.research,
  'GitHub 💻': SourceCategory.code,
  'Hacker News 🟠': SourceCategory.social,
  'Reddit 🔴': SourceCategory.social,
  'Dev.to 👩‍💻': SourceCategory.code,
  'HuggingFace 🤗': SourceCategory.research,
  'TechCrunch 🚀': SourceCategory.news,
  'The Verge 📰': SourceCategory.news,
  'Ars Technica 🔬': SourceCategory.news,
  'Wired AI 🔌': SourceCategory.news,
  'Lobsters 🦞': SourceCategory.code,
  'Product Hunt 🏹': SourceCategory.product,
  // Stage I additions
  'Engadget 🎧': SourceCategory.news,
  'VentureBeat 💼': SourceCategory.news,
  'Fast Company ⚡': SourceCategory.news,
  'MIT Tech Review 🎓': SourceCategory.research,
  'Quanta Magazine 🔭': SourceCategory.research,
  'IEEE Spectrum ⚡': SourceCategory.research,
  'Google AI 🧠': SourceCategory.research,
  'DeepMind 🧠': SourceCategory.research,
  // Round 2
  'The Register 🧙': SourceCategory.news,
  '9to5Mac 🍎': SourceCategory.news,
  '9to5Google 🅖': SourceCategory.news,
  'Crunchbase 💰': SourceCategory.news,
  'Sifted 🇪🇺': SourceCategory.news,
  'Nature 🧬': SourceCategory.research,
  'Slashdot ⌨️': SourceCategory.social,
};

class Profession {
  final String id; // stable, stored in Firestore
  final String label;
  final String description;
  final Set<SourceCategory> allowedCategories;
  const Profession(this.id, this.label, this.description, this.allowedCategories);
}

const List<Profession> kProfessions = [
  Profession(
    'developer',
    '💻 Developer',
    'Code, repos, papers, dev discussions',
    {SourceCategory.code, SourceCategory.research, SourceCategory.social, SourceCategory.product},
  ),
  Profession(
    'manager',
    '📊 Manager / PM',
    'Industry news, product launches, strategy',
    {SourceCategory.news, SourceCategory.product, SourceCategory.social},
  ),
  Profession(
    'researcher',
    '🔬 Researcher',
    'Papers, deep technical, breakthroughs',
    {SourceCategory.research, SourceCategory.code, SourceCategory.social},
  ),
  Profession(
    'student',
    '🎓 Student',
    'Mix of everything, beginner-friendly',
    {SourceCategory.code, SourceCategory.research, SourceCategory.social, SourceCategory.news, SourceCategory.product},
  ),
  Profession(
    'teacher',
    '📚 Teacher / Educator',
    'News, research, accessible explainers',
    {SourceCategory.news, SourceCategory.research, SourceCategory.social},
  ),
  Profession(
    'other',
    '🌍 Other / Curious',
    'All sources, unfiltered',
    {SourceCategory.code, SourceCategory.research, SourceCategory.social, SourceCategory.news, SourceCategory.product},
  ),
];

/// Topic suggestions shown in the onboarding domain picker, grouped by
/// field so users across ALL interests find themselves — not just tech.
/// Multi-select; selected ones auto-pin as topic subscriptions. Users can
/// also type their own in the free-text box.
const Map<String, List<String>> kInterestGroups = {
  'Tech & AI': [
    'Artificial Intelligence', 'Machine Learning', 'Data Science',
    'Web Development', 'Mobile Development', 'DevOps & Cloud',
    'Cybersecurity', 'Blockchain & Web3', 'Quantum Computing',
    'Robotics', 'Hardware & IoT', 'Game Development',
  ],
  'Science': [
    'Space & Astronomy', 'Physics', 'Biology', 'Chemistry',
    'Neuroscience', 'Climate & Environment', 'Medicine', 'Genetics',
    'Mathematics', 'Psychology',
  ],
  'Business & Money': [
    'Startups', 'Venture Capital', 'Stock Market', 'Crypto',
    'Economy', 'Personal Finance', 'Real Estate', 'Marketing',
    'Product Management', 'Entrepreneurship',
  ],
  'World & Society': [
    'World News', 'Politics', 'Geopolitics', 'Law',
    'Education', 'Social Issues', 'History', 'Philosophy',
  ],
  'Lifestyle': [
    'Health & Fitness', 'Food & Cooking', 'Travel', 'Fashion',
    'Design & UX', 'Photography', 'Productivity', 'Parenting',
  ],
  'Sports': [
    'Football / Soccer', 'Cricket', 'Basketball', 'Formula 1',
    'Tennis', 'Esports', 'NFL', 'Cycling',
  ],
  'Entertainment': [
    'Movies & TV', 'Music', 'Gaming', 'Books',
    'Anime', 'Celebrities', 'Streaming', 'Art',
  ],
  'Cars & Tech Gear': [
    'Cars', 'Electric Vehicles', 'Motorcycles', 'Gadgets',
    'Smartphones', 'Aviation', 'Drones',
  ],
};

/// Flat list of all suggestions (used where a single list is handy).
final List<String> kDomainSuggestions =
    kInterestGroups.values.expand((e) => e).toList();

class CountryOpt {
  final String code;
  final String label;
  const CountryOpt(this.code, this.label);
}

const List<CountryOpt> kProfileCountries = [
  CountryOpt('US', '🇺🇸 United States'),
  CountryOpt('IN', '🇮🇳 India'),
  CountryOpt('UK', '🇬🇧 United Kingdom'),
  CountryOpt('DE', '🇩🇪 Germany'),
  CountryOpt('FR', '🇫🇷 France'),
  CountryOpt('JP', '🇯🇵 Japan'),
  CountryOpt('CN', '🇨🇳 China'),
  CountryOpt('AU', '🇦🇺 Australia'),
  CountryOpt('CA', '🇨🇦 Canada'),
  CountryOpt('BR', '🇧🇷 Brazil'),
  CountryOpt('WORLD', '🌍 Prefer not to say'),
];

class UserProfile {
  final String professionId;
  final List<String> domains;
  final String countryCode;
  // "Understanding You" extras (iOS launch).
  final String interests; // free-text: what the user wants to follow
  final String depth;     // 'quick' | 'balanced' | 'deep'
  final DateTime? updatedAt;
  const UserProfile({
    required this.professionId,
    required this.domains,
    required this.countryCode,
    this.interests = '',
    this.depth = 'balanced',
    this.updatedAt,
  });

  Profession get profession =>
      kProfessions.firstWhere((p) => p.id == professionId,
          orElse: () => kProfessions.last);

  Set<SourceCategory> get allowedSourceCategories => profession.allowedCategories;

  Map<String, dynamic> toMap() => {
        'professionId': professionId,
        'domains': domains,
        'countryCode': countryCode,
        'interests': interests,
        'depth': depth,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  factory UserProfile.fromMap(Map<String, dynamic> m) => UserProfile(
        professionId: (m['professionId'] ?? 'other').toString(),
        domains: ((m['domains'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        countryCode: (m['countryCode'] ?? 'WORLD').toString(),
        interests: (m['interests'] ?? '').toString(),
        depth: (m['depth'] ?? 'balanced').toString(),
        updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
      );
}

class UserProfileService {
  UserProfileService._();
  static final UserProfileService instance = UserProfileService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>>? _myDoc() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid);
  }

  /// Lightweight in-memory cache so consumers don't have to await every call.
  UserProfile? _cached;
  UserProfile? get cached => _cached;

  /// Live stream of the signed-in user's profile. Emits null when signed out
  /// or when the doc doesn't exist yet.
  Stream<UserProfile?> streamMyProfile() async* {
    await for (final user in FirebaseAuth.instance.authStateChanges()) {
      if (user == null) {
        _cached = null;
        yield null;
        continue;
      }
      yield* _db
          .collection('users')
          .doc(user.uid)
          .snapshots()
          .map<UserProfile?>((snap) {
        if (!snap.exists) {
          _cached = null;
          return null;
        }
        final p = UserProfile.fromMap(snap.data() ?? {});
        _cached = p;
        return p;
      });
    }
  }

  /// Per-uid local "onboarding finished" flag. The cloud profile is the
  /// source of truth, but this lets the user INTO the app even if the
  /// Firestore write was denied (rules not published) or offline — so they
  /// never get stuck on the onboarding screen.
  Future<bool> isOnboardedLocally() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('onboarded_$uid') ?? false;
  }

  Future<void> markOnboardedLocally(UserProfile profile) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarded_$uid', true);
    _cached = profile; // so feed personalization has it immediately
  }

  Future<UserProfile?> loadOnce() async {
    final doc = _myDoc();
    if (doc == null) return null;
    final snap = await doc.get();
    if (!snap.exists) return null;
    final p = UserProfile.fromMap(snap.data() ?? {});
    _cached = p;
    return p;
  }

  /// Writes the profile. Forces an ID-token refresh first so a stale token
  /// can't silently cause PERMISSION_DENIED (the most common production
  /// failure mode for write-on-cold-start scenarios).
  Future<void> save(UserProfile profile) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-signed-in',
        message: 'You need to be signed in to save your profile.',
      );
    }
    // Force a fresh token. Without this, a token issued at app launch but
    // stale by the time of save can be rejected by Firestore rules even
    // though the local SDK thinks the user is "signed in".
    try {
      await user.getIdToken(true);
    } catch (_) {
      // Non-fatal: continue with the cached token. Save() below will
      // surface the real failure if it still doesn't work.
    }
    final doc = _db.collection('users').doc(user.uid);
    try {
      await doc.set(profile.toMap(), SetOptions(merge: true));
      _cached = profile;
    } on FirebaseException catch (e) {
      // Re-throw with a clearer code so the UI can show something useful.
      throw FirebaseException(
        plugin: e.plugin,
        code: e.code,
        message: e.code == 'permission-denied'
            ? "Firestore rejected the write (permission-denied). "
                "Check that Firestore Rules for 'users/{uid}' allow the signed-in user."
            : e.message,
      );
    }
  }
}
