# lib/stage-user-dirs.sh — default XDG user dirs + custom omedora dirs.
#
# This stage is intentionally minimal and idempotent.
#
# What it does:
#   1. Runs xdg-user-dirs-update --force as the target user. That populates
#      ~/.config/user-dirs.dirs and creates ~/Desktop, ~/Documents, etc.
#      (`xdg-user-dirs` ships in `packages.apps.required`.)
#   2. Appends three custom dirs (dev / projects / programs by default) to
#      user-dirs.dirs. xdg-user-dirs-update does NOT recognize these XDG
#      names natively, so we manage them ourselves:
#        * Append XDG_<NAME>_DIR="$HOME/<name>" lines only if absent (so
#          re-running the installer doesn't duplicate entries).
#        * Create the directory if missing.
#      Anything that calls `xdg-open $HOME/dev/scratch.py` then resolves
#      correctly even though it's not a freedesktop-spec-mandated dir.
#   3. Leaves the default mime associations untouched. Fedora's gio-launch-
#      desktop uses mimeinfo.cache from /usr/share; xdg-mime can change
#      defaults but that's per-app UX, not installer policy.
#
# Why this is a separate stage and not bolted into stage-dms:
#   * It must run after the `dnf` stage (xdg-user-dirs-update isn't in any
#     COPR — it's in the Fedora base repo — so dnf is fine, but the stage
#     assumes dnf already ran).
#   * It must run as the target user, not as root, because xdg-user-dirs
#     reads $HOME and writes ~/.config/user-dirs.dirs there. We shell out
#     via `sudo -u`. `sudo -H` would strip $HOME and land things in /root.

stage_user_dirs() {
  section "configs: xdg-user-dirs (default + custom)"
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"
  [[ -d "${user_home}" ]]  || die "user home '${user_home}' does not exist"

  if ! command -v xdg-user-dirs-update >/dev/null 2>&1; then
    die "xdg-user-dirs-update not in PATH. Did [packages.apps].required install xdg-user-dirs?"
  fi

  # ── 1. Default dirs ────────────────────────────────────────────────────────
  # --force overwrites user-dirs.dirs with locale defaults (XDG_DESKTOP_DIR,
  # XDG_DOCUMENTS_DIR, ...). We do this even if the file already exists,
  # because Fedora's RPM sometimes ships a pre-existing user-dirs.dirs with
  # locale-mismatched paths (e.g. $HOME/Schreibtisch on de_DE installs).
  info "generating standard XDG dirs (Desktop, Documents, ...)"
  sudo -u "${target_user}" \
    HOME="${user_home}" \
    XDG_RUNTIME_DIR="/run/user/$(id -u "${target_user}")" \
    xdg-user-dirs-update --force \
    || die "xdg-user-dirs-update --force failed"

  # ── 2. Custom omedora dirs ─────────────────────────────────────────────────
  # xdg-user-dirs-update doesn't know about $HOME/dev, $HOME/projects, etc.
  # We append entries to ~/.config/user-dirs.dirs idempotently. Names are
  # read from [userdirs] in omedora.toml (defaults: dev, projects, programs).
  # Custom omedora XDG_<UPPER>_DIR mapping:
  #   OMEDORA_USERDIR_<var>  — the variable holding the dir name (e.g. "dev")
  #   <UPPER>_DIR            — the XDG key written to user-dirs.dirs
  #   <label>                — human label used in install log output
  # Adding a fourth custom dir is a one-line TOML change + one line here.
  local settings=(
    "OMEDORA_USERDIR_DEV:DEV_DIR:dev"
    "OMEDORA_USERDIR_PROJECTS:PROJECTS_DIR:projects"
    "OMEDORA_USERDIR_PROGRAMS:PROGRAMS_DIR:programs"
  )

  local user_dirs_file="${user_home}/.config/user-dirs.dirs"
  [[ -f "${user_dirs_file}" ]] || warn "user-dirs.dirs missing (xdg-user-dirs-update did not create it?)"

  for entry in "${settings[@]}"; do
    IFS=':' read -r env_var xdg_label label <<< "${entry}"
    local dir_name="${!env_var}"
    [[ -n "${dir_name}" ]] || { warn "${env_var} is empty; skipping XDG_${xdg_label}"; continue; }

    local abs_dir="${user_home}/${dir_name}"

    # Append to user-dirs.dirs only if not already present. We key on the
    # XDG_<LABEL>_DIR line itself so users may have re-pointed it manually
    # (e.g. for a second drive) without us silently undoing their work.
    if [[ -f "${user_dirs_file}" ]] \
       && grep -qE "^XDG_${xdg_label}=" "${user_dirs_file}"; then
      info "  XDG_${xdg_label} already set; leaving in place"
    else
      info "  appending XDG_${xdg_label}=\"\$HOME/${dir_name}\" to user-dirs.dirs"
      printf '\nXDG_%s="$HOME/%s"\n' "${xdg_label}" "${dir_name}" >> "${user_dirs_file}"
    fi

    # Ensure the directory exists with sane ownership/perms.
    if [[ -d "${abs_dir}" ]]; then
      info "  ~/${dir_name} already exists"
    else
      info "  creating ~/${dir_name}"
      install -d -o "${target_user}" -g "${target_user}" -m 0755 "${abs_dir}"
    fi
  done

  chown "${target_user}:${target_user}" "${user_dirs_file}" 2>/dev/null || true

  # ── 3. Sanity printout ─────────────────────────────────────────────────────
  info "user-dirs.dirs final state:"
  sed 's/^/    /' "${user_dirs_file}" | grep -E "^    XDG_" || true
}
