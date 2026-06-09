#!/usr/bin/env bash
# Tree-wide credential scan for CI.
#
# Same patterns as the push-range scan in scripts/git-hooks/pre-push,
# but run over the checked-out tracked tree instead of a commit range,
# so GitHub Actions can run it on any ref without needing push context.
# The pre-push hook remains the history-aware first line of defense;
# this is the server-side backstop for clones that never ran
# scripts/install-hooks.sh (or pushed with --no-verify).
#
# Patterns kept narrow on purpose — false positives train people to
# ignore the gate, which defeats the point.
#   sntrys_…   → Sentry auth tokens
#   sk-…       → OpenAI keys (≥40 chars after prefix)
#   sk-ant-…   → Anthropic keys
#   api_hash = "<32 hex chars>"  → Telegram api_hash literal
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

patterns=(
  'sntrys_[A-Za-z0-9+/=_-]{20,}'
  'sk-[A-Za-z0-9_-]{40,}'
  'sk-ant-[A-Za-z0-9_-]{40,}'
  '[Aa][Pp][Ii]_?[Hh]ash[[:space:]]*[=:][[:space:]]*"?[a-f0-9]{32}"?'
)

# Excludes:
#   - BetaSecrets.local.xcconfig is untracked by design, but exclude it
#     anyway in case this script is ever pointed at a dirty tree.
#   - This script and the pre-push hook contain the patterns themselves
#     as regex source strings.
excludes=(
  ':(exclude)Config/BetaSecrets.local.xcconfig'
  ':(exclude)Config/BetaSecrets.local.xcconfig.template'
  ':(exclude)scripts/scan_secrets.sh'
  ':(exclude)scripts/git-hooks/pre-push'
)

hits=0
for pattern in "${patterns[@]}"; do
  # -I skips binaries; git grep exits 1 on no match, which is the
  # good case here.
  if git grep -I -nE "$pattern" -- "${excludes[@]}"; then
    hits=1
  fi
done

if [ "$hits" -ne 0 ]; then
  echo "" >&2
  echo "ERROR: credential-looking strings found in tracked files (matches above)." >&2
  echo "If a key is real: rotate it first, then rewrite history before merging." >&2
  exit 1
fi

echo "No credential patterns found in tracked files ✓"
