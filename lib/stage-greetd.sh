# lib/stage-greetd.sh — wire dms-greeter as the greetd login manager.
#
# dms-greeter (avengemedia/danklinux COPR, RPM 1.6.0+) is a Wayland
# greeter that runs inside a Hyprland session, so the greeter and the
# post-login session share DRM master — no VT-framebuffer cross-monitor
# mirroring. dms-greeter install --yes writes /etc/greetd/config.toml
# with the correct [terminal] vt = 1 + [default_session] blocks plus
# the /etc/pam.d/greetd fingerprint/U2F plug if available.
#
# Post-login chain: `uwsm start /usr/bin/start-hyprland`. Bare `hyprland`
# skips the env-setup wrapper that `start-hyprland` provides
# (XDG_CURRENT_DESKTOP etc.), which Hyprland rejects on startup. uwsm
# validates the Wayland/D-Bus environment, activates
# `graphical-session.target` (so dms.service's `Requisite=` is
# satisfied), then execs start-hyprland.
#
# Greeter user handling: the greetd RPM ships a `greetd` system user,
# while dms-greeter expects `greeter`. We rename greetd → greeter
# (group + user + home) before invoking `dms-greeter install`, so the
# box doesn't end up with two greeter accounts. Override with
# [greeter].user_mode = "leave" to keep both.
stage_greetd() {
  require_root
  section "greetd: wiring ${OMEDORA_GREETER_BACKEND}"

  # Reject legacy tuigreet backend. tuigreet was removed entirely from
  # omedora (no vendored source builds, no build toolchain). If a
  # config still names 'tuigreet' as backend, fail loudly so the user
  # knows to edit omedora.toml.
  if [[ "${OMEDORA_GREETER_BACKEND}" != "dms-greeter" ]]; then
    die "unsupported greeter backend: '${OMEDORA_GREETER_BACKEND}' (only 'dms-greeter' is supported; tuigreet was removed)"
  fi

  local cfg="/etc/greetd/config.toml"
  install -d /etc/greetd

  if [[ -f "${cfg}" ]]; then
    local bak="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    info "backing up ${cfg} → ${bak}"
    cp -p "${cfg}" "${bak}"
  fi

  # DMS_PRIVESC pins the privilege-escalation tool dms-greeter uses
  # for its sub-commands. Without it, dms-greeter prompts
  # interactively when both sudo and run0 are present, which is fatal
  # for a non-interactive installer. Default 'sudo' matches the rest
  # of omedora (sudo ./install.sh).
  local privesc="${OMEDORA_DMS_PRIVESC:-sudo}"
  case "${privesc}" in
    sudo|doas|run0) ;;
    *) die "invalid [greeter].privesc: '${privesc}' (expected sudo|doas|run0)" ;;
  esac
  if [[ "${OMEDORA_GREETER_USER_MODE:-rename}" == "rename" ]]; then
    rename_greetd_to_greeter
  fi
  info "delegating greetd config to dms-greeter (DMS_PRIVESC=${privesc})"
  DMS_PRIVESC="${privesc}" dms-greeter install --yes \
    || die "dms-greeter install failed"
  info "dms-greeter install complete"

  # ── dms-greeter sync: run now (install phase, as root) ─────────────────────
  # dms-greeter sync -y writes the greeter theme/wallpaper/settings from the
  # current user's DMS config. Running it now (during install, as root) means
  # the greeter looks correct on the very first login — no visual pop.
  #
  # Escalation: pkexec --user root (the greeter daemon user) because the
  # target user's DMS config lives under their home dir which greeter can't
  # read. pkexec with polkit approval (user in wheel group) avoids needing
  # any password or NOPASSWD sudoers entry.
  info "syncing DMS theme/wallpaper to greeter"
  if pkexec --user root --disable-internal-agent dms-greeter sync -y \
       2>&1 | sed 's/^/  /'; then
    info "dms-greeter sync complete"
  else
    warn "dms-greeter sync failed (continuing)"
  fi
}

# rename_greetd_to_greeter — collapse the greetd RPM's `greetd` system
# account into the `greeter` user that dms-greeter expects, so the box
# doesn't end up with two greeter accounts.
#
# Idempotent across all four state combinations:
#
#   greetd=exists, greeter=missing → full rename (group, user, home)
#   greetd=exists, greeter=exists  → user left both (warn loudly)
#   greetd=missing, greeter=exists → no-op (dms-greeter install will reuse)
#   greetd=missing, greeter=missing → no-op (dms-greeter sysusers.d creates it)
#
# We deliberately do NOT delete `greetd` here when `greeter` already
# exists — the user may have custom PAM / logind config keyed off the
# greetd username, and silent deletion would be hostile. Just warn.
rename_greetd_to_greeter() {
  local have_greetd=0 have_greeter=0
  id greetd  >/dev/null 2>&1 && have_greetd=1
  id greeter >/dev/null 2>&1 && have_greeter=1

  if (( have_greetd == 0 )); then
    info "no 'greetd' user to rename (already absent)"
    return 0
  fi

  if (( have_greeter == 1 )); then
    # Two greeter accounts already coexist from a previous run that
    # used the old installer. The user can clean this up later with:
    #   sudo userdel -r greetd     # only if no live processes
    # Leave both in place so the running greetd session isn't disturbed.
    warn "both 'greetd' (uid=$(id -u greetd)) and 'greeter' (uid=$(id -u greeter)) users exist"
    warn "omedora no longer auto-merges them; remove 'greetd' manually after a reboot if desired:"
    warn "  sudo userdel -r greetd    # only if greetd has no live processes"
    return 0
  fi

  # ── Both: greetd exists, greeter does not. Do the rename. ──────────────
  # Order matters: rename the group BEFORE the user, otherwise usermod
  # has to update a still-named-after-the-old-name primary GID and
  # fails on some systemd-userdb configurations.
  # Home dir is moved at the same time as the rename via `usermod -d -m`
  # (note: order of flags: -l first, then -d, then -m). GECOS field
  # updated to match dms-greeter's "System Greeter" convention.
  info "renaming 'greetd' → 'greeter' (group + user + home)"

  if ! groupmod -n greeter greetd; then
    die "groupmod -n greeter greetd failed — refusing to continue with mismatched user/group names"
  fi
  if ! usermod -l greeter -d /var/lib/greeter -m -c "System Greeter" greetd; then
    die "usermod -l greeter greetd failed (group was already renamed; restore with: groupmod -n greetd greeter)"
  fi

  # future greetd-RPM reinstalls will see `greetd` as a stale entry in
  # their sysusers.d fragment and try to recreate it. We can't suppress
  # the RPM fragment, so the user may end up with both `greetd` and
  # `greeter` again if they reinstall `greetd` after the rename. To
  # prevent that, remove `/usr/lib/sysusers.d/greetd.conf` once your
  # install is stable:
  #   sudo rm /usr/lib/sysusers.d/greetd.conf
  # The dms-greeter sysusers.d fragment (`u greeter` / `g greeter`)
  # remains, so the greeter user keeps getting recreated on package
  # reinstalls — that's the part of the rename that's sticky on its
  # own.
  info "rename complete: greetd → greeter (home now /var/lib/greeter)"
}
