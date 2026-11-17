#!/usr/bin/env python3
"""Build a P0 test package with the Rust core bundled."""
import os
import platform
import shutil
import subprocess
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


def android():
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
    flutter("build", "apk", "--debug", "--target-platform", "android-arm64")
    apk = APP / "build/app/outputs/flutter-apk/app-debug.apk"
    import zipfile
    with zipfile.ZipFile(apk) as bundle:
        bundle.getinfo("lib/arm64-v8a/libwencrypt_core.so")
    shutil.copy2(apk, OUTPUT / "wencrypt-android-arm64-debug.apk")


def windows():
    library = rust_build("x86_64-pc-windows-msvc") / "wencrypt_core.dll"
    flutter("build", "windows", "--release")
    bundle = APP / "build/windows/x64/runner/Release"
    if not (bundle / "wencrypt.exe").is_file():
        raise SystemExit("Windows build did not produce wencrypt.exe")
    shutil.copy2(library, bundle)
    shutil.make_archive(str(OUTPUT / "wencrypt-windows-x64"), "zip", root_dir=bundle)


def macos():
    if platform.machine() != "arm64":
        raise SystemExit("macOS packaging requires an Apple Silicon runner")
    library = rust_build("aarch64-apple-darwin") / "libwencrypt_core.dylib"
    flutter("build", "macos", "--release")
    apps = list((APP / "build/macos/Build/Products/Release").glob("*.app"))
    if len(apps) != 1:
        raise SystemExit("Expected one macOS app")
    bundle = apps[0]
    dylib = bundle / "Contents/Frameworks/libwencrypt_core.dylib"
    shutil.copy2(library, dylib)
    run("codesign", "--force", "--sign", "-", str(dylib))
    run("codesign", "--force", "--sign", "-", "--entitlements",
        str(APP / "macos/Runner/Release.entitlements"), str(bundle))
    run("codesign", "--verify", "--deep", "--strict", str(bundle))
    run("ditto", "-c", "-k", "--keepParent", str(bundle),
        str(OUTPUT / "wencrypt-macos-arm64.zip"))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("android", "windows", "macos"))
    target = parser.parse_args().target
    OUTPUT.mkdir(parents=True, exist_ok=True)
    {"android": android, "windows": windows, "macos": macos}[target]()
