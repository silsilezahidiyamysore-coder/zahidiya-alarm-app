import os

dir_path = "android/app/src/main/kotlin/com/zahidiya/alarm"
path = dir_path + "/MainActivity.kt"

MAIN_KT = r"""package com.zahidiya.alarm

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

    // App aage aate hi alarm ka overlay hata do (ab app khud poori screen par hai)
    override fun onResume() {
        super.onResume()
        AlarmOverlay.hide()
    }

    override fun onDestroy() {
        screenOffReceiver?.let {
            try { unregisterReceiver(it) } catch (e: Exception) {}
        }
        super.onDestroy()
    }
}
"""

OVERLAY_KT = r"""package com.zahidiya.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

// Alarm bajte hi YouTube/Facebook jaisi kisi bhi app ke UPAR poori screen ka
// alarm dikhata hai ("Display over other apps" ki ijazat se). Isse Android
// ki "background se app kholne ki rok" bhi hat jaati hai, aur alarm app
// poori screen par aa jaati hai.
object AlarmOverlay {
    private var overlayView: View? = null
    private var appContext: Context? = null
    private val handler = Handler(Looper.getMainLooper())
    private var hideRunnable: Runnable? = null

    fun openApp(context: Context) {
        try {
            val i = Intent()
            i.setClassName(context.packageName, "com.zahidiya.alarm.MainActivity")
            i.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            context.startActivity(i)
        } catch (e: Exception) {
        }
    }

    fun show(context: Context, title: String, seconds: Int) {
        try {
            if (!Settings.canDrawOverlays(context)) return
            hide()
            appContext = context
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

            val root = LinearLayout(context)
            root.orientation = LinearLayout.VERTICAL
            root.gravity = Gravity.CENTER
            root.setBackgroundColor(Color.parseColor("#4CAF50"))
            root.setPadding(48, 48, 48, 48)

            val icon = TextView(context)
            icon.text = "\u23F0"
            icon.textSize = 72f
            icon.gravity = Gravity.CENTER
            root.addView(icon)

            val titleView = TextView(context)
            titleView.text = title
            titleView.setTextColor(Color.WHITE)
            titleView.textSize = 26f
            titleView.typeface = Typeface.DEFAULT_BOLD
            titleView.gravity = Gravity.CENTER
            root.addView(titleView)

            val btn = Button(context)
            btn.text = "OPEN  /  \u06A9\u06BE\u0648\u0644\u06CC\u06BA"
            btn.textSize = 20f
            btn.setOnClickListener {
                hide()
                openApp(context)
            }
            val btnParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            btnParams.topMargin = 96
            root.addView(btn, btnParams)

            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                PixelFormat.TRANSLUCENT
            )
            wm.addView(root, params)
            overlayView = root

            // Alarm ka time khatam hone par (ya app khul jaane par) khud hat jaayega
            val secs = if (seconds < 10) 10 else if (seconds > 300) 300 else seconds
            val r = Runnable { hide() }
            hideRunnable = r
            handler.postDelayed(r, secs * 1000L)
        } catch (e: Exception) {
        }
    }

    fun hide() {
        try {
            hideRunnable?.let { handler.removeCallbacks(it) }
            hideRunnable = null
            val v = overlayView ?: return
            val ctx = appContext ?: return
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeView(v)
        } catch (e: Exception) {
        } finally {
            overlayView = null
        }
    }
}

class AlarmOverlayReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: "Alarm"
        val seconds = intent.getIntExtra("seconds", 60)
        val app = context.applicationContext
        AlarmOverlay.show(app, title, seconds)
        // Overlay dikhne ke thodi der baad app bhi aage laao (Android 15 ke liye
        // "visible overlay window" zaroori hai)
        val pending = goAsync()
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                AlarmOverlay.openApp(app)
            } finally {
                pending.finish()
            }
        }, 400)
    }
}
"""

if not os.path.exists(path):
    print("MainActivity.kt not found at expected path, skipping patch:", path)
else:
    with open(path, "w", encoding="utf-8") as f:
        f.write(MAIN_KT)
    with open(dir_path + "/AlarmOverlay.kt", "w", encoding="utf-8") as f:
        f.write(OVERLAY_KT)
    print("MainActivity.kt + AlarmOverlay.kt patched")
