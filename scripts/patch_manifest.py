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
    "android.permission.SYSTEM_ALERT_WINDOW",
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

# MainActivity ko lock-screen ke upar dikhne aur screen ON karne ki ijazat do
# (alarm bajte waqt app poori screen par aaye, chahe phone locked ho).
import re
if "showWhenLocked" not in content:
    content = re.sub(
        r'(<activity\s+android:name="\.MainActivity")',
        r'\1\n            android:showWhenLocked="true"\n            android:turnScreenOn="true"',
        content,
        count=1,
    )

with open(path, "w") as f:
    f.write(content)

print("AndroidManifest.xml patched")
