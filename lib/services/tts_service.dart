// TtsService — natural, calm, slow read-aloud for articles.
//
// Designed for the "train / falling asleep" use case: low speech rate,
// the device's highest-quality available voice, and a sentence-by-sentence
// engine so we know WHICH sentence is being spoken (used by the player UI
// to highlight + to let the user "search this" on whatever they just heard).

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _inited = false;

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

  /// Cycle to the next speed step and apply it live. Re-speaks the current
  /// sentence so the new rate takes effect immediately.
  Future<void> cycleSpeed() async {
    final i = speedSteps.indexOf(speed.value);
    final nextSpeed = speedSteps[(i + 1) % speedSteps.length];
    speed.value = nextSpeed;
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
        _isPlaying = false;
        isPlaying.value = false;
        currentSentence.value = -1;
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
    await _tts.stop(); // pause() is unreliable across engines; stop + resume index
  }

  Future<void> resume() async {
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
  }

  bool get playing => _isPlaying;
}
