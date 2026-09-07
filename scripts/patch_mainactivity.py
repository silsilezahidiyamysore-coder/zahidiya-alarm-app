import os

path = "android/app/src/main/kotlin/com/zahidiya/alarm/MainActivity.kt"

if not os.path.exists(path):
    print("MainActivity.kt not found at expected path, skipping patch:", path)
else:
    new_content = """package com.zahidiya.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Power button dabakar screen OFF/lock hone par Dart side ko signal
// bhejta hai, taaki baj raha alarm turant band ho sake.
class MainActivity : FlutterActivity() {
    private val CHANNEL = "zahidiya.alarm/screen"
    private var methodChannel: MethodChannel? = null
    private var screenOffReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        screenOffReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                methodChannel?.invokeMethod("screenOff", null)
            }
        }
        registerReceiver(screenOffReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }

    override fun onDestroy() {
        screenOffReceiver?.let {
            try { unregisterReceiver(it) } catch (e: Exception) {}
        }
        super.onDestroy()
    }
}
"""
    with open(path, "w") as f:
        f.write(new_content)
    print("MainActivity.kt patched with screen-off receiver")
