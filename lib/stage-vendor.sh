# lib/stage-vendor.sh — download + install vendored binaries from a pinned
# GitHub release.
#
# No signature verification. This is a personal postinstall script; the
# download is trusted implicitly. If you want sha256 checksums, fork this
# stage and re-add them.
#
# To upgrade: bump [vendored.dms].version in nokron.toml, re-run
# `install.sh --only vendor`.

stage_vendor() {
  if [[ -z "${NOKRON_VENDORED_DMS_VERSION}" ]]; then
    info "no vendored binaries configured"
    return 0
  fi

  section "vendor: dms ${NOKRON_VENDORED_DMS_VERSION}"

  local version="${NOKRON_VENDORED_DMS_VERSION}"
  local base="${NOKRON_VENDORED_DMS_BASE_URL}"
  local dest="${NOKRON_VENDORED_DMS_INSTALL_DIR}"

  [[ -n "${base}" ]]   || die "[vendored.dms].base_url is empty"
  [[ -d "${dest}" ]]   || install -d "${dest}"

  local tmp
  tmp="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "${tmp}"' RETURN

  for bin in "${NOKRON_VENDORED_DMS_BINS[@]}"; do
    local url="${base}/${version}/${bin}"
    local out="${tmp}/${bin}"

    info "downloading ${bin} (${version})"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${out}" "${url}"; then
      die "download failed: ${url}"
    fi

    info "installing ${bin} → ${dest}/${bin}"
    install -m 0755 "${out}" "${dest}/${bin}"
  done

  # NOKRON_VENDORED_DMS_UNIT was used by dms-greeter. We don't ship that
  # anymore (tuigreet handles the greeter). Left in the TOML for legacy
  # but not acted on here.

  info "vendor stage complete"
}
