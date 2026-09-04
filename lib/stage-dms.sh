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

  # ── Enable dms.service + lingering ───────────────────────────────────────────
  # dms.service upstream ships with `Requisite=graphical-session.target` and
  # `WantedBy=graphical-session.target`. With nothing pulling that target
  # live on a bare Hyprland+greetd install, dms.service fails with
  # `Job dms.service/start failed with result 'dependency'` on first login.
  # We close the loop by shipping `hyprland-session.target` (in
  # hyprland/systemd-user/) which `BindsTo=` graphical-session.target.
  # hyprland.lua calls `systemctl --user start hyprland-session.target`
  # at session start; that pulls graphical-session.target live, which
  # satisfies dms's Requisite= and triggers dms's WantedBy= to autostart.
  # See wiki.hypr.land/Useful-Utilities/Systemd-Integration
  # "Services / dms.service" for the canonical pattern.
  if ! id "${target_user}" >/dev/null 2>&1; then
    warn "target_user ${target_user} not found; skipping dms.service setup"
    return 0
  fi

  # ── Lingering ────────────────────────────────────────────────────────────────
  # Without lingering the user's systemd manager dies at logout. dms.service,
  # keyring agents, portals — all of it drops on logout. Auto-login setups
  # silently lose their user services without it.
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

  # ── Enable dms.service ──────────────────────────────────────────────────────
  # Drops a symlink at default.target.wants/dms.service. That auto-fires on
  # every user login once hyprland-session.target is started (see
  # hyprland.lua). We use default.target.wants rather than enabling at
  # install time directly because:
  #   * `systemctl --user enable` requires a running user manager
  #     (`XDG_RUNTIME_DIR=/run/user/<uid>`), silently absent on a fresh install.
  #     Writing the symlink ourselves works regardless of session state.
  #   * default.target is active for every logged-in user, unlike
  #     graphical-session.target which is intermittent.
  local user_unit_dir="${user_home}/.config/systemd/user"
  install -d -o "${target_user}" -g "${target_user}" -m 0755 "${user_unit_dir}"

  # Reclaim ownership of anything left over from previous omedora runs
  # so we can rm it (stage runs as root) and so the user can later edit.
  chown -R "${target_user}:${target_user}" "${user_unit_dir}" 2>/dev/null || true

  # ── Write local dms.service override + link it into default.target.wants ──
  # Upstream dms.service ships with three directives that don't work on
  # bare Hyprland+greetd:
  #
  #   1. `Requisite=graphical-session.target` — never activated by
  #      greetd/Hyprland; the Requisite is unmet, systemd refuses to
  #      start dms with `result 'dependency'`. We saw this exact failure
  #      (Sep 4 fresh install on test@fedora: `Job dms.service/start
  #      failed with result 'dependency'` even though Hyprland was
  #      running and our `hyprland-session.target` was deployed).
  #
  #   2. `Type=dbus` + `BusName=org.freedesktop.Notifications` — if
  #      anything else (mako, dunst) claims that bus name first,
  #      systemd waits on dms to claim it and eventually times out.
  #      Letting dms own its own D-Bus lifecycle via `Type=simple` is
  #      strictly more robust.
  #
  #   3. `WantedBy=graphical-session.target` — same issue as (1). Repoint
  #      at `default.target`, which is active for every logged-in user
  #      regardless of session type.
  #
  # Local units in ~/.config/systemd/user/ always win over vendor units
  # in /usr/lib/systemd/user/ (see `man systemd.unit`, "User Unit Search
  # Path"). We sed-strip the three problematic directives above, drop
  # the result at ${user_unit_dir}/dms.service, then symlink THAT into
  # default.target.wants/ — so the auto-start edge picks up our fixed
  # copy, not the upstream one.
  local service_src="/usr/lib/systemd/user/dms.service"
  if [[ ! -f "${service_src}" ]]; then
    warn "dms.service unit not found at ${service_src}; not enabling (dms RPM missing?)"
    return 0
  fi

  local override_unit="${user_unit_dir}/dms.service"
  if [[ ! -f "${override_unit}" ]] \
     || ! grep -q '^# omedora: dms.service override$' "${override_unit}" 2>/dev/null; then
    sed -e '/^Requisite=/d' \
        -e 's/^Type=dbus$/Type=simple/' \
        -e 's/^WantedBy=graphical-session.target$/WantedBy=default.target/' \
        -e '1i # omedora: dms.service override (Requisite stripped, Type=simple, WantedBy=default)' \
        -e 's|^Description=.*|Description=Dank Material Shell (DMS) [omedora override]|' \
        "${service_src}" > "${override_unit}" \
      || die "failed to write ${override_unit}"
  fi
  [[ -s "${override_unit}" ]] \
    || die "${override_unit} is missing or empty after write"
  chmod 0644 "${override_unit}"

  # Drop stale graphical-session.target.wants/ symlinks from older
  # install runs that pointed at the upstream copy. Harmless but worth
  # keeping the user unit dir unambiguous.
  rm -f "${user_unit_dir}/graphical-session.target.wants/dms.service" 2>/dev/null || true

  install -d -o "${target_user}" -g "${target_user}" -m 0755 \
    "${user_unit_dir}/default.target.wants"
  if ! ln -sf "${override_unit}" \
     "${user_unit_dir}/default.target.wants/dms.service"; then
    die "failed to symlink dms.service into ${user_unit_dir}/default.target.wants/"
  fi
  chown -h "${target_user}:${target_user}" \
    "${user_unit_dir}/default.target.wants/dms.service"
  info "dms.service auto-start symlink installed"

  # Tell the running user manager to forget any leftover unit state.
  # Silent if no manager is up (fresh install, no XDG_RUNTIME_DIR yet);
  # the next login will load the unit.
  if [[ -d "/run/user/$(id -u "${target_user}")" ]]; then
    sudo -u "${target_user}" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "${target_user}")" \
      systemctl --user daemon-reload 2>/dev/null \
      || warn "user manager daemon-reload failed (will pick up on next login)"
  fi
}
