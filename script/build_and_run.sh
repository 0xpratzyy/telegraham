#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Pidgy"
BUNDLE_ID="com.pidgy.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${PIDGY_DERIVED_DATA:-/private/tmp/pidgy-codex-derived}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  local package_args=()
  if [[ -n "${PIDGY_CLONED_SOURCE_PACKAGES:-}" ]]; then
    package_args+=(
      -clonedSourcePackagesDirPath "$PIDGY_CLONED_SOURCE_PACKAGES"
      -disableAutomaticPackageResolution
    )
  fi

  xcodebuild \
    -project "$ROOT_DIR/Pidgy.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${package_args[@]}" \
    build
}

launch_app() {
  local open_args=(-n)
  if [[ -n "${PIDGY_DASHBOARD_ON_LAUNCH:-}" ]]; then
    open_args+=(--env "PIDGY_DASHBOARD_ON_LAUNCH=$PIDGY_DASHBOARD_ON_LAUNCH")
  fi
  /usr/bin/open "${open_args[@]}" "$APP_BUNDLE"
}

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

stop_running_app
build_app

case "$MODE" in
  run)
    launch_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    launch_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
