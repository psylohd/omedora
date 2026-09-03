# lib/stage-vendor.sh — build tuigreet from the vendored git source.
#
# tuigreet is built from a git repo (psylohd/tuigreet fork) using cargo.
# The build toolchain (rust, cargo) is installed by stage_dnf.
# dms itself is now installed as a COPR package — no vendor script needed.
#
# The binary is installed to /usr/local/bin/tuigreet (not /usr/bin, which
# is reserved for rpm-owned files on Fedora).

stage_vendor() {
  section "vendor: tuigreet"
  require_root

  local repo_url="${NOKRON_TUIGREET_REPO_URL}"
  local branch="${NOKRON_TUIGREET_BRANCH}"
  local commit="${NOKRON_TUIGREET_COMMIT}"

  if [[ -z "${repo_url}" ]]; then
    info "tuigreet vendoring disabled (empty repo_url)"
    return 0
  fi

  # Build toolchain must have been installed by stage_dnf.
  command -v cargo >/dev/null 2>&1 || \
    die "cargo not in PATH — build toolchain install failed"

  # Rust's default toolchain is stable. tuigreet builds fine on stable.
  # Override with RUSTUP_TOOLCHAIN if you need a specific version.

  local build_dir
  build_dir="$(mktemp -d)"
  trap 'rm -rf "${build_dir}"' EXIT

  info "cloning tuigreet: ${repo_url}"
  git clone --depth=1 -b "${branch}" "${repo_url}" "${build_dir}/tuigreet" \
    || die "failed to clone tuigreet"

  if [[ -n "${commit}" ]]; then
    info "checking out pinned commit: ${commit}"
    git -C "${build_dir}/tuigreet" checkout "${commit}" \
      || die "failed to checkout commit: ${commit}"
  fi

  info "building tuigreet (cargo build --release)"
  cargo build --release --manifest-path "${build_dir}/tuigreet/Cargo.toml" \
    || die "tuigreet build failed"

  local tuigreet_binary="${build_dir}/tuigreet/target/release/tuigreet"
  [[ -x "${tuigreet_binary}" ]] || die "tuigreet binary not found after build"

  info "installing tuigreet → /usr/local/bin/tuigreet"
  install -Dm755 "${tuigreet_binary}" /usr/local/bin/tuigreet \
    || die "failed to install tuigreet"

  info "vendor stage complete"
}
