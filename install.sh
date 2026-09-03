#!/bin/bash
# install.sh — Nokron post-install entrypoint for Fedora Server.
#
# Reads nokron.toml, then runs each enabled stage in order. Designed for
# the workflow:
#
#   1. Install Fedora Server (DVD ISO, minimal layout, no DE).
#   2. Create your desktop user + set password.
#   3. Edit nokron.toml — set [meta].target_user, fill in dms sha256s.
#   4. sudo ./install.sh
#
# Usage:
#   sudo ./install.sh                  # full run
#   sudo ./install.sh --config PATH    # alternate config
#   sudo ./install.sh --dry-run        # show stages, do nothing
#   sudo ./install.sh --only dnf,vendor
#   sudo ./install.sh --skip plymouth
#
# Re-running is safe: every stage is idempotent (timestamped .bak on
# conflicts, services re-enabled are no-ops, packages already installed
# are skipped by dnf5).
#
# For surgical tweaks after a full install (re-apply one stage, etc.),
# use ./tweaks.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NOKRON_REPO_ROOT="${SCRIPT_DIR}"

# ── CLI parsing ───────────────────────────────────────────────────────────────
DRY_RUN=false
ONLY=""
SKIP=""
CONFIG_PATH=""

usage() {
  cat <<USAGE
Usage: sudo ./install.sh [options]

Options:
  --config PATH      use a non-default nokron.toml
  --dry-run          print what would happen, do nothing
  --only stages      comma-separated list of stages to run (e.g. dnf,vendor)
  --skip stages      comma-separated list of stages to skip
  -h, --help         this help

Stages (toggleable in nokron.toml [stages]):
  copr, dnf, vendor, flatpak, plymouth, tuigreet, hyprland, quickshell,
  greetd, dms, services
Default config: ${SCRIPT_DIR}/nokron.toml
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --skip)     SKIP="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Load config + helpers ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/parser.sh"
source "${SCRIPT_DIR}/lib/self-check.sh"
# Source stage functions so `run_stage <name> <fn>` can dispatch to them.
for _stage in copr dnf vendor flatpak configs greetd dms services; do
  source "${SCRIPT_DIR}/lib/stage-${_stage}.sh"
done

load_config

# Apply --only / --skip overrides to the stage flags.
apply_stage_filter() {
  local s
  # When --only is passed, reset all known stages to false first so --only
  # starts from a known-clean slate. Without --only, leave the TOML-emitted
  # values alone (don't disable what the user explicitly enabled).
  if [[ -n "${ONLY}" ]]; then
    for s in copr dnf vendor flatpak plymouth tuigreet hyprland quickshell greetd dms services; do
      printf -v "NOKRON_STAGE_${s^^}" "false"
    done
    IFS=',' read -ra list <<< "${ONLY}"
    for s in "${list[@]}"; do
      local var="NOKRON_STAGE_${s^^}"
      printf -v "${var}" "true"
    done
  fi
  if [[ -n "${SKIP}" ]]; then
    IFS=',' read -ra list <<< "${SKIP}"
    for s in "${list[@]}"; do
      local var="NOKRON_STAGE_${s^^}"
      printf -v "${var}" "false"
    done
  fi
}
apply_stage_filter

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_root

# Sanity: confirm this is Fedora.
if ! command -v dnf5 >/dev/null 2>&1; then
  die "dnf5 not found — this installer targets Fedora Server. (Did you mean install.sh?)"
fi
if ! grep -q '^ID=fedora' /etc/os-release 2>/dev/null; then
  warn "this doesn't look like Fedora (/etc/os-release ID != fedora). Continuing anyway."
fi

# Sanity: confirm greeter backend is sane.
case "${NOKRON_GREETER_BACKEND}" in
  tuigreet|dms-greeter) ;;
  *) die "unknown greeter backend: ${NOKRON_GREETER_BACKEND} (expected 'tuigreet' or 'dms-greeter')" ;;
esac

# ── Plan ──────────────────────────────────────────────────────────────────────
section "nokron ${NOKRON_META_NAME}"
echo "  target user: ${NOKRON_TARGET_USER}"
echo "  greeter:     ${NOKRON_GREETER_BACKEND} → ${NOKRON_GREETER_SESSION}"
echo "  repo root:   ${NOKRON_REPO_ROOT}"
echo "  config:      ${NOKRON_CONFIG}"
echo
echo "  stages:"
for s in copr dnf vendor flatpak plymouth tuigreet hyprland quickshell greetd dms services; do
  f="NOKRON_STAGE_${s^^}"
  v="${!f:-false}"          # default missing stage flags to false
  printf "    %-12s %s\n" "${s}" "${v}"
done

if ${DRY_RUN}; then
  info "dry-run — exiting before any change"
  exit 0
fi
# ── Self-check (before destructive work) ─────────────────────────────────────
self_check

echo
read -r -p "Proceed? [y/N] " proceed
case "${proceed}" in
  y|Y|yes|YES) ;;
  *) info "aborted"; exit 0 ;;
esac

# ── Run stages ────────────────────────────────────────────────────────────────
run_stage copr       stage_copr
run_stage dnf        stage_dnf
run_stage vendor     stage_vendor
run_stage flatpak    stage_flatpak
run_stage greetd     stage_greetd       # wire /etc/greetd/config.toml + start-hyprland
run_stage plymouth   stage_configs      # plymouth is part of stage_configs
run_stage tuigreet   stage_configs      # tuigreet is part of stage_configs
run_stage hyprland   stage_configs
run_stage quickshell stage_configs      # quickshell is part of stage_configs
run_stage dms        stage_dms          # DankMaterialShell config + plugins
run_stage services   stage_services

# ── Done ──────────────────────────────────────────────────────────────────────
section "complete"
cat <<DONE

Next steps:
  1. Reboot:   systemctl reboot
  2. Greetd → tuigreet (or dms-greeter) → Hyprland → dms via exec-once.
  3. If Plymouth doesn't load: dracut -f --regenerate-all
  4. To re-run only a stage:  sudo ./install.sh --only vendor

All installed files live under:
  /usr/share/plymouth/themes/nokron
  /etc/tuigreet/                /usr/local/bin/tuigreet
  /etc/greetd/config.toml       /usr/local/bin/start-hyprland
  /usr/local/bin/{dms,dms-greeter,dgop}
  ~${NOKRON_TARGET_USER}/.config/hypr/
  ~${NOKRON_TARGET_USER}/.config/quickshell/

Backups of overwritten files have timestamped .bak.<date> suffixes.
DONE
