#!/bin/sh
# Isolated Jev-compatible decision server. Never exposes chat data on the LAN.
set -eu
cd "$(dirname "$0")/.."
if [ ! -x Build/Laya/.venv/bin/laya-serve ]; then
  uv venv --python 3.12 Build/Laya/.venv
  uv pip install --python Build/Laya/.venv/bin/python 'laya[serve]==0.3.21'
fi
export LAYA_HOST=127.0.0.1 LAYA_PORT=8889 LAYA_DEVICE=mps
export LAYA_PRELOAD=1 LAYA_MODELS=multilingual LAYA_MAX_LOADED=1 LAYA_THREADS=4
export LAYA_REVISION=55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851
export HF_HUB_DISABLE_TELEMETRY=1
exec Build/Laya/.venv/bin/laya-serve
