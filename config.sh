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

# Write an env file atomically without ever interpreting its values as shell.
# Values (which may contain '$' for bcrypt hashes) are written with printf %s.
write_env() { # write_env <file> <owner:group> <mode> <lines...>
  local file="$1" owner="$2" mode="$3"; shift 3
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$@" > "$tmp"
  chown "$owner" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
  rm -f "$tmp"
}

echo -e "\n${BL}What would you like to configure?${CL}"
echo "  1) Cloudflare API token"
echo "  2) PVE API token"
echo "  3) PVE host address"
echo "  4) Domain / ACME email"
echo "  5) Edit services.yaml"
echo "  6) Re-sync now"
echo "  7) Show status"
echo "  8) Basic auth hash (for services with auth: basic)"
echo "  9) Create/update Cloudflare DNS record (wildcard A -> tailscale IP)"
echo "  0) Exit"
echo ""
read -r -p "  Choice: " CHOICE

case "$CHOICE" in
  1)
    read -r -s -p "  New Cloudflare API Token: " CF_TOKEN || true
    echo
    [ -z "$CF_TOKEN" ] && { echo "Aborted."; exit 1; }
    write_env /etc/pve-proxy/cloudflare.env root:caddy 640 "CLOUDFLARE_API_TOKEN=${CF_TOKEN}"
    msg_ok "Cloudflare token updated"
    systemctl restart caddy
    msg_ok "Caddy restarted"
    ;;
  2)
    read -r -p "  PVE Token ID: " TID
    read -r -s -p "  PVE Token Secret: " TSEC || true
    echo
    [ -z "$TID" ] || [ -z "$TSEC" ] && { echo "Aborted."; exit 1; }
    # Preserve PVE_HOST if it exists
    PVE_HOST=$(grep -oP 'PVE_HOST=\K.*' /etc/pve-proxy/pve-token.env 2>/dev/null || true)
    write_env /etc/pve-proxy/pve-token.env root:root 600 \
      "PVE_TOKEN_ID=${TID}" "PVE_TOKEN_SECRET=${TSEC}" "PVE_HOST=${PVE_HOST}"
    msg_ok "PVE token updated"
    ;;
  3)
    read -r -p "  PVE host IP/hostname: " NEW_HOST
    [ -z "$NEW_HOST" ] && { echo "Aborted."; exit 1; }
    TID=$(grep -oP 'PVE_TOKEN_ID=\K.*' /etc/pve-proxy/pve-token.env 2>/dev/null || true)
    TSEC=$(grep -oP 'PVE_TOKEN_SECRET=\K.*' /etc/pve-proxy/pve-token.env 2>/dev/null || true)
    write_env /etc/pve-proxy/pve-token.env root:root 600 \
      "PVE_TOKEN_ID=${TID}" "PVE_TOKEN_SECRET=${TSEC}" "PVE_HOST=${NEW_HOST}"
    msg_ok "PVE host updated to ${NEW_HOST}"
    ;;
  4)
    DOMAIN=$(grep -oP 'DOMAIN=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    EMAIL=$(grep -oP 'EMAIL=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    BAH=$(grep -oP 'BASIC_AUTH_HASH=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    read -r -p "  Wildcard base domain [${DOMAIN}]: " NEW_DOMAIN
    read -r -p "  ACME email [${EMAIL}]: " NEW_EMAIL
    write_env /etc/pve-proxy/proxy.env root:caddy 640 \
      "DOMAIN=${NEW_DOMAIN:-$DOMAIN}" "EMAIL=${NEW_EMAIL:-$EMAIL}" "BASIC_AUTH_HASH=${BAH}"
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
    echo ""
    echo -e "${BL}Basic auth:${CL}"
    if grep -q '^BASIC_AUTH_HASH=.' /etc/pve-proxy/proxy.env 2>/dev/null; then
      echo "  configured"
    else
      echo "  not set (services with auth: basic will render WITHOUT auth)"
    fi
    ;;
  8)
    echo -e "${YW}Generate a hash with: caddy hash-password${CL}"
    read -r -s -p "  New basic auth hash (Enter to clear): " NEW_HASH || true
    echo
    DOMAIN=$(grep -oP 'DOMAIN=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    EMAIL=$(grep -oP 'EMAIL=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    write_env /etc/pve-proxy/proxy.env root:caddy 640 \
      "DOMAIN=${DOMAIN}" "EMAIL=${EMAIL}" "BASIC_AUTH_HASH=${NEW_HASH}"
    msg_ok "Basic auth hash updated"
    read -r -p "  Run sync now? [Y/n]: " SYNC
    if [[ "${SYNC,,}" != "n" ]]; then
      /usr/local/bin/pve-proxy-sync.sh
      msg_ok "Sync complete"
    fi
    ;;
  9)
    DOMAIN=$(grep -oP 'DOMAIN=\K.*' /etc/pve-proxy/proxy.env 2>/dev/null || true)
    TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '\r' || true)
    if [ -z "$TS_IP" ]; then
      echo "  tailscale IP not available - is the node joined to the tailnet?"
      echo "  Run: tailscale up --hostname=\$(hostname) --advertise-tags=tag:pve-proxy"
      exit 1
    fi
    /usr/local/bin/pve-proxy-dns.sh "$DOMAIN" "$TS_IP"
    msg_ok "DNS record set: *.$DOMAIN -> $TS_IP"
    ;;
  0)
    echo "Bye."
    ;;
  *)
    echo "Invalid choice."
    exit 1
    ;;
esac
