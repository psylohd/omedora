-- inputs.lua — keyboard + touchpad config and trackpad gestures.
--
-- Hyprland 0.55+ Lua API only. The legacy `hyprctl keyword gesture ...`
-- pattern from <0.54 does NOT work — the gesture keyword was folded into
-- the `binds` table as a `gesture` entry, and is now set via `hl.gesture()`.
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Gestures/

hl.config({
    input = {
        kb_layout = "us",
        kb_options = "",
        numlock_by_default = true,
        repeat_delay = 250,
        repeat_rate = 35,
        accel_profile = "flat",
        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            clickfinger_behavior = false,
            scroll_factor = 0.5,
        },
        special_fallthrough = true,
        follow_mouse = 1,
    },
})

-- ── Gestures ─────────────────────────────────────────────────────────────────
-- 3-finger horizontal swipe = cycle workspaces (Hyprland built-in
--   "workspace" action; mirrors SUPER+arrows / SUPER+SHIFT+arrows in binds).
-- 4-finger swipe down       = toggle dms overview (lua lambda wrapper,
--   so the dms IPC call is invoked once per gesture).
-- 2-finger pinch            = cursor zoom at 2× (Omarchy default).
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
hl.gesture({
    fingers = 2,
    direction = "pinch",
    action = "cursor_zoom",
    zoom_level = 2,
    mode = "mult",
    description = "2-finger pinch: cursor zoom",
})
