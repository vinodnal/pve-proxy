# PVE-Proxy

Caddy reverse proxy for Proxmox VE containers, accessible over Tailscale with wildcard TLS via Cloudflare DNS-01.

## Install

On a Proxmox VE node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vinodnal/pve-proxy/master/install.sh)"
```

The installer asks for only the environment-specific values:

- Container ID (auto-detects the next free one), hostname, resources
- Wildcard base domain (e.g. `pve.example.com`) and ACME contact email
- Cloudflare authentication (see [API keys](#api-keys))
- Tailscale pre-auth key — optional, enables fully automatic setup
- Basic-auth hash — optional

The **PVE API token is auto-created** by the installer (it runs as root on the PVE
host), so you don't provide one. Secrets are written directly into the container
and never logged. The PVE cluster CA is pushed into the container so the sync
verifies the PVE API TLS certificate (no `-k`).

### API keys

| What | Required | Notes |
|------|----------|-------|
| Cloudflare API token | yes | `Zone:Read` + `Zone:DNS:Edit` on your zone (DNS-01 wildcard cert + auto DNS record). Or choose option 2 and the installer mints a scoped token from your **Global API Key** (the global key is not stored). |
| Tailscale pre-auth key | optional | Tagged `tag:pve-proxy`. With it the installer joins the tailnet, creates the DNS record, runs the first sync, and starts Caddy — zero manual steps. |
| PVE API token | no | Auto-created (`pve-proxy@pam!sync`, `PVEAuditor` role). |
| ACME email | yes | Just a contact email for Let's Encrypt. |

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
    ├── pve-proxy-dns.sh                 # Creates/updates the Cloudflare wildcard A record
    └── render_caddyfile.py              # Merges live data + services.yaml + domain
```

## Prerequisites

- **A Cloudflare API token** with `Zone:Read` + `Zone:DNS:Edit` on the zone — or the
  zone's **Global API Key** + email, and the installer will auto-create the scoped
  token for you.
- **Optional:** a Tailscale pre-auth key tagged `tag:pve-proxy` for fully automatic
  setup (Tailscale admin console → Settings → Keys).
- **No PVE token needed** — the installer creates `pve-proxy@pam` + `PVEAuditor` and
  its token automatically (it runs as root on the node).

## Post-Install Steps

**If you provided a Tailscale pre-auth key:** nothing to do — the installer joined
the tailnet, created the DNS record, ran the first sync, and started Caddy. The
wildcard cert issues on first request.

**If you skipped the Tailscale key:** one command after install:

```bash
pct enter <CTID>
tailscale up --hostname=pve-proxy --advertise-tags=tag:pve-proxy
tailscale ip -4          # note the IP, then:
config.sh                # -> 9) Create/update Cloudflare DNS record
```

(First sync and Caddy are already started by the installer.)

Optional (sensitive services only): set a basic-auth hash so `auth: basic` entries
in `services.yaml` actually get protected:

```bash
caddy hash-password      # generate a bcrypt hash
config.sh                # -> 8) Basic auth hash
```

## Adding a Service

Edit `/etc/pve-proxy/services.yaml`. Only the container name and service `port`
are required — the container's IP is auto-discovered by the sync from the PVE API
(`/nodes/{node}/lxc/{vmid}/interfaces`), which reports the live address even for
DHCP containers:

```yaml
myapp: { node: pve1, port: 8080 }
```

Pin a specific IP only when you need to override discovery:

```yaml
myapp: { node: pve1, ip: 10.0.0.30, port: 8080 }
```

Wait for the next cron cycle (15 min) or run `config.sh` → re-sync.

The service will be available at `https://myapp.<domain>`.

If the service should require login, set `auth: basic` on its line and make sure a
`BASIC_AUTH_HASH` is configured (`config.sh` → 8). Services marked `auth: basic`
without a hash are rendered **without** auth and log a warning, so a missing hash
can never break a sync.

> **Note:** The service `port` is the one value PVE can't tell you and must always
> be set by hand. The container IP is resolved automatically from the PVE API
> whenever you omit `ip:`.

### Raw TCP services (SSH, RDP, databases, ...)

pve-proxy can also forward non-HTTP protocols. Mark an entry `mode: tcp` and give
it a dedicated public `listen_port`. Because raw TCP carries no hostname, routing
is **by port** — give each TCP service its own `listen_port` and connect to
`<domain>:<listen_port>` (the subdomain label is cosmetic for TCP):

```yaml
# SSH into the nexterm container via pve.salahxg.com:2222
nexterm-ssh: { node: pve1, container: nexterm, port: 22, mode: tcp, listen_port: 2222 }
```

- The key is a **label**, not the container name (routing is by `listen_port`, so the
  subdomain label is cosmetic). Add `container: <name>` to say which running container
  it fronts — that container is used for the running-container check and IP
  auto-discovery. Omit `container:` when the key already equals the container name,
  and `ip:` overrides discovery as usual.
- Requires the Caddy build with **caddy-l4**. Code updates alone (`update.sh`) deploy
the new scripts/template but do **not** rebuild the binary — run
`bash /root/pve-proxy/setup.sh` once afterwards (idempotent) so the installer
rebuilds Caddy with caddy-l4. The installer verifies both modules after a build.
- The sync refuses to render TCP services with a clear message if the module is
  missing, so a forgotten rebuild can never ship a broken config.
- `listen_port` must be unique and must not collide with the proxy's own services
  (`80`/`443`/`2019` are rejected; the proxy's own sshd usually owns `:22`, so
  prefer a high port).
- `port` is the container-side port (e.g. `22`); `listen_port` is the public proxy
  port. Container-IP auto-discovery works exactly as it does for HTTP services.
- TCP forwards inherit the same Tailscale-only trust as HTTP: connections are
  dropped unless they come from `100.64.0.0/10` (plus your extra trusted subnets).

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
config.sh        # bare name works (it is on PATH)
```

The interactive menu covers secrets and services plus **Tailscale** and **Advanced**
options:

```
 1) Cloudflare API token          8) Basic auth hash
 2) PVE API token                 9) Cloudflare DNS record
 3) PVE host address             10) Tailscale
 4) Domain / ACME email          11) Advanced options
 5) Edit services.yaml            0) Exit
 6) Re-sync now
 7) Show status
```

- **10) Tailscale** — status/IP, join/authenticate, set node name & tags, route via
  an exit node, or leave the tailnet.
- **11) Advanced** — settings stored in `/etc/pve-proxy/settings.env`:
  - sync schedule (cron minutes, rewrites `/etc/cron.d/pve-proxy-sync`),
  - PVE API TLS verification on/off,
  - extra trusted client subnets beyond Tailscale (`EXTRA_TRUSTED_SUBNETS`,
    added to Caddy's `remote_ip` allow list),
  - ACME CA endpoint (default Let's Encrypt production; staging for testing),
  - show current settings.

Advanced settings are picked up by `pve-proxy-sync.sh` on the next sync/render.

## Operations: status & logs

Inside the container, check the health of the whole stack in one place:

```bash
pve-proxy-status.sh              # human dashboard
pve-proxy-status.sh --json       # machine-readable aggregate (collector)
pve-proxy-status.sh --tail       # tail the central log
```

The dashboard shows Caddy service/config state, the last sync result, configuration
presence (tokens shown as `set`/`empty`, never their value), scheduler status, and
certificate expiry.

**Central logging.** All components (`sync`, `dns`, `update`, `install`, `status`)
write timestamped, level-tagged lines to a single central log:

```bash
tail -f /var/log/pve-proxy/pve-proxy.log      # central log
tail -f /var/lib/pve-proxy/state/sync.json    # last sync outcome (for the collector)
journalctl -t 'pve-proxy*'                     # mirrored to journald
```

Every `pve-proxy-*.sh` exports a fixed `PATH` (including `/usr/local/bin`) so it
works correctly under cron/systemd, which supply a minimal `PATH`. Guards fail
**gracefully**: they log the reason, write a failure state (so the dashboard never
shows a stale success), and exit non-zero without corrupting the live config.
The cron job runs with `PP_QUIET=1` so it emits no mail spam; all structured
logging goes to the central log and journald. Logs are rotated by
`/etc/logrotate.d/pve-proxy`.

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
- Pinned toolchain: Caddy v2.11.4, xcaddy v0.4.7, cloudflare DNS v0.2.4, uv 0.12.7.
  Pin the whole install to a release tag with `PVE_PROXY_REF=v1.x.y` (default
  `master`); override the source repo with `PVE_PROXY_REPO=<url>` (default: the
  upstream repo).

## License

MIT
