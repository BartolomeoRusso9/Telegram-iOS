#!/bin/bash
# Builds output/Telegram-Cast-sideload.ipa, for a tool that re-signs it with the user's own
# Apple ID (Sideloadly, AltStore). The IPA cannot be installed as it is.
#
#   build-sideload-ipa.sh <config.json> <build-number>
#
# rules_apple refuses a device app without an unexpired profile, and the repository's fake
# profiles have expired. This makes placeholder copies with a new date, signed by a throwaway
# key. They satisfy the build and grant nothing: Apple does not trust them, and the app is
# signed ad hoc until the re-signing tool replaces both.
set -euo pipefail

CONFIGURATION="$1"
BUILD_NUMBER="$2"
WORK="$HOME/.telegram-cast/sideload-signing"

python3 scripts/cast/check-integration.py

umask 077
mkdir -p "$WORK/certs" "$WORK/profiles" output
cp build-system/fake-codesigning/certs/* "$WORK/certs/"
KEY_DIR="$(mktemp -d)"
trap 'rm -f "$KEY_DIR/key.pem" "$KEY_DIR/cert.pem"; rmdir "$KEY_DIR"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Telegram Cast sideload placeholder" \
    -keyout "$KEY_DIR/key.pem" -out "$KEY_DIR/cert.pem" 2> /dev/null

for PROFILE in build-system/fake-codesigning/profiles/*.mobileprovision; do
    security cms -D -i "$PROFILE" 2> /dev/null > "$KEY_DIR/profile.plist"
    python3 -I - "$KEY_DIR/profile.plist" <<'PY'
import datetime, plistlib, sys
path = sys.argv[1]
with open(path, "rb") as file:
    profile = plistlib.load(file)
profile["ExpirationDate"] = datetime.datetime.now() + datetime.timedelta(days=3650)
with open(path, "wb") as file:
    plistlib.dump(profile, file)
PY
    openssl smime -sign -nodetach -binary -outform der -signer "$KEY_DIR/cert.pem" -inkey "$KEY_DIR/key.pem" \
        -in "$KEY_DIR/profile.plist" -out "$WORK/profiles/$(basename "$PROFILE")"
    rm -f "$KEY_DIR/profile.plist"
done

ARTIFACTS="$(mktemp -d)"
python3 build-system/Make/Make.py \
    --cacheDir="${TELEGRAM_BAZEL_CACHE:-$HOME/telegram-bazel-cache}" \
    build \
    --adHocSigning \
    --configurationPath="$CONFIGURATION" \
    --codesigningInformationPath="$WORK" \
    --buildNumber="$BUILD_NUMBER" \
    --configuration=release_arm64 \
    --outputBuildArtifactsPath="$ARTIFACTS"

test -s "$ARTIFACTS/Telegram.ipa"
cp "$ARTIFACTS/Telegram.ipa" output/Telegram-Cast-sideload.ipa
ls -la output/Telegram-Cast-sideload.ipa
