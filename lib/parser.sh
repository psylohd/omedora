# lib/parser.sh — read nokron.toml into bash globals.
#
# Single source of truth. Every other lib/* script sources this and reads
# NOKRON_* arrays/vars. We use python3 (in stdlib since 3.11 has tomllib)
# to parse TOML so the syntax is real TOML, not a regex hack.
#
# Outputs (after `load_config <path>`):
#   NOKRON_TARGET_USER
#   NOKRON_COPRS=( list )
#   NOKRON_HYPRLAND=( list )
#   NOKRON_QUICKSHELL=( list )
#   NOKRON_APPS=( list )
#   NOKRON_APPS_OPTIONAL=( list )
#   NOKRON_DMS_WEAK_DEPS
#   NOKRON_TARGET_USER
#   NOKRON_COPRS=( list )
#   NOKRON_PATH_PLYMOUTH, NOKRON_PATH_TUIGREET, NOKRON_PATH_TUIGREET_SRC
#   NOKRON_PATH_HYPRLAND, NOKRON_PATH_DMS, NOKRON_PATH_QUICKSHELL
#   NOKRON_DMS_PLUGINS=( list )
#   NOKRON_SERVICES_ENABLE=( list )

# `set -u` is intentionally NOT enabled — bash version differences between
# the build host and other systems cause spurious "unbound variable" errors
# on `local var` declarations without explicit init values. We rely on
# `set -e` to catch real errors, and use explicit `${var:-default}` in
# the few places where unset matters.
set -eo pipefail

# Resolve repo root from the location of this script's parent (lib/ lives
# one level under repo root). fedora_install.sh sets NOKRON_REPO_ROOT
# explicitly; fall back to discovery if a lib/*.sh is sourced directly.
NOKRON_REPO_ROOT="${NOKRON_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NOKRON_CONFIG="${NOKRON_CONFIG:-${NOKRON_REPO_ROOT}/nokron.toml}"

load_config() {
  local cfg="${1:-${NOKRON_CONFIG}}"
  [[ -f "$cfg" ]] || die "config not found: $cfg"

  # Single python invocation dumps every value we need as KEY=VALUE pairs
  # (lists become newline-separated) on stdout. Sourced into the shell.
  local dump
  dump="$(CONFIG_PATH="$cfg" CONFIG_ROOT="$NOKRON_REPO_ROOT" python3 - <<'PY'
import os, sys, tomllib, pathlib

with open(os.environ["CONFIG_PATH"], "rb") as f:
    cfg = tomllib.load(f)

root = os.environ["CONFIG_ROOT"]

def emit(key, value):
    if isinstance(value, bool):
        print(f"{key}={'true' if value else 'false'}")
    elif isinstance(value, list):
        elements = ' '.join(repr(v) for v in value)
        print(f"{key}=( {elements} )")
    elif isinstance(value, dict):
        for k, v in value.items():
            safe_k = k.upper().replace('-', '_')
            print(f"{key}__{safe_k}={v!r}")
    elif isinstance(value, str):
        print(f"{key}={value!r}")
    elif value is None:
        print(f"{key}=")
    else:
        print(f"{key}={value}")

# meta
meta = cfg.get("meta", {})
emit("NOKRON_TARGET_USER", meta.get("target_user", ""))
emit("NOKRON_META_NAME", meta.get("name", "nokron"))
emit("NOKRON_META_DESCRIPTION", meta.get("description", ""))
coprs = cfg.get("coprs", {}).get("enable", [])
emit("NOKRON_COPRS", coprs)

# packages
pkgs = cfg.get("packages", {})
emit("NOKRON_HYPRLAND", pkgs.get("hyprland", {}).get("core", []))
emit("NOKRON_QUICKSHELL", pkgs.get("quickshell", {}).get("runtime", []))
emit("NOKRON_BUILD", pkgs.get("build", {}).get("required", []))
apps = pkgs.get("apps", {})
emit("NOKRON_APPS", apps.get("required", []))
emit("NOKRON_APPS_OPTIONAL", apps.get("optional_copr", []))

# dms from COPR (avengemedia/dms + avengemedia/danklinux)
dms_cfg = cfg.get("packages", {}).get("dms", {})
emit("NOKRON_DMS_WEAK_DEPS", str(bool(dms_cfg.get("install_weak_deps", True))).lower())

# vendored tuigreet (build from source) — under [paths.repo]
vtg_cfg = cfg.get("paths", {}).get("repo", {})
emit("NOKRON_TUIGREET_REPO_URL",  vtg_cfg.get("vendored_tuigreet_repo_url", ""))
emit("NOKRON_TUIGREET_BRANCH",    vtg_cfg.get("vendored_tuigreet_branch", ""))
emit("NOKRON_TUIGREET_COMMIT",    vtg_cfg.get("vendored_tuigreet_commit", ""))

# flatpak
fp = cfg.get("flatpak", {})
emit("NOKRON_FLATPAK_SYSTEM", fp.get("system", []))
emit("NOKRON_FLATPAK_USER", fp.get("user", []))

# greeter
g = cfg.get("greeter", {})
emit("NOKRON_GREETER_BACKEND", g.get("backend", "tuigreet"))

# paths
def repo_abs(rel):
    if not rel:
        return ""
    p = pathlib.Path(rel)
    return str(p if p.is_absolute() else (pathlib.Path(root) / p))

p = cfg.get("paths", {}).get("repo", {})
emit("NOKRON_PATH_PLYMOUTH", repo_abs(p.get("plymouth", "plymouth")))
emit("NOKRON_PATH_TUIGREET", repo_abs(p.get("tuigreet", "tuigreet")))
emit("NOKRON_PATH_TUIGREET_SRC", repo_abs(p.get("tuigreet_src", "")))
emit("NOKRON_PATH_HYPRLAND", repo_abs(p.get("hyprland", "hyprland")))
emit("NOKRON_PATH_DMS", repo_abs(p.get("dms", "DankMaterialShell")))
emit("NOKRON_PATH_QUICKSHELL", repo_abs(p.get("quickshell", "quickshell")))

# dms plugins
dp = cfg.get("dms_plugins", {})
emit("NOKRON_DMS_PLUGINS", dp.get("plugins", []))
emit("NOKRON_DMS_REGISTRY", dp.get("registry", []))

# services
svc = cfg.get("services", {})
emit("NOKRON_SERVICES_ENABLE", svc.get("enable", []))
emit("NOKRON_SERVICES_DEFAULT", svc.get("set_default", "graphical.target"))

# stages
stg = cfg.get("stages", {})
for k, v in stg.items():
    emit(f"NOKRON_STAGE_{k.upper()}", "true" if v else "false")
PY
)"

  # Strip python-side stderr if any leaked (none should).
  [[ -n "$dump" ]] || die "TOML parser returned empty output — invalid config?"

  # Source into the calling shell. Bash treats += as list append.
  eval "$dump"

  # Sanity: target user must be set. If the TOML left it empty, autodetect
  # by scanning /etc/passwd for exactly one human account (UID 1000-60000,
  # a real login shell, a /home/<user> home dir). If zero or multiple match,
  # fall back to a clear error pointing the user at the TOML.
  if [[ -z "${NOKRON_TARGET_USER}" ]]; then
    local detected
    detected="$(awk -F: '$3 >= 1000 && $3 < 60000 \
      && $7 !~ /(nologin|false)$/ \
      && $6 ~ /^\/home\// \
      { print $1 }' /etc/passwd)"
    local count
    count="$(printf '%s\n' "${detected}" | grep -c .)"
    if [[ "${count}" -eq 1 ]]; then
      NOKRON_TARGET_USER="${detected}"
      info "auto-detected target_user=${NOKRON_TARGET_USER} (set [meta].target_user in nokron.toml to override)"
    else
      die "couldn't auto-detect target_user: found ${count} candidate(s) in /etc/passwd:
${detected:-<none>}
Set [meta].target_user = \"<your-username>\" in nokron.toml."
    fi
  fi
}

# ── Free-standing log helpers (so sourcing this file is enough) ───────────────
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info()    { echo -e "${GRN}[+]${RST} $*"; }
section() { echo -e "\n${BLU}═══${RST} $* ${BLU}═══${RST}"; }
warn()    { echo -e "${YEL}[!]${RST} $*" >&2; }
err()     { echo -e "${RED}[✗]${RST} $*" >&2; }
die()     { err "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "this must run as root (sudo ./fedora_install.sh)"
}

run_stage() {
  local name="$1"; shift
  local flag="NOKRON_STAGE_${name^^}"
  local on="${!flag:-true}"
  if [[ "$on" != "true" ]]; then
    info "stage '${name}' disabled in nokron.toml — skipping"
    return 0
  fi
  info "running stage: ${name}"
  "$@"
}
