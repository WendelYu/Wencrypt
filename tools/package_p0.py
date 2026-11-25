#!/usr/bin/env python3
"""Build a P0 test package with the Rust core bundled."""
import os
import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps/wencrypt_flutter"
OUTPUT = ROOT / "build/p0"
NDK = "28.2.13676358"


def run(*args, cwd=ROOT, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def flutter(*args):
    command = shutil.which("flutter")
    if command is None:
        raise SystemExit("Flutter must be on PATH")
    if os.name == "nt":
        run("cmd.exe", "/d", "/c", command, "--no-version-check", *args, cwd=APP)
    else:
        run(command, "--no-version-check", *args, cwd=APP)


def rust_build(target, env=None):
    build_env = dict(os.environ if env is None else env)
    build_env["CARGO_TARGET_DIR"] = str(ROOT / "target")
    run("cargo", "build", "--locked", "--release", "-p", "wencrypt-core",
        "--target", target, env=build_env)
    return ROOT / "target" / target / "release"


def android(*, release=False):
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        raise SystemExit("Set ANDROID_HOME to the Android SDK directory")
    host = {"Darwin": "darwin-x86_64", "Windows": "windows-x86_64",
            "Linux": "linux-x86_64"}[platform.system()]
    bin_dir = Path(sdk) / "ndk" / NDK / "toolchains/llvm/prebuilt" / host / "bin"
    clang = bin_dir / ("clang.exe" if os.name == "nt" else "clang")
    if not clang.is_file() or os.name == "nt":
        raise SystemExit(f"Use Linux or macOS with Android NDK {NDK} to package Android")
    # NDK's API-specific wrapper supplies --target and the Android sysroot.
    linker = bin_dir / "aarch64-linux-android29-clang"
    env = dict(os.environ, CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=str(linker),
               CC_aarch64_linux_android=str(linker),
               AR_aarch64_linux_android=str(bin_dir / "llvm-ar"))
    library = rust_build("aarch64-linux-android", env) / "libwencrypt_core.so"
    jni = APP / "android/rust-jni/arm64-v8a"
    jni.mkdir(parents=True, exist_ok=True)
    shutil.copy2(library, jni)
    mode = "release" if release else "debug"
    flutter("build", "apk", f"--{mode}", "--target-platform", "android-arm64")
    apk = APP / f"build/app/outputs/flutter-apk/app-{mode}.apk"
    import zipfile
    with zipfile.ZipFile(apk) as bundle:
        bundle.getinfo("lib/arm64-v8a/libwencrypt_core.so")
    variant = "unsigned" if release else "debug"
    shutil.copy2(apk, OUTPUT / f"Wencrypt-android-arm64-{variant}.apk")


def windows():
    library = rust_build("x86_64-pc-windows-msvc") / "wencrypt_core.dll"
    flutter("build", "windows", "--release")
    bundle = APP / "build/windows/x64/runner/Release"
    if not (bundle / "Wencrypt.exe").is_file():
        raise SystemExit("Windows build did not produce Wencrypt.exe")
    shutil.copy2(library, bundle)
    shutil.make_archive(str(OUTPUT / "Wencrypt-windows-x64"), "zip", root_dir=bundle)


def macos():
    if platform.machine() != "arm64":
        raise SystemExit("macOS packaging requires an Apple Silicon runner")
    library = rust_build("aarch64-apple-darwin") / "libwencrypt_core.dylib"
    flutter("build", "macos", "--release")
    bundle = APP / "build/macos/Build/Products/Release/Wencrypt.app"
    if not bundle.is_dir():
        raise SystemExit("macOS build did not produce Wencrypt.app")
    package_macos_bundle(bundle, library)


def package_macos_bundle(app, library):
    with tempfile.TemporaryDirectory(prefix="wencrypt-macos-") as tmp:
        bundle = Path(tmp) / app.name
        run("ditto", str(app), str(bundle))
        dylib = bundle / "Contents/Frameworks/libwencrypt_core.dylib"
        shutil.copy2(library, dylib)
        run("codesign", "--force", "--sign", "-", str(dylib))
        run("codesign", "--force", "--sign", "-", "--entitlements",
            str(APP / "macos/Runner/Release.entitlements"), str(bundle))
        run("codesign", "--verify", "--deep", "--strict", str(bundle))
        run("ditto", "-c", "-k", "--keepParent", str(bundle),
            str(OUTPUT / "Wencrypt-macos-arm64.zip"))
        macos_disk_image(bundle)


def macos_disk_image(bundle):
    image = OUTPUT / "Wencrypt-macos-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix="wencrypt-dmg-") as tmp:
        staging = Path(tmp) / "Wencrypt"
        staging.mkdir()
        run("ditto", str(bundle), str(staging / bundle.name))
        (staging / "Applications").symlink_to("/Applications")
        shutil.copy2(ROOT / "docs/macos-first-open.html", staging / "首次打开帮助.html")
        run("hdiutil", "create", "-ov", "-volname", "Wencrypt", "-srcfolder",
            str(staging), "-fs", "HFS+", "-format", "UDZO", str(image))
    run("hdiutil", "verify", str(image))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("android", "windows", "macos"))
    parser.add_argument("--android-release", action="store_true",
                        help="build an unsigned Android APK for the release signing job")
    args = parser.parse_args()
    if args.android_release and args.target != "android":
        parser.error("--android-release requires the Android target")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if args.target == "android":
        android(release=args.android_release)
    else:
        {"windows": windows, "macos": macos}[args.target]()
