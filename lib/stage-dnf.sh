# lib/stage-dnf.sh — install every package listed in omedora.toml.
#
# One dnf5 invocation per logical group so failures are scoped. We pass -y
# only on the package install (so the user can't get stuck on a prompt) but
# rely on dnf5's own GPG/transaction logic.

stage_dnf() {
  section "dnf"
  command -v dnf5 >/dev/null 2>&1 || die "dnf5 not found"

  info "installing Hyprland stack (${#OMEDORA_HYPRLAND[@]} packages from lionheartp/Hyprland)"
  if [[ ${#OMEDORA_HYPRLAND[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_HYPRLAND[@]}" || die "Hyprland stack install failed"
  fi

  info "installing quickshell + Qt runtime (${#OMEDORA_QUICKSHELL[@]} packages)"
  if [[ ${#OMEDORA_QUICKSHELL[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_QUICKSHELL[@]}" || die "quickshell install failed"
  fi

  info "installing DMS (dms + weak deps from avengemedia/dms COPR)"
  local dms_opts=()
  [[ "${OMEDORA_DMS_WEAK_DEPS}" == "false" ]] && dms_opts+=( --setopt=install_weak_deps=False )
  dnf5 -y install "${dms_opts[@]}" dms || die "dms install failed"
  info "installing required apps (${#OMEDORA_APPS[@]} packages)"
  if [[ ${#OMEDORA_APPS[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_APPS[@]}" || die "apps install failed"
  fi

  info "installing build toolchain (${#OMEDORA_BUILD[@]} packages)"
  if [[ ${#OMEDORA_BUILD[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_BUILD[@]}" \
      || warn "build toolchain install failed — tuigreet build will fail"
  fi
  info "installing optional COPR packages (${#OMEDORA_APPS_OPTIONAL[@]} packages)"
  if [[ ${#OMEDORA_APPS_OPTIONAL[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_APPS_OPTIONAL[@]}" || {
      warn "optional package install failed — continuing. (Re-run after fixing.)"
    }
  fi

  # Plymouth hard dep: the omedora script theme requires plymouth-plugin-script.
  # install.sh already asserts this; the post-install path needs it too.
  if ! rpm -q plymouth-plugin-script >/dev/null 2>&1; then
    die "plymouth-plugin-script is not installed. dnf5 install plymouth-plugin-script first."
  fi
}
