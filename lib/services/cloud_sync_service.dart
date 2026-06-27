// CloudSyncService — mirrors per-user state (vault, dislikes, pinned
// topics, behavior counters) to Firestore. SharedPreferences stays as
// the source of truth on-device for speed; this just keeps a backup
// keyed by uid so the user can reinstall and not lose history.
//
// All writes are best-effort: if the user is signed out, the network
// is flaky, or rules deny, we silently no-op. The local prefs always
// succeed first.

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CloudSyncService {
  CloudSyncService._();
  static final CloudSyncService instance = CloudSyncService._();

  CollectionReference<Map<String, dynamic>> get _users =>
      FirebaseFirestore.instance.collection('users');

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Mirror the user's vault list to Firestore. Called after every save.
  Future<void> pushVault(List<String> jsonItems) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _users.doc(uid).collection('data').doc('vault').set({
        'items': jsonItems,
        'updated': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> pushDislikes(List<String> jsonItems) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _users.doc(uid).collection('data').doc('dislikes').set({
        'items': jsonItems,
        'updated': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Append one highlight under users/{uid}/highlights (auto-id docs).
  Future<void> pushHighlight(String articleUrl, String text) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _users.doc(uid).collection('highlights').add({
        'url': articleUrl,
        'text': text,
        'created': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> pushReadLater(List<String> jsonItems) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _users.doc(uid).collection('data').doc('read_later').set({
        'items': jsonItems,
        'updated': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> pushSubs(List<String> topics) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _users.doc(uid).collection('data').doc('subs').set({
        'topics': topics,
        'updated': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Behavior counters — increments are stored as raw ints so we can
  /// compare across devices and feed simple stats back into recommendations.
  Future<void> pushBehavior({int? saves, int? skips, int? seen}) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final data = <String, dynamic>{
        'updated': FieldValue.serverTimestamp(),
      };
      if (saves != null) data['saves'] = saves;
      if (skips != null) data['skips'] = skips;
      if (seen != null) data['seen'] = seen;
      await _users.doc(uid).collection('data').doc('behavior').set(
            data,
            SetOptions(merge: true),
          );
    } catch (_) {}
  }

  /// Pull cloud state into local prefs after sign-in. Only fills empty
  /// keys — never overwrites local content (the user might have added
  /// stuff while signed out on this device).
  Future<void> pullToLocalIfMissing() async {
    final uid = _uid;
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final dataCol = _users.doc(uid).collection('data');

      final vaultSnap = await dataCol.doc('vault').get();
      final localVault = prefs.getStringList('saved_vault') ?? <String>[];
      if (localVault.isEmpty && vaultSnap.exists) {
        final items = (vaultSnap.data()?['items'] as List?)?.cast<String>();
        if (items != null && items.isNotEmpty) {
          await prefs.setStringList('saved_vault', items);
        }
      }

      final dislikesSnap = await dataCol.doc('dislikes').get();
      final localDislikes = prefs.getStringList('disliked_titles') ?? <String>[];
      if (localDislikes.isEmpty && dislikesSnap.exists) {
        final items = (dislikesSnap.data()?['items'] as List?)?.cast<String>();
        if (items != null && items.isNotEmpty) {
          await prefs.setStringList('disliked_titles', items);
        }
      }

      // NOTE: the app stores subscriptions under 'subscribed_topics'
      // (see _subsKey in tech_feed.dart). It MUST match here or pulled
      // topics land in a dead key and Discover never sees them.
      final subsSnap = await dataCol.doc('subs').get();
      final localSubs = prefs.getStringList('subscribed_topics') ?? <String>[];
      if (localSubs.isEmpty && subsSnap.exists) {
        final topics = (subsSnap.data()?['topics'] as List?)?.cast<String>();
        if (topics != null && topics.isNotEmpty) {
          await prefs.setStringList('subscribed_topics', topics);
        }
      }
    } catch (_) {
      // Network/permission errors are fine — local state still works.
    }
  }

  /// Helper to count items in a JSON-encoded list. Used by pushBehavior
  /// callers to keep counters in sync.
  static int countItems(List<String>? jsonList) =>
      jsonList == null ? 0 : jsonList.length;

  /// Parses an item from JSON if it's encoded, otherwise returns null.
  /// Used to deduplicate cloud vs local vault entries.
  static Map<String, dynamic>? tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      if (v is Map<String, dynamic>) return v;
    } catch (_) {}
    return null;
  }
}
