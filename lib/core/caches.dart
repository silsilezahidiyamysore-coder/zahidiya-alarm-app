// ============================================================
// CACHES
// Server se data fetch karke memory + SharedPreferences mein save
// ============================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';

// ============ CACHE STORAGE ============
Map<String, Map<String, String>> _prayerMessagesCache = {};
Map<String, Map<String, String>> _prayerNamesCache = {};
List<Map<String, dynamic>> _menuItemsCache = [];

// ============ PUBLIC GETTERS ============
Map<String, Map<String, String>> get prayerMessagesCache => _prayerMessagesCache;
Map<String, Map<String, String>> get prayerNamesCache => _prayerNamesCache;
List<Map<String, dynamic>> get menuItemsCache => _menuItemsCache;

// ============ FETCH FROM SERVER ============
Future<void> fetchPrayerMessages() async {
  try {
    final res = await http
        .get(Uri.parse(getPrayerMessagesUrl))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final data = jsonDecode(res.body);
    if (data['success'] != true) return;
    final Map<String, Map<String, String>> newCache = {};
    for (final m in (data['messages'] as List)) {
      final String key = '${m['prayer']}_${m['msg_type']}';
      newCache[key] = {
        'ur': (m['message_ur'] ?? '').toString(),
        'en': (m['message_en'] ?? '').toString(),
      };
    }
    _prayerMessagesCache = newCache;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrayerMessagesPrefs, jsonEncode(newCache));
  } catch (_) {}
}

Future<void> fetchPrayerNames() async {
  try {
    final res = await http
        .get(Uri.parse(getPrayerNamesUrl))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final data = jsonDecode(res.body);
    if (data['success'] != true) return;
    final Map<String, Map<String, String>> newCache = {};
    for (final n in (data['names'] as List)) {
      final String key = (n['prayer'] ?? '').toString();
      newCache[key] = {
        'ur': (n['name_ur'] ?? '').toString(),
        'en': (n['name_en'] ?? '').toString(),
      };
    }
    _prayerNamesCache = newCache;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrayerNamesPrefs, jsonEncode(newCache));
  } catch (_) {}
}

Future<void> fetchMenuItems() async {
  try {
    final res = await http
        .get(Uri.parse(getMenuItemsUrl))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return;
    final data = jsonDecode(res.body);
    if (data['success'] != true) return;
    final List<dynamic> items = data['items'] ?? [];
    _menuItemsCache = items.map((e) => Map<String, dynamic>.from(e)).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kMenuItemsPrefs, jsonEncode(_menuItemsCache));
  } catch (_) {}
}

// ============ FETCH ALL (parallel) ============
Future<void> fetchRemoteCaches() async {
  await Future.wait([
    fetchPrayerMessages(),
    fetchPrayerNames(),
    fetchMenuItems(),
  ]);
}

// ============ LOAD FROM SharedPreferences ============
Future<void> loadCachesFromPrefs() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    final msgJson = prefs.getString(kPrayerMessagesPrefs);
    if (msgJson != null) {
      final decoded = jsonDecode(msgJson) as Map<String, dynamic>;
      decoded.forEach((k, v) {
        _prayerMessagesCache[k] = {
          'ur': (v['ur'] ?? '').toString(),
          'en': (v['en'] ?? '').toString(),
        };
      });
    }

    final namesJson = prefs.getString(kPrayerNamesPrefs);
    if (namesJson != null) {
      final decoded = jsonDecode(namesJson) as Map<String, dynamic>;
      decoded.forEach((k, v) {
        _prayerNamesCache[k] = {
          'ur': (v['ur'] ?? '').toString(),
          'en': (v['en'] ?? '').toString(),
        };
      });
    }

    final menuJson = prefs.getString(kMenuItemsPrefs);
    if (menuJson != null) {
      final decoded = jsonDecode(menuJson) as List;
      _menuItemsCache =
          decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    }
  } catch (_) {}
}
