#!/usr/bin/env bash

# Copyright (c) 2026 SalahXG
# License: MIT
# https://github.com/vinodnal/pve-proxy

set -euo pipefail

# ── Colors & helpers ──────────────────────────────────────────
YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
BL="\033[36m"
CL="\033[m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

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

function msg_info() { echo -ne " ${YW}⏳ ${1}...${CL}\n"; }
function msg_ok()   { echo -e  " ${CM} ${1}"; }
function msg_error(){ echo -e  " ${CROSS} ${1}"; exit 1; }

# ── Find next available CTID ──────────────────────────────────
function next_ctid() {
  local id
  id=$(pvesh get /cluster/nextid 2>/dev/null) || id=100
  echo "$id"
}

header_info

# ── Sanity checks ────────────────────────────────────────────
if ! command -v pct &>/dev/null; then
  msg_error "This script must be run on a Proxmox VE host"
fi

# ── Interactive configuration ─────────────────────────────────
DEFAULT_CTID=$(next_ctid)

echo -e "\n${BL}Configuration${CL}"
echo -e "─────────────────────────────────────────────"

read -r -p "  Container ID [$DEFAULT_CTID]: " CTID
CTID="${CTID:-$DEFAULT_CTID}"

if pct status "$CTID" &>/dev/null; then
  msg_error "CT $CTID already exists"
fi

read -r -p "  Hostname [pve-proxy]: " HN
HN="${HN:-pve-proxy}"

read -r -p "  Disk size in GB [4]: " DISK_SIZE
DISK_SIZE="${DISK_SIZE:-4}"

read -r -p "  CPU cores [1]: " CORE_COUNT
CORE_COUNT="${CORE_COUNT:-1}"

read -r -p "  RAM in MB [512]: " RAM_SIZE
RAM_SIZE="${RAM_SIZE:-512}"

read -r -p "  Bridge [vmbr0]: " BRG
BRG="${BRG:-vmbr0}"

read -r -p "  IP (dhcp or static CIDR) [dhcp]: " NET
NET="${NET:-dhcp}"

echo ""
echo -e "${BL}Secrets${CL} (stored directly in the container, never logged)"
echo -e "─────────────────────────────────────────────"

read -r -p "  Cloudflare API Token (Zone:DNS:Edit): " CF_TOKEN
if [ -z "$CF_TOKEN" ]; then
  msg_error "Cloudflare API token is required"
fi

read -r -p "  PVE API Token ID [pve-proxy@pam!sync]: " PVE_TOKEN_ID
PVE_TOKEN_ID="${PVE_TOKEN_ID:-pve-proxy@pam!sync}"

read -r -p "  PVE API Token Secret: " PVE_TOKEN_SECRET
if [ -z "$PVE_TOKEN_SECRET" ]; then
  msg_error "PVE API token secret is required"
fi

read -r -p "  PVE API Host (IP or hostname) [192.168.10.20]: " PVE_HOST
PVE_HOST="${PVE_HOST:-192.168.10.20}"

echo ""
echo -e "${BL}Summary${CL}"
echo -e "─────────────────────────────────────────────"
echo -e "  CT ID:     ${GN}${CTID}${CL}"
echo -e "  Hostname:  ${GN}${HN}${CL}"
echo -e "  Resources: ${GN}${CORE_COUNT} core(s), ${RAM_SIZE}MB RAM, ${DISK_SIZE}GB disk${CL}"
echo -e "  Network:   ${GN}${BRG} / ${NET}${CL}"
echo -e "  PVE Token: ${GN}${PVE_TOKEN_ID}${CL}"
echo -e "  PVE Host:  ${GN}${PVE_HOST}${CL}"
echo ""
read -r -p "  Proceed? [Y/n]: " CONFIRM
if [[ "${CONFIRM,,}" == "n" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Download template ────────────────────────────────────────
msg_info "Checking for Debian 12 template"
TEMPLATE=$(pveam available -section system | grep "debian-12-standard" | tail -1 | awk '{print $2}')
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
sleep 3
msg_ok "Started CT $CTID"

# ── Clone repo inside the container ───────────────────────────
msg_info "Cloning pve-proxy into CT $CTID"
pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -yqq git >/dev/null 2>&1"
pct exec "$CTID" -- git clone https://github.com/vinodnal/pve-proxy.git /root/pve-proxy
msg_ok "Repository cloned"

# ── Write secrets into the container ──────────────────────────
msg_info "Writing secrets"
pct exec "$CTID" -- mkdir -p /etc/pve-proxy
pct exec "$CTID" -- bash -c "cat > /etc/pve-proxy/cloudflare.env <<INNEREOF
CLOUDFLARE_API_TOKEN=${CF_TOKEN}
INNEREOF"
pct exec "$CTID" -- bash -c "cat > /etc/pve-proxy/pve-token.env <<INNEREOF
PVE_TOKEN_ID=${PVE_TOKEN_ID}
PVE_TOKEN_SECRET=${PVE_TOKEN_SECRET}
PVE_HOST=${PVE_HOST}
INNEREOF"
msg_ok "Secrets written"

# ── Run setup inside the container ────────────────────────────
msg_info "Running setup inside CT $CTID (this takes a few minutes)"
pct exec "$CTID" -- bash /root/pve-proxy/setup.sh
msg_ok "Setup complete"

# ── Lock down secrets ─────────────────────────────────────────
msg_info "Setting secret file permissions"
pct exec "$CTID" -- bash -c "chown root:caddy /etc/pve-proxy/*.env && chmod 640 /etc/pve-proxy/*.env"
msg_ok "Permissions set"

echo ""
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
echo -e "${GN} PVE-Proxy (CT ${CTID}) installed and configured${CL}"
echo -e "${GN}═══════════════════════════════════════════════════${CL}"
echo -e " Remaining steps:"
echo -e "  ${YW}1.${CL} Enter CT:  pct enter ${CTID}"
echo -e "  ${YW}2.${CL} Join tailnet:  tailscale up --hostname=pve-proxy --advertise-tags=tag:pve-proxy"
echo -e "  ${YW}3.${CL} Note IP:  tailscale ip -4"
echo -e "  ${YW}4.${CL} Run first sync:  /usr/local/bin/pve-proxy-sync.sh"
echo -e "  ${YW}5.${CL} Start Caddy:  systemctl start caddy"
echo -e "  ${YW}6.${CL} Add Cloudflare DNS: *.pve.lab.hmh2.salahxg.com → <tailscale IP> (DNS only)"
echo ""
