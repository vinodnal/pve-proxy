#!/usr/bin/env bash
set -Eeuo pipefail

# cron/systemd supply a minimal PATH; our binaries live under /usr/local/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Centralized logging/state/guardrails (graceful fallback if not yet deployed).
PP_COMPONENT="${PP_COMPONENT:-sync}"
if [ -f /usr/local/lib/pve-proxy/common.sh ]; then
  # shellcheck source=/usr/local/lib/pve-proxy/common.sh
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
  pp_require_cmd() { command -v "$1" >/dev/null 2>&1 || pp_die "required command not found: $1"; }
fi
pp_info "sync started (pid $$)"

# Pre-flight guard failures must never leave a stale ok:true in the status
# collector, so log the failure AND write a failure state before exiting.
guard_fail() {
  pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"guard\",\"error\":\"$*\"}"
  pp_die "$*"
}

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
# Advanced settings (config.sh -> Advanced). settings.env holds no secrets, but
# read it the same safe way for consistency.
EXTRA_TRUSTED_SUBNETS=$(get_env "$WORKDIR/settings.env" EXTRA_TRUSTED_SUBNETS)
ACME_CA=$(get_env "$WORKDIR/settings.env" ACME_CA)
PVE_SKIP_TLS_VERIFY=$(get_env "$WORKDIR/settings.env" PVE_SKIP_TLS_VERIFY)

# ── Guards: required inputs must exist before we do anything ──
for f in "$WORKDIR/pve-token.env" "$WORKDIR/proxy.env" "$TEMPLATE" "$SERVICES"; do
  if [ ! -f "$f" ]; then
    pp_err "missing required file: $f"
    pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"guard\",\"error\":\"missing $f\"}"
    exit 1
  fi
done
if [ -z "$PVE_HOST" ]; then
  guard_fail "PVE_HOST is not set in $WORKDIR/pve-token.env (run config.sh -> 3)"
fi
if [ -z "$PVE_TOKEN_SECRET" ]; then
  guard_fail "PVE token secret is not set in $WORKDIR/pve-token.env (run config.sh -> 2)"
fi
if [ -z "$DOMAIN" ]; then
  guard_fail "DOMAIN is not set in $WORKDIR/proxy.env (run config.sh -> 4)"
fi
if [ -z "$EMAIL" ]; then
  guard_fail "EMAIL is not set in $WORKDIR/proxy.env (config.sh -> 4)"
fi
pp_require_cmd caddy "Caddy binary (cloudflare build)"
if ! /usr/local/bin/caddy list-modules 2>/dev/null | grep -q cloudflare; then
  guard_fail "caddy binary is missing the cloudflare DNS module; reinstall with the cloudflare build"
fi

# Export the Cloudflare token so `caddy validate/reload` (which run as root, not
# as the caddy service user) can expand {env.CLOUDFLARE_API_TOKEN} in the config.
CLOUDFLARE_API_TOKEN=$(get_env "$WORKDIR/cloudflare.env" CLOUDFLARE_API_TOKEN)
export CLOUDFLARE_API_TOKEN
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  pp_warn "CLOUDFLARE_API_TOKEN is empty; wildcard (DNS-01) certs will not issue until set (config.sh -> 1)"
fi

# ── Safety: never let secrets end up in git history ───────────
if [ ! -f "$WORKDIR/.gitignore" ]; then
  printf '*.env\n*.staged\n*.previous\nlive-containers.json\ncerts.json\npve-ssl-ca.pem\n*.log\n' > "$WORKDIR/.gitignore"
fi
# Keep IP-discovery scratch files out of the config git repo (idempotent).
for pat in 'ifaces/' 'lxc.map' 'needed.list' 'live-ips.json'; do
  grep -qxF "$pat" "$WORKDIR/.gitignore" || printf '%s\n' "$pat" >> "$WORKDIR/.gitignore"
done
if git ls-files 2>/dev/null | grep -Eq '(^|/)(cloudflare|pve-token|proxy)\.env$'; then
  pp_err "SECRET env files are tracked in git history; aborting."
  pp_err "Remediation: remove them from history, e.g."
  pp_err "  git -C /etc/pve-proxy rm --cached cloudflare.env pve-token.env proxy.env"
  pp_err "  git -C /etc/pve-proxy filter-branch --index-filter 'git rm --cached --ignore-unmatch cloudflare.env pve-token.env proxy.env' -- --all"
  pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"guard\",\"error\":\"secret env tracked in git\"}"
  exit 1
fi

# Snapshot current config for rollback
git add -A && git commit -m "pre-sync snapshot $(date -Iseconds)" --allow-empty -q 2>/dev/null || true

# Pull live container list from PVE (read-only PVEAuditor scope).
# Verify TLS against the PVE cluster CA (pushed at install time) instead of
# disabling verification with -k. Only falls back to -k if the CA is missing,
# and logs a prominent warning when it does.
CURL_OPTS=(-H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
if [ "${PVE_SKIP_TLS_VERIFY:-0}" = "1" ]; then
  pp_warn "PVE TLS verification disabled by settings (PVE_SKIP_TLS_VERIFY=1); using -k"
  CURL_OPTS+=(-k)
elif [ -f "$CA_FILE" ]; then
  CURL_OPTS+=(--cacert "$CA_FILE")
else
  pp_warn "PVE CA not found at $CA_FILE; using -k (TLS NOT verified)"
  CURL_OPTS+=(-k)
fi
pp_info "Fetching live container list from https://${PVE_HOST}:8006"
if ! curl -sS --connect-timeout 10 --max-time 30 "${CURL_OPTS[@]}" \
     "https://${PVE_HOST}:8006/api2/json/cluster/resources?type=vm" \
     > live-containers.json; then
  pp_err "PVE API request failed (network/TLS). Check PVE_HOST (config.sh -> 3) and CA bundle."
  pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"api\",\"error\":\"curl failed\"}"
  exit 1
fi
chmod 600 live-containers.json
# Guard: the API response must be valid JSON with a data array.
if ! /opt/pve-proxy/.venv/bin/python -c 'import json,sys; d=json.load(open("live-containers.json")); assert isinstance(d.get("data"), list)' 2>/dev/null; then
  pp_err "PVE API returned an invalid/empty response; aborting"
  pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"api\",\"error\":\"invalid PVE API response\"}"
  exit 1
fi
pp_ok "PVE API response valid"

# ── IP discovery (PVE /interfaces) ──────────────────────────
# Resolve each service container's IP from its live network interfaces when
# services.yaml does not pin an explicit `ip:`. PVE's /interfaces endpoint
# reports real (DHCP or static) addresses even though /config only stores
# `ip=dhcp`. Result is written to live-ips.json for the renderer.
pp_info "Discovering container IPs from PVE /interfaces"
IFDIR="$WORKDIR/ifaces"
rm -rf "$IFDIR"; mkdir -p "$IFDIR"
# name -> node vmid for every running LXC (from cluster/resources already fetched)
/opt/pve-proxy/.venv/bin/python - "$IFDIR/lxc.map" <<'PY'
import sys
import json
with open("live-containers.json") as f:
    data = json.load(f).get("data", [])
with open(sys.argv[1], "w") as out:
    for it in data:
        if it.get("type") == "lxc" and it.get("status") == "running":
            out.write(f"{it.get('name')}\t{it.get('node')}\t{it.get('vmid')}\n")
PY
# service names in services.yaml that do NOT pin an explicit ip
/opt/pve-proxy/.venv/bin/python - "$IFDIR/needed.list" <<'PY'
import sys
import yaml
svc = yaml.safe_load(open("services.yaml")) or {}
with open(sys.argv[1], "w") as out:
    if isinstance(svc, dict):
        for name, conf in svc.items():
            if not (isinstance(conf, dict) and str(conf.get("ip", "")).strip()):
                out.write(f"{name}\n")
PY
# Fetch interfaces only for containers we actually need (running + in needed.list)
while IFS=$'\t' read -r name node vmid; do
  [ -n "$name" ] || continue
  grep -qx "$name" "$IFDIR/needed.list" || continue
  if ! curl -sS --connect-timeout 10 --max-time 20 "${CURL_OPTS[@]}" \
       "https://${PVE_HOST}:8006/api2/json/nodes/${node}/lxc/${vmid}/interfaces" \
       -o "$IFDIR/$name.json"; then
    pp_warn "could not read interfaces for container '$name' (${node}/${vmid})"
  fi
done < "$IFDIR/lxc.map"
# Extract each container's primary IPv4 and write the name -> IP map
/opt/pve-proxy/.venv/bin/python - "$WORKDIR/live-ips.json" <<'PY'
import os
import sys
import json
result = {}
for fname in os.listdir("ifaces"):
    if not fname.endswith(".json"):
        continue
    name = fname[:-5]
    try:
        with open(os.path.join("ifaces", fname)) as f:
            data = json.load(f).get("data", [])
    except Exception:
        continue
    ip = None
    for it in data:
        if str(it.get("name", "")).lower() == "lo":
            continue
        for addr in it.get("ip-addresses", []):
            if addr.get("ip-address-type") == "inet":
                ip = str(addr.get("ip-address", "")).split("/")[0]
                break
        if ip is None:
            raw = str(it.get("inet", "") or "")
            if raw:
                ip = raw.split("/")[0]
        if ip:
            break
    if ip:
        result[name] = ip
with open(sys.argv[1], "w") as out:
    json.dump(result, out, indent=0)
PY
chmod 600 "$WORKDIR/live-ips.json"

# Render the Caddyfile from template + live data + services.yaml
pp_info "Rendering Caddyfile from template + live data"
/opt/pve-proxy/.venv/bin/python /usr/local/bin/render_caddyfile.py \
  --live live-containers.json \
  --live-ips "$WORKDIR/live-ips.json" \
  --services "$SERVICES" \
  --template "$TEMPLATE" \
  --domain "$DOMAIN" \
  --email "$EMAIL" \
  --basic-auth-hash "$BASIC_AUTH_HASH" \
  ${EXTRA_TRUSTED_SUBNETS:+--extra-subnets "$EXTRA_TRUSTED_SUBNETS"} \
  ${ACME_CA:+--acme-ca "$ACME_CA"} \
  --out "$STAGED"

# Validate before touching live config
if ! caddy validate --config "$STAGED"; then
  pp_err "generated Caddyfile failed validation; live config untouched"
  pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"validate\",\"error\":\"caddy validate failed\"}"
  exit 1
fi
pp_ok "Caddyfile validation passed"

# ── Apply and (re)load, with rollback ────────────────────────
# Keep the previous good config so any reload/start failure can be undone.
cp "$CADDYFILE" "$PREVIOUS" 2>/dev/null || true
cp "$STAGED" "$CADDYFILE"
if systemctl is-active --quiet caddy; then
  if ! caddy reload --config "$CADDYFILE"; then
    pp_err "caddy reload failed; rolling back to previous config"
    [ -f "$PREVIOUS" ] && cp "$PREVIOUS" "$CADDYFILE"
    caddy reload --config "$CADDYFILE" 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"reload\",\"error\":\"caddy reload failed\"}"
    exit 1
  fi
  pp_ok "Caddy config applied and reloaded"
else
  pp_info "caddy not running; starting it with the new config"
  if ! systemctl start caddy; then
    pp_err "caddy failed to start with the new config; rolling back"
    [ -f "$PREVIOUS" ] && cp "$PREVIOUS" "$CADDYFILE"
    pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":false,\"stage\":\"start\",\"error\":\"systemctl start caddy failed\"}"
    exit 1
  fi
  pp_ok "Caddy started"
fi

git add -A && git commit -m "sync applied $(date -Iseconds)" -q 2>/dev/null || true

# ── Record result for the status collector ───────────────────
pp_write_state sync "{\"ts\":\"$(date -Is)\",\"ok\":true,\"stage\":\"done\",\"host\":\"${PVE_HOST}\",\"domain\":\"${DOMAIN}\",\"error\":\"\"}"
pp_ok "sync completed"

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
