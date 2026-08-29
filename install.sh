#!/usr/bin/env bash
# One-liner installer: bash -c "$(curl -fsSL https://raw.githubusercontent.com/vinodnal/pve-proxy/main/create-lxc.sh)"
# This is a thin wrapper that downloads and runs create-lxc.sh on a PVE host.
set -euo pipefail

REPO="https://github.com/vinodnal/pve-proxy"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v git &>/dev/null; then
  apt-get update -qq && apt-get install -yqq git >/dev/null 2>&1
fi

git clone --depth 1 "$REPO" "$TMPDIR/pve-proxy"
bash "$TMPDIR/pve-proxy/create-lxc.sh"
