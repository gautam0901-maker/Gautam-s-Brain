// Tiny wrapper around firebase_auth + google_sign_in. The rest of the app
// reads `currentUser` and listens to `authStateChanges` — no direct Firebase
// imports outside this file.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _google = GoogleSignIn();

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  bool get isSignedIn => _auth.currentUser != null;

  /// Returns the signed-in user on success, null on user cancel, throws on
  /// hard failure (network, misconfigured SHA-1, etc.) so the UI can surface it.
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

  Future<void> signOut() async {
    // Sign out of both layers — otherwise GoogleSignIn caches the last account
    // and re-pops it instantly on next sign-in.
    await _google.signOut();
    await _auth.signOut();
  }
}
