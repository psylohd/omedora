# lib/parser.sh — read omedora.toml into bash globals.
#
# Single source of truth. Every other lib/* script sources this and reads
# OMEDORA_* arrays/vars. We use python3 (in stdlib since 3.11 has tomllib)
# to parse TOML so the syntax is real TOML, not a regex hack.
#
# Outputs (after `load_config <path>`):
#   OMEDORA_TARGET_USER
#   OMEDORA_COPRS=( list )
#   OMEDORA_HYPRLAND=( list )
#   OMEDORA_QUICKSHELL=( list )
#   OMEDORA_APPS=( list )
#   OMEDORA_APPS_OPTIONAL=( list )
#   OMEDORA_DMS_WEAK_DEPS
#   OMEDORA_TARGET_USER
#   OMEDORA_COPRS=( list )
#   OMEDORA_PATH_PLYMOUTH, OMEDORA_PATH_TUIGREET, OMEDORA_PATH_TUIGREET_SRC
#   OMEDORA_PATH_HYPRLAND, OMEDORA_PATH_DMS, OMEDORA_PATH_QUICKSHELL
#   OMEDORA_DMS_PLUGINS=( list )
#   OMEDORA_SERVICES_ENABLE=( list )

# `set -u` is intentionally NOT enabled — bash version differences between
# the build host and other systems cause spurious "unbound variable" errors
# on `local var` declarations without explicit init values. We rely on
# `set -e` to catch real errors, and use explicit `${var:-default}` in
# the few places where unset matters.
set -eo pipefail

# Resolve repo root from the location of this script's parent (lib/ lives
# one level under repo root). fedora_install.sh sets OMEDORA_REPO_ROOT
# explicitly; fall back to discovery if a lib/*.sh is sourced directly.
OMEDORA_REPO_ROOT="${OMEDORA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OMEDORA_CONFIG="${OMEDORA_CONFIG:-${OMEDORA_REPO_ROOT}/omedora.toml}"

load_config() {
  local cfg="${1:-${OMEDORA_CONFIG}}"
  [[ -f "$cfg" ]] || die "config not found: $cfg"

  # Single python invocation dumps every value we need as KEY=VALUE pairs
  # (lists become newline-separated) on stdout. Sourced into the shell.
  local dump
  dump="$(CONFIG_PATH="$cfg" CONFIG_ROOT="$OMEDORA_REPO_ROOT" python3 - <<'PY'
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
emit("OMEDORA_TARGET_USER", meta.get("target_user", ""))
emit("OMEDORA_META_NAME", meta.get("name", "omedora"))
emit("OMEDORA_META_DESCRIPTION", meta.get("description", ""))
coprs = cfg.get("coprs", {}).get("enable", [])
emit("OMEDORA_COPRS", coprs)

# packages
pkgs = cfg.get("packages", {})
emit("OMEDORA_HYPRLAND", pkgs.get("hyprland", {}).get("core", []))
emit("OMEDORA_QUICKSHELL", pkgs.get("quickshell", {}).get("runtime", []))
emit("OMEDORA_BUILD", pkgs.get("build", {}).get("required", []))
apps = pkgs.get("apps", {})
emit("OMEDORA_APPS", apps.get("required", []))
emit("OMEDORA_APPS_OPTIONAL", apps.get("optional_copr", []))

# dms from COPR (avengemedia/dms + avengemedia/danklinux)
dms_cfg = cfg.get("packages", {}).get("dms", {})
emit("OMEDORA_DMS_WEAK_DEPS", str(bool(dms_cfg.get("install_weak_deps", True))).lower())

# vendored tuigreet (build from source) — under [paths.repo]
vtg_cfg = cfg.get("paths", {}).get("repo", {})
emit("OMEDORA_TUIGREET_REPO_URL",  vtg_cfg.get("vendored_tuigreet_repo_url", ""))
emit("OMEDORA_TUIGREET_BRANCH",    vtg_cfg.get("vendored_tuigreet_branch", ""))
emit("OMEDORA_TUIGREET_COMMIT",    vtg_cfg.get("vendored_tuigreet_commit", ""))

# flatpak
fp = cfg.get("flatpak", {})
emit("OMEDORA_FLATPAK_SYSTEM", fp.get("system", []))
emit("OMEDORA_FLATPAK_USER", fp.get("user", []))

# greeter
g = cfg.get("greeter", {})
emit("OMEDORA_GREETER_BACKEND", g.get("backend", "tuigreet"))

# paths
def repo_abs(rel):
    if not rel:
        return ""
    p = pathlib.Path(rel)
    return str(p if p.is_absolute() else (pathlib.Path(root) / p))

p = cfg.get("paths", {}).get("repo", {})
emit("OMEDORA_PATH_PLYMOUTH", repo_abs(p.get("plymouth", "plymouth")))
emit("OMEDORA_PATH_TUIGREET", repo_abs(p.get("tuigreet", "tuigreet")))
emit("OMEDORA_PATH_TUIGREET_SRC", repo_abs(p.get("tuigreet_src", "")))
emit("OMEDORA_PATH_HYPRLAND", repo_abs(p.get("hyprland", "hyprland")))
emit("OMEDORA_PATH_DMS", repo_abs(p.get("dms", "DankMaterialShell")))
emit("OMEDORA_PATH_QUICKSHELL", repo_abs(p.get("quickshell", "quickshell")))

# dms plugins
dp = cfg.get("dms_plugins", {})
emit("OMEDORA_DMS_PLUGINS", dp.get("plugins", []))
emit("OMEDORA_DMS_REGISTRY", dp.get("registry", []))

# userdirs — extra dir names appended to ~/.config/user-dirs.dirs
# (in addition to the eight standard dirs xdg-user-dirs-update writes).
userdirs_cfg = cfg.get("userdirs", {})
emit("OMEDORA_USERDIR_DEV",      userdirs_cfg.get("xdg_dev_dir", "dev"))
emit("OMEDORA_USERDIR_PROJECTS", userdirs_cfg.get("xdg_projects_dir", "projects"))
emit("OMEDORA_USERDIR_PROGRAMS", userdirs_cfg.get("xdg_programs_dir", "programs"))

# plymouth device_scale override (0 = script auto-derives from fb_w)
emit("OMEDORA_PLYMOUTH_DEVICE_SCALE", cfg.get("plymouth", {}).get("device_scale", 0))

# services
svc = cfg.get("services", {})
emit("OMEDORA_SERVICES_ENABLE", svc.get("enable", []))
emit("OMEDORA_SERVICES_DEFAULT", svc.get("set_default", "graphical.target"))

# greeter.outputs — per-monitor config list used by stage-greetd.sh
# to emit `[[outputs]]` blocks in tuigreet's /etc/tuigreet/config.toml.
# Each entry is a pipe-delimited string so bash can array-append it.
gr = cfg.get("greeter", {})
if gr.get("backend", "") == "tuigreet":
    outputs = gr.get("outputs", [])
    print("OMEDORA_GREETER_OUTPUTS=( )")
    for o in outputs:
        connector = o.get("connector", "").replace("|", " ")
        enabled   = "true" if o.get("enabled", True)  else "false"
        primary   = "true" if o.get("primary", False) else "false"
        print(f"OMEDORA_GREETER_OUTPUTS+=( 'connector={connector}|enabled={enabled}|primary={primary}' )")

stg = cfg.get("stages", {})
for k, v in stg.items():
    emit(f"OMEDORA_STAGE_{k.upper()}", "true" if v else "false")
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
  if [[ -z "${OMEDORA_TARGET_USER}" ]]; then
    local detected
    detected="$(awk -F: '$3 >= 1000 && $3 < 60000 \
      && $7 !~ /(nologin|false)$/ \
      && $6 ~ /^\/home\// \
      { print $1 }' /etc/passwd)"
    local count
    count="$(printf '%s\n' "${detected}" | grep -c .)"
    if [[ "${count}" -eq 1 ]]; then
      OMEDORA_TARGET_USER="${detected}"
      info "auto-detected target_user=${OMEDORA_TARGET_USER} (set [meta].target_user in omedora.toml to override)"
    else
      die "couldn't auto-detect target_user: found ${count} candidate(s) in /etc/passwd:
${detected:-<none>}
Set [meta].target_user = \"<your-username>\" in omedora.toml."
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
  local flag="OMEDORA_STAGE_${name^^}"
  local on="${!flag:-true}"
  if [[ "$on" != "true" ]]; then
    info "stage '${name}' disabled in omedora.toml — skipping"
    return 0
  fi
  info "running stage: ${name}"
  "$@"
}
