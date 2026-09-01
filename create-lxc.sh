#!/usr/bin/env bash

# Copyright (c) 2026 SalahXG
# License: MIT
# https://github.com/vinodnal/pve-proxy
#
# Host-side entry point: creates and configures the pve-proxy LXC.
# Community-scripts architecture: sources build.func, prompts for all
# environment-specific values, then runs install/pve-proxy-install.sh
# inside the container.

source "$(dirname "$0")/build.func"

function header_info {
  clear
  cat <<"EOF"
    ____  _    ________   ____
   / __ \| |  / / ____/  / __ \_________  _  ____  __
  / /_/ /| | / / __/    / /_/ / ___/ __ \| |/_/ / / /
 / ____/ | |/ / /___   / ____/ /  / /_/ />  </ /_/ /
/_/      |___/_____/  /_/   /_/   \____/_/|_|\__, /
  Caddy reverse proxy for PVE containers   /____/
EOF
}

# ── Defaults (generic; everything can be overridden) ─────────
APP="PVE-Proxy"
# Canonical repo; override with PVE_PROXY_REPO to install from a fork/mirror.
REPO_URL="${PVE_PROXY_REPO:-https://github.com/vinodnal/pve-proxy}"
HN_DEFAULT="pve-proxy"
DISK_SIZE_DEFAULT="8"   # Go module cache + Caddy build need ~4 GB; runtime needs little
CORE_COUNT_DEFAULT="1"
RAM_SIZE_DEFAULT="2048"  # headroom for the one-time Go/Caddy build
BRG_DEFAULT="vmbr0"
NET_DEFAULT="dhcp"

header_info
pve_check
root_check

# ── Cloudflare / JSON helpers ────────────────────────────────
# json_get <expr> — reads JSON from stdin, prints the Python expression result.
# `expr` may reference `d` (parsed JSON); expressions are controlled, not user input.
json_get() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
print(eval(sys.argv[1], {"d": d}))' "$1" 2>/dev/null || true
}

# cf_api <method> <path> [data] — Cloudflare API call authenticated with the global key.
cf_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-s -X "$method" "https://api.cloudflare.com/client/v4$path" \
    -H "X-Auth-Email: $CF_GLOBAL_EMAIL" -H "X-Auth-Key: $CF_GLOBAL_KEY" \
    -H "Content-Type: application/json")
  if [ -n "$data" ]; then curl "${args[@]}" --data "$data"; else curl "${args[@]}"; fi
}

# cf_mint_token <email> <global-key> <domain> — creates a least-privilege
# Zone:Read + Zone:DNS:Edit token scoped to <domain>'s zone; echoes the token.
# The global key is used in-memory only and is NOT stored or logged.
cf_mint_token() {
  local email="$1" key="$2" domain="$3"
  local resp zone zone_read dns_edit zr dr body
  CF_GLOBAL_EMAIL="$email" CF_GLOBAL_KEY="$key"
  resp=$(cf_api GET "/zones?name=$domain")
  zone=$(printf '%s' "$resp" | json_get 'd["result"][0]["id"] if d.get("success") and d.get("result") else ""')
  if [ -z "$zone" ]; then CF_GLOBAL_KEY=""; return 1; fi
  resp=$(cf_api GET "/user/tokens/permission_groups")
  zone_read=$(printf '%s' "$resp" | json_get '" ".join(g["id"] for g in d.get("result") or [] if g.get("name")=="Zone Read")')
  dns_edit=$(printf '%s' "$resp" | json_get '" ".join(g["id"] for g in d.get("result") or [] if g.get("name")=="Zone DNS Edit")')
  zr=$(printf '%s' "$zone_read" | awk '{print $1}')
  dr=$(printf '%s' "$dns_edit" | awk '{print $1}')
  if [ -z "$zr" ] || [ -z "$dr" ]; then CF_GLOBAL_KEY=""; return 1; fi
  body=$(python3 - "$zone" "$zr" "$dr" "$domain" <<'PYEOF'
import json, sys
zone, zr, dr, domain = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({"name": f"pve-proxy-{domain}", "policies": [{
    "effect": "allow",
    "resources": {f"com.cloudflare.api.account.zone.{zone}": "*"},
    "permission_groups": [{"id": zr}, {"id": dr}]
}]}))
PYEOF
)
  resp=$(cf_api POST "/user/tokens" "$body")
  CF_GLOBAL_KEY=""
  printf '%s' "$resp" | json_get '(d.get("result") or {}).get("value","") if d.get("success") else ""'
}

# ── Container settings ───────────────────────────────────────
DEFAULT_CTID=$(next_ctid)

echo -e "\n${BL}Container${CL}"
echo -e "─────────────────────────────────────────────"

CTID=$(prompt_with_default "Container ID" "$DEFAULT_CTID")
if ctid_in_use "$CTID"; then
  msg_error "CT $CTID already exists"
fi

HN=$(prompt_with_default "Hostname" "$HN_DEFAULT")
DISK_SIZE=$(prompt_with_default "Disk size in GB" "$DISK_SIZE_DEFAULT")
CORE_COUNT=$(prompt_with_default "CPU cores" "$CORE_COUNT_DEFAULT")
RAM_SIZE=$(prompt_with_default "RAM in MB" "$RAM_SIZE_DEFAULT")
BRG=$(prompt_with_default "Bridge" "$BRG_DEFAULT")
NET=$(prompt_with_default "IPv4 (dhcp or CIDR)" "$NET_DEFAULT")

# ── Proxy configuration (no hardcoded domain/IP) ─────────────
echo ""
echo -e "${BL}Proxy${CL}"
echo -e "─────────────────────────────────────────────"
DOMAIN=$(prompt_with_default "Wildcard base domain" "pve.example.com")
EMAIL=$(prompt_with_default "ACME email" "admin@example.com")

# ── Cloudflare authentication ────────────────────────────────
echo ""
echo -e "${BL}Cloudflare${CL}"
echo -e "─────────────────────────────────────────────"
echo "  How do you want to authenticate to Cloudflare?"
echo "  1) Provide an API token (Zone:Read + Zone:DNS:Edit)   [recommended]"
echo "  2) Auto-create a scoped token from a Global API Key"
echo ""
read -r -p "  Choice [1/2]: " CF_MODE </dev/tty
if [[ "${CF_MODE:-1}" == "2" ]]; then
  CF_GLOBAL_EMAIL=$(prompt_with_default "Cloudflare account email" "")
  CF_GLOBAL_KEY=$(prompt_secret "Cloudflare Global API Key")
  if [ -z "$CF_GLOBAL_EMAIL" ] || [ -z "$CF_GLOBAL_KEY" ]; then
    msg_error "Global API Key + email are required for auto token creation"
  fi
  msg_info "Creating scoped Cloudflare token (global key is NOT stored)"
  CF_TOKEN=$(cf_mint_token "$CF_GLOBAL_EMAIL" "$CF_GLOBAL_KEY" "$DOMAIN")
  CF_GLOBAL_KEY=""
  if [ -z "$CF_TOKEN" ]; then
    msg_warn "Could not auto-create a Cloudflare token; falling back to manual entry"
    CF_TOKEN=$(prompt_secret "Cloudflare API Token (Zone:Read + Zone:DNS:Edit)")
  fi
else
  CF_TOKEN=$(prompt_secret "Cloudflare API Token (Zone:Read + Zone:DNS:Edit)")
fi
if [ -z "$CF_TOKEN" ]; then
  msg_error "Cloudflare API token is required"
fi

# ── PVE access (auto-created; we run as root on this host) ───
echo ""
echo -e "${BL}PVE access${CL} (auto-created, no key needed)"
echo -e "─────────────────────────────────────────────"
msg_info "Creating PVE auditor user/token (auto)"
pveum user add pve-proxy@pam >/dev/null 2>&1 || true
pveum aclmod / -user pve-proxy@pam -role PVEAuditor >/dev/null 2>&1 || true
# Rotate the token so the secret is always fresh and captured here.
pveum user token delete pve-proxy@pam sync >/dev/null 2>&1 || true
PVE_TOKEN_JSON=$(pveum user token add pve-proxy@pam sync --privsep 0 --output-format json 2>/dev/null)
PVE_TOKEN_ID="pve-proxy@pam!sync"
# PVE returns the one-time secret under the "value" field. Fall back to "secret"
# or a plain grep if the shape ever changes on another PVE version.
PVE_TOKEN_SECRET=$(printf '%s' "$PVE_TOKEN_JSON" \
  | json_get '(d.get("value") or d.get("secret") or "") if isinstance(d, dict) else ((d[0].get("value") or d[0].get("secret") or "") if d else "")')
if [ -z "$PVE_TOKEN_SECRET" ]; then
  PVE_TOKEN_SECRET=$(printf '%s' "$PVE_TOKEN_JSON" \
    | sed -n 's/.*"\(value\|secret\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' | head -n1)
fi
if [ -z "$PVE_TOKEN_SECRET" ]; then
  msg_error "Failed to create/parse the PVE API token. pveum output: $(printf '%s' "$PVE_TOKEN_JSON" | head -c 300)"
fi
msg_ok "PVE token auto-created: $PVE_TOKEN_ID"

# Auto-detect the API host (this node's primary IP) as a sensible default.
PVE_HOST_DEFAULT=$(hostname -I 2>/dev/null | awk '{print $1}')
PVE_HOST=$(prompt_with_default "PVE API host (IP or hostname)" "${PVE_HOST_DEFAULT:-}")

# ── Tailscale (optional pre-auth key => fully automatic setup) ─
echo ""
echo -e "${BL}Tailscale${CL} (optional)"
echo -e "─────────────────────────────────────────────"
echo "  Provide a pre-auth key (tagged tag:pve-proxy) to join the tailnet and"
echo "  finish setup fully automatically. Leave empty to join manually later."
read -r -s -p "  Tailscale pre-auth key (optional): " TS_AUTHKEY </dev/tty || true
echo

# Optional: bcrypt hash for services marked `auth: basic` in services.yaml.
# Generate with `caddy hash-password` (or after install: config.sh -> 8).
read -r -s -p "  Basic auth hash (optional, Enter to skip; see docs): " BASIC_AUTH_HASH </dev/tty || true
echo

# ── Summary & confirmation ───────────────────────────────────
echo ""
echo -e "${BL}Summary${CL}"
echo -e "─────────────────────────────────────────────"
echo -e "  CT ID:     ${GN}${CTID}${CL}"
echo -e "  Hostname:  ${GN}${HN}${CL}"
echo -e "  Resources: ${GN}${CORE_COUNT} core(s), ${RAM_SIZE}MB RAM, ${DISK_SIZE}GB disk${CL}"
echo -e "  Network:   ${GN}${BRG} / ${NET}${CL}"
echo -e "  Domain:    ${GN}*.${DOMAIN}${CL}"
echo -e "  Email:     ${GN}${EMAIL}${CL}"
echo -e "  PVE Token: ${GN}auto-created (${PVE_TOKEN_ID})${CL}"
echo -e "  PVE Host:  ${GN}${PVE_HOST:-<unset>}${CL}"
echo -e "  Tailscale: ${GN}$([ -n "$TS_AUTHKEY" ] && echo "auto-join (key provided)" || echo "manual join")${CL}"
echo -e "  Basic Auth:${GN}$([ -n "$BASIC_AUTH_HASH" ] && echo " configured" || echo " not set")${CL}"
echo ""
read -r -p "  Proceed? [Y/n]: " CONFIRM </dev/tty
if [[ "${CONFIRM,,}" == "n" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Download template ────────────────────────────────────────
msg_info "Checking for Debian template"
TEMPLATE=$(pveam available -section system | grep -E "debian-12-standard" | tail -1 | awk '{print $2}')
if [ -z "$TEMPLATE" ]; then
  msg_error "No Debian 12 template available"
fi
pveam download local "$TEMPLATE" >/dev/null 2>&1 || true
msg_ok "Template ready: $TEMPLATE"

# ── Create container ─────────────────────────────────────────
msg_info "Creating LXC container (CT $CTID)"
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  --hostname "$HN" \
  --cores "$CORE_COUNT" \
  --memory "$RAM_SIZE" \
  --swap 0 \
  --rootfs "local-lvm:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRG},ip=${NET}" \
  --unprivileged 1 \
  --features nesting=1 \
  --tags "proxy" \
  --onboot 1 \
  >/dev/null
# Guard: confirm the container actually exists.
pct config "$CTID" >/dev/null 2>&1 || msg_error "CT $CTID was not created"
msg_ok "Created CT $CTID"

msg_info "Starting CT $CTID"
pct start "$CTID"
# Guard: wait for the container to report running.
for _ in $(seq 1 20); do
  [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" = "running" ] && break
  sleep 1
done
pct status "$CTID" | grep -q running || msg_error "CT $CTID did not reach 'running' state"
setting_up_container
network_check
update_os

# ── Push repo files into the container ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Push repo files into the container (single tar stream) ───
# Per-file `pct exec mkdir` + `pct push` was flaky (transient pct exec failures
# could drop a file and abort). Streaming one tarball over pct exec stdin is one
# atomic operation and much faster. pct exec forwards stdin on PVE.
msg_info "Pushing project files into CT $CTID (tar stream)"
command -v tar >/dev/null 2>&1 || msg_error "tar not found on host"
pct exec "$CTID" -- mkdir -p /root/pve-proxy || msg_error "cannot create /root/pve-proxy in CT"
if ! tar -C "$SCRIPT_DIR" -cf - \
       --exclude='./.git' --exclude='./.git/*' \
       --exclude='./.omo' --exclude='./.omo/*' \
       --exclude='./.codegraph' --exclude='./.codegraph/*' \
       --exclude='./create-lxc.sh' \
       . \
     | pct exec "$CTID" -- tar -C /root/pve-proxy -xf -; then
  msg_error "Failed to stream project files into CT $CTID"
fi
# Guard: confirm the key files actually landed.
pct exec "$CTID" -- bash -c 'test -f /root/pve-proxy/install/pve-proxy-install.sh &&
  test -f /root/pve-proxy/usr/local/bin/render_caddyfile.py &&
  test -f /root/pve-proxy/etc/caddy/Caddyfile.template' \
  || msg_error "Project files incomplete in CT after push"
msg_ok "Project files pushed"

# Guard: all required secrets must be non-empty before we write config.
[ -n "$CF_TOKEN" ] || msg_error "Cloudflare token is empty"
[ -n "$PVE_TOKEN_SECRET" ] || msg_error "PVE token secret is empty"

# ── Write configuration into the container (injection-safe) ───
# Values are written with printf to a temp file and pushed with pct push so no
# secret can ever be interpreted as shell/heredoc syntax inside the container.
msg_info "Writing configuration"
pct exec "$CTID" -- mkdir -p /etc/pve-proxy
TMPCF=$(mktemp)
trap 'rm -f "$TMPCF"' EXIT

printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CF_TOKEN" > "$TMPCF"
pct push "$CTID" "$TMPCF" /etc/pve-proxy/cloudflare.env

printf 'PVE_TOKEN_ID=%s\nPVE_TOKEN_SECRET=%s\nPVE_HOST=%s\n' \
  "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET" "$PVE_HOST" > "$TMPCF"
pct push "$CTID" "$TMPCF" /etc/pve-proxy/pve-token.env

printf 'DOMAIN=%s\nEMAIL=%s\nBASIC_AUTH_HASH=%s\n' \
  "$DOMAIN" "$EMAIL" "$BASIC_AUTH_HASH" > "$TMPCF"
pct push "$CTID" "$TMPCF" /etc/pve-proxy/proxy.env
msg_ok "Configuration written"

# ── Push PVE cluster CA so sync verifies API TLS (no -k) ──────
# Path differs across PVE versions; try the common locations.
msg_info "Pushing PVE cluster CA"
PVE_CA=""
for c in /etc/pve/pve-root-ca.pem /etc/pve/local/pve-ssl-ca.pem; do
  [ -f "$c" ] && PVE_CA="$c" && break
done
if [ -n "$PVE_CA" ]; then
  pct push "$CTID" "$PVE_CA" /etc/pve-proxy/pve-ssl-ca.pem
  msg_ok "PVE CA pushed ($PVE_CA)"
else
  msg_warn "PVE CA not found on host; sync will fall back to insecure TLS (-k)"
fi

# ── Run installer inside the container ────────────────────────
msg_info "Running installer inside CT $CTID (this takes a few minutes)"
pct exec "$CTID" -- bash /root/pve-proxy/install/pve-proxy-install.sh /root/pve-proxy "$REPO_URL" \
  || msg_error "Container installer failed (see output above)"
# Guard: the installer must have built caddy and deployed the files.
pct exec "$CTID" -- test -x /usr/local/bin/caddy \
  || msg_error "Caddy binary missing after install"
pct exec "$CTID" -- test -f /etc/pve-proxy/services.yaml \
  || msg_error "Project files not deployed after install"
msg_ok "Installer complete"

# ── Lock down secrets ─────────────────────────────────────────
# Least privilege: only caddy needs cloudflare.env (DNS-01 at runtime) and
# proxy.env (basic-auth hash is baked into the Caddyfile at render time).
# pve-token.env is used only by the root cron sync, so it is root-only.
msg_info "Setting secret file permissions"
pct exec "$CTID" -- bash -c "chown root:root /etc/pve-proxy/pve-token.env && chmod 600 /etc/pve-proxy/pve-token.env"
pct exec "$CTID" -- bash -c "chown root:caddy /etc/pve-proxy/cloudflare.env /etc/pve-proxy/proxy.env && chmod 640 /etc/pve-proxy/cloudflare.env /etc/pve-proxy/proxy.env"
msg_ok "Permissions set"

# ── Optional: join tailnet automatically (if a pre-auth key was given) ──
TS_IP=""
if [ -n "${TS_AUTHKEY:-}" ]; then
  msg_info "Joining tailnet automatically"
  TMPTS=$(mktemp)
  printf '#!/usr/bin/env bash\nset -euo pipefail\numask 077\ntailscale up --authkey="%s" --hostname="%s" --advertise-tags=tag:pve-proxy\n' \
    "$TS_AUTHKEY" "$HN" > "$TMPTS"
  pct push "$CTID" "$TMPTS" /tmp/pve-proxy-join.sh
  pct exec "$CTID" -- bash /tmp/pve-proxy-join.sh \
    || msg_warn "tailscale up failed; join manually later"
  pct exec "$CTID" -- rm -f /tmp/pve-proxy-join.sh
  rm -f "$TMPTS"
  for _ in $(seq 1 15); do
    TS_IP=$(pct exec "$CTID" -- tailscale ip -4 2>/dev/null | tr -d '\r' | head -n1)
    [ -n "$TS_IP" ] && break
    sleep 2
  done
  if [ -n "$TS_IP" ]; then
    msg_ok "Tailnet joined; node IP = $TS_IP"
  else
    msg_warn "Could not read the tailscale IP yet; DNS record not auto-created"
  fi
fi

# ── Create the Cloudflare wildcard DNS record (if we have an IP) ──
if [ -n "${TS_IP:-}" ]; then
  msg_info "Creating Cloudflare DNS record *.${DOMAIN} -> ${TS_IP} (DNS only)"
  pct exec "$CTID" -- /usr/local/bin/pve-proxy-dns.sh "$DOMAIN" "$TS_IP" \
    || msg_warn "DNS auto-setup failed; use config.sh -> 9 later"
fi

# ── First sync + start Caddy ─────────────────────────────────
msg_info "Running first sync"
pct exec "$CTID" -- /usr/local/bin/pve-proxy-sync.sh \
  || msg_warn "first sync failed; run '/usr/local/bin/pve-proxy-sync.sh' manually"
msg_info "Starting Caddy"
pct exec "$CTID" -- systemctl start caddy 2>/dev/null || true

echo ""
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
echo -e "${GN} PVE-Proxy (CT ${CTID}) installed and configured${CL}"
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
if [ -n "${TS_IP:-}" ]; then
  echo -e " ${GN}Fully automated:${CL} tailnet joined, DNS record created,"
  echo -e " first sync done, Caddy started. Cert issues on first start."
  echo -e "  Node IP:  ${GN}${TS_IP}${CL}"
else
  echo -e " Remaining steps (inside the CT):"
  echo -e "  ${YW}1.${CL} pct enter ${CTID}"
  echo -e "  ${YW}2.${CL} tailscale up --hostname=${HN} --advertise-tags=tag:pve-proxy"
  echo -e "  ${YW}3.${CL} tailscale ip -4   (note the IP)"
  echo -e "  ${YW}4.${CL} config.sh -> 9   (create the Cloudflare DNS record)"
  echo -e "  (first sync + Caddy already ran)"
fi
echo ""
