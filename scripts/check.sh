#!/usr/bin/env bash
# Local validation for the pve-proxy repo.
# Usage: scripts/check.sh
# Used by hooks/pre-commit and available for manual/CI runs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

echo "==> Shell syntax (bash -n)"
while IFS= read -r f; do
  bash -n "$f" || { echo "ERROR: bash syntax error in $f"; fail=1; }
done < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './.omo/*' | sort)

echo "==> Python syntax (render_caddyfile.py)"
if command -v uv &>/dev/null; then
  uv run --no-project --no-dev python -m py_compile usr/local/bin/render_caddyfile.py \
    || { echo "ERROR: render_caddyfile.py failed to compile"; fail=1; }
elif command -v python3 &>/dev/null; then
  python3 -m py_compile usr/local/bin/render_caddyfile.py \
    || { echo "ERROR: render_caddyfile.py failed to compile"; fail=1; }
else
  echo "WARN: neither uv nor python3 found; skipping Python compile check"
fi

echo "==> Secret scan (working tree)"
# Flags accidental credential values (16+ chars, no placeholder chars $ % < space).
if grep -rInE '(CLOUDFLARE_API_TOKEN|PVE_TOKEN_ID|PVE_TOKEN_SECRET|BASIC_AUTH_HASH)=[^$%< ]{16,}' \
     --exclude-dir=.git --exclude-dir=.omo --exclude-dir=.venv . 2>/dev/null; then
  echo "ERROR: possible secret value found in the tree"
  fail=1
else
  echo "    no secrets found"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Checks FAILED."
  exit 1
fi
echo "==> All checks passed"
exit 0
