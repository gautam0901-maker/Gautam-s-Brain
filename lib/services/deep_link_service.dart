// Deep links: a shared URL opens the app on the article's detail screen.
//
// Two URL shapes are accepted:
//   1. https://focus-c6659.web.app/p?u=<base64-url>   ← Android App Link
//   2. hiddenai://open?u=<base64-url>                 ← custom scheme
//
// The base64 payload is the original article URL. We URL-safe base64 encode
// so it survives in any sharing channel (SMS, WhatsApp, email).

import 'dart:async';
import 'dart:convert';
import 'package:app_links/app_links.dart';

class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const _hostingDomain = 'focus-c6659.web.app';
  static const _customScheme = 'hiddenai';

  final _appLinks = AppLinks();

  /// Streams article URLs as they arrive (cold start + while running).
  /// The first emission is the cold-start link if the app was opened via
  /// a deep link from another app. Subsequent emissions are warm.
  Stream<String> incomingArticleUrls() async* {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        final url = _decode(initial);
        if (url != null) yield url;
      }
    } catch (_) {}
    yield* _appLinks.uriLinkStream
        .map(_decode)
        .where((u) => u != null)
        .cast<String>();
  }

  /// Encodes a shareable URL that opens the app when tapped.
  static String encodeShareUrl(String articleUrl) {
    final encoded = base64Url.encode(utf8.encode(articleUrl));
    return 'https://$_hostingDomain/p?u=$encoded';
  }

  String? _decode(Uri uri) {
    // Accept either our hosting domain on https or the custom scheme.
    final ok = (uri.scheme == 'https' && uri.host == _hostingDomain) ||
        uri.scheme == _customScheme;
    if (!ok) return null;
    final encoded = uri.queryParameters['u'];
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return utf8.decode(base64Url.decode(encoded));
    } catch (_) {
      return null;
    }
  }
}
