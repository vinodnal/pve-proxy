# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - 2026-08-30

Initial hardened release.

### Added

- Auto-sync cron: pulls running LXCs from the PVE API every 15 minutes and renders a
  single-wildcard-cert Caddyfile (DNS-01 via Cloudflare, no CT-log name leaks).
- `basicauth` for sensitive services (username `admin`, bcrypt hash from
  `BASIC_AUTH_HASH`) — now actually enforced end-to-end.
- Access logging to `/var/log/caddy/access.log` (rotated, JSON).
- Certificate-expiry alerting via the Caddy admin API (warns via journald < 14 days).
- Pinned toolchain: Caddy `v2.10.2`, xcaddy `v0.4.7`, cloudflare DNS plugin `v0.2.4`,
  uv `0.12.7`, jinja2 `3.1.6`, pyyaml `6.0.3`. `PVE_PROXY_REF` pins the whole install
  to a release tag.
- Git hooks (`hooks/`) and `scripts/check.sh` for local validation (bash -n, Python
  compile, secret scan).

### Security

- Secrets excluded from the `/etc/pve-proxy` git history via a shipped `.gitignore`;
  the sync script refuses to run if a secret `*.env` file is ever tracked.
- PVE API TLS verified against the pushed cluster CA (no `-k` by default).
- `remote_ip` matcher pinned to Tailscale CGNAT `100.64.0.0/10` — RFC1918 LAN traffic
  is rejected (was previously allowed via `private_ranges`).
- Least-privilege secret permissions (`pve-token.env` `600 root:root`; others
  `640 root:caddy`).
- Injection-safe secret writes (`printf` + `pct push`; no heredoc interpolation).
- Renderer validates service names/IPs/ports before emitting the Caddyfile.
- Rollback on reload failure via `Caddyfile.previous`.

### Changed

- `config.sh`: new basic-auth option (8), hidden (`-s`) secret prompts, atomic
  `write_env` helper.
- Installer / `update.sh` install dependencies from pinned `requirements.txt`.
- `install.sh`: `PVE_PROXY_REF` support for tag-pinned installs.
