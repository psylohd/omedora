# lib/stage-configs.sh — drop the repo's config trees into the right places.
#
# Three destinations:
#   /usr/share/plymouth/themes/omedora      — Plymouth theme (system)
#   /etc/tuigreet  + /usr/local/bin/tuigreet — tuigreet binary + config (system)
#   $HOME/.config/hypr                     — Hyprland user config
#   $HOME/.config/quickshell               — quickshell/dms user config
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
  fi

  if [[ "${OMEDORA_STAGE_QUICKSHELL}" == "true" ]]; then
    section "configs: quickshell"
    stage_config_quickshell "${user_home}"
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
}

stage_config_quickshell() {
  local home="$1"
  local src="${OMEDORA_PATH_QUICKSHELL}"

  [[ -d "${src}" ]] || { warn "quickshell config dir not found: ${src} (skipping)"; return 0; }

  backup_and_copy_tree "${src}" "${home}/.config/quickshell"
  chown -R "${OMEDORA_TARGET_USER}:${OMEDORA_TARGET_USER}" "${home}/.config/quickshell"
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
