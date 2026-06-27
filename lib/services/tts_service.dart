// TtsService — natural, calm, slow read-aloud for articles.
//
// Designed for the "train / falling asleep" use case: low speech rate,
// the device's highest-quality available voice, and a sentence-by-sentence
// engine so we know WHICH sentence is being spoken (used by the player UI
// to highlight + to let the user "search this" on whatever they just heard).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _inited = false;

  // ── Cloud Audio Engine (premium Groq voice via the worker) ───────────────
  // When the worker returns audio we play it through just_audio (which also
  // gives lock-screen + background controls). If it fails we fall back to the
  // device flutter_tts engine below. `_mode` says which engine is live.
  final AudioPlayer _audio = AudioPlayer();
  String _mode = 'device'; // 'device' | 'cloud'
  bool _cloudWired = false;
  bool _advancing = false;
  static const String _workerTtsUrl =
      'https://glint-ai.glintai.workers.dev/tts';
  static const String _kCloudVoiceKey = 'tts_cloud_voice';
  static const String _kCloudEnabledKey = 'tts_cloud_enabled';
  /// Premium voice name (Groq PlayAI). User-changeable in Settings.
  String cloudVoice = 'Celeste-PlayAI';
  /// Master switch — off = always use the device voice.
  bool cloudEnabled = true;
  /// Position / duration for the player scrubber (cloud mode).
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(Duration.zero);
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(Duration.zero);
  /// True while we're fetching the premium audio for the current track.
  final ValueNotifier<bool> buffering = ValueNotifier<bool>(false);

  /// Available premium voices (Groq PlayAI English). Label → id.
  static const Map<String, String> kCloudVoices = {
    'Celeste (warm female)': 'Celeste-PlayAI',
    'Arista (bright female)': 'Arista-PlayAI',
    'Quinn (calm neutral)': 'Quinn-PlayAI',
    'Fritz (clear male)': 'Fritz-PlayAI',
    'Atlas (deep male)': 'Atlas-PlayAI',
    'Indigo (soft neutral)': 'Indigo-PlayAI',
  };

  Future<void> loadAudioPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      cloudVoice = p.getString(_kCloudVoiceKey) ?? cloudVoice;
      cloudEnabled = p.getBool(_kCloudEnabledKey) ?? true;
    } catch (_) {}
  }

  Future<void> setCloudVoice(String id) async {
    cloudVoice = id;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCloudVoiceKey, id);
  }

  Future<void> setCloudEnabled(bool on) async {
    cloudEnabled = on;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kCloudEnabledKey, on);
  }

  // Playlist machinery — one ConcatenatingAudioSource holds all generated
  // broadcast segments; just_audio auto-advances + gives lock-screen next/prev.
  ConcatenatingAudioSource? _playlist;
  final List<int> _childToQueue = []; // playlist child index → _queue index
  int _genToken = 0; // cancels a stale background generation loop

  // Background music bed + intro sting (news-channel feel). Asset-based;
  // silently skipped if the audio files aren't bundled.
  final AudioPlayer _bgm = AudioPlayer();
  bool _bgmReady = false;
  static const double _bgmVolume = 0.10;

  void _wireCloud() {
    if (_cloudWired) return;
    _cloudWired = true;
    _audio.positionStream.listen((p) => position.value = p);
    _audio.durationStream.listen((d) {
      if (d != null) duration.value = d;
    });
    // Map just_audio's current child → our queue index (so the player UI +
    // lock screen show the right story as it auto-advances).
    _audio.currentIndexStream.listen((ci) {
      if (_mode != 'cloud' || ci == null) return;
      if (ci >= 0 && ci < _childToQueue.length) {
        final qi = _childToQueue[ci];
        _trackIndex = qi;
        trackIndex.value = qi;
        currentTrack.value = _queue[qi];
      }
    });
    _audio.playerStateStream.listen((st) {
      if (_mode != 'cloud') return;
      final done = st.processingState == ProcessingState.completed;
      final playing = st.playing && !done;
      _isPlaying = playing;
      isPlaying.value = playing;
      // Duck the music bed with play/pause.
      if (playing) {
        _bgm.play();
      } else {
        _bgm.pause();
      }
      if (done && !_advancing) {
        _advancing = true;
        _onCloudPlaylistDone();
      }
    });
  }

  /// POST the script to the worker, save returned audio to a temp file.
  /// Returns null on any failure (→ device fallback).
  Future<File?> _fetchTtsAudio(String text) async {
    try {
      buffering.value = true;
      final resp = await http
          .post(Uri.parse(_workerTtsUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'text': text, 'voice': cloudVoice}))
          .timeout(const Duration(seconds: 35));
      final ct = resp.headers['content-type'] ?? '';
      if (resp.statusCode != 200 ||
          !ct.contains('audio') ||
          resp.bodyBytes.length < 1000) {
        return null;
      }
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/glint_tts_${text.hashCode}.wav');
      await f.writeAsBytes(resp.bodyBytes);
      return f;
    } catch (_) {
      return null;
    } finally {
      buffering.value = false;
    }
  }

  MediaItem _mediaItem(Map<String, String> item) {
    final art = item['image'] ?? '';
    return MediaItem(
      id: item['url'] ?? item['title'] ?? 'glint',
      album: 'Glint News',
      title: item['title'] ?? 'Glint',
      artist: item['source'] ?? 'Glint AI',
      artUri: art.startsWith('http') ? Uri.tryParse(art) : null,
    );
  }

  Future<String> _scriptFor(Map<String, String> item) async {
    try {
      final s = scriptBuilder != null
          ? await scriptBuilder!(item)
          : '${item['title'] ?? ''}. ${item['summary'] ?? ''}';
      return s.trim().isEmpty ? (item['title'] ?? 'No content.') : s;
    } catch (_) {
      return '${item['title'] ?? ''}. ${item['summary'] ?? ''}';
    }
  }

  // ── News-channel scripting: greeting → segments with transitions → signoff.
  static const List<String> _transitions = [
    'Next up,',
    'In other news,',
    'Turning now to another story,',
    'Meanwhile,',
    'Also making headlines,',
    'Moving on,',
  ];

  String _broadcastText(int i, int total, String script) {
    if (i == 0) {
      final lead = total > 1
          ? "Good day, and welcome to Glint News. I'm your A.I. host, and here are today's top stories. Our first story:"
          : "Good day, and welcome to Glint News. I'm your A.I. host. Here's your story:";
      return '$lead $script';
    }
    final t = _transitions[i % _transitions.length];
    return '$t $script';
  }

  /// Build the broadcast as a growing playlist: generate segment audio one by
  /// one, start playing as soon as the first is ready, keep appending. Gives
  /// auto-advance + lock-screen next/prev natively. Falls back to the device
  /// voice if the FIRST segment can't be generated.
  Future<void> _startCloudPlaylist(int startIndex) async {
    await _init(); // device handlers must be ready for the spoken outro
    _wireCloud();
    _mode = 'cloud';
    _advancing = false;
    _spokeOutro = false;
    await _tts.stop();
    final myToken = ++_genToken;
    _childToQueue.clear();
    _playlist = ConcatenatingAudioSource(children: []);
    buffering.value = true;
    try {
      await _audio.setSpeed(speed.value);
      await _audio.setAudioSource(_playlist!, preload: false);
    } catch (_) {}

    bool started = false;
    // Generate the chosen story first (so the user hears what they tapped),
    // then the rest in order, wrapping around.
    final order = <int>[];
    for (int k = 0; k < _queue.length; k++) {
      order.add((startIndex + k) % _queue.length);
    }

    for (final qi in order) {
      if (myToken != _genToken) return; // a newer session superseded this one
      final item = _queue[qi];
      final text =
          _broadcastText(_childToQueue.length, _queue.length, await _scriptFor(item));
      final file = await _fetchTtsAudio(cleanForSpeech(text));
      if (myToken != _genToken) return;
      if (file == null) {
        if (!started && _childToQueue.isEmpty) {
          // The very first segment failed → cloud unavailable. Fall back to
          // the device voice for the whole session.
          buffering.value = false;
          await _startDevicePlaylist(startIndex);
          return;
        }
        continue; // skip a single failed story, keep the broadcast going
      }
      try {
        await _playlist!
            .add(AudioSource.uri(Uri.file(file.path), tag: _mediaItem(item)));
        _childToQueue.add(qi);
      } catch (_) {
        continue;
      }
      if (!started) {
        started = true;
        buffering.value = false;
        _stopped = false;
        _isPlaying = true;
        isPlaying.value = true;
        currentTrack.value = item;
        _startBgm();
        await _audio.play();
      }
    }
    if (!started) {
      buffering.value = false;
      await _startDevicePlaylist(startIndex);
    }
  }

  /// Device-voice fallback playlist (per-track flutter_tts with auto-advance).
  Future<void> _startDevicePlaylist(int startIndex) async {
    _mode = 'device';
    await _devicePlayTrack(startIndex.clamp(0, _queue.length - 1));
  }

  Future<void> _devicePlayTrack(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _mode = 'device';
    _trackIndex = i;
    trackIndex.value = i;
    final item = _queue[i];
    currentTrack.value = item;
    _spokeOutro = false;
    final script = _broadcastText(i, _queue.length, await _scriptFor(item));
    await start(script);
  }

  void _onCloudPlaylistDone() {
    // Whole broadcast finished — sign off (device voice, instant) then end.
    if (!_spokeOutro && _queue.isNotEmpty) {
      _spokeOutro = true;
      _mode = 'device';
      _bgm.pause();
      _sentences = [_outroLine];
      _index = 0;
      _stopped = false;
      _isPlaying = true;
      isPlaying.value = true;
      _speakCurrent();
      return;
    }
    _finishSession();
  }

  // ── Background music bed (asset-based; graceful if missing) ───────────────
  Future<void> _startBgm() async {
    try {
      if (!_bgmReady) {
        await _bgm.setAsset('assets/audio/news_bed.mp3');
        await _bgm.setLoopMode(LoopMode.one);
        await _bgm.setVolume(_bgmVolume);
        _bgmReady = true;
      }
      await _bgm.seek(Duration.zero);
      await _bgm.play();
    } catch (_) {
      // No bundled music — fine, the broadcast just plays without a bed.
    }
  }

  Future<void> _stopBgm() async {
    try {
      await _bgm.stop();
    } catch (_) {}
  }

  // Sentence queue for the current article.
  List<String> _sentences = [];
  int _index = 0;
  bool _isPlaying = false;
  bool _stopped = true;

  /// Emits the index of the sentence currently being spoken so the UI can
  /// highlight it and offer "search this".
  final ValueNotifier<int> currentSentence = ValueNotifier<int>(-1);
  final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);

  // Playback speed. Base calm rate is 0.42; the multiplier scales it.
  static const double _baseRate = 0.42;
  static const List<double> speedSteps = [0.75, 1.0, 1.25, 1.5];
  final ValueNotifier<double> speed = ValueNotifier<double>(1.0);

  // ── Queue (Spotify-style playlist of articles) ───────────────────────────
  /// Metadata for the track currently being read (title/source/url/image).
  final ValueNotifier<Map<String, String>?> currentTrack =
      ValueNotifier<Map<String, String>?>(null);
  /// The full queue + the playing index, so the player can render a list.
  final ValueNotifier<List<Map<String, String>>> queue =
      ValueNotifier<List<Map<String, String>>>([]);
  final ValueNotifier<int> trackIndex = ValueNotifier<int>(0);
  /// True while a listen session is alive (drives the mini-player visibility).
  /// Goes false after the outro so the mini-player auto-dismisses.
  final ValueNotifier<bool> hasSession = ValueNotifier<bool>(false);

  /// Caller supplies how to turn an article item into a spoken script
  /// (Glint AI narration). Set once at app start. Falls back to title+summary.
  Future<String> Function(Map<String, String> item)? scriptBuilder;

  List<Map<String, String>> _queue = [];
  int _trackIndex = 0;
  bool _spokeOutro = false;

  static const String _outroLine =
      "And that's the latest from Glint. You're all caught up — "
      "tap any story to dive deeper whenever you like.";

  bool get hasNextTrack => _trackIndex < _queue.length - 1;
  bool get hasPrevTrack => _trackIndex > 0;

  /// Start a fresh "Glint News" broadcast over [items], beginning at
  /// [startIndex]. Premium voice → one growing playlist (auto-advance +
  /// lock-screen next/prev). Device voice → per-track fallback.
  Future<void> playQueue(List<Map<String, String>> items,
      {int startIndex = 0}) async {
    if (items.isEmpty) return;
    _genToken++; // cancel any in-flight generation from a previous session
    _queue = List.of(items);
    queue.value = _queue;
    hasSession.value = true;
    _spokeOutro = false;
    final start = startIndex.clamp(0, _queue.length - 1);
    _trackIndex = start;
    trackIndex.value = start;
    currentTrack.value = _queue[start];
    if (cloudEnabled) {
      await _startCloudPlaylist(start);
    } else {
      await _startDevicePlaylist(start);
    }
  }

  Future<void> nextTrack() async {
    if (_mode == 'cloud') {
      if (_audio.hasNext) await _audio.seekToNext();
      return;
    }
    if (hasNextTrack) await _devicePlayTrack(_trackIndex + 1);
  }

  Future<void> prevTrack() async {
    if (_mode == 'cloud') {
      // Restart the current segment if we're into it; else go back one.
      if (position.value.inSeconds > 3 || !_audio.hasPrevious) {
        await _audio.seek(Duration.zero);
      } else {
        await _audio.seekToPrevious();
      }
      return;
    }
    if (_index > 1) {
      await jumpTo(0);
    } else if (hasPrevTrack) {
      await _devicePlayTrack(_trackIndex - 1);
    }
  }

  /// Jump to a specific queue index (tap a story in the player's list).
  Future<void> playTrackAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    if (_mode == 'cloud') {
      final child = _childToQueue.indexOf(i);
      if (child >= 0) {
        await _audio.seek(Duration.zero, index: child);
        await _audio.play();
      }
      // If that segment hasn't been generated yet, ignore — it'll auto-play
      // when the broadcast reaches it.
      return;
    }
    await _devicePlayTrack(i);
  }

  /// Append an article to the running broadcast (long-press "Add to queue").
  Future<void> addToQueue(Map<String, String> item) async {
    if (!hasSession.value) {
      await playQueue([item], startIndex: 0);
      return;
    }
    final qi = _queue.length;
    _queue.add(item);
    queue.value = List.of(_queue);
    if (_mode == 'cloud' && _playlist != null) {
      // Generate + append a new segment to the live playlist.
      final text = _broadcastText(_childToQueue.length, _queue.length,
          await _scriptFor(item));
      final file = await _fetchTtsAudio(cleanForSpeech(text));
      if (file != null) {
        try {
          await _playlist!
              .add(AudioSource.uri(Uri.file(file.path), tag: _mediaItem(item)));
          _childToQueue.add(qi);
        } catch (_) {}
      }
    }
  }

  /// Fully ends the session (mini-player close button).
  Future<void> endSession() async {
    _genToken++;
    _queue = [];
    queue.value = [];
    _childToQueue.clear();
    _trackIndex = 0;
    trackIndex.value = 0;
    currentTrack.value = null;
    hasSession.value = false;
    await _stopBgm();
    await stop();
  }

  void _finishSession() {
    _isPlaying = false;
    isPlaying.value = false;
    currentSentence.value = -1;
    currentTrack.value = null;
    hasSession.value = false;
    _stopBgm();
  }

  /// Device-mode track finished (sentences ran out) → advance / outro / end.
  void _onSentencesDone() {
    // The outro itself just finished → end the session (don't re-advance).
    if (_spokeOutro) {
      _finishSession();
      return;
    }
    if (_trackIndex < _queue.length - 1) {
      _devicePlayTrack(_trackIndex + 1);
      return;
    }
    if (!_spokeOutro && _queue.isNotEmpty) {
      _spokeOutro = true;
      _mode = 'device';
      _sentences = [_outroLine];
      _index = 0;
      _stopped = false;
      _isPlaying = true;
      isPlaying.value = true;
      _speakCurrent();
      return;
    }
    _finishSession();
  }

  /// Cycle to the next speed step and apply it live.
  Future<void> cycleSpeed() async {
    final i = speedSteps.indexOf(speed.value);
    final nextSpeed = speedSteps[(i + 1) % speedSteps.length];
    speed.value = nextSpeed;
    if (_mode == 'cloud') {
      await _audio.setSpeed(nextSpeed);
      return;
    }
    await _tts.setSpeechRate((_baseRate * nextSpeed).clamp(0.1, 1.0));
    // Re-speak the current sentence at the new rate WITHOUT flipping to pause.
    if (_isPlaying && _index >= 0 && _index < _sentences.length) {
      await _restartSpeak();
    }
  }

  List<String> get sentences => _sentences;

  Future<void> _init() async {
    if (_inited) return;
    // iOS: TTS is SILENT unless we claim a playback audio session. This is
    // the #1 reason Live Listen "doesn't work" on iPhone.
    try {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
        ],
        IosTextToSpeechAudioMode.spokenAudio,
      );
    } catch (_) {
      // Not on iOS / older plugin — safe to ignore.
    }
    // Slow + calm by default. The speed multiplier (1.0×) scales this.
    await _tts.setSpeechRate((_baseRate * speed.value).clamp(0.1, 1.0));
    await _tts.setPitch(0.96); // very slightly lower = warmer, less robotic
    await _tts.setVolume(1.0);
    // Pick the BEST available voice by scoring. iOS ships excellent free
    // Premium/Enhanced/Siri voices (com.apple.voice.premium.*, *.enhanced.*),
    // and Android has Google neural voices (en-us-x-*-network). We strongly
    // prefer those and avoid the robotic "compact" defaults.
    try {
      final voices = (await _tts.getVoices) as List?;
      if (voices != null) {
        Map? best;
        int bestScore = -1000;
        for (final v in voices) {
          final name = (v['name'] ?? '').toString().toLowerCase();
          final id = (v['identifier'] ?? v['name'] ?? '').toString().toLowerCase();
          final locale = (v['locale'] ?? '').toString().toLowerCase();
          if (!locale.startsWith('en')) continue;
          final hay = '$name $id';
          int score = 0;
          if (hay.contains('premium')) score += 120;      // iOS 16+ best
          if (hay.contains('enhanced')) score += 90;       // iOS downloadable
          if (hay.contains('siri')) score += 85;           // iOS Siri voices
          if (hay.contains('neural')) score += 80;         // Android/Google
          if (hay.contains('wavenet')) score += 80;
          if (hay.contains('network')) score += 60;        // Android online
          if (hay.contains('en-us-x')) score += 40;        // Android local neural
          if (hay.contains('compact')) score -= 60;        // iOS low quality
          if (locale == 'en-us') score += 10;              // prefer US English
          if (score > bestScore) {
            bestScore = score;
            best = v;
          }
        }
        if (best != null) {
          await _tts.setVoice({
            'name': best['name'].toString(),
            'locale': best['locale'].toString(),
          });
        }
      }
    } catch (_) {}

    _tts.setCompletionHandler(() {
      // Move to the next sentence automatically.
      if (_stopped) return;
      _index++;
      if (_index < _sentences.length) {
        _speakCurrent();
      } else {
        // Track finished — advance the queue / play outro / end session.
        _onSentencesDone();
      }
    });
    _tts.setCancelHandler(() {
      // Ignore cancels caused by an intentional restart (speed change /
      // next / previous) — otherwise the player flips to "paused" while it
      // actually keeps speaking.
      if (_restarting) return;
      _isPlaying = false;
      isPlaying.value = false;
    });
    _inited = true;
  }

  bool _restarting = false;

  /// Stop the current utterance and immediately speak [_index] again, keeping
  /// the playing state intact (used by speed change + skip).
  Future<void> _restartSpeak() async {
    _restarting = true;
    await _tts.stop();
    _stopped = false;
    _isPlaying = true;
    isPlaying.value = true;
    await _speakCurrent();
    _restarting = false;
  }

  /// Strips characters/markup that TTS engines read literally as symbols
  /// ("dot slash", "asterisk", "hashtag") so the audio sounds natural.
  static String cleanForSpeech(String input) {
    var t = input;
    t = t.replaceAll(RegExp(r'https?://\S+'), ' ');     // URLs
    t = t.replaceAll(RegExp(r'[*_#`>]+'), ' ');          // markdown
    t = t.replaceAll(RegExp(r'[/\\|]+'), ' ');           // slashes/pipes
    t = t.replaceAll(RegExp(r'^\s*[-•·]\s*', multiLine: true), ''); // bullets
    t = t.replaceAll(RegExp(r'\.{2,}'), '.');            // ellipses
    t = t.replaceAll(RegExp(r'[~^=<>{}\[\]]+'), ' ');    // stray symbols
    t = t.replaceAll('&amp;', ' and ').replaceAll('&', ' and ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();        // collapse spaces
    return t;
  }

  /// Splits text into speakable sentences. Keeps them short enough that the
  /// completion handler fires often (better highlight granularity).
  static List<String> splitSentences(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return [];
    // Split on sentence-ending punctuation followed by a space.
    final raw = cleaned.split(RegExp(r'(?<=[.!?])\s+'));
    final out = <String>[];
    for (final s in raw) {
      final t = s.trim();
      if (t.isEmpty) continue;
      // Break very long sentences on commas to keep chunks digestible.
      if (t.length > 240) {
        out.addAll(t.split(RegExp(r'(?<=,)\s+')).where((e) => e.trim().isNotEmpty));
      } else {
        out.add(t);
      }
    }
    return out;
  }

  Future<void> start(String text, {int fromIndex = 0}) async {
    await _init();
    await stop();
    // Safety net — even if the caller forgot to clean, strip symbols so
    // TTS never reads "dot slash" / "asterisk".
    _sentences = splitSentences(cleanForSpeech(text));
    if (_sentences.isEmpty) return;
    _index = fromIndex.clamp(0, _sentences.length - 1);
    _stopped = false;
    _isPlaying = true;
    isPlaying.value = true;
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    if (_index < 0 || _index >= _sentences.length) return;
    currentSentence.value = _index;
    await _tts.speak(_sentences[_index]);
  }

  Future<void> pause() async {
    _isPlaying = false;
    isPlaying.value = false;
    if (_mode == 'cloud') {
      await _audio.pause(); // real pause — resumes at the same spot
      return;
    }
    await _tts.stop(); // device pause() is unreliable; stop + resume by index
  }

  Future<void> resume() async {
    if (_mode == 'cloud') {
      _isPlaying = true;
      isPlaying.value = true;
      await _audio.play();
      return;
    }
    if (_sentences.isEmpty) return;
    _stopped = false;
    _isPlaying = true;
    isPlaying.value = true;
    await _speakCurrent();
  }

  Future<void> next() async {
    if (_index < _sentences.length - 1) {
      _index++;
      await _restartSpeak();
    }
  }

  Future<void> previous() async {
    if (_index > 0) {
      _index--;
      await _restartSpeak();
    }
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _sentences.length) return;
    _index = i;
    await _restartSpeak();
  }

  String currentSentenceText() {
    if (_index < 0 || _index >= _sentences.length) return '';
    return _sentences[_index];
  }

  Future<void> stop() async {
    _stopped = true;
    _isPlaying = false;
    isPlaying.value = false;
    currentSentence.value = -1;
    // Clear the queue so the NEXT article starts fresh instead of resuming
    // this one. (pause() deliberately keeps the queue for resume.)
    _sentences = [];
    _index = 0;
    await _tts.stop();
    try {
      await _audio.stop();
    } catch (_) {}
  }

  /// Seek within the current cloud track (player scrubber).
  Future<void> seek(Duration to) async {
    if (_mode == 'cloud') await _audio.seek(to);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHAT-SPECIFIC TTS (single message, not a queue)
  // ─────────────────────────────────────────────────────────────────────────
  bool _chatMode = false;

  bool get chatMode => _chatMode;

  /// Play a single chat response using cloud TTS if available, device TTS fallback.
  /// This is different from playQueue() — no queue, no auto-advance, single message.
  Future<void> playChatResponse(String text) async {
    if (text.trim().isEmpty) return;
    await _init();
    await stop(); // stop any running audio
    _chatMode = true;
    HapticFeedback.mediumImpact();

    final cleaned = cleanForSpeech(text);

    // Try cloud TTS first.
    if (cloudEnabled) {
      _mode = 'cloud';
      _wireCloud();
      buffering.value = true;
      try {
        final file = await _fetchTtsAudio(cleaned);
        if (file != null) {
          await _audio.setAudioSource(AudioSource.uri(Uri.file(file.path)));
          _stopped = false;
          _isPlaying = true;
          isPlaying.value = true;
          buffering.value = false;
          await _audio.play();
          return;
        }
      } catch (_) {}
    }

    // Fallback: device TTS
    _mode = 'device';
    buffering.value = false;
    await start(cleaned);
  }

  /// Stop any playing chat audio and clear chat mode.
  Future<void> stopChatAudio() async {
    if (!_chatMode) return;
    _chatMode = false;
    await stop();
  }

  bool get isCloud => _mode == 'cloud';
  bool get playing => _isPlaying;
}
