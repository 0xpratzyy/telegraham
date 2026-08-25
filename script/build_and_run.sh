#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Pidgy"
BUNDLE_ID="com.pidgy.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${PIDGY_DERIVED_DATA:-/private/tmp/pidgy-codex-derived}"
SOURCE_PACKAGES_DIR="${PIDGY_CLONED_SOURCE_PACKAGES:-/private/tmp/pidgy-source-packages}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  "$ROOT_DIR/script/build_whatsapp_bridge.sh"
  xcodebuild \
    -project "$ROOT_DIR/Pidgy.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    build
}

launch_app() {
  local open_args=(-n)
  if [[ -n "${PIDGY_DASHBOARD_ON_LAUNCH:-}" ]]; then
    open_args+=(--env "PIDGY_DASHBOARD_ON_LAUNCH=$PIDGY_DASHBOARD_ON_LAUNCH")
  fi
  /usr/bin/open "${open_args[@]}" "$APP_BUNDLE"
}

wait_for_launched_binary() {
  local attempts=0
  while (( attempts < 40 )); do
    if pgrep -f -- "^${APP_BINARY}$" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    ((attempts += 1))
  done

  echo "Pidgy did not launch from the current build: $APP_BINARY" >&2
  echo "Running Pidgy processes:" >&2
  pgrep -af "$APP_NAME.app/Contents/MacOS/$APP_NAME" >&2 || true
  return 1
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
    wait_for_launched_binary
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
