# lib/stage-hyprcapture.sh — install the HyprCapture compositor plugin via
# hyprpm and wire its Lua config block into ~/.config/hypr/hyprland.lua.
#
# HyprCapture is a hyprpm-style plugin: `hyprpm add <repo>` clones the source
# tree, runs CMake, and exposes captures/recordings via Lua functions
# (hl.plugin.hyprcapture.*). We bind it to Print in hyprland/dms/binds-user.lua.
#
# Runs everything inline: install build deps, pre-create the hyprpm cache
# dir, run hyprpm add + enable + reload as the target user, reload Hyprland.
# No post-install script for the user to run separately — when this stage
# finishes, Print is live. Safe to re-run.

# HyprCapture installer logic, factored out so we can keep the if/then/fi
# structure clean. Reads URL from $HYCAPTURE_URL env var; needs
# HYPRLAND_INSTANCE_SIGNATURE, XDG_RUNTIME_DIR, HOME set in the env too.
_hc_install() {
  set -e
  url="$HYCAPTURE_URL"
  yes | hyprpm remove HyprCapture 2>/dev/null || true
  yes | hyprpm update
  yes | hyprpm add -f "$url"
}
stage_hyprcapture() {

  local repo_url="${OMEDORA_HYPRCAPTURE_REPO_URL}"
  if [[ -z "${repo_url}" ]]; then
    info "hyprpm disabled (empty hyprcapture.repo_url)"
    return 0
  fi

  # Toolchain sanity. hyprland-devel / hyprlang-devel come from
  # [packages.hyprland].build in omedora.toml; everything else for the
  # HyprCapture plugin build is listed below and matches its CMakeLists.txt
  # pkg_check_modules calls.
  local missing_pkgs=()
  local pkg
  for pkg in hyprpm cmake git \
             hyprland-devel hyprlang-devel hyprwayland-scanner \
             qt6-qtbase-devel qt6-qtsvg-devel layer-shell-qt-devel \
             pulseaudio-libs-devel pipewire-devel \
             libavformat-free-devel libavcodec-free-devel \
             libavutil-free-devel libswresample-free-devel \
             fftw-devel lua-devel glib2-devel nlohmann-json-devel; do
    if ! rpm -q "${pkg}" >/dev/null 2>&1; then
      missing_pkgs+=("${pkg}")
    fi
  done
  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    info "installing missing build deps: ${missing_pkgs[*]}"
    dnf install -y "${missing_pkgs[@]}" || die "failed to install build deps"
  fi

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"
  local target_uid
  target_uid="$(id -u "${target_user}")"

  # Pin handling: "<url>|<branch>|<commit>" — same shape as hyprland_plugins.
  local url branch commit
  url="${repo_url}"
  branch="${OMEDORA_HYPRCAPTURE_BRANCH}"
  commit="${OMEDORA_HYPRCAPTURE_COMMIT}"
  if [[ "${repo_url}" == *"|"* ]]; then
    IFS='|' read -r url branch commit <<<"${repo_url}"
  fi

  # Pre-create /var/cache/hyprpm/<user>/ owned by the target user with
  # mode 1777. hyprpm's internal sudo mkdir is blocked by !visiblepw on
  # headless installs, and pre-creating as root with a different owner
  # leaves root-owned build artifacts that future `hyprpm remove` calls
  # can't clean up. Owning the dir from the start lets hyprpm write
  # inside without escalation and clean up after itself.
  local hyprpm_cache="/var/cache/hyprpm/${target_user}"
  install -d -m 1777 -o "${target_user}" -g "${target_user}" "${hyprpm_cache}"

  # Discover the live Hyprland instance signature. The signature is a
  # per-session var that lives in the env of Hyprland's child processes
  # (Xwayland, dms) but isn't exported by any login profile — so we
  # derive it from /run/user/<uid>/hypr/, where each subdir is one live
  # instance. hyprpm and hyprctl need this set to find the IPC socket.
  local hypr_signature=""
  local hypr_dir
  for hypr_dir in "/run/user/${target_uid}/hypr"/*/; do
    [[ -d "${hypr_dir}" ]] || continue
    hypr_signature="$(basename "${hypr_dir}")"
    break
  done
  if [[ -z "${hypr_signature}" ]]; then
    die "no live Hyprland instance found for ${target_user} — log in to a graphical session first"
  fi

  # Run the hyprpm sequence as the target user. `runuser -l` sources the
  # user's login profile for $PATH; HYPRLAND_INSTANCE_SIGNATURE,
  # XDG_RUNTIME_DIR, and the URL are passed explicitly via `env`. We
  # source `_hc_install` (defined above) into the user's bash, then
  # call it. This keeps the if/then/fi structure of stage_hyprcapture
  # simple and avoids the heredoc-inside-if parsing pitfalls.
  info "installing HyprCapture as ${target_user} (url=${url}, instance=${hypr_signature})"
  if ! runuser -u "${target_user}" -- env \
        "HYPRLAND_INSTANCE_SIGNATURE=${hypr_signature}" \
        "XDG_RUNTIME_DIR=/run/user/${target_uid}" \
        "HOME=${user_home}" \
        "HYCAPTURE_URL=${url}" \
        bash -l -c "$(declare -f _hc_install); _hc_install"; then
    die "HyprCapture install failed — see output above"
  fi

  # Reload Hyprland so the freshly enabled plugin's Lua hooks are visible
  # to binds-user.lua on the next config load. hyprctl needs the same
  # env vars as hyprpm.
  if ! runuser -u "${target_user}" -- env \
        "HYPRLAND_INSTANCE_SIGNATURE=${hypr_signature}" \
        "XDG_RUNTIME_DIR=/run/user/${target_uid}" \
        "HOME=${user_home}" \
        hyprctl reload; then
    warn "hyprctl reload failed (manual reload needed: SUPER+R)"
  fi

  info "HyprCapture installed and enabled. Print key opens the screenshot overlay."
}

# tweak_hyprcapture — re-apply the install. Safe to re-run.
tweak_hyprcapture() {
  section "tweak: hyprpm HyprCapture"
  stage_hyprcapture
}
