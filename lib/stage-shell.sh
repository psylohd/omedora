# lib/stage-shell.sh — set user shell to fish and patch ~/.config/fish/config.fish.

stage_shell() {
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local home
  home="$(getent passwd "${target_user}" | cut -d: -f6)"

  if [[ -z "${home}" ]]; then
    die "could not resolve home directory for user: ${target_user}"
  fi

  section "shell: fish + starship"

  # ── Install fish ─────────────────────────────────────────────────────────────
  if command -v dnf5 >/dev/null 2>&1; then
    if ! rpm -q fish >/dev/null 2>&1; then
      info "installing fish"
      dnf5 install -y fish \
        || die "dnf5 install fish failed"
    else
      info "fish already installed"
    fi
  else
    die "dnf5 not found"
  fi

  # ── Set login shell ─────────────────────────────────────────────────────────
  local current_shell
  current_shell="$(getent passwd "${target_user}" | cut -d: -f7)"
  if [[ "${current_shell}" == */fish ]]; then
    info "shell for ${target_user} is already fish (${current_shell})"
  else
    info "setting shell for ${target_user} to /bin/fish"
    chsh -s /bin/fish "${target_user}" \
      || die "chsh -s /bin/fish ${target_user} failed"
  fi

  # ── Install starship ─────────────────────────────────────────────────────────
  if ! command -v starship >/dev/null 2>&1; then
    info "installing starship"
    curl -sS https://starship.rs/install.sh | sh -s -- -y \
      || die "starship install failed"
  else
    info "starship already installed"
  fi

  # ── Patch ~/.config/fish/config.fish ─────────────────────────────────────────
  local fishdir="${home}/.config/fish"
  local fishconfig="${fishdir}/config.fish"

  if [[ ! -w "${home}" ]]; then
    warn "cannot write to ${home} (not writable); skipping fish config patch"
    return 0
  fi

  install -d -m 0755 -o "${target_user}" -g "${target_user}" "${fishdir}"

  info "applying fish + starship tweaks to ${fishconfig}"

  # ── starship init ───────────────────────────────────────────────────────────
  local starship_init='starship init fish | source'
  if grep -qF "${starship_init}" "${fishconfig}" 2>/dev/null; then
    info "starship already initialized in config.fish"
  else
    printf '\n# starship prompt\n%s\n' "${starship_init}" >> "${fishconfig}"
    info "added starship init to config.fish"
  fi
}
