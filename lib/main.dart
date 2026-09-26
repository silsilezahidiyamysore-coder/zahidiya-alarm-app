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

const String scheduleUrlBase =
    'https://zahidiya-mysore.pages.dev/api/get-alarm-schedule';
const String saveFcmTokenUrl =
    'https://zahidiya-mysore.pages.dev/api/save-fcm-token';
const String dailySyncTaskName = 'zahidiyaDailyAlarmSync';

// "category" ke hisaab se alag file name/pref-key use karta hai, taaki
// Namaz/Custom, Event aur Live Class ki alag-alag ringtone cache ho sakein.
String _toneFileName(String category) {
  switch (category) {
    case 'event': return 'event_alarm_tone.mp3';
    case 'live': return 'live_alarm_tone.mp3';
    case 'custom': return 'custom_alarm_tone_dedicated.mp3';
    default: return 'custom_alarm_tone.mp3'; // 'namaz' ka default/global tone
  }
}
String _tonePrefKey(String category) {
  switch (category) {
    case 'event': return 'cached_tone_url_event';
    case 'live': return 'cached_tone_url_live';
    case 'custom': return 'cached_tone_url_custom';
    default: return 'cached_tone_url';
  }
}

// Admin ka upload kiya hua ringtone download karke phone mein save karta hai
// (taaki app band/FCM push ke waqt bhi bina internet ke bhi use ho sake).
// Agar URL pehle jaisa hi hai to dobara download nahi karta.
Future<String?> _getLocalTonePath(String? toneUrl, [String category = 'namaz']) async {
  if (toneUrl == null || toneUrl.isEmpty) return null;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${_toneFileName(category)}');
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_tonePrefKey(category));

    if (savedUrl == toneUrl && await file.exists()) {
      return file.path;
    }

    final response = await http.get(Uri.parse(toneUrl)).timeout(const Duration(seconds: 20));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      await prefs.setString(_tonePrefKey(category), toneUrl);
      return file.path;
    }
  } catch (e) {
    // Download fail ho to purani cached file (agar ho) use kar lo
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${_toneFileName(category)}');
      if (await file.exists()) return file.path;
    } catch (_) {}
  }
  return null;
}

// Namaz ke "shuru" aur "khatam" alarm titles pehchanne ke liye (backend ke
// fixed text se match hote hain). Emoji ho ya na ho, dono chalega.
final RegExp _startTitleRe = RegExp(r'^(Fajr|Dhuhr|Asr|Maghrib|Isha) ki namaz ka waqt ho gaya hai$');
final RegExp _endTitleRe = RegExp(r'^(?:⏳ )?(Fajr|Dhuhr|Asr|Maghrib|Isha) ki namaz khatam hone wali hai(?:\s*\((\d+)\s*min\))?$');

// Alarm bajte hi app ko sabse aage (full screen) le aata hai — chahe phone
// unlock ho aur koi aur app chal rahi ho. Iske liye phone mein "Display over
// other apps" ki ijazat zaroori hai (app pehli baar kholne par maangti hai).
// ignore: unused_element
Future<void> _bringAppToFront() async {
  try {
    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      category: 'android.intent.category.LAUNCHER',
      package: 'com.zahidiya.alarm',
      componentName: 'com.zahidiya.alarm.MainActivity',
      flags: <int>[
        Flag.FLAG_ACTIVITY_NEW_TASK,
        Flag.FLAG_ACTIVITY_REORDER_TO_FRONT,
        Flag.FLAG_ACTIVITY_SINGLE_TOP,
      ],
    );
    await intent.launch();
  } catch (_) {}
}

// Alarm bajte hi kisi bhi app (YouTube/Facebook...) ke UPAR poori screen ka
// alarm dikhata hai (native overlay, "Display over other apps" ki ijazat se)
// aur alarm app ko bhi aage le aata hai.
// ignore: unused_element
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

// Phone ke alarm ke saath-saath usi exact time par "kisi bhi app ke upar poori
// screen ka alarm" (overlay) lagata / hataata hai. Ye alarm ki ringing se bilkul
// alag hai — isme kuch bhi gadbad ho to alarm ki awaaz par asar nahi padta.
Future<void> _scheduleOverlay(int id, DateTime at, String title, int seconds) async {
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

// Admin ne jitne second ka Start Alarm duration set kiya hai, us time ke baad
// yeh khud alarm ko band kar deta hai (background WorkManager task ke through).
Future<void> _scheduleStopAlarm(int alarmId, DateTime ringAt, int durationSeconds) async {
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

// Ab yeh function seedha alarm set NAHI karta — sirf aaj ka schedule
// dikhaane ke liye laata hai, aur ringtone ko offline-use ke liye cache
// kar leta hai. Asli "ring" ab seedha server se FCM push aane par
// triggerImmediateAlarm() se hota hai (WhatsApp jaisa reliable) — isliye
// phone ko khud "jaag" kar time check karne ki zaroorat nahi rehti.
Future<List<Map<String, dynamic>>> fetchAndScheduleForMobile(String mobile, {bool force = false}) async {
  await Alarm.init();
  final uri = Uri.parse('$scheduleUrlBase?mobile=$mobile');
  final response = await http.get(uri).timeout(const Duration(seconds: 25));

  if (response.statusCode != 200) {
    throw Exception('Server status ${response.statusCode}');
  }

  final data = jsonDecode(response.body);
  if (data['success'] != true) {
    throw Exception(data['message'] ?? 'Unknown error');
  }

  final List<dynamic> schedule = data['schedule'] ?? [];
  final String? toneUrl = data['tone_url'];
  final String? eventToneUrl = data['event_tone_url'];
  final String? liveToneUrl = data['live_class_tone_url'];
  final String? customToneUrl = data['custom_alarm_tone_url'];
  await _getLocalTonePath(toneUrl); // default (namaz) tone offline ke liye cache kar lo
  await _getLocalTonePath(eventToneUrl, 'event'); // event ki alag tone
  await _getLocalTonePath(liveToneUrl, 'live'); // live class ki alag tone
  await _getLocalTonePath(customToneUrl, 'custom'); // custom alarm ki alag tone
  // Aaj + kal ke saare alarm phone mein khud EXACT time par set kar do
  // (server ke push par nirbhar nahi — internet/token/cron ki dikkat se alarm
  // kabhi miss ya late nahi hoga). Push ab sirf backup hai.
  try {
    List<dynamic> tomorrowSchedule = [];
    List<dynamic> tomorrowExtra = [];
    try {
      final t = DateTime.now().add(const Duration(days: 1));
      final dStr = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      final r2 = await http.get(Uri.parse('$scheduleUrlBase?mobile=$mobile&date=$dStr')).timeout(const Duration(seconds: 25));
      if (r2.statusCode == 200) {
        final d2 = jsonDecode(r2.body);
        if (d2['success'] == true) {
          tomorrowSchedule = d2['schedule'] ?? [];
          tomorrowExtra = d2['extra_alarms'] ?? [];
        }
      }
    } catch (_) {}
    final int fetchedEndMinutesBefore = (data['end_reminder_minutes_before'] as num?)?.toInt() ?? 0;
    await AppConfig.saveEndMinutes(fetchedEndMinutesBefore);
    await _scheduleLocalAlarms(
      [...schedule, ...((data['extra_alarms'] as List?) ?? []), ...tomorrowSchedule, ...tomorrowExtra],
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
    final String dateTimeStr = item['dateTime'];
    final DateTime dt = DateTime.parse(dateTimeStr).toLocal();
    // "khatam hone wali hai" (end reminder) items ke liye "realEndDateTime"
    // asli namaz-khatam waqt hota hai (jab agli namaz shuru hoti hai) —
    // isko "End" column mein dikhate hain. "dateTime" (dt) sirf yeh batata
    // hai ki reminder alert kab bajni hai (X min pehle) — display ke liye
    // nahi, isliye ab dono ko alag rakha hai.
    DateTime? realEndDt;
    if (item['realEndDateTime'] != null) {
      realEndDt = DateTime.parse(item['realEndDateTime']).toLocal();
    }
    final DateTime relevantUntil = realEndDt ?? dt;
    // FIX: namaz ke Start/End poore din list mein rehte hain (admin panel jaisa),
    // pehle Start time nikalte hi hat jaata tha (Fajr/Zohar mein '—' dikhta tha).
    // Sirf Event/Custom alarm guzar jaane par hatte hain.
    final bool isPrayerItem = _startTitleRe.hasMatch(title) || _endTitleRe.hasMatch(title);
    if (relevantUntil.isBefore(now) && !isPrayerItem) continue;
    shownItems.add({
      'title': title,
      'time': dt,
      if (realEndDt != null) 'realEndTime': realEndDt,
      // Event ka text/file (agar hai) — list se tap karke app ke andar dikhane ke liye
      if (item['contentType'] != null) 'contentType': item['contentType'],
      if (item['contentText'] != null) 'contentText': item['contentText'],
      if (item['fileUrl'] != null) 'fileUrl': item['fileUrl'],
    });
  }

  shownItems.sort((a, b) => (a['time'] as DateTime).compareTo(b['time'] as DateTime));
  return shownItems;
}

// Sirf pehle se cache mein saved tone file uthata hai — download nahi karta
// (push aane ke waqt turant alarm bajna zaroori hai, download ka wait nahi karna).
// Agar us category ki alag tone upload nahi hui hai, to default (namaz/custom) tone use hoti hai.
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

// Sirf jo alarm abhi baj raha hai (ya jiska time aa chuka hai) use band karta hai.
// PEHLE Alarm.stopAll() chalta tha, jo aane wale SAARE alarm bhi cancel kar deta
// tha (ek alarm band karte hi baaki din ke alarm gayab ho jaate the).
Future<void> _stopRingingOnly() async {
  try {
    final now = DateTime.now();
    final all = await Alarm.getAlarms();
    for (final a in all) {
      if (!a.dateTime.isAfter(now) || await Alarm.isRinging(a.id)) {
        await Alarm.stop(a.id);
      }
    }
  } catch (_) {
    // Kuch bhi gadbad ho to bhi alarm band hona sabse zaroori hai
    try { await Alarm.stopAll(); } catch (_) {}
  }
}

// ---------- PHONE PAR EXACT-TIME ALARM (asli, bharosemand tareeka) ----------
const String _kLocalAlarmRecords = 'local_alarm_records_v1';

String _normTitle(String t) =>
    t.replaceAll('\u23F3', '').replaceAll(RegExp(r'\s*\(\d+ min\)\s*$'), '').trim();

// Server ke schedule ke har alarm ko phone ke AlarmManager mein exact time par
// set karta hai. Agar app band ho, internet na ho, ya server ka push late/fail
// ho — tab bhi ye alarm theek waqt par bajega.
Future<void> _scheduleLocalAlarms(
  List<dynamic> schedule, {
  required int startDuration,
  required int endDuration,
  required int endMinutesBefore,
  bool force = false,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); // doosre isolate ka likha hua bhi dikhe
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
        // Isha ka end alarm pehle jaisa server push se hi chalega
        if (title.contains('Isha')) continue;
        at = at.subtract(Duration(minutes: endMinutesBefore));
        duration = endDuration;
        // Kitne minute mein namaz khatam ho rahi hai, ye title ke saath jod
        // dete hain (jaise "Fajr ki namaz khatam hone wali hai (15 min)") —
        // translateAlarmTitle() ise pehchan kar naya wording banata hai.
        if (endMinutesBefore > 0 && !title.contains('(')) {
          title = '$title ($endMinutesBefore min)';
        }
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
      // Guzar chuka (ya bilkul abhi) ho to chhod do; 2 din se door bhi nahi
      if (!at.isAfter(now.add(const Duration(seconds: 20)))) continue;
      if (at.isAfter(now.add(const Duration(hours: 50)))) continue;

      final int id = idFromString('local_${raw['id']}');
      newIds.add(id);
      newRecords.add({'id': id, 'title': _normTitle(title), 'at': at.millisecondsSinceEpoch});

      // Overlay har baar dobara lagate hain (wahi id/time se, to bas badal jaata hai) —
      // taaki phone restart ke baad bhi wapas lag jaaye
      await _scheduleOverlay(id, at, translateAlarmTitle(title), duration);

      if (!force) {
        final existing = await Alarm.getAlarm(id);
        if (existing != null && existing.dateTime.difference(at).abs() < const Duration(seconds: 2)) {
          continue; // pehle se sahi time par set hai
        }
      }
      final localTonePath = await _getCachedTonePathOnly(category);
      await Alarm.set(
        alarmSettings: AlarmSettings(
          id: id,
          dateTime: at,
          assetAudioPath: localTonePath,
          loopAudio: true,
          vibrate: true,
          warningNotificationOnKill: false, // "Your alarms may not ring" wali notification band
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

  // Jo alarm ab schedule mein nahi (admin ne hata diye ya time badal diya) unhe band karo
  try {
    final oldJson = prefs.getString(_kLocalAlarmRecords);
    if (oldJson != null) {
      for (final r in (jsonDecode(oldJson) as List)) {
        final int oid = r['id'] as int;
        final DateTime oat = DateTime.fromMillisecondsSinceEpoch(r['at'] as int);
        if (!newIds.contains(oid) && oat.isAfter(now)) {
          await Alarm.stop(oid);
          await _cancelOverlay(oid);
        } else if (!newIds.contains(oid) && now.difference(oat) < const Duration(minutes: 15)) {
          // BUG FIX: baj chuke alarm ka record 15 minute tak rakhte hain. Pehle
          // naya schedule lete hi ye record mit jaata tha, aur server ka push
          // (jo 1-2 minute late aata hai) usi alarm ko DOOBARA baja deta tha.
          newRecords.add(Map<String, dynamic>.from(r as Map));
        }
      }
    }
  } catch (_) {}
  await prefs.setString(_kLocalAlarmRecords, jsonEncode(newRecords));
}

// Server ka push aane par: agar phone ne yehi alarm apne andar (exact time par)
// pehle se lagaya hua hai, to push se dobara NAHI bajana (warna 1-2 minute baad
// doosri baar bajta tha, kyunki server ka push hamesha thoda late aata hai).
// Push tabhi bajta hai jab phone ke paas is alarm ka apna record hi na ho
// (jaise phone ne schedule abhi tak liya hi na ho) — yaani sirf backup ke roop mein.
Future<bool> _localAlarmAlreadyHandled(String title) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // doosre isolate (app/WorkManager) ka likha hua bhi dikhe
    final json = prefs.getString(_kLocalAlarmRecords);
    if (json == null) return false;
    final now = DateTime.now();
    final String wanted = _normTitle(title);
    for (final r in (jsonDecode(json) as List)) {
      if (r['title'] != wanted) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(r['at'] as int);
      final diff = now.difference(at); // + matlab alarm ka time guzar chuka
      if (diff >= const Duration(seconds: -120) && diff <= const Duration(minutes: 5)) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

// FCM push aate hi (server se, exact time par) yeh seedha loud alarm bajata hai.
// wakelock isliye lagaya hai taaki background mein CPU turant so na jaaye
// jab tak alarm set na ho jaaye — phone jaldi/pakka bajata hai.
Future<void> triggerImmediateAlarm(String title, {int durationSeconds = 60, String category = 'namaz', bool showOverlay = true}) async {
  // Phone ne yehi alarm pehle hi (exact time par) baja diya ho to push se dobara nahi
  if (category != 'live' && await _localAlarmAlreadyHandled(title)) return;
  try {
    await WakelockPlus.enable();
  } catch (_) {}
  await Alarm.init();
  final DateTime ringAt = DateTime.now().add(const Duration(seconds: 2));
  final int alarmId = idFromString('live_${DateTime.now().millisecondsSinceEpoch}');
  final localTonePath = await _getCachedTonePathOnly(category);
  final alarmSettings = AlarmSettings(
    id: alarmId,
    dateTime: ringAt,
    assetAudioPath: localTonePath,
    loopAudio: true,
    vibrate: true,
    warningNotificationOnKill: false, // "Your alarms may not ring" wali notification band
    androidFullScreenIntent: true,
    volumeSettings: VolumeSettings.fixed(volume: 1.0),
    notificationSettings: NotificationSettings(
      title: 'Silsila-e-Zahidiya Alarm',
      body: translateAlarmTitle(title),
      stopButton: 'Band Karo',
    ),
  );
  await Alarm.set(alarmSettings: alarmSettings);
  await _scheduleStopAlarm(alarmId, ringAt, durationSeconds);
  // Alarm ab baj raha hai. Uske BAAD (alarm ko chhue bina) kisi bhi app ke upar
  // poori screen ka overlay dikhate hain — isme gadbad ho to alarm par asar nahi.
  if (showOverlay) {
    await _showAlarmOverlay(translateAlarmTitle(title), durationSeconds);
  }
  // BUG FIX: pehle yahan turant WakelockPlus.disable() ho jaata tha —
  // is wajah se kabhi-kabhi phone ki screen 2-3 second mein hi wapas so
  // jaati thi, aur app usko "user ne khud screen off/lock ki" samajh ke
  // alarm galti se jaldi band kar deta tha (jabki set duration bahut
  // zyada baaki hota tha). Ab wakelock tabhi chhodenge jab alarm SACH
  // mein band ho — ya to user "Band Karo" dabaye, ya scheduled duration
  // poora ho jaaye (dono jagah neeche WakelockPlus.disable() call hai).
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

// FCM token ko backend ko bhejta hai taaki us mobile number se link ho jaaye.
Future<void> sendTokenToBackend(String mobile, String token) async {
  try {
    await http.post(
      Uri.parse(saveFcmTokenUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mobile': mobile, 'token': token}),
    ).timeout(const Duration(seconds: 15));
  } catch (e) {
    // Fail ho to bhi crash na ho, agli baar app khulne par phir try hoga
  }
}

// App band ho ya background mein ho, tab bhi FCM push yahan aata hai.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(fcm.RemoteMessage message) async {
  await Firebase.initializeApp();
  if (message.data['type'] == 'refresh_settings') {
    // Admin ne tone/duration badla — turant naya schedule+tone fetch karo, alarm mat bajao
    try {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString('mobile');
      if (mobile != null && mobile.isNotEmpty) {
        await fetchAndScheduleForMobile(mobile, force: true);
      }
    } catch (e) {}
    return;
  }
  await triggerImmediateAlarm(_titleFromMessage(message), durationSeconds: _durationFromMessage(message), category: _categoryFromMessage(message));
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == 'stopAlarmTask') {
      try {
        await Alarm.init();
        final id = inputData?['alarmId'];
        if (id != null) {
          await Alarm.stop(id as int);
        }
        try { await WakelockPlus.disable(); } catch (_) {}
      } catch (e) {}
    } else if (task == 'safetyResyncTask') {
      // Har 15 minute mein display list + ringtone cache refresh karta hai
      // (ab asli alarm ka time server FCM push se aata hai, ye sirf UI/tone
      // taaza rakhne ke liye hai).
      //
      // BUG FIX: pehle yahan sirf schedule/tone refresh hota tha, FCM token
      // dobara backend ko nahi bheja jaata tha. Agar Android/Google Play
      // Services kabhi FCM token badal de (aksar hota hai jab app kai ghante/
      // din tak khola na jaaye) aur user subah app na khole, to backend ke
      // paas PURANA (mar chuka) token reh jaata tha — is wajah se us poore din
      // koi bhi alarm push hi nahi pahुँchta tha, jab tak user khud app kholke
      // dobara "Set Alarms" na dabata. Ab yahan bhi token check + resend karte
      // hain, taaki app kabhi khola na jaaye tab bhi token hamesha taaza rahe.
      try {
        final prefs = await SharedPreferences.getInstance();
        final mobile = prefs.getString('mobile');
        if (mobile != null && mobile.isNotEmpty) {
          try {
            final token = await fcm.FirebaseMessaging.instance.getToken();
            if (token != null) {
              await sendTokenToBackend(mobile, token);
            }
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

  // FCM token kabhi-kabhi khud badal jaata hai (Android/Google Play Services
  // ki taraf se) — jab bhi aisa ho, turant naya token backend ko bhej do,
  // taaki purana (mar chuka) token backend mein reh na jaaye.
  fcm.FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString('mobile');
      if (mobile != null && mobile.isNotEmpty) {
        await sendTokenToBackend(mobile, newToken);
      }
    } catch (_) {}
  });

  await Alarm.init();

  // Ab roz raat 1 baje "jaagne" wala kaam nahi karna padta — server (backend)
  // khud FCM push bhejta hai exact waqt par, app seedha triggerImmediateAlarm()
  // se bajati hai. Isliye AndroidAlarmManager/WorkManager-based nightly sync
  // hata diya hai. WorkManager sirf "stopAlarmTask" (duration ke baad band
  // karna) aur ek chhota safety-refresh (display list + tone cache) ke liye reh gaya hai.
  await Workmanager().initialize(callbackDispatcher);
  try {
    // Ye ek baar register hone ke baad hamesha chalta rahega (reboot ke baad bhi,
    // WorkManager khud-ba-khud phir se register kar leta hai) — koi extra kaam
    // nahi karna padega. Agar pehle se registered hai to ye no-op hai.
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
  try {
    // Font ko pehle hi download/cache karke rakh do, taaki jab bhi user
    // Urdu par switch kare, turant sahi (Nastaliq) font dikhe — koi flash/farak na aaye.
    await GoogleFonts.pendingFonts([GoogleFonts.notoNastaliqUrdu()]);
  } catch (e) {}
  runApp(const ZahidiyaAlarmApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

// ---------- LANGUAGE (Urdu / English) ----------
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

// Agar koi text "English | اردو" format mein diya gaya ho (jaise events ke
// title mein pehle se hota hai), to sirf app ki abhi chuni hui language ka
// hissa nikalta hai. Agar pipe nahi hai (sirf ek hi language ka text), to
// wahi text waapas kar deta hai (koi translation/transliteration nahi hoti).
String pickByLang(String raw) {
  if (raw.contains('|')) {
    final parts = raw.split('|').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length >= 2) {
      final hasUrdu = RegExp('[\u0600-\u06FF]');
      final urdu = parts.firstWhere((p) => hasUrdu.hasMatch(p), orElse: () => parts[1]);
      final english = parts.firstWhere((p) => !hasUrdu.hasMatch(p), orElse: () => parts[0]);
      return AppLang.current == 'ur' ? urdu : english;
    }
  }
  return raw.trim();
}

// Roman Urdu mein likhe aam Islami/Urdu naam (jaise "syed", "shabbir") ke
// Urdu-script spelling — mureed ka naam khud-b-khud Urdu mein dikhane ke
// liye. Ye ek fixed dictionary hai (jaisi Fajr/Dhuhr ke liye upar hai),
// isliye sirf inhi mein se jo lafz naam mein mile wo Urdu mein badlega;
// koi naya/anokha lafz mile to wo Roman mein hi reh jaayega.
const Map<String, String> _romanUrduNameWords = {
  'syed': 'سید', 'sayyid': 'سید', 'sayed': 'سید',
  'shabbir': 'شبیر', 'shabir': 'شبیر',
  'muhammad': 'محمد', 'mohammed': 'محمد', 'mohammad': 'محمد', 'mohd': 'محمد', 'md': 'محمد',
  'ahmed': 'احمد', 'ahmad': 'احمد',
  'ali': 'علی', 'alli': 'علی',
  'hussain': 'حسین', 'husain': 'حسین', 'hussein': 'حسین', 'hussan': 'حسین',
  'hassan': 'حسن', 'hasan': 'حسن',
  'abbas': 'عباس',
  'abdul': 'عبد', 'abdullah': 'عبداللہ',
  'rahim': 'رحیم', 'rahman': 'رحمٰن',
  'karim': 'کریم', 'kareem': 'کریم',
  'fatima': 'فاطمہ', 'fatema': 'فاطمہ',
  'zainab': 'زینب', 'zaynab': 'زینب',
  'aisha': 'عائشہ', 'ayesha': 'عائشہ',
  'khadija': 'خدیجہ',
  'bilal': 'بلال',
  'bibi': 'بی بی',
  'zahid': 'زاہد', 'zahida': 'زاہدہ',
  'zahidiya': 'زاہدیہ',
  'anwar': 'انور', 'akhtar': 'اختر',
  'iqbal': 'اقبال', 'nawaz': 'نواز', 'sharif': 'شریف',
  'khan': 'خان',
  'sheikh': 'شیخ', 'shaikh': 'شیخ',
  'qadri': 'قادری', 'chishti': 'چشتی', 'naqshbandi': 'نقشبندی',
  'farooq': 'فاروق', 'farooque': 'فاروق',
  'usman': 'عثمان', 'uthman': 'عثمان',
  'umar': 'عمر', 'omar': 'عمر',
  'bakar': 'بکر', 'bakr': 'بکر',
  'jafar': 'جعفر', 'zafar': 'ظفر',
  'hasnain': 'حسنین', 'zulfiqar': 'ذوالفقار',
  'yusuf': 'یوسف', 'yousuf': 'یوسف',
  'ibrahim': 'ابراہیم',
  'ismail': 'اسماعیل', 'ismael': 'اسماعیل',
  'dawood': 'داؤد', 'dawud': 'داؤد',
  'sulaiman': 'سلیمان', 'suleman': 'سلیمان',
  'musa': 'موسیٰ', 'isa': 'عیسیٰ',
  'ghulam': 'غلام',
  'imran': 'عمران',
  'amir': 'عامر', 'ameer': 'امیر',
  'asif': 'آصف',
  'kamal': 'کمال', 'jamal': 'جمال', 'kamran': 'کامران',
  'nasir': 'ناصر', 'naseer': 'نصیر',
  'tariq': 'طارق',
  'waseem': 'وسیم', 'wasim': 'وسیم',
  'naeem': 'نعیم', 'tahir': 'طاہر',
  'zain': 'زین', 'zayn': 'زین',
  'saba': 'صبا', 'sana': 'ثنا',
  'amna': 'آمنہ', 'aamna': 'آمنہ',
  'mariam': 'مریم', 'maryam': 'مریم',
  'hina': 'حنا',
  'rukhsana': 'رخسانہ', 'nasreen': 'نسرین',
  'shabnam': 'شبنم', 'shazia': 'شازیہ',
  'shaheen': 'شاہین', 'shahid': 'شاہد', 'shahida': 'شاہدہ',
  'javed': 'جاوید', 'javaid': 'جاوید',
  'kausar': 'کوثر', 'kauser': 'کوثر',
  'mumtaz': 'ممتاز', 'nusrat': 'نصرت',
  'parveen': 'پروین', 'perveen': 'پروین',
  'rashida': 'راشدہ', 'rehana': 'ریحانہ',
  'riaz': 'ریاض', 'riyaz': 'ریاض',
  'saleem': 'سلیم', 'salim': 'سلیم', 'salma': 'سلمیٰ',
  'shaista': 'شائستہ',
  'yasmin': 'یاسمین', 'yasmeen': 'یاسمین',
  'feroz': 'فیروز', 'firoz': 'فیروز',
  'rafiq': 'رفیق', 'rafique': 'رفیق',
  'hameed': 'حمید', 'hamid': 'حامد',
  'wahid': 'واحد', 'waheed': 'وحید',
  'majeed': 'مجید',
  'aziz': 'عزیز', 'aziza': 'عزیزہ',
  'latif': 'لطیف', 'lateef': 'لطیف',
  'noor': 'نور', 'nur': 'نور',
  'sabir': 'صابر', 'shakir': 'شاکر',
  'basheer': 'بشیر', 'bashir': 'بشیر',
  'mubarak': 'مبارک',
  'sultan': 'سلطان', 'sultana': 'سلطانہ',
  'begum': 'بیگم', 'bano': 'بانو', 'banu': 'بانو',
};

// Backend se aaya naam agar sirf Roman (English) script mein ho (pipe format
// mein Urdu waala hissa na diya gaya ho), to har lafz ko upar ki dictionary
// se milaakar best-effort Urdu spelling banata hai. Jo lafz dictionary mein
// na mile wo Roman mein hi reh jaata hai (100% guarantee nahi, par zyaadatar
// aam Islami naam sahi Urdu mein dikh jaate hain).
String transliterateNameToUrdu(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  return words.map((w) {
    final clean = w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return _romanUrduNameWords[clean] ?? w;
  }).join(' ');
}

// English/Roman spelling ke naam ko Urdu script mein transliterate karta hai
// (Google ke input-tools transliteration engine se — wahi jo phone ke Urdu
// keyboard mein use hota hai). Internet na ho ya fail ho jaaye to null
// deta hai, is case mein naam sirf jis language mein aaya tha usi mein dikhega.
Future<String?> _transliterateToUrdu(String englishText) async {
  try {
    final uri = Uri.parse(
      'https://inputtools.google.com/request?text=${Uri.encodeComponent(englishText)}&itc=ur-t-i0-und&num=1&cp=0&cs=1&ie=utf-8&oe=utf-8',
    );
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
// ---------- ADMIN SETTINGS CACHE (end-reminder minute count) ----------
// "Kitne minute pehle namaz khatam hone ka reminder bajna hai" — admin ka
// ye setting yahan cache karte hain, taaki jin end-alarm mein minute count
// title ke saath nahi aata (jaise Isha, jo seedha server push se bajta hai,
// ya kabhi koi bhi end-alarm backup push se bajay), unme bhi sahi minute
// count dikha sakein — taaki HAR namaz ke end-alarm par minute count dikhe.
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

// Agar backend naam "English | اردو" format mein bheje (jaise "Syed Shabbir
// | سید شبیر"), to wahi Urdu hissa dikhta hai (sabse accurate). Warna app
// khud upar ki dictionary se best-effort Urdu transliteration bana leta hai.
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
    if (newName.isEmpty) {
      await prefs.remove('mureed_name');
    } else {
      await prefs.setString('mureed_name', newName);
    }
  }
}

const Map<String, Map<String, String>> kStrings = {
  'en': {
    'app_title': 'Silsila-e-Zahidiya Alarm',
    'mobile_label': 'Mobile Number',
    'set_alarms_btn': 'Set Alarms',
    'battery_btn': '🔋 Open Battery Settings (for alarm without interruption)',
    'overlay_btn': '📱 Allow full-screen alarm (Display over other apps)',
    'event_view_hint': 'Tap to view',
    'no_event_content': 'Nothing to show for this event.',
    'band_karo_btn': '🛑 Stop',
    'default_status': 'Enter your mobile number and tap "Set Alarms".\n(After this they will set automatically every day.)',
    'status_empty_mobile': 'First enter your mobile number.',
    'status_not_registered': 'This mobile number is not registered. Please register/login on the website first.',
    'status_verify_error': 'Problem verifying, please check your internet.',
    'status_fetching': 'Fetching schedule...',
    'status_no_alarms_left': 'No alarms left for today (all have passed).',
    'status_error_prefix': 'Internet or server issue: ',
    'lang_toggle': '🌐 اردو',
    'prayer_start_label': 'Start', 'prayer_end_label': 'End', 'active_now_label': '🟢 Now',
    'minutes_left_suffix': 'minute mein',
    'change_number_label': '✏️ Change mobile number',
  },
  'ur': {
    'app_title': 'سلسلہ زاہدیہ الارم',
    'mobile_label': 'موبائل نمبر',
    'set_alarms_btn': 'الارمز سیٹ کریں',
    'battery_btn': '🔋 بیٹری سیٹنگز کھولیں (الارم بلا رکاوٹ بجنے کے لیے)',
    'overlay_btn': '📱 فل اسکرین الارم کی اجازت دیں (دوسری ایپس کے اوپر دکھائیں)',
    'event_view_hint': 'دیکھنے کے لیے ٹچ کریں',
    'no_event_content': 'اس ایونٹ کے لیے کچھ نہیں ہے۔',
    'band_karo_btn': '🛑 بند کریں',
    'default_status': 'اپنا موبائل نمبر ڈال کر "الارمز سیٹ کریں" دبائیں۔\n(اس کے بعد روز خود بخود سیٹ ہوتے رہیں گے۔)',
    'status_empty_mobile': 'پہلے اپنا موبائل نمبر ڈالیں۔',
    'status_not_registered': 'یہ موبائل نمبر رجسٹرڈ نہیں ہے۔ پہلے ویب سائٹ پر رجسٹر/لاگ ان کریں۔',
    'status_verify_error': 'تصدیق میں مسئلہ ہوا، انٹرنیٹ چیک کریں۔',
    'status_fetching': 'شیڈول لایا جا رہا ہے...',
    'status_no_alarms_left': 'آج کے باقی کوئی الارم نہیں بچا (سب گزر چکے)۔',
    'status_error_prefix': 'انٹرنیٹ یا سرور میں مسئلہ: ',
    'lang_toggle': '🌐 English',
    'prayer_start_label': 'شروع', 'prayer_end_label': 'ختم', 'active_now_label': '🟢 ابھی',
    'minutes_left_suffix': 'منٹ میں',
    'change_number_label': '✏️ موبائل نمبر تبدیل کریں',
  },
};

String tr(String key) => kStrings[AppLang.current]?[key] ?? kStrings['en']![key] ?? key;

// Backend (website) se aane wale Namaz reminder titles fixed pattern mein hote hain
// (jaise "Fajr ki namaz ka waqt ho gaya hai"). Inko yahin app ke andar (dono
// language mein) naye wording ke saath translate kar dete hain, backend badle bina.
const Map<String, String> _prayerNameUr = {
  'Fajr': 'فجر', 'Dhuhr': 'ظہر', 'Asr': 'عصر', 'Maghrib': 'مغرب', 'Isha': 'عشاء',
};

String prayerLabel(String name) => AppLang.current == 'ur' ? (_prayerNameUr[name] ?? name) : name;

// Namaz shuru hone ka message: "Fajr ki namaz ka waqt ab shuru ho gaya hai"
String prayerStartMessage(String prayerName) {
  final name = prayerLabel(prayerName);
  if (AppLang.current == 'ur') {
    return '🕌 $name کی نماز کا وقت اب شروع ہو گیا ہے';
  }
  return '🕌 $name ki namaz ka waqt ab shuru ho gaya hai';
}

// Namaz khatam hone ka message: "Fajr ki namaz ka waqt khatam hone wala hai
// (X minute baaki hai)" — minutesLeft na mile to bina minute ke dikhta hai.
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

// Har namaz ka "shuru" aur "khatam" alarm alag-alag items hote hain (backend se) —
// yahan dono ko ek hi prayer ke naam se jod kar ek group bana dete hain, taaki
// UI mein ek hi box mein dono time (Start + End) dikhein.
List<Map<String, dynamic>> _groupScheduledItems(List<Map<String, dynamic>> items) {
  final Map<String, Map<String, dynamic>> groups = {};
  final List<Map<String, dynamic>> others = [];
  final startRe = _startTitleRe;
  final endRe = _endTitleRe;
  for (final item in items) {
    final title = item['title'] as String;
    final time = item['time'] as DateTime;
    final sm = startRe.firstMatch(title);
    final em = endRe.firstMatch(title);
    if (sm != null) {
      final name = sm.group(1)!;
      groups.putIfAbsent(name, () => <String, dynamic>{'type': 'prayer', 'prayer': name});
      groups[name]!['start'] = time;
    } else if (em != null) {
      final name = em.group(1)!;
      groups.putIfAbsent(name, () => <String, dynamic>{'type': 'prayer', 'prayer': name});
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
  // Namaz ke cards hamesha FIXED (asli) order mein dikhte hain — Fajr,
  // Dhuhr, Asr, Maghrib, Isha — chahe unka start/end time kabhi
  // aapas mein takra jaaye (jaise Fajr ka "start" nikal chuka ho aur sirf
  // "end" bacha ho, jo agli namaz ke start ke barabar hota hai). Pehle
  // sirf time se sort hota tha, jisse kabhi order galat (jaise Dhuhr,
  // Fajr, Asr) dikh jaata tha.
  const prayerOrder = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
  result.sort((a, b) {
    if (a['type'] == 'prayer' && b['type'] == 'prayer') {
      final ia = prayerOrder.indexOf(a['prayer'] as String);
      final ib = prayerOrder.indexOf(b['prayer'] as String);
      return ia.compareTo(ib);
    }
    if (a['type'] == 'prayer' && b['type'] != 'prayer') return -1;
    if (a['type'] != 'prayer' && b['type'] == 'prayer') return 1;
    final DateTime ta = a['time'] as DateTime;
    final DateTime tb = b['time'] as DateTime;
    return ta.compareTo(tb);
  });
  // Jis namaz ka "End" waqt guzar chuka hai (jaise Asr mein Fajr aur Zuhr),
  // use list se hata do — sirf abhi chal rahi aur aane wali namaz dikhe.
  final nowT = DateTime.now();
  result.removeWhere((g) =>
      g['type'] == 'prayer' &&
      g['end'] != null &&
      (g['end'] as DateTime).isBefore(nowT));
  // Event khatam ho jaaye to wo bhi list se hat jaaye
  result.removeWhere((g) =>
      g['type'] == 'other' &&
      g['end'] != null &&
      (g['end'] as DateTime).isBefore(nowT));
  return result;
}

String translateAlarmTitle(String title) {
  // Custom Event/Alarm title agar "English | اردو" format mein likha ho,
  // to sirf usi language ka hissa dikhao jo app mein abhi chuni hui hai
  // (English mode mein English, Urdu mode mein Urdu) — dono mix nahi hote.
  if (title.contains('|')) {
    return pickByLang(title);
  }
  // Namaz "shuru" ka fixed backend title
  final sm = _startTitleRe.firstMatch(title);
  if (sm != null) {
    return prayerStartMessage(sm.group(1)!);
  }
  // Namaz "khatam hone wali hai" ka fixed backend title (minute count sath ho to wo bhi)
  final em = _endTitleRe.firstMatch(title);
  if (em != null) {
    int? mins = em.group(2) != null ? int.tryParse(em.group(2)!) : null;
    // Title ke saath minute count na ho (jaise Isha ka end-alarm, jo seedha
    // server push se bajta hai) to admin ki cached setting use kar lo, taaki
    // HAR namaz ke end-alarm par minute count dikhe.
    mins ??= AppConfig.endMinutesBefore > 0 ? AppConfig.endMinutesBefore : null;
    return prayerEndMessage(em.group(1)!, minutesLeft: mins);
  }
  if (AppLang.current != 'ur') return title;
  if (title == 'Alarm') return 'الارم';
  return title; // custom event/alarm titles jo admin ne khud likhe (bina pipe ke), wo waise hi rahenge
}

// Website jaisa hi Nastaliq font — Urdu mode mein hamesha yehi use hoga,
// chahe phone mein koi bhi Urdu font installed ho ya na ho.
TextStyle appFont([TextStyle? base]) {
  final b = base ?? const TextStyle();
  if (AppLang.current == 'ur') {
    return GoogleFonts.notoNastaliqUrdu(textStyle: b, height: 1.9);
  }
  return b;
}

// Title mein Urdu aur English saath ho (jaise "Zanana Class / زنانہ کلاس") to
// sirf Urdu wale hisse ko Nastaliq font dete hain, baaki English normal font
// mein — chahe app abhi English mode mein ho ya Urdu mode mein.
const String _urduChars = '\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF\u200C\u200D';
final RegExp _urduRun = RegExp('[$_urduChars]+(?:\\s+[$_urduChars]+)*');

TextSpan mixedTextSpan(String text, TextStyle base) {
  final children = <InlineSpan>[];
  int last = 0;
  for (final m in _urduRun.allMatches(text)) {
    if (m.start > last) {
      children.add(TextSpan(text: text.substring(last, m.start)));
    }
    children.add(TextSpan(
      text: m.group(0),
      style: GoogleFonts.notoNastaliqUrdu(textStyle: base, height: 1.9),
    ));
    last = m.end;
  }
  if (last < text.length) {
    children.add(TextSpan(text: text.substring(last)));
  }
  return TextSpan(style: base, children: children);
}

class MixedText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  const MixedText(this.text, {super.key, this.style, this.textAlign});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      mixedTextSpan(text, style ?? const TextStyle()),
      textAlign: textAlign,
    );
  }
}

String trSetSuccess(int count) => AppLang.current == 'ur'
    ? '$count الارم سیٹ ہو گئے۔ اب روز خود بخود سیٹ ہوتے رہیں گے۔'
    : '$count alarm(s) set. They will now set automatically every day.';

class ZahidiyaAlarmApp extends StatelessWidget {
  const ZahidiyaAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Silsila-e-Zahidiya Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// Alarm bajte hi yeh bada, saaf screen dikhta hai — "Band Karo" button
// hamesha turant nazar aayega, chhota/chhupa hua nahi. Sabse upar (agar
// pata ho) mureed ka naam bhi dikhta hai.
// Event ka text ("English \n[[UR]]\n اردو" format mein save hota hai) — sirf
// app ki chuni hui language ka hissa dikhao.
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

// Event ka text / image / audio / PDF alarm app ke andar hi dikhata hai.
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
    return u.startsWith('/') ? 'https://zahidiya-mysore.pages.dev$u' : u;
  }

  // Kisi bhi YouTube link (video ya /live/...) se uski ID nikalta hai, taaki
  // use isi screen ke andar (embed) dikhaya ja sake — YouTube app nahi khulti
  String? get _youtubeId {
    final m = RegExp(r'(?:youtu\.be/|youtube\.com/(?:watch\?v=|live/|embed/|shorts/))([A-Za-z0-9_-]{6,})')
        .firstMatch(widget.fileUrl);
    return m?.group(1);
  }

  @override
  void initState() {
    super.initState();
    if (widget.fileUrl.isEmpty) return;
    if (widget.contentType == 'pdf') {
      // PDF ko Google ke viewer se app ke andar hi dikhate hain
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse('https://docs.google.com/gview?embedded=true&url=${Uri.encodeComponent(_url)}'));
    } else if (widget.contentType == 'youtube') {
      final id = _youtubeId;
      if (id != null) {
        _web = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.black)
          ..loadRequest(Uri.parse('https://www.youtube.com/embed/$id?autoplay=1&playsinline=1'));
      }
    } else if (widget.contentType == 'video') {
      final safe = _url.replaceAll('"', '%22');
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..loadHtmlString(
          '<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>'
          '<body style="margin:0;background:#000;display:flex;align-items:center;justify-content:center;height:100vh;">'
          '<video controls autoplay playsinline style="max-width:100%;max-height:100%" src="$safe"></video></body></html>',
        );
    } else if (widget.contentType == 'audio') {
      final safe = _url.replaceAll('"', '%22');
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF0F2A0F))
        ..loadHtmlString(
          '<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>'
          '<body style="margin:0;background:#0f2a0f;display:flex;align-items:center;justify-content:center;height:100vh;">'
          '<audio controls style="width:92%" src="$safe"></audio></body></html>',
        );
    }
  }

  Widget _body() {
    final type = widget.contentType;
    if (type == 'text') {
      final txt = eventTextForLang(widget.contentText);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: MixedText(
          txt.isEmpty ? tr('no_event_content') : txt,
          style: const TextStyle(fontSize: 18, height: 1.6),
        ),
      );
    }
    if (type == 'image' && widget.fileUrl.isNotEmpty) {
      return InteractiveViewer(
        child: Center(
          child: Image.network(
            _url,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const Center(child: CircularProgressIndicator()),
            errorBuilder: (context, error, stack) =>
                Center(child: Text(tr('no_event_content'), style: appFont())),
          ),
        ),
      );
    }
    if (_web != null) return WebViewWidget(controller: _web!);
    if (type == 'youtube') {
      // Sahi YouTube link nahi mila
      return Center(child: Text(tr('no_event_content'), style: appFont()));
    }
    return Center(child: Text(tr('no_event_content'), style: appFont()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MixedText(widget.title, style: const TextStyle(color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.green,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _body(),
    );
  }
}

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
                    MixedText(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Icon(Icons.alarm, color: Colors.white, size: 90),
                  const SizedBox(height: 24),
                  MixedText(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 60),
                  ElevatedButton(
                    onPressed: () async {
                      await _stopRingingOnly();
                      try { await WakelockPlus.disable(); } catch (_) {}
                      if (navigatorKey.currentState?.canPop() ?? false) {
                        navigatorKey.currentState?.pop();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(tr('band_karo_btn'), style: appFont(const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _mobileController = TextEditingController();
  String _statusKind = 'default';
  int _statusCount = 0;
  String _statusErrorDetail = '';

  // _status ko seedha translated string ki jagah "kind" store karte hain,
  // taake language toggle karne par purana (stale) translation na reh jaaye —
  // build() ke waqt hamesha current language mein dobara translate hota hai.
  String get _status {
    switch (_statusKind) {
      case 'empty_mobile': return tr('status_empty_mobile');
      case 'not_registered': return tr('status_not_registered');
      case 'verify_error': return tr('status_verify_error');
      case 'fetching': return tr('status_fetching');
      case 'no_alarms_left': return tr('status_no_alarms_left');
      case 'success': return trSetSuccess(_statusCount);
      case 'error': return tr('status_error_prefix') + _statusErrorDetail;
      default: return tr('default_status');
    }
  }
  List<Map<String, dynamic>> _scheduledItems = [];
  bool _loading = false;
  String? _fcmToken;
  // Jab tak mobile number pehle se save nahi hai, tab tak number field
  // dikhta hai. Login (verify) kamyaab hote hi ye field hat jaata hai aur
  // sirf naam dikhta hai — number background mein save rehta hai.
  bool _showMobileField = true;
  static const _screenChannel = MethodChannel('zahidiya.alarm/screen');

  Timer? _highlightRefreshTimer;
  DateTime _lastFetched = DateTime.now();

  // Chup-chaap (bina status badle) naya schedule le aata hai — taaki agli
  // subah Fajr se list phir shuru ho jaaye, app dobara khole bina.
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

  // Alarm wala bada "Band Karo" screen kholta hai (agar pehle se khula na ho).
  void _openRingingScreen(String body) {
    if (_ringingScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _ringingScreenOpen = true;
    nav
        .push(MaterialPageRoute(
          builder: (_) => AlarmRingingScreen(title: translateAlarmTitle(body.isNotEmpty ? body : 'Alarm')),
          fullscreenDialog: true,
        ))
        .then((_) {
      _ringingScreenOpen = false;
    });
  }

  @override
  void initState() {
    super.initState();
    // _status ab getter hai (upar dekho), initState mein set karne ki zaroorat nahi
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadSavedMobile();
    _setupFCM();
    // Agar app alarm bajte waqt hi khuli (jaise alarm ne khud app aage laayi),
    // to pehle frame ke baad turant bada "Band Karo" screen dikhao.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ringing = Alarm.ringing.value;
      if (ringing.alarms.isNotEmpty) {
        _openRingingScreen(ringing.alarms.first.notificationSettings.body);
      }
    });
    // Har minute UI ko refresh karte hain taaki "abhi kaunsi namaz chal rahi
    // hai" wala gold border turant sahi waqt par update ho (na ki sirf
    // dobara app kholne par).
    _highlightRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      setState(() {});
      // Saari namaz guzar jaayein (Isha bhi khatam) to naya din ka schedule le aao
      final hasPrayerLeft = _groupScheduledItems(_scheduledItems).any((g) => g['type'] == 'prayer');
      if (!hasPrayerLeft && DateTime.now().difference(_lastFetched) > const Duration(minutes: 10)) {
        _silentRefresh();
      }
    });
    // Power button dabakar screen OFF/lock hote hi (native side se signal
    // aayega), baj raha alarm turant band kar do.
    _screenChannel.setMethodCallHandler((call) async {
      if (call.method == 'screenOff') {
        await _stopRingingOnly();
        try { await WakelockPlus.disable(); } catch (_) {}
      }
    });
    // Alarm bajte hi apna bada "Band Karo" wala screen turant dikha do.
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
      // Pehle yahan alarm turant band ho jaata tha. Ab app khulte hi (ya
      // alarm ke waqt khud aage aate hi) agar alarm baj raha hai to bada
      // "Band Karo" screen dikhta hai — alarm sirf button dabane se band hoga.
      final ringing = Alarm.ringing.value;
      if (ringing.alarms.isNotEmpty) {
        _openRingingScreen(ringing.alarms.first.notificationSettings.body);
      }
      // Kaafi der baad app khuli to list purani ho sakti hai — naya le aao
      if (DateTime.now().difference(_lastFetched) > const Duration(minutes: 10)) {
        _silentRefresh();
      }
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
      if (mobile != null && mobile.isNotEmpty) {
        await sendTokenToBackend(mobile, token);
      }
    }

    // App khuli/foreground mein ho tab bhi push aane par turant alarm bajao
    fcm.FirebaseMessaging.onMessage.listen((fcm.RemoteMessage message) {
      if (message.data['type'] == 'refresh_settings') {
        SharedPreferences.getInstance().then((prefs) {
          final mobile = prefs.getString('mobile');
          if (mobile != null && mobile.isNotEmpty) {
            fetchAndScheduleForMobile(mobile);
          }
        });
        return;
      }
      // App pehle se khuli hai, isliye overlay ki zaroorat nahi
      triggerImmediateAlarm(_titleFromMessage(message), durationSeconds: _durationFromMessage(message), category: _categoryFromMessage(message), showOverlay: false);
    });
  }

  Future<void> _loadSavedMobile() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('mobile');
    if (saved != null) {
      _mobileController.text = saved;
      setState(() {
        _showMobileField = false; // pehle se login hai, seedha naam dikhao
      });
      // Number pehle se saved hai — matlab pehli baar "Set Alarms" pehle
      // ho chuka hai. Ab dobara app khulte hi (chahe naya APK update ho ya
      // phone restart ho) yeh khud-b-khud dobara register/refresh ho jaata
      // hai, taaki user ko kabhi bhi manually button dabana na pade.
      _fetchAndScheduleAlarms();
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();
    await Permission.scheduleExactAlarm.request();
    await Permission.ignoreBatteryOptimizations.request();
    // "Display over other apps" — isi se alarm phone unlock hone par bhi
    // full screen aa sakta hai. Sirf ek baar khud maangte hain.
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
      setState(() {
        _statusKind = 'empty_mobile';
      });
      return;
    }    final verifyUri = Uri.parse('https://zahidiya-mysore.pages.dev/api/verify-mobile?mobile=$mobile');
    try {
      final verifyRes = await http.get(verifyUri).timeout(const Duration(seconds: 15));
      final verifyData = jsonDecode(verifyRes.body);
      if (verifyData['registered'] != true) {
        setState(() {
          _statusKind = 'not_registered';
        });
        return;
      }
      // Login kamyaab — ab number field hata kar sirf naam dikhao
      setState(() {
        _showMobileField = false;
      });
      // Backend agar mureed ka naam bhejta hai (verify-mobile response mein
      // "name" field), to use save kar lete hain — alarm bajte waqt sabse
      // upar dikhane ke liye. Agar naam mein Urdu script nahi hai (i.e.
      // Roman/English mein likha hai), to khud-ba-khud uska Urdu version bhi
      // nikaal kar "English | Urdu" format mein save karte hain, taaki naam
      // bhi baaki page ki tarah language ke hisaab se badalta rahe.
      final String? fetchedName = verifyData['name']?.toString();
      if (fetchedName != null && fetchedName.trim().isNotEmpty) {
        final String cleanName = fetchedName.trim();
        final bool alreadyBilingual = cleanName.contains('|');
        final bool hasUrduScript = RegExp('[\u0600-\u06FF]').hasMatch(cleanName);
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
      setState(() {
        _statusKind = 'verify_error';
      });
      return;
    }

    setState(() {
      _loading = true;
      _statusKind = 'fetching';
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mobile', mobile);

    // Ab jo bhi FCM token pehle se mil chuka hai, use bhi is mobile se link kar do
    if (_fcmToken != null) {
      await sendTokenToBackend(mobile, _fcmToken!);
    }

    try {
      final items = await fetchAndScheduleForMobile(mobile, force: true);
      _lastFetched = DateTime.now();
      setState(() {
        _loading = false;
        _scheduledItems = items;
        if (items.isNotEmpty) {
          _statusKind = 'success';
          _statusCount = items.length;
        } else {
          _statusKind = 'no_alarms_left';
        }
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
          AppUser.displayName.trim().isNotEmpty ? AppUser.displayName : tr('app_title'),
          style: appFont(),
        ),
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
                      textStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      height: 1.9,
                    )
                  : const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                  border: const OutlineInputBorder(),
                ),
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
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : Text(tr('set_alarms_btn'), style: appFont()),
              ),
            ] else ...[
              // Login ho chuka hai — number ki jagah sirf naam dikhta hai
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.green, width: 1.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: MixedText(
                  AppUser.displayName.trim().isNotEmpty ? AppUser.displayName : _mobileController.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () {
                    setState(() {
                      _showMobileField = true;
                    });
                  },
                  child: Text(tr('change_number_label'), style: appFont(const TextStyle(fontSize: 13))),
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await openAppSettings();
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              child: Text(tr('battery_btn'), style: appFont()),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await Permission.systemAlertWindow.request();
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              child: Text(tr('overlay_btn'), style: appFont()),
            ),
            const SizedBox(height: 16),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: appFont(const TextStyle(fontSize: 15)),
            ),
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
                      // Abhi konsi namaz "active" hai (start aur end ke beech) —
                      // usko gold border se highlight karte hain, taaki sirf
                      // app kholte hi pata chal jaaye ki abhi kaunsi namaz ka
                      // waqt chal raha hai, kisi button dabane ki zaroorat nahi.
                      final bool isActive = start != null && end != null &&
                          now.isAfter(start) && now.isBefore(end);
                      return Card(
                        shape: isActive
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xFFFFD700), width: 2.5),
                              )
                            : null,
                        color: isActive ? const Color(0xFFFFFBEA) : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.alarm, color: Colors.green),
                                  const SizedBox(width: 10),
                                  Text(prayerLabel(g['prayer'] as String), style: appFont(const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                                  if (isActive) ...[
                                    const SizedBox(width: 8),
                                    Text(tr('active_now_label'), style: appFont(const TextStyle(color: Color(0xFFB8860B), fontWeight: FontWeight.bold, fontSize: 12))),
                                  ],
                                ],
                              ),
                              const Divider(height: 14),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(tr('prayer_start_label'), style: appFont(const TextStyle(color: Colors.black54))),
                                  Text(start != null ? _formatTime(start) : '—', style: appFont()),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(tr('prayer_end_label'), style: appFont(const TextStyle(color: Colors.black54))),
                                  Text(end != null ? _formatTime(end) : '—', style: appFont()),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    final String cType = (g['contentType'] ?? 'none').toString();
                    final String cText = (g['contentText'] ?? '').toString();
                    final String cUrl = (g['fileUrl'] ?? '').toString();
                    final bool hasContent = (cType == 'text' && cText.trim().isNotEmpty) ||
                        (cType != 'text' && cType != 'none' && cUrl.isNotEmpty);
                    return Card(
                      child: ListTile(
                        leading: Icon(hasContent ? Icons.attach_file : Icons.alarm, color: Colors.green),
                        title: MixedText(translateAlarmTitle(g['title'] as String)),
                        subtitle: hasContent
                            ? Text(tr('event_view_hint'), style: appFont(const TextStyle(fontSize: 12, color: Colors.green)))
                            : null,
                        trailing: Text(_formatTime(g['time'] as DateTime), style: appFont()),
                        onTap: hasContent
                            ? () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => EventContentScreen(
                                    title: translateAlarmTitle(g['title'] as String),
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
