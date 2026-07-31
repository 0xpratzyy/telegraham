#!/bin/bash
# Invite-system report: every code with its status + who redeemed it,
# and every registered install with its referral count. Reads the
# INVITES KV namespace via wrangler (run `wrangler login` first).
#
#   scripts/invite_report.sh
#
# Data is identifiers only (codes + random install ids) — safe to run
# anywhere, nothing personal comes back.
set -euo pipefail
cd "$(dirname "$0")/../infra/ai-proxy"

NS_ID=$(grep -A2 'binding = "INVITES"' wrangler.toml | grep '^id' | cut -d'"' -f2)
if [ -z "$NS_ID" ] || [ "$NS_ID" = "REPLACE_WITH_INVITES_NAMESPACE_ID" ]; then
  echo "error: INVITES namespace id not set in wrangler.toml" >&2
  exit 1
fi

echo "== Codes =="
# `|| true`: an empty namespace lists as [] and grep's miss must not
# kill the report under pipefail.
wrangler kv key list --namespace-id "$NS_ID" --prefix "code:" 2>/dev/null \
  | { grep '"name"' || true; } | cut -d'"' -f4 | while read -r key; do
    value=$(wrangler kv key get --namespace-id "$NS_ID" "$key" 2>/dev/null)
    code="${key#code:}"
    status=$(echo "$value" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    by=$(echo "$value" | sed -n 's/.*"createdBy":"\([^"]*\)".*/\1/p')
    redeemed=$(echo "$value" | sed -n 's/.*"redeemedAt":"\([^"]*\)".*/\1/p')
    if [ "$status" = "redeemed" ]; then
      echo "  $code  USED     (by-install: $(echo "$value" | sed -n 's/.*"redeemedBy":"\([^"]*\)".*/\1/p'), at: $redeemed, from: $by)"
    else
      echo "  $code  active   (from: $by)"
    fi
  done

echo ""
echo "== Installs =="
wrangler kv key list --namespace-id "$NS_ID" --prefix "install:" 2>/dev/null \
  | { grep '"name"' || true; } | cut -d'"' -f4 | while read -r key; do
    value=$(wrangler kv key get --namespace-id "$NS_ID" "$key" 2>/dev/null)
    id="${key#install:}"
    refs=$(echo "$value" | sed -n 's/.*"referrals":\([0-9]*\).*/\1/p')
    invited=$(echo "$value" | sed -n 's/.*"invitedBy":"\([^"]*\)".*/\1/p')
    echo "  $id  referrals: ${refs:-0}  invited-by: ${invited:-—}"
  done
