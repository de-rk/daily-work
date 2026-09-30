#!/usr/bin/env python3
"""为 flutter create 生成的 Android 工程注入：
1. AndroidManifest 权限与中文应用名
2. app/build.gradle(.kts) 的 core library desugaring（flutter_local_notifications 必需）
"""
import os
import sys

MANIFEST = "android/app/src/main/AndroidManifest.xml"

PERMISSIONS = [
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.SCHEDULE_EXACT_ALARM",
    "android.permission.USE_FULL_SCREEN_INTENT",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.VIBRATE",
]

DESUGAR_LIB = "com.android.tools:desugar_jdk_libs:2.1.4"


def patch_manifest():
    with open(MANIFEST, encoding="utf-8") as f:
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

    if 'android:label="time_planner"' in s:
        s = s.replace('android:label="time_planner"', 'android:label="时间规划"')
        injected = True

    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(s)

    print("AndroidManifest patched" if injected else "AndroidManifest already patched")
    if s.count("<application") == 0:
        print("WARNING: <application tag not found", file=sys.stderr)
        sys.exit(1)


def patch_gradle_kts(path):
    """build.gradle.kts（Flutter 3.29+ 新模板）"""
    with open(path, encoding="utf-8") as f:
        s = f.read()

    original = s

    # 1. compileOptions 中启用 desugaring
    if "isCoreLibraryDesugaringEnabled" not in s:
        if "compileOptions {" in s:
            s = s.replace(
                "compileOptions {",
                "compileOptions {\n        isCoreLibraryDesugaringEnabled = true",
                1,
            )
        else:
            # 模板缺 compileOptions 时，插入到 android { 内
            s = s.replace(
                "android {",
                "android {\n    compileOptions {\n"
                "        isCoreLibraryDesugaringEnabled = true\n"
                "        sourceCompatibility = JavaVersion.VERSION_11\n"
                "        targetCompatibility = JavaVersion.VERSION_11\n    }",
                1,
            )

    # 2. 依赖
    if "coreLibraryDesugaring" not in s:
        s += (
            "\ndependencies {\n"
            '    coreLibraryDesugaring("%s")\n'
            "}\n" % DESUGAR_LIB
        )

    if s != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print("%s patched (desugaring enabled)" % path)
    else:
        print("%s already patched" % path)


def patch_gradle_groovy(path):
    """build.gradle（旧模板）"""
    with open(path, encoding="utf-8") as f:
        s = f.read()

    original = s

    if "coreLibraryDesugaringEnabled" not in s:
        if "compileOptions {" in s:
            s = s.replace(
                "compileOptions {",
                "compileOptions {\n        coreLibraryDesugaringEnabled true",
                1,
            )
        else:
            s = s.replace(
                "android {",
                "android {\n    compileOptions {\n"
                "        coreLibraryDesugaringEnabled true\n"
                "        sourceCompatibility JavaVersion.VERSION_11\n"
                "        targetCompatibility JavaVersion.VERSION_11\n    }",
                1,
            )

    if "coreLibraryDesugaring" not in s.replace("coreLibraryDesugaringEnabled", ""):
        s += (
            "\ndependencies {\n"
            "    coreLibraryDesugaring '%s'\n"
            "}\n" % DESUGAR_LIB
        )

    if s != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print("%s patched (desugaring enabled)" % path)
    else:
        print("%s already patched" % path)


def main():
    patch_manifest()

    kts = "android/app/build.gradle.kts"
    groovy = "android/app/build.gradle"
    if os.path.exists(kts):
        patch_gradle_kts(kts)
    elif os.path.exists(groovy):
        patch_gradle_groovy(groovy)
    else:
        print("WARNING: app build.gradle not found", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
