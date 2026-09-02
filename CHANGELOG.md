# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [1.3.0] - 2026-09-02

### Added

- **Tailscale menu** in `config.sh` (option 10): status/IP, join/authenticate,
  set node name & tags, route via an exit node, leave the tailnet.
- **Advanced menu** in `config.sh` (option 11): a `settings.env` layer with
  sync schedule (rewrites the cron entry), PVE API TLS verification toggle,
  extra trusted client subnets (beyond Tailscale), and an optional ACME CA
  endpoint. `pve-proxy-sync.sh`/`render_caddyfile.py` read these and render them
  into the Caddyfile (defaults keep output identical when unset).

## [1.2.2] - 2026-09-02

### Fixed

- `config.sh` / `update.sh` / `pve-proxy-*` were "command not found" inside the
  container's interactive (`pct enter`) shell: that shell is non-login, never
  reads `/etc/profile`, and its `PATH` omitted `/usr/local/bin` (where the tools
  are installed). The installer now appends a `PATH` guard to `/etc/bash.bashrc`
  so the admin commands run by bare name.
- `update.sh` no longer hangs on an interactive prompt (e.g. git credentials /
  repo URL): it runs git non-interactively (`GIT_TERMINAL_PROMPT=0`) and, if no
  `origin` is configured, defaults to the canonical repo URL and degrades to
  local files when offline.

## [1.2.1] - 2026-09-02

### Fixed

- `update.sh` no longer aborts when run from its own repo dir: it tried to `cp`
  files onto themselves under `/root/pve-proxy` ("same file"), which failed under
  `set -e`. Removed the redundant self-copies (git keeps `/root/pve-proxy` current).
- `config.sh` and `update.sh` are now reachable as bare commands (symlinked into
  `/usr/local/bin`, which is on `PATH` in the container) instead of requiring
  `bash /root/pve-proxy/<name>.sh`.

## [1.2.0] - 2026-09-02

### Added

- **Central logging** (`/usr/local/lib/pve-proxy/common.sh`): all components
  (`sync`, `dns`, `update`, `install`, `status`) log timestamped, level-tagged
  lines to `/var/log/pve-proxy/pve-proxy.log` and mirror to journald.
- **Status collector & display** (`pve-proxy-status.sh`): one dashboard showing
  Caddy state, last sync result, config presence, scheduler, and cert expiry
  (`--json` for machine use, `--tail` for the log). Tokens shown as set/empty only.
- **Component state files** under `/var/lib/pve-proxy/state/*.json` written
  atomically on both success and every failure, so status never shows stale data.
- `etc/logrotate.d/pve-proxy` rotation for the central and legacy logs.
- Graceful-failure guardrails: guards log the reason, write failure state, and
  never touch live config; cron runs with `PP_QUIET=1` (no mail spam).

### Fixed

- **Cron PATH bug (root cause of silent failure):** cron/systemd supply a minimal
  `PATH` that omits `/usr/local/bin`, so every scheduled sync died with
  `caddy binary not found` and never generated the Caddyfile. All scripts now
  export a fixed `PATH` and use `pp_require_cmd` with a clear message.
- First-sync / caddy-start failures are no longer silently swallowed: installer
  and update paths log and surface the error with remediation hints.
- `services.yaml` is never overwritten on reinstall/update (seeded once).

- Installer: replaced the per-file `pct push` loop with a single `tar | pct exec`
  stream (a transient `pct exec` failure could previously drop a file and abort);
  added post-push guards for key files.
- Caddy pinned to `v2.11.4`: the `caddy-dns/cloudflare` plugin `v0.2.4` is built
  against Caddy 2.7.5 and **panics at runtime in the TLS module loader** with
  Caddy 2.10.2. `v2.11.4` loads the plugin cleanly (verified end-to-end).

## [1.1.0] - 2026-08-31

### Added

- Fully automatic setup: the **PVE API token is auto-created** at install (no key to
  provide); an optional Tailscale pre-auth key enables zero-step post-install
  (auto-join tailnet, auto DNS record, first sync, Caddy start).
- `pve-proxy-dns.sh`: creates/updates the Cloudflare wildcard `*.domain` A record
  (also available as `config.sh` → 9).
- Optional Cloudflare token auto-minting from a Global API Key (key is used in
  memory only, never stored).

### Changed

- Cloudflare token scope: `Zone:Read` + `Zone:DNS:Edit` (Zone:Read added for the
  automatic DNS record).
- Install prompts simplified; PVE host auto-detected from the node.
- Secret scan in `scripts/check.sh` no longer flags token IDs or placeholders.

## [1.0.0] - 2026-08-30

Initial hardened release.

### Added

- Auto-sync cron: pulls running LXCs from the PVE API every 15 minutes and renders a
  single-wildcard-cert Caddyfile (DNS-01 via Cloudflare, no CT-log name leaks).
- `basicauth` for sensitive services (username `admin`, bcrypt hash from
  `BASIC_AUTH_HASH`) — now actually enforced end-to-end.
- Access logging to `/var/log/caddy/access.log` (rotated, JSON).
- Certificate-expiry alerting via the Caddy admin API (warns via journald < 14 days).
- Pinned toolchain: Caddy `v2.11.4`, xcaddy `v0.4.7`, cloudflare DNS plugin `v0.2.4`,
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
