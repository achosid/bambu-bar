#!/bin/zsh
# Builds Bambu Bar.app (the menu bar app) with Xcode.
#   scripts/build.sh                     release build into build/App.noindex/Bambu Bar.app
#                                        (.noindex keeps build copies out of Spotlight and Launchpad)
#   CONFIG=Debug scripts/build.sh
#   ARCHS=arm64 scripts/build.sh        one architecture (default: universal)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                        signing identity (default: the first Developer ID Application
#                                        identity in the keychain, else ad-hoc)
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-Release}
BUILD="$ROOT/build"
APP="$BUILD/App.noindex/Bambu Bar.app"
DERIVED="$BUILD/DerivedData.noindex"
cd "$ROOT"
mkdir -p "$BUILD"

# Use Xcode without changing the global developer directory.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 2; }

echo "==> App icon"
rm -rf "$BUILD/AppIcon.iconset"
swift "$ROOT/scripts/generate-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "==> Generating Xcode project"
xcodegen generate --quiet --spec "$ROOT/project.yml" --project "$ROOT"

echo "==> xcodebuild ($CONFIG)"
xcodebuild -project BambuBar.xcodeproj -scheme BambuBar -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" ${ARCHS:+ARCHS=$ARCHS} \
  -quiet build 2>&1 | grep -v "^Failed frontend command" | grep -vE "^/Applications/Xcode.*swift-frontend" | grep -v "IDERunDestination" || true
[[ ${pipestatus[1]} -eq 0 ]] || { echo "xcodebuild failed" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "${APP:h}"
ditto "$DERIVED/Build/Products/$CONFIG/Bambu Bar.app" "$APP"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
ENT="$ROOT/Resources/Signing/BambuBar.entitlements"
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ENT" "$APP"
else
  echo "==> Ad-hoc signing (no Developer ID identity found)"
  codesign --force --sign - --entitlements "$ENT" "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "==> Built $APP"
