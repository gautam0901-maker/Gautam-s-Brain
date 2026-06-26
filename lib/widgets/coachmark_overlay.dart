// First-launch tutorial. Triggered from TechFeedScreen the very first
// time Discover renders; "coachmark_seen" is flipped on dismiss so it
// never reappears. Three pages: swipe → nav → daily brief.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';

class CoachmarkOverlay extends StatefulWidget {
  final VoidCallback onDone;
  const CoachmarkOverlay({super.key, required this.onDone});
  @override
  State<CoachmarkOverlay> createState() => _CoachmarkOverlayState();
}

class _CoachmarkOverlayState extends State<CoachmarkOverlay> {
  int _page = 0;

  static const _steps = [
    _Step(
      icon: Icons.local_fire_department_outlined,
      title: 'Five tabs, one place',
      body: 'Discover surfaces fresh drops in your topics.\nTrending shows 24h hottest.\nNews shows breaking by country.\nVault stores your saves.\nSettings controls personalization.',
    ),
    _Step(
      icon: Icons.auto_awesome,
      title: 'Today\'s Brief',
      body: 'Tap the amber banner on Discover for an AI-generated 60-second recap of what\'s new across your pinned topics.',
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('coachmark_seen', true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_page];
    final isLast = _page == _steps.length - 1;
    return Material(
      color: Colors.black.withOpacity(0.72),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
                decoration: BoxDecoration(
                  color: glintMuted(context, 0.20),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: glintAccent(context).withOpacity(0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: glintAccent(context).withOpacity(0.20),
                      blurRadius: 32,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(step.icon, color: glintAccent(context), size: 52),
                    const SizedBox(height: 16),
                    Text(
                      step.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      step.body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_steps.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active
                          ? glintAccent(context)
                          : Colors.white.withOpacity(0.30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
              const Spacer(),
              Row(
                children: [
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Skip', style: TextStyle(color: Colors.white60)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: glintAccent(context),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    onPressed: () {
                      if (isLast) {
                        _finish();
                      } else {
                        setState(() => _page++);
                      }
                    },
                    child: Text(isLast ? 'Got it' : 'Next',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step {
  final IconData icon;
  final String title;
  final String body;
  const _Step({required this.icon, required this.title, required this.body});
}

/// Helper for callers — flips returns true the very first time, false after.
Future<bool> shouldShowCoachmark() async {
  final prefs = await SharedPreferences.getInstance();
  return !(prefs.getBool('coachmark_seen') ?? false);
}
