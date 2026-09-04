-- dms/binds-user.lua — Omarchy-style keybinds that layer on top of DMS defaults.
--
-- This file is loaded by hyprland.lua AFTER dms/binds.lua, so anything we
-- re-bind here wins over the upstream DMS defaults. DMS leaves binds.lua as a
-- stub on a fresh install (it ships only ~12 binds from binds-user); Hyprland's
-- stock arrow/workspace binds do NOT live in DMS and never appear unless we
-- set them here. That is why SUPER+arrows, SUPER+1-0, SUPER+SHIFT+1-0,
-- SUPER+SHIFT+arrows are all unbound after a fresh install.
--
-- Bind ordering:
--   1. unbind any DMS defaults that conflict (cheap idempotency: hl.unbind
--      on a non-bound key is a no-op)
--   2. App launching (SUPER + {RETURN, E, B, …})
--   3. Workspace focus + window-to-workspace (SUPER + 1-9 and SUPER + SHIFT + 1-0)
--   4. Directional focus + swap (SUPER + arrows and SUPER + SHIFT + arrows)
--   5. Window management (SUPER + {Q, W, T, F, V})
--   6. Layout / display
--   7. Misc / utility (reload, exit, scratch)
--
-- Notes:
--   - hl.bind / hl.unbind / hl.dsp.* are the Hyprland 0.55+ Lua API.
--     See https://wiki.hyprland.org/Configuring/Dispatchers
--   - "SUPER" maps to the Super key (modmask 64).
--   - Arrow keys: hl.bind uses "LEFT", "RIGHT", "UP", "DOWN" (full names).
--   - Dirs are passed as strings: hl.dsp.focus({ direction = "left" }).
--   - Do NOT call dispatcher tables on their own — pass them to hl.bind,
--     which executes them on key press. To run a dispatcher inside a
--     function, wrap with hl.dispatch(table).
--   - Common pitfalls that produced nil-value errors:
--       * hl.dsp.movefocus — does NOT exist. Use hl.dsp.focus({direction=…}).
--       * hl.dsp.swapwindow — does NOT exist. Use hl.dsp.window.swap({direction=…}).
--       * hl.dsp.reload / hl.reload — do NOT exist (both nil in 0.56).
--         Reload via hl.dsp.exec_cmd("hyprctl reload").

local scrPath = (os.getenv("HOME") or "") .. "/.config/hypr/Scripts"

-- ── 1. Clear conflicting DMS defaults before re-binding ──────────────────────
--
-- dms upstream binds a lot of SUPER-prefixed keys. If we don't unbind
-- them first, our re-binds become DUPLICATE bindings rather than
-- overrides, and Hyprland picks one or the other depending on internal
-- dispatch ordering — which produces the "keybinds kind of work
-- unreliably" symptom (sometimes SUPER+1 goes to dms's workspace
-- focus, sometimes to ours, with no apparent rhyme).
--
-- Hyprland `hl.unbind` on a never-bound key is a documented no-op, so
-- being exhaustive is safe; we list every key we re-bind below plus
-- the Omarchy-style keys we expect dms might bind on a fresh install.
local conflicts = {
	-- App launching (we redefine these below)
	"SUPER + RETURN",
	"SUPER + SHIFT + F",
	"SUPER + E",
	"SUPER + B",
	"SUPER + M",
	"SUPER + SPACE",
	"SUPER + CTRL + SPACE",
	"SUPER + K",
	-- Workspace focus + send-window (we redefine all 10)
	"SUPER + 1", "SUPER + 2", "SUPER + 3", "SUPER + 4", "SUPER + 5",
	"SUPER + 6", "SUPER + 7", "SUPER + 8", "SUPER + 9", "SUPER + 0",
	"SUPER + SHIFT + 1", "SUPER + SHIFT + 2", "SUPER + SHIFT + 3",
	"SUPER + SHIFT + 4", "SUPER + SHIFT + 5", "SUPER + SHIFT + 6",
	"SUPER + SHIFT + 7", "SUPER + SHIFT + 8", "SUPER + SHIFT + 9",
	"SUPER + SHIFT + 0",
	-- Directional focus + swap (we redefine all four)
	"SUPER + LEFT",  "SUPER + RIGHT", "SUPER + UP", "SUPER + DOWN",
	"SUPER + SHIFT + LEFT",  "SUPER + SHIFT + RIGHT",
	"SUPER + SHIFT + UP",    "SUPER + SHIFT + DOWN",
	-- Window management (we redefine Q, W, T, F, V)
	"SUPER + Q", "SUPER + W", "SUPER + T", "SUPER + F", "SUPER + V",
	-- Layout toggle + reload + exit
	"SUPER + L", "SUPER + SHIFT + L", "SUPER + R", "SUPER + Escape",
	-- ALT-space (kept for safety — dms has historically bound this)
	"ALT + space",
}
for _, key in ipairs(conflicts) do
	hl.unbind(key)
end

-- ── 2. App launching ────────────────────────────────────────────────────────
local apps = {
	{"SUPER + RETURN",      "ghostty",                                               "Terminal"},
	{"SUPER + SHIFT + F",   "nautilus",                                              "File manager (open)"},
	{"SUPER + E",           scrPath .. "/omarchy-launch-or-focus thunar thunar",     "File manager (launch-or-focus)"},
	{"SUPER + B",           scrPath .. "/omarchy-launch-browser",                    "Browser (xdg default)"},
	{"SUPER + M",           "dms ipc call spotlight focusOrToggle",                  "Spotlight (focus)"},
	{"SUPER + SPACE",       "dms ipc call spotlight toggle",                         "Spotlight (toggle)"},
	{"SUPER + CTRL + SPACE","dms ipc call wallpaperCarousel toggle",                 "Wallpaper carousel"},
	{"SUPER + K",           scrPath .. "/omarchy-menu-keybindings-minimal",          "Keybindings cheatsheet"},
}
for _, entry in ipairs(apps) do
	hl.bind(entry[1], hl.dsp.exec_cmd(entry[2]), { description = entry[3] })
end

-- ── 3. Workspace focus (SUPER + 1-9, 0 = ws 10) + send window ───────────────
-- Hyprland binds keys by name: digits are "1".."9" and "0", not "10". Loop
-- 1..9 with "0" -> workspace 10 (the canonical Omarchy keymap).
local focus_workspaces = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
local focus_ws_ids     = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
for idx, key in ipairs(focus_workspaces) do
	local ws = focus_ws_ids[idx]
	hl.bind("SUPER + " .. key,
		hl.dsp.focus({ workspace = ws }),
		{ description = "Focus workspace " .. ws }
	)
end

-- Send window to workspace N. Same key layout as focus.
local move_ws_keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
local move_ws_ids  = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }
for idx, key in ipairs(move_ws_keys) do
	local ws = move_ws_ids[idx]
	hl.bind("SUPER + SHIFT + " .. key,
		hl.dsp.window.move({ workspace = ws }),
		{ description = "Move active window to workspace " .. ws }
	)
end

-- ── 4. Directional focus + swap ─────────────────────────────────────────────
-- Hyprland dispatcher names use "l", "r", "u", "d" for direction swaps
-- (single-letter) and full words ("left", "right", "up", "down") for focus.
--
-- Layout toggle is bound to SUPER + L only (see § 6). SHIFT + L was
-- removed: layouts mutate window arrangement and shipping two bind
-- surfaces for the same mutation made the layout "feel unpredictable"
-- whenever a stray Shift modifier flipped it.
local dirs = {
	{ focus = "left",  arrow = "LEFT",  swap = "l" },
	{ focus = "right", arrow = "RIGHT", swap = "r" },
	{ focus = "up",    arrow = "UP",    swap = "u" },
	{ focus = "down",  arrow = "DOWN",  swap = "d" },
}
for _, d in ipairs(dirs) do
	hl.bind("SUPER + " .. d.arrow,
		hl.dsp.focus({ direction = d.focus }),
		{ description = "Focus window " .. d.focus }
	)
	hl.bind("SUPER + SHIFT + " .. d.arrow,
		hl.dsp.window.swap({ direction = d.swap }),
		{ description = "Swap window " .. d.focus }
	)
end

-- ── 5. Window management ────────────────────────────────────────────────────
hl.bind("SUPER + Q", hl.dsp.window.close(), { description = "Close window" })
hl.bind("SUPER + W", hl.dsp.window.close(), { description = "Close window" })
hl.bind("SUPER + T",
	hl.dsp.window.float({ action = "toggle" }),
	{ description = "Toggle floating" }
)
hl.bind("SUPER + F",
	hl.dsp.exec_cmd(scrPath .. "/omarchy-fullscreen-toggle"),
	{ description = "Toggle true fullscreen (hide bars)" }
)
hl.bind("SUPER + V",
	hl.dsp.window.float({ action = "toggle" }),
	{ description = "Toggle floating (V alias)" }
)

-- ── 6. Layout / display ─────────────────────────────────────────────────────
hl.bind("SUPER + L",
	hl.dsp.exec_cmd(scrPath .. "/omarchy-hyprland-workspace-layout-toggle"),
	{ description = "Toggle dwindle/scrolling layout" }
)
-- Layout toggle bound to SUPER + L only. The previous SUPER + SHIFT + L

-- ── 7. Misc / utility ───────────────────────────────────────────────────────
hl.bind("SUPER + R",
	hl.dsp.exec_cmd("hyprctl reload"),
	{ description = "Reload Hyprland config" }
)
hl.unbind("SUPER + Escape")
hl.bind("SUPER + Escape",
	hl.dsp.exec_cmd("hyprctl dispatch exit"),
	{ description = "Exit Hyprland" }
)
