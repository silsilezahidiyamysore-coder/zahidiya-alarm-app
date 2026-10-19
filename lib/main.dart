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
  String currentLanguage = 'english'; // Default language
  Map<String, dynamic> appConfig = {}; // Config store karne ke liye
  bool isLoading = true;

  // Website se data uthane ka function
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
        setState(() => isLoading = false); // Error aaye toh load band karo
      }
    } catch (e) {
      // Agar internet nahi hai, toh app crash nahi hogi, bas error dikhayegi
      setState(() => isLoading = false);
      print("Error fetching config: $e");
    }
  }

  @override
  void initState() {
    super.initState();
    fetchConfig(); // App open hote hi data laao
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()), // Loading spinner
      );
    }

    // Agar config load nahi hua toh default message
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

    // Text nikalne ka logic (Language ke hisaab se)
    String title = appConfig['texts'][currentLanguage]['isha_reminder_title'] ?? 'No Title';
    String message = appConfig['texts'][currentLanguage]['isha_reminder_message'] ?? 'No Message';

    return Scaffold(
      appBar: AppBar(
        title: const Text("Zahidiya Alarm"),
        actions: [
          // Language Toggle Buttons
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
              // Title
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                // Urdu ke liye Nastaliq font (agar phone me installed hai)
                textDirection: currentLanguage == 'urdu' ? TextDirection.rtl : TextDirection.ltr,
              ),
              const SizedBox(height: 20),
              
              // Message
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
                textDirection: currentLanguage == 'urdu' ? TextDirection.rtl : TextDirection.ltr,
              ),
              
              const SizedBox(height: 40),
              // Admin Panel Status dikhane ke liye
              Text(
                "Reminders Enabled: ${appConfig['remindersEnabled']}",
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
