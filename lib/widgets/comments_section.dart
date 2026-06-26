// Live comments section for the DetailScreen. Stream of comments,
// composer (when signed in), per-comment upvote button.
//
// Visuals reuse GlassPanel + SpringScale from tech_feed.dart to stay
// consistent with the rest of the app.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../screens/tech_feed.dart' show GlassPanel, SpringScale;
import '../services/auth_service.dart';
import '../services/comments_service.dart';
import '../theme.dart';

class CommentsSection extends StatefulWidget {
  final String articleUrl;
  const CommentsSection({super.key, required this.articleUrl});
  @override
  State<CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends State<CommentsSection> {
  final TextEditingController _input = TextEditingController();
  bool _posting = false;
  late final String _postId;

  @override
  void initState() {
    super.initState();
    _postId = CommentsService.postIdFromUrl(widget.articleUrl);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final text = _input.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      await CommentsService.instance.post(postId: _postId, text: text);
      _input.clear();
      if (!mounted) return;
      FocusScope.of(context).unfocus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Post failed: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _signIn() async {
    try {
      await AuthService.instance.signInWithGoogle();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sign-in failed: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  String _timeAgo(DateTime then) {
    final diff = DateTime.now().difference(then);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(18),
      borderRadius: 18,
      blurSigma: 14,
      tint: glintAccent(context),
      tintOpacity: 0.08,
      borderColor: glintAccent(context).withOpacity(0.32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.forum_outlined, color: glintAccent(context)),
            const SizedBox(width: 8),
            Text("COMMENTS",
                style: TextStyle(
                    color: glintText(context),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    letterSpacing: 1.2)),
          ]),
          const SizedBox(height: 14),
          StreamBuilder<User?>(
            stream: AuthService.instance.authStateChanges,
            initialData: AuthService.instance.currentUser,
            builder: (context, snap) {
              final user = snap.data;
              if (user == null) return _signInPrompt();
              return _composer(user);
            },
          ),
          const SizedBox(height: 14),
          StreamBuilder<List<Comment>>(
            stream: CommentsService.instance.streamFor(_postId),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          color: glintAccent(context), strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text('Failed to load comments: ${snap.error}',
                      style: const TextStyle(color: Colors.redAccent)),
                );
              }
              final comments = snap.data ?? const <Comment>[];
              if (comments.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    'No comments yet. Be the first.',
                    style: TextStyle(color: glintText(context, 0.55)),
                  ),
                );
              }
              return Column(
                children: comments
                    .map((c) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _CommentRow(
                            comment: c,
                            timeAgo: _timeAgo(c.createdAt),
                          ),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _signInPrompt() {
    return Builder(builder: (context) {
      return SpringScale(
        onTap: _signIn,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: glintMuted(context, 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: glintMuted(context, 0.20)),
          ),
          child: Row(
            children: [
              Icon(Icons.login, color: glintAccent(context), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text("Sign in with Google to join the discussion",
                    style: TextStyle(color: glintText(context, 0.75))),
              ),
              Icon(Icons.chevron_right, color: glintText(context, 0.40)),
            ],
          ),
        ),
      );
    });
  }

  Widget _composer(User user) {
    return Builder(builder: (context) {
      final photo = user.photoURL;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (photo != null && photo.isNotEmpty)
            CircleAvatar(
                radius: 18,
                backgroundImage: CachedNetworkImageProvider(photo),
                backgroundColor: glintMuted(context, 0.10))
          else
            CircleAvatar(
                radius: 18,
                backgroundColor: glintMuted(context, 0.10),
                child: Icon(Icons.person, color: glintText(context, 0.70), size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              style: TextStyle(color: glintText(context)),
              decoration: InputDecoration(
                hintText: 'Add a comment...',
                hintStyle: TextStyle(color: glintText(context, 0.55)),
                filled: true,
                fillColor: glintMuted(context, 0.08),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                suffixIcon: _posting
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: glintAccent(context), strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: Icon(Icons.send, color: glintAccent(context)),
                        onPressed: _post,
                      ),
              ),
              onSubmitted: (_) => _post(),
            ),
          ),
        ],
      );
    });
  }
}

class _CommentRow extends StatelessWidget {
  final Comment comment;
  final String timeAgo;
  const _CommentRow({required this.comment, required this.timeAgo});

  Future<void> _toggleVote(BuildContext context) async {
    final user = AuthService.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to vote.'), backgroundColor: Colors.orange),
      );
      return;
    }
    try {
      await CommentsService.instance.toggleUpvote(comment.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vote failed: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.currentUser;
    final voted = me != null && comment.voterIds.contains(me.uid);
    final mine = me != null && me.uid == comment.authorId;
    final photo = comment.authorPhoto;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: glintMuted(context, 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glintMuted(context, 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (photo != null && photo.isNotEmpty)
            CircleAvatar(
                radius: 16,
                backgroundImage: CachedNetworkImageProvider(photo),
                backgroundColor: glintMuted(context, 0.10))
          else
            CircleAvatar(
                radius: 16,
                backgroundColor: glintMuted(context, 0.10),
                child: Icon(Icons.person, color: glintText(context, 0.70), size: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.authorName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: glintText(context),
                            fontWeight: FontWeight.w700,
                            fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('• $timeAgo',
                        style: TextStyle(color: glintText(context, 0.45), fontSize: 12)),
                    if (mine) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: glintWarmAccent(context).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('you',
                            style: TextStyle(
                                color: glintWarmAccent(context), fontSize: 10)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(comment.text,
                    style: TextStyle(
                        color: glintText(context), fontSize: 14, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SpringScale(
            onTap: () => _toggleVote(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: voted
                    ? glintAccent(context).withOpacity(0.22)
                    : glintMuted(context, 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: voted
                        ? glintAccent(context).withOpacity(0.6)
                        : glintMuted(context, 0.20)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    voted ? Icons.arrow_upward : Icons.arrow_upward_outlined,
                    size: 14,
                    color: voted ? glintAccent(context) : glintText(context, 0.60),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${comment.upvotes}',
                    style: TextStyle(
                      color: voted ? glintAccent(context) : glintText(context, 0.60),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
