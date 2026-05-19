#!/usr/bin/env bash
# scripts/install-hooks.sh
#
# Symlinks the tracked git hooks at scripts/git-hooks/* into
# .git/hooks/. Idempotent — re-running is safe.
#
# Run once per clone (e.g. after `git clone`, after onboarding a
# new contributor, after switching to a fresh worktree).

set -euo pipefail

cd "$(dirname "$0")/.."

git_dir=$(git rev-parse --git-dir)
hooks_src="scripts/git-hooks"
hooks_dst="${git_dir}/hooks"

mkdir -p "$hooks_dst"

installed=0
skipped=0
for src in "${hooks_src}"/*; do
  [ -f "$src" ] || continue
  hook_name=$(basename "$src")
  dst="${hooks_dst}/${hook_name}"

  # Compute the relative path FROM the destination directory TO
  # the source file, so the symlink survives worktree moves.
  rel_src=$(python3 -c "
import os, sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$(pwd)/${src}" "$(pwd)/${hooks_dst}")

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$rel_src" ]; then
    echo "  skip  ${hook_name} (already linked)"
    skipped=$((skipped + 1))
    continue
  fi

  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "  back  ${hook_name} (moving existing to ${hook_name}.bak)"
    mv "$dst" "${dst}.bak"
  fi

  ln -sfn "$rel_src" "$dst"
  chmod +x "$src"
  echo "  link  ${hook_name} → ${rel_src}"
  installed=$((installed + 1))
done

echo ""
echo "${installed} installed, ${skipped} already present."
echo ""
echo "Hooks active. Push to main now runs pre-push checks; --no-verify bypasses."
