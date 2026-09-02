#!/usr/bin/env bash
# Create or update the Cloudflare wildcard DNS record for the proxy.
# Usage: pve-proxy-dns.sh <base-domain> <ipv4>
# Reads CLOUDFLARE_API_TOKEN from /etc/pve-proxy/cloudflare.env.
# Token needs: Zone:Read + Zone:DNS:Edit scoped to the zone.
set -Eeuo pipefail

# cron/systemd supply a minimal PATH; our binaries live under /usr/local/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Centralized logging/state/guardrails (graceful fallback if not yet deployed).
PP_COMPONENT="${PP_COMPONENT:-dns}"
if [ -f /usr/local/lib/pve-proxy/common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/pve-proxy/common.sh
  pp_init
else
  pp_init() { :; }
  pp_info() { echo "$*"; }
  pp_ok()   { echo "OK: $*"; }
  pp_warn() { echo "WARN: $*" >&2; }
  pp_err()  { echo "ERROR: $*" >&2; }
  pp_die()  { pp_err "$*"; exit 1; }
  pp_write_state() { :; }
fi

DOMAIN="${1:?usage: pve-proxy-dns.sh <base-domain> <ipv4>}"
IP="${2:?usage: pve-proxy-dns.sh <base-domain> <ipv4>}"

# Prefer the renderer's venv python; fall back to the system python.
PY="/opt/pve-proxy/.venv/bin/python"
command -v "$PY" >/dev/null 2>&1 || PY=python3

TOKEN=$(grep -oP '^CLOUDFLARE_API_TOKEN=\K.*' /etc/pve-proxy/cloudflare.env 2>/dev/null | head -n1)
if [ -z "$TOKEN" ]; then
  pp_write_state dns "{\"ts\":\"$(date -Is)\",\"ok\":false,\"action\":\"guard\",\"error\":\"cloudflare token empty\"}"
  pp_die "CLOUDFLARE_API_TOKEN not set in /etc/pve-proxy/cloudflare.env (config.sh -> 1)"
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
pp_info "Resolving Cloudflare zone for ${DOMAIN}"
ZONE=$(curl -s --connect-timeout 10 --max-time 20 "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
  | json_get 'd["result"][0]["id"] if d.get("success") and d.get("result") else ""')
if [ -z "$ZONE" ]; then
  pp_err "could not resolve zone for $DOMAIN (token needs Zone:Read + Zone:DNS:Edit)"
  pp_write_state dns "{\"ts\":\"$(date -Is)\",\"ok\":false,\"action\":\"zone-resolve\",\"domain\":\"${DOMAIN}\"}"
  exit 1
fi

# Update the existing record if present, otherwise create it.
REC=$(curl -s --connect-timeout 10 --max-time 20 "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=$NAME" \
  | json_get 'd["result"][0]["id"] if d.get("success") and d.get("result") else ""')
BODY="{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}"
if [ -n "$REC" ]; then
  if curl -s --connect-timeout 10 --max-time 20 -X PUT "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$REC" --data "$BODY" >/dev/null; then
    pp_ok "updated $NAME -> $IP (DNS only)"
  else
    pp_err "Cloudflare API PUT failed for $NAME"
    pp_write_state dns "{\"ts\":\"$(date -Is)\",\"ok\":false,\"action\":\"update\",\"domain\":\"${DOMAIN}\"}"
    exit 1
  fi
else
  if curl -s --connect-timeout 10 --max-time 20 -X POST "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" --data "$BODY" >/dev/null; then
    pp_ok "created $NAME -> $IP (DNS only)"
  else
    pp_err "Cloudflare API POST failed for $NAME"
    pp_write_state dns "{\"ts\":\"$(date -Is)\",\"ok\":false,\"action\":\"create\",\"domain\":\"${DOMAIN}\"}"
    exit 1
  fi
fi
pp_write_state dns "{\"ts\":\"$(date -Is)\",\"ok\":true,\"action\":\"$( [ -n "$REC" ] && echo update || echo create )\",\"domain\":\"${DOMAIN}\",\"name\":\"${NAME}\",\"ip\":\"${IP}\"}"
