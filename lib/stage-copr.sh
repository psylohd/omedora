# lib/stage-copr.sh — enable the COPRs listed in nokron.toml.
#
# Idempotent: `dnf5 copr enable` is a no-op when the repo is already enabled.
#
# Stage order matters: this runs before `dnf`, so packages installed
# by [packages.*] can resolve against any COPR enabled here.

stage_copr() {
  section "copr"
  command -v dnf5 >/dev/null 2>&1 || die "dnf5 not found — this installer targets Fedora."

  if [[ ${#NOKRON_COPRS[@]} -eq 0 ]]; then
    info "no COPRs configured in nokron.toml"
  else
  for copr in "${NOKRON_COPRS[@]}"; do
    if dnf5 -q copr list 2>/dev/null | grep -qx "${copr}/enabled"; then
      info "  ${copr} already enabled"
    else
      info "  enabling ${copr}"
      dnf5 -y copr enable "${copr}" || die "failed to enable COPR: ${copr}"
    fi
    # COPR-generated .repo files have gpgcheck=1 but the RPM signatures
    # often don't validate (key imported, payload untrusted). Patch the repo
    # file to gpgcheck=0 so both `dnf5 install` and any sub-script's dnf
    # call (e.g. vendored dankinstall) skip verification for these repos.
    local repo_file="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:${copr//\//:}.repo"
    if [[ -f "${repo_file}" ]]; then
      sed -i 's/^gpgcheck=1$/gpgcheck=0/' "${repo_file}"
    fi
  done
  fi

  # RPM Fusion is also useful for media codecs on Fedora Server. Skip if
  # already enabled. (Not in nokron.toml by default — keep it explicit.)
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    info "RPM Fusion not present (skipping — add it to [coprs] if you need codecs)"
  fi
}
