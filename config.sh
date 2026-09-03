#!/usr/bin/env bash
# Run inside the pve-proxy CT to reconfigure secrets or services.
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Centralized logging/state (graceful fallback if lib not yet deployed).
PP_COMPONENT=config
if [ -f /usr/local/lib/pve-proxy/common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/pve-proxy/common.sh
  pp_init
fi

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

function msg_warn() { echo -e " ${YW}⚠ ${1}${CL}"; }
function msg_error(){ echo -e " ${CROSS} ${1}"; exit 1; }

# ── Advanced settings (/etc/pve-proxy/settings.env) ──────────
get_setting() { grep -oP "^${1}=\K.*" /etc/pve-proxy/settings.env 2>/dev/null | head -n1 || true; }

write_settings() { # write_settings KEY=VALUE ...  (merges with existing file)
  local f=/etc/pve-proxy/settings.env pair k v tmp
  local -A s=()
  [ -f "$f" ] && while IFS='=' read -r k v; do [ -n "$k" ] && s["$k"]="$v"; done < "$f"
  for pair in "$@"; do k="${pair%%=*}"; v="${pair#*=}"; s["$k"]="$v"; done
  tmp=$(mktemp)
  for k in "${!s[@]}"; do printf '%s=%s\n' "$k" "${s[$k]}"; done > "$tmp"
  chmod 0644 "$tmp"; mv -f "$tmp" "$f"
}

confirm_yes() { local a; read -r -p "  $1 [y/N]: " a; [[ "${a,,}" == "y" ]]; }

apply_cron() { # rewrite /etc/cron.d/pve-proxy-sync from SYNC_CRON
  local expr; expr=$(get_setting SYNC_CRON); [ -n "$expr" ] || expr="*/15"
  cat > /etc/cron.d/pve-proxy-sync <<EOF
# pve-proxy sync schedule (managed by config.sh -> Advanced). PP_QUIET=1 keeps
# cron output empty: logging goes to the central log and journald.
$expr * * * * root PP_QUIET=1 /usr/local/bin/pve-proxy-sync.sh >> /var/log/pve-proxy/pve-proxy.log 2>&1
EOF
  chmod 0644 /etc/cron.d/pve-proxy-sync
}

# ── Tailscale ────────────────────────────────────────────────
menu_tailscale() {
  echo ""
  echo -e "${BL}Tailscale${CL}"
  echo "  1) Status / IP"
  echo "  2) Join / authenticate tailnet"
  echo "  3) Set node name & tags (re-run up)"
  echo "  4) Route via an exit node"
  echo "  5) Leave tailnet (down)"
  echo "  0) Back"
  read -r -p "  Choice: " TCH
  case "$TCH" in
    1)
      echo ""
      tailscale status 2>&1 || true
      echo "  IPv4: $(tailscale ip -4 2>/dev/null | head -n1 | tr -d '\r' || echo none)"
      ;;
    2)
      read -r -s -p "  Tailscale pre-auth key (blank if already authorized): " TS_KEY || true
      echo
      read -r -p "  Node name [$(hostname)]: " TS_HN
      read -r -p "  Advertise tags (comma list) [tag:pve-proxy]: " TS_TAGS
      if tailscale up --authkey="${TS_KEY:-}" \
          --hostname="${TS_HN:-$(hostname)}" \
          --advertise-tags="${TS_TAGS:-tag:pve-proxy}"; then
        msg_ok "Tailnet joined: $(tailscale ip -4 2>/dev/null | head -n1 | tr -d '\r')"
      else
        msg_warn "tailscale up failed (check the pre-auth key / tag permissions)"
      fi
      ;;
    3)
      read -r -p "  Node name [$(hostname)]: " TS_HN
      read -r -p "  Advertise tags (comma list) [tag:pve-proxy]: " TS_TAGS
      if tailscale up --hostname="${TS_HN:-$(hostname)}" \
          --advertise-tags="${TS_TAGS:-tag:pve-proxy}"; then
        msg_ok "Node identity updated"
      else
        msg_warn "tailscale up failed (is the node authorized?)"
      fi
      ;;
    4)
      echo "  Current exit node: $(tailscale exit-node 2>/dev/null || echo none)"
      read -r -p "  Exit node name/IP (blank to disable): " TS_EXIT
      if [ -n "$TS_EXIT" ]; then
        if tailscale set --exit-node="$TS_EXIT" 2>/dev/null; then
          msg_ok "Exit node set to $TS_EXIT"
        else
          msg_warn "could not set exit node (is Tailscale up?)"
        fi
      else
        tailscale set --exit-node= 2>/dev/null || true
        msg_ok "Exit node disabled"
      fi
      ;;
    5)
      if confirm_yes "Leave the tailnet (tailscale down)?"; then
        if tailscale down; then msg_ok "Tailscale is down"; else msg_warn "tailscale down failed"; fi
      fi
      ;;
    *) echo "Back." ;;
  esac
}

# ── Advanced ─────────────────────────────────────────────────
adv_sync_schedule() {
  local cur new; cur=$(get_setting SYNC_CRON); [ -n "$cur" ] || cur="*/15"
  read -r -p "  Cron minutes expression (e.g. */5, */15, 30) [$cur]: " new
  new="${new:-$cur}"
  if ! [[ "$new" =~ ^[0-9*/,\-]+$ ]]; then echo "  Invalid cron minutes expression."; return; fi
  write_settings "SYNC_CRON=$new"; apply_cron
  msg_ok "Sync schedule set to '$new'"
}
adv_tls() {
  local cur; cur=$(get_setting PVE_SKIP_TLS_VERIFY)
  if [ "${cur:-0}" = "1" ]; then
    echo "  PVE API TLS verification is currently OFF (insecure -k)."
    if confirm_yes "Enable verification against the PVE cluster CA?"; then
      write_settings "PVE_SKIP_TLS_VERIFY=0"; msg_ok "TLS verification enabled"
    fi
  else
    echo "  PVE API TLS verification is currently ON (cluster CA)."
    if confirm_yes "Disable TLS verification (insecure -k)?"; then
      write_settings "PVE_SKIP_TLS_VERIFY=1"; msg_ok "TLS verification disabled (insecure)"
    fi
  fi
}
adv_subnets() {
  local cur new; cur=$(get_setting EXTRA_TRUSTED_SUBNETS)
  echo "  Current extra trusted subnets: ${cur:-<none>}"
  echo "  (Tailscale 100.64.0.0/10 is always trusted; add more, comma-separated.)"
  read -r -p "  Extra client subnets (blank to clear): " new
  new="${new//[[:space:]]/}"
  write_settings "EXTRA_TRUSTED_SUBNETS=$new"
  msg_ok "Trusted subnets updated. Run config.sh -> 6 (re-sync) to apply."
}
adv_acme() {
  local cur new; cur=$(get_setting ACME_CA)
  echo "  Current ACME CA: ${cur:-<Let Encrypt production>}"
  echo "  Staging: https://acme-staging-v02.api.letsencrypt.org/directory"
  read -r -p "  ACME directory URL (blank = production): " new
  write_settings "ACME_CA=${new}"
  msg_ok "ACME CA updated. Run config.sh -> 6 (re-sync) to apply."
}
menu_advanced() {
  echo ""
  echo -e "${BL}Advanced${CL}"
  echo "  1) Sync schedule (cron minutes)"
  echo "  2) PVE API TLS verification"
  echo "  3) Extra trusted client subnets"
  echo "  4) ACME CA endpoint"
  echo "  5) Show current settings"
  echo "  0) Back"
  read -r -p "  Choice: " ACH
  case "$ACH" in
    1) adv_sync_schedule ;;
    2) adv_tls ;;
    3) adv_subnets ;;
    4) adv_acme ;;
    5) echo ""; cat /etc/pve-proxy/settings.env 2>/dev/null || echo "  (no advanced settings set)";;
    *) echo "Back." ;;
  esac
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
echo " 10) Tailscale"
echo " 11) Advanced options"
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
    /usr/local/bin/pve-proxy-status.sh
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
  10)
    menu_tailscale
    ;;
  11)
    menu_advanced
    ;;
  0)
    echo "Bye."
    ;;
  *)
    echo "Invalid choice."
    exit 1
    ;;
esac
