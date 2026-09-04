# lib/stage-greetd.sh — write /etc/greetd/config.toml.
#
# Two greeter backends supported:
#   tuigreet      — Rust build under [vendored.tuigreet]. Draws onto the
#                    kernel VT framebuffer directly.
#   dms-greeter   — avengemedia/danklinux COPR (RPM, 1.6.0+). Wayland
#                    greeter; runs inside a Hyprland session so greeter and
#                    post-login session share DRM master, no VT-framebuffer
#                    cross-monitor mirroring.
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
      # Source-of-truth rules:
      #   1. If [[greeter.outputs]] in omedora.toml has ANY entries,
      #      those win verbatim (user override).
      #   2. Otherwise: probe /sys/class/drm EDIDs at install time
      #      (detect-monitors.sh:detect_active_connectors) to find the
      #      currently connected output with the largest PHYSICAL area
      #      (HSize * VSize from EDID bytes 21..22, in mm^2). Mark that
      #      one primary; emit a sensible fallback list of common
      #      external connectors in case the user plugs in a second
      #      monitor later.
      #
      # We always emit a comment header explaining what the installer
      # decided, so future `tweaks.sh greetd` runs leave a readable
      # audit trail in /etc/tuigreet/config.toml.
      if [[ ${#OMEDORA_GREETER_OUTPUTS[@]} -gt 0 ]]; then
        printf '\n# Output entries from [[greeter.outputs]] in omedora.toml (verbatim).\n' >> "${tmp}"
        for entry in "${OMEDORA_GREETER_OUTPUTS[@]}"; do
          IFS='|' read -r k_conn k_en k_pri <<< "${entry}"
          printf '\n[[outputs]]\nconnector = "%s"\nenabled   = %s\nprimary   = %s\n' \
            "${k_conn#connector=}" "${k_en#enabled=}" "${k_pri#primary=}" >> "${tmp}"
        done
      else
        # Auto-detect from /sys/class/drm.
        printf '\n# No [[greeter.outputs]] set in omedora.toml; auto-detected at install time.\n' >> "${tmp}"
        local -a detected=()
        while IFS= read -r line; do
          [[ -z "${line}" ]] && continue
          detected+=( "${line}" )
        done < <(detect_active_connectors 2>/dev/null || true)

        if (( ${#detected[@]} > 0 )); then
          # First entry is the largest by area (sort already done).
          local first="${detected[0]}"
          local primary_name="${first#*|}"
          local primary_area="${first%%|*}"
          printf '# Largest connected monitor: %s (%s mm^2, primary).\n' \
            "${primary_name}" "${primary_area}" >> "${tmp}"
          printf '\\n# Enabling detected monitors; others left disabled.\\n' >> "${tmp}"
          printf '# Re-run `tweaks.sh greetd` if the wiring needs to change.\\n\\n' >> "${tmp}"
          for line in "${detected[@]}"; do
            local name="${line#*|}"
            local is_primary=""
            [[ "${name}" == "${primary_name}" ]] && is_primary="true"
            printf '[[outputs]]\\nconnector = "%s"\\nenabled   = true\\nprimary   = %s\\n\\n' \
              "${name}" "${is_primary}" >> "${tmp}"
          done
        else
          # Detection failed (no EDID-readable outputs at install time,
          # likely a headless VM or a host without a wired display).
          # Emit a minimal "enable whatever's there" config; tuigreet's
          # own autoprobe picks the right output at runtime.
          printf '\\n# Monitor detection could not read any EDIDs at install time.\\n' >> "${tmp}"
          printf '# (Normal on headless VMs or installs without a wired display.)\\n' >> "${tmp}"
          printf '# Add [[outputs]] entries in omedora.toml and re-run\\n' >> "${tmp}"
          printf '# `tweaks.sh greetd` once a monitor is plugged in.\\n' >> "${tmp}"
        fi
      fi
      ;;
    dms-greeter)
      # dms-greeter owns /etc/greetd/config.toml AND its PAM bits and the
      # greeter group assignment. Drive its installer so we don't fight it
      # on re-runs. dms-greeter install --yes writes a config with the
      # correct [terminal] vt = 1 + [default_session] blocks plus the
      # /etc/pam.d/greetd fingerprint/U2F plug if available.
      #
      # The 'greeter' user (UID 976) is created by dms-greeter's sysusers.d
      # fragment. dms-greeter install adds the desktop user to the 'greeter'
      # group so the post-login session can read /var/cache/dms-greeter.
      info "delegating greetd config to dms-greeter"
      dms-greeter install --yes \
        || die "dms-greeter install failed"
      info "dms-greeter install complete"
      ;;
    *)
      die "unknown greeter backend: ${OMEDORA_GREETER_BACKEND}"
      ;;
  esac

  install -m 0644 "${tmp}" "${cfg}"
  rm -f "${tmp}"

  info "wrote ${cfg}"
}
