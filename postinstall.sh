#!/bin/bash
# postinstall.sh — tasks that require a running Hyprland session.
#
# Run this after your first graphical login. It syncs the DMS greeter
# theme and installs HyprCapture (which needs $HYPRLAND_INSTANCE_SIGNATURE).
#
# Usage:
#   ./postinstall.sh              # full run
#   ./postinstall.sh --dry-run    # show actions, do nothing

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

source "${SCRIPT_DIR}/lib/parser.sh"
load_config

section "postinstall"

# ── dms-greeter sync ─────────────────────────────────────────────────────────
# dms-greeter sync syncs the greeter theme/wallpaper from the current user's
# DMS config. Run as root via pkexec (user in wheel group gets polkit auth).
info "syncing DMS theme/wallpaper to greeter"
if ! ${DRY_RUN}; then
  if pkexec --user root dms-greeter sync -y 2>&1 | sed 's/^/  /'; then
    info "dms-greeter sync complete"
  else
    warn "dms-greeter sync failed (continuing)"
  fi
else
  echo "  [dry-run] would run: pkexec --user root dms-greeter sync -y"
fi

# ── HyprCapture ───────────────────────────────────────────────────────────────
# HyprCapture needs a live Hyprland session to build (hyprpm reads
# $HYPRLAND_INSTANCE_SIGNATURE for header validation).
if [[ "${OMEDORA_HYPRCAPTURE_ENABLED:-true}" == "true" ]]; then
  info "installing HyprCapture"
  if ! ${DRY_RUN}; then
    if command -v hyprpm >/dev/null 2>&1; then
      if hyprpm add https://github.com/KZDKM/HyprCapture 2>&1 | sed 's/^/  /'; then
        hyprpm enable HyprCapture 2>&1 | sed 's/^/  /' || true
        info "HyprCapture installed"
      else
        warn "HyprCapture add failed (continuing)"
      fi
    else
      warn "hyprpm not found — HyprCapture skipped"
    fi
  else
    echo "  [dry-run] would run: hyprpm add https://github.com/KZDKM/HyprCapture"
  fi
fi

echo ""
info "postinstall complete"
