// Lightweight shimmer skeletons — no external package. A single
// AnimationController drives a moving highlight across grey blocks so
// loading states feel "alive" and the app reads as faster than a spinner.

import 'package:flutter/material.dart';
import '../theme.dart';

class Shimmer extends StatefulWidget {
  final Widget child;
  const Shimmer({super.key, required this.child});
  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = glintMuted(context, 0.08);
    final hi = glintMuted(context, 0.16);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final dx = (_c.value * 2 - 1) * rect.width;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [base, hi, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(dx),
            ).createShader(rect);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlideGradient extends GradientTransform {
  final double dx;
  const _SlideGradient(this.dx);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}

Widget _block(BuildContext c, double w, double h, [double r = 8]) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: glintMuted(c, 0.10),
        borderRadius: BorderRadius.circular(r),
      ),
    );

/// Full-bleed skeleton of a Discover swipe card.
class DiscoverCardSkeleton extends StatelessWidget {
  const DiscoverCardSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(
        decoration: BoxDecoration(
          color: glintMuted(context, 0.05),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: glintMuted(context, 0.10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Container(
                decoration: BoxDecoration(
                  color: glintMuted(context, 0.12),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                ),
              ),
            ),
            Expanded(
              flex: 7,
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _block(context, double.infinity, 22),
                    const SizedBox(height: 10),
                    _block(context, 220, 22),
                    const SizedBox(height: 18),
                    _block(context, 120, 13),
                    const SizedBox(height: 16),
                    _block(context, double.infinity, 13),
                    const SizedBox(height: 8),
                    _block(context, double.infinity, 13),
                    const SizedBox(height: 8),
                    _block(context, 260, 13),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton of a horizontal list row (Trending / News).
class RowSkeleton extends StatelessWidget {
  const RowSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: glintMuted(context, 0.05),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: glintMuted(context, 0.10)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _block(context, 96, 84, 12),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _block(context, double.infinity, 15),
                  const SizedBox(height: 8),
                  _block(context, double.infinity, 15),
                  const SizedBox(height: 8),
                  _block(context, 140, 15),
                  const SizedBox(height: 12),
                  _block(context, 90, 11),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A column of N row skeletons for list screens.
class ListSkeleton extends StatelessWidget {
  final int count;
  const ListSkeleton({super.key, this.count = 6});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      children: List.generate(count, (_) => const RowSkeleton()),
    );
  }
}
