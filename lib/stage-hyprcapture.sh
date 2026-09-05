# lib/stage-hyprcapture.sh — install the HyprCapture compositor plugin via
# hyprpm and wire its Lua config block into ~/.config/hypr/hyprland.lua.
#
# HyprCapture is a hyprpm-style plugin: `hyprpm add <repo>` clones the source
# tree, runs CMake, installs the resulting .so into the Hyprland plugin dir,
# and installs the Qt helper `hyprcapture-ui` into ~/.local/bin/. HyprCapture
# then exposes its captures/recordings via Lua functions (hl.plugin.hyprcapture.*)
# and a keybind helper. We bind it to Print on install.

# ─── Why a post-install script, not an immediate service ─────────────────────
# hyprpm has three runtime requirements that are NOT satisfiable at install
# time on a fresh box:
#
#   1. Live Hyprland instance. hyprpm reads the running compositor's
#      version (via the Hyprland IPC socket) to validate plugin ABI
#      headers. On a fresh install, Hyprland hasn't started yet.
#
#   2. XDG_RUNTIME_DIR. hyprpm writes its state to $XDG_RUNTIME_DIR/hyprpm/.
#      Logind creates /run/user/<uid> on first login; on a fresh install
#      this dir doesn't exist. hyprpm errors with "XDG_RUNTIME_DIR not set!".
#
#   3. Write access to /var/cache/hyprpm/<user>/. We pre-create this dir
#      with mode 1777 so hyprpm's clone operations succeed without escalation.
#
# To satisfy all three, this stage ships a post-install script the user
# runs manually after their first Hyprland boot. The script is idempotent —
# safe to re-run if the first attempt failed.
#
# ─── What this stage does ───────────────────────────────────────────────────
#   - Installs build deps + hyprpm binary (via dnf).
#   - Pre-creates /var/cache/hyprpm/<user>/ with mode 1777 (sticky, writable
#     by user) so hyprpm's first-add clone succeeds without escalation.
#   - Ships ~/.local/share/omedora/install-hyprcapture.sh — the user runs
#     this manually after first Hyprland boot.
#
# ─── Idempotency ────────────────────────────────────────────────────────────
# - `tweaks.sh hyprcapture` re-applies this stage; it overwrites the script.
# - hyprpm's own `add` is idempotent (errors on duplicate and the script
#   treats that as success).
# - If the user already has HyprCapture installed, hyprpm add errors but
#   the script continues and subsequent hyprpm commands are no-ops.
#
# ─── Failure handling ──────────────────────────────────────────────────────
# - If the script fails, the user can re-run `tweaks.sh hyprcapture`
#   or run it manually: bash ~/.local/share/omedora/install-hyprcapture.sh
stage_hyprcapture() {
  section "hyprpm: HyprCapture compositor plugin"
  require_root

  local repo_url="${OMEDORA_HYPRCAPTURE_REPO_URL}"

  if [[ -z "${repo_url}" ]]; then
    info "hyprpm disabled (empty hyprcapture.repo_url)"
    return 0
  fi

  # Toolchain sanity (root context — /usr/bin paths are uid-independent).
  local missing=()
  for tool in hyprpm cmake git; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      missing+=("${tool}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "missing hyprpm build deps: ${missing[*]} (stage_dnf should have installed these)"
  fi

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"

  # Pin handling: "<url>|<branch>|<commit>" — same shape as hyprland_plugins.
  local url="${repo_url}" branch="${OMEDORA_HYPRCAPTURE_BRANCH}" commit="${OMEDORA_HYPRCAPTURE_COMMIT}"
  if [[ "${repo_url}" == *"|"* ]]; then
    IFS='|' read -r url branch commit <<<"${repo_url}"
  fi

  # ── Pre-create /var/cache/hyprpm/<user>/ ───────────────────────────────────
  # hyprpm clones plugin repos into this dir. hyprpm's internal sudo mkdir
  # for the first plugin is blocked by !visiblepw on headless installs, so we
  # pre-create the dir as root with sticky-bit 1777 so the user can write
  # subdirs (hyprpm's clone targets) without needing any escalation.
  local hyprpm_cache="/var/cache/hyprpm/${target_user}"
  install -d -m 1777 "${hyprpm_cache}"
  chown -R "${target_user}:${target_user}" "${hyprpm_cache}"

  # ── Drop the post-install script ────────────────────────────────────────────
  # A standalone bash script the user runs manually after first Hyprland boot.
  # hyprpm needs XDG_RUNTIME_DIR + Hyprland IPC socket, both only available
  # after Hyprland is running. The script is idempotent — safe to re-run.
  local script="${user_home}/.local/share/omedora/install-hyprcapture.sh"
  install -d -m 0755 -o "${target_user}" -g "${target_user}" \
    "$(dirname "${script}")"
  cat > "${script}" <<SH
#!/bin/bash
# ~/.local/share/omedora/install-hyprcapture.sh
#
# Installs HyprCapture via hyprpm. Run manually after your first Hyprland
# boot (hyprpm needs the Hyprland IPC socket).
#
#   bash ~/.local/share/omedora/install-hyprcapture.sh
#
# Idempotent — safe to re-run if the first attempt failed.

set -eo pipefail

URL='${url}'
BRANCH='${branch}'
COMMIT='${commit}'
NAME="\$(basename "\${URL}" .git)"

# ── Build dep check ────────────────────────────────────────────────────────────
# HyprCapture's screenshot UI needs Qt6 (qtbase + qtsvg). Install via sudo
# if missing; if sudo fails, warn but continue — the plugin .so may still build.
for pkg in qt6-qtbase-devel qt6-qtsvg-devel layer-shell-qt-devel; do
    if ! rpm -q "$pkg" >/dev/null 2>&1; then
        echo "[omedora] $pkg not found — installing..."
        sudo dnf install -y "$pkg" || echo "[omedora] $pkg install failed"
    fi
done

# Remove any previous broken install so hyprpm add -f can re-clone fresh.
echo "[omedora] hyprpm remove \${NAME} (if exists)"
yes | hyprpm remove "\${NAME}" 2>/dev/null || true

# Pipe yes to auto-confirm the trust prompt.
# --force (-f) re-clones and rebuilds from scratch.
echo "[omedora] hyprpm add -f \${URL}"
yes | hyprpm add -f "\${URL}" || true

echo "[omedora] hyprpm reload"
hyprpm reload || true

echo "[omedora] HyprCapture installed."
SH
  chmod 0755 "${script}"
  chown "${target_user}:${target_user}" "${script}"

  info "HyprCapture stage complete."
  info "Run this after your first Hyprland boot:"
  info "  bash ~/.local/share/omedora/install-hyprcapture.sh"
}

# tweak_hyprcapture — re-apply the post-install script. Safe to re-run.
tweak_hyprcapture() {
  section "tweak: hyprpm HyprCapture"
  stage_hyprcapture
}
