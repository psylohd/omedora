# lib/stage-greetd.sh — write /etc/greetd/config.toml.
#
# Two greeter backends supported:
#   tuigreet      — current Rust build under [vendored.tuigreet]
#   dms-greeter   — vendored binary (not currently shipped)
#
# Both backends exec /usr/bin/start-hyprland (the binary shipped by the
# Hyprland RPM). We do NOT install a /usr/local/bin wrapper — the Hyprland
# startup hook + dbus-update-activation-environment set XDG_CURRENT_DESKTOP
# etc. before exec-once fires `dms run`, so env vars reach dms without a
# custom launcher.

stage_greetd() {
  require_root
  section "greetd: wiring ${NOKRON_GREETER_BACKEND}"

  local cfg="/etc/greetd/config.toml"
  install -d /etc/greetd

  if [[ -f "${cfg}" ]]; then
    local bak="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    info "backing up ${cfg} → ${bak}"
    cp -p "${cfg}" "${bak}"
  fi

  local tmp; tmp="$(mktemp /etc/greetd/config.toml.XXXXXX)"
  case "${NOKRON_GREETER_BACKEND}" in
    tuigreet)
      cat > "${tmp}" <<'GREETD_EOF'
[terminal]
vt = 1

[default_session]
command = "sh -c '. /etc/tuigreet/palette.sh; exec tuigreet --cmd /usr/bin/start-hyprland'"
user = "greetd"
GREETD_EOF
      ;;
    dms-greeter)
      cat > "${tmp}" <<'GREETD_EOF'
[terminal]
vt = 1

[default_session]
command = "dms-greeter --command /usr/bin/start-hyprland"
user = "greetd"
GREETD_EOF
      ;;
    *)
      die "unknown greeter backend: ${NOKRON_GREETER_BACKEND}"
      ;;
  esac

  install -m 0644 "${tmp}" "${cfg}"
  rm -f "${tmp}"

  info "wrote ${cfg}"
}
