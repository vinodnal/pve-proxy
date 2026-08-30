#!/usr/bin/env bash
# Container-side installer. Runs INSIDE the LXC as root.
set -Eeuo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
function msg_info() { echo -ne " ${YW}⏳ $*...${CL}\n"; }
function msg_ok()   { echo -e  " ${CM} $*"; }
function msg_error(){ echo -e  " ${CROSS} $*"; exit 1; }

REPO_DIR="${1:-/root/pve-proxy}"
# Canonical repo; the host installer passes its source via $2 so a fork/mirror
# install updates from the same place (PVE_PROXY_REPO).
REPO_URL="${2:-https://github.com/vinodnal/pve-proxy}"

# ── 1. Base packages ─────────────────────────────────────────
msg_info "Installing base packages"
apt-get update -qq >/dev/null 2>&1
apt-get install -yqq curl gnupg ca-certificates git golang-go cron >/dev/null 2>&1
msg_ok "Base packages installed"

# ── 2. Install uv + Python dependencies ──────────────────────
msg_info "Installing uv (pinned 0.12.7)"
curl -LsSf https://releases.astral.sh/github/uv/releases/download/0.12.7/uv-installer.sh | sh >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"
msg_ok "uv installed"

msg_info "Setting up Python venv with uv"
mkdir -p /opt/pve-proxy
uv venv /opt/pve-proxy/.venv >/dev/null 2>&1
uv pip install --python /opt/pve-proxy/.venv/bin/python -r "$REPO_DIR/requirements.txt" >/dev/null 2>&1
msg_ok "Python dependencies installed"

# ── 3. Tailscale ─────────────────────────────────────────────
msg_info "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
msg_ok "Tailscale installed"

# ── 4. Build Caddy with Cloudflare DNS plugin ────────────────
msg_info "Building Caddy with Cloudflare DNS plugin (this takes a while)"
export PATH=$PATH:$(go env GOPATH)/bin
# Pinned: xcaddy v0.4.7, caddy v2.10.2, cloudflare DNS plugin v0.2.4
go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 >/dev/null 2>&1
xcaddy build v2.10.2 --with github.com/caddy-dns/cloudflare@v0.2.4 >/dev/null 2>&1
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
cp "$REPO_DIR/usr/local/bin/render_caddyfile.py" /usr/local/bin/render_caddyfile.py
cp "$REPO_DIR/usr/local/bin/pve-proxy-sync.sh"   /usr/local/bin/pve-proxy-sync.sh
chmod +x /usr/local/bin/render_caddyfile.py /usr/local/bin/pve-proxy-sync.sh

cp "$REPO_DIR/etc/caddy/Caddyfile.template"       /etc/caddy/Caddyfile.template
cp "$REPO_DIR/etc/pve-proxy/services.yaml"         /etc/pve-proxy/services.yaml
# .gitignore MUST exist before `git init` so the sync snapshots never
# commit the secret *.env files into git history.
cp "$REPO_DIR/etc/pve-proxy/.gitignore"            /etc/pve-proxy/.gitignore
cp "$REPO_DIR/etc/systemd/system/caddy.service"    /etc/systemd/system/caddy.service
cp "$REPO_DIR/etc/cron.d/pve-proxy-sync"           /etc/cron.d/pve-proxy-sync

git init -q /etc/pve-proxy 2>/dev/null || true

# ── 7. Initialize the container-side repo so update.sh can pull ──
if [ ! -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" init -q
  git -C "$REPO_DIR" remote add origin "$REPO_URL"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" -c user.email="pve-proxy@localhost" -c user.name="pve-proxy" \
    commit -qm "installed snapshot $(date -Iseconds)"
fi

systemctl daemon-reload
systemctl enable caddy >/dev/null 2>&1
msg_ok "Project files deployed"

msg_ok "Install complete"
