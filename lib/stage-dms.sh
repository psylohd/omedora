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

  # ── Enable dms user service + lingering ─────────────────────────────────────
  # We pre-stamp four things so that dms auto-starts on every login even
  # if the user manager isn't running yet at install time, and even if
  # no graphical session manager ever fires `graphical-session.target`
  # (raw Hyprland+greetd never activates that target).
  #
  # 1. Drop a local override at $user_unit_dir/dms.service that strips
  #    `Requisite=graphical-session.target` and `Type=dbus`, and repoints
  #    `WantedBy=` at `default.target`.
  # 2. Drop symlink $user_unit_dir/default.target.wants/dms.service → the
  #    override above. With `WantedBy=default.target` in the [Install]
  #    block, this is what re-creates the auto-start edge on every
  #    login.
  # 3. Enable lingering so the user's systemd manager stays alive
  #    across logouts (else dms only auto-starts on the next login).
  #
  # We do NOT call `systemctl --user enable` / `reenable`. Those calls
  # require a running user manager (`XDG_RUNTIME_DIR=/run/user/<uid>`),
  # which on a fresh system this stage runs in is silently absent. The
  # warning has shipped in earlier revisions and resulted in users
  # booting a system without dms.service enabled. We write the
  # symlinks/files directly instead — `systemctl --user` will pick
  # them up at the next user manager start, no questions asked.
  if id "${target_user}" >/dev/null 2>&1; then
    local user_unit_dir="${user_home}/.config/systemd/user"
    local service_src="/usr/lib/systemd/user/dms.service"

    # Source unit must exist (dms package installs it). If it's missing
    # we can't enable, and that's worth dying over — silent skip would
    # leave the user without an auto-starting shell.
    if [[ ! -f "${service_src}" ]]; then
      die "dms.service unit not found at ${service_src} (dms package not installed?)"
    fi

    # -g` honours `-o`/`-g` but plain `sed > file` and `ln -sf` run as the
    # invoking process (root) so we need a single sweep afterwards. Run
    # it eagerly — even though `install -d -o u -g u` set the *immediate*
    # dir to u:u, recursively walking the tree cheap and guarantees any
    # stale file from a previous install run also gets fixed up.
    mkdir -p "${user_unit_dir}"
    chown "${target_user}:${target_user}" "${user_home}/.config/systemd" 2>/dev/null || true
    chown -R "${target_user}:${target_user}" "${user_unit_dir}" 2>/dev/null || true

    # Override by COPYING the vendor unit, then sed-stripping the bits
    # that don't work under bare Hyprland+greetd:
    #   - Requisite=graphical-session.target  → removed (target never active)
    #   - Type=dbus + BusName=org.freedesktop.Notifications
    #                                        → Type=simple (lets dms own its
    #                                          own D-Bus lifecycle; if mako or
    #                                          dunst beat dms to the bus, this
    #                                          would otherwise make systemd
    #                                          refuse to start dms)
    #   - WantedBy=graphical-session.target  → WantedBy=default.target
    #                                          (default IS active for every
    #                                          logged-in user)
    # Everything else passes through unchanged.
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

    # Drop the enable symlink ourselves: $user_unit_dir/default.target.wants/
    # This is what makes dms auto-start on every user login.
    install -d "${user_unit_dir}/default.target.wants"
    if ! ln -sf "${override_unit}" \
       "${user_unit_dir}/default.target.wants/dms.service"; then
      die "failed to symlink dms.service into ${user_unit_dir}/default.target.wants/"
    fi

    # Pull any old, now-stale graphical-session wants-link. Vendors started
    # shipping symlinks here on fully-installed Fedora desktops; on a fresh
    # omedora install the symlink only exists because some other enabler
    # (or this stage's earlier revisions) put it there. It's harmless but
    # worth dropping so the override unit is unambiguous.
    rm -f "${user_unit_dir}/graphical-session.target.wants/dms.service" 2>/dev/null || true

    # Final permission sweep. `install -d` and `ln -sf` (run by root)
    # produce root:root artifacts; systemd's user manager declines to
    # follow them on reload if owned by anything other than the user.
    # We sweep recursively so any stale file from a previous install
    # (or from the wrong-owner intermediate state) is also fixed.
    chown -R "${target_user}:${target_user}" "${user_unit_dir}" \
      || die "chown -R ${user_unit_dir} failed"

    info "dms.service override + default.target.wants symlink in place (perms fixed)"

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
  else
    warn "target_user ${target_user} not found; skipping dms.service install"
  fi
}
