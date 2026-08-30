# PVE-Proxy

Caddy reverse proxy for Proxmox VE containers, accessible over Tailscale with wildcard TLS via Cloudflare DNS-01.

## Install

On a Proxmox VE node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vinodnal/pve-proxy/master/install.sh)"
```

The installer asks interactively for everything environment-specific:

- Container ID (auto-detects the next free one), hostname, resources
- Wildcard base domain (e.g. `pve.example.com`) and ACME contact email
- Cloudflare API token (`Zone:DNS:Edit` scope)
- PVE API token ID + secret, and PVE host address

Secrets are written directly into the container and never logged. The PVE cluster
CA is pushed into the container so the sync verifies the PVE API TLS certificate
(no `-k`).

## Architecture

```
Cloudflare (DNS-only, grey cloud)
  *.<domain> → 100.x.x.x (Tailscale IP)
        │
        ▼
  ┌─────────────┐
  │  pve-proxy  │  LXC — Caddy + wildcard cert
  │  (tailnet)  │
  └──────┬──────┘
         │ reverse_proxy
    ┌────┴─────────────────────┐
    │    LAN backends          │
    │  <container-ip>:port     │
    └──────────────────────────┘
```

- **One wildcard cert** (`*.<domain>`) via DNS-01 — no per-container certs, no CT log leaks
- **Tailscale ACL** restricts who can reach the proxy; Caddy's `remote_ip` matcher allows **only** Tailscale CGNAT (`100.64.0.0/10`) traffic — LAN traffic is rejected too
- **Auto-sync cron** pulls running containers from the PVE API every 15 minutes (verifying TLS against the PVE cluster CA) and regenerates the Caddyfile

## Project Structure (community-scripts style)

```
pve-proxy/
├── install.sh                           # One-liner entry point (curl|bash on PVE node)
├── create-lxc.sh                        # Host-side: creates + configures the CT
├── build.func                           # Shared host-side library (msg, checks, prompts)
├── install/
│   └── pve-proxy-install.sh             # Container-side installer
├── setup.sh                             # Wrapper around install/pve-proxy-install.sh
├── update.sh                            # Pull latest + redeploy (inside CT)
├── config.sh                            # Interactive reconfiguration menu (inside CT)
├── etc/
│   ├── caddy/Caddyfile.template         # Jinja2 template (domain/email injected)
│   ├── cron.d/pve-proxy-sync            # 15-minute sync cron job
│   ├── pve-proxy/services.yaml          # Manual port map (name → ip:port)
│   ├── pve-proxy/.gitignore             # Keeps secrets out of the sync git repo
│   └── systemd/system/caddy.service     # Hardened systemd unit
├── hooks/
│   ├── pre-commit                       # Git hook: scripts/check.sh + staged secret guard
│   └── install.sh                       # Enables hooks (core.hooksPath=hooks)
├── scripts/
│   └── check.sh                         # Local validation (bash -n, py compile, secret scan)
├── requirements.txt                    # Pinned Python deps (jinja2, pyyaml)
├── pyproject.toml                      # Renderer project metadata
├── SECURITY.md                         # Threat model & token scopes
├── CHANGELOG.md                        # Release notes
└── usr/local/bin/
    ├── pve-proxy-sync.sh                # Discovery: PVE API → render → validate → reload
    └── render_caddyfile.py              # Merges live data + services.yaml + domain
```

## Prerequisites

Create the PVE API token on any PVE node (name it whatever you like):

```bash
pveum user add pve-proxy@pam
pveum aclmod / -user pve-proxy@pam -role PVEAuditor
pveum user token add pve-proxy@pam sync --privsep 0
```

Save the token ID (`pve-proxy@pam!sync`) and secret — the installer asks for them.

You also need a Cloudflare API token with `Zone:DNS:Edit` scope on your zone.

## Post-Install Steps

After the installer finishes, enter the container and:

```bash
# Join tailnet
tailscale up --hostname=pve-proxy --advertise-tags=tag:pve-proxy

# Note the IP for the DNS record
tailscale ip -4

# Run first sync
/usr/local/bin/pve-proxy-sync.sh

# Start Caddy
systemctl start caddy
```

Then create a Cloudflare DNS record:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `*.<domain>` | `100.x.x.x` (Tailscale IP) | DNS only |

Optional (sensitive services only): set a basic-auth hash so `auth: basic` entries
in `services.yaml` actually get protected:

```bash
# generate a bcrypt hash
caddy hash-password
# then store it
config.sh   # -> 8) Basic auth hash
```

## Adding a Service

Edit `/etc/pve-proxy/services.yaml`:

```yaml
myapp: { node: pve1, ip: 10.0.0.30, port: 8080 }
```

Wait for the next cron cycle (15 min) or run `config.sh` → re-sync.

The service will be available at `https://myapp.<domain>`.

If the service should require login, set `auth: basic` on its line and make sure a
`BASIC_AUTH_HASH` is configured (`config.sh` → 8). Services marked `auth: basic`
without a hash are rendered **without** auth and log a warning, so a missing hash
can never break a sync.

> **Note:** The port map is manual. The PVE API provides container names/IPs but not which port a service listens on.

## Update

Inside the container:

```bash
bash /root/pve-proxy/update.sh
```

Pulls latest code, redeploys all scripts (including the secrets `.gitignore`),
updates Python deps, and reloads Caddy.

> Upgrading an install that was created before the `.gitignore` shipped: the sync
> script will refuse to run until secret files are removed from the `/etc/pve-proxy`
> git history. See the remediation hint printed by `pve-proxy-sync.sh`, or re-run the
> installer for a clean container.

## Configure

Inside the container:

```bash
bash /root/pve-proxy/config.sh
```

Interactive menu to update tokens, PVE host, domain/email, edit services, trigger a sync, or show status.

## Tailscale ACL (Recommended)

```json
{
  "tagOwners": { "tag:pve-proxy": ["autogroup:admin"] },
  "acls": [{
    "action": "accept",
    "src": ["autogroup:admin"],
    "dst": ["tag:pve-proxy:443"]
  }]
}
```

## Verification

```bash
dig myapp.<domain> +short
curl -v https://myapp.<domain>/

# Confirm wildcard cert (not per-name)
echo | openssl s_client -connect myapp.<domain>:443 \
  -servername myapp.<domain> 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

## Development

```bash
# Enable git hooks (runs bash -n + Python compile + secret scan on every commit)
bash hooks/install.sh

# Run the same checks manually
bash scripts/check.sh

# Render a Caddyfile locally (needs uv)
uv run --no-project --with pyyaml --with jinja2 python usr/local/bin/render_caddyfile.py \
  --live live.json --services etc/pve-proxy/services.yaml \
  --template etc/caddy/Caddyfile.template --domain pve.example.com --email you@example.com \
  --basic-auth-hash '$2y$10$...' --out /tmp/Caddyfile
```

Commits use [conventional commits](https://www.conventionalcommits.org/), e.g.
`fix(security): ...`, `feat(sync): ...`. Never use `--no-verify`.

## Security

- Secrets are written into the container with `printf` (never shell-interpolated) and
  are **excluded from the `/etc/pve-proxy` git repo** via a shipped `.gitignore`. The
  sync script refuses to run if a secret `*.env` file is ever tracked in git history.
- PVE API calls verify TLS against the PVE cluster CA (pushed at install); no `-k`.
- Caddy admin API bound to `localhost:2019` only.
- Unprivileged container with nesting (required for Tailscale).
- `remote_ip` matcher allows **only Tailscale CGNAT (`100.64.0.0/10`)** — RFC1918 LAN
  traffic is rejected at the Caddy layer (defense in depth behind the Tailscale ACL).
- Sensitive services get working `basicauth` (username `admin`) — set the bcrypt hash
  at install or via `config.sh` → 8 (`caddy hash-password`).
- Least-privilege file permissions: `pve-token.env` is `600 root:root`;
  `cloudflare.env` and `proxy.env` are `640 root:caddy`. Upgradeable to systemd
  `LoadCredential=` later.
- Access logging to `/var/log/caddy/access.log` (rotated, JSON) for audit.
- Certificate expiry is monitored and warns via journald when < 14 days remain.
- Pinned toolchain: Caddy v2.10.2, xcaddy v0.4.7, cloudflare DNS v0.2.4, uv 0.12.7.
  Pin the whole install to a release tag with `PVE_PROXY_REF=v1.x.y` (default
  `master`); override the source repo with `PVE_PROXY_REPO=<url>` (default: the
  upstream repo).

## License

MIT
