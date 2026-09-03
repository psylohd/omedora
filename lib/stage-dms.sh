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
    local service_src="/usr/lib/systemd/user/dms.service"

    # Source unit must exist (dms package installs it). If it's missing
    # we can't enable, and that's worth dying over — silent skip would
    # leave the user without an auto-starting shell.
    if [[ ! -f "${service_src}" ]]; then
      die "dms.service unit not found at ${service_src} (dms package not installed?)"
    fi

    # dms hooks graphical-session.target by default; that fires on every
    # graphical login (greeter → Hyprland → dms). The Hyprland RPM ships
    # hyprland-session.target as a regular FILE (not a directory), so we
    # can't drop a `.wants/` symlink next to it — dms starts fine without
    # the extra hook (graphical-session already pulls it in).
    #
    # Create the parent user unit dir first (idempotent: `install -d`
    # silently succeeds if it already exists). On a fresh system
    # ~/.config/systemd/ may not exist at all, and `install -d
    # …/graphical-session.target.wants` would then create a stray
    # `~/.config/systemd/graphical-session.target.wants/` path that
    # systemd never reads. Doing it in two steps keeps the layout
    # correct: ~/.config/systemd/user/ + …/user/graphical-session.target.wants/.
    install -d -m 0755 "${user_unit_dir}"
    chown "${target_user}:${target_user}" "${user_unit_dir}"
    install -d -m 0755 -o "${target_user}" -g "${target_user}" \
      "${user_unit_dir}/graphical-session.target.wants"
    # ln -sf: -f overwrites any existing symlink/file at the target.
    # Capture the result so a failure produces a clear error instead of
    # the cryptic `ln: failed to create symbolic link` from set -e.
    if ! ln -sf "${service_src}" \
         "${user_unit_dir}/graphical-session.target.wants/dms.service"; then
      die "failed to symlink dms.service into ${user_unit_dir}/graphical-session.target.wants/"
    fi
    # Override dms.service by COPYING it to ~/.config/systemd/user/.
    # Local unit files take precedence over vendor units (no drop-in
    # quirks — empty `Requisite=` doesn't always reset the directive
    # across systemd versions, but a copied local unit always wins).
    #
    # Why we need to override:
    #   1. Upstream has `Requisite=graphical-session.target`. Raw
    #      Hyprland+greetd never activates that target (no GNOME/KDE
    #      session manager running), so the Requisite= check fails and
    #      systemd refuses to start dms.service.
    #   2. Upstream uses `Type=dbus` with `BusName=org.freedesktop.Notifications`.
    #      systemd waits for dms to claim the bus name before considering
    #      it "started". If anything else (mako, dunst) ever claims it,
    #      dms.service fails. Switch to `Type=simple` and let dms manage
    #      its own D-Bus lifecycle.
    #
    # Stripped directives: Requisite= (entire line removed), Type=dbus
    # → Type=simple. Everything else passes through unchanged.
    local override_unit="${user_unit_dir}/dms.service"
    if [[ ! -f "${override_unit}" ]] || \
       ! grep -q '^# omedora: dms.service override$' "${override_unit}" 2>/dev/null; then
      sed -e '/^Requisite=/d' \
          -e 's/^Type=dbus$/Type=simple/' \
          -e '1i # omedora: dms.service override (Requisite stripped, Type=simple)' \
          -e 's|^Description=.*|Description=Dank Material Shell (DMS) [omedora override]|' \
          "${service_src}" > "${override_unit}" \
        || die "failed to write ${override_unit}"
      chown "${target_user}:${target_user}" "${override_unit}"
    fi
    [[ -s "${override_unit}" ]] \
      || die "${override_unit} is missing or empty after write"
    # The upstream unit still has `WantedBy=graphical-session.target`,
    # but that target is never active. Replace the [Install] block with
    # one that wants `default.target` — which IS active for any logged-in
    # user. dms will then auto-start on every login.
    if grep -q '^WantedBy=graphical-session.target$' "${override_unit}"; then
      sed -i 's|^WantedBy=graphical-session.target$|WantedBy=default.target|' \
        "${override_unit}"
    fi
    # Drop the symlink so the override unit becomes the active one (no
    # longer alias to the vendor copy). Symlink vs local-unit precedence:
    # local unit in ~/.config/systemd/user/ always wins over the symlink
    # target in /usr/lib/systemd/user/, so this is safe.
    rm -f "${user_unit_dir}/graphical-session.target.wants/dms.service" 2>/dev/null || true
    # `systemctl --user enable` writes the symlink for us; we already
    # have a local unit, so `enable` is a no-op for the unit itself but
    # still creates the default.target.wants/ symlink.
    sudo -u "${target_user}" systemctl --user reenable "${override_unit##*/}" 2>/dev/null \
      || warn "systemctl --user reenable dms.service failed (user can enable manually)"
    info "dropped dms.service override (local unit, Type=simple, no Requisite)"
    if loginctl enable-linger "${target_user}" 2>/dev/null; then
      info "enabled lingering for ${target_user}"
    else
      warn "loginctl enable-linger ${target_user} failed (user can run it manually)"
    fi
  else
    info "loginctl enable-linger already enabled for ${target_user}"
  fi
}
