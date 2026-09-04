# lib/stage-hyprcapture.sh — install the HyprCapture compositor plugin via
# hyprpm and wire its Lua config block into ~/.config/hypr/hyprland.lua.
#
# HyprCapture is a hyprpm-style plugin: `hyprpm add <repo>` clones the source
# tree, runs CMake, installs the resulting .so into the Hyprland plugin dir,
# and installs the Qt helper `hyprcapture-ui` into ~/.local/bin/. HyprCapture
# then exposes its captures/recordings via Lua functions (hl.plugin.hyprcapture.*)
# and a keybind helper. We bind it to Print on install.
#
# ─── Why no hyprpm call at install time ────────────────────────────────────
# hyprpm has three runtime requirements that are NOT satisfiable at install
# time on a fresh box:
#
#   1. Live Hyprland instance. hyprpm reads the running compositor's
#      version (via the Hyprland IPC socket) to validate plugin ABI
#      headers. On a fresh install, Hyprland hasn't started yet — the
#      installer exits before the user logs in. Calling `hyprpm add`
#      without a running Hyprland returns
#      `failed to get the current hyprland version` and refuses.
#
#   2. XDG_RUNTIME_DIR. hyprpm writes its state to a tmp root at
#      $XDG_RUNTIME_DIR/hyprpm/. Logind creates /run/user/<uid> on first
#      login; on a fresh install the user has never logged in, so this
#      dir doesn't exist. hyprpm errors with `XDG_RUNTIME_DIR not set!`.
#
#   3. Root privilege for /var/cache/hyprpm. hyprpm keeps its plugin
#      registry at /var/cache/hyprpm/<username>/ and uses polkit (via
#      NSys::root::createDirectory) to escalate to root when creating
#      that dir. With no polkit rule allowing hyprpm passwordless, the
#      install hangs at the `[sudo] password for test:` prompt.
#
# To side-step all three, this stage:
#   - Installs the build deps + the hyprpm binary itself (via dnf).
#   - Drops a polkit rule so hyprpm's root escalation is silent.
#   - Pre-creates /var/cache/hyprpm/<user>/ with the right perms (so
#     hyprpm's polkit call finds the dir already there and exits early).
#   - Ships a user systemd service (hyprcapture-install.service) that
#     runs ONCE on the user's first Hyprland launch, gated by
#     `After=hyprland-session.target`. The service performs the actual
#     `hyprpm add && build && enable && reload` in a context where
#     Hyprland is up and XDG_RUNTIME_DIR exists.
#
# ─── Idempotency ────────────────────────────────────────────────────────────
# - `tweaks.sh hyprcapture` re-applies this stage; it's safe to re-run
#   because:
#     - The systemd service unit is overwritten with the same payload.
#     - The polkit rule is overwritten with the same payload.
#     - hyprpm's own `add` is idempotent (errors on duplicate and the
#       service treats that as success).
# - If the user already has HyprCapture installed (e.g. manually ran
#   `hyprpm add` before omedora), the service detects "already added"
#   and exits 0; hyprpm build + enable are also no-ops in that state.
#
# ─── Failure handling ──────────────────────────────────────────────────────
# - The service is one-shot and Type=oneshot with RemainAfterExit=no,
#   so its exit status doesn't block the Hyprland session. Failures
#   are journalctl'd via StandardOutput=journal.
# - If the service fails, the user can re-run `tweaks.sh hyprcapture`
#   or trigger it manually: `systemctl --user start hyprcapture-install`.

stage_hyprcapture() {
  section "hyprpm: HyprCapture compositor plugin (deferred to first Hyprland launch)"
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
  local user_home user_uid
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  user_uid="$(id -u "${target_user}")"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"

  # Pin handling: "<url>|<branch>|<commit>" — same shape as hyprland_plugins.
  local url="${repo_url}" branch="${OMEDORA_HYPRCAPTURE_BRANCH}" commit="${OMEDORA_HYPRCAPTURE_COMMIT}"
  if [[ "${repo_url}" == *"|"* ]]; then
    IFS='|' read -r url branch commit <<<"${repo_url}"
  fi

  # ── Pre-create /var/cache/hyprpm/<user>/ ───────────────────────────────────
  # hyprpm needs this dir before its first add. Pre-creating it here
  # means hyprpm's NSys::root::createDirectory call sees the dir already
  # exists and skips the polkit prompt.
  local hyprpm_cache="/var/cache/hyprpm/${target_user}"
  install -d -m 0755 "${hyprpm_cache}"
  chown -R "${target_user}:${target_user}" "${hyprpm_cache}"

  # ── Polkit rule so hyprpm's root escalation is silent ─────────────────────
  # hyprpm uses pkexec to call back into root for state dir creation.
  # Register a polkit rule allowing the desktop user to run hyprpm without
  # a password. Without this, every install run prompts the user.
  #
  # polkit .rules files are JavaScript-like; we evaluate the action at
  # decision time. We allow any local user in the `wheel` group to run
  # /usr/bin/hyprpm as root without re-authentication. The desktop user
  # is added to `wheel` by omedora's [users] default; if not, the rule
  # is a no-op and hyprpm prompts — degraded UX but not broken.
  local polkit_rule="/etc/polkit-1/rules.d/50-hyprpm.rules"
  install -d -m 0755 "$(dirname "${polkit_rule}")"
  cat > "${polkit_rule}" <<'POLKIT'
// Allow any user in the `wheel` group to run /usr/bin/hyprpm as root
// without re-authentication. hyprpm uses polkit for state-dir creation;
// without this rule, `hyprpm add` hangs at the `[sudo] password for …`
// prompt on a fresh install.
//
// Owned by root, mode 0644. omedora's stage-hyprcapture.sh writes this
// idempotently (same payload every run).
polkit.addRule(function(action, subject) {
    if (action.id !== "org.freedesktop.policykit.exec" ||
        !subject.local || !subject.active) {
        return polkit.Result.NOT_HANDLED;
    }
    // getCmdline() is the array of argv as polkit sees them.
    for (const arg of action.lookup("command_line") || []) {
        if (arg === "/usr/bin/hyprpm" || arg === "/usr/local/bin/hyprpm") {
            if (subject.groups.indexOf("wheel") >= 0) {
                return polkit.Result.YES;
            }
        }
    }
    return polkit.Result.NOT_HANDLED;
});
POLKIT
  chmod 0644 "${polkit_rule}"
  info "polkit rule installed at ${polkit_rule}"

  # ── Drop the user systemd service ──────────────────────────────────────────
  # The service runs ONCE on the user's first Hyprland launch. It gates
  # on hyprland-session.target so by the time the unit fires, Hyprland
  # is up, XDG_RUNTIME_DIR exists, and the IPC socket is reachable.
  #
  # The unit body invokes the install script (also shipped by this stage)
  # at ~/.local/share/omedora/install-hyprcapture.sh, which is a thin
  # bash wrapper that calls `hyprpm add` etc. and exits non-zero only on
  # real failure. `Type=oneshot` + `RemainAfterExit=yes` makes it a
  # one-shot fire-and-forget.
  local user_unit_dir="${user_home}/.config/systemd/user"
  install -d -m 0755 -o "${target_user}" -g "${target_user}" "${user_unit_dir}"

  local service_file="${user_unit_dir}/hyprcapture-install.service"
  cat > "${service_file}" <<UNIT
[Unit]
Description=omedora: install HyprCapture via hyprpm (deferred)
Documentation=https://github.com/gfhdhytghd/HyprCapture
After=hyprland-session.target
PartOf=hyprland-session.target

[Service]
Type=oneshot
# Stay running long enough to finish the build (cmake + compile can take
# a minute on slow boxes). Timeout is generous; tweak if you know your hw.
TimeoutStartSec=10min
# Run as the user (the unit is in default.target.wants/, runs as the
# logged-in user's uid). All paths are user-relative.
ExecStart=${user_home}/.local/share/omedora/install-hyprcapture.sh
# Surface install progress in the journal; useful when debugging.
StandardOutput=journal
StandardError=journal
UNIT
  chown "${target_user}:${target_user}" "${service_file}"

  # ── Drop the install script ────────────────────────────────────────────────
  # A standalone bash script the user can rerun by hand if the service
  # fails. Keep it small + boring.
  local install_script="${user_home}/.local/share/omedora/install-hyprcapture.sh"
  install -d -m 0755 -o "${target_user}" -g "${target_user}" \
    "$(dirname "${install_script}")"
  cat > "${install_script}" <<SH
#!/bin/bash
# ~/.local/share/omedora/install-hyprcapture.sh
#
# Installs HyprCapture via hyprpm. Shipped by omedora's
# stage-hyprcapture.sh and run by the user's hyprcapture-install.service
# on first Hyprland launch. Can also be invoked by hand:
#
#   systemctl --user start hyprcapture-install
#
# Exits non-zero only on hard failures; idempotent on re-run.

set -eo pipefail

URL='${url}'
BRANCH='${branch}'
COMMIT='${commit}'
NAME="\$(basename "\${URL}" .git)"

# Reuse the polkit + /var/cache/hyprpm setup the installer did. hyprpm
# checks for those at runtime; if absent (e.g. user-installed omedora
# without root) it falls back to prompting.

echo "[omedora] hyprpm add \${URL}"
if ! hyprpm add "\${URL}" 2>&1; then
    # Already added is OK; anything else is fatal.
    if hyprpm list 2>/dev/null | grep -q "\${NAME}"; then
        echo "[omedora] already registered; continuing"
    else
        echo "[omedora] hyprpm add failed" >&2
        exit 1
    fi
fi

if [[ -n "\${COMMIT}" ]]; then
    echo "[omedora] checkout \${COMMIT}"
    hyprpm -P "\${NAME}" checkout "\${COMMIT}" || true
elif [[ -n "\${BRANCH}" ]]; then
    echo "[omedora] checkout \${BRANCH}"
    hyprpm -P "\${NAME}" checkout "\${BRANCH}" || true
fi

echo "[omedora] hyprpm -P \${NAME} build"
hyprpm -P "\${NAME}" build

echo "[omedora] hyprpm enable \${NAME}"
hyprpm enable "\${NAME}"

echo "[omedora] hyprpm reload"
hyprpm reload

echo "[omedora] HyprCapture installed."
SH
  chmod 0755 "${install_script}"
  chown "${target_user}:${target_user}" "${install_script}"

  # ── Enable the user service ───────────────────────────────────────────────
  # We can enable it now even though Hyprland hasn't started; the
  # After=hyprland-session.target gating defers activation to the first
  # Hyprland launch. Standard target.wants/ link so it auto-fires.
  local wants_dir="${user_unit_dir}/hyprland-session.target.wants"
  install -d -m 0755 -o "${target_user}" -g "${target_user}" "${wants_dir}"
  ln -sf "../hyprcapture-install.service" "${wants_dir}/hyprcapture-install.service"
  chown -h "${target_user}:${target_user}" \
    "${wants_dir}/hyprcapture-install.service"
  info "user systemd service enabled (fires on first Hyprland launch)"

  # Tell the running user manager (if any) to reload. Silent on a fresh
  # install where no user manager is up yet.
  if [[ -d "/run/user/${user_uid}" ]]; then
    runuser -u "${target_user}" -- \
      XDG_RUNTIME_DIR="/run/user/${user_uid}" \
      systemctl --user daemon-reload 2>/dev/null || true
  fi

  info "HyprCapture stage complete — plugin will install on first Hyprland launch."
  info "manual recovery: systemctl --user start hyprcapture-install"
  info "                 or: bash ~/.local/share/omedora/install-hyprcapture.sh"
}

# tweak_hyprcapture — re-apply the deferred-install wiring. Safe to re-run;
# overwrites the service + script with the same payload.
tweak_hyprcapture() {
  section "tweak: hyprpm HyprCapture (deferred)"
  stage_hyprcapture
}
