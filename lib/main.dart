import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:alarm/alarm.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart' as fcm;

const String scheduleUrlBase =
    'https://zahidiya-mysore.pages.dev/api/get-alarm-schedule';
const String saveFcmTokenUrl =
    'https://zahidiya-mysore.pages.dev/api/save-fcm-token';
const String dailySyncTaskName = 'zahidiyaDailyAlarmSync';

// Admin ka upload kiya hua common ringtone download karke phone mein save karta hai
// (taaki app band/FCM push ke waqt bhi bina internet ke bhi use ho sake).
// Agar URL pehle jaisa hi hai to dobara download nahi karta.
Future<String?> _getLocalTonePath(String? toneUrl) async {
  if (toneUrl == null || toneUrl.isEmpty) return null;
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/custom_alarm_tone.mp3');
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('cached_tone_url');

    if (savedUrl == toneUrl && await file.exists()) {
      return file.path;
    }

    final response = await http.get(Uri.parse(toneUrl)).timeout(const Duration(seconds: 20));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      await prefs.setString('cached_tone_url', toneUrl);
      return file.path;
    }
  } catch (e) {
    // Download fail ho to purani cached file (agar ho) use kar lo
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/custom_alarm_tone.mp3');
      if (await file.exists()) return file.path;
    } catch (_) {}
  }
  return null;
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

// Backend se schedule laakar real alarms set karta hai.
// Yeh function App ke andar (button dabane par) aur background
// (Workmanager ke through, roz apne aap) — dono jagah use hota hai.
Future<List<Map<String, dynamic>>> fetchAndScheduleForMobile(String mobile) async {
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
  final int durationSeconds = data['start_alarm_duration_seconds'] ?? 60;
  final String? localTonePath = await _getLocalTonePath(toneUrl);
  final now = DateTime.now();
  final List<Map<String, dynamic>> shownItems = [];

  for (final item in schedule) {
    final String id = item['id'];
    final String title = item['title'];
    final String dateTimeStr = item['dateTime'];
    final DateTime dt = DateTime.parse(dateTimeStr).toLocal();

    if (dt.isBefore(now)) continue;

    final int alarmId = idFromString(id);
    final alarmSettings = AlarmSettings(
      id: alarmId,
      dateTime: dt,
      assetAudioPath: localTonePath,
      loopAudio: true,
      vibrate: true,
      androidFullScreenIntent: true,
      volumeSettings: VolumeSettings.fixed(volume: 1.0),
      notificationSettings: NotificationSettings(
        title: 'Silsila-e-Zahidiya Alarm',
        body: title,
        stopButton: 'Band Karo',
      ),
    );
    await Alarm.set(alarmSettings: alarmSettings);
    await _scheduleStopAlarm(alarmId, dt, durationSeconds);
    shownItems.add({'title': title, 'time': dt});
  }

  shownItems.sort((a, b) => (a['time'] as DateTime).compareTo(b['time'] as DateTime));
  return shownItems;
}

// Sirf pehle se cache mein saved tone file uthata hai — download nahi karta
// (push aane ke waqt turant alarm bajna zaroori hai, download ka wait nahi karna).
Future<String?> _getCachedTonePathOnly() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/custom_alarm_tone.mp3');
    if (await file.exists()) return file.path;
  } catch (_) {}
  return null;
}

// FCM se push aane par turant loud alarm bajata hai (Live/Class shuru hone ka signal).
Future<void> triggerImmediateAlarm(String title) async {
  await Alarm.init();
  final int alarmId = idFromString('live_${DateTime.now().millisecondsSinceEpoch}');
  final localTonePath = await _getCachedTonePathOnly();
  final alarmSettings = AlarmSettings(
    id: alarmId,
    dateTime: DateTime.now().add(const Duration(seconds: 2)),
    assetAudioPath: localTonePath,
    loopAudio: true,
    vibrate: true,
    androidFullScreenIntent: true,
    volumeSettings: VolumeSettings.fixed(volume: 1.0),
    notificationSettings: NotificationSettings(
      title: 'Silsila-e-Zahidiya Alarm',
      body: title,
      stopButton: 'Band Karo',
    ),
  );
  await Alarm.set(alarmSettings: alarmSettings);
}

String _titleFromMessage(fcm.RemoteMessage message) {
  return message.notification?.title ??
      message.data['title'] ??
      'Live Shuru Ho Gaya';
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
        await fetchAndScheduleForMobile(mobile);
      }
    } catch (e) {}
    return;
  }
  await triggerImmediateAlarm(_titleFromMessage(message));
}

// Yeh function background isolate mein chalta hai, jab AndroidAlarmManager
// roz khud-ba-khud is app ko "jagakar" naye alarms set karwata hai.
// Raat ko fix time (1:00 AM) par sync chalane ke liye — Fajr se kaafi pehle.
// AndroidAlarmManager (exact + wakeup) WorkManager se zyada bharosemand hai
// kyunki ye Doze/battery-saver mode mein bhi guaranteed time par jaagta hai.
DateTime _next1AM() {
  final now = DateTime.now();
  var target = DateTime(now.year, now.month, now.day, 1, 0);
  if (!now.isBefore(target)) {
    target = target.add(const Duration(days: 1));
  }
  return target;
}

const int nightlySyncAlarmId = 900001;

Future<void> _scheduleNightlySync() async {
  await AndroidAlarmManager.oneShotAt(
    _next1AM(),
    nightlySyncAlarmId,
    _nightlySyncCallback,
    exact: true,
    wakeup: true,
    rescheduleOnReboot: true,
  );
}

@pragma('vm:entry-point')
void _nightlySyncCallback() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final prefs = await SharedPreferences.getInstance();
    final mobile = prefs.getString('mobile');
    if (mobile != null && mobile.isNotEmpty) {
      await fetchAndScheduleForMobile(mobile);
    }
  } catch (e) {
    // Background mein fail ho to bhi crash na ho, agli baar phir try hoga
  }
  // Agli raat 1 baje ke liye dobara khud ko schedule kar do
  await _scheduleNightlySync();
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
      } catch (e) {}
    }
    return Future.value(true);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  fcm.FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await Alarm.init();
  await AndroidAlarmManager.initialize();

  // stopAlarmTask (duration ke baad alarm band karna) ke liye Workmanager
  // abhi bhi use hota hai — ye chhota/short-delay kaam hai.
  await Workmanager().initialize(callbackDispatcher);
  await _scheduleNightlySync();

  runApp(const ZahidiyaAlarmApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

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
// hamesha turant nazar aayega, chhota/chhupa hua nahi.
class AlarmRingingScreen extends StatelessWidget {
  final String title;
  const AlarmRingingScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
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
                  const Icon(Icons.alarm, color: Colors.white, size: 90),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 60),
                  ElevatedButton(
                    onPressed: () async {
                      await Alarm.stopAll();
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
                    child: const Text('🛑 Band Karo', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
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
  String _status = 'Apna mobile number daal kar "Alarms Set Karo" dabao.\n(Iske baad roz apne aap set hote rahenge.)';
  List<Map<String, dynamic>> _scheduledItems = [];
  bool _loading = false;
  String? _fcmToken;
  static const _screenChannel = MethodChannel('zahidiya.alarm/screen');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadSavedMobile();
    _setupFCM();
    // Power button dabakar screen OFF/lock hote hi (native side se signal
    // aayega), baj raha alarm turant band kar do.
    _screenChannel.setMethodCallHandler((call) async {
      if (call.method == 'screenOff') {
        await Alarm.stopAll();
      }
    });
    // Alarm bajte hi apna bada "Band Karo" wala screen turant dikha do.
    Alarm.ringing.listen((alarmSet) {
      final isRinging = alarmSet.alarms.isNotEmpty;
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      if (isRinging) {
        final title = alarmSet.alarms.first.notificationSettings.body;
        nav.push(MaterialPageRoute(
          builder: (_) => AlarmRingingScreen(title: title.isNotEmpty ? title : 'Alarm'),
          fullscreenDialog: true,
        ));
      } else {
        if (nav.canPop()) nav.pop();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Screen ON / app foreground hote hi baj raha alarm band kar do
      Alarm.stopAll();
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
      triggerImmediateAlarm(_titleFromMessage(message));
    });
  }

  Future<void> _loadSavedMobile() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('mobile');
    if (saved != null) {
      _mobileController.text = saved;
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();
    await Permission.scheduleExactAlarm.request();
    await Permission.ignoreBatteryOptimizations.request();
  }

  Future<void> _fetchAndScheduleAlarms() async {
    final mobile = _mobileController.text.trim();
    if (mobile.isEmpty) {
      setState(() {
        _status = 'Pehle apna mobile number daalo.';
      });
      return;
    }    final verifyUri = Uri.parse('https://zahidiya-mysore.pages.dev/api/verify-mobile?mobile=$mobile');
    try {
      final verifyRes = await http.get(verifyUri).timeout(const Duration(seconds: 15));
      final verifyData = jsonDecode(verifyRes.body);
      if (verifyData['registered'] != true) {
        setState(() {
          _status = 'Yeh mobile number registered nahi hai. Pehle website par register/login karo.';
        });
        return;
      }
    } catch (e) {
      setState(() {
        _status = 'Verify karne mein dikkat aayi, internet check karo.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Schedule laaya ja raha hai...';
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mobile', mobile);

    // Ab jo bhi FCM token pehle se mil chuka hai, use bhi is mobile se link kar do
    if (_fcmToken != null) {
      await sendTokenToBackend(mobile, _fcmToken!);
    }

    try {
      final items = await fetchAndScheduleForMobile(mobile);
      setState(() {
        _loading = false;
        _scheduledItems = items;
        _status = items.isNotEmpty
            ? '${items.length} alarm(s) set ho gaye. Ab roz apne aap set hote rahenge.'
            : 'Aaj ke baaki koi alarm nahi bacha (sab guzar chuke).';
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _status = 'Internet ya server mein dikkat: $e';
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
        title: const Text('Silsila-e-Zahidiya Alarm'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            TextField(
              controller: _mobileController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile Number',
                border: OutlineInputBorder(),
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
                  : const Text('Alarms Set Karo'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                await openAppSettings();
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              child: const Text('🔋 Battery Settings Kholo (Alarm bina rukawat bajne ke liye)'),
            ),
            const SizedBox(height: 16),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _scheduledItems.length,
                itemBuilder: (context, index) {
                  final item = _scheduledItems[index];
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.alarm, color: Colors.green),
                      title: Text(item['title']),
                      trailing: Text(_formatTime(item['time'] as DateTime)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
