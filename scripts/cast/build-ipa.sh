#!/bin/bash
# Builds a device IPA and wraps it in an .xcarchive under output/.
#
#   build-ipa.sh --configuration <config.json> --signing <dir> --build-number <n>
#
# <dir> holds certs/ and profiles/ as described in docs/google-cast/README.md. There is no
# unsigned mode: rules_apple refuses a device app without a valid provisioning profile.
set -euo pipefail

CONFIGURATION=""
SIGNING=""
BUILD_NUMBER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --signing) SIGNING="$2"; shift 2 ;;
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$CONFIGURATION" ] || [ -z "$SIGNING" ] || [ -z "$BUILD_NUMBER" ]; then
    echo "--configuration, --signing and --build-number are required" >&2
    exit 2
fi
NAME="Telegram-Cast"

python3 scripts/cast/check-integration.py

mkdir -p output
ARTIFACTS="$(mktemp -d)"
python3 build-system/Make/Make.py \
    --cacheDir="${TELEGRAM_BAZEL_CACHE:-$HOME/telegram-bazel-cache}" \
    build \
    --configurationPath="$CONFIGURATION" \
    --codesigningInformationPath="$SIGNING" \
    --buildNumber="$BUILD_NUMBER" \
    --configuration=release_arm64 \
    --outputBuildArtifactsPath="$ARTIFACTS"

test -s "$ARTIFACTS/Telegram.ipa"
cp "$ARTIFACTS/Telegram.ipa" "output/$NAME.ipa"

# Bazel signs and packages the IPA itself, so xcodebuild -exportArchive has nothing to export.
# The archive is assembled from that IPA and holds exactly the same app.
ARCHIVE="output/$NAME.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE/Products/Applications"
unzip -q "output/$NAME.ipa" -d "$ARTIFACTS/unpacked"
cp -R "$ARTIFACTS/unpacked/Payload/Telegram.app" "$ARCHIVE/Products/Applications/"
if [ -d "$ARTIFACTS/DSYMs" ]; then
    cp -R "$ARTIFACTS/DSYMs" "$ARCHIVE/dSYMs"
fi
APP_PLIST="$ARCHIVE/Products/Applications/Telegram.app/Info.plist"
/usr/bin/plutil -create xml1 "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ArchiveVersion -integer 2 "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert Name -string "Telegram-Cast" "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert SchemeName -string "Telegram" "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ApplicationProperties -dictionary "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ApplicationProperties.ApplicationPath -string "Applications/Telegram.app" "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ApplicationProperties.CFBundleIdentifier -string "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_PLIST")" "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ApplicationProperties.CFBundleShortVersionString -string "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_PLIST")" "$ARCHIVE/Info.plist"
/usr/bin/plutil -insert ApplicationProperties.CFBundleVersion -string "$(/usr/bin/plutil -extract CFBundleVersion raw "$APP_PLIST")" "$ARCHIVE/Info.plist"

# The result must be the app that was asked for, with Cast really in it.
APP="$ARCHIVE/Products/Applications/Telegram.app"
for key in NSLocalNetworkUsageDescription NSBonjourServices TelegramCastReceiverApplicationID; do
    /usr/bin/plutil -extract "$key" raw -o - "$APP/Info.plist" > /dev/null || /usr/bin/plutil -extract "$key" json -o - "$APP/Info.plist" > /dev/null
done
test -d "$APP/GoogleCastUIResources.bundle"
grep -q GCKCastContext "$APP/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"

/usr/bin/codesign --verify --deep --strict "$APP"
ls -la "output/$NAME.ipa"
echo "Built output/$NAME.ipa and $ARCHIVE"
