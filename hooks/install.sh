#!/usr/bin/env bash
# Installs the pve-proxy git hooks (sets core.hooksPath to hooks/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$ROOT" config core.hooksPath hooks
echo "Git hooks installed (core.hooksPath=hooks) -> $ROOT/hooks"
