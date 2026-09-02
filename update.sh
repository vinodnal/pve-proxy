#!/usr/bin/env bash
# Run inside the pve-proxy CT to pull latest code and redeploy.
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Centralized logging (graceful fallback if lib not yet deployed).
PP_COMPONENT=update
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
fi

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
function msg_info() { pp_info "⏳ ${1}..."; }
function msg_ok()   { pp_ok " ${1}"; }
function msg_warn() { pp_warn " ${1}"; }
function msg_error(){ pp_err " ${1}"; exit 1; }

REPO_DIR="/root/pve-proxy"

if [ ! -d "$REPO_DIR/.git" ]; then
  msg_error "Repository not found at $REPO_DIR. Run the installer first."
fi

# Pull latest, but degrade gracefully: an in-place-patched or offline repo must
# not block the update. /root/pve-proxy is a pure source mirror, so reset is safe.
msg_info "Pulling latest changes"
cd "$REPO_DIR"
if git remote 2>/dev/null | grep -q origin; then
  if git fetch origin master >/dev/null 2>&1; then
    git reset --hard origin/master
    msg_ok "Repository updated (origin/master)"
  else
    msg_warn "Could not reach origin (offline?); continuing with local files"
  fi
else
  msg_warn "No git origin configured; continuing with local files"
fi
msg_ok "Repository ready"

msg_info "Deploying updated files"
mkdir -p /usr/local/lib/pve-proxy /var/log/pve-proxy /var/lib/pve-proxy/state
cp "$REPO_DIR/usr/local/bin/render_caddyfile.py" /usr/local/bin/render_caddyfile.py
cp "$REPO_DIR/usr/local/bin/pve-proxy-sync.sh"   /usr/local/bin/pve-proxy-sync.sh
cp "$REPO_DIR/usr/local/bin/pve-proxy-dns.sh"    /usr/local/bin/pve-proxy-dns.sh
cp "$REPO_DIR/usr/local/bin/pve-proxy-status.sh" /usr/local/bin/pve-proxy-status.sh
cp "$REPO_DIR/usr/local/lib/pve-proxy/common.sh" /usr/local/lib/pve-proxy/common.sh
chmod +x /usr/local/bin/render_caddyfile.py /usr/local/bin/pve-proxy-sync.sh \
         /usr/local/bin/pve-proxy-dns.sh /usr/local/bin/pve-proxy-status.sh
chmod 0644 /usr/local/lib/pve-proxy/common.sh

cp "$REPO_DIR/etc/caddy/Caddyfile.template"       /etc/caddy/Caddyfile.template
# Never clobber a live services.yaml (users edit it); seed default only once.
if [ ! -f /etc/pve-proxy/services.yaml ]; then
  cp "$REPO_DIR/etc/pve-proxy/services.yaml" /etc/pve-proxy/services.yaml
fi
cp "$REPO_DIR/etc/pve-proxy/.gitignore"            /etc/pve-proxy/.gitignore
cp "$REPO_DIR/etc/systemd/system/caddy.service"    /etc/systemd/system/caddy.service
cp "$REPO_DIR/etc/cron.d/pve-proxy-sync"           /etc/cron.d/pve-proxy-sync
cp "$REPO_DIR/etc/logrotate.d/pve-proxy"           /etc/logrotate.d/pve-proxy
chmod 0644 /etc/cron.d/pve-proxy-sync /etc/logrotate.d/pve-proxy
cp "$REPO_DIR/install/pve-proxy-install.sh"        /root/pve-proxy/install/pve-proxy-install.sh
cp "$REPO_DIR/config.sh"                            /root/pve-proxy/config.sh
cp "$REPO_DIR/update.sh"                            /root/pve-proxy/update.sh
msg_ok "Files deployed"

msg_info "Updating Python dependencies"
export PATH="$HOME/.local/bin:$PATH"
uv pip install --python /opt/pve-proxy/.venv/bin/python --upgrade -r "$REPO_DIR/requirements.txt" >/dev/null 2>&1
msg_ok "Python dependencies updated"

msg_info "Reloading services"
systemctl daemon-reload
if /usr/local/bin/pve-proxy-sync.sh; then
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
  msg_ok "Services reloaded"
else
  msg_warn "sync reported an error; see /var/log/pve-proxy/pve-proxy.log, then run: pve-proxy-status.sh"
fi

echo -e "\n ${GN}Update complete${CL}\n"
echo -e " Check state anytime with: ${GN}pve-proxy-status.sh${CL}"
echo -e " Logs: /var/log/pve-proxy/pve-proxy.log"
