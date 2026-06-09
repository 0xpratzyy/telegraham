#!/usr/bin/env bash
#
# check_release.sh — Pidgy release / auto-update invariant checker.
#
# Catches the failure modes that have actually bitten us:
#   - CFBundleVersion (CURRENT_PROJECT_VERSION) not bumped → Sparkle
#     sees the same build number and offers no update (1.0.0–1.0.3 bug).
#   - MARKETING_VERSION not bumped.
#   - "Check for Updates" wired via manual NSMenu insert (dropped by
#     SwiftUI's menu rebuild) instead of a SwiftUI .commands entry.
#   - Appcast shipped with a stale/duplicate sparkle:version, a bad
#     enclosure URL (404), or a missing EdDSA signature.
#   - DMG not notarized / not stapled.
#
# Usage (run from the telegraham repo root):
#   scripts-or-skill/check_release.sh preflight              # before make_dmg.sh --publish
#   scripts-or-skill/check_release.sh postflight [DMG_PATH]   # after appcast push
#
# Exit code 0 = all green, 1 = at least one FAIL. WARNs don't fail.

set -uo pipefail

MODE="${1:-}"
DMG_ARG="${2:-}"

# Resolve repo root: prefer the telegraham checkout the script is run
# from. Fall back to git toplevel.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PROJECT_YML="$REPO/project.yml"
APPDELEGATE="$REPO/Sources/App/AppDelegate.swift"
PIDGYAPP="$REPO/Sources/App/PidgyApp.swift"

FAILS=0
WARNS=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ FAIL\033[0m %s\n' "$1"; FAILS=$((FAILS+1)); }
warn() { printf '  \033[33m! WARN\033[0m %s\n' "$1"; WARNS=$((WARNS+1)); }
info() { printf '  · %s\n' "$1"; }

if [ ! -f "$PROJECT_YML" ]; then
  echo "error: project.yml not found at $PROJECT_YML — run from the telegraham repo." >&2
  exit 2
fi

# ── Read versions from project.yml ──────────────────────────────────
MARKETING=$(grep -E '^\s*MARKETING_VERSION:' "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILDNUM=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | head -1 | sed -E 's/.*CURRENT_PROJECT_VERSION:[[:space:]]*([0-9]+).*/\1/')

# ── Fetch the live appcast (SUFeedURL) ──────────────────────────────
# CHECK_RELEASE_FEED_URL overrides the feed (e.g. a file:// fixture) so this
# checker can be exercised offline against a crafted appcast. Falls back to the
# SUFeedURL in project.yml, then the canonical releases feed.
FEED_URL="${CHECK_RELEASE_FEED_URL:-}"
if [ -z "$FEED_URL" ]; then
  FEED_URL=$(grep -E 'SUFeedURL:' "$PROJECT_YML" | head -1 | sed -E 's/.*(https?:\/\/[^[:space:]]+).*/\1/')
  [ -z "$FEED_URL" ] && FEED_URL="https://raw.githubusercontent.com/0xpratzyy/pidgy-releases/main/appcast.xml"
fi
APPCAST="$(curl -fsSL "$FEED_URL" 2>/dev/null || echo "")"

# Strip XML comments BEFORE any version/enclosure parsing below. The appcast's
# doc-comment header has carried a sample <item> with a real version string
# sitting ABOVE <channel>; without this, the grep-based readers treat that
# commented version as the live "top" and emit spurious version-mismatch FAILs
# on a perfectly good release (hit 2026-06-10 cutting 1.0.9 — the comment held a
# 1.0.8 sample, so preflight/postflight compared against 1.0.8, not the real
# channel top). Only real <channel> items must be parsed. perl -0777 slurps the
# whole document so comments spanning multiple lines are removed in one pass.
# Do NOT drop this guard: reintroducing comment-sensitive parsing silently
# breaks the version checks that are the entire point of this script.
if [ -n "$APPCAST" ] && command -v perl >/dev/null 2>&1; then
  APPCAST="$(printf '%s' "$APPCAST" | perl -0777 -pe 's/<!--.*?-->//gs')"
fi

# Newest <item> values (first occurrence = top of channel = newest).
appcast_top_short() { printf '%s' "$APPCAST" | grep -oE '<sparkle:shortVersionString>[^<]+' | head -1 | sed -E 's/.*>//'; }
appcast_top_build() { printf '%s' "$APPCAST" | grep -oE '<sparkle:version>[^<]+'             | head -1 | sed -E 's/.*>//'; }
appcast_2nd_build() { printf '%s' "$APPCAST" | grep -oE '<sparkle:version>[^<]+'             | sed -n '2p' | sed -E 's/.*>//'; }

ver_gt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }

echo "Pidgy release check — mode: ${MODE:-<none>}"
echo "  project.yml: MARKETING_VERSION=$MARKETING  CURRENT_PROJECT_VERSION=$BUILDNUM"
[ -n "$APPCAST" ] && echo "  live appcast top: $(appcast_top_short) (build $(appcast_top_build))" || echo "  live appcast: UNREACHABLE ($FEED_URL)"
echo

case "$MODE" in
  preflight)
    echo "── Preflight (run before make_dmg.sh --publish) ──"

    # 1. Build number strictly greater than the live appcast's top.
    #    THE bug that broke 1.0.0–1.0.3. This check must fail CLOSED:
    #    an unreachable appcast or a non-numeric operand is a FAIL,
    #    never a WARN — otherwise a network blip silently turns the
    #    one check that matters into a no-op and green-lights a
    #    can't-update build.
    TOP_BUILD="$(appcast_top_build)"
    if [ -z "$APPCAST" ]; then
      fail "appcast unreachable ($FEED_URL) — cannot confirm the build number is newer. Re-run online; do NOT ship blind."
    elif ! printf '%s' "$TOP_BUILD" | grep -qE '^[0-9]+$'; then
      fail "appcast has no numeric sparkle:version to compare against (got '$TOP_BUILD')"
    elif ! printf '%s' "$BUILDNUM" | grep -qE '^[0-9]+$'; then
      fail "couldn't read a numeric CURRENT_PROJECT_VERSION from project.yml (got '$BUILDNUM') — check the line isn't quoted/reformatted"
    elif [ "$BUILDNUM" -gt "$TOP_BUILD" ]; then
      pass "CURRENT_PROJECT_VERSION ($BUILDNUM) > shipped build ($TOP_BUILD) — Sparkle will see it as newer"
    else
      fail "CURRENT_PROJECT_VERSION ($BUILDNUM) is NOT greater than shipped build ($TOP_BUILD). Sparkle compares this integer; bump it or no update is offered."
    fi

    # 2. Marketing version bumped vs appcast top.
    if [ -n "$APPCAST" ] && [ -n "$(appcast_top_short)" ]; then
      if ver_gt "$MARKETING" "$(appcast_top_short)"; then
        pass "MARKETING_VERSION ($MARKETING) > shipped ($(appcast_top_short))"
      else
        fail "MARKETING_VERSION ($MARKETING) is not newer than shipped ($(appcast_top_short))"
      fi
    fi

    # 3. Git tree clean (--notarize refuses a dirty tree).
    if [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
      pass "git tree clean (notarize won't bail)"
    else
      warn "git tree dirty — commit before make_dmg.sh --notarize/--publish"
    fi

    # 4. "Check for Updates" wired via SwiftUI .commands, not manual NSMenu.
    if grep -q 'CommandGroup' "$PIDGYAPP" 2>/dev/null && grep -qi 'Check for Updates' "$PIDGYAPP" 2>/dev/null; then
      pass "Check-for-Updates declared via SwiftUI .commands in PidgyApp.swift"
    elif grep -q 'installCheckForUpdatesMenuItem' "$APPDELEGATE" 2>/dev/null; then
      fail "Check-for-Updates uses manual NSMenu insertion (installCheckForUpdatesMenuItem) — SwiftUI rebuilds the menu and drops it. Move to a .commands entry in PidgyApp.swift."
    else
      warn "couldn't confirm how Check-for-Updates is wired"
    fi

    # 5. Sparkle keys present.
    grep -q 'SUPublicEDKey:' "$PROJECT_YML" && pass "SUPublicEDKey present" || fail "SUPublicEDKey missing from Info.plist properties"
    grep -q 'SUFeedURL:'    "$PROJECT_YML" && pass "SUFeedURL present"    || fail "SUFeedURL missing from Info.plist properties"
    ;;

  postflight)
    echo "── Postflight (run after the appcast is pushed) ──"
    if [ -z "$APPCAST" ]; then
      fail "appcast unreachable at $FEED_URL — can't verify the release"
      echo; echo "Result: $FAILS fail(s), $WARNS warn(s)"; exit 1
    fi

    # 1. Appcast top matches what project.yml just built.
    [ "$(appcast_top_build)" = "$BUILDNUM" ] \
      && pass "appcast sparkle:version ($(appcast_top_build)) matches built CFBundleVersion ($BUILDNUM)" \
      || fail "appcast sparkle:version ($(appcast_top_build)) != built CFBundleVersion ($BUILDNUM)"
    [ "$(appcast_top_short)" = "$MARKETING" ] \
      && pass "appcast shortVersionString ($(appcast_top_short)) matches MARKETING_VERSION ($MARKETING)" \
      || fail "appcast shortVersionString ($(appcast_top_short)) != MARKETING_VERSION ($MARKETING)"

    # 2. Build number strictly increased vs the previous entry.
    SECOND="$(appcast_2nd_build)"
    if [ -n "$SECOND" ]; then
      [ "$(appcast_top_build)" -gt "$SECOND" ] 2>/dev/null \
        && pass "build number increased: $SECOND → $(appcast_top_build)" \
        || fail "build number did NOT increase ($SECOND → $(appcast_top_build)) — duplicate sparkle:version means no update is offered"
    fi

    # 3. Enclosure URL resolves (the GitHub release asset exists).
    ENCLOSURE=$(printf '%s' "$APPCAST" | grep -oE 'url="[^"]+\.dmg"' | head -1 | sed -E 's/url="([^"]+)"/\1/')
    if [ -n "$ENCLOSURE" ]; then
      CODE=$(curl -s -o /dev/null -w '%{http_code}' -I -L "$ENCLOSURE" 2>/dev/null)
      [ "$CODE" = "200" ] \
        && pass "enclosure URL reachable (HTTP 200): $(basename "$ENCLOSURE")" \
        || fail "enclosure URL returned HTTP $CODE — DMG not uploaded to the GitHub release? $ENCLOSURE"
    else
      fail "no .dmg enclosure URL found in the newest appcast item"
    fi

    # 4. EdDSA signature present on the newest enclosure.
    printf '%s' "$APPCAST" | grep -q 'sparkle:edSignature=' \
      && pass "EdDSA signature present on enclosure" \
      || fail "newest enclosure has no sparkle:edSignature — Sparkle will reject the download"

    # 5. If a DMG path was given, confirm it's notarized + stapled.
    if [ -n "$DMG_ARG" ] && [ -f "$DMG_ARG" ]; then
      if xcrun stapler validate "$DMG_ARG" >/dev/null 2>&1; then
        pass "DMG notarization ticket stapled + valid"
      else
        fail "stapler validate failed on $DMG_ARG — not notarized/stapled"
      fi
      if spctl -a -t open --context context:primary-signature "$DMG_ARG" >/dev/null 2>&1; then
        pass "Gatekeeper accepts the DMG"
      else
        warn "spctl did not accept the DMG (may still be fine for a .dmg container)"
      fi
    else
      info "pass the DMG path as arg 2 to also verify notarization/stapling"
    fi
    ;;

  *)
    echo "usage: check_release.sh {preflight|postflight} [DMG_PATH]" >&2
    exit 2
    ;;
esac

echo
if [ "$FAILS" -gt 0 ]; then
  printf '\033[31mResult: %d FAIL, %d warn — do NOT ship until fixed.\033[0m\n' "$FAILS" "$WARNS"
  exit 1
else
  printf '\033[32mResult: all checks passed (%d warn).\033[0m\n' "$WARNS"
  exit 0
fi
