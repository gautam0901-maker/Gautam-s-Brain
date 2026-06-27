import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'firebase_options.dart';
import 'screens/launch_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/tech_feed.dart';
import 'screens/trending_and_news.dart';
import 'services/cloud_sync_service.dart';
import 'services/deep_link_service.dart';
import 'services/notification_service.dart';
import 'services/tts_service.dart';
import 'services/user_profile_service.dart';
import 'theme.dart';

/// Global navigator key — lets the deep-link listener push routes from
/// outside the widget tree (cold-start, background → foreground intent).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Fires every time the user taps a nav bar tab. Value = tab index that
/// was tapped. Each tab's State listens; if its own index matches the
/// fired value, it triggers its own refresh. This is how we get the
/// "tap tab = reload" behavior without a custom navigation framework.
final ValueNotifier<int> tabTapTicker = ValueNotifier<int>(-1);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock phones to portrait (the swipe deck + reading UI are designed for it).
  // Tablets/iPads keep all orientations. shortestSide >= 600 ≈ tablet.
  final shortestSide =
      WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.shortestSide /
          WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  if (shortestSide < 600) {
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
  }
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Audio Engine: lock-screen / background controls for Live Listen.
  // Safe even if the user never uses cloud audio (device TTS ignores it).
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.glint.audio',
      androidNotificationChannelName: 'Glint Live Listen',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    );
  } catch (_) {}
  // Read the user's saved theme pref before first paint — avoids a flash.
  await loadThemeModePref();
  // Load muted sources into the in-memory cache so feed filters work
  // from the first fetch.
  await loadMutedSources();
  // Load Live Listen voice prefs (premium cloud voice on/off + which voice).
  await TtsService.instance.loadAudioPrefs();
  // Request high refresh rate (90/120Hz) on supported devices. Safe no-op
  // on phones that only support 60Hz. Wrap in try/catch because the
  // plugin throws on iOS / older Android.
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (_) {}
  // Notifications: first launch auto-asks + enables 3/day nudges;
  // every subsequent launch just reschedules to survive reboots and
  // pick up new pinned topics.
  unawaited(() async {
    try {
      final subs = await loadSubscriptions();
      // ensureRunning requests permission if needed, enables, and schedules.
      // No permanent gating — fixes users who were stuck with notifs off.
      await NotificationService.instance.ensureRunning(subs);
    } catch (_) {}
  }());
  runApp(const GlintApp());
}

class GlintApp extends StatelessWidget {
  const GlintApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the whole MaterialApp when the user changes their theme
    // preference from Settings — themeModeNotifier emits the new value.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Glint',
          navigatorKey: rootNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: glintLightTheme,
          darkTheme: glintDarkTheme,
          themeMode: mode,
          // LaunchScreen handles its own pushReplacement to RootGate.
          // This way the Glint logo Hero animates between routes.
          home: const AnimatedLaunchScreen(),
        );
      },
    );
  }
}

/// Routes based on auth + profile state, AND listens for deep-link
/// URLs (Stage J) — when an incoming URL arrives, opens DetailScreen.
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => RootGateState();
}

class RootGateState extends State<RootGate> {
  StreamSubscription<String>? _linkSub;
  // True once the user taps "Maybe later — just browse" on the login screen.
  bool _guest = false;

  @override
  void initState() {
    super.initState();
    // Listen once for incoming deep links. Wait for the first frame so
    // the navigator is ready when we try to push.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _linkSub = DeepLinkService.instance.incomingArticleUrls().listen((url) {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx != null) openUrlAsDetail(ctx, url);
      });
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data;
        if (user == null) {
          // Signed out → show the login screen, unless the user chose to
          // browse as a guest this session.
          if (_guest) return const MainShell();
          return LoginScreen(onSkip: () => setState(() => _guest = true));
        }
        // Pull cloud state into local prefs on sign-in (idempotent —
        // only fills empty keys, never overwrites local content). When done,
        // tell Discover to reload so freshly-pulled topics show up.
        unawaited(CloudSyncService.instance
            .pullToLocalIfMissing()
            .then((_) => notifySubsChanged()));
        // Re-evaluate when onboarding completes locally (profileGateTicker).
        return ValueListenableBuilder<int>(
          valueListenable: profileGateTicker,
          builder: (context, _, __) {
            return StreamBuilder<UserProfile?>(
              stream: UserProfileService.instance.streamMyProfile(),
              builder: (context, profSnap) {
                // Cloud profile present → straight in.
                if (profSnap.data != null) return const MainShell();
                // No cloud profile yet — check the local "onboarded" flag so a
                // denied/slow Firestore write doesn't trap the user.
                return FutureBuilder<bool>(
                  future: UserProfileService.instance.isOnboardedLocally(),
                  builder: (context, localSnap) {
                    if (localSnap.connectionState == ConnectionState.waiting &&
                        profSnap.connectionState == ConnectionState.waiting) {
                      return const MainShell();
                    }
                    if (localSnap.data == true) return const MainShell();
                    if (profSnap.connectionState == ConnectionState.waiting) {
                      return const MainShell();
                    }
                    return const OnboardingScreen();
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

// ============================================================
// MAIN SHELL — bottom-nav host. IndexedStack so each tab keeps
// its scroll position and in-flight requests.
// ============================================================
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  static const _tabs = <_NavItem>[
    _NavItem(Icons.explore_outlined, Icons.explore, 'Discover'),
    _NavItem(Icons.local_fire_department_outlined, Icons.local_fire_department, 'Trending'),
    _NavItem(Icons.public_outlined, Icons.public, 'News'),
    _NavItem(Icons.folder_special_outlined, Icons.folder_special, 'Vault'),
    _NavItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  // Built once and kept alive by IndexedStack so tab switches are instant.
  final _pages = const [
    TechFeedScreen(),
    TrendingScreen(),
    BreakingNewsScreen(),
    VaultScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _pages),
          // 🎧 Global Live Listen player — floats above the nav bar on every
          // tab whenever audio is active. Driven by the TtsService singleton
          // so controls stay in sync with the DetailScreen player too.
          Positioned(
            left: 0,
            right: 0,
            bottom: 84,
            child: ValueListenableBuilder<bool>(
              valueListenable: TtsService.instance.hasSession,
              builder: (context, active, __) {
                if (!active) return const SizedBox.shrink();
                return const GlintMiniPlayer();
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: GlassNavBar(
        currentIndex: _index,
        items: _tabs,
        onTap: (i) {
          setState(() => _index = i);
          // Even when tapping the SAME tab, value reassignment notifies
          // listeners — that's the "tap = refresh" behavior.
          tabTapTicker.value = -1; // force change so re-taps still notify
          tabTapTicker.value = i;
        },
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem(this.icon, this.selectedIcon, this.label);
}

// ============================================================
// GLASS NAV BAR — pill-style floating bar. Selected tab expands
// to show its label. Re-uses GlassPanel + SpringScale from
// tech_feed.dart for visual consistency.
// ============================================================
class GlassNavBar extends StatelessWidget {
  final int currentIndex;
  final List<_NavItem> items;
  final ValueChanged<int> onTap;
  const GlassNavBar({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Equal-width Expanded children + vertical icon/label layout.
    // Bulletproof on any screen size — never overflows.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: DecoratedBox(
          // Floating shadow under the bar — deeper in dark, softer in light.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : Colors.black54).withOpacity(0.30),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: GlassPanel(
            borderRadius: 34,
            blurSigma: 24,
            tintOpacity: isDark ? 0.16 : 0.55,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == currentIndex;
              return Expanded(
                child: SpringScale(
                  onTap: () => onTap(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.fastEaseInToSlowEaseOut,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.lightBlueAccent.withOpacity(0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          selected ? item.selectedIcon : item.icon,
                          size: 22,
                          color: selected ? Colors.lightBlueAccent : Colors.white60,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.lightBlueAccent : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        ),
      ),
    );
  }
}
