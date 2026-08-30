#!/usr/bin/env bash
# One-liner installer:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/vinodnal/pve-proxy/master/install.sh)"
# This is a thin wrapper that downloads and runs create-lxc.sh on a PVE host.
set -euo pipefail

REPO="https://github.com/vinodnal/pve-proxy"
# Pin the install to a release tag for reproducibility/audit, e.g.:
#   PVE_PROXY_REF=v1.0.0 bash -c "$(curl -fsSL .../install.sh)"
# Defaults to master when unset.
REF="${PVE_PROXY_REF:-master}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if ! command -v git &>/dev/null; then
  apt-get update -qq && apt-get install -yqq git >/dev/null 2>&1
fi

git clone --depth 1 --branch "$REF" "$REPO" "$TMPDIR/pve-proxy"
bash "$TMPDIR/pve-proxy/create-lxc.sh"
