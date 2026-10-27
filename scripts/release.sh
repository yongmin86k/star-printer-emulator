#!/usr/bin/env bash
# Build a release: `staremu` CLI + "StarPrinter Emulator.app" in a DMG.
#
#   scripts/release.sh 0.1.0                       # unsigned (ad-hoc) build, for local use
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=staremu scripts/release.sh 0.1.0
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials staremu --apple-id … --team-id … --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
OUT="build/release/$VERSION"
APP_NAME="StarPrinter Emulator"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Tests"
swift test

# Apple Silicon by default; UNIVERSAL=1 adds x86_64 (deprecated by recent SDKs).
ARCH_FLAGS=(--arch arm64)
APP_ARCHS="arm64"
if [[ -n "${UNIVERSAL:-}" ]]; then ARCH_FLAGS+=(--arch x86_64); APP_ARCHS="arm64 x86_64"; fi

echo "==> CLI (${APP_ARCHS})"
swift build -c release "${ARCH_FLAGS[@]}"
cp "$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/staremu" "$OUT/staremu"

echo "==> App"
xcodegen generate --quiet
SIGN_ARGS=(CODE_SIGN_IDENTITY="-")
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project StarEmu.xcodeproj -scheme StarEmu -configuration Release -derivedDataPath .build/xcode \
  MARKETING_VERSION="$VERSION" ARCHS="$APP_ARCHS" ONLY_ACTIVE_ARCH=NO "${SIGN_ARGS[@]}" build -quiet
cp -R ".build/xcode/Build/Products/Release/$APP_NAME.app" "$OUT/"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT/staremu"
fi

echo "==> DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$OUT/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/StarPrinter-Emulator-$VERSION.dmg" -quiet
rm -rf "$STAGE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarize"
  xcrun notarytool submit "$OUT/StarPrinter-Emulator-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/StarPrinter-Emulator-$VERSION.dmg"
else
  echo "(not notarized: set SIGN_IDENTITY and NOTARY_PROFILE for a distributable build)"
fi

ls -lh "$OUT"
