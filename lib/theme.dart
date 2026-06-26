// Glint visual identity, derived from the hummingbird logo:
//   - Primary teal `glintTeal` (main color of the bird's body)
//   - Soft cyan `glintGlow`  (its lit chest highlight)
//   - Deep navy `glintDeep`  (the dark backdrop the logo sits on)
//   - Cream `glintCream`     (a daytime variant of the navy)
//
// We expose:
//   - Color constants for one-off use
//   - `glintLightTheme` + `glintDarkTheme` for MaterialApp
//   - `themeModeNotifier` so the Settings toggle can flip themes live
//
// The aurora bg and glass panels also pull their palettes from these
// constants, so changing the theme switches the whole app coherently.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/cupertino.dart';
// ---- raw palette -----------------------------------------------------
const Color glintTeal       = Color(0xFF2BD9CD); // bird body teal
const Color glintTealDeep   = Color(0xFF1A9087); // for contrast on light bg
const Color glintGlow       = Color(0xFFA8ECE3); // chest highlight
const Color glintStar       = Color(0xFFE9F7FF); // sparkle / accent
const Color glintDeep       = Color(0xFF050B14); // dark mode background
const Color glintDeepLifted = Color(0xFF0E1A2A); // dark mode surface
const Color glintCream      = Color(0xFFF0F7F8); // light mode background
const Color glintCreamLift  = Color(0xFFFFFFFF); // light mode surface
const Color glintInkDark    = Color(0xFF06131C); // light mode text
const Color glintInkLight   = Color(0xFFEAF3F4); // dark mode text

// ---- aurora gradient palettes used by AnimatedAuroraBackground -----
const List<Color> glintAuroraDark = [
  Color(0xFF02080F),
  Color(0xFF0A2030),
  Color(0xFF134B4F),
  Color(0xFF03060C),
];
const List<Color> glintAuroraLight = [
  Color(0xFFF1F8F9),
  Color(0xFFD5EEEC),
  Color(0xFFBBE6E2),
  Color(0xFFEEF6F7),
];

// ---- themes ---------------------------------------------------------
final ThemeData glintDarkTheme = ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  scaffoldBackgroundColor: glintDeep,
  colorScheme: const ColorScheme.dark(
    primary: glintTeal,
    onPrimary: glintInkDark,
    secondary: glintGlow,
    onSecondary: glintInkDark,
    surface: glintDeepLifted,
    onSurface: glintInkLight,
    error: Color(0xFFFF6B6B),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    surfaceTintColor: Colors.transparent,
    foregroundColor: glintInkLight,
  ),
  splashFactory: InkRipple.splashFactory,
  pageTransitionsTheme: const PageTransitionsTheme(builders: {
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  }),
);

final ThemeData glintLightTheme = ThemeData(
  brightness: Brightness.light,
  useMaterial3: true,
  scaffoldBackgroundColor: glintCream,
  colorScheme: const ColorScheme.light(
    primary: glintTealDeep,
    onPrimary: Colors.white,
    secondary: glintTeal,
    onSecondary: glintInkDark,
    surface: glintCreamLift,
    onSurface: glintInkDark,
    error: Color(0xFFD93838),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    surfaceTintColor: Colors.transparent,
    foregroundColor: glintInkDark,
  ),
  splashFactory: InkRipple.splashFactory,
  pageTransitionsTheme: const PageTransitionsTheme(builders: {
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  }),
);

// ---- theme mode notifier --------------------------------------------
/// MaterialApp listens to this and rebuilds when the user picks
/// System / Light / Dark in Settings.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

const String _themePrefsKey = 'app_theme_mode';

Future<void> loadThemeModePref() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_themePrefsKey);
  themeModeNotifier.value = switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

Future<void> saveThemeModePref(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_themePrefsKey, switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  });
}

// ---- theme-aware text & accent helpers ------------------------------
/// Returns the right text color for the current theme at the given opacity.
/// Use everywhere instead of hardcoded `Colors.white` / `Colors.black`.
Color glintText(BuildContext c, [double opacity = 1.0]) {
  final isDark = Theme.of(c).brightness == Brightness.dark;
  return (isDark ? glintInkLight : glintInkDark).withOpacity(opacity);
}

/// Cyan brand accent that's vibrant on dark but deep enough to read on
/// light. Use for headings, links, and the "you're in Glint" highlights.
Color glintAccent(BuildContext c) {
  final isDark = Theme.of(c).brightness == Brightness.dark;
  return isDark ? glintTeal : glintTealDeep;
}

/// Theme-aware muted fill for chip backgrounds, divider lines, etc.
/// Returns a translucent white in dark mode and translucent black in light.
Color glintMuted(BuildContext c, [double opacity = 0.06]) {
  final isDark = Theme.of(c).brightness == Brightness.dark;
  return (isDark ? Colors.white : Colors.black).withOpacity(opacity);
}

/// Warm "intelligence" accent — used by Today's Brief and AI panels.
/// Returns a bright amber on dark and a deeper saturated orange on light
/// so the text is legible on both backgrounds.
Color glintWarmAccent(BuildContext c) {
  final isDark = Theme.of(c).brightness == Brightness.dark;
  return isDark ? const Color(0xFFFFD54F) : const Color(0xFFD97706);
}

// ---- system chrome helper -------------------------------------------
/// Status bar + nav bar contrast matched to the current theme. Call once
/// per frame from a widget that has Theme access (we do it in MainShell).
void syncSystemChromeToTheme(Brightness brightness) {
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness:
        brightness == Brightness.dark ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness:
        brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  ));
}
