#!/usr/bin/env bash
# Run inside the pve-proxy CT to reconfigure secrets or services.
set -euo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; BL="\033[36m"; CL="\033[m"
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
function msg_info() { echo -ne " ${YW}⏳ ${1}...${CL}\n"; }
function msg_ok()   { echo -e  " ${CM} ${1}"; }

cat <<"EOF"
    ____  _    ________   ____
   / __ \| |  / / ____/  / __ \_________  _  ____  __
  / /_/ /| | / / __/    / /_/ / ___/ __ \| |/_/ / / /
 / ____/ | |/ / /___   / ____/ /  / /_/ />  </ /_/ /
/_/      |___/_____/  /_/   /_/   \____/_/|_|\__, /
  Configuration                             /____/
EOF

echo -e "\n${BL}What would you like to configure?${CL}"
echo "  1) Cloudflare API token"
echo "  2) PVE API token"
echo "  3) PVE host address"
echo "  4) Domain / ACME email"
echo "  5) Edit services.yaml"
echo "  6) Re-sync now"
echo "  7) Show status"
echo "  0) Exit"
echo ""
read -r -p "  Choice: " CHOICE

case "$CHOICE" in
  1)
    read -r -p "  New Cloudflare API Token: " CF_TOKEN
    [ -z "$CF_TOKEN" ] && { echo "Aborted."; exit 1; }
    cat > /etc/pve-proxy/cloudflare.env <<EOF2
CLOUDFLARE_API_TOKEN=${CF_TOKEN}
EOF2
    chown root:caddy /etc/pve-proxy/cloudflare.env
    chmod 640 /etc/pve-proxy/cloudflare.env
    msg_ok "Cloudflare token updated"
    systemctl restart caddy
    msg_ok "Caddy restarted"
    ;;
  2)
    read -r -p "  PVE Token ID: " TID
    read -r -p "  PVE Token Secret: " TSEC
    [ -z "$TID" ] || [ -z "$TSEC" ] && { echo "Aborted."; exit 1; }
    # Preserve PVE_HOST if it exists
    PVE_HOST=$(grep -oP 'PVE_HOST=\K.*' /etc/pve-proxy/pve-token.env 2>/dev/null || true)
    cat > /etc/pve-proxy/pve-token.env <<EOF3
PVE_TOKEN_ID=${TID}
PVE_TOKEN_SECRET=${TSEC}
PVE_HOST=${PVE_HOST}
EOF3
    chown root:caddy /etc/pve-proxy/pve-token.env
    chmod 640 /etc/pve-proxy/pve-token.env
    msg_ok "PVE token updated"
    ;;
  3)
    read -r -p "  PVE host IP/hostname: " NEW_HOST
    [ -z "$NEW_HOST" ] && { echo "Aborted."; exit 1; }
    sed -i "s|^PVE_HOST=.*|PVE_HOST=${NEW_HOST}|" /etc/pve-proxy/pve-token.env
    msg_ok "PVE host updated to ${NEW_HOST}"
    ;;
  4)
    DOMAIN=$(grep -oP 'DOMAIN=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    EMAIL=$(grep -oP 'EMAIL=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    read -r -p "  Wildcard base domain [${DOMAIN}]: " NEW_DOMAIN
    read -r -p "  ACME email [${EMAIL}]: " NEW_EMAIL
    cat > /etc/pve-proxy/proxy.env <<EOF4
DOMAIN=${NEW_DOMAIN:-$DOMAIN}
EMAIL=${NEW_EMAIL:-$EMAIL}
EOF4
    chown root:caddy /etc/pve-proxy/proxy.env
    chmod 640 /etc/pve-proxy/proxy.env
    msg_ok "Domain/email updated"
    read -r -p "  Run sync now? [Y/n]: " SYNC
    if [[ "${SYNC,,}" != "n" ]]; then
      /usr/local/bin/pve-proxy-sync.sh
      msg_ok "Sync complete"
    fi
    ;;
  5)
    ${EDITOR:-nano} /etc/pve-proxy/services.yaml
    msg_ok "Services file saved"
    read -r -p "  Run sync now? [Y/n]: " SYNC
    if [[ "${SYNC,,}" != "n" ]]; then
      /usr/local/bin/pve-proxy-sync.sh
      msg_ok "Sync complete"
    fi
    ;;
  6)
    /usr/local/bin/pve-proxy-sync.sh
    msg_ok "Sync complete"
    ;;
  7)
    echo ""
    echo -e "${BL}Caddy status:${CL}"
    systemctl status caddy --no-pager -l 2>/dev/null || echo "  Not running"
    echo ""
    echo -e "${BL}Tailscale status:${CL}"
    tailscale status 2>/dev/null || echo "  Not connected"
    echo ""
    echo -e "${BL}Last sync log:${CL}"
    tail -5 /var/log/pve-proxy-sync.log 2>/dev/null || echo "  No logs yet"
    echo ""
    echo -e "${BL}Active services:${CL}"
    cat /etc/pve-proxy/services.yaml 2>/dev/null || echo "  No services configured"
    ;;
  0)
    echo "Bye."
    ;;
  *)
    echo "Invalid choice."
    exit 1
    ;;
esac
