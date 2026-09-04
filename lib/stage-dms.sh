# lib/stage-dms.sh — deploy the DankMaterialShell config tree, install
# [dms_plugins] entries, and enable the dms systemd user service + linger.
#
# What gets deployed (with timestamped .bak on conflict):
#   ~/.config/DankMaterialShell/
#     ├── settings.json             (your customisations — theme, popups, etc.)
#     ├── plugin_settings.json      (which plugins are enabled)
#     ├── themes/                   (your themes, including custom deepmono)
#     ├── firefox.css               (your custom CSS)
#     └── zen.css                   (your custom CSS)
#
# Plugins: two sources in [dms_plugins]:
#   plugins  — git URLs (cloned into ~/.config/DankMaterialShell/plugins/)
#   registry — IDs from https://github.com/AvengeMedia/dms-plugin-registry
#              installed via `dms plugins install <id>` (e.g. "dankQuickSearch")
# Both lists are optional and kept out of the repo (size + hygiene); the
# dms stage installs them at deploy time.
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

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -d "${user_home}" ]] || die "user home '${user_home}' does not exist"

  local src="${OMEDORA_PATH_DMS}"

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
  chown "${target_user}:${target_user}" "${user_home}/.config"
  # ── Plugins ─────────────────────────────────────────────────────────────────
  # Two sources:
  #   OMEDORA_DMS_PLUGINS   — git URLs (cloned into ~/.config/DankMaterialShell/plugins/)
  #   OMEDORA_DMS_REGISTRY  — plugin IDs from the dms registry
  #                          (e.g. "dankQuickSearch"). Installed via
  #                          `dms plugins install <id>`.
  # Both lists are optional; the install step is skipped if both are empty.
  if [[ ${#OMEDORA_DMS_PLUGINS[@]} -eq 0 && ${#OMEDORA_DMS_REGISTRY[@]} -eq 0 ]]; then
    info "no [dms_plugins] configured — skipping plugin install"
    info "edit omedora.toml [dms_plugins].plugins (git URLs) or"
    info ".registry (registry IDs) to add plugins"
  fi

  # dms writes to the user's ~/.config/DankMaterialShell/plugins/, so it
  # must run as the desktop user. `sudo -H` strips $HOME which would
  # land plugins in /root; use `sudo -u` without -H so $HOME survives.
  if ! command -v dms >/dev/null 2>&1; then
    die "dms binary not in PATH. Did [stages].vendor run successfully?"
  fi

  # `dms plugins install` (plural) for registry IDs.
  if [[ ${#OMEDORA_DMS_REGISTRY[@]} -gt 0 ]]; then
    info "installing ${#OMEDORA_DMS_REGISTRY[@]} dms plugin(s) from registry as ${target_user}"
    for pid in "${OMEDORA_DMS_REGISTRY[@]}"; do
      info "  dms plugins install ${pid}"
      if ! sudo -u "${target_user}" env HOME="${user_home}" DMS_PRIVESC=sudo \
            dms plugins install "${pid}"; then
        warn "  plugin install failed for: ${pid} (continuing)"
      fi
    done
  fi

  # Git-URL plugins: clone into the user's plugins/ dir directly. The
  # upstream `dms plugins install <git-url>` form may also work, but
  # sticking to a plain git clone avoids surprises with how the registry
  # is queried.
  if [[ ${#OMEDORA_DMS_PLUGINS[@]} -gt 0 ]]; then
    local plugins_dir="${user_home}/.config/DankMaterialShell/plugins"
    install -d -m 0755 "${plugins_dir}"
    chown "${target_user}:${target_user}" "${plugins_dir}"
    info "installing ${#OMEDORA_DMS_PLUGINS[@]} dms plugin(s) from git as ${target_user}"
    for url in "${OMEDORA_DMS_PLUGINS[@]}"; do
      local name
      name="$(basename "${url}" .git)"
      info "  git clone ${url} → ${plugins_dir}/${name}"
      if ! sudo -u "${target_user}" -H \
            git clone --depth=1 "${url}" "${plugins_dir}/${name}"; then
        warn "  plugin clone failed for: ${url} (continuing)"
      fi
    done
  fi

  # ── Enable lingering + clean up any half-installed dms.service state ─────
  #
  # We do NOT install/enable dms.service. The upstream dms unit hard-codes
  # `Requisite=graphical-session.target`, which never fires under a bare
  # Hyprland+greetd session (no GNOME/KDE session manager is ever pulled
  # in). With that Requisite unresolved, systemd refuses to start the
  # service with "Dependency failed" — that's the failure mode a clean
  # VM install hits on first login. Override unit files fix part of it
  # but the underlying incompatibility remains.
  #
  # What every Hyprland-on-Fedora rollout does instead: launch `dms run`
  # from Hyprland's `exec-once` block. We do the same — see
  # hyprland/startup.lua. It's deterministic, doesn't fight
  # `graphical-session.target`, and runs at exactly the right moment
  # (once per Hyprland session start).
  #
  # What we DO still need from systemd: lingering. Otherwise the user's
  # systemd manager dies at logout, taking keyring/portals with it;
  # auto-login setups would silently lose their user services.
  if ! id "${target_user}" >/dev/null 2>&1; then
    warn "target_user ${target_user} not found; skipping lingering setup"
    return 0
  fi

  if ! loginctl enable-linger "${target_user}" 2>/dev/null; then
    # Already-enabled returns nonzero on some systemd versions; check.
    if [[ "$(loginctl show-user "${target_user}" 2>/dev/null \
         | awk -F= '/^Linger=/{print $2}')" != "yes" ]]; then
      warn "loginctl enable-linger ${target_user} failed (user can run it manually)"
    else
      info "lingering already enabled for ${target_user}"
    fi
  else
    info "enabled lingering for ${target_user}"
  fi

  # Drop any leftover dms.service state from earlier omedora installs.
  # Stale symlinks pointing at a unit systemd will never start produce
  # confusing `systemctl --user is-enabled dms.service` output. Reclaim
  # ownership of the directory first so the user can later edit/delete
  # their own tree without sudo. Silent if no prior install ran.
  local user_unit_dir="${user_home}/.config/systemd/user"
  if [[ -d "${user_unit_dir}" ]]; then
    chown -R "${target_user}:${target_user}" "${user_unit_dir}" 2>/dev/null || true
    rm -f "${user_unit_dir}/dms.service" \
          "${user_unit_dir}/default.target.wants/dms.service" \
          "${user_unit_dir}/graphical-session.target.wants/dms.service" \
          2>/dev/null || true
    chown -R "${target_user}:${target_user}" "${user_unit_dir}" 2>/dev/null || true
  fi

  # Tell the running user manager to forget any leftover unit state.
  # Silent if no manager is up (fresh install with no XDG_RUNTIME_DIR yet).
  if [[ -d "/run/user/$(id -u "${target_user}")" ]]; then
    sudo -u "${target_user}" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "${target_user}")" \
      systemctl --user daemon-reload 2>/dev/null \
      || warn "user manager daemon-reload failed (will pick up on next login)"
  fi
}
