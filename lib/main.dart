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
      ),
      home: const TechFeedScreen(),
    );
  }
}