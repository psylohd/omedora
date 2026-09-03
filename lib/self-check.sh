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
  local version_id
  version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  info "running on Fedora ${version_id:-unknown}"

  # 2. Confirm target user exists + has a real home.
  if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
    die "target_user '${NOKRON_TARGET_USER}' does not exist on this system.
  Create it first:  useradd -m ${NOKRON_TARGET_USER}"
  fi
  local home
  home="$(getent passwd "${NOKRON_TARGET_USER}" | cut -d: -f6)"
  if [[ ! -d "${home}" ]]; then
    die "home directory '${home}' does not exist for ${NOKRON_TARGET_USER}"
  fi
  info "target user: ${NOKRON_TARGET_USER} (home=${home})"
  # 3. Plymouth hard dep: nokron theme uses ModuleName=script. If it's
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

  # 4. Greetd + greeter user. greetd's RPM creates the 'greeter' user on
  #    install; install greetd now if the greetd stage is enabled and it's
  #    missing.
  if ! id greeter >/dev/null 2>&1; then
    if [[ "${NOKRON_STAGE_GREETD}" == "true" ]]; then
      warn "the 'greeter' user does not exist — installing greetd now"
      dnf5 -y install greetd \
        || die "dnf5 install greetd failed. Run manually:
  sudo dnf5 install greetd"
    fi
  fi

  # 5. (sha256 verification removed — vendored binaries are downloaded
  # 6. Network sanity for the vendor stage. Cheap curl --head to the
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

  # 10. If we're going to use dms-greeter, confirm the binary landed.
  if [[ "${NOKRON_STAGE_GREETD}" == "true" ]] \
     && [[ "${NOKRON_GREETER_BACKEND}" == "dms-greeter" ]]; then
    if [[ ! -x "${NOKRON_VENDORED_DMS_INSTALL_DIR}/dms-greeter" ]]; then
      die "greeter backend is 'dms-greeter' but ${NOKRON_VENDORED_DMS_INSTALL_DIR}/dms-greeter is missing.
  Either enable [stages].vendor first to install the binary, or switch
  [greeter].backend to 'tuigreet'."
    fi
  fi

  info "self-check passed"
}
