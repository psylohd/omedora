# lib/stage-flatpak.sh — install Flatpak apps from nokron.toml.
#
# Zen Browser is the obvious one: not in any dnf repo, lives on Flathub.
# Flathub is added once. System-scope installs use --system; user-scope
# uses --user (no root required for those, but we are root anyway).

stage_flatpak() {
  require_root
  section "flatpak"

  command -v flatpak >/dev/null 2>&1 || {
    info "flatpak not installed — installing"
    dnf5 -y install flatpak || die "failed to install flatpak"
  }

  # Idempotent: --if-not-exists is supported by recent flatpak.
  flatpak remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo \
    || die "failed to add Flathub remote"

  if [[ ${#NOKRON_FLATPAK_SYSTEM[@]} -gt 0 ]]; then
    info "installing ${#NOKRON_FLATPAK_SYSTEM[@]} system Flatpak(s)"
    flatpak install -y --system --noninteractive flathub "${NOKRON_FLATPAK_SYSTEM[@]}" \
      || warn "system Flatpak install had failures (continuing)"
  fi

  if [[ ${#NOKRON_FLATPAK_USER[@]} -gt 0 ]]; then
    info "installing ${#NOKRON_FLATPAK_USER[@]} user Flatpak(s)"
    flatpak install -y --user --noninteractive flathub "${NOKRON_FLATPAK_USER[@]}" \
      || warn "user Flatpak install had failures (continuing)"
  fi
}
