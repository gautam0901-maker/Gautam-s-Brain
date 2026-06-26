// Firestore-backed comments per news post. Keyed by a deterministic
// hash of the article URL so the same post across feeds maps to the
// same comment thread.
//
// Schema: comments/{auto_id}
//   postId: String       (hash of article URL)
//   text: String
//   authorId: String     (firebase auth uid)
//   authorName: String
//   authorPhoto: String? (url)
//   createdAt: Timestamp
//   upvotes: int
//   voterIds: List<String>
//
// Required Firestore security rules — paste these in the Firebase
// Console (Firestore Database → Rules):
//
//   rules_version = '2';
//   service cloud.firestore {
//     match /databases/{database}/documents {
//       match /comments/{id} {
//         allow read: if true;
//         allow create: if request.auth != null
//           && request.resource.data.authorId == request.auth.uid;
//         allow update: if request.auth != null
//           && request.resource.data.diff(resource.data)
//                .affectedKeys().hasOnly(['upvotes','voterIds']);
//         allow delete: if request.auth != null
//           && request.auth.uid == resource.data.authorId;
//       }
//     }
//   }

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Comment {
  final String id;
  final String postId;
  final String text;
  final String authorId;
  final String authorName;
  final String? authorPhoto;
  final DateTime createdAt;
  final int upvotes;
  final List<String> voterIds;
  Comment({
    required this.id,
    required this.postId,
    required this.text,
    required this.authorId,
    required this.authorName,
    this.authorPhoto,
    required this.createdAt,
    required this.upvotes,
    required this.voterIds,
  });

  factory Comment.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    return Comment(
      id: d.id,
      postId: (data['postId'] ?? '').toString(),
      text: (data['text'] ?? '').toString(),
      authorId: (data['authorId'] ?? '').toString(),
      authorName: (data['authorName'] ?? 'Anonymous').toString(),
      authorPhoto: data['authorPhoto']?.toString(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      upvotes: (data['upvotes'] as num?)?.toInt() ?? 0,
      voterIds: ((data['voterIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class CommentsService {
  CommentsService._();
  static final CommentsService instance = CommentsService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _col => _db.collection('comments');

  /// Stable, URL-safe id derived from the article URL.
  static String postIdFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'unknown';
    // Simple deterministic hash — collisions are fine at this scale.
    return trimmed.hashCode.abs().toRadixString(36);
  }

  /// Live comment list for a post, sorted by upvotes desc then newest.
  Stream<List<Comment>> streamFor(String postId) {
    return _col
        .where('postId', isEqualTo: postId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map(Comment.fromDoc).toList();
      list.sort((a, b) {
        if (b.upvotes != a.upvotes) return b.upvotes.compareTo(a.upvotes);
        return b.createdAt.compareTo(a.createdAt);
      });
      return list;
    });
  }

  Future<void> post({required String postId, required String text}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Must be signed in to comment.');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > 2000) {
      throw ArgumentError('Comment too long (max 2000 chars).');
    }
    await _col.add({
      'postId': postId,
      'text': trimmed,
      'authorId': user.uid,
      'authorName': user.displayName ?? 'Anonymous',
      'authorPhoto': user.photoURL,
      'createdAt': FieldValue.serverTimestamp(),
      'upvotes': 0,
      'voterIds': <String>[],
    });
  }

  /// Toggles the current user's vote on a comment. Uses a Firestore
  /// transaction to keep upvotes/voterIds consistent under concurrency.
  Future<void> toggleUpvote(String commentId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Must be signed in to vote.');
    }
    final ref = _col.doc(commentId);
    await _db.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final voters = ((data['voterIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      final hasVoted = voters.contains(user.uid);
      if (hasVoted) {
        voters.remove(user.uid);
      } else {
        voters.add(user.uid);
      }
      txn.update(ref, {
        'voterIds': voters,
        'upvotes': voters.length,
      });
    });
  }

  Future<void> delete(String commentId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await _col.doc(commentId).delete();
  }
}
