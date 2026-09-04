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
  dnf5 -y install "${dms_opts[@]}" --exclude dms-greeter dms \
    || die "dms install failed"

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

  # Post-install verification: ghostty is the SUPER+RETURN terminal
  # launch target. It comes in as a weak-dep of dms or another
  # danklinux package; on a fresh install with weak-deps enabled,
  # dnf can silently skip it if its transaction conflicts (especially
  # when scottames/ghostty is also enabled — see [coprs] in
  # omedora.toml). If ghostty didn't land, retry from the danklinux
  # COPR explicitly. Failing the whole stage just because of a weak-
  # dep is overzealous; a loud warning is the right level.
  if ! rpm -q ghostty >/dev/null 2>&1; then
    warn "ghostty not installed after dnf stage; retrying from avengemedia/danklinux"
    if dnf5 -y install --setopt='avengemedia/danklinux.gpgcheck=0' \
                         --setopt='copr*.gpgcheck=0' ghostty; then
      info "ghostty recovered via fallback install"
    else
      warn "ghostty install failed again — re-run \`dnf5 install ghostty\` later"
    fi
  fi
}