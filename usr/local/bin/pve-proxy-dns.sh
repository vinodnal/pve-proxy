#!/usr/bin/env bash
# Create or update the Cloudflare wildcard DNS record for the proxy.
# Usage: pve-proxy-dns.sh <base-domain> <ipv4>
# Reads CLOUDFLARE_API_TOKEN from /etc/pve-proxy/cloudflare.env.
# Token needs: Zone:Read + Zone:DNS:Edit scoped to the zone.
set -euo pipefail

DOMAIN="${1:?usage: pve-proxy-dns.sh <base-domain> <ipv4>}"
IP="${2:?usage: pve-proxy-dns.sh <base-domain> <ipv4>}"

# Prefer the renderer's venv python; fall back to the system python.
PY="/opt/pve-proxy/.venv/bin/python"
command -v "$PY" >/dev/null 2>&1 || PY=python3

TOKEN=$(grep -oP '^CLOUDFLARE_API_TOKEN=\K.*' /etc/pve-proxy/cloudflare.env 2>/dev/null | head -n1)
if [ -z "$TOKEN" ]; then
  echo "pve-proxy-dns: CLOUDFLARE_API_TOKEN not set in /etc/pve-proxy/cloudflare.env" >&2
  exit 1
fi

AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
NAME="*.$DOMAIN"

json_get() {
  "$PY" -c '
import sys, json
d = json.load(sys.stdin)
print(eval(sys.argv[1], {"d": d}))' "$1" 2>/dev/null || true
}

# Resolve the zone id for the domain (needs Zone:Read).
ZONE=$(curl -s "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
  | json_get 'd["result"][0]["id"] if d.get("success") and d.get("result") else ""')
if [ -z "$ZONE" ]; then
  echo "pve-proxy-dns: could not resolve zone for $DOMAIN (token needs Zone:Read + Zone:DNS:Edit)" >&2
  exit 1
fi

# Update the existing record if present, otherwise create it.
REC=$(curl -s "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=$NAME" \
  | json_get 'd["result"][0]["id"] if d.get("success") and d.get("result") else ""')
BODY="{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}"
if [ -n "$REC" ]; then
  curl -s -X PUT "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$REC" --data "$BODY" >/dev/null
  echo "pve-proxy-dns: updated $NAME -> $IP (DNS only)"
else
  curl -s -X POST "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" --data "$BODY" >/dev/null
  echo "pve-proxy-dns: created $NAME -> $IP (DNS only)"
fi
