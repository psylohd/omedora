# lib/stage-copr.sh — enable the COPRs and other package repos listed in
# nokron.toml.
#
# Two kinds of repos are handled here:
#   - COPRs (`[coprs].enable`) — enabled via `dnf5 copr enable`. Idempotent.
#   - Third-party RPM repos (`[repos.*]`) — installed via a bootstrap
#     `dnf install` of their release package. The first install needs
#     `--nogpgcheck` because the GPG key isn't trusted yet; subsequent
#     re-runs detect the release package is already installed and skip
#     the bootstrap, so GPG verification is normal.
#
# Stage order matters: this runs before `dnf`, so packages installed
# by [packages.*] can resolve against any repo enabled here.

stage_copr() {
  section "copr"
  command -v dnf5 >/dev/null 2>&1 || die "dnf5 not found — this installer targets Fedora."

  # ── COPRs ──────────────────────────────────────────────────────────────────
  if [[ ${#NOKRON_COPRS[@]} -eq 0 ]]; then
    info "no COPRs configured in nokron.toml"
  else
    info "enabling ${#NOKRON_COPRS[@]} COPR(s): ${NOKRON_COPRS[*]}"
    for copr in "${NOKRON_COPRS[@]}"; do
      if dnf5 -q copr list 2>/dev/null | grep -qx "${copr}/enabled"; then
        info "  ${copr} already enabled"
        continue
      fi
      info "  enabling ${copr}"
      dnf5 -y copr enable "${copr}" || die "failed to enable COPR: ${copr}"
    done
  fi

  # ── Terra (Fyra Labs rolling-release repo) ────────────────────────────────
  if [[ "${NOKRON_TERRA_ENABLE}" == "true" ]]; then
    if rpm -q terra-release >/dev/null 2>&1; then
      info "terra-release already installed — Terra repo available"
    else
      info "installing Terra (fyralabs) repo"
      # Per https://developer.fyralabs.com/terra/installing:
      #   sudo dnf install --nogpgcheck \
      #     --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
      #     terra-release
      # --nogpgcheck because the GPG key is inside terra-release itself
      # (chicken-and-egg on first install). $releasever is expanded by
      # dnf5 to the running Fedora major version. Re-runs of this stage
      # see terra-release already installed and skip the bootstrap, so
      # GPG verification is normal for everything else from Terra.
      dnf5 -y install \
        --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
        terra-release \
        || die "failed to install Terra (terra-release)"
      info "Terra repo enabled"
    fi
  fi

  # RPM Fusion is also useful for media codecs on Fedora Server. Skip if
  # already enabled. (Not in nokron.toml by default — keep it explicit.)
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    info "RPM Fusion not present (skipping — add it to [coprs] if you need codecs)"
  fi
}
