// AIService — multi-provider failover chain for ALL text AI in the app
// (article concepts, chat, categorization, topic-fixing, daily brief).
//
// Order: Gemini 2.0 Flash → Cerebras → Groq → Pollinations (keyless).
//
// Why a chain instead of one provider: every free tier eventually rate-
// limits or has a bad moment. By stacking them, a single provider being
// busy costs ~8 seconds (the timeout) and the next one answers — instead
// of the 15-minute hangs / "connection error" we got from leaning on one
// slow keyless service. With all keys set, you'd have to hammer the app
// to exhaust every tier in a day.
//
// Keys are pasted by the user in Settings and stored in SharedPreferences.
// Nothing is hardcoded — no secrets in the repo.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// One message in a conversation: {'role': 'system'|'user'|'assistant',
/// 'content': '...'}. This is the OpenAI shape; we convert per-provider.
typedef Msg = Map<String, String>;

class AIService {
  AIService._();
  static final AIService instance = AIService._();

  // ─────────────────────────────────────────────────────────────
  // PRODUCTION BACKEND — your Cloudflare Worker. When set, EVERY app
  // user gets AI through your single key (held server-side), with no
  // setup on their end. Paste your deployed worker URL here after
  // running `wrangler deploy` (see cloudflare-worker/README.md).
  //   e.g. 'https://glint-ai.yourname.workers.dev'
  static const String workerUrl = 'https://glint-ai.glintai.workers.dev';
  // Optional anti-abuse token — must match the APP_TOKEN secret you set
  // on the worker. Leave '' if you didn't set one.
  static const String workerToken = '';

  bool get _workerConfigured => workerUrl.isNotEmpty;

  // SharedPreferences keys for each provider's API key.
  static const _kGemini = 'ai_key_gemini';
  static const _kCerebras = 'ai_key_cerebras';
  static const _kGroq = 'ai_key_groq';
  // Legacy single-Groq key from the previous version — migrated on first read.
  static const _kLegacyGroq = 'groq_api_key';

  static const _timeout = Duration(seconds: 8);

  // Per-provider in-memory cache so we don't hit prefs on every call.
  final Map<String, String?> _keyCache = {};

  /// Which provider answered the most recent call — surfaced in Settings.
  String lastUsedProvider = '';

  Future<String?> _key(String prefKey) async {
    if (_keyCache.containsKey(prefKey)) return _keyCache[prefKey];
    final prefs = await SharedPreferences.getInstance();
    var k = prefs.getString(prefKey);
    // One-time migration of the old Groq-only key.
    if (k == null && prefKey == _kGroq) {
      final legacy = prefs.getString(_kLegacyGroq);
      if (legacy != null && legacy.isNotEmpty) {
        await prefs.setString(_kGroq, legacy);
        await prefs.remove(_kLegacyGroq);
        k = legacy;
      }
    }
    _keyCache[prefKey] = k;
    return k;
  }

  Future<void> setKey(String provider, String key) async {
    final prefKey = _prefFor(provider);
    if (prefKey == null) return;
    final prefs = await SharedPreferences.getInstance();
    final t = key.trim();
    if (t.isEmpty) {
      await prefs.remove(prefKey);
      _keyCache[prefKey] = null;
    } else {
      await prefs.setString(prefKey, t);
      _keyCache[prefKey] = t;
    }
  }

  Future<String?> getKey(String provider) async {
    final prefKey = _prefFor(provider);
    if (prefKey == null) return null;
    return _key(prefKey);
  }

  Future<bool> hasAnyKey() async {
    for (final p in ['gemini', 'cerebras', 'groq']) {
      final k = await getKey(p);
      if (k != null && k.isNotEmpty) return true;
    }
    return false;
  }

  String? _prefFor(String provider) {
    switch (provider) {
      case 'gemini':
        return _kGemini;
      case 'cerebras':
        return _kCerebras;
      case 'groq':
        return _kGroq;
    }
    return null;
  }

  // ---------------- Public API ----------------

  /// Single-prompt generation. Used by categorization, topic-fixing, brief.
  Future<String?> generate({
    required String prompt,
    required Future<String?> Function(String) pollinationsFallback,
    int maxTokens = 800,
  }) async {
    final messages = <Msg>[
      {'role': 'user', 'content': prompt}
    ];
    return chat(
      messages,
      pollinationsFallback: (_) => pollinationsFallback(prompt),
      maxTokens: maxTokens,
    );
  }

  /// Multi-turn chat. Tries each configured provider in order, falling
  /// through on any error/empty/timeout. Pollinations is the final resort.
  Future<String?> chat(
    List<Msg> messages, {
    required Future<String?> Function(List<Msg>) pollinationsFallback,
    int maxTokens = 900,
  }) async {
    // 0) Cloudflare Worker proxy — the production path. Holds your key
    // server-side, does the Gemini→Cerebras→Groq failover itself, and
    // serves all users with zero per-user setup. If it's unreachable we
    // fall through to any locally-pasted keys, then Pollinations.
    if (_workerConfigured) {
      final r = await _callWorker(messages, maxTokens);
      if (r != null && r.isNotEmpty) return r;
    }
    // 1) Gemini (local key — dev / power-user override)
    final gKey = await _key(_kGemini);
    if (gKey != null && gKey.isNotEmpty) {
      final r = await _callGemini(gKey, messages, maxTokens);
      if (r != null && r.isNotEmpty) {
        lastUsedProvider = 'Gemini';
        return r;
      }
    }
    // 2) Cerebras
    final cKey = await _key(_kCerebras);
    if (cKey != null && cKey.isNotEmpty) {
      final r = await _callOpenAiCompatible(
        endpoint: 'https://api.cerebras.ai/v1/chat/completions',
        key: cKey,
        model: 'llama-3.3-70b',
        messages: messages,
        maxTokens: maxTokens,
      );
      if (r != null && r.isNotEmpty) {
        lastUsedProvider = 'Cerebras';
        return r;
      }
    }
    // 3) Groq
    final qKey = await _key(_kGroq);
    if (qKey != null && qKey.isNotEmpty) {
      final r = await _callOpenAiCompatible(
        endpoint: 'https://api.groq.com/openai/v1/chat/completions',
        key: qKey,
        model: 'llama-3.1-8b-instant',
        messages: messages,
        maxTokens: maxTokens,
      );
      if (r != null && r.isNotEmpty) {
        lastUsedProvider = 'Groq';
        return r;
      }
    }
    // 4) Pollinations (keyless last resort)
    lastUsedProvider = 'Pollinations';
    return pollinationsFallback(messages);
  }

  // ---------------- Backend proxy ----------------

  /// Calls your Cloudflare Worker, which holds the keys and runs the
  /// failover chain server-side. Returns the answer text or null.
  Future<String?> _callWorker(List<Msg> messages, int maxTokens) async {
    try {
      final resp = await http
          .post(
            Uri.parse(workerUrl),
            headers: {
              'Content-Type': 'application/json',
              if (workerToken.isNotEmpty) 'x-glint-token': workerToken,
            },
            body: jsonEncode({'messages': messages, 'maxTokens': maxTokens}),
          )
          .timeout(const Duration(seconds: 18));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final text = body['text'] as String?;
      if (text == null || text.isEmpty) return null;
      lastUsedProvider = (body['provider'] ?? 'Worker').toString();
      return text.trim();
    } catch (_) {
      return null;
    }
  }

  // ---------------- Providers ----------------

  /// OpenAI-compatible chat completions (Cerebras + Groq share this shape).
  Future<String?> _callOpenAiCompatible({
    required String endpoint,
    required String key,
    required String model,
    required List<Msg> messages,
    required int maxTokens,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'messages': messages,
              'max_tokens': maxTokens,
              'temperature': 0.7,
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = body['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      return ((choices.first['message'] as Map?)?['content'] as String?)?.trim();
    } catch (_) {
      return null;
    }
  }

  /// Gemini uses its own request/response shape, not OpenAI's.
  Future<String?> _callGemini(
      String key, List<Msg> messages, int maxTokens) async {
    try {
      // Convert OpenAI-style messages → Gemini contents + systemInstruction.
      final contents = <Map<String, dynamic>>[];
      String? systemText;
      for (final m in messages) {
        final role = m['role'] ?? 'user';
        final text = m['content'] ?? '';
        if (text.isEmpty) continue;
        if (role == 'system') {
          systemText = (systemText == null) ? text : '$systemText\n$text';
          continue;
        }
        contents.add({
          'role': role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': text}
          ],
        });
      }
      final payload = <String, dynamic>{
        'contents': contents,
        'generationConfig': {
          'maxOutputTokens': maxTokens,
          'temperature': 0.7,
        },
      };
      if (systemText != null) {
        payload['systemInstruction'] = {
          'parts': [
            {'text': systemText}
          ]
        };
      }
      final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$key');
      final resp = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload))
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final cands = body['candidates'] as List?;
      if (cands == null || cands.isEmpty) return null;
      final parts =
          ((cands.first['content'] as Map?)?['parts'] as List?) ?? const [];
      if (parts.isEmpty) return null;
      final out = parts
          .map((p) => (p as Map)['text']?.toString() ?? '')
          .join('')
          .trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}
