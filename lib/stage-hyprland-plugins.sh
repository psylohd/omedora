# lib/stage-hyprland-plugins.sh — clone git-URL Hyprland plugins into
# ~/.config/hypr/plugins/ and pin them to a specific commit/branch.
#
# Hyprland 0.55+ ships a Lua config; some third-party "plugins" are pure
# Lua packages (no compilation, no hyprpm) — they live as a directory
# under ~/.config/hypr/plugins/ and are `require`'d via package.path.
# The plugin's own README wires it in:
#
#   package.path = package.path .. ";./?.lua;./?/init.lua"
#   local smw = require("plugins.split-monitor-workspaces")
#
# This stage ONLY clones/pins the repos. The require() call lives in
# hyprland.lua so the plugin is loaded on first boot. To pin to a
# different commit/branch than the upstream default, append a
# "<url>|<branch>|<commit>" triple to omedora.toml's [hyprland_plugins].
# plugins ("|" is not a valid git URL character so we can split safely).
#
# Idempotency: existing dirs are `git fetch`'d and reset to the pinned
# commit (or HEAD of pinned branch). The plugin's working tree is
# overwritten on every install; this matches the dms_plugins behavior.
#
# Reference: https://wiki.hypr.land/Plugins/Using-Plugins/

stage_hyprland_plugins() {
  section "configs: hyprland plugins (lua packages)"
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -d "${user_home}" ]] || die "user '${target_user}' not found on this system"

  if [[ ${#OMEDORA_HYPRLAND_PLUGINS[@]} -eq 0 ]]; then
    info "no [hyprland_plugins].plugins entries — nothing to install"
    return 0
  fi

  # Plugins live in the user's $HOME so the git working tree survives
  # across install reruns (mirrors how DMS plugins are handled in
  # lib/stage-dms.sh — user edits there are not clobbered).
  local plugins_dir="${user_home}/.config/hypr/plugins"
  install -d -m 0755 -o "${target_user}" -g "${target_user}" "${plugins_dir}"

  command -v git >/dev/null 2>&1 || die "git not in PATH"

  local entry url branch commit name target
  for entry in "${OMEDORA_HYPRLAND_PLUGINS[@]}"; do
    # Optional pin format: "<url>|<branch>|<commit>" (pipe is not a
    # valid git URL char so it's safe to split on). Default branch is
    # "main" / "master" whichever the remote advertises.
    IFS='|' read -r url branch commit <<<"${entry}"
    [[ -n "${url}" ]] || { warn "empty hyprland_plugins entry, skipping"; continue; }

    name="$(basename "${url}" .git)"
    target="${plugins_dir}/${name}"

    # Clone (as the desktop user so the resulting repo is user-owned).
    # -H preserves $HOME so the remote URL is resolved against the
    # user's git config / known_hosts, not root's.
    if [[ -d "${target}/.git" ]]; then
      info "updating existing plugin: ${name}"
      sudo -u "${target_user}" -H git -C "${target}" remote set-url origin "${url}" \
        || warn "  failed to update origin for ${name}"
      sudo -u "${target_user}" -H git -C "${target}" fetch --depth=1 --prune --prune-tags origin \
        || warn "  git fetch failed for ${name} (continuing)"
      if [[ -n "${commit}" ]]; then
        sudo -u "${target_user}" -H git -C "${target}" reset --hard "${commit}" \
          || warn "  git reset --hard ${commit} failed for ${name} (continuing)"
      elif [[ -n "${branch}" ]]; then
        sudo -u "${target_user}" -H git -C "${target}" reset --hard "origin/${branch}" \
          || warn "  git reset --hard origin/${branch} failed for ${name} (continuing)"
      else
        # No pin: reset to whatever the upstream default branch points at.
        sudo -u "${target_user}" -H git -C "${target}" reset --hard "@{u}" \
          || warn "  git reset --hard @{u} failed for ${name} (continuing)"
      fi
    else
      info "cloning plugin: ${url} → ${target}"
      if [[ -n "${branch}" ]]; then
        sudo -u "${target_user}" -H git clone --depth=1 -b "${branch}" "${url}" "${target}" \
          || { warn "  clone failed for ${url} (continuing)"; continue; }
      else
        sudo -u "${target_user}" -H git clone --depth=1 "${url}" "${target}" \
          || { warn "  clone failed for ${url} (continuing)"; continue; }
      fi
      if [[ -n "${commit}" ]]; then
        sudo -u "${target_user}" -H git -C "${target}" fetch --depth=1 origin "${commit}" \
          || warn "  fetch ${commit} failed for ${name} (continuing)"
        sudo -u "${target_user}" -H git -C "${target}" checkout "${commit}" \
          || warn "  checkout ${commit} failed for ${name} (continuing)"
      fi
    fi
  done

  info "hyprland plugins stage complete"
}