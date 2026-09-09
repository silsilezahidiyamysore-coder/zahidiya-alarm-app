path = "android/app/src/main/AndroidManifest.xml"

with open(path) as f:
    content = f.read()

# App ka display naam "alarm" ki jagah "Zahidiya Alarm" karo (Settings/App-list mein yehi dikhta hai)
content = content.replace('android:label="alarm"', 'android:label="Silsila-e-Zahidiya Alarm"')

permission_lines = [
    "android.permission.INTERNET",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.WAKE_LOCK",
    "android.permission.VIBRATE",
    "android.permission.USE_FULL_SCREEN_INTENT",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.ACCESS_NOTIFICATION_POLICY",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    "android.permission.USE_EXACT_ALARM",
    "android.permission.SCHEDULE_EXACT_ALARM",
]

permissions_block = "\n"
for perm in permission_lines:
    permissions_block += '    <uses-permission android:name="' + perm + '"/>\n'

if "RECEIVE_BOOT_COMPLETED" not in content:
    manifest_start = content.index("<manifest")
    insert_at = content.index(">", manifest_start) + 1
    content = content[:insert_at] + permissions_block + content[insert_at:]

service_tag = '    <service android:name="com.gdelataillade.alarm.services.NotificationOnKillService" />\n'
if "NotificationOnKillService" not in content:
    content = content.replace("</application>", service_tag + "</application>")

# android_alarm_manager_plus ko kaam karne ke liye ye service + 2 receivers zaroori hain,
# warna AndroidAlarmManager.initialize() call fail ho jaata hai aur app splash screen
# par hi atka reh jaata hai (aage badhta hi nahi).
aam_tags = (
    '    <service android:name="dev.fluttercommunity.plus.androidalarmmanager.AlarmService"\n'
    '        android:permission="android.permission.BIND_JOB_SERVICE" android:exported="false"/>\n'
    '    <receiver android:name="dev.fluttercommunity.plus.androidalarmmanager.AlarmBroadcastReceiver" android:exported="false"/>\n'
    '    <receiver android:name="dev.fluttercommunity.plus.androidalarmmanager.RebootBroadcastReceiver" android:enabled="false" android:exported="true">\n'
    '        <intent-filter>\n'
    '            <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
    '        </intent-filter>\n'
    '    </receiver>\n'
)
if "androidalarmmanager.AlarmService" not in content:
    content = content.replace("</application>", aam_tags + "</application>")

with open(path, "w") as f:
    f.write(content)

print("AndroidManifest.xml patched")
