-- Optional per-user keybind overrides (managed by DMS). Loaded after default binds.
-- This file layers Omarchy-style shortcuts on top of DMS defaults.
-- Loaded last, so re-bindings here override DMS defaults.

local scrPath = (os.getenv("HOME") or "") .. "/.config/hypr/Scripts"

-- Omarchy-style overrides
-- Clear DMS's lowercase-key Super+space + Alt+space so they don't race with
-- our uppercase-key Super+SPACE registration.
hl.unbind("SUPER + space")
hl.unbind("ALT + space")

-- Omarchy-style overrides
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("ghostty"))
hl.bind("SUPER + SHIFT + F", hl.dsp.exec_cmd("nautilus"))

hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("dms ipc call spotlight toggle"), {
	description = "Toggle spotlight (launcher)",
})



hl.bind("SUPER + M", hl.dsp.exec_cmd("dms ipc call spotlight focusOrToggle"))
hl.bind("SUPER + W", hl.dsp.window.close())

-- --- User additions (apply on top of DMS) ---

-- Clear DMS's Super+L (focus-right) and Super+K (focus-up) so they don't shadow our overrides.
hl.unbind("SUPER + L")
hl.unbind("SUPER + K")
hl.unbind("SUPER + T")

-- Toggle layout dwindle/scrolling on the active workspace (Omarchy-style).
hl.bind("SUPER + L", hl.dsp.exec_cmd(scrPath .. "/omarchy-hyprland-workspace-layout-toggle"), {
	description = "Toggle dwindle/scrolling layout",
})

-- Toggle floating on Super+T (Omarchy-style; DMS had ghostty there).
hl.bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }), {
	description = "Toggle floating",
})

-- Minimal wofi keybindings cheatsheet on Super+K (Omarchy-style).
hl.bind("SUPER + K", hl.dsp.exec_cmd(scrPath .. "/omarchy-menu-keybindings-minimal"), {
	description = "Keybindings (minimal)",
})

-- Launch-or-focus thunar on Super+E (Omarchy-style).
hl.bind("SUPER + E", hl.dsp.exec_cmd(scrPath .. "/omarchy-launch-or-focus thunar thunar"), {
	description = "File manager (open or focus)",
})

-- XDG default browser on Super+B (Omarchy-style).
hl.bind("SUPER + B", hl.dsp.exec_cmd(scrPath .. "/omarchy-launch-browser"), {
	description = "Browser (xdg default)",
})

-- Wallpaper carousel on Super+Ctrl+Space (Omarchy's "background switcher" chord).
hl.bind("SUPER + CTRL + SPACE", hl.dsp.exec_cmd("dms ipc call wallpaperCarousel toggle"), {
	description = "Toggle wallpaper carousel",
})

-- True fullscreen on Super+F (DMS defaults to "maximized" which keeps borders/gaps/bars).
-- "fullscreen" mode hides bars and decorations so the pane owns the whole monitor,
-- like Ghostty's Ctrl+Enter fullscreen.
hl.unbind("SUPER + F")
hl.bind("SUPER + F", hl.dsp.exec_cmd(scrPath .. "/omarchy-fullscreen-toggle"), {
	description = "Toggle fullscreen (hide bars)",
})