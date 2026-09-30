#!/usr/bin/env python3
"""为 flutter create 生成的 AndroidManifest 注入权限与中文应用名。"""
import sys

PATH = "android/app/src/main/AndroidManifest.xml"

PERMISSIONS = [
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.SCHEDULE_EXACT_ALARM",
    "android.permission.USE_FULL_SCREEN_INTENT",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.VIBRATE",
]

def main():
    with open(PATH, encoding="utf-8") as f:
        s = f.read()

    injected = False
    for perm in PERMISSIONS:
        if perm not in s:
            s = s.replace(
                "<application",
                '<uses-permission android:name="%s" />\n    <application' % perm,
                1,
            )
            injected = True

    # 应用显示名
    if 'android:label="time_planner"' in s:
        s = s.replace('android:label="time_planner"', 'android:label="时间规划"')
        injected = True

    with open(PATH, "w", encoding="utf-8") as f:
        f.write(s)

    print("AndroidManifest patched" if injected else "AndroidManifest already patched")
    if s.count("<application") == 0 and s.count("<application ") == 0:
        print("WARNING: <application tag not found", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
