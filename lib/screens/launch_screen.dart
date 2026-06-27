// Animated launch screen. Cold start sequence:
//   1. (system) Android draws blank window
//   2. (flutter_native_splash) static dark navy + logo painted natively
//   3. main() runs, Firebase init
//   4. THIS widget animates in over the same colors, then yields to _RootGate
//
// Sequencing AnimatedLaunchScreen after the native splash means there's
// no perceptible flash — the logo position is identical, only the
// animation comes alive.

import 'package:flutter/material.dart';
import '../main.dart' show RootGate;
import '../widgets/glint_logo.dart';
import 'tech_feed.dart' show AnimatedAuroraBackground;

class AnimatedLaunchScreen extends StatefulWidget {
  const AnimatedLaunchScreen({super.key});
  @override
  State<AnimatedLaunchScreen> createState() => _AnimatedLaunchScreenState();
}

class _AnimatedLaunchScreenState extends State<AnimatedLaunchScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoCtl;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _taglineOpacity;
  late final Animation<Offset> _titleOffset;
  late final Animation<Offset> _taglineOffset;

  @override
  void initState() {
    super.initState();
    // Master controller: 0.0 → 1.0 over 1.4s drives the whole reveal.
    _logoCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..forward();

    // Logo: 0..0.55 of the timeline. Scales from 0.5 with overshoot.
    _logoScale = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(parent: _logoCtl, curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack)),
    );
    _logoOpacity = CurvedAnimation(
      parent: _logoCtl,
      curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
    );

    // Title: 0.30..0.70.
    _titleOpacity = CurvedAnimation(
      parent: _logoCtl,
      curve: const Interval(0.30, 0.70, curve: Curves.easeOut),
    );
    _titleOffset = Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _logoCtl,
            curve: const Interval(0.30, 0.70, curve: Curves.fastEaseInToSlowEaseOut)));

    // Tagline: 0.55..0.95.
    _taglineOpacity = CurvedAnimation(
      parent: _logoCtl,
      curve: const Interval(0.55, 0.95, curve: Curves.easeOut),
    );
    _taglineOffset = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _logoCtl,
            curve: const Interval(0.55, 0.95, curve: Curves.fastEaseInToSlowEaseOut)));

    // After the reveal + brief hold, push RootGate with a clean fade +
    // gentle scale. No Hero — that was lagging because of the route
    // morphing over BackdropFilter / glow layers. This feels smooth.
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const RootGate(),
          transitionDuration: const Duration(milliseconds: 650),
          reverseTransitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (_, anim, __, child) {
            final curved = CurvedAnimation(
              parent: anim,
              curve: Curves.fastEaseInToSlowEaseOut,
            );
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                // Subtle 0.98 → 1.0 scale-up — feels like the app "settling in"
                // rather than a hard cut. Cheap on the GPU.
                scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        ),
      );
    });
  }

  @override
  void dispose() {
    _logoCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF03040A),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Shared Hero logo — flies to the login screen on the
                // route transition when the user is signed out.
                AnimatedBuilder(
                  animation: _logoCtl,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _logoScale.value,
                      child: Opacity(opacity: _logoOpacity.value, child: child),
                    );
                  },
                  child: const GlintLogoHero(size: 120),
                ),
                const SizedBox(height: 32),
                FadeTransition(
                  opacity: _titleOpacity,
                  child: SlideTransition(
                    position: _titleOffset,
                    child: const Text(
                      'Glint',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: _taglineOpacity,
                  child: SlideTransition(
                    position: _taglineOffset,
                    child: Text(
                      'Catch what others miss.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 15,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
