#!/usr/bin/env bash
# Run inside the pve-proxy CT to pull latest code and redeploy.
set -euo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
function msg_info() { echo -ne " ${YW}⏳ ${1}...${CL}\n"; }
function msg_ok()   { echo -e  " ${CM} ${1}"; }
function msg_error(){ echo -e  " ${CROSS} ${1}"; exit 1; }

REPO_DIR="/root/pve-proxy"

if [ ! -d "$REPO_DIR/.git" ]; then
  msg_error "Repository not found at $REPO_DIR. Run the installer first."
fi

msg_info "Pulling latest changes"
cd "$REPO_DIR"
git pull --ff-only
msg_ok "Repository updated"

msg_info "Deploying updated files"
cp "$REPO_DIR/usr/local/bin/render_caddyfile.py" /usr/local/bin/render_caddyfile.py
cp "$REPO_DIR/usr/local/bin/pve-proxy-sync.sh"   /usr/local/bin/pve-proxy-sync.sh
chmod +x /usr/local/bin/render_caddyfile.py /usr/local/bin/pve-proxy-sync.sh

cp "$REPO_DIR/etc/caddy/Caddyfile.template"       /etc/caddy/Caddyfile.template
cp "$REPO_DIR/etc/systemd/system/caddy.service"    /etc/systemd/system/caddy.service
cp "$REPO_DIR/etc/cron.d/pve-proxy-sync"           /etc/cron.d/pve-proxy-sync
msg_ok "Files deployed"

msg_info "Updating Python dependencies"
export PATH="$HOME/.local/bin:$PATH"
uv pip install --python /opt/pve-proxy/.venv/bin/python --upgrade jinja2 pyyaml >/dev/null 2>&1
msg_ok "Python dependencies updated"

msg_info "Reloading services"
systemctl daemon-reload
/usr/local/bin/pve-proxy-sync.sh
systemctl reload caddy 2>/dev/null || systemctl restart caddy
msg_ok "Services reloaded"

echo -e "\n ${GN}Update complete${CL}\n"
