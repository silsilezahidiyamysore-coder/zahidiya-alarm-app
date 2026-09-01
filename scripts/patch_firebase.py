import os
import re
import shutil

ROOT = "android"
APP_GRADLE_KTS = os.path.join(ROOT, "app", "build.gradle.kts")
APP_GRADLE_GROOVY = os.path.join(ROOT, "app", "build.gradle")
SETTINGS_GRADLE_KTS = os.path.join(ROOT, "settings.gradle.kts")
SETTINGS_GRADLE_GROOVY = os.path.join(ROOT, "settings.gradle")

GOOGLE_SERVICES_VERSION = "4.4.2"

# 1. Copy google-services.json into android/app/
if os.path.exists("google-services.json"):
    shutil.copy("google-services.json", os.path.join(ROOT, "app", "google-services.json"))
    print("Copied google-services.json")
else:
    print("WARNING: google-services.json not found at repo root")

# 2. Declare the google-services plugin version in settings.gradle(.kts) plugins block
if os.path.exists(SETTINGS_GRADLE_KTS):
    path = SETTINGS_GRADLE_KTS
    with open(path) as f:
        content = f.read()
    if "com.google.gms.google-services" not in content:
        content = re.sub(
            r'(id\("dev\.flutter\.flutter-plugin-loader"\)[^\n]*\n)',
            r'\1    id("com.google.gms.google-services") version "%s" apply false\n' % GOOGLE_SERVICES_VERSION,
            content,
            count=1
        )
        if "com.google.gms.google-services" not in content:
            content = re.sub(
                r'(plugins\s*\{)',
                r'\1\n    id("com.google.gms.google-services") version "%s" apply false' % GOOGLE_SERVICES_VERSION,
                content,
                count=1
            )
        with open(path, "w") as f:
            f.write(content)
        print("Patched settings.gradle.kts")
elif os.path.exists(SETTINGS_GRADLE_GROOVY):
    path = SETTINGS_GRADLE_GROOVY
    with open(path) as f:
        content = f.read()
    if "com.google.gms.google-services" not in content:
        content = re.sub(
            r'(plugins\s*\{)',
            r"\1\n    id 'com.google.gms.google-services' version '%s' apply false" % GOOGLE_SERVICES_VERSION,
            content,
            count=1
        )
        with open(path, "w") as f:
            f.write(content)
        print("Patched settings.gradle")

# 3. Apply plugin (no version needed here) in app-level build.gradle(.kts)
if os.path.exists(APP_GRADLE_KTS):
    path = APP_GRADLE_KTS
    with open(path) as f:
        content = f.read()
    if "com.google.gms.google-services" not in content:
        content = re.sub(
            r'(plugins\s*\{)',
            r'\1\n    id("com.google.gms.google-services")',
            content,
            count=1
        )
        with open(path, "w") as f:
            f.write(content)
        print("Patched app build.gradle.kts")
elif os.path.exists(APP_GRADLE_GROOVY):
    path = APP_GRADLE_GROOVY
    with open(path) as f:
        content = f.read()
    if "com.google.gms.google-services" not in content:
        content += "\napply plugin: 'com.google.gms.google-services'\n"
        with open(path, "w") as f:
            f.write(content)
        print("Patched app build.gradle")
