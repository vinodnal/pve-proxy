#!/usr/bin/env bash
# pve-proxy status collector & display.
#
# Usage:
#   pve-proxy-status.sh           human-readable dashboard
#   pve-proxy-status.sh --json    machine-readable aggregate (collector mode)
#   pve-proxy-status.sh --tail    tail the central log
#
# Aggregates live systemd/caddy state + component state files written by
# pve-proxy-sync.sh / pve-proxy-dns.sh and prints one clear picture. Secrets
# are never printed: only presence/length for token values.
set -Eeuo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PP_COMPONENT=status
if [ -f /usr/local/lib/pve-proxy/common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/pve-proxy/common.sh
fi

MODE="${1:-human}"
CFG_DIR=/etc/pve-proxy
CADDYFILE=/etc/caddy/Caddyfile
LOG_FILE="${PP_LOG_FILE:-/var/log/pve-proxy/pve-proxy.log}"
PP_STATE_DIR="${PP_STATE_DIR:-/var/lib/pve-proxy/state}"

human() { [ "$MODE" = "human" ]; }
json()   { [ "$MODE" = "--json" ]; }

# ── raw collectors (never fail the whole report) ─────────────
caddy_active()   { systemctl is-active caddy 2>/dev/null || echo unknown; }
caddy_version()  { /usr/local/bin/caddy version 2>/dev/null | awk '{print $1}' || echo "n/a"; }
caddy_pid()      { systemctl show -p MainPID --value caddy 2>/dev/null || echo 0; }
tailscale_ip()   { tailscale ip -4 2>/dev/null | head -n1 | tr -d '\r' || true; }
tailscale_state(){ tailscale status --json 2>/dev/null | grep -m1 -oP '"BackendState":\s*"\K[^"]+' || echo "not connected"; }

count_generated_blocks() {
  [ -f "$CADDYFILE" ] || { echo 0; return; }
  grep -c '^    @[a-z0-9]' "$CADDYFILE" 2>/dev/null || echo 0
}

read_state() { # read_state <name> -> json string or ""
  local f="$PP_STATE_DIR/$1.json"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

state_field() { # state_field <name> <key>
  read_state "$1" | /opt/pve-proxy/.venv/bin/python -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get(sys.argv[1], ""))
except Exception:
    print("")
' "$2" 2>/dev/null || true
}

certs_info() {
  # <not_before> <not_after> pairs from caddy admin API; prints "subject|days"
  curl -sf --max-time 5 http://localhost:2019/certificates 2>/dev/null \
    | /opt/pve-proxy/.venv/bin/python -c '
import json,sys
from datetime import datetime,timezone
try:
    data=json.load(sys.stdin)
except Exception:
    print("(admin API unavailable)")
    raise SystemExit
for c in data.get("certificates", []):
    leaf=c.get("certificate", {})
    na=leaf.get("not_after","")
    try:
        exp=datetime.fromisoformat(na.replace("Z","+00:00"))
        days=(exp-datetime.now(timezone.utc)).total_seconds()/86400
        print(f"{leaf.get('subject','?')} | {int(days)}d")
    except Exception:
        continue
' 2>/dev/null || echo "(no certs yet)"
}

env_field_len() { # env_field_len <file> <key> -> length or -1
  local f="$CFG_DIR/$1"
  [ -f "$f" ] || { echo "missing"; return; }
  local v
  v="$(grep -oP "^$2=\K.*" "$f" 2>/dev/null | head -n1 || true)"
  if [ -n "$v" ]; then echo "set (len ${#v})"; else echo "empty"; fi
}

# ── human dashboard ──────────────────────────────────────────
dashboard() {
  local last_ok last_err last_ts
  last_ts="$(state_field sync ts)"
  last_ok="$(state_field sync ok)"
  last_err="$(state_field sync error)"
  [ -n "$last_ts" ] || last_ts="never (check /var/log/pve-proxy/pve-proxy.log)"
  [ -n "$last_ok" ] || last_ok="unknown"

  local active ver pid tip tstate
  active="$(caddy_active)"; ver="$(caddy_version)"; pid="$(caddy_pid)"
  tip="$(tailscale_ip)"; tstate="$(tailscale_state)"

  echo ""
  echo "== pve-proxy status =="
  printf '  %-22s %s\n' "Caddy service:" "$active (pid ${pid:-0}, ${ver})"
  printf '  %-22s %s\n' "Caddy config:" "$([ -f "$CADDYFILE" ] && echo present || echo 'MISSING (run sync)')"
  printf '  %-22s %s\n' "Managed routes:" "$(count_generated_blocks)"
  printf '  %-22s %s\n' "Last sync:" "${last_ts}"
  printf '  %-22s %s\n' "Sync result:" "${last_ok}${last_err:+ ($last_err)}"
  printf '  %-22s %s\n' "Tailscale:" "${tstate} ${tip}"
  echo ""
  echo "== configuration =="
  printf '  %-22s %s\n' "PVE host:" "$(env_field_len pve-token.env PVE_HOST)"
  printf '  %-22s %s\n' "PVE token id:" "$(env_field_len pve-token.env PVE_TOKEN_ID)"
  printf '  %-22s %s\n' "PVE token secret:" "$(env_field_len pve-token.env PVE_TOKEN_SECRET)"
  printf '  %-22s %s\n' "Domain:" "$(env_field_len proxy.env DOMAIN)"
  printf '  %-22s %s\n' "ACME email:" "$(env_field_len proxy.env EMAIL)"
  printf '  %-22s %s\n' "Cloudflare token:" "$(env_field_len cloudflare.env CLOUDFLARE_API_TOKEN)"
  printf '  %-22s %s\n' "PVE CA bundle:" "$([ -f "$CFG_DIR/pve-ssl-ca.pem" ] && echo present || echo missing)"
  printf '  %-22s %s\n' "services.yaml:" "$([ -f "$CFG_DIR/services.yaml" ] && echo present || echo missing)"
  echo ""
  echo "== scheduler =="
  printf '  %-22s %s\n' "cron:" "$(systemctl is-active cron 2>/dev/null || echo unknown)"
  printf '  %-22s %s\n' "cron entry:" "$([ -f /etc/cron.d/pve-proxy-sync ] && echo present || echo missing)"
  echo ""
  echo "== certificates (via caddy admin API) =="
  while IFS= read -r line; do printf '  %s\n' "$line"; done < <(certs_info)
  echo ""
  echo "== log =="
  echo "  ${LOG_FILE}"
  tail -n 6 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
  echo ""
}

# ── collector mode ───────────────────────────────────────────
collector_json() {
  /opt/pve-proxy/.venv/bin/python - "$LOG_FILE" <<'PYEOF'
import json, os, sys
log = sys.argv[1]
base = "/var/lib/pve-proxy/state"
out = {"ts": None, "caddy": {}, "config": {}, "scheduler": {}, "tailscale": {}, "certs": []}
def state(name):
    try:
        with open(os.path.join(base, name + ".json")) as f:
            return json.load(f)
    except Exception:
        return {}
def envfile(name):
    p = "/etc/pve-proxy/" + name
    out = {}
    try:
        for line in open(p):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    except Exception:
        pass
    return out
def envlen(name, key):
    d = envfile(name)
    v = d.get(key, None)
    return "set" if v not in (None, "") else ("empty" if key in d else "missing")
out["state"] = state("sync")
out["config"]["cloudflare_token"] = envlen("cloudflare.env", "CLOUDFLARE_API_TOKEN")
out["config"]["pve_token"] = envlen("pve-token.env", "PVE_TOKEN_SECRET")
out["config"]["pve_host"] = envfile("pve-token.env").get("PVE_HOST", "")
out["config"]["domain"] = envfile("proxy.env").get("DOMAIN", "")
out["config"]["email"] = envfile("proxy.env").get("EMAIL", "")
out["config"]["ca_present"] = os.path.exists("/etc/pve-proxy/pve-ssl-ca.pem")
out["config"]["services_yaml"] = os.path.exists("/etc/pve-proxy/services.yaml")
out["config"]["caddyfile"] = os.path.exists("/etc/caddy/Caddyfile")
out["caddy"]["active"] = os.popen("systemctl is-active caddy 2>/dev/null").read().strip() or "unknown"
out["caddy"]["pid"] = os.popen("systemctl show -p MainPID --value caddy 2>/dev/null").read().strip() or "0"
out["caddy"]["version"] = os.popen("/usr/local/bin/caddy version 2>/dev/null").read().split()[0] if os.popen("/usr/local/bin/caddy version 2>/dev/null").read() else "n/a"
out["scheduler"]["cron_active"] = (os.popen("systemctl is-active cron 2>/dev/null").read().strip() == "active")
out["scheduler"]["entry"] = os.path.exists("/etc/cron.d/pve-proxy-sync")
out["tailscale"]["state"] = os.popen("tailscale status --json 2>/dev/null").read()
try:
    ts = json.loads(out["tailscale"]["state"])
    out["tailscale"]["state"] = ts.get("BackendState", "unknown")
except Exception:
    out["tailscale"]["state"] = "not connected"
out["tailscale"]["ip"] = os.popen("tailscale ip -4 2>/dev/null | head -n1").read().strip()
print(json.dumps(out, indent=2))
PYEOF
}

case "$MODE" in
  --json) collector_json ;;
  --tail) echo "== $LOG_FILE =="; tail -n 30 "$LOG_FILE" 2>/dev/null || echo "(no log yet)";;
  *) dashboard ;;
esac
