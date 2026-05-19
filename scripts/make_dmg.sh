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
#   - For signed distribution: a "Developer ID Application" certificate
#     installed in the macOS Keychain matching DEVELOPMENT_TEAM in
#     project.yml (ZCJL3LC558). project.yml's Release config picks
#     it up automatically.
#   - For notarization: `xcrun notarytool store-credentials pidgy-beta`
#     done once locally so this script can submit without arguments.
#
# Usage:
#   scripts/make_dmg.sh                 # signed (Developer ID, per project.yml) — no notarization
#   scripts/make_dmg.sh --notarize      # signed + notarized + stapled (the path for tester distribution)
#   scripts/make_dmg.sh --ad-hoc        # ad-hoc signed (Gatekeeper-rejected) for local sanity-check builds
#   scripts/make_dmg.sh --sign "Developer ID Application: Different Identity (OTHERTEAMID)"
#                                       # override the certificate (rare — normally project.yml is enough)
#   scripts/make_dmg.sh --notary-profile other-profile-name
#                                       # use a different keychain notarytool profile than `pidgy-beta`

set -euo pipefail

cd "$(dirname "$0")/.."

# Empty = let project.yml's Release config (Developer ID Application)
# do its thing. Override only when --sign or --ad-hoc is passed.
SIGN_IDENTITY=""
NOTARIZE=0
NOTARY_PROFILE="pidgy-beta"

while [ $# -gt 0 ]; do
  case "$1" in
    --sign)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --ad-hoc)
      SIGN_IDENTITY="-"
      shift
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

# Refuse to notarize a dirty / ad-hoc build — both produce DMGs that
# Apple's notarytool can't ratify, and the resulting feedback loop
# ("notarytool rejected the package") is annoying. Bail early.
if [ "$NOTARIZE" -eq 1 ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "error: --notarize requires a real Developer ID signature; --ad-hoc is incompatible." >&2
    exit 2
  fi
  if [[ "$SHORT_SHA" == *-dirty ]]; then
    echo "error: --notarize refuses to ship a dirty tree. Commit your changes (or stash) first." >&2
    exit 2
  fi
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release"
DERIVED="$(mktemp -d -t pidgy-release-XXXXXXXX)"
trap 'rm -rf "$DERIVED"' EXIT

# When SIGN_IDENTITY is empty, omit the override entirely so the
# Release config in project.yml picks it up. Pass it as an extra
# argument otherwise.
EXTRA_ARGS=()
if [ -n "$SIGN_IDENTITY" ]; then
  EXTRA_ARGS+=("CODE_SIGN_IDENTITY=$SIGN_IDENTITY")
  EXTRA_ARGS+=("CODE_SIGN_STYLE=Manual")
  EXTRA_ARGS+=("CODE_SIGNING_REQUIRED=YES")
  EXTRA_ARGS+=("CODE_SIGNING_ALLOWED=YES")
fi

xcodebuild \
  -project Pidgy.xcodeproj \
  -scheme Pidgy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  build \
  | xcbeautify --quiet 2>/dev/null \
  || xcodebuild \
       -project Pidgy.xcodeproj \
       -scheme Pidgy \
       -configuration Release \
       -destination 'generic/platform=macOS' \
       -derivedDataPath "$DERIVED" \
       ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
       build

APP_PATH="$DERIVED/Build/Products/Release/Pidgy.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: build produced no app at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying .app signature"
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

# Sign the DMG itself. Pick the right identity:
#   - explicit override via --sign / --ad-hoc → use that
#   - otherwise read it back from the .app we just signed (so the
#     DMG and the app share an identity)
DMG_SIGN_IDENTITY="$SIGN_IDENTITY"
if [ -z "$DMG_SIGN_IDENTITY" ]; then
  DMG_SIGN_IDENTITY=$(codesign -dvv "$APP_PATH" 2>&1 \
    | sed -n 's/^Authority=//p' | head -1)
  if [ -z "$DMG_SIGN_IDENTITY" ]; then
    DMG_SIGN_IDENTITY="-"
  fi
fi

echo "==> Signing the .dmg with: $DMG_SIGN_IDENTITY"
codesign --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_OUT"

if [ "$NOTARIZE" -eq 1 ]; then
  echo "==> Submitting $DMG_OUT to notarytool (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG_OUT" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_OUT"
  xcrun stapler validate "$DMG_OUT"
  echo "==> Verifying Gatekeeper acceptance"
  spctl -a -t open --context context:primary-signature -vv "$DMG_OUT" || true
fi

echo
echo "Done. Output:"
ls -lh "$DMG_OUT"
echo
echo "Test locally:"
echo "  open $DMG_OUT"
