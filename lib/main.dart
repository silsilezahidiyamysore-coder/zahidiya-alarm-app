import 'dart:async';
import 'package:flutter/material.dart';
import 'package:alarm/alarm.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  runApp(const ZahidiyaAlarmApp());
}

class ZahidiyaAlarmApp extends StatelessWidget {
  const ZahidiyaAlarmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zahidiya Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.green,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Ready. Neeche button dabao.';
  StreamSubscription<AlarmSet>? _ringSub;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _ringSub = Alarm.ringing.listen((alarmSet) {
      if (alarmSet.alarms.isNotEmpty) {
        setState(() {
          _status = '🔔 ALARM BAJ RAHA HAI! Notification mein "Stop" dabao.';
        });
      }
    });
  }

  @override
  void dispose() {
    _ringSub?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();
    await Permission.scheduleExactAlarm.request();
  }

  Future<void> _setTestAlarm() async {
    final alarmSettings = AlarmSettings(
      id: 1,
      dateTime: DateTime.now().add(const Duration(seconds: 10)),
      loopAudio: true,
      vibrate: true,
      androidFullScreenIntent: true,
      volumeSettings: VolumeSettings.fixed(volume: 1.0),
      notificationSettings: const NotificationSettings(
        title: 'Zahidiya Alarm - Test',
        body: 'Yeh test alarm hai. Silent mode mein bhi bajna chahiye.',
        stopButton: 'Band Karo',
      ),
    );
    await Alarm.set(alarmSettings: alarmSettings);
    setState(() {
      _status = '10 second mein alarm bajega... Ab phone SILENT/MUTE kar do!';
    });
  }

  Future<void> _stopAlarm() async {
    await Alarm.stop(1);
    setState(() {
      _status = 'Alarm band ho gaya. Dubara test karne ke liye upar wala button dabao.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zahidiya Alarm'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.alarm, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _setTestAlarm,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                '10 Second Baad Test Alarm Bajao',
                style: TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _stopAlarm,
              child: const Text('Alarm Abhi Band Karo'),
            ),
          ],
        ),
      ),
    );
  }
}
