#!/usr/bin/env bash
set -euo pipefail

# ── Colors & helpers ──────────────────────────────────────────
YW="\033[33m"
GN="\033[1;92m"
RD="\033[01;31m"
CL="\033[m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
function msg_info() { echo -ne " ${YW}⏳ ${1}...${CL}"; }
function msg_ok()   { echo -e  " ${CM} ${1}"; }
function msg_error(){ echo -e  " ${CROSS} ${1}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Base packages ─────────────────────────────────────────
msg_info "Installing base packages"
apt-get update -qq >/dev/null 2>&1
apt-get install -yqq curl gnupg ca-certificates git golang-go cron >/dev/null 2>&1
msg_ok "Base packages installed"

# ── 2. Install uv + Python dependencies ──────────────────────
msg_info "Installing uv"
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"
msg_ok "uv installed"

msg_info "Setting up Python venv with uv"
mkdir -p /opt/pve-proxy
uv venv /opt/pve-proxy/.venv >/dev/null 2>&1
uv pip install --python /opt/pve-proxy/.venv/bin/python jinja2 pyyaml >/dev/null 2>&1
msg_ok "Python dependencies installed (jinja2, pyyaml)"

# ── 3. Tailscale ─────────────────────────────────────────────
msg_info "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
msg_ok "Tailscale installed"

# ── 4. Build Caddy with Cloudflare DNS plugin ────────────────
msg_info "Building Caddy with Cloudflare DNS plugin (this takes a while)"
export PATH=$PATH:$(go env GOPATH)/bin
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest >/dev/null 2>&1
xcaddy build v2.10.2 --with github.com/caddy-dns/cloudflare >/dev/null 2>&1
mv ./caddy /usr/local/bin/caddy
if caddy list-modules 2>/dev/null | grep -q cloudflare; then
  msg_ok "Caddy built (cloudflare module verified)"
else
  msg_error "Caddy build failed: cloudflare module missing"
fi

# ── 5. System user + directories ─────────────────────────────
msg_info "Creating caddy user and directories"
groupadd --system caddy 2>/dev/null || true
useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
mkdir -p /etc/caddy /etc/pve-proxy /var/log/caddy
msg_ok "User and directories created"

# ── 6. Deploy project files ──────────────────────────────────
msg_info "Deploying project files"
cp "$SCRIPT_DIR/usr/local/bin/render_caddyfile.py" /usr/local/bin/render_caddyfile.py
cp "$SCRIPT_DIR/usr/local/bin/pve-proxy-sync.sh"   /usr/local/bin/pve-proxy-sync.sh
chmod +x /usr/local/bin/render_caddyfile.py /usr/local/bin/pve-proxy-sync.sh

cp "$SCRIPT_DIR/etc/caddy/Caddyfile.template"       /etc/caddy/Caddyfile.template
cp "$SCRIPT_DIR/etc/pve-proxy/services.yaml"         /etc/pve-proxy/services.yaml
cp "$SCRIPT_DIR/etc/systemd/system/caddy.service"    /etc/systemd/system/caddy.service
cp "$SCRIPT_DIR/etc/cron.d/pve-proxy-sync"           /etc/cron.d/pve-proxy-sync

git init -q /etc/pve-proxy 2>/dev/null || true

systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1
msg_ok "Project files deployed"
