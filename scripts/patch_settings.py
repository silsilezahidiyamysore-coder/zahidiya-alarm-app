import re
import glob


def bump_version(match):
    prefix = match.group(1)
    version = match.group(2)
    suffix = match.group(3)
    parts = tuple(int(p) for p in version.split("."))
    if parts < (1, 9, 0):
        return prefix + "1.9.22" + suffix
    return match.group(0)


pattern = re.compile(
    r'(id\s*[\("]org\.jetbrains\.kotlin\.android[\)"]\s*version\s*["\'])([0-9.]+)(["\'])'
)

targets = glob.glob("android/settings.gradle") + glob.glob("android/settings.gradle.kts")

for path in targets:
    with open(path) as f:
        content = f.read()
    content = pattern.sub(bump_version, content)
    with open(path, "w") as f:
        f.write(content)
    print("Checked " + path)
