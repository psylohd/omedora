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
#   OMEDORA_DOCKER=( list )
#   OMEDORA_DMS_WEAK_DEPS
#   OMEDORA_PATH_PLYMOUTH, OMEDORA_PATH_TUIGREET, OMEDORA_PATH_TUIGREET_SRC
#   OMEDORA_PATH_HYPRLAND, OMEDORA_PATH_DMS, OMEDORA_PATH_QUICKSHELL
#   OMEDORA_PATH_NVIM
#   OMEDORA_DMS_PLUGINS=( list )
#   OMEDORA_HYPRLAND_PLUGINS=( list )   # git URLs cloned into ~/.config/hypr/plugins/

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

# COPR repos
coprs = cfg.get("coprs", {}).get("enable", [])
emit("OMEDORA_COPRS", coprs)

# External repos (non-COPR .repo file URLs, e.g. Docker CE)
_repos = cfg.get("repos", {}).get("enable", [])
emit("OMEDORA_REPOS", _repos)

# packages
pkgs = cfg.get("packages", {})
emit("OMEDORA_HYPRLAND", pkgs.get("hyprland", {}).get("core", []))
emit("OMEDORA_HYPRLAND_BUILD", pkgs.get("hyprland", {}).get("build", []))
emit("OMEDORA_QUICKSHELL", pkgs.get("quickshell", {}).get("runtime", []))
emit("OMEDORA_BUILD", pkgs.get("build", {}).get("required", []))
apps = pkgs.get("apps", {})
emit("OMEDORA_APPS", apps.get("required", []))
emit("OMEDORA_APPS_OPTIONAL", apps.get("optional_copr", []))

# Docker packages from [packages.docker]
_docker_pkgs = cfg.get("packages", {}).get("docker", {}).get("runtime", [])
emit("OMEDORA_DOCKER", _docker_pkgs)

# dms from COPR (avengemedia/dms + avengemedia/danklinux)
dms_cfg = cfg.get("packages", {}).get("dms", {})
emit("OMEDORA_DMS_WEAK_DEPS", str(bool(dms_cfg.get("install_weak_deps", True))).lower())

vendored_cfg = cfg.get("vendored", {})
vtg_cfg = vendored_cfg.get("tuigreet", {})
emit("OMEDORA_TUIGREET_REPO_URL",  vtg_cfg.get("repo_url", ""))
emit("OMEDORA_TUIGREET_BRANCH",    vtg_cfg.get("branch", ""))
emit("OMEDORA_TUIGREET_COMMIT",    vtg_cfg.get("commit", ""))
# flatpak
# Two scopes per the flatpak CLI: `--system` lands apps at /var/lib/flatpak
# (visible to every user; the only mode that survives a multi-user setup),
# `--user` lands at ~/.local/share/flatpak (per-user, doesn't show up in
# other users' launchers). Zen Browser lives on Flathub; we install it
# system-scope so a fresh, single-user install sees Zen in dms's launcher
# without needing per-user remote-list bootstrapping.
fp = cfg.get("flatpak", {})
emit("OMEDORA_FLATPAK_SYSTEM", fp.get("system", []))
emit("OMEDORA_FLATPAK_USER",   fp.get("user", []))

# zen_browser extensions — XPI URLs installed into the Zen Flatpak sandbox.
# This stays separate from [flatpak]; it's a list of post-install extensions,
# not Zen's own install location (which is governed by OMEDORA_FLATPAK_SYSTEM
# above). Empty list = no extensions added.
zb = cfg.get("zen_browser", {})
emit("OMEDORA_ZEN_EXTENSIONS", zb.get("extensions", []))

# vendored_repos — .repo files we ship verbatim into /etc/yum.repos.d/.
# Used when an upstream doesn't host a stable .repo URL (so `dnf5
# config-manager addrepo --from-repofile` can't fetch them) and we
# want the contents pinned in-repo. Each entry exposes:
#   repo_file  — verbatim content of the .repo file
#   package    — package name to install once the repo is enabled
# The repo filename is derived from the section key (e.g.
# `[vendored_repos.vscodium]` → /etc/yum.repos.d/vscodium.repo).
vr = cfg.get("vendored_repos", {})
for _name, _entry in vr.items():
    safe_name = _name.replace("-", "_").replace(" ", "_")
    emit(f"OMEDORA_VENDORED_REPO_{safe_name.upper()}__FILE",
         _entry.get("repo_file", ""))
    emit(f"OMEDORA_VENDORED_REPO_{safe_name.upper()}__PACKAGE",
         _entry.get("package", ""))


# greeter
g = cfg.get("greeter", {})
emit("OMEDORA_GREETER_BACKEND", g.get("backend", "tuigreet"))
# privesc — escalation tool dms-greeter install should pin via
# DMS_PRIVESC=... Valid values: sudo, doas, run0. Default 'sudo'
# matches the rest of omedora (sudo ./install.sh).
emit("OMEDORA_DMS_PRIVESC",      g.get("privesc", "sudo"))
# greeter user naming. dms-greeter ships a `greeter` user; greetd RPM
# ships `greetd`. omedora collapses the two via rename by default
# (user_mode = "rename"). Set user_mode = "leave" to skip the rename
# and keep whatever dms-greeter creates.
emit("OMEDORA_GREETER_USER_MODE", g.get("user_mode", "rename"))
def repo_abs(rel):
    if not rel:
        return ""
    p = pathlib.Path(rel)
    return str(p if p.is_absolute() else (pathlib.Path(root) / p))

p = cfg.get("paths", {}).get("repo", {})
emit("OMEDORA_PATH_PLYMOUTH",   repo_abs(p.get("plymouth", "plymouth")))
emit("OMEDORA_PATH_TUIGREET",   repo_abs(p.get("tuigreet", "tuigreet")))
emit("OMEDORA_PATH_TUIGREET_SRC", repo_abs(p.get("tuigreet_src", "")))
emit("OMEDORA_PATH_HYPRLAND",   repo_abs(p.get("hyprland", "hyprland")))
emit("OMEDORA_PATH_DMS",        repo_abs(p.get("dms", "DankMaterialShell")))
emit("OMEDORA_PATH_QUICKSHELL", repo_abs(p.get("quickshell", "quickshell")))
emit("OMEDORA_PATH_WALLPAPERS",  repo_abs(p.get("wallpapers", "wallpapers")))
emit("OMEDORA_PATH_NVIM",       repo_abs(p.get("nvim", "")))

# [hyprland].monitors — explicit per-monitor `monitor=NAME,WxH@RRR,XxY,SCALE`
# entries that stage-configs.sh appends to the deployed hyprland.lua.
# Empty list (the default) means "let dms autodetect on first launch"
# — see the comment in omedora.toml and the Scaling Note block at the
# top of hyprland.lua for why this exists.
hl_cfg = cfg.get("hyprland", {})
emit("OMEDORA_HYPRLAND_MONITORS", hl_cfg.get("monitors", []))

# dms plugins
dp = cfg.get("dms_plugins", {})
emit("OMEDORA_DMS_PLUGINS", dp.get("plugins", []))
emit("OMEDORA_DMS_REGISTRY", dp.get("registry", []))

# hyprland plugins — git URLs cloned into ~/.config/hypr/plugins/.
# Each entry is a git URL; the cloned repo lives at
# ~/.config/hypr/plugins/<basename>.git-stripped>/ and is `require`'d by
# hyprland.lua via `package.path = package.path .. ";./?.lua;./?/init.lua"`
# so a plugin named "foo" is `require("plugins.foo")`. Empty list disables
# the stage.
hp = cfg.get("hyprland_plugins", {}).get("plugins", [])
emit("OMEDORA_HYPRLAND_PLUGINS", hp)
# hyprcapture compositor plugin (hyprpm). `repo_url = ""` disables the stage.
hc = cfg.get("hyprcapture", {})
emit("OMEDORA_HYPRCAPTURE_REPO_URL", hc.get("repo_url", ""))
emit("OMEDORA_HYPRCAPTURE_BRANCH",   hc.get("branch", ""))
emit("OMEDORA_HYPRCAPTURE_COMMIT",   hc.get("commit", ""))

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

# Stage toggles
stg = cfg.get("stages", {})
for k, v in stg.items():
    # Hyphens are valid in TOML keys (e.g. "hyprland-plugins") but bash
    # variable names forbid them; emit uses underscores.
    safe_k = k.upper().replace("-", "_")
    emit(f"OMEDORA_STAGE_{safe_k}", "true" if v else "false")
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

# stage_flag_name <name> — canonical "OMEDORA_STAGE_<NAME>" form for a
# stage's OMEDORA_* flag. Replaces '-' with '_' before uppercasing
# because bash var names forbid '-' AND bash's ${var^^} only matches
# letters (a hyphen is left as-is, so ${var^^//-/_} is a no-op).
stage_flag_name() {
  printf 'OMEDORA_STAGE_%s' "${1//-/_}" | tr '[:lower:]' '[:upper:]'
}

run_stage() {
  local name="$1"; shift
  local flag
  flag="$(stage_flag_name "${name}")"
  local on="${!flag:-true}"
  if [[ "$on" != "true" ]]; then
    info "stage '${name}' disabled in omedora.toml — skipping"
    return 0
  fi
  info "running stage: ${name}"
  "$@"
}
