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
PUBLISH=0
NOTARY_PROFILE="pidgy-beta"
# Where the public appcast lives — Sparkle on each tester's Mac
# polls this URL. The DMG itself gets attached to a matching
# GitHub Release in the same repo, so the URL pattern below
# (`download/v{version}/...`) is deterministic.
APPCAST_REPO="0xpratzyy/pidgy-releases"

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
    --publish)
      # Sign the DMG with Sparkle's EdDSA key (using the private
      # key from the Keychain) and print the appcast <item> entry
      # to paste into pidgy-releases/appcast.xml. Forces
      # --notarize so we never publish an un-notarized build.
      PUBLISH=1
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
# Ad-hoc smoke-test builds can't run with hardened runtime: the
# library validation pass in hardened runtime refuses to load a
# non-platform framework whose Team ID doesn't match the host
# process. Two ad-hoc signatures both have Team ID "" — and
# macOS treats that as "doesn't match" rather than "matches".
# Result: dyld kills Pidgy at launch with "Library not loaded:
# Sparkle.framework ... different Team IDs". Strip hardened
# runtime when ad-hoc; Release builds that go on to notarization
# (--notarize) keep it.
if [ "$SIGN_IDENTITY" = "-" ]; then
  EXTRA_ARGS+=("ENABLE_HARDENED_RUNTIME=NO")
  EXTRA_ARGS+=("OTHER_CODE_SIGN_FLAGS=")
fi

xcodebuild \
  -project Pidgy.xcodeproj \
  -scheme Pidgy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath SourcePackages \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  build \
  | xcbeautify --quiet 2>/dev/null \
  || xcodebuild \
       -project Pidgy.xcodeproj \
       -scheme Pidgy \
       -configuration Release \
       -destination 'generic/platform=macOS' \
       -derivedDataPath "$DERIVED" \
       -clonedSourcePackagesDirPath SourcePackages \
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
DMG_RW="$(mktemp -t pidgy-dmg-rw-XXXXXXXX).dmg"
trap 'rm -rf "$DERIVED" "$DMG_STAGING"; rm -f "$DMG_RW"' EXIT

cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Note: Finder draws the stock macOS /Applications icon over this
# symlink — we can't override it. macOS blocks `setxattr` on
# `com.apple.ResourceFork` for symlinks at the kernel level
# (Operation not permitted, even with XATTR_NOFOLLOW), and embedding
# the icon directly in the .DS_Store would require a from-scratch
# Buddy Allocator implementation. Every major shipping mac app
# (Slack, 1Password, Discord, …) uses the stock icon here too.

# Render the illustrated background PNG (720×452 @2x) and drop it into
# a hidden `.background/` folder inside the staging dir — that path is
# referenced by the AppleScript block below that customizes the Finder
# window. The PNG bakes the wallpaper, gradient overlay, dashed arrow,
# and instruction pill; Finder draws the real Pidgy.app and
# Applications icons on top of it at the configured positions.
echo "==> Rendering install-window background"
mkdir -p "$DMG_STAGING/.background"
swift scripts/render_install_bg.swift \
  --output "$DMG_STAGING/.background/install-bg.png"

mkdir -p dist
DMG_OUT="dist/Pidgy-${SHORT_SHA}.dmg"
rm -f "$DMG_OUT"

# Two-step DMG build:
#
#   1. Create a read-write APFS image from the staging dir. We need
#      it writable so AppleScript can drop a customized `.DS_Store`
#      into it (window size, background image, icon positions).
#
#   2. Mount it, run the customization script, eject, then convert
#      to a compressed UDZO read-only image. The compressed image
#      is what ships to testers.
#
# This is the same dance create-dmg / appdmg do under the hood —
# we keep it explicit so the script stays a single tracked file
# rather than a Homebrew dependency every developer must install.
DMG_VOLUME_NAME="Pidgy 1.0"
echo "==> Creating writable scratch image"
hdiutil create \
  -volname "$DMG_VOLUME_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$DMG_RW" >/dev/null

# Pre-flight: if Finder already has a "Pidgy 1.0" volume mounted from
# a previous build, the upcoming `tell disk` would address the WRONG
# window (the stale one) and write customization there. Eject any
# pre-existing volumes by the same name before we mount the fresh
# scratch image.
for pre in /Volumes/Pidgy\ 1.0*; do
  if [ -d "$pre" ]; then
    echo "==> Detaching stale volume $pre"
    hdiutil detach "$pre" -force >/dev/null 2>&1 || true
  fi
done

echo "==> Mounting scratch image to customize window layout"
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")
MOUNT_DEV=$(echo "$MOUNT_INFO" | grep -E '^/dev/' | head -1 | awk '{print $1}')
MOUNT_POINT=$(echo "$MOUNT_INFO" | grep -E '/Volumes/' | head -1 | sed -E 's/.*(\/Volumes\/[^	]+).*/\1/')
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
  echo "error: couldn't determine mount point from hdiutil output" >&2
  echo "$MOUNT_INFO" >&2
  exit 1
fi
# Bail if hdiutil deduplicated and gave us "Pidgy 1.0 2" or similar
# — that means there's a stale volume we missed. Same window
# confusion as above would result.
if [ "$MOUNT_POINT" != "/Volumes/$DMG_VOLUME_NAME" ]; then
  echo "error: mounted at unexpected path $MOUNT_POINT (expected /Volumes/$DMG_VOLUME_NAME)" >&2
  echo "       there's probably a stale 'Pidgy 1.0' volume still attached." >&2
  hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
  exit 1
fi

# Apply the Finder layout via AppleScript. The numbers here mirror
# the design handoff exactly:
#   - Window content area 720×452 (bounds height 480 includes the
#     system titlebar Finder draws over the top 28pt)
#   - Pidgy.app icon center at (188, 220)
#   - Applications symlink center at (532, 220)
#   - Icon size 128
#   - Toolbar + status bar hidden so the wallpaper reads cleanly
#
# Pipe stderr through so AppleScript errors actually surface
# instead of disappearing into a black hole. The `|| ...` is
# essential: under `set -e` a bare osascript that exits nonzero
# would abort the whole script BEFORE the `APPLESCRIPT_RC` capture
# below, skipping the cleanup detach and leaving the scratch volume
# mounted (which then trips the stale-volume guard on the next run).
APPLESCRIPT_RC=0
osascript 2>&1 <<APPLESCRIPT || APPLESCRIPT_RC=$?
tell application "Finder"
  tell disk "$DMG_VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    -- {left, top, right, bottom} on the screen; size = right-left, bottom-top
    set the bounds of container window to {200, 120, 920, 600}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 12
    set label position of viewOptions to bottom
    set background picture of viewOptions to file ".background:install-bg.png"
    set position of item "Pidgy.app" of container window to {188, 220}
    set position of item "Applications" of container window to {532, 220}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
if [ "$APPLESCRIPT_RC" -ne 0 ]; then
  echo "error: AppleScript customization failed (exit $APPLESCRIPT_RC)" >&2
  hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
  exit 1
fi

# Give Finder a generous moment to flush the .DS_Store before we
# eject — anything less than ~2s has been observed to lose the
# settings entirely on busy machines.
sync || true
sleep 3

# Verify the customization actually landed. Without a .DS_Store on
# the volume, Finder will fall back to its default icon arrangement
# (icons in the top-left, no background, toolbar visible) — exactly
# the "stock" appearance we're trying to avoid.
if [ ! -f "$MOUNT_POINT/.DS_Store" ]; then
  echo "error: .DS_Store was not written by AppleScript — DMG would ship without customization" >&2
  hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
  exit 1
fi
DS_STORE_SIZE=$(stat -f '%z' "$MOUNT_POINT/.DS_Store")
echo "==> .DS_Store written ($DS_STORE_SIZE bytes)"

echo "==> Detaching scratch image"
hdiutil detach "$MOUNT_DEV" -force >/dev/null

echo "==> Compressing to read-only $DMG_OUT"
hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT" >/dev/null

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

if [ "$PUBLISH" -eq 1 ]; then
  # Sparkle's sign_update tool lives inside the resolved SPM
  # checkout. We find it dynamically because the path includes
  # a hash that changes per Xcode version. Prefer THIS build's
  # DerivedData ($DERIVED — where xcodebuild just unpacked the
  # Sparkle SPM artifact), then fall back to the user's global
  # DerivedData.
  SIGN_UPDATE=$(find "$DERIVED" \
                     -name "sign_update" -type f \
                     -not -path "*old_dsa*" 2>/dev/null | head -1)
  if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                       -name "sign_update" -type f \
                       -not -path "*old_dsa*" 2>/dev/null | head -1)
  fi
  if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
    echo "error: couldn't find Sparkle's sign_update binary." >&2
    echo "       Run an Xcode build first so SPM unpacks Sparkle." >&2
    exit 1
  fi

  echo "==> Signing the .dmg with Sparkle's EdDSA key"
  # sign_update prints attributes you can paste straight into the
  # enclosure element of an appcast item, e.g.:
  #   sparkle:edSignature="abc..." length="74448219"
  SPARKLE_ATTRS=$("$SIGN_UPDATE" "$DMG_OUT")

  # Pull the version out of the built Info.plist so the appcast
  # entry matches what the .app actually advertises.
  APP_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist")
  APP_BUILD=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "$APP_PATH/Contents/Info.plist")
  PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

  # The DMG needs a publicly-fetchable URL. We assume each release
  # is uploaded as an asset to a GitHub Release tagged v<version>
  # in the appcast repo — so the URL is fully determined by the
  # version. Adjust APPCAST_REPO at the top of the script if you
  # host elsewhere.
  RELEASE_URL="https://github.com/${APPCAST_REPO}/releases/download/v${APP_VERSION}/$(basename "$DMG_OUT")"

  echo
  echo "============================================================"
  echo "Appcast entry — paste into ${APPCAST_REPO}/appcast.xml:"
  echo "============================================================"
  cat <<EOF
    <item>
      <title>Version ${APP_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${APP_BUILD}</sparkle:version>
      <sparkle:shortVersionString>${APP_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <!-- TODO: release notes for ${APP_VERSION} go here -->
      ]]></description>
      <enclosure url="${RELEASE_URL}"
                 type="application/octet-stream"
                 ${SPARKLE_ATTRS} />
    </item>
EOF
  echo "============================================================"
  echo
  echo "Next steps to actually ship the update:"
  echo "  1. Create the GitHub release + upload the DMG:"
  echo "       gh release create v${APP_VERSION} \\"
  echo "         --repo ${APPCAST_REPO} \\"
  echo "         --title 'Pidgy ${APP_VERSION}' \\"
  echo "         --notes 'release notes here' \\"
  echo "         ${DMG_OUT}"
  echo "  2. Paste the <item> block above into appcast.xml at"
  echo "     the top of <channel> (newest entries go first)."
  echo "  3. Commit + push that repo. Within ~5 min of GitHub CDN"
  echo "     refresh, every installed Pidgy will see the update on"
  echo "     its next scheduled check."
fi

echo
echo "Done. Output:"
ls -lh "$DMG_OUT"
echo
echo "Test locally:"
echo "  open $DMG_OUT"
