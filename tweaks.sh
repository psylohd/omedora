#!/bin/bash
# tweaks.sh — apply individual Omedora tweaks after a full install.
#
# `install.sh` is the big entrypoint that runs every stage on a fresh
# system. This script is the small, surgical counterpart: pick one tweak,
# apply it, see if you like it, roll back if not.
#
# Each tweak delegates to the matching lib/stage-*.sh function used by
# install.sh, so the two scripts share identical logic — tweak outcomes
# match full-install outcomes 1:1.
#
# Usage:
#   sudo ./tweaks.sh                     # list available tweaks
#   sudo ./tweaks.sh plymouth            # re-apply Plymouth omedora theme
#   sudo ./tweaks.sh greetd              # rewrite /etc/greetd/config.toml
#   sudo ./tweaks.sh hyprland            # redeploy ~/.config/hypr/
#   sudo ./tweaks.sh quickshell          # redeploy ~/.config/quickshell/
#   sudo ./tweaks.sh dms                 # redeploy DankMaterialShell config + plugins
#   sudo ./tweaks.sh services            # systemctl enable + set-default
#   sudo ./tweaks.sh --list              # same as no args
#   sudo ./tweaks.sh --diff <name>       # show what would change vs current state
#   sudo ./tweaks.sh --revert <name>     # restore .bak.<date> backups for a tweak
#
# files alongside overwritten targets (see lib/parser.sh's backup_and_*).
# `--revert <name>` restores the most recent .bak for every file that
# stage <name> would have touched.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OMEDORA_REPO_ROOT="${SCRIPT_DIR}"
export OMEDORA_CONFIG="${OMEDORA_CONFIG:-${SCRIPT_DIR}/omedora.toml}"

source "${SCRIPT_DIR}/lib/parser.sh"
source "${SCRIPT_DIR}/lib/self-check.sh"
load_config

# ── Tweaks registry ──────────────────────────────────────────────────────────
# Each entry: name → bash function that performs the tweak.
declare -A TWEAK_FN=(
  [plymouth]=tweak_plymouth
  [hyprland]=tweak_hyprland
  [quickshell]=tweak_quickshell
  [dms]=tweak_dms
  [keyring]=tweak_keyring
  [userdirs]=tweak_userdirs
  [services]=tweak_services
  [flatpak]=tweak_flatpak
  [hyprland-plugins]=tweak_hyprland_plugins
  [wallpapers]=tweak_wallpapers
  [hyprcapture]=tweak_hyprcapture
  [zsh]=tweak_zsh
)
declare -A TWEAK_DESC=(
  [plymouth]="Plymouth omedora theme (script module)"
  [greetd]="Wire /etc/greetd/config.toml + /usr/local/bin/start-hyprland"
  [hyprland]="Deploy hyprland/ → ~/.config/hypr/"
  [quickshell]="Deploy quickshell/ → ~/.config/quickshell/"
  [dms]="Deploy DankMaterialShell/ + install plugins from [dms_plugins]"
  [keyring]="Wire pam_gnome_keyring in PAM + ensure autostart entry"
  [userdirs]="xdg-user-dirs-update --force + write ~/dev, ~/projects, ~/programs"
  [services]="systemctl enable + set-default graphical.target"
  [flatpak]="Install Flatpaks from [flatpak] + refresh desktop-database cache"
  [hyprland-plugins]="Clone Lua plugins to ~/.config/hypr/plugins/"
  [hyprcapture]="hyprpm add HyprCapture + build .so + install helper"
  [zsh]="Set user shell to zsh + patch ~/.zshrc with extensions"
)

list_tweaks() {
  echo "Available tweaks:"
  for name in "${!TWEAK_FN[@]}"; do
    printf "  %-12s %s\n" "${name}" "${TWEAK_DESC[${name}]}"
  done
  echo
  echo "Use './tweaks.sh <name>' to apply, '--diff <name>' to preview, '--revert <name>' to undo."
}

# ── Each tweak wraps the matching install.sh stage logic ─────────────────────
# We re-source the lib/ scripts lazily so this file stays small and the
# logic lives in one place (the stages).

source "${SCRIPT_DIR}/lib/stage-copr.sh"
source "${SCRIPT_DIR}/lib/stage-dnf.sh"
source "${SCRIPT_DIR}/lib/stage-configs.sh"
source "${SCRIPT_DIR}/lib/stage-userdirs.sh"
source "${SCRIPT_DIR}/lib/stage-services.sh"
source "${SCRIPT_DIR}/lib/stage-flatpak.sh"
source "${SCRIPT_DIR}/lib/stage-hyprland-plugins.sh"
source "${SCRIPT_DIR}/lib/stage-wallpapers.sh"
source "${SCRIPT_DIR}/lib/stage-hyprcapture.sh"
source "${SCRIPT_DIR}/lib/detect-monitors.sh"

tweak_plymouth()   { section "tweak: plymouth";   stage_config_plymouth; }
tweak_hyprland()   {
  local home; home="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
  section "tweak: hyprland"
  stage_config_hyprland "${home}"
}
tweak_quickshell() {
  local home; home="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
  section "tweak: quickshell"
  stage_config_quickshell "${home}"
}
tweak_dms() {
  section "tweak: dms"
  stage_dms
  # stage_dms already runs `systemctl --user daemon-reload` itself when
  # a user manager is up, so there's nothing to add here. Tweaking again
  # is idempotent: lingering is a no-op if already on, and the cleanup
  # block reclaims ownership + removes any stale dms.service artifacts.
}
tweak_keyring()    { section "tweak: keyring";    stage_keyring; }
tweak_wallpapers()  { section "tweak: wallpapers"; stage_wallpapers; }
tweak_userdirs()   { section "tweak: userdirs";   stage_user_dirs; }
tweak_services()   { section "tweak: services";   stage_services; }
tweak_flatpak()    { section "tweak: flatpak";    stage_flatpak; }
tweak_hyprland_plugins() { section "tweak: hyprland-plugins"; stage_hyprland_plugins; }
tweak_hyprcapture()  { section "tweak: hyprcapture"; stage_hyprcapture; }
tweak_zsh()        { section "tweak: zsh";        stage_zsh; }
# ── --diff: preview what the tweak would do (no writes) ──────────────────────
# Currently a stub: each stage would need to support --dry-run. Today this
# falls back to "all config files would be overwritten with .bak backups."
tweak_diff() {
  local name="$1"
  echo "(diff stub) — would overwrite files in:"
  case "${name}" in
    plymouth)
      echo "  /usr/share/plymouth/themes/omedora/"
      echo "  /etc/plymouth/plymouthd.conf" ;;
    greetd)
      echo "  /etc/greetd/config.toml"
      echo "  /usr/local/bin/start-hyprland" ;;
    hyprland)
      echo "  ~${OMEDORA_TARGET_USER}/.config/hypr/" ;;
    quickshell)
      echo "  ~${OMEDORA_TARGET_USER}/.config/quickshell/" ;;
    dms)
      echo "  ~${OMEDORA_TARGET_USER}/.config/DankMaterialShell/" ;;
    hyprland-plugins)
      echo "  ~${OMEDORA_TARGET_USER}/.config/hypr/plugins/ (git clones; pinned via [hyprland_plugins])" ;;
    services)
      echo "  systemctl enable greetd plymouth-start"
      echo "  systemctl set-default graphical.target" ;;
  esac
  echo "Existing files would be backed up with timestamped .bak suffixes."
}

# ── --revert: restore most recent .bak for every file in the affected paths ─
tweak_revert() {
  local name="$1"
  local paths=()
  case "${name}" in
    plymouth) paths=(/usr/share/plymouth/themes/omedora /etc/plymouth/plymouthd.conf) ;;
    hyprland)
      local h; h="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
      paths=("${h}/.config/hypr") ;;
    quickshell)
      local h; h="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
      paths=("${h}/.config/quickshell") ;;
    dms)
      local h; h="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
      paths=("${h}/.config/DankMaterialShell") ;;
    hyprland-plugins)
      # Plugins are git clones; revert = drop the local repo and let the
      # next stage run re-clone from the URL. No .bak files to restore.
      local h; h="$(getent passwd "${OMEDORA_TARGET_USER}" | cut -d: -f6)"
      paths=("${h}/.config/hypr/plugins") ;;
    services)
      warn "--revert doesn't apply to services (use systemctl disable + set-default)" ; return 0 ;;
    *) die "unknown tweak: ${name}" ;;
  esac

  for base in "${paths[@]}"; do
    if [[ ! -e "${base}" ]]; then continue; fi
    # Find most recent .bak.<date> sibling(s) — either at the same path or
    # any descendant. Restore each by copying back.
    find "${base}" -name '*.bak.*' 2>/dev/null | sort -r | while read -r bak; do
      local target="${bak%.bak.*}"
      if [[ -f "${bak}" ]]; then
        info "reverting ${target} from ${bak}"
        cp -p "${bak}" "${target}"
      fi
    done
  done
  info "revert complete — restart greetd / re-login to pick up changes"
}

# ── CLI ──────────────────────────────────────────────────────────────────────
# Read-only ops (--list, --diff, --revert) don't need root. The tweak
# functions (e.g. tweak_plymouth) call require_root themselves.

if [[ $# -eq 0 || "${1:-}" == "--list" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  list_tweaks
  exit 0
fi

case "${1:-}" in
  --diff)
    tweak_diff "$2" ;;
  --revert)
    [[ $# -ge 2 ]] || die "--revert requires a tweak name"
    tweak_revert "$2" ;;
  --*)
    echo "unknown flag: $1" >&2
    list_tweaks >&2
    exit 2 ;;
  *)
    name="$1"
    if [[ -z "${TWEAK_FN[${name}]+x}" ]]; then
      echo "unknown tweak: ${name}" >&2
      list_tweaks >&2
      exit 2
    fi
    info "applying tweak: ${name}"
    "${TWEAK_FN[${name}]}" ;;
esac
