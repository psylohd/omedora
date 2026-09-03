# lib/stage-vendor.sh — invoke the vendored dms installer script.
#
# We vendor the upstream installer from https://install.danklinux.com at
# lib/vendor/danklinux-install.sh. That script handles:
#   - querying the latest dms release tag from the GitHub API
#   - downloading the right gzipped binary for our arch
#   - sha256 verification (better than our previous no-verify stance)
#   - decompression + execution
#
# dgop is installed via Fedora official repos (dnf5 install dgop) and is
# NOT part of the vendored flow.
#
# The upstream installer refuses to run as root; when [vendored.dms].run_as_user
# is true (default), we drop to target_user via `sudo -u` before invoking.

stage_vendor() {
  local script_rel="${NOKRON_VENDORED_DMS_INSTALL_SCRIPT}"
  if [[ -z "${script_rel}" ]]; then
    info "no [vendored.dms].install_script configured — skipping dms install"
    return 0
  fi

  local script="${NOKRON_REPO_ROOT}/${script_rel}"
  [[ -f "${script}" ]] || die "vendored dms install script not found: ${script}"
  [[ -x "${script}" ]] || chmod +x "${script}"

  section "vendor: dms (via upstream installer)"

  # The upstream installer queries the GitHub releases API itself, so we
  # don't pin a version here. To upgrade dms, just re-run this stage —
  # it will fetch the latest release.
  if [[ "${NOKRON_VENDORED_DMS_RUN_AS_USER}" == "true" ]]; then
    if ! id "${NOKRON_TARGET_USER}" >/dev/null 2>&1; then
      die "run_as_user=true but target_user '${NOKRON_TARGET_USER}' does not exist"
    fi
    info "running installer as ${NOKRON_TARGET_USER} (script refuses root)"
    sudo -u "${NOKRON_TARGET_USER}" -H "${script}" \
      || die "dms installer failed — see output above"
  else
    warn "run_as_user=false — installer will likely refuse (it requires non-root)"
    "${script}" || die "dms installer failed — see output above"
  fi

  info "vendor stage complete"
}
