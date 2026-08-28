import re
import glob

targets = glob.glob("android/app/build.gradle") + glob.glob("android/app/build.gradle.kts")

for path in targets:
    with open(path) as f:
        content = f.read()

    is_kts = path.endswith(".kts")

    if is_kts:
        content = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 23", content)
        content = re.sub(r"minSdkVersion\s*=\s*flutter\.minSdkVersion", "minSdkVersion = 23", content)
        if "multiDexEnabled" not in content:
            content = content.replace(
                "defaultConfig {",
                "defaultConfig {\n        multiDexEnabled = true",
                1,
            )
    else:
        content = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 23", content)
        if "multiDexEnabled" not in content:
            content = content.replace(
                "defaultConfig {",
                "defaultConfig {\n        multiDexEnabled true",
                1,
            )

    with open(path, "w") as f:
        f.write(content)
    print("Patched " + path)
