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

Secrets are written directly into the container and never logged.

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
- **Tailscale ACL** restricts who can reach the proxy; Caddy's `remote_ip` matcher blocks non-tailnet traffic
- **Auto-sync cron** pulls running containers from the PVE API every 15 minutes and regenerates the Caddyfile

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
│   └── systemd/system/caddy.service     # Hardened systemd unit
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

## Adding a Service

Edit `/etc/pve-proxy/services.yaml`:

```yaml
myapp: { node: pve1, ip: 10.0.0.30, port: 8080 }
```

Wait for the next cron cycle (15 min) or run `config.sh` → re-sync.

The service will be available at `https://myapp.<domain>`.

> **Note:** The port map is manual. The PVE API provides container names/IPs but not which port a service listens on.

## Update

Inside the container:

```bash
bash /root/pve-proxy/update.sh
```

Pulls latest code, redeploys all scripts, updates Python deps, and reloads Caddy.

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

## Security

- Secrets created directly on the host, never passed through automation logs
- Caddy admin API bound to `localhost:2019` only
- Unprivileged container with nesting (required for Tailscale)
- `remote_ip` matcher rejects non-Tailscale traffic at the Caddy layer
- Sensitive services get `basicauth` — generate hash with `caddy hash-password`
- Secret files: `640 root:caddy`; upgradeable to systemd `LoadCredential=` later

## License

MIT
