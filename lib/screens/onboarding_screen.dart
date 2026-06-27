// Onboarding — captures profession, domains of interest, and country.
// Shown automatically after Google sign-in if the user doesn't have a
// profile yet, and re-openable from Settings → Edit Profile.
//
// Saving auto-pins the selected domains as topic subscriptions, so the
// Discover feed immediately reflects the picks.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import '../services/ai_service.dart';
import '../services/user_profile_service.dart';
import '../theme.dart';
import 'tech_feed.dart'
    show
        AnimatedAuroraBackground,
        GlassPanel,
        PollinationsAI,
        SpringScale,
        addSubscription,
        loadSubscriptions,
        notifySubsChanged;

class OnboardingScreen extends StatefulWidget {
  final UserProfile? initial;
  final bool isEdit;
  const OnboardingScreen({super.key, this.initial, this.isEdit = false});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late String _professionId;
  late Set<String> _domains;
  late String _countryCode;
  late String _depth;
  final TextEditingController _interests = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _professionId = widget.initial?.professionId ?? 'developer';
    _domains = (widget.initial?.domains ?? const <String>[]).toSet();
    _countryCode = widget.initial?.countryCode ?? 'WORLD';
    _depth = widget.initial?.depth ?? 'balanced';
    _interests.text = widget.initial?.interests ?? '';
  }

  @override
  void dispose() {
    _interests.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_domains.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Pick at least one interest so we can tune your feed.'),
            backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _saving = true);
    final profile = UserProfile(
      professionId: _professionId,
      domains: _domains.toList(),
      countryCode: _countryCode,
      interests: _interests.text.trim(),
      depth: _depth,
    );

    // Mark complete LOCALLY first so the user always gets into the app, even
    // if the Firestore write is denied (rules not published) or offline.
    await UserProfileService.instance.markOnboardedLocally(profile);

    // Auto-pin selected domains as topic subscriptions (missing ones only).
    final existing = (await loadSubscriptions()).map((s) => s.toLowerCase()).toSet();
    for (final d in _domains) {
      if (!existing.contains(d.toLowerCase())) {
        await addSubscription(d);
      }
    }
    // Let Glint AI read the free-text answer and pin a few real topics.
    final free = _interests.text.trim();
    if (free.length > 4) {
      try {
        final extracted = await AIService.instance.generate(
          prompt:
              "From this sentence, extract up to 4 concrete news/interest topics "
              "(1-3 words each), comma-separated, Title Case, no extra words:\n\"$free\"",
          pollinationsFallback: PollinationsAI.generate,
          maxTokens: 60,
        );
        if (extracted != null) {
          for (final t in extracted.split(RegExp(r'[,\n]'))) {
            final topic = t.trim().replaceAll(RegExp(r'[."’]'), '');
            if (topic.length >= 3 && topic.length <= 30) {
              await addSubscription(topic);
            }
          }
        }
      } catch (_) {}
    }
    notifySubsChanged();

    // Best-effort cloud save — does NOT block navigation. If it fails we
    // already proceeded locally; a quiet note tells the user sync is off.
    String? cloudWarning;
    try {
      await UserProfileService.instance.save(profile);
    } on FirebaseException catch (e) {
      cloudWarning = e.code == 'permission-denied'
          ? 'Saved on this device. Cloud sync is off until the Firestore rules are published.'
          : 'Saved on this device. Cloud sync failed (${e.code}).';
    } catch (_) {
      cloudWarning = 'Saved on this device. Cloud sync failed.';
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (widget.isEdit) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated'), backgroundColor: Colors.green),
      );
    } else {
      // First onboarding → leave the screen via the gate ticker.
      profileGateTicker.value++;
    }
    if (cloudWarning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cloudWarning), backgroundColor: Colors.orange),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: widget.isEdit,
        title: Text(widget.isEdit ? 'Edit Profile' : 'Welcome',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  children: [
                    if (!widget.isEdit) ...[
                      Text(
                        "Let's get to know you",
                        style: TextStyle(
                            color: glintText(context),
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            height: 1.1),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "A few quick questions so Glint AI shows you exactly what you care about.",
                        style: TextStyle(
                            color: glintText(context, 0.6), fontSize: 14),
                      ),
                      const SizedBox(height: 22),
                    ],
                    _sectionLabel("WHAT DO YOU DO"),
                    const SizedBox(height: 10),
                    ...kProfessions.map((p) => _professionCard(p)),
                    const SizedBox(height: 24),
                    _sectionLabel("WHAT INTERESTS YOU (pick a few)"),
                    const SizedBox(height: 4),
                    Text(
                      "Scroll through every field — tech, science, sports, money, lifestyle & more.",
                      style: TextStyle(color: glintText(context, 0.5), fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    // Grouped so users across ALL interests find themselves.
                    ...kInterestGroups.entries.map((group) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(group.key.toUpperCase(),
                                  style: TextStyle(
                                      color: glintAccent(context),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.0)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    group.value.map((d) => _domainChip(d)).toList(),
                              ),
                            ],
                          ),
                        )),
                    const SizedBox(height: 16),
                    _sectionLabel("TELL GLINT AI WHAT YOU'RE INTO"),
                    const SizedBox(height: 6),
                    Text(
                      "In your own words — Glint AI reads this to tune your feed. e.g. \"F1, indie games, space launches, and AI startups.\"",
                      style: TextStyle(color: glintText(context, 0.5), fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    GlassPanel(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _interests,
                        maxLines: 3,
                        style: TextStyle(color: glintText(context), fontSize: 15),
                        decoration: InputDecoration(
                          hintText: "What do you want to follow?",
                          hintStyle: TextStyle(color: glintText(context, 0.4)),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    _sectionLabel("HOW DEEP DO YOU LIKE IT"),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _depthChip('quick', 'Quick headlines', Icons.bolt),
                        const SizedBox(width: 8),
                        _depthChip('balanced', 'Balanced', Icons.balance),
                        const SizedBox(width: 8),
                        _depthChip('deep', 'Deep dives', Icons.menu_book),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _sectionLabel("WHERE ARE YOU"),
                    const SizedBox(height: 10),
                    GlassPanel(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          canvasColor: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF14172A)
                              : Colors.white,
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _countryCode,
                            isExpanded: true,
                            iconEnabledColor: glintText(context, 0.7),
                            style: TextStyle(color: glintText(context), fontSize: 15),
                            items: kProfileCountries
                                .map((c) => DropdownMenuItem(
                                      value: c.code,
                                      child: Text(c.label),
                                    ))
                                .toList(),
                            onChanged: (v) {
                              if (v != null) setState(() => _countryCode = v);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: SpringScale(
                  onTap: _saving ? () {} : _save,
                  child: Container(
                    width: double.infinity,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.lightBlueAccent,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.lightBlueAccent.withOpacity(0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Center(
                      child: _saving
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  color: Colors.black, strokeWidth: 2),
                            )
                          : Text(
                              widget.isEdit ? 'Save changes' : 'Start exploring',
                              style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  letterSpacing: 0.4),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
            color: glintText(context, 0.6),
            letterSpacing: 1.4,
            fontWeight: FontWeight.bold,
            fontSize: 12),
      );

  Widget _professionCard(Profession p) {
    final selected = p.id == _professionId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SpringScale(
        onTap: () => setState(() => _professionId = p.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? glintAccent(context).withOpacity(0.18)
                : glintMuted(context, 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? glintAccent(context).withOpacity(0.6)
                  : glintMuted(context, 0.10),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.label,
                        style: TextStyle(
                            color: glintText(context),
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(p.description,
                        style: TextStyle(
                            color: glintText(context, 0.55), fontSize: 12)),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? glintAccent(context) : glintMuted(context, 0.30),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _depthChip(String id, String label, IconData icon) {
    final on = _depth == id;
    return Expanded(
      child: SpringScale(
        onTap: () => setState(() => _depth = id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: on ? glintAccent(context).withOpacity(0.18) : glintMuted(context, 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: on ? glintAccent(context).withOpacity(0.6) : glintMuted(context, 0.10)),
          ),
          child: Column(
            children: [
              Icon(icon, color: on ? glintAccent(context) : glintText(context, 0.5), size: 22),
              const SizedBox(height: 6),
              Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: on ? glintAccent(context) : glintText(context, 0.6),
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _domainChip(String domain) {
    final selected = _domains.contains(domain);
    return SpringScale(
      onTap: () => setState(() {
        if (selected) {
          _domains.remove(domain);
        } else {
          _domains.add(domain);
        }
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? glintAccent(context).withOpacity(0.18)
              : glintMuted(context, 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected
                  ? glintAccent(context).withOpacity(0.7)
                  : glintMuted(context, 0.18)),
        ),
        child: Text(domain,
            style: TextStyle(
                color: selected ? glintAccent(context) : glintText(context, 0.75),
                fontWeight: FontWeight.w600,
                fontSize: 13)),
      ),
    );
  }
}
