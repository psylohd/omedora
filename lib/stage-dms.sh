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
}
