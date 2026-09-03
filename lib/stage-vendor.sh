# lib/stage-vendor.sh — invoke the vendored dms installer script in headless mode.
#
# We vendor the upstream installer from https://install.danklinux.com at
# lib/vendor/danklinux-install.sh. That wrapper handles:
#   - querying the latest dms release tag from the GitHub API
#   - downloading the right gzipped binary for our arch
#   - sha256 verification
#   - decompression + execution
#
# The downloaded `dankinstall` binary itself accepts a headless mode
# (-c <compositor> -t <terminal> -y, plus --include-deps / --exclude-deps /
# --replace-configs flags). We forward [dankinstall] from nokron.toml so
# the install is fully unattended.
#
# dgop is installed via Fedora official repos (dnf5 install dgop) and is
# NOT part of the vendored flow.
#
# The upstream installer refuses to run as root; when [vendored.dms].run_as_user
# is true (default), we drop to target_user via `sudo -u` before invoking.
# `DMS_PRIVESC=sudo` is exported so dms's own subcommands (e.g. dms greeter)
# don't prompt for sudo vs run0 when both are installed.

stage_vendor() {
  local script_rel="${NOKRON_VENDORED_DMS_INSTALL_SCRIPT}"
  if [[ -z "${script_rel}" ]]; then
    info "no [vendored.dms].install_script configured — skipping dms install"
    return 0
  fi

  local script="${NOKRON_REPO_ROOT}/${script_rel}"
  [[ -f "${script}" ]] || die "vendored dms install script not found: ${script}"
  [[ -x "${script}" ]] || chmod +x "${script}"

  section "vendor: dms (headless dankinstall)"

  # Build the headless flag list from [dankinstall] in nokron.toml. We
  # always pin -c / -t / -y so the installer never enters the TUI. The
  # replace/include/exclude lists are only emitted when non-empty so a
  # user who only wants defaults doesn't pass an empty --replace-configs
  # that the binary might reject.
  local -a flags=(
    -c "${NOKRON_DANKINSTALL_COMPOSITOR:-hyprland}"
    -t "${NOKRON_DANKINSTALL_TERMINAL:-ghostty}"
  )
  if [[ "${NOKRON_DANKINSTALL_YES:-true}" == "true" ]]; then
    flags+=( -y )
  fi
  if [[ ${#NOKRON_DANKINSTALL_REPLACE_CONFIGS[@]} -gt 0 ]]; then
    flags+=( --replace-configs "${NOKRON_DANKINSTALL_REPLACE_CONFIGS[*]}" )
  fi
  if [[ ${#NOKRON_DANKINSTALL_INCLUDE_DEPS[@]} -gt 0 ]]; then
    flags+=( --include-deps "${NOKRON_DANKINSTALL_INCLUDE_DEPS[*]}" )
  fi
  if [[ ${#NOKRON_DANKINSTALL_EXCLUDE_DEPS[@]} -gt 0 ]]; then
    flags+=( --exclude-deps "${NOKRON_DANKINSTALL_EXCLUDE_DEPS[*]}" )
  fi

  info "dankinstall flags: ${flags[*]}"

  # Run the installer as the desktop user (it refuses root). Export
  # DMS_PRIVESC=sudo so dms subcommands that need root don't pause to
  # ask which privilege tool to use.
  if [[ "${NOKRON_VENDORED_DMS_RUN_AS_USER}" == "true" ]]; then
    if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
      die "run_as_user=true but target_user '${NOKRON_TARGET_USER}' does not exist"
    fi
    info "running installer as ${NOKRON_TARGET_USER} (script refuses root)"
    sudo -u "${NOKRON_TARGET_USER}" -H \
      env DMS_PRIVESC=sudo \
      "${script}" "${flags[@]}" \
      || die "dms installer failed — see output above"
  else
    warn "run_as_user=false — installer will likely refuse (it requires non-root)"
    DMS_PRIVESC=sudo "${script}" "${flags[@]}" \
      || die "dms installer failed — see output above"
  fi

  # Sanity check: dms binary on PATH. If vendor's installer didn't land
  # dms in ~/.local/bin, the dms stage will fail later anyway — die now
  # with a clearer message.
  if ! command -v dms >/dev/null 2>&1; then
    if ! sudo -u "${NOKRON_TARGET_USER}" -H command -v dms >/dev/null 2>&1; then
      die "dms binary not on PATH after install — vendor stage produced no binary"
    fi
  fi

  info "vendor stage complete"
}
