// Onboarding — captures profession, domains of interest, and country.
// Shown automatically after Google sign-in if the user doesn't have a
// profile yet, and re-openable from Settings → Edit Profile.
//
// Saving auto-pins the selected domains as topic subscriptions, so the
// Discover feed immediately reflects the picks.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import '../services/user_profile_service.dart';
import '../theme.dart';
import 'tech_feed.dart'
    show
        AnimatedAuroraBackground,
        GlassPanel,
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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _professionId = widget.initial?.professionId ?? 'developer';
    _domains = (widget.initial?.domains ?? const <String>[]).toSet();
    _countryCode = widget.initial?.countryCode ?? 'WORLD';
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
    try {
      final profile = UserProfile(
        professionId: _professionId,
        domains: _domains.toList(),
        countryCode: _countryCode,
      );
      await UserProfileService.instance.save(profile);

      // Auto-pin selected domains as topic subscriptions. We add only the
      // missing ones so the user's manual edits aren't clobbered.
      final existing = (await loadSubscriptions()).map((s) => s.toLowerCase()).toSet();
      for (final d in _domains) {
        if (!existing.contains(d.toLowerCase())) {
          await addSubscription(d);
        }
      }
      notifySubsChanged();

      if (!mounted) return;
      if (widget.isEdit) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated'), backgroundColor: Colors.green),
        );
      }
      // When isEdit is false, the OnboardingGate in MainShell auto-closes
      // because the profile stream emits non-null.
    } on FirebaseException catch (e) {
      if (!mounted) return;
      // Show the actual reason — code + message — and offer a fix when we
      // can identify a common one. No more generic "Save failed".
      final code = e.code;
      final hint = code == 'permission-denied'
          ? 'Open Firestore Rules in the Firebase console and confirm the '
              "users/{uid} match block exists, then try again."
          : code == 'unavailable'
              ? 'No network. Check your connection.'
              : code == 'not-signed-in'
                  ? 'Sign out and sign in again from Settings.'
                  : 'Code: $code';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${e.message ?? code}\n$hint'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Unexpected error: $e'),
            backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
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
                        "Let's tune your feed",
                        style: TextStyle(
                            color: glintText(context),
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            height: 1.1),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Three quick questions so Discover shows things you actually care about.",
                        style: TextStyle(
                            color: glintText(context, 0.6), fontSize: 14),
                      ),
                      const SizedBox(height: 22),
                    ],
                    _sectionLabel("WHAT DO YOU DO"),
                    const SizedBox(height: 10),
                    ...kProfessions.map((p) => _professionCard(p)),
                    const SizedBox(height: 24),
                    _sectionLabel("WHAT INTERESTS YOU (pick 2+)"),
                    const SizedBox(height: 10),
                    GlassPanel(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: kDomainSuggestions
                            .map((d) => _domainChip(d))
                            .toList(),
                      ),
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
