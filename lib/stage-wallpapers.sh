# lib/stage-wallpapers.sh — copy the repo's `wallpapers/` tree into the
# target user's $HOME/Pictures/wallpapers/.
#
# Repo structure:
#   wallpapers/<theme>/<file>.jpg|png|webp
#   (one subdir per theme; the directory name is the theme name)
#
# Live structure:
#   $HOME/Pictures/wallpapers/<file>.jpg|png|webp
#   (flat — theme subdirs are dropped; wallpaper pickers expect flat dirs)
#
# Idempotency:
#   - Existing files in $HOME/Pictures/wallpapers/ that match a repo file
#     are compared via cmp; identical files are skipped, differing files
#     are backed up to .bak.<date> and overwritten.
#   - Files in $HOME/Pictures/wallpapers/ that have NO counterpart in the
#     repo (e.g. wallpapers the user dropped in via wget) are preserved.
#
# Why a separate stage file:
#   `wallpapers` is in the same conceptual family as `hyprland`/`dms`/`nvim`
#   (user-config deployment), but it does NOT need any of the dnf/COPR
#   prerequisites. Putting it in its own stage keeps `tweaks.sh wallpapers`
#   and `install.sh --only wallpapers` cheap (no dnf re-resolution).
#
# Multi-theme collision policy:
#   If two themes ship a file with the same basename (e.g. both themes ship
#   `BG1.png`), the order is non-deterministic — `find` returns files in
#   inode/directory order. In practice the repo layout guarantees one
#   theme per file. If that ever changes, add a `theme_priority` table.

stage_wallpapers() {
  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"
  stage_wallpapers_for_user "${user_home}"
}

stage_wallpapers_for_user() {
  local home="$1"
  local src="${OMEDORA_PATH_WALLPAPERS}"
  local dst="${home}/Pictures/wallpapers"

  [[ -d "${src}" ]] || { warn "wallpapers source not found: ${src} (skipping)"; return 0; }

  install -d "${dst}"
  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" \
    "$(dirname "${dst}")" "${dst}"

  local copied=0 backed=0 skipped=0
  # Flatten: every file under src/ (recursively, depth-unbounded) lands at
  # dst/. The trailing basename is what matters — theme subdirs are dropped.
  while IFS= read -r -d '' f; do
    local rel="${f#${src}/}"
    local base="${rel##*/}"            # basename only — strip theme dir
    local target="${dst}/${base}"
    if [[ -f "${target}" ]] && cmp -s "${f}" "${target}"; then
      ((++skipped))
      continue
    fi
    if [[ -f "${target}" ]]; then
      cp -p "${target}" "${target}.bak.$(date +%Y%m%d-%H%M%S)"
      ((++backed))
    fi
    install -m 0644 "${f}" "${target}"
    ((++copied))
  done < <(find "${src}" -type f -print0)

  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${dst}"
  info "wallpapers: copied=${copied} backed=${backed} skipped=${skipped} → ${dst}"
}
