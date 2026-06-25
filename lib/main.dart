import 'package:flutter/material.dart';
import 'screens/tech_feed.dart';

void main() {
  runApp(const HiddenAIApp());
}

class HiddenAIApp extends StatelessWidget {
  const HiddenAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hidden AI Tech',
      debugShowCheckedModeBanner: false, // Removes the little "DEBUG" banner
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        useMaterial3: true,
        // Transparent scaffold lets AnimatedAuroraBackground show through everywhere.
        scaffoldBackgroundColor: const Color(0xFF03040A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        splashFactory: InkRipple.splashFactory,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: const TechFeedScreen(),
    );
  }
}