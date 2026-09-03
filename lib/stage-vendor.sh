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
# field from [dankinstall] in nokron.toml — flag semantics are taken from
# the upstream source:
#   - core/cmd/dankinstall/main.go        (cobra flag definitions)
#   - core/internal/headless/runner.go    (validation + per-dep logic)
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
# use. `dankinstall` itself takes its own `--privesc sudo` flag.

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
  if [[ -n "${NOKRON_DANKINSTALL_PRIVESC}" ]]; then
    flags+=( --privesc "${NOKRON_DANKINSTALL_PRIVESC}" )
  fi

  # Dedicated bool flags. These resolve BEFORE --include-deps in the
  # runner, which is the form we want — explicit opt-in beats generic.
  [[ "${NOKRON_DANKINSTALL_DANKSEARCH:-false}"   == "true" ]] && flags+=( --danksearch )
  [[ "${NOKRON_DANKINSTALL_DANKCALENDAR:-false}" == "true" ]] && flags+=( --dankcalendar )
  # dms-greeter is opt-out by default; the dedicated flag opts back in.
  # We expose the toml as `dms_greeter = true/false` for symmetry with the
  # other two and forward --dms-greeter only when true.
  [[ "${NOKRON_DANKINSTALL_DMS_GREETER:-false}"  == "true" ]] && flags+=( --dms-greeter )

  # StringSliceVar: emit each element as its own --replace-configs flag.
  # pflag accepts comma-lists too, but the repeated-flag form is what the
  # upstream README uses and what avoids the "hyprland ghostty" parsing
  # trap when the list has >1 element.
  if [[ ${#NOKRON_DANKINSTALL_REPLACE_CONFIGS[@]} -gt 0 ]]; then
    for cfg in "${NOKRON_DANKINSTALL_REPLACE_CONFIGS[@]}"; do
      flags+=( --replace-configs "${cfg}" )
    done
  fi

  # Same for --exclude-deps.
  if [[ ${#NOKRON_DANKINSTALL_EXCLUDE_DEPS[@]} -gt 0 ]]; then
    for dep in "${NOKRON_DANKINSTALL_EXCLUDE_DEPS[@]}"; do
      flags+=( --exclude-deps "${dep}" )
    done
  fi

  info "dankinstall flags: ${flags[*]}"

  # ── Sudo credential cache ───────────────────────────────────────────────
  # The runner's resolveSudoPassword() aborts with a clear error if no
  # cached credentials are available, even when --privesc is set. Cache
  # them now so the install is truly unattended. `sudo -v` is a no-op if
  # the cache is already fresh.
  info "priming sudo credential cache"
  sudo -v || die "sudo -v failed — installer needs cached sudo credentials"

  # ── Run the installer as the desktop user ──────────────────────────────
  if [[ "${NOKRON_VENDORED_DMS_RUN_AS_USER}" == "true" ]]; then
    if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
      die "run_as_user=true but target_user '${NOKRON_TARGET_USER}' does not exist"
    fi
    info "running installer as ${NOKRON_TARGET_USER} (script refuses root)"
    # DMS_PRIVESC=sudo pins dms's own priv-esc tool detection. The
    # vendored script itself spawns the downloaded installer with the
    # flags we pass — its --privesc is a separate concern (handled above).
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
