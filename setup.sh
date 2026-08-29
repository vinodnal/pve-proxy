#!/usr/bin/env bash
# Backwards-compatible wrapper. The real installer lives in
# install/pve-proxy-install.sh (community-scripts style).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/install/pve-proxy-install.sh" "$SCRIPT_DIR"
