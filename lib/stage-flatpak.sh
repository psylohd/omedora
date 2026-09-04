# lib/stage-flatpak.sh — install Flatpak apps from omedora.toml.
#
# Zen Browser is the obvious one: not in any dnf repo, lives on Flathub.
# Flathub is added once. System-scope installs use --system (run as root,
# land in /var/lib/flatpak). User-scope installs use --user and MUST be
# invoked as the desktop user (sudo -u) so they land in their own
# ~/.local/share/flatpak, not /root's.

# `desktop-file-utils` (provides `update-desktop-database`) is required
# by this stage to keep Flatpak .desktop entries visible to dms without
# a re-login. Install it on entry if missing — Fedora Server's "Standard"
# environment already pulls it in via glib's weak deps, but a bare
# minimal install will not. The dnf5 install is a no-op on re-runs.
command -v update-desktop-database >/dev/null 2>&1 \
  || dnf5 -y install desktop-file-utils >/dev/null 2>&1 \
  || warn "desktop-file-utils install failed; Flatpak .desktop entries may not appear until re-login"

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

  # Resolve the desktop user's home ONCE; used both by the user-scope
  # flatpak install (--user) and by the user-scope desktop-database
  # refresh below. stage-dms.sh / stage-configs.sh do this the same way.
  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  if [[ -n "${target_user}" ]] && id "${target_user}" >/dev/null 2>&1; then
    user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  fi

  # System-scope flatpak CLI reads /var/lib/flatpak/repo (added above is
  # already visible there). User-scope reads ~/.local/share/flatpak/repo,
  # which is a separate repo and needs flathub added again for the
  # desktop user's own remote list. Without this, `flatpak install --user
  # flathub ...` errors with "Remote 'flathub' not found" because the
  # system remote isn't visible from the user repo.
  if [[ ${#OMEDORA_FLATPAK_USER[@]} -gt 0 ]]; then
    info "adding flathub to user-scope remote for ${OMEDORA_TARGET_USER}"
    sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
      flatpak remote-add --if-not-exists --user flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo \
      || warn "failed to add user-scope flathub (user Flatpaks will fail)"
  fi

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

  # ── Refresh desktop-entry caches so dms / xdg-desktop-portal see Flatpaks ──
  #
  # Without this step, freshly-installed Flatpaks DO exist on disk (under
  # /var/lib/flatpak/exports/share/applications for system installs and
  # ~/.local/share/flatpak/exports/share/applications for user installs),
  # but the desktop-database cache at $XDG_DATA_DIRS/applications/
  # desktop.cache is stale. dms enumerates desktop entries through the
  # cache (xdg-desktop-portal's "recent files" / "open with" UIs read it,
  # and dms's own launcher menu reads it via glib's GDesktopAppInfo), so
  # an un-refreshed cache means: app icons are present but unselectable
  # from the launcher, "Open With" menus are empty, and the .desktop
  # file is invisible until the user logs out and back in (which forces
  # glib to re-scan on startup).
  #
  # `update-desktop-database` is in the `desktop-file-utils` RPM, which
  # ships in the Fedora Server "Standard" environment. If it's missing
  # on a bare-minimal install, fall back to a plain find that triggers
  # glib's auto-rescan on next launch (a no-op rather than an error).
  #
  # `flatpak update --appstream` refreshes the AppStream metadata that
  # dms's plugin installer / Software Center integration consumes. It
  # is a no-op when the AppStream cache is already fresh; cheap to run.
  if command -v update-desktop-database >/dev/null 2>&1; then
    info "refreshing desktop-entry caches for Flatpak installs"
    update-desktop-database /var/lib/flatpak/exports/share/applications 2>/dev/null \
      || warn "system flatpak desktop-database refresh failed (entries may not appear until re-login)"
    if [[ -n "${user_home:-}" && -d "${user_home}/.local/share/flatpak/exports/share/applications" ]]; then
      sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
        update-desktop-database "${user_home}/.local/share/flatpak/exports/share/applications" \
        2>/dev/null \
        || warn "user flatpak desktop-database refresh failed (entries may not appear until re-login)"
    fi
  else
    warn "update-desktop-database not installed; Flatpak .desktop entries may not appear until re-login"
  fi

  # AppStream metadata refresh (system scope). Cheap, idempotent, no-op
  # when cache is fresh. User scope has its own AppStream cache but the
  # system one is what dms reads by default.
  flatpak update --appstream 2>/dev/null \
    || warn "flatpak update --appstream failed (AppStream metadata stale; cosmetic)"
 }

