# lib/detect-monitors.sh — detect currently-connected monitors via
# /sys/class/drm EDID, rank by physical area, and feed a sorted list
# to stage-greetd.sh so the auto-generated tuigreet config only enables
# the largest one(s).
#
# Why EDID over /sys/class/drm/{modes,edid}?  EDID's bytes 21..22 are
# the panel's *physical* size in millimeters (per VESA EDID 1.4
# "Size of display" fields). Two 1920x1080 monitors at 24" vs 27"
# would tie on pixel count but differ on physical area — and that's
# the metric the user wants for "largest screen wins". Pixel count
# alone is the wrong signal here; area is correct.
#
# Why read sysfs here and not call a runtime helper?  At install time
# there is no Wayland session — Hyprland isn't installed yet, no
# DRM master, no `wlr-randr` would work. Direct sysfs + EDID parsing
# is the only path that works on a fresh Fedora Server install with
# only the kernel-mode KMS driver loaded.
#
# Output:
#   detect_active_connectors prints one line per connected output:
#     <area_mm2>|<connector_name>
#   sorted by area descending; ties broken lexicographically by name
#   (so eDP-1 < DP-1 < HDMI-A-1 reliably when areas match).
#
# Notes on the EDID parsing:
#   * We treat the `card*-*-{connector}` directory path as canonical.
#   * We only consider `status == "connected"`. Disconnected connectors
#     and virtual/wb-only paths (`Writeback-*`) are skipped.
#   * `cat /sys/.../edid` may include trailing null bytes; bash's
#     command substitution strips nulls in the substring expansion
#     (`${edid:21:1}`), which is fine because byte positions 21 and 22
#     are non-null in every EDID I've ever seen. The "ignored null
#     byte in input" warning is benign.

# detect_active_connectors — print connected monitors ranked by area.
#
# Arguments: none.
# Side effects: none (read-only against sysfs).
# Returns:
#   0 — at least one connected output was found, list printed.
#   1 — no connected outputs (caller falls back to the static
#       [[greeter.outputs]] table from omedora.toml).
# Output: lines like
#   13692|card1-eDP-1
#   18816|card1-DP-1
detect_active_connectors() {
  local -a entries=()

  # Walk every /sys/class/drm/card*-*-{connector} path. We use a glob
  # because card numbering and connector enumeration differs across
  # GPU vendors (AMD renumbers; Optimus shows the same connector on
  # multiple cards). Reading from all of them is cheap — typically
  # fewer than a dozen entries — and gives us a guaranteed-clean view
  # regardless of which display server wins arbitration.
  local c status name edid hsize vsize area
  for c in /sys/class/drm/card*-*-*; do
    [[ -f "${c}/status" ]] || continue
    [[ -f "${c}/edid" ]] || continue

    status="$(cat "${c}/status" 2>/dev/null)"
    [[ "${status}" == "connected" ]] || continue

    name="$(basename "${c}")"
    # Strip the "card1-" prefix so the output is just "eDP-1" /
    # "DP-1" / "HDMI-A-1" — that matches the connector format
    # [[greeter.outputs]] in omedora.toml uses.
    name="${name#card*-}"

    # EDID may have trailing null bytes after the 128-byte base block
    # (extension blocks); bash command substitution drops nulls, so
    # substring ${edid:21:1} still returns the byte at offset 21 of
    # the 128-byte base EDID. Verified against the bytes dumped from
    # /sys/class/drm/card1-eDP-1/edid on a real laptop.
    edid="$(cat "${c}/edid" 2>/dev/null)" || continue
    [[ -z "${edid}" ]] && continue

    # Parse EDID 1.4 bytes 21/22 (HSize / VSize in mm).
    hsize=$(printf '%d' "'${edid:21:1}" 2>/dev/null) || continue
    vsize=$(printf '%d' "'${edid:22:1}" 2>/dev/null) || continue
    [[ -z "${hsize}" || -z "${vsize}" ]] && continue

    area=$(( hsize * vsize ))
    (( area > 0 )) || continue

    entries+=( "${area}|${name}" )
  done

  if (( ${#entries[@]} == 0 )); then
    return 1
  fi

  # Sort: primary key = area descending (large area = high rank);
  # secondary = connector name ascending (eDP-1 first, then DP-1,
  # HDMI-A-1, USB-C…, alphabetical order for ties).
  printf '%s\n' "${entries[@]}" \
    | sort -t'|' -k1,1nr -k2,2

  return 0
}

# pick_largest_connector — print just the connector name of the
# largest connected output, or empty on no-detection.
#
# Used by stage-greetd.sh for the default-auto-on-primary fallback:
# if the user hasn't manually flipped any connector to enabled=true
# in omedora.toml, we mark the largest one primary and let the rest
# stay disabled. If detection fails (no /sys, no KMS yet) we print
# nothing and the static [[greeter.outputs]] table governs.
pick_largest_connector() {
  local line
  line="$(detect_active_connectors | head -n 1)"
  [[ -z "${line}" ]] && return 1
  echo "${line#*|}"
  return 0
}
