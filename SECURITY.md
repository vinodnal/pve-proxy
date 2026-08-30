# Security

## Threat model & trust boundaries

- The `pve-proxy` container is the highest-value target in the lab: it holds the
  Cloudflare **DNS-edit token**, the **wildcard TLS private key**, and a route to
  every backend behind it. Keep it minimal and single-purpose.
- The **primary** access control is the Tailscale ACL (`tag:pve-proxy`). Caddy's
  `remote_ip` matcher (Tailscale CGNAT `100.64.0.0/10` only) is defense in depth —
  RFC1918 LAN traffic is **not** trusted.
- The public `*.domain` DNS record resolves to the Tailscale IP but is not routable
  from the public internet (mesh-private by design).

## Token scopes (least privilege)

| Token | Scope | Leak impact |
|-------|-------|-------------|
| Cloudflare API token | `Zone:DNS:Edit` on **one** zone | DNS hijack + ACME DNS-01 can issue TLS certs for arbitrary names in that zone. **Rotate immediately if leaked.** |
| PVE API token | `PVEAuditor` role on `/` (read-only container discovery) | Read-only inventory leak (container names/IPs). No container power. |

## Secret handling

- Secret files live in `/etc/pve-proxy/`:
  - `pve-token.env` → `600 root:root` (only the root cron sync reads it)
  - `cloudflare.env`, `proxy.env` → `640 root:caddy`
- Secrets are written with `printf` + `pct push` (or temp-file `mv`), never
  shell/heredoc-interpolated.
- `/etc/pve-proxy/.gitignore` excludes `*.env`; the sync script refuses to run if a
  secret `*.env` file is ever tracked in git history.
- Future hardening: migrate to systemd `LoadCredential=` so secrets never sit as
  plaintext files.

## Sync hardening

- PVE API calls verify TLS against the pushed cluster CA (`--cacert
  /etc/pve-proxy/pve-ssl-ca.pem`). `-k` is used only as a **logged fallback** when
  the CA is missing.
- The Caddyfile is validated (`caddy validate`) before reload, and the previous good
  config is kept for automatic rollback.

## Reporting

Do **not** open a public issue containing secrets or topology details. Report
security issues privately to the maintainer (see the GitHub repository's security
advisories / contact settings).
