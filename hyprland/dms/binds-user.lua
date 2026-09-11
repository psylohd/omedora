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
--   8. Mouse-drag rearrange (SUPER + mouse:272 → window.drag())
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
	"SUPER + CTRL + SPACE",
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
	-- Minimize / restore (added in § 9)
	"SUPER + MINUS", "SUPER + CTRL + equal", "SUPER + equal",
	-- Mouse-button binds: SUPER + LMB drag is rebound in § 8.
	-- dms upstream does NOT bind this by default, but listing it
	-- here future-proofs against a future dms release that adds it.
	"SUPER + mouse:272",
	-- ALT-space (kept for safety — dms has historically bound this)
	"ALT + space",
	-- HyprCapture: Print opens the screenshot overlay (region select). The
	-- explicit unbind below clears any leftover dispatch from a previous
	-- session before we re-bind. SHIFT + Print is left unbound for users
	-- who want to add it as a quick fullscreen capture.
	"Print",
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
	{"SUPER + SPACE",       "dms ipc call spotlight toggle",                         "Spotlight (toggle)"},
	{"SUPER + CTRL + SPACE","dms ipc call wallpaperCarousel toggle",                 "Wallpaper carousel"},
	{"SUPER + K",           scrPath .. "/omarchy-menu-keybindings-minimal",          "Keybindings cheatsheet"},
}

-- Some keyboards emit Linux KEY_PRINT (XKB `I218`) rather than the
-- traditional PrintScreen key (XKB `PRSC`). Keep both forms bound; this
-- avoids relying on the keysym produced by a device-specific firmware map.
-- Use --overlay-scope all so the region overlay spans the entire desktop.
-- With split-monitor-workspaces loaded the keyboard lives on DP-3 and
-- `active` always resolves to that monitor, leaving HDMI-A-1 unsupported.
-- `all` makes the overlay cover both outputs so the larger monitor can
-- be captured regardless of which workspace holds the focused window.
local function hyprcapture_dispatcher()
	return hl.dsp.exec_cmd(
		"/home/intox/.local/bin/hyprcapture-ui --mode region --overlay-scope all"
	)
end
hl.bind("Print", hyprcapture_dispatcher(), { description = "HyPrCapture screenshot overlay (region)" })

for _, entry in ipairs(apps) do
	hl.bind(entry[1], hl.dsp.exec_cmd(entry[2]), { description = entry[3] })
end
-- ── 3. Workspace focus (SUPER + 1..5) + send window ─────────────────────────
-- Workspaces are managed by split-monitor-workspaces (smw), giving
-- per-monitor independent numbering: SUPER+1 on monitor A goes to A's
-- ws 1; SUPER+1 on monitor B goes to B's ws 1. Loop bound driven by
-- smw.get_amount_of_workspaces(), so SUPER+1..N and SUPER+SHIFT+1..N
-- always match workspace_count in hyprland.lua — change it there, not here.
local smw = require("plugins.split-monitor-workspaces")
for i = 1, smw.get_amount_of_workspaces() do
	local key = tostring(i)
	hl.bind("SUPER + " .. key,
		smw.workspace(key),
		{ description = "Focus workspace " .. key .. " on this monitor" }
	)
	hl.bind("SUPER + SHIFT + " .. key,
		smw.move_to_workspace(key),
		{ description = "Move active window to workspace " .. key .. " and follow it" }
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
hl.bind("SUPER + W",
	hl.dsp.exec_cmd(""),
	{ description = "(unbound)" }
)
-- ── 6. Layout / display ─────────────────────────────────────────────────────
hl.bind("SUPER + M",
	hl.dsp.exec_cmd(scrPath .. "/omarchy-hyprland-workspace-layout-toggle"),
	{ description = "Toggle dwindle/scrolling layout" }
)
hl.bind("SUPER + L",
	hl.dsp.exec_cmd("loginctl lock-session"),
	{ description = "Lock screen" }
)
--
-- ── 8. Mouse-drag rearrange (SUPER + LMB) ───────────────────────────────────
-- Hyprland's `window.drag()` keeps the window tiled and reflows the
-- layout around the new position. NOT a float-and-drag. mouse:272
-- is the xkbcommon keycode for the left mouse button (use `wev` to
-- enumerate other buttons on your hardware). drag_threshold is set
-- in hyprland.lua's binds block; with the default there every
-- press becomes a drag, with our 10 a plain click still focuses.
hl.bind("SUPER + mouse:272",
	hl.dsp.window.drag(),
	{ description = "Drag window within layout (SUPER + LMB)" }
)
-- SUPER + scroll cycles workspaces within the CURRENT monitor's pool
hl.bind("SUPER + mouse_down", smw.cycle_workspaces("next"), { description = "Cycle to next workspace (this monitor)" })
hl.bind("SUPER + mouse_up",   smw.cycle_workspaces("prev"), { description = "Cycle to previous workspace (this monitor)" })
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
-- ── 9. Minimize / restore (SUPER + MINUS / SUPER + equal) ────────────────────
-- "Minimize" parks the active window in the special workspace named
-- `minimized` (Hyprland auto-creates the special on first move). Restore
-- toggles that workspace open (focusing the most recently parked window)
-- and moves it back to whatever workspace was active at restore time.
-- Limitation: all minimized windows share one special workspace, so
-- pressing SUPER+= brings back the most-recently parked window, not any
-- specific one. Single-window-minimize semantics, like the snippet
-- this is based on.
--
-- Hyprland quirk: hl.get_workspaces() reports specials as `.name ==
-- "special:minimized"` while hl.dsp.workspace.toggle_special() takes
-- the bare suffix. The match below handles both forms.
--
-- Keysym names follow the XKB_KEY_<name> convention (lowercase, no
-- `S` suffix). `MINUS` (hyphen) and `equal` (=) are the bare keycap
-- labels, without Shift. Hyprland rejects uppercased variants like
-- `EQUALS` with "Unknown keysym" at hl.bind time.
hl.bind("SUPER + MINUS",
	hl.dsp.window.move({ workspace = "special:minimized", follow = false }),
	{ description = "Minimize current window to scratchpad" }
)
hl.bind("SUPER + CTRL + equal",
	hl.dsp.workspace.toggle_special("minimized"),
	{ description = "Toggle minimized windows workspace" }
)
hl.bind("SUPER + equal",
	function()
		-- Capture destination workspace before touching special.
		local cur = hl.get_active_workspace()
		local dest = cur and cur.name or "1"

		for _, ws in ipairs(hl.get_workspaces()) do
			local nm = ws.name or ""
			if nm == "special:minimized" or nm == "minimized" then
				local wins = hl.get_workspace_windows(ws)
				if #wins > 0 then
					-- Open special to refresh window addresses, focus the last
					-- (most recently parked) window, then move it out.
					hl.dispatch(hl.dsp.workspace.toggle_special("minimized"))
					local win = wins[#wins]
					-- Focus the specific window by address.
					hl.dispatch(hl.dsp.focus({ window = win.address }))
					-- Move the now-focused window to the destination workspace.
					hl.dispatch(hl.dsp.window.move({ workspace = dest }))
				end
				return
			end
		end
	end,
	{ description = "Restore most recently minimized window" }
)
-- ═══════════════════════════════════════════════════════════════════════════
-- § 10. Media keys — brightness, volume, playback
-- ═══════════════════════════════════════════════════════════════════════════
-- These use bare keysyms (no SUPER modifier) so they work without any prefix.
-- brightnessctl no-ops gracefully on machines with no backlight.
-- pactl drives the default PulseAudio/PipeWire sink.
-- playerctl targets whichever media player is active (spotify, firefox, etc.).

-- ── Brightness (laptop panel) ──────────────────────────────────────────────
-- brightnessctl exits 0 when there's no backlight (desktop), so the
-- || true guards against any device-access failure on any machine.
hl.bind("XF86MonBrightnessUp",
	hl.dsp.exec_cmd("brightnessctl set +5% || true"),
	{ description = "Increase screen brightness" }
)
hl.bind("XF86MonBrightnessDown",
	hl.dsp.exec_cmd("brightnessctl set 5%- || true"),
	{ description = "Decrease screen brightness" }
)

-- ── Volume ───────────────────────────────────────────────────────────────────
hl.bind("XF86AudioRaiseVolume",
	hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +5%"),
	{ description = "Raise volume 5%" }
)
hl.bind("XF86AudioLowerVolume",
	hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5%"),
	{ description = "Lower volume 5%" }
)
hl.bind("XF86AudioMute",
	hl.dsp.exec_cmd("pactl set-sink-mute @DEFAULT_SINK@ toggle"),
	{ description = "Toggle mute" }
)

-- ── Media playback ──────────────────────────────────────────────────────────
hl.bind("XF86AudioPlay",
	hl.dsp.exec_cmd("playerctl play-pause"),
	{ description = "Play / pause" }
)
hl.bind("XF86AudioPause",
	hl.dsp.exec_cmd("playerctl pause"),
	{ description = "Pause" }
)
hl.bind("XF86AudioNext",
	hl.dsp.exec_cmd("playerctl next"),
	{ description = "Next track" }
)
hl.bind("XF86AudioPrev",
	hl.dsp.exec_cmd("playerctl previous"),
	{ description = "Previous track" }
)
hl.bind("XF86AudioStop",
	hl.dsp.exec_cmd("playerctl stop"),
	{ description = "Stop playback" }
)
