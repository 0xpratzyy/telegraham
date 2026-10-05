#!/usr/bin/env bash
# Paid synthetic evaluations only. Does not enable the production extractor.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--live" ]]; then
  echo 'Usage: tools/run_jev_extraction_eval.sh --live (uses saved API credentials)' >&2
  exit 2
fi
python3 tools/jev_fact_extraction_bench.py --live
python3 tools/jev_fact_extraction_bench.py --live --batches
# Avoid concurrent writes to the local usage meter. Relaunch the existing bundle on exit.
APP_BUNDLE=/private/tmp/pidgy-codex-derived/Build/Products/Debug/Pidgy.app
pkill -x Pidgy || true
trap 'open -n "$APP_BUNDLE"' EXIT
TEST_RUNNER_PIDGY_LIVE_DIRECT_FACTS=1 xcodebuild \
  -project Pidgy.xcodeproj -scheme Pidgy -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/pidgy-codex-derived \
  -clonedSourcePackagesDirPath /private/tmp/pidgy-source-packages \
  -only-testing:PidgyTests/TypeSafeAppTests \
  -only-testing:PidgyTests/TypeSafeAppBenchmark/testLiveDirectFactComparison test
