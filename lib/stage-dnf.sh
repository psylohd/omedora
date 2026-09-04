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

  # Add external repos (e.g. Docker CE from docker-ce.repo).
  # Each URL is fetched and registered with dnf5 config-manager addrepo.
  for _repo_url in "${OMEDORA_REPOS[@]}"; do
    info "adding repo: ${_repo_url}"
    dnf5 -y config-manager addrepo --from-repofile "${_repo_url}" \
      || warn "failed to add repo ${_repo_url} (continuing)"
  done
  # Vendored .repo files — when upstream doesn't host a stable .repo URL
  # (so `dnf5 config-manager addrepo --from-repofile` can't reach it), we
  # ship the repo contents in-repo and write them under /etc/yum.repos.d/.
  # Each entry surfaces two env vars: ``OMEDORA_VENDORED_REPO_<NAME>__FILE``
  # (verbatim .repo content; `\n` escapes are decoded by printf %b) and
  # ``OMEDORA_VENDORED_REPO_<NAME>__PACKAGE`` (package to install after).
  # The repo filename mirrors the section key (slashes / hyphens turn
  # into underscores to stay legal as a filename on every filesystem).
  for _vr_var in $(compgen -v OMEDORA_VENDORED_REPO_ 2>/dev/null); do
    [[ "${_vr_var}" == *__FILE ]] && continue
    local _vr_pkg="${!_vr_var}"
    [[ -n "${_vr_pkg}" ]] || continue
    local _vr_name="${_vr_var#OMEDORA_VENDORED_REPO_}"
    _vr_name="${_vr_name%__PACKAGE}"
    local _vr_name_lc="${_vr_name,,}"   # lowercase for filename
    local _vr_file_var="OMEDORA_VENDORED_REPO_${_vr_name}__FILE"
    local _vr_content="${!_vr_file_var}"
    [[ -n "${_vr_content}" ]] || continue
    local _vr_path="/etc/yum.repos.d/${_vr_name_lc}.repo"
    info "writing vendored repo: ${_vr_path} (will install: ${_vr_pkg})"
    # printf %b decodes \n escapes that python's repr() put into the string
    # when TOML triple-quoted strings went through emit().
    printf '%b\n' "${_vr_content}" > "${_vr_path}" \
      || warn "failed to write ${_vr_path}"
    chmod 0644 "${_vr_path}"
  done

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

  # hyprpm build toolchain + HyprCapture runtime deps (added as a sibling
  # install to keep the Hyprland transaction independent — if the COPR
  # `hyprland-devel` is missing on a one-off run, the core Hyprland
  # install still succeeds and only the plugin build path errors).
  if [[ ${#OMEDORA_HYPRLAND_BUILD[@]} -gt 0 ]]; then
    info "installing hyprpm build toolchain + HyprCapture runtime deps (${#OMEDORA_HYPRLAND_BUILD[@]} packages)"
    dnf5 -y install "${copr_flags[@]}" "${OMEDORA_HYPRLAND_BUILD[@]}" \
      || die "hyprpm build deps install failed"
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
  # Packages from external repos (e.g. Docker CE from [repos]).
  # COPR flags are intentionally omitted — these repos are not COPRs.
  info "installing external-repo packages (${#OMEDORA_DOCKER[@]} packages)"
  if [[ ${#OMEDORA_DOCKER[@]} -gt 0 ]]; then
    dnf5 -y install "${OMEDORA_DOCKER[@]}" \
      || die "external-repo packages install failed"
  fi

  # Plymouth hard dep: the omedora script theme requires plymouth-plugin-script.
  # install.sh already asserts this; the post-install path needs it too.
  if ! rpm -q plymouth-plugin-script >/dev/null 2>&1; then
    die "plymouth-plugin-script is not installed. dnf5 install plymouth-plugin-script first."
  fi

  # Post-install verification: ghostty is the SUPER+RETURN terminal
  # launch target. Listed explicitly in [packages.apps].required so the
  # install doesn't depend on it being a weak-dep of dms (which dnf5
  # sometimes drops silently on a transaction conflict). This check is
  # belt-and-braces: if the explicit install failed for whatever reason,
  # try the deprecated weak-dep recovery path one last time. A loud
  # warning is the right level — failing the whole dnf stage for a
  # single optional app is overzealous.
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