path = "android/app/src/main/AndroidManifest.xml"

with open(path) as f:
    content = f.read()

permission_lines = [
    "android.permission.INTERNET",    "android.permission.RECEIVE_BOOT_COMPLETED",
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

with open(path, "w") as f:
    f.write(content)

print("AndroidManifest.xml patched")
