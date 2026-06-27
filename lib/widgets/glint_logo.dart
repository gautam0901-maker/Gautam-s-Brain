// Shared Glint logo tile with a Hero tag. Placing the SAME tagged widget on
// the launch screen and the login screen lets the logo fly between them on
// the cold-start → login transition (only when the user is signed out; if
// signed in there's no matching destination, so it just fades — no flight).

import 'package:flutter/material.dart';

const String kGlintLogoHeroTag = 'glint-logo';

class GlintLogoHero extends StatelessWidget {
  final double size;
  final bool glow;
  const GlintLogoHero({super.key, this.size = 100, this.glow = true});

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.23;
    return Hero(
      tag: kGlintLogoHeroTag,
      // Keep the flight cheap: a single modest glow (not the launch screen's
      // double 48–64px blur, which was what made the old Hero janky).
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.white.withOpacity(0.04),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
          boxShadow: glow
              ? [
                  BoxShadow(
                    color: Colors.cyanAccent.withOpacity(0.28),
                    blurRadius: 34,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.asset(
            'images/a.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(
              child: Text('G',
                  style: TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: size * 0.5,
                      fontWeight: FontWeight.w900)),
            ),
          ),
        ),
      ),
    );
  }
}
