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
HN_DEFAULT="pve-proxy"
DISK_SIZE_DEFAULT="4"
CORE_COUNT_DEFAULT="1"
RAM_SIZE_DEFAULT="512"
BRG_DEFAULT="vmbr0"
NET_DEFAULT="dhcp"

header_info
pve_check
root_check

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

# ── Secrets (stored directly in the CT, never logged) ────────
echo ""
echo -e "${BL}Secrets${CL} (stored directly in the container, never logged)"
echo -e "─────────────────────────────────────────────"

CF_TOKEN=$(prompt_secret "Cloudflare API Token (Zone:DNS:Edit)")
if [ -z "$CF_TOKEN" ]; then
  msg_error "Cloudflare API token is required"
fi

PVE_TOKEN_ID=$(prompt_with_default "PVE API Token ID" "pve-proxy@pam!sync")
PVE_TOKEN_SECRET=$(prompt_secret "PVE API Token Secret")
if [ -z "$PVE_TOKEN_SECRET" ]; then
  msg_error "PVE API token secret is required"
fi

PVE_HOST=$(prompt_with_default "PVE API host (IP or hostname)" "")

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
echo -e "  PVE Token: ${GN}${PVE_TOKEN_ID}${CL}"
echo -e "  PVE Host:  ${GN}${PVE_HOST:-<unset>}${CL}"
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
msg_ok "Created CT $CTID"

msg_info "Starting CT $CTID"
pct start "$CTID"
setting_up_container
network_check
update_os

# ── Push repo files into the container ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

msg_info "Pushing project files into CT $CTID"
pct exec "$CTID" -- mkdir -p /root/pve-proxy
while IFS= read -r -d '' f; do
  REL="${f#$SCRIPT_DIR/}"
  DIR=$(dirname "/root/pve-proxy/$REL")
  pct exec "$CTID" -- mkdir -p "$DIR"
  pct push "$CTID" "$f" "/root/pve-proxy/$REL"
done < <(find "$SCRIPT_DIR" -type f -not -path "*/.git/*" -not -path "*/.omo/*" -not -path "*/.codegraph/*" ! -name "create-lxc.sh" -print0)
msg_ok "Files pushed"

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
msg_info "Pushing PVE cluster CA"
if [ -f /etc/pve/local/pve-ssl-ca.pem ]; then
  pct push "$CTID" /etc/pve/local/pve-ssl-ca.pem /etc/pve-proxy/pve-ssl-ca.pem
  msg_ok "PVE CA pushed"
else
  msg_warn "PVE CA not found on host; sync will fall back to insecure TLS (-k)"
fi

# ── Run installer inside the container ────────────────────────
msg_info "Running installer inside CT $CTID (this takes a few minutes)"
pct exec "$CTID" -- bash /root/pve-proxy/install/pve-proxy-install.sh /root/pve-proxy
msg_ok "Installer complete"

# ── Lock down secrets ─────────────────────────────────────────
# Least privilege: only caddy needs cloudflare.env (DNS-01 at runtime) and
# proxy.env (basic-auth hash is baked into the Caddyfile at render time).
# pve-token.env is used only by the root cron sync, so it is root-only.
msg_info "Setting secret file permissions"
pct exec "$CTID" -- bash -c "chown root:root /etc/pve-proxy/pve-token.env && chmod 600 /etc/pve-proxy/pve-token.env"
pct exec "$CTID" -- bash -c "chown root:caddy /etc/pve-proxy/cloudflare.env /etc/pve-proxy/proxy.env && chmod 640 /etc/pve-proxy/cloudflare.env /etc/pve-proxy/proxy.env"
msg_ok "Permissions set"

echo ""
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
echo -e "${GN} PVE-Proxy (CT ${CTID}) installed and configured${CL}"
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
echo -e " Remaining steps:"
echo -e "  ${YW}1.${CL} Enter CT:  pct enter ${CTID}"
echo -e "  ${YW}2.${CL} Join tailnet:  tailscale up --hostname=${HN} --advertise-tags=tag:pve-proxy"
echo -e "  ${YW}3.${CL} Note IP:  tailscale ip -4"
echo -e "  ${YW}4.${CL} Run first sync:  /usr/local/bin/pve-proxy-sync.sh"
echo -e "  ${YW}5.${CL} Start Caddy:  systemctl start caddy"
echo -e "  ${YW}6.${CL} Add Cloudflare DNS: *.${DOMAIN} → <tailscale IP> (DNS only)"
echo ""
