local env = {
    "HYPRCURSOR_THEME,Bibata-Modern-Classic",
    "HYPRCURSOR_SIZE,24",
    "XCURSOR_THEME,Bibata-Modern-Classic",
    "XCURSOR_SIZE,24",
    "QT_CURSOR_THEME,Bibata-Modern-Classic",
    "QT_CURSOR_SIZE,24",
}

for _, item in ipairs(env) do
    local key, value = item:match("^([^,]+),(.+)$")
    if key and value then
        hl.env(key, value)
    end
end

-- theme.lua is currently UNUSED. hyprland.lua does not require it, so
-- any `hl.config` here is silently ignored. The file is kept in the
-- repo because (a) it holds the Bibata cursor env exports that may be
-- useful as a manual `require("themes.theme")` later, and (b) deletion
-- would invalidate existing user configs that source it.
--
-- DO NOT add `layout = ...` here even if you "fix" the file to be
-- required: layout is owned by dms (see hyprland.lua). Adding it back
-- would re-introduce the "unpredictable window arrangement" bug.
hl.config({
    general = {
        gaps_in = 2,
        gaps_out = 4,
        border_size = 2,
        resize_on_border = true,
        allow_tearing = false,
    },

    decoration = {
        rounding = 8,
        shadow = {
            enabled = true,
        },
        active_opacity = 1.0,
        inactive_opacity = 0.90,
        fullscreen_opacity = 1.0,
        blur = {
            enabled = true,
            size = 1,
            passes = 3,
            new_optimizations = true,
            ignore_opacity = true,
            xray = false,
            special = true,
        },
    },
})
