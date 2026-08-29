#!/usr/bin/env bash
set -euo pipefail

source /etc/pve-proxy/pve-token.env
source /etc/pve-proxy/proxy.env

CADDYFILE=/etc/caddy/Caddyfile
WORKDIR=/etc/pve-proxy
STAGED="$WORKDIR/Caddyfile.staged"
TEMPLATE=/etc/caddy/Caddyfile.template
SERVICES="$WORKDIR/services.yaml"

cd "$WORKDIR"

# Snapshot current config for rollback
git add -A && git commit -m "pre-sync snapshot $(date -Iseconds)" --allow-empty -q 2>/dev/null || true

# Pull live container list from PVE (read-only PVEAuditor scope)
curl -sk \
  -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
  "https://${PVE_HOST}:8006/api2/json/cluster/resources?type=vm" \
  > live-containers.json

# Render the Caddyfile from template + live data + services.yaml
/opt/pve-proxy/.venv/bin/python /usr/local/bin/render_caddyfile.py \
  --live live-containers.json \
  --services "$SERVICES" \
  --template "$TEMPLATE" \
  --domain "$DOMAIN" \
  --email "$EMAIL" \
  --out "$STAGED"

# Validate before touching live config
if ! caddy validate --config "$STAGED"; then
  echo "pve-proxy-sync: generated Caddyfile failed validation, aborting" >&2
  systemd-cat -t pve-proxy -p err <<< "sync failed: Caddyfile validation error at $(date -Iseconds)"
  exit 1
fi

# Replace live file and reload
cp "$STAGED" "$CADDYFILE"
if ! caddy reload --config "$CADDYFILE"; then
  echo "pve-proxy-sync: reload failed, rolling back" >&2
  systemd-cat -t pve-proxy -p err <<< "sync failed: caddy reload error at $(date -Iseconds)"
  git checkout -- Caddyfile
  cp "$WORKDIR/Caddyfile" "$CADDYFILE"
  caddy reload --config "$CADDYFILE"
  exit 1
fi

git add -A && git commit -m "sync applied $(date -Iseconds)" -q 2>/dev/null || true
