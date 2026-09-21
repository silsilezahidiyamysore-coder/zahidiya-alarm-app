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
        AlarmOverlay.appInForeground = true
        AlarmOverlay.hide()
    }

    override fun onPause() {
        AlarmOverlay.appInForeground = false
        super.onPause()
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

import android.app.AlarmManager
import android.app.PendingIntent
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
// alarm dikhata hai ("Display over other apps" ki ijazat se), aur alarm app ko
// bhi aage le aata hai. Ye alarm ki asli ringing se bilkul alag hai — isme kuch
// bhi gadbad ho to alarm ki awaaz par koi asar nahi padta.
object AlarmOverlay {
    @Volatile
    var appInForeground: Boolean = false

    private var overlayView: View? = null
    private var appContext: Context? = null
    private val handler = Handler(Looper.getMainLooper())
    private var hideRunnable: Runnable? = null

    fun openApp(context: Context) {
        try {
            if (appInForeground) return
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
            if (appInForeground) return // app pehle se saamne hai
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

// Overlay abhi dikhane ka hukm (server ke push wale backup alarm ke liye)
class AlarmOverlayReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
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
        } catch (e: Exception) {
        }
    }
}

// Phone ke alarm ke SAATH-SAATH usi exact time par overlay dikhane ka apna
// AlarmManager alarm lagata / hataata hai (Dart se broadcast aata hai).
class OverlayScheduleReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_SCHEDULE = "com.zahidiya.alarm.SCHEDULE_OVERLAY"
        const val ACTION_CANCEL = "com.zahidiya.alarm.CANCEL_OVERLAY"

        fun pendingFor(context: Context, id: Int, title: String, seconds: Int): PendingIntent {
            val i = Intent(context, AlarmOverlayReceiver::class.java)
            i.action = "com.zahidiya.alarm.SHOW_OVERLAY"
            i.putExtra("title", title)
            i.putExtra("seconds", seconds)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return PendingIntent.getBroadcast(context, id, i, flags)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val id = intent.getIntExtra("id", 0)
            val title = intent.getStringExtra("title") ?: "Alarm"
            val seconds = intent.getIntExtra("seconds", 60)
            val pi = pendingFor(context, id, title, seconds)
            if (intent.action == ACTION_CANCEL) {
                am.cancel(pi)
                return
            }
            val at = (intent.getStringExtra("at") ?: "0").toLong()
            if (at <= System.currentTimeMillis()) return
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } catch (e: SecurityException) {
                am.set(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (e: Exception) {
        }
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
