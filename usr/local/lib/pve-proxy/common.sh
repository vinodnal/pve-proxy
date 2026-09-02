#!/usr/bin/env bash
# pve-proxy shared runtime library: centralized logging, component state, and
# guardrail helpers. Source it from any pve-proxy script, e.g.:
#     PP_COMPONENT=sync; . /usr/local/lib/pve-proxy/common.sh; pp_init
#
# Provides:
#   * pp_init          - create log/state directories (idempotent)
#   * pp_info/pp_ok/pp_warn/pp_err - timestamped, level-tagged logging to the
#     central log file + journald, and to stdout/stderr unless PP_QUIET=1.
#   * pp_die           - log an error and exit non-zero (graceful failure)
#   * pp_write_state   - write a component JSON file for the status collector
#   * pp_require_*     - guardrail helpers with clear messages
#   * pp_env_*         - safe reading of KEY=VALUE files (never `source`d, so
#     values containing '$' such as bcrypt hashes are never expanded)
#
# This file is installed to /usr/local/lib/pve-proxy/common.sh. It is safe to
# source multiple times; it only defines functions and environment defaults.

# ── Overridable paths (kept together for testing) ────────────
PP_LOG_DIR="${PP_LOG_DIR:-/var/log/pve-proxy}"
PP_LOG_FILE="${PP_LOG_FILE:-${PP_LOG_DIR}/pve-proxy.log}"
PP_STATE_DIR="${PP_STATE_DIR:-/var/lib/pve-proxy/state}"
PP_COMPONENT="${PP_COMPONENT:-pve-proxy}"
PP_QUIET="${PP_QUIET:-0}"   # 1 = cron/non-interactive: central log/journald only

# ── Bootstrap ────────────────────────────────────────────────
pp_init() {
  mkdir -p "$PP_LOG_DIR" "$PP_STATE_DIR" 2>/dev/null || true
  touch "$PP_LOG_FILE" 2>/dev/null || true
  chmod 0640 "$PP_LOG_FILE" 2>/dev/null || true
}

pp_ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }

# ── Centralized logging ──────────────────────────────────────
# Every line is tagged [ts | component | level] so greps stay easy, and is
# mirrored to journald (logger) for `journalctl -t pve-proxy`.
pp_log() { # pp_log <LEVEL> <message...>
  local level="$1"; shift
  local line sev
  line="$(pp_ts) | ${PP_COMPONENT} | ${level} | $*"
  printf '%s\n' "$line" >> "$PP_LOG_FILE" 2>/dev/null || true
  case "$level" in
    ERROR) sev=err ;;
    WARN)  sev=warning ;;
    *)     sev=info ;;
  esac
  if command -v logger >/dev/null 2>&1; then
    logger -t "pve-proxy[$$]" -p "user.$sev" -- "$*" 2>/dev/null || true
  fi
  if [ "$PP_QUIET" != "1" ]; then
    case "$level" in
      ERROR) printf '\033[31mERROR: %s\033[0m\n' "$*" >&2 ;;
      WARN)  printf '\033[33mWARN: %s\033[0m\n' "$*" >&2 ;;
      OK)    printf '\033[1;92mOK: %s\033[0m\n' "$*" ;;
      INFO)  printf '%s\n' "$*" ;;
      *)     printf '%s\n' "$*" ;;
    esac
  fi
}

pp_info() { pp_log INFO "$*"; }
pp_ok()   { pp_log OK   "$*"; }
pp_warn() { pp_log WARN "$*"; }
pp_err()  { pp_log ERROR "$*"; }
pp_die()  { pp_err "$*"; exit 1; }   # graceful failure: log + non-zero exit

# ── Component state (consumed by pve-proxy-status.sh) ────────
# Each component writes <PP_STATE_DIR>/<name>.json atomically (tmp + mv).
pp_write_state() { # pp_write_state <name> <json>
  local name="$1" json="$2" tmp
  mkdir -p "$PP_STATE_DIR" 2>/dev/null || true
  tmp="$(mktemp "${PP_STATE_DIR}/.${name}.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$json" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "${PP_STATE_DIR}/${name}.json"
}

# ── Guardrails ───────────────────────────────────────────────
pp_require_root() {
  [ "$(id -u)" = "0" ] || pp_die "must run as root (uid 0), got uid $(id -u)"
}

pp_require_cmd() { # pp_require_cmd <cmd> [purpose]
  command -v "$1" >/dev/null 2>&1 || pp_die "required command not found: $1${2:+ ($2)}"
}

pp_require_file() { # pp_require_file <path> [purpose]
  [ -f "$1" ] || pp_die "required file missing: $1${2:+ ($2)}"
}

pp_require_nonempty_file() { # pp_require_nonempty_file <path> [purpose]
  [ -s "$1" ] || pp_die "required file is empty: $1${2:+ ($2)}"
}

# ── Safe KEY=VALUE reads (never `source` — values may contain '$') ──
# These read one line per key. If a file holds multiple values per key they
# must be de-duplicated by the writer (they always are in this project).
pp_env_value() { # pp_env_value <file> <key>  -> prints value ("" if absent)
  grep -oP "^${2}=\K.*" "$1" 2>/dev/null | head -n1 || true
}

pp_env_value_set() { # pp_env_value_set <file> <key> -> 0 if non-empty
  local v
  v="$(pp_env_value "$1" "$2")"
  [ -n "$v" ]
}

pp_env_status() { # pp_env_status <file> <key> -> "set" | "empty" | "missing"
  if [ ! -f "$1" ]; then echo "missing"; return 0; fi
  if pp_env_value_set "$1" "$2"; then echo "set"; else echo "empty"; fi
}

# Normalize a KEY=VALUE file in place: strip CR, drop malformed lines (empty
# keys) so systemd EnvironmentFile never chokes on garbage.
pp_normalize_env() { # pp_normalize_env <file>
  [ -f "$1" ] || return 0
  sed -i -e 's/\r$//' -e '/^[[:space:]]*=[[:space:]]*$/d' -e '/^[[:space:]]*$/d' "$1" 2>/dev/null || true
}
