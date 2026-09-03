# lib/stage-dms.sh — deploy the DankMaterialShell config tree and (optionally)
# install dms plugins from [dms_plugins] in nokron.toml.
#
# What gets deployed (with timestamped .bak on conflict):
#   ~/.config/DankMaterialShell/
#     ├── settings.json             (your customisations — theme, popups, etc.)
#     ├── plugin_settings.json      (which plugins are enabled)
#     ├── themes/                   (your themes, including custom deepmono)
#     ├── firefox.css               (your custom CSS)
#     └── zen.css                   (your custom CSS)
#
# Plugins: the installer runs `dms plugin install <url>` for each entry in
# [dms_plugins].plugins in nokron.toml. By default the list is empty; you
# populate it with git URLs of the plugins you actually want. This keeps
# the repo small and avoids the security/reproducibility problem of
# committing plugin git histories.
#
# Notes:
#   - dms/binds.lua, dms/colors.lua, dms/layout.lua, dms/outputs.lua are
#     intentionally NOT shipped in the repo. dms writes them on first
#     launch from the current monitor config + theme.
#   - dms/binds-user.lua IS shipped (your Omarchy-style overrides). It
#     loads AFTER dms/binds.lua so your overrides win.
#   - customThemeFile in settings.json uses a path relative to the dms
#     config root, so it works regardless of $HOME or username.

stage_dms() {
  section "configs: DankMaterialShell"
  require_root

  local target_user="${NOKRON_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -d "${user_home}" ]] || die "user home '${user_home}' does not exist"

  local src="${NOKRON_PATH_DMS}"

  if [[ ! -d "${src}" ]]; then
    warn "DankMaterialShell source dir not found: ${src} (skipping)"
    return 0
  fi

  local dst="${user_home}/.config/DankMaterialShell"
  info "deploying ${src} → ${dst}"
  backup_and_copy_tree "${src}" "${dst}"

  # settings.json contains customThemeFile as a relative path ("themes/
  # deepmono/theme.json"). dms resolves this against its config dir, so it
  # Just Works regardless of whose $HOME it lives under. No sed needed.

  # Permissions: everything user-readable, owned by the desktop user.
  chown -R "${target_user}:${target_user}" "${dst}"

  # ── Plugins ─────────────────────────────────────────────────────────────────
  if [[ ${#NOKRON_DMS_PLUGINS[@]} -eq 0 ]]; then
    info "no [dms_plugins] configured — skipping plugin install"
    info "edit nokron.toml [dms_plugins].plugins to add plugin git URLs"
    return 0
  fi

  # `dms plugin install` runs as the desktop user (it writes to their
  # ~/.config/DankMaterialShell/plugins/, not /usr). Drop privileges with
  # `sudo -u`.
  if ! command -v dms >/dev/null 2>&1; then
    die "dms binary not in PATH. Did [stages].vendor run successfully?"
  fi

  info "installing ${#NOKRON_DMS_PLUGINS[@]} dms plugin(s) as ${target_user}"
  for plugin in "${NOKRON_DMS_PLUGINS[@]}"; do
    info "  dms plugin install ${plugin}"
    if ! sudo -u "${target_user}" -H dms plugin install "${plugin}"; then
      warn "  plugin install failed for: ${plugin} (continuing)"
    fi
  done

  # ── Enable dms user service + lingering ─────────────────────────────────────
  # `/usr/lib/systemd/user/dms.service` (shipped by the dms package) auto-
  # starts the shell on graphical-session.target. The installer enables it
  # by writing the symlink directly under ~/.config/systemd/user/ (where
  # `systemctl --user enable` would write it). This avoids the
  # `sudo -u … systemctl --user` dance — `sudo -H` strips XDG_RUNTIME_DIR
  # so the call silently fails on a fresh system where the user manager
  # isn't running yet, or when the user is logged out. Dropping a symlink
  # works regardless of session state.
  #
  # We also `loginctl enable-linger <user>` so the user's systemd manager
  # stays alive across logouts — without this, dms only starts on the
  # login that immediately follows the install.
  if id "${target_user}" >/dev/null 2>&1; then
    local user_unit_dir="${user_home}/.config/systemd/user"
    # dms hooks graphical-session.target by default; that fires on every
    # graphical login (greeter → Hyprland → dms). The Hyprland RPM ships
    # hyprland-session.target as a regular FILE, not a directory, so we
    # can't drop a `.wants/` symlink next to it. dms starts fine without
    # the extra hook (graphical-session already pulls it in).
    install -d -m 0755 -o "${target_user}" -g "${target_user}" \
      "${user_unit_dir}/graphical-session.target.wants"
    ln -sf /usr/lib/systemd/user/dms.service \
      "${user_unit_dir}/graphical-session.target.wants/dms.service"
    chown -h "${target_user}:${target_user}" \
      "${user_unit_dir}/graphical-session.target.wants/dms.service"
    info "enabled dms user service (graphical-session.target)"
  fi
  if [[ "$(loginctl show-user "${target_user}" 2>/dev/null | awk -F= '/^Linger=/{print $2}')" != "yes" ]]; then
    loginctl enable-linger "${target_user}" \
      || warn "loginctl enable-linger ${target_user} failed (user can run it manually)"
  else
    info "loginctl enable-linger already enabled for ${target_user}"
  fi
}
