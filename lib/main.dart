import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:alarm/alarm.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart' as fcm;
import 'package:google_fonts/google_fonts.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const String scheduleUrlBase =
    'https://zahidiya-mysore.pages.dev/api/get-alarm-schedule';
const String saveFcmTokenUrl =
    'https://zahidiya-mysore.pages.dev/api/save-fcm-token';
const String websiteUrl = 'https://zahidiya-mysore.pages.dev';
const String dailySyncTaskName = 'zahidiyaDailyAlarmSync';

// ============ GLOBAL USER INFO ============
String currentUserRole = 'mureed'; // 'admin' ya 'mureed'
String currentUserName = '';

// ============ RINGTONE FILE HELPERS ============
String _toneFileName(String category) {
  switch (category) {
    case 'event':
      return 'event_alarm_tone.mp3';
    case 'live':
      return 'live_alarm_tone.mp3';
    case 'custom':
      return 'custom_alarm_tone_dedicated.mp3';
    default:
      return 'custom_alarm_tone.mp3';
  }
}

String _tonePrefKey(String category) {
  switch (category) {
    case 'event':
      return 'cached_tone_url_event';
    case 'live':
      return 'cached_tone_url_live';
    case 'custom':
      return 'cached_tone_url_custom';
    default:
      return 'cached_tone_url';
  }
}

Future<String?> _getLocalTonePath(String? toneUrl,
    [String category = 'namaz']) async {
  if (toneUrl == null || toneUrl.isEmpty) return null;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${_toneFileName(category)}');
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_tonePrefKey(category));
    if (savedUrl == toneUrl && await file.exists()) return file.path;
    final response =
        await http.get(Uri.parse(toneUrl)).timeout(const Duration(seconds: 20));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      await prefs.setString(_tonePrefKey(category), toneUrl);
      return file.path;
    }
  } catch (e) {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${_toneFileName(category)}');
      if (await file.exists()) return file.path;
    } catch (_) {}
  }
  return null;
}

final RegExp _startTitleRe =
    RegExp(r'^(Fajr|Dhuhr|Asr|Maghrib|Isha) ki namaz ka waqt ho gaya hai$');
final RegExp _endTitleRe = RegExp(
    r'^(?:⏳ )?(Fajr|Dhuhr|Asr|Maghrib|Isha) ki namaz khatam hone wali hai(?:\s*\((\d+)\s*min\))?$');

Future<void> _showAlarmOverlay(String title, int seconds) async {
  try {
    final intent = AndroidIntent(
      action: 'com.zahidiya.alarm.SHOW_OVERLAY',
      package: 'com.zahidiya.alarm',
      arguments: <String, dynamic>{'title': title, 'seconds': seconds},
    );
    await intent.sendBroadcast();
  } catch (_) {}
}

Future<void> _scheduleOverlay(
    int id, DateTime at, String title, int seconds) async {
  try {
    final intent = AndroidIntent(
      action: 'com.zahidiya.alarm.SCHEDULE_OVERLAY',
      package: 'com.zahidiya.alarm',
      arguments: <String, dynamic>{
        'id': id,
        'at': at.millisecondsSinceEpoch.toString(),
        'title': title,
        'seconds': seconds,
      },
    );
    await intent.sendBroadcast();
  } catch (_) {}
}

Future<void> _cancelOverlay(int id) async {
  try {
    final intent = AndroidIntent(
      action: 'com.zahidiya.alarm.CANCEL_OVERLAY',
      package: 'com.zahidiya.alarm',
      arguments: <String, dynamic>{'id': id, 'title': 'x', 'seconds': 10},
    );
    await intent.sendBroadcast();
  } catch (_) {}
}

int idFromString(String s) {
  int hash = 0;
  for (final unit in s.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash % 1000000;
}

Future<void> _scheduleStopAlarm(
    int alarmId, DateTime ringAt, int durationSeconds) async {
  final stopAt = ringAt.add(Duration(seconds: durationSeconds));
  final delay = stopAt.difference(DateTime.now());
  if (delay.isNegative) return;
  await Workmanager().registerOneOffTask(
    'stopAlarm_$alarmId',
    'stopAlarmTask',
    initialDelay: delay,
    inputData: {'alarmId': alarmId},
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

Future<List<Map<String, dynamic>>> fetchAndScheduleForMobile(String mobile,
    {bool force = false}) async {
  await Alarm.init();
  final uri = Uri.parse('$scheduleUrlBase?mobile=$mobile');
  final response = await http.get(uri).timeout(const Duration(seconds: 25));
  if (response.statusCode != 200)
    throw Exception('Server status ${response.statusCode}');
  final data = jsonDecode(response.body);
  if (data['success'] != true)
    throw Exception(data['message'] ?? 'Unknown error');

  final List<dynamic> schedule = data['schedule'] ?? [];
  await _getLocalTonePath(data['tone_url']);
  await _getLocalTonePath(data['event_tone_url'], 'event');
  await _getLocalTonePath(data['live_class_tone_url'], 'live');
  await _getLocalTonePath(data['custom_alarm_tone_url'], 'custom');

  try {
    List<dynamic> tomorrowSchedule = [];
    List<dynamic> tomorrowExtra = [];
    try {
      final t = DateTime.now().add(const Duration(days: 1));
      final dStr =
          '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      final r2 = await http
          .get(Uri.parse('$scheduleUrlBase?mobile=$mobile&date=$dStr'))
          .timeout(const Duration(seconds: 25));
      if (r2.statusCode == 200) {
        final d2 = jsonDecode(r2.body);
        if (d2['success'] == true) {
          tomorrowSchedule = d2['schedule'] ?? [];
          tomorrowExtra = d2['extra_alarms'] ?? [];
        }
      }
    } catch (_) {}
    final int fetchedEndMinutesBefore =
        (data['end_reminder_minutes_before'] as num?)?.toInt() ?? 0;
    await AppConfig.saveEndMinutes(fetchedEndMinutesBefore);
    await _scheduleLocalAlarms(
      [
        ...schedule,
        ...((data['extra_alarms'] as List?) ?? []),
        ...tomorrowSchedule,
        ...tomorrowExtra
      ],
      startDuration: (data['start_alarm_duration_seconds'] as num?)?.toInt() ?? 60,
      endDuration: (data['end_reminder_beep_seconds'] as num?)?.toInt() ?? 20,
      endMinutesBefore: fetchedEndMinutesBefore,
      force: force,
    );
  } catch (_) {}

  final now = DateTime.now();
  final List<Map<String, dynamic>> shownItems = [];
  for (final item in schedule) {
    final String title = item['title'];
    final DateTime dt = DateTime.parse(item['dateTime']).toLocal();
    DateTime? realEndDt;
    if (item['realEndDateTime'] != null)
      realEndDt = DateTime.parse(item['realEndDateTime']).toLocal();
    final DateTime relevantUntil = realEndDt ?? dt;
    final bool isPrayerItem =
        _startTitleRe.hasMatch(title) || _endTitleRe.hasMatch(title);
    if (relevantUntil.isBefore(now) && !isPrayerItem) continue;
    shownItems.add({
      'title': title,
      'time': dt,
      if (realEndDt != null) 'realEndTime': realEndDt,
      if (item['contentType'] != null) 'contentType': item['contentType'],
      if (item['contentText'] != null) 'contentText': item['contentText'],
      if (item['fileUrl'] != null) 'fileUrl': item['fileUrl'],
    });
  }
  shownItems.sort((a, b) => (a['time'] as DateTime).compareTo(b['time'] as DateTime));
  return shownItems;
}

Future<String?> _getCachedTonePathOnly([String category = 'namaz']) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${_toneFileName(category)}');
    if (await file.exists()) return file.path;
    if (category != 'namaz') {
      final defaultFile = File('${dir.path}/${_toneFileName('namaz')}');
      if (await defaultFile.exists()) return defaultFile.path;
    }
  } catch (_) {}
  return null;
}

Future<void> _stopRingingOnly() async {
  try {
    final now = DateTime.now();
    final all = await Alarm.getAlarms();
    for (final a in all) {
      if (!a.dateTime.isAfter(now) || await Alarm.isRinging(a.id))
        await Alarm.stop(a.id);
    }
  } catch (_) {
    try {
      await Alarm.stopAll();
    } catch (_) {}
  }
}

const String _kLocalAlarmRecords = 'local_alarm_records_v1';

String _normTitle(String t) => t
    .replaceAll('\u23F3', '')
    .replaceAll(RegExp(r'\s*\(\d+ min\)\s*$'), '')
    .trim();

Future<void> _scheduleLocalAlarms(
  List<dynamic> schedule, {
  required int startDuration,
  required int endDuration,
  required int endMinutesBefore,
  bool force = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final now = DateTime.now();
  final newRecords = <Map<String, dynamic>>[];
  final newIds = <int>{};

  for (final raw in schedule) {
    try {
      String title = raw['title'].toString();
      final String type = (raw['type'] ?? '').toString();
      DateTime at = DateTime.parse(raw['dateTime'].toString()).toLocal();
      int duration = startDuration;
      String category = 'namaz';
      if (type == 'end_reminder') {
        at = at.subtract(Duration(minutes: endMinutesBefore));
        duration = endDuration;
        if (endMinutesBefore > 0 && !title.contains('('))
          title = '$title ($endMinutesBefore min)';
      } else if (type == 'event') {
        category = 'event';
      } else if (type == 'custom_alarm') {
        category = 'custom';
      } else if (type == 'event_end') {
        category = 'event';
        duration = endDuration;
      } else if (type == 'custom_alarm_end') {
        category = 'custom';
        duration = endDuration;
      }

      if (!at.isAfter(now.add(const Duration(seconds: 20)))) continue;
      if (at.isAfter(now.add(const Duration(hours: 50)))) continue;

      final int id = idFromString('local_${type}_${raw['id']}');
      newIds.add(id);
      newRecords.add({
        'id': id,
        'title': _normTitle(title),
        'at': at.millisecondsSinceEpoch
      });
      await _scheduleOverlay(id, at, translateAlarmTitle(title), duration);

      if (!force) {
        final existing = await Alarm.getAlarm(id);
        if (existing != null &&
            existing.dateTime.difference(at).abs() < const Duration(seconds: 2))
          continue;
      }
      final localTonePath = await _getCachedTonePathOnly(category);
      await Alarm.set(
        alarmSettings: AlarmSettings(
          id: id,
          dateTime: at,
          assetAudioPath: localTonePath,
          loopAudio: true,
          vibrate: true,
          warningNotificationOnKill: false,
          androidFullScreenIntent: true,
          volumeSettings: VolumeSettings.fixed(volume: 1.0),
          notificationSettings: NotificationSettings(
            title: 'Silsila-e-Zahidiya Alarm',
            body: translateAlarmTitle(title),
            stopButton: 'Band Karo',
          ),
        ),
      );
      await _scheduleStopAlarm(id, at, duration);
    } catch (_) {}
  }

  try {
    final oldJson = prefs.getString(_kLocalAlarmRecords);
    if (oldJson != null) {
      for (final r in (jsonDecode(oldJson) as List)) {
        final int oid = r['id'] as int;
        final DateTime oat = DateTime.fromMillisecondsSinceEpoch(r['at'] as int);
        if (!newIds.contains(oid) && oat.isAfter(now)) {
          await Alarm.stop(oid);
          await _cancelOverlay(oid);
        } else if (!newIds.contains(oid) &&
            now.difference(oat) < const Duration(minutes: 15)) {
          newRecords.add(Map<String, dynamic>.from(r as Map));
        }
      }
    }
  } catch (_) {}
  await prefs.setString(_kLocalAlarmRecords, jsonEncode(newRecords));
}

Future<bool> _localAlarmAlreadyHandled(String title) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final json = prefs.getString(_kLocalAlarmRecords);
    if (json == null) return false;
    final now = DateTime.now();
    final String wanted = _normTitle(title);
    for (final r in (jsonDecode(json) as List)) {
      if (r['title'] != wanted) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(r['at'] as int);
      final diff = now.difference(at);
      if (diff >= const Duration(seconds: -120) &&
          diff <= const Duration(minutes: 5)) return true;
    }
  } catch (_) {}
  return false;
}

Future<void> triggerImmediateAlarm(String title,
    {int durationSeconds = 60,
    String category = 'namaz',
    bool showOverlay = true}) async {
  if (category != 'live' && await _localAlarmAlreadyHandled(title)) return;
  try {
    await WakelockPlus.enable();
  } catch (_) {}
  await Alarm.init();
  final DateTime ringAt = DateTime.now().add(const Duration(seconds: 2));
  final int alarmId = idFromString('live_${DateTime.now().millisecondsSinceEpoch}');
  final localTonePath = await _getCachedTonePathOnly(category);
  await Alarm.set(
    alarmSettings: AlarmSettings(
      id: alarmId,
      dateTime: ringAt,
      assetAudioPath: localTonePath,
      loopAudio: true,
      vibrate: true,
      warningNotificationOnKill: false,
      androidFullScreenIntent: true,
      volumeSettings: VolumeSettings.fixed(volume: 1.0),
      notificationSettings: NotificationSettings(
        title: 'Silsila-e-Zahidiya Alarm',
        body: translateAlarmTitle(title),
        stopButton: 'Band Karo',
      ),
    ),
  );
  await _scheduleStopAlarm(alarmId, ringAt, durationSeconds);
  if (showOverlay)
    await _showAlarmOverlay(translateAlarmTitle(title), durationSeconds);
}

String _titleFromMessage(fcm.RemoteMessage message) {
  return message.notification?.title ??
      message.data['title'] ??
      'Live Shuru Ho Gaya';
}

int _durationFromMessage(fcm.RemoteMessage message) {
  return int.tryParse(message.data['duration']?.toString() ?? '') ?? 60;
}

String _categoryFromMessage(fcm.RemoteMessage message) {
  return message.data['category']?.toString() ?? 'namaz';
}

Future<void> sendTokenToBackend(String mobile, String token) async {
  try {
    await http.post(
      Uri.parse(saveFcmTokenUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mobile': mobile, 'token': token}),
    ).timeout(const Duration(seconds: 15));
  } catch (e) {}
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(fcm.RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.data['type'] == 'refresh_settings') {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString('mobile');
      if (mobile != null && mobile.isNotEmpty)
        await fetchAndScheduleForMobile(mobile, force: true);
    } catch (e) {}
    return;
  }
  await triggerImmediateAlarm(_titleFromMessage(message),
      durationSeconds: _durationFromMessage(message),
      category: _categoryFromMessage(message));
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == 'stopAlarmTask') {
      try {
        await Alarm.init();
        final id = inputData?['alarmId'];
        if (id != null) await Alarm.stop(id as int);
        try {
          await WakelockPlus.disable();
        } catch (_) {}
      } catch (e) {}
    } else if (task == 'safetyResyncTask') {
      try {
        final prefs = await SharedPreferences.getInstance();
        final mobile = prefs.getString('mobile');
        if (mobile != null && mobile.isNotEmpty) {
          try {
            final token = await fcm.FirebaseMessaging.instance.getToken();
            if (token != null) await sendTokenToBackend(mobile, token);
          } catch (_) {}
          await fetchAndScheduleForMobile(mobile);
        }
      } catch (e) {}
    }
    return Future.value(true);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  fcm.FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  fcm.FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString('mobile');
      if (mobile != null && mobile.isNotEmpty)
        await sendTokenToBackend(mobile, newToken);
    } catch (_) {}
  });

  await Alarm.init();
  await Workmanager().initialize(callbackDispatcher);
  try {
    await Workmanager().registerPeriodicTask(
      'zahidiya_safety_resync',
      'safetyResyncTask',
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (e) {}

  await AppLang.load();
  await AppUser.load();
  await AppConfig.load();

  // ============ ROLE LOAD (app restart pe Admin tab yaad rahe) ============
  try {
    final _prefs = await SharedPreferences.getInstance();
    currentUserRole = _prefs.getString('role') ?? 'mureed';
  } catch (_) {}

  try {
    await GoogleFonts.pendingFonts([GoogleFonts.notoNastaliqUrdu()]);
  } catch (e) {}
  runApp(const ZahidiyaAlarmApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

// ---------- LANGUAGE ----------
class AppLang {
  static String current = 'ur';
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    current = prefs.getString('app_lang') ?? 'ur';
  }

  static Future<void> toggle() async {
    current = current == 'ur' ? 'en' : 'ur';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_lang', current);
  }
}

String pickByLang(String raw) {
  if (raw.contains('|')) {
    final parts =
        raw.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length >= 2) {
      final hasUrdu = RegExp('[\u0600-\u06FF]');
      final urdu =
          parts.firstWhere((p) => hasUrdu.hasMatch(p), orElse: () => parts[1]);
      final english =
          parts.firstWhere((p) => !hasUrdu.hasMatch(p), orElse: () => parts[0]);
      return AppLang.current == 'ur' ? urdu : english;
    }
  }
  return raw.trim();
}

const Map<String, String> _romanUrduNameWords = {
  'syed': 'سید',
  'shabbir': 'شبیر',
  'muhammad': 'محمد',
  'ahmed': 'احمد',
  'ali': 'علی',
  'hussain': 'حسین',
  'hassan': 'حسن',
  'abbas': 'عباس',
  'zahid': 'زاہد',
  'zahida': 'زاہدہ',
};

String transliterateNameToUrdu(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  return words.map((w) {
    final clean = w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return _romanUrduNameWords[clean] ?? w;
  }).join(' ');
}

Future<String?> _transliterateToUrdu(String englishText) async {
  try {
    final uri = Uri.parse(
        'https://inputtools.google.com/request?text=${Uri.encodeComponent(englishText)}&itc=ur-t-i0-und&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8');
    final res = await http.get(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data is List && data.isNotEmpty && data[0] == 'SUCCESS') {
        final suggestions = data[1][0][1] as List;
        if (suggestions.isNotEmpty) return suggestions[0].toString();
      }
    }
  } catch (_) {}
  return null;
}

class AppConfig {
  static int endMinutesBefore = 0;
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    endMinutesBefore = prefs.getInt('end_reminder_minutes_before_cache') ?? 0;
  }

  static Future<void> saveEndMinutes(int mins) async {
    if (mins <= 0) return;
    endMinutesBefore = mins;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('end_reminder_minutes_before_cache', mins);
  }
}

class AppUser {
  static String name = '';
  static String get displayName {
    if (name.contains('|')) return pickByLang(name);
    if (AppLang.current == 'ur') return transliterateNameToUrdu(name);
    return name.trim();
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    name = prefs.getString('mureed_name') ?? '';
  }

  static Future<void> save(String newName) async {
    name = newName;
    final prefs = await SharedPreferences.getInstance();
    if (newName.isEmpty)
      await prefs.remove('mureed_name');
    else
      await prefs.setString('mureed_name', newName);
  }
}

const Map<String, Map<String, String>> kStrings = {
  'en': {
    'app_title': 'Silsila-e-Zahidiya Alarm',
    'mobile_label': 'Mobile Number',
    'set_alarms_btn': 'Set Alarms',
    'battery_btn': '🔋 Open Battery Settings',
    'overlay_btn': '📱 Allow full-screen alarm',
    'event_view_hint': 'Tap to view',
    'no_event_content': 'Nothing to show.',
    'band_karo_btn': '🛑 Stop',
    'default_status':
        'Enter your mobile number and tap "Set Alarms".',
    'status_empty_mobile': 'First enter your mobile number.',
    'status_not_registered': 'This mobile number is not registered.',
    'status_verify_error': 'Problem verifying, please check internet.',
    'status_fetching': 'Fetching schedule...',
    'status_no_alarms_left': 'No alarms left for today.',
    'status_error_prefix': 'Internet or server issue: ',
    'lang_toggle': '🌐 اردو',
    'prayer_start_label': 'Start',
    'prayer_end_label': 'End',
    'active_now_label': '🟢 Now',
    'minutes_left_suffix': 'minute mein',
    'change_number_label': '✏️ Change mobile number',
    'tab_home': 'Home',
    'tab_website': 'Website',
    'tab_admin': 'Admin',
  },
  'ur': {
    'app_title': 'سلسلہ زاہدیہ الارم',
    'mobile_label': 'موبائل نمبر',
    'set_alarms_btn': 'الارمز سیٹ کریں',
    'battery_btn': '🔋 بیٹری سیٹنگز کھولیں',
    'overlay_btn': '📱 فل اسکرین الارم کی اجازت دیں',
    'event_view_hint': 'دیکھنے کے لیے ٹچ کریں',
    'no_event_content': 'کچھ نہیں ہے۔',
    'band_karo_btn': '🛑 بند کریں',
    'default_status':
        'موبائل نمبر ڈال کر "الارمز سیٹ کریں" دبائیں۔',
    'status_empty_mobile': 'پہلے موبائل نمبر ڈالیں۔',
    'status_not_registered': 'یہ نمبر رجسٹرڈ نہیں ہے۔',
    'status_verify_error': 'تصدیق میں مسئلہ ہوا۔',
    'status_fetching': 'شیڈول لایا جا رہا ہے...',
    'status_no_alarms_left': 'آج کے باقی الارم نہیں بچے۔',
    'status_error_prefix': 'انٹرنیٹ یا سرور مسئلہ: ',
    'lang_toggle': '🌐 English',
    'prayer_start_label': 'شروع',
    'prayer_end_label': 'ختم',
    'active_now_label': '🟢 ابھی',
    'minutes_left_suffix': 'منٹ میں',
    'change_number_label': '✏️ موبائل نمبر تبدیل کریں',
    'tab_home': 'ہوم',
    'tab_website': 'ویب سائٹ',
    'tab_admin': 'ایڈمن',
  },
};

String tr(String key) =>
    kStrings[AppLang.current]?[key] ?? kStrings['en']![key] ?? key;

const Map<String, String> _prayerNameUr = {
  'Fajr': 'فجر',
  'Dhuhr': 'ظہر',
  'Asr': 'عصر',
  'Maghrib': 'مغرب',
  'Isha': 'عشاء',
};

String prayerLabel(String name) =>
    AppLang.current == 'ur' ? (_prayerNameUr[name] ?? name) : name;

String prayerStartMessage(String prayerName) {
  final name = prayerLabel(prayerName);
  if (AppLang.current == 'ur') return '🕌 $name کی نماز کا وقت اب شروع ہو گیا ہے';
  return '🕌 $name ki namaz ka waqt ab shuru ho gaya hai';
}

String prayerEndMessage(String prayerName, {int? minutesLeft}) {
  final name = prayerLabel(prayerName);
  if (AppLang.current == 'ur') {
    final minsTxt = (minutesLeft != null && minutesLeft > 0)
        ? ' ($minutesLeft ${tr('minutes_left_suffix')})'
        : '';
    return '⏳ $name کی نماز کا وقت ختم ہونے والا ہے$minsTxt';
  }
  final minsTxt = (minutesLeft != null && minutesLeft > 0)
      ? ' ($minutesLeft ${tr('minutes_left_suffix')})'
      : '';
  return '⏳ $name ki namaz ka waqt khatam hone wala hai$minsTxt';
}

List<Map<String, dynamic>> _groupScheduledItems(
    List<Map<String, dynamic>> items) {
  final Map<String, Map<String, dynamic>> groups = {};
  final List<Map<String, dynamic>> others = [];
  for (final item in items) {
    final title = item['title'] as String;
    final time = item['time'] as DateTime;
    final sm = _startTitleRe.firstMatch(title);
    final em = _endTitleRe.firstMatch(title);
    if (sm != null) {
      final name = sm.group(1)!;
      groups.putIfAbsent(
          name, () => <String, dynamic>{'type': 'prayer', 'prayer': name});
      groups[name]!['start'] = time;
    } else if (em != null) {
      final name = em.group(1)!;
      groups.putIfAbsent(
          name, () => <String, dynamic>{'type': 'prayer', 'prayer': name});
      groups[name]!['end'] = (item['realEndTime'] as DateTime?) ?? time;
    } else {
      others.add(<String, dynamic>{
        'type': 'other',
        'title': title,
        'time': time,
        'end': item['realEndTime'],
        'contentType': item['contentType'],
        'contentText': item['contentText'],
        'fileUrl': item['fileUrl'],
      });
    }
  }
  final result = <Map<String, dynamic>>[...groups.values, ...others];
  const prayerOrder = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
  result.sort((a, b) {
    if (a['type'] == 'prayer' && b['type'] == 'prayer') {
      return prayerOrder
          .indexOf(a['prayer'] as String)
          .compareTo(prayerOrder.indexOf(b['prayer'] as String));
    }
    if (a['type'] == 'prayer' && b['type'] != 'prayer') return -1;
    if (a['type'] != 'prayer' && b['type'] == 'prayer') return 1;
    return (a['time'] as DateTime).compareTo(b['time'] as DateTime);
  });
  final nowT = DateTime.now();
  result.removeWhere((g) =>
      g['type'] == 'prayer' &&
      g['end'] != null &&
      (g['end'] as DateTime).isBefore(nowT));
  result.removeWhere((g) =>
      g['type'] == 'other' &&
      g['end'] != null &&
      (g['end'] as DateTime).isBefore(nowT));
  return result;
}

String translateAlarmTitle(String title) {
  if (title.contains('|')) return pickByLang(title);
  final sm = _startTitleRe.firstMatch(title);
  if (sm != null) return prayerStartMessage(sm.group(1)!);
  final em = _endTitleRe.firstMatch(title);
  if (em != null) {
    int? mins = em.group(2) != null ? int.tryParse(em.group(2)!) : null;
    mins ??= AppConfig.endMinutesBefore > 0 ? AppConfig.endMinutesBefore : null;
    return prayerEndMessage(em.group(1)!, minutesLeft: mins);
  }
  if (AppLang.current != 'ur') return title;
  if (title == 'Alarm') return 'الارم';
  return title;
}

TextStyle appFont([TextStyle? base]) {
  final b = base ?? const TextStyle();
  if (AppLang.current == 'ur')
    return GoogleFonts.notoNastaliqUrdu(textStyle: b, height: 1.9);
  return b;
}

const String _urduChars =
    '\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF\u200C\u200D';
final RegExp _urduRun = RegExp('[$_urduChars]+(?:\\s+[$_urduChars]+)*');

TextSpan mixedTextSpan(String text, TextStyle base) {
  final children = <InlineSpan>[];
  int last = 0;
  for (final m in _urduRun.allMatches(text)) {
    if (m.start > last) children.add(TextSpan(text: text.substring(last, m.start)));
    children.add(TextSpan(
        text: m.group(0),
        style: GoogleFonts.notoNastaliqUrdu(textStyle: base, height: 1.9)));
    last = m.end;
  }
  if (last < text.length) children.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: children);
}

class MixedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  const MixedText(this.text, {super.key, this.style, this.textAlign});
  @override
  Widget build(BuildContext context) {
    return Text.rich(mixedTextSpan(text, style ?? const TextStyle()),
        textAlign: textAlign);
  }
}

String trSetSuccess(int count) => AppLang.current == 'ur'
    ? '$count الارم سیٹ ہو گئے۔'
    : '$count alarm(s) set.';

class ZahidiyaAlarmApp extends StatelessWidget {
  const ZahidiyaAlarmApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Silsila-e-Zahidiya Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.green, useMaterial3: true),
      home: const MainTabScreen(),
    );
  }
}

// ============================================================
// ============ MAIN TAB SCREEN (Home + Website + Admin) ======
// ============================================================

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});
  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  int _currentIndex = 0;

  WebViewController? _webController;    // Website tab
  WebViewController? _adminController;  // Admin tab
  bool _webLoading = true;
  bool _adminLoading = true;

  final Key _homeKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _webController = _makeController(websiteUrl, (v) => _webLoading = v);
    if (currentUserRole == 'admin') {
      _adminController =
          _makeController('$websiteUrl/admin.html', (v) => _adminLoading = v);
    }
  }

  /// HomeScreen se role update hone par ye call hoga
  void onRoleChanged() {
    if (!mounted) return;
    if (currentUserRole == 'admin' && _adminController == null) {
      _adminController =
          _makeController('$websiteUrl/admin.html', (v) => _adminLoading = v);
    }
    setState(() {});
  }

  WebViewController _makeController(String url, void Function(bool) setLoading) {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => setLoading(true)),
        onPageFinished: (_) => setState(() => setLoading(false)),
        onNavigationRequest: (request) {
          final u = request.url;
          // Website ke andar ke links → andar
          if (u.startsWith(websiteUrl) ||
              u.startsWith('https://zahidiya-mysore.pages.dev')) {
            return NavigationDecision.navigate;
          }
          // Bahar ke links → bahar kholo
          if (u.startsWith('http://') ||
              u.startsWith('https://') ||
              u.startsWith('tel:') ||
              u.startsWith('mailto:') ||
              u.startsWith('whatsapp:')) {
            _openExternal(u);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(url));
  }

  Future<void> _openExternal(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // Bottom nav label style helpers (Urdu Nastaliq + English bold)
  TextStyle _navSelectedLabelStyle() {
    if (AppLang.current == 'ur') {
      return GoogleFonts.notoNastaliqUrdu(
        textStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          height: 1.8,
        ),
      );
    }
    return const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
    );
  }

  TextStyle _navUnselectedLabelStyle() {
    if (AppLang.current == 'ur') {
      return GoogleFonts.notoNastaliqUrdu(
        textStyle: const TextStyle(
          fontSize: 16,
          height: 1.8,
        ),
      );
    }
    return const TextStyle(
      fontSize: 14,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<BottomNavigationBarItem> items = [
      BottomNavigationBarItem(icon: const Icon(Icons.home), label: tr('tab_home')),
      BottomNavigationBarItem(
          icon: const Icon(Icons.language), label: tr('tab_website')),
    ];
    final List<Widget> pages = [
      HomeScreen(key: _homeKey, onRoleChanged: onRoleChanged),
      _buildWebTab(_webController, _webLoading),
    ];

    if (currentUserRole == 'admin') {
      items.add(BottomNavigationBarItem(
        icon: const Icon(Icons.admin_panel_settings),
        label: tr('tab_admin'),
      ));
      pages.add(_buildWebTab(_adminController, _adminLoading));
    }

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (_currentIndex == 0) {
          SystemNavigator.pop();
          return;
        }
        setState(() => _currentIndex = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: _currentIndex, children: pages),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (i) => setState(() => _currentIndex = i),
            backgroundColor: Colors.white,
            elevation: 0,
            selectedItemColor: Colors.green[800],
            unselectedItemColor: Colors.grey[600],
            type: BottomNavigationBarType.fixed,
            selectedFontSize: 18,
            unselectedFontSize: 14,
            selectedLabelStyle: _navSelectedLabelStyle(),
            unselectedLabelStyle: _navUnselectedLabelStyle(),
            items: items,
          ),
        ),
      ),
    );
  }

  Widget _buildWebTab(WebViewController? controller, bool loading) {
    return Stack(
      children: [
        if (controller != null) WebViewWidget(controller: controller),
        if (loading) const Center(child: CircularProgressIndicator()),
        Positioned(
          top: 40,
          left: 8,
          child: SafeArea(
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                onTap: () async {
                  if (await controller?.canGoBack() ?? false) {
                    controller?.goBack();
                  } else {
                    setState(() => _currentIndex = 0);
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Icon(Icons.arrow_back, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ============ EVENT CONTENT SCREEN ==========================
// ============================================================

const String _urTextMark = '\n[[UR]]\n';

String eventTextForLang(String raw) {
  final i = raw.indexOf(_urTextMark);
  if (i < 0) return raw.trim();
  final en = raw.substring(0, i).trim();
  final ur = raw.substring(i + _urTextMark.length).trim();
  if (ur.isEmpty) return en;
  if (en.isEmpty) return ur;
  return AppLang.current == 'ur' ? ur : en;
}

class EventContentScreen extends StatefulWidget {
  final String title;
  final String contentType;
  final String contentText;
  final String fileUrl;
  const EventContentScreen({
    super.key,
    required this.title,
    required this.contentType,
    required this.contentText,
    required this.fileUrl,
  });
  @override
  State<EventContentScreen> createState() => _EventContentScreenState();
}

class _EventContentScreenState extends State<EventContentScreen> {
  WebViewController? _web;

  String get _url {
    final u = widget.fileUrl;
    return u.startsWith('/') ? '$websiteUrl$u' : u;
  }

  String? get _youtubeId {
    final m = RegExp(
            r'(?:youtu\.be/|youtube\.com/(?:watch\?v=|live/|embed/|shorts/))([A-Za-z0-9_-]{6,})')
        .firstMatch(widget.fileUrl);
    return m?.group(1);
  }

  @override
  void initState() {
    super.initState();
    if (widget.fileUrl.isEmpty) return;
    if (widget.contentType == 'pdf') {
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse(
            'https://docs.google.com/gview?embedded=true&url=${Uri.encodeComponent(_url)}'));
    } else if (widget.contentType == 'youtube') {
      final id = _youtubeId;
      if (id != null) {
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.black)
          ..loadRequest(Uri.parse(
              'https://www.youtube.com/embed/$id?autoplay=1&playsinline=1'));
      }
    } else if (widget.contentType == 'video') {
      final safe = _url.replaceAll('"', '%22');
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..loadHtmlString(
            '<html><body style="margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh;"><video controls autoplay playsinline style="max-width:100%;max-height:100%" src="$safe"></video></body></html>');
    } else if (widget.contentType == 'audio') {
      final safe = _url.replaceAll('"', '%22');
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0F2A0F))
        ..loadHtmlString(
            '<html><body style="margin:0;background:#0f2a0f;display:flex;align-items:center;justify-content:center;height:100vh;"><audio controls style="width:92%" src="$safe"></audio></body></html>');
    }
  }

  Widget _body() {
    final type = widget.contentType;
    if (type == 'text') {
      final txt = eventTextForLang(widget.contentText);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: MixedText(txt.isEmpty ? tr('no_event_content') : txt,
            style: const TextStyle(fontSize: 18, height: 1.6)),
      );
    }
    if (type == 'image' && widget.fileUrl.isNotEmpty) {
      return InteractiveViewer(
        child: Center(
          child: Image.network(
            _url,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    if (_web != null) return WebViewWidget(controller: _web!);
    return Center(child: Text(tr('no_event_content'), style: appFont()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MixedText(widget.title,
            style: const TextStyle(color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.green,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _body(),
    );
  }
}

// ============================================================
// ============ ALARM RINGING SCREEN ==========================
// ============================================================

class AlarmRingingScreen extends StatelessWidget {
  final String title;
  final String? mureedName;
  const AlarmRingingScreen({super.key, required this.title, this.mureedName});

  @override
  Widget build(BuildContext context) {
    final name = mureedName ?? AppUser.displayName;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.green,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (name.trim().isNotEmpty) ...[
                    MixedText(name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                  ],
                  const Icon(Icons.alarm, color: Colors.white, size: 90),
                  const SizedBox(height: 24),
                  MixedText(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 60),
                  ElevatedButton(
                    onPressed: () async {
                      await _stopRingingOnly();
                      try {
                        await WakelockPlus.disable();
                      } catch (_) {}
                      if (navigatorKey.currentState?.canPop() ?? false)
                        navigatorKey.currentState?.pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 48, vertical: 20),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(tr('band_karo_btn'),
                        style: appFont(const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold))),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ============ HOME SCREEN (Alarm) ==========================
// ============================================================

class HomeScreen extends StatefulWidget {
  final VoidCallback? onRoleChanged;
  const HomeScreen({super.key, this.onRoleChanged});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _mobileController = TextEditingController();
  String _statusKind = 'default';
  int _statusCount = 0;
  String _statusErrorDetail = '';

  String get _status {
    switch (_statusKind) {
      case 'empty_mobile':
        return tr('status_empty_mobile');
      case 'not_registered':
        return tr('status_not_registered');
      case 'verify_error':
        return tr('status_verify_error');
      case 'fetching':
        return tr('status_fetching');
      case 'no_alarms_left':
        return tr('status_no_alarms_left');
      case 'success':
        return trSetSuccess(_statusCount);
      case 'error':
        return tr('status_error_prefix') + _statusErrorDetail;
      default:
        return tr('default_status');
    }
  }

  List<Map<String, dynamic>> _scheduledItems = [];
  bool _loading = false;
  String? _fcmToken;
  bool _showMobileField = true;
  static const _screenChannel = MethodChannel('zahidiya.alarm/screen');
  Timer? _highlightRefreshTimer;
  DateTime _lastFetched = DateTime.now();

  Future<void> _silentRefresh() async {
    if (_loading) return;
    _lastFetched = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString('mobile');
      if (mobile == null || mobile.isEmpty) return;
      final items = await fetchAndScheduleForMobile(mobile);
      if (!mounted) return;
      setState(() {
        _scheduledItems = items;
        if (items.isNotEmpty) {
          _statusKind = 'success';
          _statusCount = items.length;
        }
      });
    } catch (_) {}
  }

  StreamSubscription<dynamic>? _ringingSub;
  bool _ringingScreenOpen = false;

  void _openRingingScreen(String body) {
    if (_ringingScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _ringingScreenOpen = true;
    nav
        .push(MaterialPageRoute(
          builder: (_) => AlarmRingingScreen(
              title: translateAlarmTitle(body.isNotEmpty ? body : 'Alarm')),
          fullscreenDialog: true,
        ))
        .then((_) {
      _ringingScreenOpen = false;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadSavedMobile();
    _setupFCM();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ringing = Alarm.ringing.value;
      if (ringing.alarms.isNotEmpty)
        _openRingingScreen(ringing.alarms.first.notificationSettings.body);
    });
    _highlightRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      setState(() {});
      final hasPrayerLeft =
          _groupScheduledItems(_scheduledItems).any((g) => g['type'] == 'prayer');
      if (!hasPrayerLeft &&
          DateTime.now().difference(_lastFetched) > const Duration(minutes: 10))
        _silentRefresh();
    });
    _screenChannel.setMethodCallHandler((call) async {
      if (call.method == 'screenOff') {
        await _stopRingingOnly();
        try {
          await WakelockPlus.disable();
        } catch (_) {}
      }
    });
    _ringingSub = Alarm.ringing.listen((alarmSet) {
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      if (alarmSet.alarms.isNotEmpty) {
        _openRingingScreen(alarmSet.alarms.first.notificationSettings.body);
      } else {
        if (_ringingScreenOpen && nav.canPop()) nav.pop();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightRefreshTimer?.cancel();
    _ringingSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final ringing = Alarm.ringing.value;
      if (ringing.alarms.isNotEmpty)
        _openRingingScreen(ringing.alarms.first.notificationSettings.body);
      if (DateTime.now().difference(_lastFetched) > const Duration(minutes: 10))
        _silentRefresh();
    }
  }

  Future<void> _setupFCM() async {
    final messaging = fcm.FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await messaging.getToken();
    _fcmToken = token;
    if (token != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      final mobile = prefs.getString('mobile');
      if (mobile != null && mobile.isNotEmpty)
        await sendTokenToBackend(mobile, token);
    }
    fcm.FirebaseMessaging.onMessage.listen((fcm.RemoteMessage message) {
      if (message.data['type'] == 'refresh_settings') {
        SharedPreferences.getInstance().then((prefs) {
          final mobile = prefs.getString('mobile');
          if (mobile != null && mobile.isNotEmpty)
            fetchAndScheduleForMobile(mobile);
        });
        return;
      }
      triggerImmediateAlarm(_titleFromMessage(message),
          durationSeconds: _durationFromMessage(message),
          category: _categoryFromMessage(message),
          showOverlay: false);
    });
  }

  Future<void> _loadSavedMobile() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('mobile');
    if (saved != null) {
      _mobileController.text = saved;
      setState(() => _showMobileField = false);
      _fetchAndScheduleAlarms();
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();
    await Permission.scheduleExactAlarm.request();
    await Permission.ignoreBatteryOptimizations.request();
    try {
      final prefs = await SharedPreferences.getInstance();
      final asked = prefs.getBool('asked_overlay_permission') ?? false;
      if (!asked && !await Permission.systemAlertWindow.isGranted) {
        await prefs.setBool('asked_overlay_permission', true);
        await Permission.systemAlertWindow.request();
      }
    } catch (_) {}
  }

  Future<void> _fetchAndScheduleAlarms() async {
    final mobile = _mobileController.text.trim();
    if (mobile.isEmpty) {
      setState(() => _statusKind = 'empty_mobile');
      return;
    }
    final verifyUri = Uri.parse('$websiteUrl/api/verify-mobile?mobile=$mobile');
    try {
      final verifyRes =
          await http.get(verifyUri).timeout(const Duration(seconds: 15));
      final verifyData = jsonDecode(verifyRes.body);
      if (verifyData['registered'] != true) {
        setState(() => _statusKind = 'not_registered');
        return;
      }
      setState(() => _showMobileField = false);

      // ===== ROLE SET KARO =====
      currentUserRole = verifyData['role']?.toString() ?? 'mureed';
      currentUserName = verifyData['name']?.toString() ?? '';

      // Save role so app restart pe bhi yaad rahe
      final _p = await SharedPreferences.getInstance();
      await _p.setString('role', currentUserRole);
      // Parent ko batao — Admin tab show karne ke liye
      widget.onRoleChanged?.call();

      final String? fetchedName = verifyData['name']?.toString();
      if (fetchedName != null && fetchedName.trim().isNotEmpty) {
        final String cleanName = fetchedName.trim();
        final bool alreadyBilingual = cleanName.contains('|');
        final bool hasUrduScript =
            RegExp('[\u0600-\u06FF]').hasMatch(cleanName);
        if (!alreadyBilingual && !hasUrduScript) {
          final urduName = await _transliterateToUrdu(cleanName);
          await AppUser.save(urduName != null && urduName.isNotEmpty
              ? '$cleanName | $urduName'
              : cleanName);
        } else {
          await AppUser.save(cleanName);
        }
      }
    } catch (e) {
      setState(() => _statusKind = 'verify_error');
      return;
    }

    setState(() {
      _loading = true;
      _statusKind = 'fetching';
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mobile', mobile);
    await prefs.setString('role', currentUserRole);

    if (_fcmToken != null) await sendTokenToBackend(mobile, _fcmToken!);

    try {
      final items = await fetchAndScheduleForMobile(mobile, force: true);
      _lastFetched = DateTime.now();
      setState(() {
        _loading = false;
        _scheduledItems = items;
        if (items.isNotEmpty) {
          _statusKind = 'success';
          _statusCount = items.length;
        } else
          _statusKind = 'no_alarms_left';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _statusKind = 'error';
        _statusErrorDetail = '$e';
      });
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            AppUser.displayName.trim().isNotEmpty
                ? AppUser.displayName
                : tr('app_title'),
            style: appFont()),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: () async {
              await AppLang.toggle();
              setState(() {});
            },
            child: Text(
              tr('lang_toggle'),
              style: AppLang.current == 'en'
                  ? GoogleFonts.notoNastaliqUrdu(
                      textStyle: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                      height: 1.9)
                  : const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            if (_showMobileField) ...[
              TextField(
                controller: _mobileController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: tr('mobile_label'),
                    labelStyle: appFont(),
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading ? null : _fetchAndScheduleAlarms,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : Text(tr('set_alarms_btn'), style: appFont()),
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                decoration: BoxDecoration(
                    border: Border.all(color: Colors.green, width: 1.5),
                    borderRadius: BorderRadius.circular(8)),
                child: MixedText(
                  AppUser.displayName.trim().isNotEmpty
                      ? AppUser.displayName
                      : _mobileController.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.green),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () => setState(() => _showMobileField = true),
                  child: Text(tr('change_number_label'),
                      style: appFont(const TextStyle(fontSize: 13))),
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await openAppSettings();
              },
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44)),
              child: Text(tr('battery_btn'), style: appFont()),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await Permission.systemAlertWindow.request();
              },
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44)),
              child: Text(tr('overlay_btn'), style: appFont()),
            ),
            const SizedBox(height: 16),
            Text(_status,
                textAlign: TextAlign.center,
                style: appFont(const TextStyle(fontSize: 15))),
            const SizedBox(height: 16),
            Expanded(
              child: Builder(builder: (context) {
                final grouped = _groupScheduledItems(_scheduledItems);
                return ListView.builder(
                  itemCount: grouped.length,
                  itemBuilder: (context, index) {
                    final g = grouped[index];
                    if (g['type'] == 'prayer') {
                      final DateTime? start = g['start'] as DateTime?;
                      final DateTime? end = g['end'] as DateTime?;
                      final now = DateTime.now();
                      final bool isActive = start != null &&
                          end != null &&
                          now.isAfter(start) &&
                          now.isBefore(end);
                      return Card(
                        shape: isActive
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(
                                    color: Color(0xFFFFD700), width: 2.5))
                            : null,
                        color: isActive ? const Color(0xFFFFFBEA) : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const Icon(Icons.alarm, color: Colors.green),
                                const SizedBox(width: 10),
                                Text(prayerLabel(g['prayer'] as String),
                                    style: appFont(const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16))),
                                if (isActive) ...[
                                  const SizedBox(width: 8),
                                  Text(tr('active_now_label'),
                                      style: appFont(const TextStyle(
                                          color: Color(0xFFB8860B),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12))),
                                ],
                              ]),
                              const Divider(height: 14),
                              Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(tr('prayer_start_label'),
                                        style: appFont(const TextStyle(
                                            color: Colors.black54))),
                                    Text(start != null ? _formatTime(start) : '—',
                                        style: appFont()),
                                  ]),
                              const SizedBox(height: 4),
                              Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(tr('prayer_end_label'),
                                        style: appFont(const TextStyle(
                                            color: Colors.black54))),
                                    Text(end != null ? _formatTime(end) : '—',
                                        style: appFont()),
                                  ]),
                            ],
                          ),
                        ),
                      );
                    }
                    final String cType = (g['contentType'] ?? 'none').toString();
                    final String cText = (g['contentText'] ?? '').toString();
                    final String cUrl = (g['fileUrl'] ?? '').toString();
                    final bool hasContent = (cType == 'text' &&
                            cText.trim().isNotEmpty) ||
                        (cType != 'text' && cType != 'none' && cUrl.isNotEmpty);
                    return Card(
                      child: ListTile(
                        leading: Icon(hasContent ? Icons.attach_file : Icons.alarm,
                            color: Colors.green),
                        title: MixedText(translateAlarmTitle(g['title'] as String)),
                        subtitle: hasContent
                            ? Text(tr('event_view_hint'),
                                style: appFont(const TextStyle(
                                    fontSize: 12, color: Colors.green)))
                            : null,
                        trailing: Text(_formatTime(g['time'] as DateTime),
                            style: appFont()),
                        onTap: hasContent
                            ? () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => EventContentScreen(
                                    title: translateAlarmTitle(
                                        g['title'] as String),
                                    contentType: cType,
                                    contentText: cText,
                                    fileUrl: cUrl,
                                  ),
                                ));
                              }
                            : null,
                      ),
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
