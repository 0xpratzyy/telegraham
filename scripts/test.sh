#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/source_build_settings.sh"
python3 scripts/scan_secrets.py
python3 -m unittest discover -s tools -p 'test_*.py'
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 tools/product_prompt_oracle_bench.py --variants product_coverage_v2 --require-perfect
node --check infra/ai-proxy/worker.js
node infra/ai-proxy/invite-smoke.test.mjs
(cd tools/WhatsAppBridge && go test ./... && go vet ./...)
xcodegen generate
xcodebuild -project Pidgy.xcodeproj -scheme Pidgy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${PIDGY_DERIVED_DATA:-/private/tmp/pidgy-codex-derived}" \
  -clonedSourcePackagesDirPath "${PIDGY_CLONED_SOURCE_PACKAGES:-/private/tmp/pidgy-source-packages}" \
  "${PIDGY_SOURCE_BUILD_SETTINGS[@]}" test
