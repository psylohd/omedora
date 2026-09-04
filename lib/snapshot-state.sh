# lib/snapshot-state.sh — capture live desktop state into the repo.
#
# Problem: install.sh overwrites ~/.config/DankMaterialShell/ + hypr/ on every
# run, so any local tweak (new wallpaper, switched theme, enabled a plugin,
# added a keybind) is lost on the next install. The fix is to capture the live
# state into the repo, then commit. install.sh deploys from the repo, so the
# committed state survives.
#
# Usage (run as the desktop user, NOT root):
#   ./omedora state save     # writes live state into repo (DankMaterialShell/, hypr/)
#   ./omedora state diff     # shows what would change before you commit
#   ./omedora state revert   # restore repo state to live (i.e. nuke local customisations)
#
# Files captured (live path → repo path):
#   ~/.config/DankMaterialShell/settings.json        → DankMaterialShell/settings.json
#   ~/.config/DankMaterialShell/plugin_settings.json → DankMaterialShell/plugin_settings.json
#   ~/.config/DankMaterialShell/firefox.css          → DankMaterialShell/firefox.css
#   ~/.config/DankMaterialShell/zen.css              → DankMaterialShell/zen.css
#   ~/.config/DankMaterialShell/themes/<theme>/      → DankMaterialShell/themes/<theme>/
#     (the whole themes/ tree, since themes can be added locally and we don't
#      know which one is "active")
#   ~/.config/hypr/hyprland.lua                     → hyprland/hyprland.lua
#   ~/.config/hypr/dms/binds-user.lua               → hyprland/dms/binds-user.lua
#
# Files NOT captured (intentionally):
#   * dms-generated: dms/{binds,colors,outputs,layout}.lua, dms/cursor.lua
#     — these are regenerated on first launch and are environment-specific.
#   * Hyprland .bak files — stale.
#   * .config/hypr/plugins/<name>/ — git clones; their repo URLs live in
#     omedora.toml's [hyprland_plugins].plugins. If a plugin was installed
#     outside the installer, add its URL there and rerun install.sh.
#   * .config/hypr/hyprpm-plugins/ — hyprpm managed; [hyprcapture] in
#     omedora.toml is the source of truth.
#
# The capture path is idempotent: re-running snapshot-state overwrites the
# repo's DankMaterialShell/{settings,plugin_settings}.json with whatever is
# live. Use git diff to review before committing.

# state_capture_file <live_path> <repo_path> — copy a single file with a
# timestamped .bak if the repo copy already differs.
state_capture_file() {
  local live="$1" repo="$2"
  if [[ ! -f "${live}" ]]; then
    warn "live file missing: ${live} (skipping)"
    return 0
  fi
  if ! cmp -s "${live}" "${repo}" 2>/dev/null; then
    if [[ -f "${repo}" ]]; then
      info "  ${repo#"${OMEDORA_REPO_ROOT}/"}: live differs from repo — will update"
    else
      info "  ${repo#"${OMEDORA_REPO_ROOT}/"}: new file"
    fi
  fi
  install -D -m 0644 "${live}" "${repo}"
}

# state_capture_dir <live_dir> <repo_dir> — recursive copy of one tree.
# Skips dms-generated files. Adds new files; replaces changed ones.
state_capture_dir() {
  local live="$1" repo="$2"
  if [[ ! -d "${live}" ]]; then
    warn "live dir missing: ${live} (skipping)"
    return 0
  fi
  install -d "${repo}"
  # Copy each file under live/ into repo/ verbatim. Top-level + recursive.
  find "${live}" -type f -print0 |
  while IFS= read -r -d '' f; do
    local rel="${f#${live}/}"
    # Skip dms-generated noise.
    case "${rel}" in
      *.bak.*) continue ;;
    esac
    install -D -m 0644 "${f}" "${repo}/${rel}"
  done
}

# state_capture — main entry. Reads ${HOME} (the desktop user's $HOME) and
# writes into OMEDORA_REPO_ROOT. Caller decides which user; default to the
# user running the script (typical case: the desktop user, NOT root).
state_capture() {
  local live_home="${1:-${HOME}}"
  local repo_root="${OMEDORA_REPO_ROOT}"
  [[ -d "${repo_root}" ]] || die "repo root not found: ${repo_root}"

  section "state capture: ${live_home} → ${repo_root}"

  local dms_live="${live_home}/.config/DankMaterialShell"
  local dms_repo="${repo_root}/DankMaterialShell"
  local hypr_live="${live_home}/.config/hypr"
  local hypr_repo="${repo_root}/hyprland"

  if [[ ! -d "${dms_live}" ]]; then
    warn "live DankMaterialShell dir missing: ${dms_live} (skipping dms capture)"
  else
    info "capturing DankMaterialShell/ files"
    state_capture_file "${dms_live}/settings.json"      "${dms_repo}/settings.json"
    state_capture_file "${dms_live}/plugin_settings.json" "${dms_repo}/plugin_settings.json"
    state_capture_file "${dms_live}/firefox.css"        "${dms_repo}/firefox.css"
    state_capture_file "${dms_live}/zen.css"            "${dms_repo}/zen.css"
    if [[ -d "${dms_live}/themes" ]]; then
      info "capturing DankMaterialShell/themes/ (recursive)"
      state_capture_dir "${dms_live}/themes" "${dms_repo}/themes"
    fi
  fi

  if [[ ! -d "${hypr_live}" ]]; then
    warn "live hypr dir missing: ${hypr_live} (skipping hyprland capture)"
  else
    info "capturing hyprland configs"
    state_capture_file "${hypr_live}/hyprland.lua"      "${hypr_repo}/hyprland.lua"
    state_capture_file "${hypr_live}/dms/binds-user.lua" "${hypr_repo}/dms/binds-user.lua"
    # Also capture any custom Scripts/ if the user has them — recursive.
    if [[ -d "${hypr_live}/Scripts" ]]; then
      info "capturing hyprland/Scripts/ (recursive)"
      state_capture_dir "${hypr_live}/Scripts" "${hypr_repo}/Scripts"
    fi
  fi

  # Wallpapers — capture from $HOME/Pictures/wallpapers/ (live, flat) into
  # repo wallpapers/<theme>/. The theme is sourced from the just-captured
  # settings.json: customThemeFile (when category=custom) → strip the
  # "themes/" prefix and the trailing "/theme.json" to get the theme dir
  # name. Falls back to currentThemeName (the registry path) when custom is
  # not in use. If neither yields a usable theme, defaults to "default" so
  # the files aren't lost — the user can rename the dir before commit.
  local wp_live="${live_home}/Pictures/wallpapers"
  if [[ -d "${wp_live}" ]]; then
    local wp_repo="${repo_root}/wallpapers"
    local theme="default"
    local settings="${dms_live}/settings.json"
    if [[ -f "${settings}" ]]; then
      # customThemeFile takes the form "themes/<name>/theme.json"
      local custom
      custom="$(python3 -c "
import json,sys
try:
    with open('${settings}') as f:
        s = json.load(f)
    ct = s.get('customThemeFile', '')
    if ct.startswith('themes/') and ct.endswith('/theme.json'):
        print(ct[len('themes/'):-len('/theme.json')])
        sys.exit(0)
    if s.get('currentThemeCategory') == 'custom':
        print(s.get('currentThemeName', 'default'))
        sys.exit(0)
    print(s.get('currentThemeName', 'default'))
except Exception:
    print('default')
")"
      [[ -n "${custom}" ]] && theme="${custom}"
    fi
    info "capturing wallpapers/ (theme=${theme})"
    install -d "${wp_repo}/${theme}"
    find "${wp_live}" -type f -print0 |
    while IFS= read -r -d '' f; do
      local base="${f##*/}"
      install -m 0644 "${f}" "${wp_repo}/${theme}/${base}"
    done
    chown -R "$(id -u):$(id -g)" "${wp_repo}" 2>/dev/null || true
  else
    info "live $HOME/Pictures/wallpapers/ not found — skipping wallpaper capture"
  fi

  echo
  info "captured. Review with: git diff"
  info "commit with:           git add -p && git commit -m 'state: capture'"
}

# state_diff — show what would change without writing.
state_diff() {
  local live_home="${1:-${HOME}}"
  local repo_root="${OMEDORA_REPO_ROOT}"
  section "state diff: ${live_home} vs ${repo_root}"

  local dms_live="${live_home}/.config/DankMaterialShell"
  local dms_repo="${repo_root}/DankMaterialShell"
  local hypr_live="${live_home}/.config/hypr"
  local hypr_repo="${repo_root}/hyprland"

  local found=0
  for live_path in \
    "${dms_live}/settings.json" \
    "${dms_live}/plugin_settings.json" \
    "${dms_live}/firefox.css" \
    "${dms_live}/zen.css" \
    "${hypr_live}/hyprland.lua" \
    "${hypr_live}/dms/binds-user.lua" \
  ; do
    local rel="${live_path#${live_home}/.config/}"
    # .config/DankMaterialShell/...  → DankMaterialShell/...
    # .config/hypr/...                → hyprland/...
    local repo_path
    case "${rel}" in
      DankMaterialShell/*) repo_path="${repo_root}/${rel}" ;;
      hypr/*)             repo_path="${repo_root}/hyprland/${rel#hypr/}" ;;
      *) continue ;;
    esac
    if [[ -f "${live_path}" ]] && { [[ ! -f "${repo_path}" ]] || ! cmp -s "${live_path}" "${repo_path}"; }; then
      ((++found))
      info "${rel}: live differs from repo"
    fi
  done

  # Themes/ — check for any theme file in live that isn't in repo, or differs.
  if [[ -d "${dms_live}/themes" ]]; then
    find "${dms_live}/themes" -type f -print0 |
    while IFS= read -r -d '' f; do
      local rel="${f#${dms_live}/}"
      local repo_path="${dms_repo}/${rel}"
      if [[ ! -f "${repo_path}" ]] || ! cmp -s "${f}" "${repo_path}"; then
        ((++found))
        info "themes/${rel}: live differs from repo"
      fi
    done
  fi

  if [[ "${found}" -eq 0 ]]; then
    info "no drift between live and repo"
  else
    echo
    info "${found} file(s) would change. Run 'state save' to update the repo."
  fi
}

# state_revert — copy the repo state OVER the live state. Used to nuke local
# customisations and restore the committed baseline (e.g. before a test).
state_revert() {
  local live_home="${1:-${HOME}}"
  local repo_root="${OMEDORA_REPO_ROOT}"
  section "state revert: ${repo_root} → ${live_home}"
  warn "this will overwrite your LIVE config with the committed baseline."
  warn "any unsaved local customisations will be lost."
  read -r -p "continue? [y/N] " _ans
  [[ "${_ans}" == "y" || "${_ans}" == "Y" ]] || { info "aborted"; return 0; }

  local dms_repo="${repo_root}/DankMaterialShell"
  local hypr_repo="${repo_root}/hyprland"
  local dms_live="${live_home}/.config/DankMaterialShell"
  local hypr_live="${live_home}/.config/hypr"

  [[ -d "${dms_repo}" ]] && backup_and_copy_tree "${dms_repo}" "${dms_live}"
  [[ -d "${hypr_repo}" ]] && backup_and_copy_tree "${hypr_repo}" "${hypr_live}"
  info "live config restored from repo; restart Hyprland to pick up changes"
}
