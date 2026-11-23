#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# != 3 ]]; then
    echo 'Usage: sign_android_release.sh BUILD_TOOLS INPUT_APK OUTPUT_APK' >&2
    exit 2
fi

build_tools="$1"
input="$2"
output="$3"
: "${ANDROID_SIGNING_KEYSTORE_BASE64:?Configure the Android release keystore secret}"
: "${ANDROID_SIGNING_STORE_PASSWORD:?Configure the Android keystore password secret}"
: "${ANDROID_SIGNING_KEY_ALIAS:?Configure the Android release key alias secret}"
: "${ANDROID_SIGNING_CERT_SHA256:?Configure the Android release certificate fingerprint}"
expected=$(printf '%s' "$ANDROID_SIGNING_CERT_SHA256" | tr '[:upper:]' '[:lower:]')
if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Invalid ANDROID_SIGNING_CERT_SHA256. Use 64 hex digits without separators.' >&2
    exit 1
fi

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wencrypt-sign-android.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
"$build_tools/aapt2" dump badging "$input" > "$work/badging.txt"
if ! grep -q "^package: name='org.wencrypt.wencrypt' " "$work/badging.txt" ||
    grep -q '^application-debuggable' "$work/badging.txt"; then
    echo 'Expected the non-debuggable Wencrypt APK with its published application ID.' >&2
    exit 1
fi

"$build_tools/zipalign" -P 16 -f 4 "$input" "$work/aligned.apk"
printf '%s' "$ANDROID_SIGNING_KEYSTORE_BASE64" | base64 --decode > "$work/keystore.p12"
unset ANDROID_SIGNING_KEYSTORE_BASE64
"$build_tools/apksigner" sign \
    --ks "$work/keystore.p12" --ks-type PKCS12 \
    --ks-pass env:ANDROID_SIGNING_STORE_PASSWORD \
    --ks-key-alias "$ANDROID_SIGNING_KEY_ALIAS" \
    --key-pass env:ANDROID_SIGNING_STORE_PASSWORD \
    --v4-signing-enabled false \
    --out "$work/signed.apk" "$work/aligned.apk"

actual=$("$build_tools/apksigner" verify --print-certs "$work/signed.apk" |
    awk '/^Signer #[0-9]+ certificate SHA-256 digest: / {print tolower($NF)}')
if [[ "$actual" != "$expected" ]]; then
    echo 'Android release certificate does not match the configured fingerprint.' >&2
    exit 1
fi
"$build_tools/zipalign" -c -P 16 4 "$work/signed.apk"
mv -- "$work/signed.apk" "$output"
echo 'Android APK signature and pinned certificate verified.'
