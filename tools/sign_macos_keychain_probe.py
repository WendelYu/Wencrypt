#!/usr/bin/env python3
"""Sign a local copy of the Wencrypt CI macOS app for the Keychain probe."""
import argparse
import datetime
import hashlib
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

BUNDLE_ID = "org.wencrypt.wencrypt"
APP_ID_KEY = "com.apple.application-identifier"
TEAM_KEY = "com.apple.developer.team-identifier"


def read_plist(*command):
    result = subprocess.run(command, check=True, stdout=subprocess.PIPE)
    return plistlib.loads(result.stdout)


def signed_entitlements(app):
    return read_plist("codesign", "-d", "--entitlements", ":-", str(app))


def profile_settings(profile, identity):
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("Choose a macOS development provisioning profile")
    if not profile.get("ProvisionedDevices"):
        raise ValueError("Choose a development profile with registered devices")
    if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise ValueError("Provisioning profile expired")
    permitted = profile.get("Entitlements", {})
    if permitted.get("get-task-allow") is not True and permitted.get("com.apple.security.get-task-allow") is not True:
        raise ValueError("Choose a development provisioning profile")
    certs = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
    if identity not in certs:
        raise ValueError("The certificate selected on this Mac is not included in the profile")
    teams = profile.get("TeamIdentifier", [])
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if len(teams) != 1 or len(prefixes) != 1 or permitted.get(TEAM_KEY) != teams[0]:
        raise ValueError("Could not identify the team's application identifier prefix")
    app_id = f"{prefixes[0]}.{BUNDLE_ID}"
    permitted_app_id = permitted.get(APP_ID_KEY, "")
    wildcard_match = permitted_app_id == f"{prefixes[0]}.*"
    if permitted_app_id != app_id and not wildcard_match:
        raise ValueError(f"Profile does not authorize {BUNDLE_ID}")
    # The app's own application identifier grants its default Keychain group.
    return {APP_ID_KEY: app_id, TEAM_KEY: teams[0]}


def sign_app(app, profile_path, identity, output):
    if app == output or output.exists() or output.suffix != ".app":
        raise ValueError("Choose a new .app output path")
    with (app / "Contents/Info.plist").open("rb") as info:
        if plistlib.load(info).get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError(f"Expected a {BUNDLE_ID} app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    profile = read_plist("security", "cms", "-D", "-i", str(profile_path))
    entitlements = signed_entitlements(app)
    if entitlements != {"com.apple.security.app-sandbox": True}:
        raise ValueError("Expected the release CI probe with only its original sandbox entitlement")
    entitlements.update(profile_settings(profile, identity))

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wencrypt-sign-", dir=output.parent) as temp:
        staging = Path(temp)
        signed = staging / output.name
        subprocess.run(["ditto", str(app), str(signed)], check=True)
        shutil.copy2(profile_path, signed / "Contents/embedded.provisionprofile")
        plist = staging / "entitlements.plist"
        plist.write_bytes(plistlib.dumps(entitlements))
        frameworks = signed / "Contents/Frameworks"
        code = [
            entry for entry in frameworks.iterdir()
            if entry.suffix in {".framework", ".dylib"} and not entry.is_symlink()
        ]
        for entry in sorted(code):
            subprocess.run(["codesign", "--force", "--sign", identity, str(entry)], check=True)
        subprocess.run(
            ["codesign", "--force", "--sign", identity, "--entitlements", str(plist), str(signed)],
            check=True,
        )
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(signed)], check=True)
        if signed_entitlements(signed) != entitlements:
            raise ValueError("Signed application entitlements do not match the verified profile")
        signed.rename(output)
    print(f"Signed and verified {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--identity", required=True, help="SHA-1 from security find-identity -v -p codesigning")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    identity = args.identity.upper()
    if not re.fullmatch(r"[0-9A-F]{40}", identity):
        parser.error("identity must be a 40-character certificate fingerprint")
    try:
        sign_app(args.app.resolve(), args.profile.resolve(), identity, args.output.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Signing stopped: {error}\n")


if __name__ == "__main__":
    main()
