# lib/stage-zsh.sh — set user shell to zsh and patch ~/.zshrc.

stage_zsh() {
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local home
  home="$(getent passwd "${target_user}" | cut -d: -f6)"

  if [[ -z "${home}" ]]; then
    die "could not resolve home directory for user: ${target_user}"
  fi

  section "zsh: shell + dotfile tweaks"

  # ── Set login shell ─────────────────────────────────────────────────────────
  local current_shell
  current_shell="$(getent passwd "${target_user}" | cut -d: -f7)"
  if [[ "${current_shell}" == */zsh ]]; then
    info "shell for ${target_user} is already zsh (${current_shell})"
  else
    info "setting shell for ${target_user} to /bin/zsh"
    chsh -s /bin/zsh "${target_user}" \
      || die "chsh -s /bin/zsh ${target_user} failed"
  fi

  # ── Patch ~/.zshrc ───────────────────────────────────────────────────────────
  local zshrc="${home}/.zshrc"
  if [[ ! -w "${home}" ]]; then
    warn "cannot write to ${home} (not writable); skipping .zshrc patch"
    return 0
  fi

  info "applying zsh tweaks to ${zshrc}"

  # ── starship prompt ─────────────────────────────────────────────────────────
  local starship_init='eval "$(starship init zsh)"'
  if grep -qF "${starship_init}" "${zshrc}" 2>/dev/null; then
    info "starship already initialized in .zshrc"
  else
    printf '\n# starship prompt\n%s\n' "${starship_init}" >> "${zshrc}"
    info "added starship init to .zshrc"
  fi

  # ── zsh-syntax-highlighting ────────────────────────────────────────────────
  local highlight_base="/usr/share/zsh/plugins/zsh-syntax-highlighting"
  if [[ -d "${highlight_base}" ]]; then
    local highlight_line="source ${highlight_base}/zsh-syntax-highlighting.zsh"
    if grep -qF "${highlight_line}" "${zshrc}" 2>/dev/null; then
      info "zsh-syntax-highlighting already sourced in .zshrc"
    else
      printf '\n# zsh-syntax-highlighting\n%s\n' "${highlight_line}" >> "${zshrc}"
      info "added zsh-syntax-highlighting to .zshrc"
    fi
  else
    warn "zsh-syntax-highlighting not found at ${highlight_base}; skipping"
  fi

  # ── zsh-autosuggestions ────────────────────────────────────────────────────
  local autosuggest_base="/usr/share/zsh/plugins/zsh-autosuggestions"
  if [[ -d "${autosuggest_base}" ]]; then
    local autosuggest_line="source ${autosuggest_base}/zsh-autosuggestions.zsh"
    if grep -qF "${autosuggest_line}" "${zshrc}" 2>/dev/null; then
      info "zsh-autosuggestions already sourced in .zshrc"
    else
      printf '\n# zsh-autosuggestions\n%s\n' "${autosuggest_line}" >> "${zshrc}"
      info "added zsh-autosuggestions to .zshrc"
    fi
  else
    warn "zsh-autosuggestions not found at ${autosuggest_base}; skipping"
  fi

  # ── User-defined additional tweaks ─────────────────────────────────────────
  # Drop extra zshrc fragments under /etc/omedora/zshrc.d/ (lexical order).
  # Each fragment is sourced directly — keep them self-contained.
  local zshrc_d="/etc/omedora/zshrc.d"
  if [[ -d "${zshrc_d}" ]]; then
    local fragment
    for fragment in "${zshrc_d}"/*.zsh; do
      [[ -e "${fragment}" ]] || continue
      local src_line="source ${fragment}"
      if grep -qF "${src_line}" "${zshrc}" 2>/dev/null; then
        info "fragment ${fragment} already sourced in .zshrc"
      else
        printf '\n# from %s\n%s\n' "${fragment}" "${src_line}" >> "${zshrc}"
        info "sourced ${fragment} into .zshrc"
      fi
    done
  fi
}
