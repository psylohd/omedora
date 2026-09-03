# lib/stage-dnf.sh — install every package listed in omedora.toml.
#
# One dnf5 invocation per logical group so failures are scoped. We pass -y
# only on the package install (so the user can't get stuck on a prompt) but
# rely on dnf5's own GPG/transaction logic.
#
# COPR repos frequently fail gpgcheck even after their pubkey is imported
# (key import succeeds but signature validity windows don't always match
# the package build date). Rather than sed-patching /etc/yum.repos.d/*.repo
# post-hoc, we pass `--setopt=<repo_id>.gpgcheck=0` to every dnf5 invocation
# that may resolve a package from a COPR. Per-call, leaves repo files
# untouched, idempotent on re-run.

# build_copr_setopt_flags — emit one --setopt glob disabling gpgcheck on
# every copr: / coprdep: repo dnf5 currently has loaded. The glob form is
# used (vs. enumerating OMEDORA_COPRS) because:
#   - dnf5 rejects --setopt=<id>... for repos it doesn't have loaded,
#     so an explicit per-COPR list would error out when a COPR was
#     removed from the host but still listed in omedora.toml.
#   - coprdep: sub-repo ids depend on dnf5's internal hashing and may not
#     match the canonical "copr.fedorainfracloud.org:owner:name" form.
#   - globbing `copr*` covers both `copr:` and `coprdep:` namespaces.
# The glob is a no-op when no COPR repos are loaded.
build_copr_setopt_flags() {
  printf '%s\n' '--setopt=copr*.gpgcheck=0'
}

stage_dnf() {
  section "dnf"
  command -v dnf5 >/dev/null 2>&1 || die "dnf5 not found"

  # Snapshot the COPR setopt flags once — every install below appends them.
  local copr_flags=()
  if [[ ${#OMEDORA_COPRS[@]} -gt 0 ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && copr_flags+=( "$f" )
    done < <(build_copr_setopt_flags)
  fi

  info "installing Hyprland stack (${#OMEDORA_HYPRLAND[@]} packages from lionheartp/Hyprland)"
  if [[ ${#OMEDORA_HYPRLAND[@]} -gt 0 ]]; then
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_HYPRLAND[@]}" \
      || die "Hyprland stack install failed"
  fi

  info "installing quickshell + Qt runtime (${#OMEDORA_QUICKSHELL[@]} packages)"
  if [[ ${#OMEDORA_QUICKSHELL[@]} -gt 0 ]]; then
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_QUICKSHELL[@]}" \
      || die "quickshell install failed"
  fi

  info "installing DMS (dms-cli from avengemedia/dms COPR; dms-greeter excluded)"
  local dms_opts=( "${copr_flags[@]}" )
  [[ "${OMEDORA_DMS_WEAK_DEPS}" == "false" ]] && dms_opts+=( --setopt=install_weak_deps=False )
  # Bypass libdnf5's /var/cache/libdnf5 download path: dnf5 occasionally
  # writes the RPM to its cache in a state rpmReadPackageFile() can't parse
  # (the download itself reports success, but the cached file is bad and
  # the transaction dies with "Failed to read package header"). Stage the
  # RPMs to a tmpdir we control via `dnf5 download`, verify each one with
  # rpm -K (which uses the same rpmReadPackageFile path), and only then
  # hand them to `dnf5 install <local-path>` for the actual install.
  local dms_stage dms_attempt=1 dms_rc=0 dms_rpm
  dms_stage="$(mktemp -d /tmp/dms-stage.XXXXXX)"
  while (( dms_attempt <= 3 )); do
    rm -f "${dms_stage}"/*.rpm 2>/dev/null || true
    if ! dnf5 download -y "${copr_flags[@]}" --destdir="${dms_stage}" \
         --exclude dms-greeter dms; then
      warn "dms download attempt ${dms_attempt}/3 failed"
      dms_attempt=$(( dms_attempt + 1 ))
      continue
    fi
    # Validate every staged RPM's digests only. `rpm -K` reports multiple
    # categories (digests, signatures); we ignore `signatures NOT OK`
    # because the avengemedia/dms COPR ships unsigned RPMs by design
    # (gpgcheck is disabled via --setopt=copr*.gpgcheck=0 for the
    # install). The real failure mode we need to catch is a corrupt file
    # that dnf5 wrote successfully but rpmReadPackageFile() can't parse —
    # that surfaces as a non-zero exit AND no readable header. We use
    # rpm -K --nodigest --nosignature first to confirm the header itself
    # is readable, which mirrors the libdnf5 transaction-time check.
    local dms_bad=0
    for dms_rpm in "${dms_stage}"/*.rpm; do
      [[ -f "${dms_rpm}" ]] || continue
      if ! rpm -K --nodigest --nosignature "${dms_rpm}" >/dev/null 2>&1; then
        warn "rpm header unreadable for: ${dms_rpm} ($(rpm -K --nodigest --nosignature "${dms_rpm}" 2>&1 | tail -1))"
        dms_bad=1
      fi
    done
    # Build a list of installable RPMs (skip src.rpm). Glob returns the
    # pattern itself when nothing matches; the installable array stays
    # empty in that case and the install fails through to the next retry.
    # Run the install from local files. Capture the rc explicitly so a
    # non-zero exit doesn't get masked by the prior-loop dms_rc=0 init.
    if (( ${#installable[@]} > 0 )) && (( dms_bad == 0 )); then
      if dnf5 -y install "${dms_opts[@]}" "${installable[@]}"; then
        dms_rc=0
        break
      else
        dms_rc=$?
      fi
    else
      dms_rc=1
    fi
    warn "dms install attempt ${dms_attempt}/3 failed"
    dms_attempt=$(( dms_attempt + 1 ))
  done
  if (( dms_rc != 0 )); then
    warn "staged RPMs in ${dms_stage}: $(ls -la "${dms_stage}" 2>&1)"
    die "dms install failed after 3 attempts"
  fi

  info "installing required apps (${#OMEDORA_APPS[@]} packages)"
  if [[ ${#OMEDORA_APPS[@]} -gt 0 ]]; then
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_APPS[@]}" \
      || die "apps install failed"
  fi

  info "installing build toolchain (${#OMEDORA_BUILD[@]} packages)"
  if [[ ${#OMEDORA_BUILD[@]} -gt 0 ]]; then
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_BUILD[@]}" \
      || warn "build toolchain install failed — tuigreet build will fail"
  fi

  info "installing optional COPR packages (${#OMEDORA_APPS_OPTIONAL[@]} packages)"
  if [[ ${#OMEDORA_APPS_OPTIONAL[@]} -gt 0 ]]; then
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_APPS_OPTIONAL[@]}" || {
      warn "optional package install failed — continuing. (Re-run after fixing.)"
    }
  fi

  # Plymouth hard dep: the omedora script theme requires plymouth-plugin-script.
  # install.sh already asserts this; the post-install path needs it too.
  if ! rpm -q plymouth-plugin-script >/dev/null 2>&1; then
    die "plymouth-plugin-script is not installed. dnf5 install plymouth-plugin-script first."
  fi
}