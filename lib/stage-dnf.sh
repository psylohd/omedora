# lib/stage-dnf.sh — install every package listed in nokron.toml.
#
# One dnf5 invocation per logical group so failures are scoped. We pass -y
# only on the package install (so the user can't get stuck on a prompt) but
# rely on dnf5's own GPG/transaction logic.

stage_dnf() {
  command -v dnf5 >/dev/null 2>&1 || die "dnf5 not found"

  info "installing Hyprland stack (${#NOKRON_HYPRLAND[@]} packages from lionheartp/Hyprland)"
  if [[ ${#NOKRON_HYPRLAND[@]} -gt 0 ]]; then
    dnf5 -y install "${NOKRON_HYPRLAND[@]}" || die "Hyprland stack install failed"
  fi

  info "installing quickshell + Qt runtime (${#NOKRON_QUICKSHELL[@]} packages)"
  if [[ ${#NOKRON_QUICKSHELL[@]} -gt 0 ]]; then
    dnf5 -y install "${NOKRON_QUICKSHELL[@]}" || die "quickshell install failed"
  fi
  info "installing required apps (${#NOKRON_APPS[@]} packages)"
  if [[ ${#NOKRON_APPS[@]} -gt 0 ]]; then
    dnf5 -y install "${NOKRON_APPS[@]}" || die "apps install failed"
  fi

  info "installing build toolchain (${#NOKRON_BUILD[@]} packages)"
  if [[ ${#NOKRON_BUILD[@]} -gt 0 ]]; then
    dnf5 -y install "${NOKRON_BUILD[@]}" \
      || warn "build toolchain install failed — tuigreet build will fail"
  fi
  info "installing optional COPR packages (${#NOKRON_APPS_OPTIONAL[@]} packages)"
  if [[ ${#NOKRON_APPS_OPTIONAL[@]} -gt 0 ]]; then
    dnf5 -y install "${NOKRON_APPS_OPTIONAL[@]}" || {
      warn "optional package install failed — continuing. (Re-run after fixing.)"
    }
  fi

  # Plymouth hard dep: the nokron script theme requires plymouth-plugin-script.
  # install.sh already asserts this; the post-install path needs it too.
  if ! rpm -q plymouth-plugin-script >/dev/null 2>&1; then
    die "plymouth-plugin-script is not installed. dnf5 install plymouth-plugin-script first."
  fi
}
