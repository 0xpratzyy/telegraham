#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/tools/WhatsAppBridge"
OUTPUT="$BRIDGE_DIR/bin/pidgy-whatsapp-bridge"
ARCHITECTURES="${ARCHS:-$(uname -m)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
BUILD_STAMP="$ARCHITECTURES;macOS=$DEPLOYMENT_TARGET"
ARCH_STAMP="$OUTPUT.architectures"

if [[ -x "$OUTPUT" && -f "$ARCH_STAMP" ]] &&
   [[ "$(cat "$ARCH_STAMP")" == "$BUILD_STAMP" ]] &&
   ! find "$BRIDGE_DIR" -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) \
     -newer "$OUTPUT" -print -quit | grep -q . &&
   [[ ! "${BASH_SOURCE[0]}" -nt "$OUTPUT" ]]; then
  echo "WhatsApp bridge is up to date ($ARCHITECTURES)"
  exit 0
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: Go 1.25+ is required to build the read-only WhatsApp bridge." >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pidgy-bridge.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT
BINARIES=()
for arch in $ARCHITECTURES; do
  case "$arch" in
    arm64) target=arm64 ;;
    x86_64) target=amd64 ;;
    *) echo "error: unsupported macOS architecture: $arch" >&2; exit 1 ;;
  esac
  binary="$SCRATCH_DIR/bridge-$arch"
  (
    cd "$BRIDGE_DIR"
    GOCACHE="${PIDGY_GO_BUILD_CACHE:-/private/tmp/pidgy-go-build-cache}" \
      GOOS=darwin GOARCH="$target" CGO_ENABLED=1 CC=/usr/bin/clang \
      CGO_CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      CGO_LDFLAGS="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      go build -trimpath -ldflags="-s -w" -o "$binary" ./cmd/pidgy-whatsapp-bridge
  )
  BINARIES+=("$binary")
done
if [[ "${#BINARIES[@]}" == "1" ]]; then
  cp "${BINARIES[0]}" "$OUTPUT"
else
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$OUTPUT"
fi
chmod 755 "$OUTPUT"
printf '%s' "$BUILD_STAMP" > "$ARCH_STAMP"
echo "Built WhatsApp bridge ($ARCHITECTURES)"
