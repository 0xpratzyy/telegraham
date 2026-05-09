#!/usr/bin/env bash
# scripts/make_dmg.sh
#
# Builds a Release .app and packages it into a .dmg for beta distribution.
# Output lands in `dist/Pidgy-<short-sha>.dmg` (or, if the working tree is
# dirty, `dist/Pidgy-<short-sha>-dirty.dmg`).
#
# Prerequisites:
#   - Credentials filled into Config/BetaSecrets.local.xcconfig
#   - xcodegen on PATH (brew install xcodegen)
#   - Xcode command line tools
#
# Usage:
#   scripts/make_dmg.sh                # ad-hoc signed (testers see Gatekeeper warning)
#   scripts/make_dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"
#                                      # signed for distribution
#   scripts/make_dmg.sh --notarize     # also notarize via notarytool;
#                                      # requires `xcrun notarytool store-credentials pidgy-beta` first

set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="-"
NOTARIZE=0
NOTARY_PROFILE="pidgy-beta"

while [ $# -gt 0 ]; do
  case "$1" in
    --sign)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

if [ ! -f Config/BetaSecrets.local.xcconfig ]; then
  cat <<'EOF' >&2
warning: Config/BetaSecrets.local.xcconfig is missing — the build will run
         but the .app won't have bundled credentials, so testers will land
         on the AuthView credential entry screen instead of skipping it.
         Copy BetaSecrets.local.xcconfig.template if you want zero-config.
EOF
fi

SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  SHORT_SHA="${SHORT_SHA}-dirty"
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release"
DERIVED="$(mktemp -d -t pidgy-release-XXXXXXXX)"
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild \
  -project Pidgy.xcodeproj \
  -scheme Pidgy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build \
  | xcbeautify --quiet 2>/dev/null \
  || xcodebuild \
       -project Pidgy.xcodeproj \
       -scheme Pidgy \
       -configuration Release \
       -destination 'generic/platform=macOS' \
       -derivedDataPath "$DERIVED" \
       CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
       CODE_SIGN_STYLE=Manual \
       CODE_SIGNING_REQUIRED=YES \
       CODE_SIGNING_ALLOWED=YES \
       build

APP_PATH="$DERIVED/Build/Products/Release/Pidgy.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: build produced no app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | head -10 || true

echo "==> Staging .dmg layout"
DMG_STAGING="$(mktemp -d -t pidgy-dmg-XXXXXXXX)"
trap 'rm -rf "$DERIVED" "$DMG_STAGING"' EXIT

cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

mkdir -p dist
DMG_OUT="dist/Pidgy-${SHORT_SHA}.dmg"
rm -f "$DMG_OUT"

echo "==> Creating $DMG_OUT"
hdiutil create \
  -volname "Pidgy" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  -imagekey zlib-level=9 \
  "$DMG_OUT" >/dev/null

echo "==> Signing the .dmg"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_OUT" 2>/dev/null || true

if [ "$NOTARIZE" -eq 1 ]; then
  echo "==> Submitting $DMG_OUT to notarytool (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG_OUT" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_OUT"
  xcrun stapler validate "$DMG_OUT"
fi

echo
echo "Done. Output:"
ls -lh "$DMG_OUT"
echo
echo "Test locally:"
echo "  open $DMG_OUT"
