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
import 'tech_feed.dart' show AnimatedAuroraBackground;

class AnimatedLaunchScreen extends StatefulWidget {
  const AnimatedLaunchScreen({super.key});
  @override
  State<AnimatedLaunchScreen> createState() => _AnimatedLaunchScreenState();
}

class _AnimatedLaunchScreenState extends State<AnimatedLaunchScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoCtl;
  late final AnimationController _glowCtl;
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

    // Continuous gentle pulse for the logo's outer glow.
    _glowCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

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
    _glowCtl.dispose();
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
                // Logo + pulsing glow. The Hero around the image lets it
                // morph into the small AppBar logo on Discover during the
                // route transition.
                AnimatedBuilder(
                  animation: Listenable.merge([_logoCtl, _glowCtl]),
                  builder: (context, _) {
                    final glow = 0.35 + _glowCtl.value * 0.25;
                    return Transform.scale(
                      scale: _logoScale.value,
                      child: Opacity(
                        opacity: _logoOpacity.value,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            color: Colors.white.withOpacity(0.04),
                            border: Border.all(color: Colors.white.withOpacity(0.10)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.cyanAccent.withOpacity(glow * 0.5),
                                blurRadius: 48,
                                spreadRadius: 4,
                              ),
                              BoxShadow(
                                color: Colors.purpleAccent.withOpacity(glow * 0.3),
                                blurRadius: 64,
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: Image.asset(
                              'images/a.png',
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Text('G',
                                    style: TextStyle(
                                        color: Colors.cyanAccent,
                                        fontSize: 64,
                                        fontWeight: FontWeight.w900)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
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
