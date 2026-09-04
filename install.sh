#!/bin/bash
# install.sh — Omedora post-install entrypoint for Fedora Server.
#
# Reads omedora.toml, then runs each enabled stage in order. Designed for
# the workflow:
#
#   1. Install Fedora Server (DVD ISO, minimal layout, no DE).
#   2. Create your desktop user + set password.
#   3. Edit omedora.toml — set [meta].target_user.
#   4. sudo ./install.sh
#
# Usage:
#   sudo ./install.sh                  # full run
#   sudo ./install.sh --config PATH    # alternate config
#   sudo ./install.sh --dry-run        # show stages, do nothing
#   sudo ./install.sh --only dnf,vendor
#   sudo ./install.sh --skip greetd
#
# Re-running is safe: every stage is idempotent (timestamped .bak on
# conflicts, services re-enabled are no-ops, packages already installed
# are skipped by dnf5).
#
# For surgical tweaks after a full install (re-apply one stage, etc.),
# use ./tweaks.sh.

# -u omitted: see lib/parser.sh for rationale.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OMEDORA_REPO_ROOT="${SCRIPT_DIR}"

# ── CLI parsing ───────────────────────────────────────────────────────────────
DRY_RUN=false
NO_REBOOT=false

ONLY=""
SKIP=""
usage() {
  cat <<USAGE
Usage: sudo ./install.sh [options]

Options:
  --config PATH      use a non-default omedora.toml
  --dry-run          print what would happen, do nothing
  --only stages      comma-separated list of stages to run (e.g. dnf,vendor)
  --skip stages      comma-separated list of stages to skip
  --no-reboot        skip the automatic reboot at the end (e.g. for headless
                     automation that wants to do its own reboot)
  -h, --help         this help


Stages (toggleable in omedora.toml [stages]):
  copr, dnf, vendor, flatpak, plymouth, tuigreet, hyprland,
  quickshell, greetd, dms, keyring, userdirs, services, hyprland-plugins,
  hyprcapture
(configs = plymouth + tuigreet + hyprland + quickshell in one pass;
 plymouth/tuigreet/hyprland/quickshell are also accepted as aliases for configs)

Default config: ${SCRIPT_DIR}/omedora.toml
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --skip)     SKIP="$2"; shift 2 ;;
    --no-reboot) NO_REBOOT=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Load config + helpers ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/parser.sh"
source "${SCRIPT_DIR}/lib/self-check.sh"
for _stage in copr dnf vendor flatpak configs greetd dms keyring userdirs services hyprland-plugins hyprcapture wallpapers; do
  source "${SCRIPT_DIR}/lib/stage-${_stage}.sh"
done

# Monitor detection (used by stage-greetd.sh to default-enable the
# largest connected output). Doesn't read /sys itself unless called —
# pure functions + raw sysfs reads at the moment of invocation.
source "${SCRIPT_DIR}/lib/detect-monitors.sh"

load_config

# Apply --only / --skip overrides to the stage flags.
apply_stage_filter() {
  local s
  # When --only is passed, reset all known stages to false first so --only
  # starts from a known-clean slate. Without --only, leave the TOML-emitted
  # values alone (don't disable what the user explicitly enabled).
  #
  # plymouth/tuigreet/hyprland/quickshell are accepted as aliases for the
  # 'configs' stage (which runs all four in one pass). The iteration list
  # below contains both names so users can pass either via --only.
  if [[ -n "${ONLY}" ]]; then

    for s in copr dnf vendor flatpak plymouth tuigreet hyprland quickshell configs greetd dms keyring userdirs services hyprland-plugins hyprcapture wallpapers; do
      printf -v "$(stage_flag_name "${s}")" "false"
    done
    IFS=',' read -ra list <<< "${ONLY}"
    for s in "${list[@]}"; do
      case "${s,,}" in
        # Sub-stage aliases: enable the sub-stage, its parent (configs), and
        # any hard dependencies the sub-stage requires to function.
        plymouth)
          printf -v "OMEDORA_STAGE_PLYMOUTH" "true"
          printf -v "OMEDORA_STAGE_CONFIGS" "true" ;;
        tuigreet)
          # tuigreet binary is installed by the dnf stage; greetd needs it.
          printf -v "OMEDORA_STAGE_DNF" "true"
          printf -v "OMEDORA_STAGE_TUIGREET" "true"
          printf -v "OMEDORA_STAGE_GREETD" "true"
          printf -v "OMEDORA_STAGE_CONFIGS" "true" ;;
        hyprland)
          printf -v "OMEDORA_STAGE_HYPRLAND" "true"
          printf -v "OMEDORA_STAGE_CONFIGS" "true" ;;
        quickshell)
          printf -v "OMEDORA_STAGE_DNF" "true"
          printf -v "OMEDORA_STAGE_QUICKSHELL" "true"
          printf -v "OMEDORA_STAGE_CONFIGS" "true" ;;
        dms)
          # dms binary + greeter binary come from the vendor stage.
          printf -v "OMEDORA_STAGE_DNF" "true"
          printf -v "OMEDORA_STAGE_VENDOR" "true"
          printf -v "OMEDORA_STAGE_DMS" "true" ;;
        hyprland-plugins)
          # Pure-Lua Hyprland plugins (cloned to ~/.config/hypr/plugins/).
          printf -v "OMEDORA_STAGE_HYPRLAND_PLUGINS" "true" ;;
        hyprcapture)
          printf -v "OMEDORA_STAGE_DNF" "true"
          printf -v "OMEDORA_STAGE_HYPRCAPTURE" "true" ;;
        wallpapers)
          # Pure file copy, no dependencies. Uses OMEDORA_PATH_WALLPAPERS.
          printf -v "OMEDORA_STAGE_WALLPAPERS" "true" ;;
        *)
          local var
          var="$(stage_flag_name "${s}")"
          printf -v "${var}" "true" ;;
      esac
    done
  fi
}
if [[ -n "${SKIP}" ]]; then
  IFS=',' read -ra list <<< "${SKIP}"
  for s in "${list[@]}"; do
    var="$(stage_flag_name "${s}")"
    printf -v "${var}" "false"
  done
fi


if ! command -v dnf5 >/dev/null 2>&1; then
  die "dnf5 not found — this installer targets Fedora Server."
fi
if ! grep -q '^ID=fedora' /etc/os-release 2>/dev/null; then
  warn "this doesn't look like Fedora (/etc/os-release ID != fedora). Continuing anyway."
fi

# Sanity: confirm greeter backend is sane.
case "${OMEDORA_GREETER_BACKEND}" in
  tuigreet|dms-greeter) ;;
  *) die "unknown greeter backend: ${OMEDORA_GREETER_BACKEND} (expected 'tuigreet' or 'dms-greeter')" ;;
esac

# ── Plan ──────────────────────────────────────────────────────────────────────

section "omedora ${OMEDORA_META_NAME}"
echo "  target user: ${OMEDORA_TARGET_USER}"
echo "  greeter:     ${OMEDORA_GREETER_BACKEND}"
echo "  repo root:   ${OMEDORA_REPO_ROOT}"
echo "  config:      ${OMEDORA_CONFIG}"
for s in copr dnf vendor flatpak plymouth tuigreet hyprland quickshell greetd dms keyring userdirs services hyprland-plugins hyprcapture wallpapers; do
  f="$(stage_flag_name "${s}")"
  v="${!f:-false}"
  if [[ "${s}" == "plymouth" ]] || [[ "${s}" == "tuigreet" ]] || \
     [[ "${s}" == "hyprland" ]] || [[ "${s}" == "quickshell" ]]; then
    [[ "${v}" == "true" ]] && parent="(via configs)" || parent=""
    printf "    %-12s %s %s\n" "${s}" "${v}" "${parent}"
  else
    printf "    %-12s %s\n" "${s}" "${v}"
  fi
done

if ${DRY_RUN}; then
  info "dry-run — exiting before any change"
  exit 0
fi
# ── Self-check (before destructive work) ─────────────────────────────────────
self_check
# ── Run stages ────────────────────────────────────────────────────────────────
run_stage copr       stage_copr
run_stage dnf        stage_dnf
run_stage vendor     stage_vendor
run_stage flatpak    stage_flatpak
run_stage greetd     stage_greetd       # wire /etc/greetd/config.toml + start-hyprland
run_stage configs    stage_configs      # plymouth + tuigreet + hyprland + quickshell in one pass
run_stage dms        stage_dms          # DankMaterialShell config + plugins
run_stage hyprland-plugins stage_hyprland_plugins  # clone Lua plugins to ~/.config/hypr/plugins/
run_stage hyprcapture stage_hyprcapture  # hyprpm add HyprCapture + build .so + helper
run_stage keyring    stage_keyring      # GNOME keyring auto-unlock at greetd login
run_stage userdirs   stage_user_dirs    # default XDG dirs + custom dev/projects/programs
run_stage services   stage_services
run_stage wallpapers stage_wallpapers     # repo wallpapers/ → $HOME/Pictures/wallpapers/
# ── Done ──────────────────────────────────────────────────────────────────────
cat <<DONE

Next steps:
  1. Reboot:   systemctl reboot
  2. Greetd → tuigreet (or dms-greeter) → Hyprland → dms via exec-once.
  3. If Plymouth doesn't load: dracut -f --regenerate-all
  4. To re-run only a stage:  sudo ./install.sh --only vendor

All installed files live under:
  /usr/share/plymouth/themes/omedora
  /etc/tuigreet/                /usr/local/bin/tuigreet
  /etc/greetd/config.toml       /usr/bin/start-hyprland
  /usr/local/bin/{dms,dgop}
  ~${OMEDORA_TARGET_USER}/.config/hypr/
  ~${OMEDORA_TARGET_USER}/.config/quickshell/

Backups of overwritten files have timestamped .bak.<date> suffixes.
DONE

# ── Auto-reboot ──────────────────────────────────────────────────────────────
# Greetd is system-level and won't see its new /etc/greetd/config.toml + the
# freshly-installed Hyprland binary unless the kernel brings everything up
# from scratch. The user shouldn't have to type `sudo systemctl reboot` —
# we do it for them, with a 5-second grace period for anyone reading the
# install log tail on a serial console.
#
# Skipped automatically when --dry-run is set, when the user has the
# OMEDORA_NO_REBOOT=1 env var (used by CI / tweaks.sh), or when not on a
# TTY (so headless ssh invocations don't accidentally reboot the box).
if ${DRY_RUN} || ${NO_REBOOT}; then
  info "--dry-run / --no-reboot — skipping automatic reboot. Run \`sudo systemctl reboot\` to finish."
elif [[ ! -t 1 ]]; then
  # not a TTY (e.g. piped to a file or run from systemd): don't surprise
  # whoever's downstream by yanking the machine out from under them.
  warn "non-TTY invocation — automatic reboot suppressed. Run \`sudo systemctl reboot\` when ready."
else
  echo
  echo -e "${RED}Rebooting in 5 seconds. Ctrl-C to cancel.${RST}"
  sleep 5
  systemctl reboot || warn "systemctl reboot failed (returned $?). Run it manually."
fi
