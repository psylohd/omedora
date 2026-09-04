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
        -- Mouse-refocus off: even with follow_mouse = 0, Hyprland
        -- will still re-focus the currently focused window when the
        -- mouse leaves and re-enters it (and on some monitors
        -- pointer motion wakes the focus). Disabling refocus means
        -- clicks/keybinds are the ONLY way focus changes — which
        -- is the "click-to-focus only" behavior the user wants.
        mouse_refocus = false,
    },
    -- Cursor-hiding timers live under the `cursor` section (NOT
    -- under `input` — these are Hyprland's compositor-side cursor
    -- hide policies, separate from per-device input). Earlier
    -- versions of this file set those keys under input, but they
    -- are not input-level keys and Hyprland rejected them with
    -- "unknown config key 'input.cursor_invisible_timeout' /
    -- 'input.hide_cursor_on_key_press'" at config-load time.
    -- Correct keys per https://wiki.hypr.land/configuring/core/
    -- config-options/#cursor:
    --   hide_on_key_press  (bool) — hide cursor while typing
    --   hide_on_touch      (bool) — hide cursor while a touch is active
    --   inactive_timeout   (int)  — seconds of cursor inactivity
    --                               before hiding. 0 = never hide.
    -- Set all three so Hyprland never auto-hides the cursor.
    cursor = {
        hide_on_key_press = false,
        hide_on_touch = false,
        inactive_timeout = 0,
        -- no_hardware_cursors: forces Hyprland to draw the cursor
        -- in software (CPU/GPU-rendered, not a hardware plane).
        --   0 = use hw cursors when possible
        --   1 = always software
        --   2 = auto: try hw, fall back to software on tearing
        --
        -- The flash symptom is caused by Hyprland on NVIDIA GPUs
        -- toggling between hw and sw cursor modes every frame,
        -- because the NVIDIA driver does not reliably expose
        -- hardware cursor planes via GBM. Forcing sw here is
        -- essentially free on modern hardware (one extra blit per
        -- frame) and reliably kills the flash on NVIDIA.
        -- Non-NVIDIA users see no visual difference.
        no_hardware_cursors = 1,
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
