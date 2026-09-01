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
apt-get install -yqq curl gnupg ca-certificates git cron python3 >/dev/null 2>&1
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

# Guard: the Go build needs ~2 GB of free disk for modules + build cache.
AVAIL_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 2000000 ]; then
  msg_error "Not enough disk for the Caddy build (need ~2 GB free, have $((AVAIL_KB/1024)) MB). Increase the container disk."
fi

# Debian 12 ships Go 1.19, which is too old for Caddy 2.10 / xcaddy 0.4.x.
# Install a pinned modern Go from go.dev (override with GO_VERSION=goX.Y.Z).
GO_VERSION="${GO_VERSION:-go1.27.1}"
msg_info "Installing Go (pinned $GO_VERSION)"
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz
export PATH="/usr/local/go/bin:$PATH"
go version >/dev/null 2>&1 || msg_error "Go installation failed"
msg_ok "Go installed: $(go version)"

export PATH="$PATH:$(go env GOPATH)/bin"
# Pinned: xcaddy v0.4.7, caddy v2.10.2, cloudflare DNS plugin v0.2.4
if ! go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.7 >/tmp/xcaddy-install.log 2>&1; then
  echo "--- go install xcaddy failed; tail of log:" >&2
  tail -30 /tmp/xcaddy-install.log >&2
  msg_error "go install xcaddy failed"
fi
# Build straight to the final path (no mv, no cwd ambiguity).
if ! xcaddy build v2.10.2 -output /usr/local/bin/caddy \
     --with github.com/caddy-dns/cloudflare@v0.2.4 >/tmp/xcaddy-build.log 2>&1; then
  echo "--- xcaddy build failed; tail of log:" >&2
  tail -30 /tmp/xcaddy-build.log >&2
  msg_error "xcaddy build failed"
fi
if /usr/local/bin/caddy list-modules 2>/dev/null | grep -q cloudflare; then
  msg_ok "Caddy built (cloudflare module verified)"
else
  msg_error "Caddy build failed: cloudflare module missing"
fi
# Reclaim the Go module/build caches (~2 GB) — not needed at runtime.
go clean -cache -modcache 2>/dev/null || true
msg_ok "Go caches cleaned"

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
cp "$REPO_DIR/usr/local/bin/pve-proxy-dns.sh"     /usr/local/bin/pve-proxy-dns.sh
chmod +x /usr/local/bin/render_caddyfile.py /usr/local/bin/pve-proxy-sync.sh /usr/local/bin/pve-proxy-dns.sh

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
