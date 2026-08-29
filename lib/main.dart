import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:alarm/alarm.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String scheduleUrlBase =
    'https://zahidiya-mysore.pages.dev/api/get-alarm-schedule';

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

int idFromString(String s) {
  int hash = 0;
  for (final unit in s.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash % 1000000;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _mobileController = TextEditingController();
  String _status = 'Apna mobile number daal kar "Alarms Set Karo" dabao.';
  List<Map<String, dynamic>> _scheduledItems = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadSavedMobile();
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
  }

  Future<void> _fetchAndScheduleAlarms() async {
    final mobile = _mobileController.text.trim();
    if (mobile.isEmpty) {
      setState(() {
        _status = 'Pehle apna mobile number daalo.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Schedule laaya ja raha hai...';
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mobile', mobile);

    try {
      final uri = Uri.parse('$scheduleUrlBase?mobile=$mobile');
      final response = await http.get(uri).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        setState(() {
          _loading = false;
          _status = 'Server se jawab nahi mila (${response.statusCode}). Dubara try karo.';
        });
        return;
      }

      final data = jsonDecode(response.body);
      if (data['success'] != true) {
        setState(() {
          _loading = false;
          _status = 'Error: ${data['message'] ?? 'Kuch galat hua'}';
        });
        return;
      }

      final List<dynamic> schedule = data['schedule'] ?? [];
      final now = DateTime.now();
      int setCount = 0;
      final List<Map<String, dynamic>> shownItems = [];

      for (final item in schedule) {
        final String id = item['id'];
        final String title = item['title'];
        final String dateTimeStr = item['dateTime'];
        final DateTime dt = DateTime.parse(dateTimeStr).toLocal();

        // Sirf aane wale (future) alarms set karo, guzre hue nahi
        if (dt.isBefore(now)) continue;

        final int alarmId = idFromString(id);
        final alarmSettings = AlarmSettings(
          id: alarmId,
          dateTime: dt,
          loopAudio: true,
          vibrate: true,
          androidFullScreenIntent: true,
          volumeSettings: VolumeSettings.fixed(volume: 1.0),
          notificationSettings: NotificationSettings(
            title: 'Zahidiya Alarm',
            body: title,
            stopButton: 'Band Karo',
          ),
        );
        await Alarm.set(alarmSettings: alarmSettings);
        setCount++;
        shownItems.add({'title': title, 'time': dt});
      }

      shownItems.sort((a, b) => (a['time'] as DateTime).compareTo(b['time'] as DateTime));

      setState(() {
        _loading = false;
        _scheduledItems = shownItems;
        _status = setCount > 0
            ? '$setCount alarm(s) set ho gaye. Neeche list dekho.'
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
        title: const Text('Zahidiya Alarm'),
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
