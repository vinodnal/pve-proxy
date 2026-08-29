# PVE-Proxy

Caddy reverse proxy for Proxmox VE containers, accessible over Tailscale with wildcard TLS via Cloudflare DNS-01.

## Install

On a Proxmox VE node:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/vinodnal/pve-proxy/main/install.sh)"
```

The installer will interactively ask for:
- Container ID (auto-detects next available), hostname, resources
- Cloudflare API token (Zone:DNS:Edit scope)
- PVE API token ID and secret
- PVE host address

Everything is set up automatically — secrets are written directly into the container and never logged.

## Architecture

```
Cloudflare (DNS-only, grey cloud)
  *.pve.lab.hmh2.salahxg.com → 100.x.x.x (Tailscale IP)
        │
        ▼
  ┌─────────────┐
  │  pve-proxy  │  LXC — Caddy + wildcard cert
  │  (tailnet)  │
  └──────┬──────┘
         │ reverse_proxy
    ┌────┴─────────────────────┐
    │    LAN backends          │
    │  192.168.10.x:port       │
    └──────────────────────────┘
```

- **One wildcard cert** (`*.pve.lab.hmh2.salahxg.com`) via DNS-01 — no per-container certs, no CT log leaks
- **Tailscale ACL** restricts who can reach the proxy; Caddy's `remote_ip` matcher blocks non-tailnet traffic
- **Auto-sync cron** pulls running containers from the PVE API every 15 minutes and regenerates the Caddyfile

## Prerequisites

Before running the installer, create the PVE API token on any PVE node:

```bash
pveum user add pve-proxy@pam
pveum aclmod / -user pve-proxy@pam -role PVEAuditor
pveum user token add pve-proxy@pam sync --privsep 0
```

Save the token ID (`pve-proxy@pam!sync`) and secret — the installer will ask for them.

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
| A | `*.pve.lab.hmh2.salahxg.com` | `100.x.x.x` (Tailscale IP) | DNS only |

## Adding a Service

Edit `/etc/pve-proxy/services.yaml`:

```yaml
myapp: { node: pve1, ip: 192.168.10.30, port: 8080 }
```

Wait for the next cron cycle (15 min) or run `config.sh` → option 5.

The service will be available at `https://myapp.pve.lab.hmh2.salahxg.com`.

> **Note:** The port map is manual. The PVE API provides container names/IPs but not which port a service listens on.

## Update

Inside the container:

```bash
bash /root/pve-proxy/update.sh
```

Pulls latest code from the repo, redeploys all scripts, updates Python deps, and reloads Caddy.

## Configure

Inside the container:

```bash
bash /root/pve-proxy/config.sh
```

Interactive menu to:
1. Update Cloudflare API token
2. Update PVE API token
3. Change PVE host address
4. Edit services.yaml
5. Trigger a sync
6. Show status (Caddy, Tailscale, last sync, active services)

## Project Structure

```
pve-proxy/
├── install.sh                           # One-liner entry point (curl|bash on PVE node)
├── create-lxc.sh                        # Interactive CT creation + provisioning
├── setup.sh                             # Runs inside CT — installs all dependencies
├── update.sh                            # Pull latest + redeploy
├── config.sh                            # Interactive reconfiguration menu
├── etc/
│   ├── caddy/Caddyfile.template         # Jinja2 template for the generated Caddyfile
│   ├── cron.d/pve-proxy-sync            # 15-minute sync cron job
│   ├── pve-proxy/services.yaml          # Manual port map (name → ip:port)
│   └── systemd/system/caddy.service     # Hardened systemd unit
└── usr/local/bin/
    ├── pve-proxy-sync.sh                # Discovery: PVE API → render → validate → reload
    └── render_caddyfile.py              # Merges live container data with services.yaml
```

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
dig nexterm.pve.lab.hmh2.salahxg.com +short
curl -v https://nexterm.pve.lab.hmh2.salahxg.com/

# Confirm wildcard cert (not per-name)
echo | openssl s_client -connect nexterm.pve.lab.hmh2.salahxg.com:443 \
  -servername nexterm.pve.lab.hmh2.salahxg.com 2>/dev/null \
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
