# lib/self-check.sh — pre-flight validation before any stage runs.
#
# Runs as part of fedora_install.sh after load_config() and before any
# destructive operation. Catches the common "I forgot to fill in the
# dms sha256s" footgun so the user finds out before dnf5 spends 10 minutes
# installing the world.

self_check() {
  section "self-check"

  # 1. Confirm Fedora + dnf5.
  if ! command -v dnf5 >/dev/null 2>&1; then
    die "dnf5 not in PATH — this installer targets Fedora. Wrong host?"
  fi
  if ! grep -q '^ID=fedora' /etc/os-release 2>/dev/null; then
    warn "/etc/os-release does not advertise ID=fedora — continuing"
  fi
  local version_id=""
  version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  info "running on Fedora ${version_id:-unknown}"

  # 2. Confirm target user exists + has a real home.
  if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
    die "target_user '${NOKRON_TARGET_USER}' does not exist on this system.
  Create it first:  useradd -m ${NOKRON_TARGET_USER}"
  fi
  local home=""
  home="$(getent passwd "${NOKRON_TARGET_USER}" | cut -d: -f6)"
  if [[ ! -d "${home}" ]]; then
    die "home directory '${home}' does not exist for ${NOKRON_TARGET_USER}"
  fi
  info "target user: ${NOKRON_TARGET_USER} (home=${home})"

  # 2b. Passwordless sudo for target_user. The vendored dms installer
  # (dankinstall) runs as target_user but needs root for dnf/copr/systemctl.
  # Its `privesc.CheckCached()` (which runs `sudo -n true`) aborts cleanly
  # if target_user lacks cached credentials. Stock Fedora Server doesn't
  # give created users NOPASSWD sudo, so we drop a sudoers file here
  # (idempotent, validated with `visudo -c` before install) to make the
  # install actually unattended. Opt out via [sudo].passwordless = false
  # in nokron.toml; clean up by deleting the file (documented inline).
  if [[ "${NOKRON_SUDO_PASSWORDLESS:-true}" == "true" ]]; then
    local sudoers_file="/etc/sudoers.d/99-nokron-${NOKRON_TARGET_USER}"
    # Skip if target_user already has any NOPASSWD sudo rule — don't
    # clobber an existing setup (e.g. they're in %wheel with NOPASSWD).
    if sudo -l -U "${NOKRON_TARGET_USER}" 2>/dev/null \
         | grep -qE 'NOPASSWD:[[:space:]]*ALL'; then
      info "target_user already has NOPASSWD sudo — not adding ours"
    elif [[ -f "${sudoers_file}" ]]; then
      info "${sudoers_file} already present — not overwriting"
    else
      info "granting NOPASSWD sudo to ${NOKRON_TARGET_USER}"
      # Use a sudoers.d drop-in (parses cleanly, easy to remove) with
      # the same content visudo would accept. `visudo -c -f` validates
      # the file before we leave it on disk, so a syntax error won't
      # lock out the system.
      printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${NOKRON_TARGET_USER}" \
        > "${sudoers_file}".tmp
      chmod 0440 "${sudoers_file}".tmp
      if ! visudo -c -f "${sudoers_file}".tmp >/dev/null; then
        rm -f "${sudoers_file}".tmp
        die "visudo rejected the proposed sudoers file; refusing to write ${sudoers_file}"
      fi
      install -m 0440 "${sudoers_file}".tmp "${sudoers_file}"
      rm -f "${sudoers_file}".tmp
      info "wrote ${sudoers_file} (remove with: sudo rm ${sudoers_file})"
    fi
  else
    info "[sudo].passwordless=false — not granting NOPASSWD; ensure target_user's cache is primed"
  fi

  # 3. Plymouth script plugin. If plymouth is missing the script-plugin is
  #    missing and the plymouth stage is enabled, install it now rather
  #    than aborting — much friendlier when running on a fresh server.
  if ! rpm -q plymouth-plugin-script >/dev/null 2>&1; then
    if [[ "${NOKRON_STAGE_PLYMOUTH}" == "true" ]]; then
      warn "plymouth-plugin-script is NOT installed — installing now"
      dnf5 -y install plymouth-plugin-script \
        || die "dnf5 install plymouth-plugin-script failed. Run manually:
  sudo dnf5 install plymouth-plugin-script"
    else
      info "plymouth-plugin-script not installed (plymouth stage disabled — skipping)"
    fi
  fi

  # 4. Greetd system user. The greetd RPM creates a 'greetd' user (not
  #    'greeter' — that's dms-greeter's convention). If it's missing and
  #    the greetd stage is enabled, install greetd to materialise it.
  if ! id greetd >/dev/null 2>&1; then
    if [[ "${NOKRON_STAGE_GREETD}" == "true" ]]; then
      warn "the 'greetd' user does not exist — installing greetd now"
      dnf5 -y install greetd \
        || die "dnf5 install greetd failed. Run manually:
  sudo dnf5 install greetd"
    fi
  fi

  # 5. Network sanity for the vendor stage. Cheap curl --head to the
  #    GitHub release hostname; non-fatal but warn.
  if [[ "${NOKRON_STAGE_VENDOR}" == "true" ]] || \
     [[ "${NOKRON_STAGE_COPR}" == "true" ]] || \
     [[ "${NOKRON_STAGE_FLATPAK}" == "true" ]]; then
    if ! curl -fsSL --max-time 5 -o /dev/null https://github.com 2>/dev/null; then
      warn "github.com unreachable — vendor / COPR / flatpak stages may fail"
    fi
  fi

  # 7. Plymouth theme source must exist if plymouth stage is enabled.
  if [[ "${NOKRON_STAGE_PLYMOUTH}" == "true" ]]; then
    if [[ ! -d "${NOKRON_PATH_PLYMOUTH}" ]]; then
      die "plymouth source dir not found: ${NOKRON_PATH_PLYMOUTH}"
    fi
    if [[ ! -f "${NOKRON_PATH_PLYMOUTH}/nokron.plymouth" ]]; then
      die "nokron.plymouth not found in ${NOKRON_PATH_PLYMOUTH}"
    fi
  fi

  # 8. tuigreet: skip src-workspace check if we'll clone fresh from
  #    [vendored.tuigreet].repo_url. Otherwise, require a pre-cloned
  #    Cargo workspace at [paths.repo].tuigreet_src.
  if [[ "${NOKRON_STAGE_TUIGREET}" == "true" ]]; then
    if [[ -z "${NOKRON_TUIGREET_REPO_URL}" ]]; then
      if [[ ! -d "${NOKRON_PATH_TUIGREET_SRC}" ]]; then
        die "tuigreet Cargo workspace not found: ${NOKRON_PATH_TUIGREET_SRC}
Set [vendored.tuigreet].repo_url + branch (recommended), or point
[paths.repo].tuigreet_src at a directory containing Cargo.toml."
      fi
      if [[ ! -f "${NOKRON_PATH_TUIGREET_SRC}/Cargo.toml" ]]; then
        die "Cargo.toml missing in ${NOKRON_PATH_TUIGREET_SRC}"
      fi
    fi
    if [[ ! -f "${NOKRON_PATH_TUIGREET}/nokron.theme.toml" ]]; then
      die "tuigreet theme not found: ${NOKRON_PATH_TUIGREET}/nokron.theme.toml"
    fi
  fi

  # 9. Hyprland + quickshell config dirs are optional — the script handles
  #    a missing dir gracefully (warn + skip). But warn the user upfront.
  if [[ "${NOKRON_STAGE_HYPRLAND}" == "true" ]] \
     && [[ ! -d "${NOKRON_PATH_HYPRLAND}" ]]; then
    warn "hyprland config dir not found: ${NOKRON_PATH_HYPRLAND}
  Create it with your config (at minimum hyprland.conf) before running.
  Continuing — the stage will no-op."
  fi
  if [[ "${NOKRON_STAGE_QUICKSHELL}" == "true" ]] \
     && [[ ! -d "${NOKRON_PATH_QUICKSHELL}" ]]; then
    warn "quickshell config dir not found: ${NOKRON_PATH_QUICKSHELL}
  Create it (at minimum shell.qml for dms) before running.
  Continuing — the stage will no-op."
  fi

  info "self-check passed"
}
