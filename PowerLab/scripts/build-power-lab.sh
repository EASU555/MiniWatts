#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="PowerLab.xcodeproj"
SCHEME="PowerLab"
BUILD_DIR="build/PowerLab"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/export"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-$(git rev-list --count HEAD)}"

rm -rf "$DERIVED" "$EXPORT_DIR" "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

echo "==> PowerLab $MARKETING_VERSION ($CURRENT_PROJECT_VERSION)"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  "OTHER_SWIFT_FLAGS=-file-prefix-map $PWD=/PowerLab" \
  "OTHER_CFLAGS=-ffile-prefix-map=$PWD=/PowerLab"

APP="$DERIVED/Build/Products/Release-iphoneos/PowerLab.app"
test -d "$APP"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
rm -rf "$BUILD_DIR/Payload/PowerLab.app/_CodeSignature"

while IFS= read -r -d '' plist; do
  bundle="$(dirname "$plist")"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
  test -z "$executable" || test ! -f "$bundle/$executable" || xcrun strip -S -x "$bundle/$executable"
done < <(find "$BUILD_DIR/Payload/PowerLab.app" -name Info.plist -print0)

(cd "$BUILD_DIR" && zip -qry "export/PowerLab-unsigned.ipa" Payload)
rm -rf "$BUILD_DIR/Payload"

IPA="$EXPORT_DIR/PowerLab-unsigned.ipa"
scripts/verify-clean.sh "$IPA"
ls -lh "$IPA"
