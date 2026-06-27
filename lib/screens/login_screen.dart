// Glint sign-in / sign-up. Apple (iOS) + Google one-tap, plus email and
// phone. A "browse without account" escape so users aren't forced. Shown
// by RootGate when signed out; on success RootGate routes to onboarding.

import 'dart:io' show Platform;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/glint_logo.dart';
import 'tech_feed.dart' show AnimatedAuroraBackground, SpringScale;

class LoginScreen extends StatefulWidget {
  /// Called when the user chooses to skip sign-in and browse as guest.
  final VoidCallback? onSkip;
  const LoginScreen({super.key, this.onSkip});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  bool get _isApple {
    try {
      return Platform.isIOS || Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run(Future<User?> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await fn();
      // On success, the authStateChanges stream in RootGate takes over —
      // nothing else to do here. Null = user cancelled.
      if (user == null && mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e.toString());
        });
      }
    }
  }

  String _friendly(String raw) {
    if (raw.contains('network')) return 'Network error — check your connection.';
    if (raw.contains('canceled') || raw.contains('cancelled')) return '';
    if (raw.contains('wrong-password') || raw.contains('invalid-credential')) {
      return 'Wrong email or password.';
    }
    if (raw.contains('user-not-found')) return 'No account with that email.';
    if (raw.contains('email-already-in-use')) return 'That email is already registered — sign in instead.';
    if (raw.contains('weak-password')) return 'Password is too weak (min 6 characters).';
    return 'Something went wrong. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedAuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Shared Hero logo — flies in from the launch screen.
                  const GlintLogoHero(size: 92),
                  const SizedBox(height: 20),
                  Text('Welcome to Glint',
                      style: TextStyle(
                          color: glintText(context),
                          fontSize: 26,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text('Your AI-powered window into tech & the world.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: glintText(context, 0.6), fontSize: 14)),
                  const SizedBox(height: 32),

                  if (_error != null && _error!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                    ),

                  // Apple first on Apple platforms (App Store guideline).
                  if (_isApple) ...[
                    _AppleButton(
                      onTap: _busy ? null : () => _run(AuthService.instance.signInWithApple),
                    ),
                    const SizedBox(height: 12),
                  ],

                  _bigButton(
                    label: 'Continue with Google',
                    icon: Icons.g_mobiledata,
                    bg: Colors.white,
                    fg: Colors.black87,
                    onTap: _busy ? null : () => _run(AuthService.instance.signInWithGoogle),
                  ),
                  const SizedBox(height: 12),

                  _bigButton(
                    label: 'Continue with Email',
                    icon: Icons.mail_outline,
                    bg: glintMuted(context, 0.10),
                    fg: glintText(context),
                    onTap: _busy ? null : () => _openEmailSheet(),
                  ),
                  const SizedBox(height: 12),

                  _bigButton(
                    label: 'Continue with Phone',
                    icon: Icons.phone_iphone,
                    bg: glintMuted(context, 0.10),
                    fg: glintText(context),
                    onTap: _busy ? null : () => _openPhoneSheet(),
                  ),

                  const SizedBox(height: 22),
                  if (_busy)
                    CircularProgressIndicator(color: glintAccent(context))
                  else
                    TextButton(
                      onPressed: widget.onSkip,
                      child: Text('Maybe later — just browse',
                          style: TextStyle(color: glintText(context, 0.55))),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'By continuing you agree to our Terms & Privacy Policy.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: glintText(context, 0.4), fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bigButton({
    required String label,
    required IconData icon,
    required Color bg,
    required Color fg,
    required VoidCallback? onTap,
  }) {
    return SpringScale(
      onTap: onTap ?? () {},
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 24),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- Email sheet ----------------
  void _openEmailSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EmailSheet(onRun: _run),
    );
  }

  // ---------------- Phone sheet ----------------
  void _openPhoneSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PhoneSheet(),
    );
  }
}

// Native-styled Apple button.
class _AppleButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _AppleButton({this.onTap});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SignInWithAppleButton(
      onPressed: onTap ?? () {},
      style: dark ? SignInWithAppleButtonStyle.white : SignInWithAppleButtonStyle.black,
      borderRadius: BorderRadius.circular(16),
      height: 52,
    );
  }
}

// ======================= EMAIL SHEET =======================
class _EmailSheet extends StatefulWidget {
  final Future<void> Function(Future<User?> Function()) onRun;
  const _EmailSheet({required this.onRun});
  @override
  State<_EmailSheet> createState() => _EmailSheetState();
}

class _EmailSheetState extends State<_EmailSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _isSignUp = false;
  bool _busy = false;
  String? _err;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      if (_isSignUp) {
        await AuthService.instance
            .signUpWithEmail(_email.text, _password.text, name: _name.text);
      } else {
        await AuthService.instance.signInWithEmail(_email.text, _password.text);
      }
      if (mounted) Navigator.pop(context); // RootGate takes over
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _err = _msg(e.toString());
        });
      }
    }
  }

  String _msg(String raw) {
    if (raw.contains('email-already-in-use')) return 'Email already registered — switch to Sign In.';
    if (raw.contains('wrong-password') || raw.contains('invalid-credential')) return 'Wrong email or password.';
    if (raw.contains('user-not-found')) return 'No account with that email.';
    if (raw.contains('weak-password')) return 'Password must be at least 6 characters.';
    if (raw.contains('invalid-email')) return 'That email looks invalid.';
    return 'Could not continue. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF0C1622) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: glintMuted(context, 0.2),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
            Text(_isSignUp ? 'Create your account' : 'Sign in',
                style: TextStyle(
                    color: glintText(context), fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            if (_isSignUp) ...[
              _field(_name, 'Your name', Icons.person_outline),
              const SizedBox(height: 12),
            ],
            _field(_email, 'Email', Icons.mail_outline,
                keyboard: TextInputType.emailAddress),
            const SizedBox(height: 12),
            _field(_password, 'Password', Icons.lock_outline, obscure: true),
            if (_err != null) ...[
              const SizedBox(height: 10),
              Text(_err!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: glintAccent(context),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : Text(_isSignUp ? 'Create account' : 'Sign in',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => setState(() => _isSignUp = !_isSignUp),
                child: Text(
                  _isSignUp ? 'Already have an account? Sign in' : "New here? Create an account",
                  style: TextStyle(color: glintAccent(context)),
                ),
              ),
            ),
            if (!_isSignUp)
              Center(
                child: TextButton(
                  onPressed: () async {
                    if (_email.text.trim().isEmpty) return;
                    try {
                      await AuthService.instance.sendPasswordReset(_email.text);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Password reset email sent.')));
                      }
                    } catch (_) {}
                  },
                  child: Text('Forgot password?',
                      style: TextStyle(color: glintText(context, 0.55), fontSize: 13)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon,
      {bool obscure = false, TextInputType? keyboard}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      style: TextStyle(color: glintText(context)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: glintText(context, 0.45)),
        prefixIcon: Icon(icon, color: glintText(context, 0.55)),
        filled: true,
        fillColor: glintMuted(context, 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ======================= PHONE SHEET =======================
class _PhoneSheet extends StatefulWidget {
  const _PhoneSheet();
  @override
  State<_PhoneSheet> createState() => _PhoneSheetState();
}

class _PhoneSheetState extends State<_PhoneSheet> {
  final _phone = TextEditingController(text: '+');
  final _code = TextEditingController();
  String? _verificationId;
  bool _busy = false;
  String? _err;

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    await AuthService.instance.startPhoneVerification(
      _phone.text,
      onCodeSent: (id) {
        if (mounted) setState(() {
          _verificationId = id;
          _busy = false;
        });
      },
      onAutoVerified: (_) {
        if (mounted) Navigator.pop(context);
      },
      onError: (m) {
        if (mounted) setState(() {
          _busy = false;
          _err = m;
        });
      },
    );
  }

  Future<void> _confirm() async {
    if (_verificationId == null) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await AuthService.instance.confirmPhoneCode(_verificationId!, _code.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _err = 'Wrong code. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final codeStage = _verificationId != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF0C1622) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: glintMuted(context, 0.2),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
            Text(codeStage ? 'Enter the code' : 'Sign in with phone',
                style: TextStyle(
                    color: glintText(context), fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              codeStage
                  ? 'We texted a 6-digit code to ${_phone.text}.'
                  : 'Include your country code, e.g. +1 555 123 4567.',
              style: TextStyle(color: glintText(context, 0.55), fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (!codeStage)
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: glintText(context)),
                decoration: _dec('+1 555 123 4567', Icons.phone_iphone),
              )
            else
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                style: TextStyle(color: glintText(context), letterSpacing: 8, fontSize: 20),
                decoration: _dec('______', Icons.sms_outlined),
              ),
            if (_err != null) ...[
              const SizedBox(height: 10),
              Text(_err!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: glintAccent(context),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _busy ? null : (codeStage ? _confirm : _sendCode),
                child: _busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : Text(codeStage ? 'Verify' : 'Send code',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _dec(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: glintText(context, 0.4)),
        prefixIcon: Icon(icon, color: glintText(context, 0.55)),
        filled: true,
        fillColor: glintMuted(context, 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      );
}
