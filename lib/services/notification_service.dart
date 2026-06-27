// Scheduled local-only notifications. Three nudges per day at user-set
// hours (default 9am / 1pm / 6pm). Each nudge picks a random template +
// a random pinned topic so it feels fresh rather than repetitive.
//
// "Local only" = no FCM, no backend, no battery cost beyond Android's
// AlarmManager. Reschedules on app launch in case the device rebooted.

import 'dart:math';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _kChannelId = 'glint_daily_nudges';
  static const _kChannelName = 'Daily nudges';
  static const _kEnabledKey = 'notif_enabled';
  static const _kFirstAskKey = 'notif_first_ask_done';

  // 8AM = personalized morning brief; 1PM + 6PM = topical nudges.
  static const int _kMorningHour = 8;
  static const List<int> _kHours = [8, 13, 18];

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    tz.initializeTimeZones();
    // iOS (Darwin) needs its own init or local notifications silently no-op.
    // requestXPermission:false here — we ask explicitly in requestPermission().
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(init);
    // Create channel up-front so first scheduled notification doesn't fail.
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
      _kChannelId,
      _kChannelName,
      description: 'Daily reminders to check Glint',
      importance: Importance.high,
    ));
    _ready = true;
  }

  /// Requests notification permission on both platforms. Android 13+ uses
  /// POST_NOTIFICATIONS; iOS uses the native alert/badge/sound prompt.
  Future<bool> requestPermission() async {
    // iOS: ask through the plugin so the system prompt appears.
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (iosImpl != null) {
      final granted = await iosImpl.requestPermissions(
          alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    // Android.
    final ok = await Permission.notification.request();
    if (!ok.isGranted) return false;
    await Permission.scheduleExactAlarm.request();
    return true;
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled, {List<String> topics = const []}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, enabled);
    await _plugin.cancelAll();
    if (!enabled) return;
    await init();
    await schedule(topics);
  }

  /// First-launch bootstrap. Called once from main(); auto-asks for
  /// permission and enables 3/day nudges. Subsequent launches do nothing
  /// here — schedule() in main() handles topic refresh + reboot recovery.
  Future<void> autoEnableOnFirstLaunch(List<String> topics) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kFirstAskKey) ?? false) return;
    await prefs.setBool(_kFirstAskKey, true);
    final granted = await requestPermission();
    if (!granted) return;
    await setEnabled(true, topics: topics);
  }

  /// Schedules the next 7 days of nudges. Called on app launch + after the
  /// user changes topics so old schedules don't reference stale topics.
  Future<void> schedule(List<String> topics) async {
    if (!await isEnabled()) return;
    await init();
    await _plugin.cancelAll();

    final rand = Random();
    final now = tz.TZDateTime.now(tz.local);
    int idCounter = 1;

    for (int day = 0; day < 7; day++) {
      for (final hour in _kHours) {
        final when = tz.TZDateTime(
          tz.local,
          now.year,
          now.month,
          now.day + day,
          hour,
          rand.nextInt(50), // jitter minutes so it doesn't feel robotic
        );
        if (when.isBefore(now)) continue;
        String title;
        String body;
        if (hour == _kMorningHour) {
          // Personalized morning brief — lists up to 3 of the user's topics.
          title = '☀️ Good morning';
          if (topics.isEmpty) {
            body = "Your daily brief is ready — tap for today's tech recap.";
          } else {
            final picks = (topics.toList()..shuffle(rand)).take(3).join(', ');
            body = "Today in $picks — tap for your 60-second brief.";
          }
        } else {
          final topic = topics.isEmpty
              ? null
              : topics[rand.nextInt(topics.length)];
          final template = _templates[rand.nextInt(_templates.length)];
          title = template.title;
          body = topic == null
              ? template.bodyGeneric
              : template.body.replaceAll('{topic}', topic);
        }
        await _plugin.zonedSchedule(
          idCounter++,
          title,
          body,
          when,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _kChannelId,
              _kChannelName,
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }
}

class _Template {
  final String title;
  final String body;
  final String bodyGeneric;
  const _Template(this.title, this.body, this.bodyGeneric);
}

const List<_Template> _templates = [
  _Template('🚀 Fresh signal', 'New {topic} drops landed. See what\'s breaking.', 'Fresh tech & research drops are waiting.'),
  _Template('🔥 Hot right now', 'Trending in {topic} on Hacker News & GitHub.', 'Hot right now on Hacker News & GitHub.'),
  _Template('✨ Daily Brief ready', 'AI recap of {topic} in 60 seconds.', 'AI recap of today\'s tech in 60 seconds.'),
  _Template('🧠 Worth a swipe', 'Bleeding-edge {topic} drops just for you.', 'Bleeding-edge drops just for you.'),
  _Template('📰 Today in tech', 'Don\'t miss what {topic} ships today.', 'Don\'t miss what tech ships today.'),
  _Template('🎯 Sharp signal', '{topic} just had a real moment. See it.', 'Sharp signal across your feed today.'),
  _Template('🌍 Around the world', 'Breaking news + {topic} from your country.', 'Breaking news from around the world.'),
];
