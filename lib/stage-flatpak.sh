# lib/stage-flatpak.sh — install Flatpak apps from omedora.toml.
#
# Zen Browser is the obvious one: not in any dnf repo, lives on Flathub.
# Flathub is added once. System-scope installs use --system (run as root,
# land in /var/lib/flatpak). User-scope installs use --user and MUST be
# invoked as the desktop user (sudo -u) so they land in their own
# ~/.local/share/flatpak, not /root's.

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

  if [[ ${#OMEDORA_FLATPAK_SYSTEM[@]} -gt 0 ]]; then
    info "installing ${#OMEDORA_FLATPAK_SYSTEM[@]} system Flatpak(s)"
    # --or-update: install if missing, update if already installed.
    # positional app-id after remote name (not --flag app-id).
    flatpak install -y --system flathub --or-update "${OMEDORA_FLATPAK_SYSTEM[@]}" \
      || warn "system Flatpak install had failures (continuing)"
  fi

  if [[ ${#OMEDORA_FLATPAK_USER[@]} -gt 0 ]]; then
    if ! id "${OMEDORA_TARGET_USER}" >/dev/null 2>&1; then
      die "user-scope flatpaks configured but target_user '${OMEDORA_TARGET_USER}' does not exist"
    fi
    info "installing ${#OMEDORA_FLATPAK_USER[@]} user Flatpak(s) as ${OMEDORA_TARGET_USER}"
    # `sudo -u foo` without -H keeps $HOME=root's, which would land the
    # install in /root/.local/share/flatpak. Set HOME explicitly so
    sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
      flatpak install -y --user flathub --or-update "${OMEDORA_FLATPAK_USER[@]}" \
      || warn "user Flatpak install had failures (continuing)"
  fi
}
