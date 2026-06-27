// Auth wrapper around firebase_auth. Supports Google, Apple, Email/Password,
// and Phone (OTP). The rest of the app reads `currentUser` and listens to
// `authStateChanges` — no direct Firebase imports outside this file.

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _google = GoogleSignIn();

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  bool get isSignedIn => _auth.currentUser != null;

  // ---------------- Google ----------------
  Future<User?> signInWithGoogle() async {
    final googleUser = await _google.signIn();
    if (googleUser == null) return null; // user dismissed the picker
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final cred = await _auth.signInWithCredential(credential);
    return cred.user;
  }

  // ---------------- Apple ----------------
  /// Sign in with Apple. iOS/macOS native; on Android it falls back to the
  /// web flow (needs Service ID config — fine to leave Apple iOS-only).
  Future<User?> signInWithApple() async {
    final rawNonce = _generateNonce();
    final nonce = _sha256(rawNonce);
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: nonce,
    );
    final oauth = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      rawNonce: rawNonce,
    );
    final cred = await _auth.signInWithCredential(oauth);
    // Apple only returns the name on the FIRST sign-in — capture it.
    final user = cred.user;
    if (user != null &&
        (user.displayName == null || user.displayName!.isEmpty) &&
        appleCredential.givenName != null) {
      final name =
          '${appleCredential.givenName ?? ''} ${appleCredential.familyName ?? ''}'.trim();
      if (name.isNotEmpty) await user.updateDisplayName(name);
    }
    return cred.user;
  }

  static bool get appleSignInSupported {
    // Available on iOS 13+ / macOS. SignInWithApple.isAvailable() is async;
    // the UI just shows the button on Apple platforms.
    return true;
  }

  // ---------------- Email / Password ----------------
  Future<User?> signUpWithEmail(String email, String password,
      {String? name}) async {
    final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(), password: password);
    if (name != null && name.trim().isNotEmpty) {
      await cred.user?.updateDisplayName(name.trim());
    }
    return cred.user;
  }

  Future<User?> signInWithEmail(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
        email: email.trim(), password: password);
    return cred.user;
  }

  Future<void> sendPasswordReset(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
  }

  // ---------------- Phone (OTP) ----------------
  /// Starts phone verification. On Android auto-retrieval may sign in
  /// directly (onAutoVerified). Otherwise onCodeSent gives a verificationId
  /// you pass to [confirmPhoneCode].
  Future<void> startPhoneVerification(
    String phoneE164, {
    required void Function(String verificationId) onCodeSent,
    required void Function(User user) onAutoVerified,
    required void Function(String message) onError,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneE164.trim(),
      verificationCompleted: (cred) async {
        try {
          final r = await _auth.signInWithCredential(cred);
          if (r.user != null) onAutoVerified(r.user!);
        } catch (e) {
          onError(e.toString());
        }
      },
      verificationFailed: (e) => onError(e.message ?? 'Verification failed'),
      codeSent: (verificationId, _) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
      timeout: const Duration(seconds: 60),
    );
  }

  Future<User?> confirmPhoneCode(String verificationId, String smsCode) async {
    final cred = PhoneAuthProvider.credential(
        verificationId: verificationId, smsCode: smsCode.trim());
    final r = await _auth.signInWithCredential(cred);
    return r.user;
  }

  // ---------------- Sign out ----------------
  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {}
    await _auth.signOut();
  }

  // ---------------- Nonce helpers (Apple) ----------------
  String _generateNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  String _sha256(String input) {
    final bytes = utf8.encode(input);
    return sha256.convert(bytes).toString();
  }
}
