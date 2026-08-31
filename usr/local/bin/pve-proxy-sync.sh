#!/usr/bin/env bash
set -euo pipefail

WORKDIR=/etc/pve-proxy
CADDYFILE=/etc/caddy/Caddyfile
STAGED="$WORKDIR/Caddyfile.staged"
PREVIOUS="$WORKDIR/Caddyfile.previous"
TEMPLATE=/etc/caddy/Caddyfile.template
SERVICES="$WORKDIR/services.yaml"
CA_FILE="$WORKDIR/pve-ssl-ca.pem"

cd "$WORKDIR"

# Load secrets/settings without shell-sourcing: values may contain '$' (e.g.
# bcrypt hashes), which `source` would expand and corrupt.
get_env() { # get_env <file> <key>
  grep -oP "^$2=\K.*" "$1" 2>/dev/null | head -n1 || true
}
PVE_TOKEN_ID=$(get_env "$WORKDIR/pve-token.env" PVE_TOKEN_ID)
PVE_TOKEN_SECRET=$(get_env "$WORKDIR/pve-token.env" PVE_TOKEN_SECRET)
PVE_HOST=$(get_env "$WORKDIR/pve-token.env" PVE_HOST)
DOMAIN=$(get_env "$WORKDIR/proxy.env" DOMAIN)
EMAIL=$(get_env "$WORKDIR/proxy.env" EMAIL)
BASIC_AUTH_HASH=$(get_env "$WORKDIR/proxy.env" BASIC_AUTH_HASH)

# ── Guards: required inputs must exist before we do anything ──
for f in "$WORKDIR/pve-token.env" "$WORKDIR/proxy.env" "$TEMPLATE" "$SERVICES"; do
  [ -f "$f" ] || { echo "pve-proxy-sync: missing required file: $f" >&2; exit 1; }
done
[ -n "$PVE_HOST" ] || { echo "pve-proxy-sync: PVE_HOST is not set" >&2; exit 1; }
[ -n "$PVE_TOKEN_SECRET" ] || { echo "pve-proxy-sync: PVE token secret is not set" >&2; exit 1; }
[ -n "$DOMAIN" ] || { echo "pve-proxy-sync: DOMAIN is not set" >&2; exit 1; }
command -v caddy >/dev/null 2>&1 || { echo "pve-proxy-sync: caddy binary not found" >&2; exit 1; }

# ── Safety: never let secrets end up in git history ───────────
if [ ! -f "$WORKDIR/.gitignore" ]; then
  printf '*.env\n*.staged\n*.previous\nlive-containers.json\ncerts.json\npve-ssl-ca.pem\n*.log\n' > "$WORKDIR/.gitignore"
fi
if git ls-files 2>/dev/null | grep -Eq '(^|/)(cloudflare|pve-token|proxy)\.env$'; then
  echo "pve-proxy-sync: SECRET env files are tracked in git; aborting." >&2
  echo "  Remediation: remove them from history, e.g." >&2
  echo "    git -C /etc/pve-proxy rm --cached cloudflare.env pve-token.env proxy.env" >&2
  echo "    git -C /etc/pve-proxy filter-branch --index-filter 'git rm --cached --ignore-unmatch cloudflare.env pve-token.env proxy.env' -- --all" >&2
  systemd-cat -t pve-proxy -p err <<< "sync aborted: secret env files tracked in git history"
  exit 1
fi

# Snapshot current config for rollback
git add -A && git commit -m "pre-sync snapshot $(date -Iseconds)" --allow-empty -q 2>/dev/null || true

# Pull live container list from PVE (read-only PVEAuditor scope).
# Verify TLS against the PVE cluster CA (pushed at install time) instead of
# disabling verification with -k. Only falls back to -k if the CA is missing,
# and logs a prominent warning when it does.
CURL_OPTS=(-H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
if [ -f "$CA_FILE" ]; then
  CURL_OPTS+=(--cacert "$CA_FILE")
else
  echo "pve-proxy-sync: WARNING: PVE CA not found at $CA_FILE; using -k (TLS NOT verified)" >&2
  systemd-cat -t pve-proxy -p warning <<< "PVE CA missing at $CA_FILE; sync used insecure TLS"
  CURL_OPTS+=(-k)
fi
curl -s "${CURL_OPTS[@]}" \
  "https://${PVE_HOST}:8006/api2/json/cluster/resources?type=vm" \
  > live-containers.json
chmod 600 live-containers.json
# Guard: the API response must be valid JSON with a data array.
if ! /opt/pve-proxy/.venv/bin/python -c 'import json,sys; d=json.load(open("live-containers.json")); assert isinstance(d.get("data"), list)' 2>/dev/null; then
  echo "pve-proxy-sync: PVE API returned an invalid response; aborting" >&2
  systemd-cat -t pve-proxy -p err <<< "sync failed: invalid PVE API response at $(date -Iseconds)"
  exit 1
fi

# Render the Caddyfile from template + live data + services.yaml
/opt/pve-proxy/.venv/bin/python /usr/local/bin/render_caddyfile.py \
  --live live-containers.json \
  --services "$SERVICES" \
  --template "$TEMPLATE" \
  --domain "$DOMAIN" \
  --email "$EMAIL" \
  --basic-auth-hash "$BASIC_AUTH_HASH" \
  --out "$STAGED"

# Validate before touching live config
if ! caddy validate --config "$STAGED"; then
  echo "pve-proxy-sync: generated Caddyfile failed validation, aborting" >&2
  systemd-cat -t pve-proxy -p err <<< "sync failed: Caddyfile validation error at $(date -Iseconds)"
  exit 1
fi

# Replace live file (keep the previous good one for rollback) and reload
cp "$CADDYFILE" "$PREVIOUS" 2>/dev/null || true
cp "$STAGED" "$CADDYFILE"
if ! caddy reload --config "$CADDYFILE"; then
  echo "pve-proxy-sync: reload failed, rolling back" >&2
  systemd-cat -t pve-proxy -p err <<< "sync failed: caddy reload error at $(date -Iseconds)"
  if [ -f "$PREVIOUS" ]; then
    cp "$PREVIOUS" "$CADDYFILE"
    caddy reload --config "$CADDYFILE" || true
  fi
  exit 1
fi

git add -A && git commit -m "sync applied $(date -Iseconds)" -q 2>/dev/null || true

# ── Certificate expiry alerting (best-effort, never fails the sync) ──
# Reads managed certs from Caddy's localhost admin API and warns via
# systemd-cat when the wildcard cert is within 14 days of expiry.
if curl -sf http://localhost:2019/certificates > "$WORKDIR/certs.json" 2>/dev/null; then
  /opt/pve-proxy/.venv/bin/python - "$WORKDIR/certs.json" <<'PYEOF' || true
import json
import sys
from datetime import datetime, timezone

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

now = datetime.now(timezone.utc)
for cert in data.get("certificates", []):
    leaf = cert.get("certificate", {})
    not_after = leaf.get("not_after")
    if not not_after:
        continue
    try:
        exp = datetime.fromisoformat(not_after.replace("Z", "+00:00"))
    except Exception:
        continue
    days = (exp - now).total_seconds() / 86400
    if days < 14:
        print(f"certificate {leaf.get('subject', '?')} expires in {int(days)} days")
PYEOF
fi
