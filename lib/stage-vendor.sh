# lib/stage-vendor.sh — invoke the vendored dms installer script in headless mode.
#
# We vendor the upstream installer from https://install.danklinux.com at
# lib/vendor/danklinux-install.sh. That wrapper handles:
#   - querying the latest dms release tag from the GitHub API
#   - downloading the right gzipped binary for our arch
#   - sha256 verification
#   - decompression + execution
#
# The downloaded `dankinstall` binary accepts a headless mode that requires
# both `--compositor` and `--term` plus `--yes`. We forward every relevant
# field from [dankinstall] in nokron.toml — flag semantics verified against
# the **latest released** tag (v1.5.3 at the time of writing), not master
# HEAD. master has unreleased flags like `--privesc` and `--dms-greeter`
# that the released binary rejects with "unknown flag". Re-verify against
# the latest tag whenever [vendored.dms] drifts.
#
# Critical pflag gotcha: --replace-configs and --exclude-deps are
# StringSliceVar. They accept BOTH `--flag a,b` (comma list) and
# `--flag a --flag b` (repeated), but the bash `"${arr[*]}"` form expands
# to a space-separated list which pflag treats as a single value with
# embedded spaces, then the runner's `validConfigNames[strings.ToLower(name)]`
# lookup fails with "unknown config 'hyprland ghostty'". We MUST emit each
# element as its own flag, or join with a comma. The repeated-flag form is
# unambiguous regardless of how the list is configured.
#
# The upstream installer refuses to run as root. We drop to target_user
# via `sudo -u` and export `DMS_PRIVESC=sudo` so subsequent dms subcommands
# (e.g. `dms greeter install`) don't pause to ask which privilege tool to
# use. The dankinstall binary itself autodetects sudo/doas/run0 from
# what's installed on the system (the released v1.5.3 has no --privesc
# flag; the runner's privesc autodetect handles this).

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

  # ── Build the headless flag list ─────────────────────────────────────────
  # Required for headless mode: -c + -t + -y. The runner aborts with
  # ErrConfirmationRequired if -y is missing.
  local -a flags=(
    -c "${NOKRON_DANKINSTALL_COMPOSITOR:-hyprland}"
    -t "${NOKRON_DANKINSTALL_TERMINAL:-ghostty}"
  )
  if [[ "${NOKRON_DANKINSTALL_YES:-true}" == "true" ]]; then
    flags+=( -y )
  fi

  # Dedicated bool flags in v1.5.3: --danksearch, --dankcalendar.
  # (--dms-greeter exists on master HEAD but not in v1.5.3; we use the
  # generic --exclude-deps "dms-greeter" instead, which works in both.)
  [[ "${NOKRON_DANKINSTALL_DANKSEARCH:-false}"   == "true" ]] && flags+=( --danksearch )
  [[ "${NOKRON_DANKINSTALL_DANKCALENDAR:-false}" == "true" ]] && flags+=( --dankcalendar )

  # StringSliceVar: emit each element as its own --replace-configs flag.
  # pflag accepts comma-lists too, but the repeated-flag form is what the
  # upstream README uses and what avoids the "hyprland ghostty" parsing
  # trap when the list has >1 element.
  if [[ ${#NOKRON_DANKINSTALL_REPLACE_CONFIGS[@]} -gt 0 ]]; then
    for cfg in "${NOKRON_DANKINSTALL_REPLACE_CONFIGS[@]}"; do
      flags+=( --replace-configs "${cfg}" )
    done
  fi

  # Same for --exclude-deps and --include-deps.
  if [[ ${#NOKRON_DANKINSTALL_EXCLUDE_DEPS[@]} -gt 0 ]]; then
    for dep in "${NOKRON_DANKINSTALL_EXCLUDE_DEPS[@]}"; do
      flags+=( --exclude-deps "${dep}" )
    done
  fi
  if [[ ${#NOKRON_DANKINSTALL_INCLUDE_DEPS[@]} -gt 0 ]]; then
    for dep in "${NOKRON_DANKINSTALL_INCLUDE_DEPS[@]}"; do
      flags+=( --include-deps "${dep}" )
    done
  fi

  info "dankinstall flags: ${flags[*]}"

  # ── Run the installer as the desktop user ──────────────────────────────
  if [[ "${NOKRON_VENDORED_DMS_RUN_AS_USER}" != "true" ]]; then
    warn "run_as_user=false — installer will likely refuse (it requires non-root)"
    DMS_PRIVESC=sudo "${script}" "${flags[@]}" \
      || die "dms installer failed — see output above"
  else
    if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
      die "run_as_user=true but target_user '${NOKRON_TARGET_USER}' does not exist"
    fi

    # ── Sudo credential cache for the target user ──────────────────────
    # The runner's `privesc.CheckCached()` runs `sudo -n true` under
    # target_user's identity and aborts mid-install if it fails. The
    # self_check stage drops a NOPASSWD sudoers file by default; if
    # that didn't happen (either because [sudo].passwordless=false or
    # because the file wasn't writable), the install will fail with a
    # confusing "sudo auth required" error. Check upfront and die with
    # a clear message so the user can fix it instead of waiting for
    # the runner to bail at an arbitrary point.
    if ! sudo -u "${NOKRON_TARGET_USER}" sudo -n true 2>/dev/null; then
      die "${NOKRON_TARGET_USER} cannot run sudo non-interactively.

  The vendored dms installer needs cached sudo credentials for
  ${NOKRON_TARGET_USER} (it calls sudo internally for dnf/copr).
  Self-check did not (or could not) set this up.

  Fix: either re-enable [sudo].passwordless = true in nokron.toml and
  re-run, or pre-cache the user's creds before re-running:
    sudo -u ${NOKRON_TARGET_USER} sudo -v
  Or grant NOPASSWD manually:
    echo '${NOKRON_TARGET_USER} ALL=(ALL) NOPASSWD: ALL' \\
      > /etc/sudoers.d/99-nokron-${NOKRON_TARGET_USER} \\
      && chmod 0440 /etc/sudoers.d/99-nokron-${NOKRON_TARGET_USER}"
    fi

    info "running installer as ${NOKRON_TARGET_USER} (script refuses root)"
    # DMS_PRIVESC=sudo pins dms's own priv-esc tool detection for any
    # dms subcommands spawned after the installer (e.g. `dms greeter
    # install`). The vendored script itself spawns the downloaded
    # installer with the flags we pass — its privesc is autodetected
    # by the runner from whatever's on the system.
    sudo -u "${NOKRON_TARGET_USER}" -H \
      env DMS_PRIVESC=sudo \
      "${script}" "${flags[@]}" \
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
