# lib/stage-greetd.sh — write /etc/greetd/config.toml.
#
# Two greeter backends supported:
#   tuigreet      — current Rust build under [vendored.tuigreet]
#   dms-greeter   — vendored binary (not currently shipped)
#
# Both backends exec into `uwsm start /usr/bin/start-hyprland`. Bare
# `hyprland` skips the env-setup wrapper that `start-hyprland` provides
# (XDG_CURRENT_DESKTOP etc.), which Hyprland rejects on startup. uwsm
# validates the Wayland/D-Bus environment, activates
# `graphical-session.target` (so dms.service's `Requisite=` is
# satisfied), then execs start-hyprland.
stage_greetd() {
  require_root
  section "greetd: wiring ${OMEDORA_GREETER_BACKEND}"

  local cfg="/etc/greetd/config.toml"
  install -d /etc/greetd

  if [[ -f "${cfg}" ]]; then
    local bak="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    info "backing up ${cfg} → ${bak}"
    cp -p "${cfg}" "${bak}"
  fi

  local tmp; tmp="$(mktemp /etc/greetd/config.toml.XXXXXX)"
  # Clean up temp file on any exit (error, interrupt, etc.)
  trap 'rm -f '"${tmp}" EXIT
  case "${OMEDORA_GREETER_BACKEND}" in
    tuigreet)
      cat > "${tmp}" <<'GREETD_EOF'
[terminal]
vt = 1

[default_session]
command = "sh -c '. /etc/tuigreet/palette.sh; exec tuigreet --cmd \"uwsm start /usr/bin/start-hyprland\"'"
user = "greetd"

# Per-monitor selection from [[greeter.outputs]] in omedora.toml.
# Each entry is one [[outputs]] block at the root of this file
# (tuigreet reads these at the root, not inside any [section]).
# enabled = false means tuigreet skips that connector entirely — no
# surface, no password prompt, no clock on that monitor.
# Set primary = true on EXACTLY one entry; that one's native resolution
# drives the terminal cell-grid sizing. Multiple primaries error out at
# tuigreet's config-validation step.
GREETD_EOF
      # Append the [[outputs]] blocks outside the heredoc; the heredoc
      # is single-quote-quoted so $vars would not expand inside, and we
      # need to splice in OMEDORA_GREETER_OUTPUTS which bash owns.
      if [[ ${#OMEDORA_GREETER_OUTPUTS[@]} -gt 0 ]]; then
        for entry in "${OMEDORA_GREETER_OUTPUTS[@]}"; do
          IFS='|' read -r k_conn k_en k_pri <<< "${entry}"
          printf '\n[[outputs]]\nconnector = "%s"\nenabled   = %s\nprimary   = %s\n' \
            "${k_conn#connector=}" "${k_en#enabled=}" "${k_pri#primary=}" >> "${tmp}"
        done
      fi
      ;;
    dms-greeter)
      cat > "${tmp}" <<'GREETD_EOF'
[terminal]
vt = 1

[default_session]
command = "dms-greeter --command \"uwsm start /usr/bin/start-hyprland\""
user = "greetd"
GREETD_EOF
      ;;
    *)
      die "unknown greeter backend: ${OMEDORA_GREETER_BACKEND}"
      ;;
  esac

  install -m 0644 "${tmp}" "${cfg}"
  rm -f "${tmp}"

  info "wrote ${cfg}"
}
