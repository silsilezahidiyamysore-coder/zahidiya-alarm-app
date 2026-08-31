import os
import re
import shutil

ROOT = "android"
APP_GRADLE_GROOVY = os.path.join(ROOT, "app", "build.gradle")
APP_GRADLE_KTS = os.path.join(ROOT, "app", "build.gradle.kts")
PROJ_GRADLE_GROOVY = os.path.join(ROOT, "build.gradle")
PROJ_GRADLE_KTS = os.path.join(ROOT, "build.gradle.kts")

# 1. Copy google-services.json into android/app/
if os.path.exists("google-services.json"):
    shutil.copy("google-services.json", os.path.join(ROOT, "app", "google-services.json"))
    print("Copied google-services.json")
else:
    print("WARNING: google-services.json not found at repo root")

# 2. Add classpath to project-level build.gradle(.kts)
if os.path.exists(PROJ_GRADLE_KTS):
    path = PROJ_GRADLE_KTS
    with open(path) as f:
        content = f.read()
    if "google-services" not in content:
        content = content.replace(
            "dependencies {",
            'dependencies {\n        classpath("com.google.gms:google-services:4.4.2")',
            1
        )
        with open(path, "w") as f:
            f.write(content)
        print("Patched project build.gradle.kts")
elif os.path.exists(PROJ_GRADLE_GROOVY):
    path = PROJ_GRADLE_GROOVY
    with open(path) as f:
        content = f.read()
    if "google-services" not in content:
        content = content.replace(
            "dependencies {",
            "dependencies {\n        classpath 'com.google.gms:google-services:4.4.2'",
            1
        )
        with open(path, "w") as f:
            f.write(content)
        print("Patched project build.gradle")

# 3. Apply plugin in app-level build.gradle(.kts)
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
