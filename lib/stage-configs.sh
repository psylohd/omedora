# lib/stage-configs.sh — drop the repo's config trees into the right places.
#
# Destinations:
#   /usr/share/plymouth/themes/omedora      — Plymouth theme (system)
#   /etc/tuigreet  + /usr/local/bin/tuigreet — tuigreet binary + config (system)
#   $HOME/.config/hypr                     — Hyprland user config
#   $HOME/.config/quickshell               — quickshell/dms user config
#   $HOME/.config/nvim                     — Neovim / LazyVim user config
#
# Every existing target file is backed up with a timestamped .bak suffix,
# matching the convention in install.sh. This makes the installer safely
# idempotent for re-runs.

stage_configs() {
  require_root

  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [[ -n "${user_home}" ]] || die "user '${target_user}' not found on this system"
  [[ -d "${user_home}" ]] || die "user home '${user_home}' does not exist"

  if [[ "${OMEDORA_STAGE_PLYMOUTH}" == "true" ]]; then
    section "configs: plymouth"
    stage_config_plymouth
  fi

  if [[ "${OMEDORA_STAGE_TUIGREET}" == "true" ]]; then
    section "configs: tuigreet"
    stage_config_tuigreet
  fi

  if [[ "${OMEDORA_STAGE_HYPRLAND}" == "true" ]]; then
    section "configs: hyprland"
    stage_config_hyprland "${user_home}"
    # Drop user-systemd units (hyprland-session.target) alongside the
    # main hyprland config; ships once per hyprland stage because the
    # target unit is keyed off `BindsTo=graphical-session.target`.
    stage_config_systemd_user "${user_home}"
  fi

  if [[ "${OMEDORA_STAGE_QUICKSHELL}" == "true" ]]; then
    section "configs: quickshell"
    stage_config_quickshell "${user_home}"
  fi

  if [[ "${OMEDORA_STAGE_NVIM}" == "true" ]]; then
    section "configs: neovim"
    stage_config_neovim "${user_home}"
  fi
}

stage_config_plymouth() {
  local src="${OMEDORA_PATH_PLYMOUTH}"
  local theme="omedora"
  local theme_dir="/usr/share/plymouth/themes/${theme}"

  [[ -d "${src}" ]] || die "plymouth source dir not found: ${src}"

  install -d "${theme_dir}"
  install -m 0644 \
    "${src}"/{omedora.plymouth,omedora.script,logo.png,lock.png,entry.png,bullet.png,progress_bar.png,progress_box.png} \
    "${theme_dir}/"


  if [[ -f "${src}/plymouthd.conf" ]]; then
    backup_and_install "${src}/plymouthd.conf" "/etc/plymouth/plymouthd.conf"
  fi

  # Apply [plymouth].device_scale from omedora.toml. We update the
  # installed /etc/plymouth/plymouthd.conf in-place rather than
  # overwriting it wholesale, because the install-shipped file may
  # already carry our (or the user's) manual edits — see how dracut
  # rebuilds the initramfs downstream which pulls the new config in.
  if [[ "${OMEDORA_PLYMOUTH_DEVICE_SCALE:-0}" -gt 0 ]]; then
    if ! grep -q '^DeviceScale' /etc/plymouth/plymouthd.conf 2>/dev/null; then
      echo "DeviceScale=${OMEDORA_PLYMOUTH_DEVICE_SCALE}" >> /etc/plymouth/plymouthd.conf
      info "set DeviceScale=${OMEDORA_PLYMOUTH_DEVICE_SCALE} in /etc/plymouth/plymouthd.conf"
    elif ! grep -q "^DeviceScale=${OMEDORA_PLYMOUTH_DEVICE_SCALE}" /etc/plymouth/plymouthd.conf; then
      # Replace any existing DeviceScale= line with our value.
      sed -i "s|^DeviceScale=.*|DeviceScale=${OMEDORA_PLYMOUTH_DEVICE_SCALE}|" /etc/plymouth/plymouthd.conf
      info "updated DeviceScale to ${OMEDORA_PLYMOUTH_DEVICE_SCALE} in /etc/plymouth/plymouthd.conf"
    fi
  fi
  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme "${theme}" || die "plymouth-set-default-theme failed"
  fi

  if command -v dracut >/dev/null 2>&1; then
    info "rebuilding initramfs (dracut)"
    dracut -f --regenerate-all || die "dracut failed — Plymouth theme won't load until initramfs is rebuilt"
  else
    die "no dracut/mkinitcpio found — cannot rebuild initramfs"
  fi
}

stage_config_tuigreet() {
  local src="${OMEDORA_PATH_TUIGREET}"
  [[ -d "${src}" ]] || die "tuigreet theme dir not found: ${src}"

  # Decide where the Cargo workspace lives. Each branch sets src_src to the
  # directory containing Cargo.toml; the trap (if any) cleans it up. This
  # avoids any set -u issues with a shared workdir variable that could be
  # unbound depending on which branch ran.
  local src_src=""      # absolute path to the Cargo workspace root
  local cleanup=""      # path to remove on exit (empty = nothing to clean)

  # Skip build if vendor stage already installed the binary (avoids double-build
  # when --only tuigreet is used, which enables both vendor + tuigreet stages).
  if ! command -v tuigreet >/dev/null 2>&1; then
    if [[ -n "${OMEDORA_TUIGREET_REPO_URL}" ]]; then
      # New style: clone from a pinned git URL into a scratch dir, build, clean up.
      [[ -n "${OMEDORA_TUIGREET_BRANCH}" ]] \
        || die "[vendored.tuigreet].branch is empty — set to e.g. 'tweak'"
      command -v git  >/dev/null 2>&1 || die "git not found. dnf5 install git first."
      command -v cargo >/dev/null 2>&1 || die "cargo not found. Did [packages.build] install fail?"

      cleanup="$(mktemp -d)" || die "mktemp failed"
      src_src="${cleanup}/tuigreet"

      info "cloning tuigreet (${OMEDORA_TUIGREET_BRANCH})"
      git clone --depth=1 --branch "${OMEDORA_TUIGREET_BRANCH}" \
        "${OMEDORA_TUIGREET_REPO_URL}" "${src_src}" \
        || die "git clone failed: ${OMEDORA_TUIGREET_REPO_URL}"

      if [[ -n "${OMEDORA_TUIGREET_COMMIT}" ]]; then
        info "checking out pinned commit ${OMEDORA_TUIGREET_COMMIT}"
        ( cd "${src_src}" && git fetch --unshallow \
          && git checkout "${OMEDORA_TUIGREET_COMMIT}" ) \
          || die "git checkout failed"
      fi
    else
      # Legacy style: a pre-cloned Cargo workspace already in the repo
      # (OMEDORA_PATH_TUIGREET_SRC). Honour it if it has a Cargo.toml.
      local legacy_src="${OMEDORA_PATH_TUIGREET_SRC:-}"
      if [[ -z "${legacy_src}" || ! -f "${legacy_src}/Cargo.toml" ]]; then
        die "[vendored.tuigreet].repo_url is empty and [paths.repo].tuigreet_src
points to a non-Cargo directory. Either:
  1. Set [vendored.tuigreet].repo_url + branch (recommended), or
  2. Set [paths.repo].tuigreet_src to a directory containing Cargo.toml"
      fi
      warn "using legacy tuigreet_src path: ${legacy_src}"
      src_src="$(dirname "${legacy_src}")"
    fi

    # ── 2. Build ───────────────────────────────────────────────────────────────
    # Register cleanup for the clone-scratch path. The trap handler runs
    # at function exit, after the local var has gone out of scope — so we
    # promote the path to the environment (so the trap can still see it)
    # and give the trap's expansion an explicit default.
    if [[ -n "${cleanup}" ]]; then
      export OMEDORA_TUIGREET_CLEANUP="${cleanup}"
      trap 'rm -rf "${OMEDORA_TUIGREET_CLEANUP:-}"' RETURN
    fi

    [[ -n "${src_src}" && -f "${src_src}/Cargo.toml" ]] \
      || die "tuigreet Cargo.toml not found in '${src_src}'"

    info "building tuigreet (cargo --release)"
    ( cd "${src_src}" && cargo build --release -p tuigreet ) \
      || die "tuigreet build failed"

    local bin="${src_src}/target/release/tuigreet"
    [[ -x "${bin}" ]] || die "tuigreet binary missing after build: ${bin}"

    install -m 0755 "${bin}" /usr/local/bin/tuigreet
  fi


  # ── 3. Drop the theme config ───────────────────────────────────────────────
  install -d /etc/tuigreet
  install -m 0644 "${src}/omedora.theme.toml" /etc/tuigreet/config.toml
  install -m 0755 "${src}/palette.sh"         /etc/tuigreet/palette.sh
  install -m 0644 "${src}/brand.txt"          /etc/tuigreet/brand.txt

  install -d /var/cache/tuigreet
  # greetd RPM creates a 'greetd' system user that owns the pre-auth session.
  if id greetd >/dev/null 2>&1; then
    chown greetd:greetd /var/cache/tuigreet
  fi
  chmod 0755 /var/cache/tuigreet
}

stage_config_hyprland() {
  local home="$1"
  local src="${OMEDORA_PATH_HYPRLAND}"

  [[ -d "${src}" ]] || { warn "hyprland config dir not found: ${src} (skipping)"; return 0; }

  backup_and_copy_tree "${src}" "${home}/.config/hypr"
  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config/hypr"
  chown "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config"

  # If the user configured [hyprland].monitors in omedora.toml, append
  # them as `monitor = "..."` lines to the deployed hyprland.lua so
  # they're active on first boot, before dms has had a chance to write
  # dms/outputs.lua. Format matches Hyprland's monitor line; e.g.
  # "eDP-1,2880x1800@120,0x0,2" → monitor = "eDP-1,2880x1800@120,0x0,2".
  if [[ ${#OMEDORA_HYPRLAND_MONITORS[@]} -gt 0 ]]; then
    local hlconf="${home}/.config/hypr/hyprland.lua"
    if [[ -f "${hlconf}" ]]; then
      info "appending ${#OMEDORA_HYPRLAND_MONITORS[@]} explicit monitor line(s) to hyprland.lua"
      {
        printf '\n-- omedora: explicit per-monitor lines from [hyprland].monitors\n'
        printf -- '-- (appended by stage-configs.sh; survives tweaks.sh hyprland reruns)\n'
        for m in "${OMEDORA_HYPRLAND_MONITORS[@]}"; do
          printf 'monitor = %q\n' "${m}"
        done
      } >> "${hlconf}"
      chown "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${hlconf}"
    fi
  fi
}

stage_config_quickshell() {
  local home="$1"
  local src="${OMEDORA_PATH_QUICKSHELL}"

  [[ -d "${src}" ]] || { warn "quickshell config dir not found: ${src} (skipping)"; return 0; }

  backup_and_copy_tree "${src}" "${home}/.config/quickshell"
  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config/quickshell"
  chown "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config"
}

stage_config_neovim() {
  local home="$1"
  local src="${OMEDORA_PATH_NVIM}"
  local dst="${home}/.config/nvim"

  if [[ -z "${src}" || "${src}" == "" ]]; then
    info "no nvim config path configured (set [paths.repo].nvim in omedora.toml)"
    return 0
  fi
  [[ -d "${src}" ]] || { warn "nvim config dir not found: ${src} (skipping)"; return 0; }

  backup_and_copy_tree "${src}" "${dst}"
  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${dst}"
  chown "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config"
}

stage_config_systemd_user() {
  # Drop `hyprland/systemd-user/*.target` / `*.service` files into
  # `~/.config/systemd/user/` and reload the running user manager so it
  # sees them. Used for `hyprland-session.target`, the glue unit that
  # `BindsTo=` graphical-session.target — without it, anything with
  # `Requisite=graphical-session.target` (e.g. dms.service) never has
  # its requirement satisfied on a bare Hyprland+greetd install.
  # Hyprland's `hyprland.lua` calls `systemctl --user start
  # hyprland-session.target` on each session start; that target's
  # `BindsTo=` activates graphical-session.target live, and
  # dms.service's `WantedBy=graphical-session.target` then auto-fires.
  # Pattern documented at wiki.hypr.land/Useful-Utilities/Systemd-Integration
  # under "Services / dms.service". We deliberately do NOT
  # `systemctl --user enable` anything from here — the target is
  # started per-session from hyprland.lua, not via `[Install] WantedBy=`.
  local home="$1"
  local src="${OMEDORA_PATH_HYPRLAND}/systemd-user"

  [[ -d "${src}" ]] || { info "no ${src} (skipping user systemd units)"; return 0; }

  local dst="${home}/.config/systemd/user"
  install -d -o "${OMEDORA_TARGET_USER}" -g "${OMEDORA_TARGET_USER}" -m 0755 "${dst}"

  local f name
  for f in "${src}"/*; do
    [[ -f "${f}" ]] || continue
    name="$(basename "${f}")"
    backup_and_install "${f}" "${dst}/${name}"
    chown "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${dst}/${name}"
  done

  # Reload the running user manager so it picks up the new unit
  # immediately. Silent if no manager is up yet (fresh install with no
  # XDG_RUNTIME_DIR); the next login will load the unit.
  if [[ -d "/run/user/$(id -u "${OMEDORA_TARGET_USER}")" ]]; then
    sudo -u "${OMEDORA_TARGET_USER}" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "${OMEDORA_TARGET_USER}")" \
      systemctl --user daemon-reload 2>/dev/null \
      || warn "user manager daemon-reload failed (will pick up on next login)"
    info "user manager reloaded; user systemd units active"
  fi
}

# ── helpers ───────────────────────────────────────────────────────────────────
# backup_and_install <src> <dst> — copy src to dst, backing up any existing file.
backup_and_install() {
  local src="$1" dst="$2"
  install -d "$(dirname "${dst}")"
  if [[ -f "${dst}" ]]; then
    local bak="${dst}.bak.$(date +%Y%m%d-%H%M%S)"
    info "  backing up ${dst} → ${bak}"
    cp -p "${dst}" "${bak}"
  fi
  install -m 0644 "${src}" "${dst}"
}

# backup_and_copy_tree <src_dir> <dst_dir> — copy tree contents, backing up
# any existing files inside dst_dir with timestamped .bak suffixes.
backup_and_copy_tree() {
  local src="$1" dst="$2"

  install -d "${dst}"

  # Copy each file individually so we can back up conflicts. Directories
  # are created with install -d.
  find "${src}" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 |
  while IFS= read -r -d '' entry; do
    local name
    name="$(basename "${entry}")"
    local target="${dst}/${name}"
    if [[ -e "${target}" ]]; then
      local bak="${target}.bak.$(date +%Y%m%d-%H%M%S)"
      info "  backing up ${target} → ${bak}"
      cp -p "${target}" "${bak}"
    fi
    cp -p "${entry}" "${target}"
  done

  # Subdirectories: recurse with rsync if available, else tar pipe.
  find "${src}" -mindepth 1 -maxdepth 1 -type d -print0 |
  while IFS= read -r -d '' sub; do
    local name sub_dst
    name="$(basename "${sub}")"
    sub_dst="${dst}/${name}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --backup --backup-dir="$(mktemp -d)" "${sub}/" "${sub_dst}/"
    else
      install -d "${sub_dst}"
      ( cd "${sub}" && tar cf - . ) | ( cd "${sub_dst}" && tar xf - )
    fi
  done
}
