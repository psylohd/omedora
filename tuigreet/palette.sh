#!/bin/sh
# /etc/tuigreet/palette.sh — set the Linux TTY palette before tuigreet starts.
#
# tuigreet has no native theme for these, so we drive the kernel TTY palette
# with OSC escapes and let tuigreet inherit. Selection/foreground/cursor
# remain CLI flags on the tuigreet invocation.
#
# Source this from greetd's `command` line, e.g.
#   command = "sh -c '. /etc/tuigreet/palette.sh; exec tuigreet --theme ...'"

# ── Console font sizing ────────────────────────────────────────────────
#
# On a 4K / HiDPI display, the Linux TTY's default 8×16 font renders as
# tiny pixels because each character cell occupies ~70–90 px on a 2160p
# framebuffer. Detect that condition and load a larger PSF font with
# `setfont` so the greeter is readable.
#
# Heuristic: px per character row = framebuffer_pixel_height / tty_rows.
#   ≤ 32 px/row  → default 8×16 is fine, skip
#   ≤ 56 px/row  → 16×32 (lat2-32 / ter-v32n)
#   > 56 px/row  → 32×64 (lat4-32 / ter-v64n)
#
# Override at run time:
#   NOKRON_FORCE_FONT=ter-v32n sh -c '...palette.sh...'
#   NOKRON_NO_FONT=1                        skip font selection entirely
#
# Only meaningful on the Linux TTY; silently no-ops on Wayland/headless
# or when setfont is unavailable.

pick_console_font() {
    [ "$TERM" = "linux" ] || return 0
    [ -z "${NOKRON_NO_FONT-}" ] || return 0
    command -v setfont >/dev/null 2>&1 || return 0
    tty_dev="$(tty 2>/dev/null)" || tty_dev=/dev/tty
    [ -w "$tty_dev" ] || return 0

    px_h=$(awk -F, '/virtual_size/{print $2; exit}' \
        /sys/class/graphics/fb0/virtual_size 2>/dev/null)
    [ -n "$px_h" ] || return 0

    rows=$(stty size 2>/dev/null | awk '{print $1}')
    [ -n "$rows" ] || rows=${LINES:-$(tput lines 2>/dev/null)}
    [ -n "$rows" ] && [ "$rows" -gt 0 ] || return 0

    # px per character row — the DPI proxy.
    ppr=$((px_h / rows))

    font=""
    if   [ "$ppr" -le 32 ]; then return 0
    elif [ "$ppr" -le 56 ]; then font=ter-v32n
    else                          font=ter-v64n
    fi

    if [ -n "${NOKRON_FORCE_FONT-}" ]; then font=$NOKRON_FORCE_FONT; fi

    setfont -C "$tty_dev" "$font" 2>/dev/null || return 0
}

pick_console_font
unset -f pick_console_font

# Guard: only meaningful on a Linux TTY. No-op under Wayland/headless.

if [ "$TERM" = "linux" ]; then
    echo -en "\e]P01a1b26" #black
    echo -en "\e]P82B2B2B" #darkgrey
    echo -en "\e]P1D75F5F" #darkred
    echo -en "\e]P9E33636" #red
    echo -en "\e]P287AF5F" #darkgreen
    echo -en "\e]PA9ece6a" #light-green
    echo -en "\e]P3D7AF87" #brown
    echo -en "\e]PBFFD75F" #yellow
    echo -en "\e]P48787AF" #darkblue
    echo -en "\e]PC75bfee" #light-blue
    echo -en "\e]P5BD53A5" #darkmagenta
    echo -en "\e]PDD633B2" #magenta
    echo -en "\e]P65FAFAF" #darkcyan
    echo -en "\e]PEc0caf5" #cyan
    echo -en "\e]P7414867" #gray
    echo -en "\e]PFFFFFFF" #white
    clear #for background artifacting
fi
