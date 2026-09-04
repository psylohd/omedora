-- inputs.lua — keyboard + touchpad config and trackpad gestures.
--
-- Hyprland 0.55+ Lua API only. The legacy `hyprctl keyword gesture ...`
-- pattern from <0.54 does NOT work — the gesture keyword was folded into
-- the `binds` table as a `gesture` entry, and is now set via `hl.gesture()`.
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/
--
-- This file is the SINGLE source of truth for `hl.config({ input = ... })`.
-- hyprland.lua MUST NOT also call hl.config({ input = ... }) — a second
-- hl.config call replaces the table wholesale in some Hyprland versions
-- and merges in others, which previously left follow_mouse and the
-- cursor-hide timers in an undefined mix, producing the "cursor
-- flashes" symptom. One hl.config({ input = ... }) per session.

hl.config({
    input = {
        kb_layout = "us",
        kb_options = "",
        numlock_by_default = true,
        repeat_delay = 250,
        repeat_rate = 35,
        -- Pointer speed: sensitivity is clamped to [-1.0, 1.0]; positive is
        -- faster. `1.0` plus `accel_profile = "flat"` (below) gives a clean
        -- linear cursor with the maximum legal multiplier — the default
        -- (0.0) felt sluggish on a HiDPI screen. Lower this on a smaller
        -- monitor or with a high-DPI mouse.
        sensitivity = 1.0,
        accel_profile = "flat",
        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            clickfinger_behavior = false,
            scroll_factor = 0.5,
        },
        special_fallthrough = true,
        -- follow_mouse = 0 → click-to-focus. Hyprland focuses a window
        -- only on click or keybind. Do NOT set this to 1 ("always") or 2
        -- ("on fullscreen / unlocked") — both refocus the window under
        -- the cursor on hover, which is the "auto focus on mouse over"
        -- behavior the user wants OFF.
        follow_mouse = 0,
        -- Cursor hiding: disable all three Hyprland timers so the cursor
        -- stays visible at rest. Anything else tends to fight with dms's
        -- software cursor overlay (which has its own hide policy in
        -- settings.json:cursorSettings) and produces the per-frame blink.
        -- The values below match the keys listed under
        -- https://wiki.hypr.land/Configuring/Variables/#input
        --   hide_cursor_on_key_press = false  → cursor stays while typing
        --   hide_on_touch               = false → cursor stays during tap
        --   cursor_invisible_timeout    = 0     → never auto-hide
        hide_cursor_on_key_press = false,
        hide_on_touch = false,
        cursor_invisible_timeout = 0,
    },
})

-- ── Gestures ─────────────────────────────────────────────────────────────────
-- 3-finger horizontal swipe = cycle workspaces (Hyprland built-in
--   "workspace" action; mirrors SUPER+arrows / SUPER+SHIFT+arrows in binds).
-- 4-finger swipe down       = toggle dms overview (lua lambda wrapper,
--   so the dms IPC call is invoked once per gesture).
--
-- The previous 2-finger pinch → cursor_zoom gesture was REMOVED. Cursor
-- zoom toggled Hyprland's render scale per pinch, which presented as
-- "the cursor flashes" because dms kept redrawing its overlay at the new
-- scale every frame the gesture was active. No replacement — pinching
-- is now a no-op (acceptable; dms doesn't have a competing pinch bind).
hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
    description = "3-finger swipe workspaces",
})
hl.gesture({
    fingers = 4,
    direction = "down",
    action = function() hl.exec_cmd("dms ipc call hypr toggleOverview") end,
    description = "4-finger swipe down: dms overview toggle",
})
