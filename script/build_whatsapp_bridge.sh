#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/tools/WhatsAppBridge"
OUTPUT="$BRIDGE_DIR/bin/pidgy-whatsapp-bridge"

if [[ -x "$OUTPUT" ]] &&
   ! find "$BRIDGE_DIR" -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) \
     -newer "$OUTPUT" -print -quit | grep -q .; then
  echo "WhatsApp bridge is up to date"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go is required to build the read-only WhatsApp bridge." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
(
  cd "$BRIDGE_DIR"
  GOCACHE="${PIDGY_GO_BUILD_CACHE:-/private/tmp/pidgy-go-build-cache}" \
    CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o "$OUTPUT" ./cmd/pidgy-whatsapp-bridge
)
chmod 755 "$OUTPUT"
echo "Built $OUTPUT"
