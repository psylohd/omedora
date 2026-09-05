# lib/stage-keyring.sh — GNOME Keyring auto-unlock at greetd login.
#
# What this stage does:
#   1. Verifies pam_gnome_keyring.so is on disk (it's shipped by the
#      `gnome-keyring-pam` package; install via the [packages.apps] list).
#      If it's missing we fail loudly because the next step would silently
#      no-op against an absent module.
#   2. Confirms `/etc/pam.d/greetd` references pam_gnome_keyring.so on both
#      the `-auth` and `-session optional … auto_start` lines. The
#      Fedora-shipped greetd RPM already wires these — if the install
#      predates that wiring (rare; only on customized /etc/pam.d/greetd)
#      we patch the file idempotently.
#   3. Ensures the keys service has been started in the user's session by
#      emitting /etc/xdg/autostart/gnome-keyring-secrets.desktop from the
#      RPM. If the autostart file is absent we copy it from
#      /usr/share/applications/.
#   4. Falls back to set OMEDORA_STAGE_KEYRING=false to skip silently;
#      check `journalctl -u greetd` for any login-time pam errors.
#
# Why this stage is separate from `startup.lua`:
#   * The unlock side runs *during* PAM auth (in the greetd child process),
#     not after the user session starts. It needs to be wired in
#     /etc/pam.d/greetd, which is a system file (must run as root, not
#     under `hyprland-session.target`).
#   * The unlock mechanism is loaded into the greetd-launched session and
#     inherits to Hyprland. No extra exec_once is needed at the Hyprland
#     level beyond what `startup.lua` already does for `--components=ssh`
#     fallback (a USB key unlock).

stage_keyring() {
  section "system: gnome-keyring auto-unlock"
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"

  # ── 1. Module presence ─────────────────────────────────────────────────────
  local mod_path="/usr/lib64/security/pam_gnome_keyring.so"
  if [[ ! -f "${mod_path}" ]]; then
    die "pam_gnome_keyring.so not found at ${mod_path}.
The module ships in the 'gnome-keyring-pam' package. Add it to
[packages.apps].required in omedora.toml and rerun the dnf stage:
    sudo dnf install gnome-keyring-pam"
  fi
  info "pam_gnome_keyring.so present at ${mod_path}"

  # ── 2. PAM wiring sanity ────────────────────────────────────────────────────
  local pam_file="/etc/pam.d/greetd"
  if [[ ! -f "${pam_file}" ]]; then
    warn "${pam_file} missing; greetd might use a different backend (login, etc)."
    warn "If your display manager isn't greetd, you'll need to wire pam_gnome_keyring.so manually."
  else
    # Two lines are expected: -auth optional pam_gnome_keyring.so (try to
    # unlock with the login password), and -session optional …
    # auto_start (spawn the daemon). We patch missing lines only; existing
    # lines are left intact (the Fedora-shipped file has the right entries).
    local need_patch=0
    grep -qE '^[-\s]*auth\s+optional\s+pam_gnome_keyring\.so\b' "${pam_file}" || need_patch=1
    grep -qE '^[-\s]*session\s+optional\s+pam_gnome_keyring\.so\b.*auto_start' "${pam_file}" || need_patch=1

    if [[ "${need_patch}" -eq 1 ]]; then
      warn "PAM wiring incomplete; patching ${pam_file}"
      # Insert the auth and session lines as the *first* two non-comment
      # entries (this is where the Fedora RPM expects them — see
      # pam_gnome_keyring(8)). Idempotent: we only insert if a line was
      # missing; never duplicate.
      backup_and_install_etc "${pam_file}"
      if ! grep -qE '^[-\s]*auth\s+optional\s+pam_gnome_keyring\.so\b' "${pam_file}"; then
        sed -i '1i -auth       optional    pam_gnome_keyring.so' "${pam_file}"
      fi
      if ! grep -qE '^[-\s]*session\s+optional\s+pam_gnome_keyring\.so\b.*auto_start' "${pam_file}"; then
        sed -i '/^[[:space:]]*session[[:space:]]\+include[[:space:]]\+postlogin/i -session    optional    pam_gnome_keyring.so auto_start' "${pam_file}"
      fi
    else
      info "PAM wiring already correct in ${pam_file}"
    fi
  fi

  # ── 3. Autostart file ──────────────────────────────────────────────────────
  # The XDG autostart mechanism is how the user's session starts the
  # keyring daemon after greetd completes. The Fedora package drops the
  # desktop file into /usr/share but typically also installs it into
  # /etc/xdg/autostart/. We check and copy from /usr/share if needed so
  # the desktop user gets it.
  local share_desktop="/usr/share/applications/gnome-keyring-secrets.desktop"
  local xdg_autostart="/etc/xdg/autostart/gnome-keyring-secrets.desktop"
  if [[ -f "${share_desktop}" ]]; then
    install -d "/etc/xdg/autostart"
    if [[ ! -f "${xdg_autostart}" ]]; then
      install -m 0644 "${share_desktop}" "${xdg_autostart}"
      info "installed ${xdg_autostart}"
    else
      info "autostart entry already present: ${xdg_autostart}"
    fi
  else
    warn "${share_desktop} not found (gnome-keyring may not be installed yet)"
  fi

  info "keyring will unlock automatically at next greetd login"
}

# Local helper — system-file backup mirroring backup_and_install in
# stage-configs.sh, but without expecting the rest of that file's globals
# to be loaded. Kept small so we don't pull in stage-configs.sh here.
backup_and_install_etc() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    rm -f "${target}.bak".* 2>/dev/null || true
    local bak="${target}.bak.$(date +%Y%m%d-%H%M%S)"
    info "  backing up ${target} → ${bak}"
    cp -p "${target}" "${bak}"
  fi
}
