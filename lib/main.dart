import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zahidiya Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.green),
      home: const AlarmScreen(),
    );
  }
}

class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key});

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> {
  String currentLanguage = 'english';
  Map<String, dynamic> appConfig = {};
  bool isLoading = true;

  // Data fetch karne ka function
  Future<void> fetchConfig() async {
    try {
      final response = await http.get(
        Uri.parse('https://zahidiya-mysore.pages.dev/config.json'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        setState(() {
          appConfig = jsonDecode(response.body);
          isLoading = false;
        });
      } else {
        setState(() => isLoading = false);
      }
    } catch (e) {
      setState(() => isLoading = false);
      print("Error fetching config: $e");
    }
  }

  @override
  void initState() {
    super.initState();
    fetchConfig();
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (appConfig.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text("Error")),
        body: Center(
          child: ElevatedButton(
            onPressed: () {
              setState(() => isLoading = true);
              fetchConfig();
            },
            child: const Text("Retry (Internet check karein)"),
          ),
        ),
      );
    }

    String title = appConfig['texts']?[currentLanguage]?['isha_reminder_title'] ?? 'No Title';
    String message = appConfig['texts']?[currentLanguage]?['isha_reminder_message'] ?? 'No Message';

    return Scaffold(
      appBar: AppBar(
        title: const Text("Zahidiya Alarm"),
        actions: [
          TextButton(
            onPressed: () => setState(() => currentLanguage = 'english'),
            child: const Text("EN", style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => setState(() => currentLanguage = 'urdu'),
            child: const Text("اردو", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textDirection: currentLanguage == 'urdu' ? TextDirection.rtl : TextDirection.ltr,
              ),
              const SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
                textDirection: currentLanguage == 'urdu' ? TextDirection.rtl : TextDirection.ltr,
              ),
              const SizedBox(height: 40),
              Text(
                "Reminders: ${appConfig['remindersEnabled'] == true ? 'ON' : 'OFF'}",
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
