local env = {
    "XDG_CURRENT_DESKTOP,Hyprland",
    "XDG_SESSION_TYPE,wayland",
    "QT_QPA_PLATFORMTHEME,qt6ct",
    "QT_AUTO_SCREEN_SCALE_FACTOR,1",
    "QT_WAYLAND_DISABLE_WINDOWDECORATION,1",
    "ELECTRON_OZONE_PLATFORM_HINT,wayland",
}

local nvidia_optional = {
    "WLR_NO_HARDWARE_CURSORS,1",
    "LIBVA_DRIVER_NAME,nvidia",
    "GBM_BACKEND,nvidia-drm",
    "__GLX_VENDOR_LIBRARY_NAME,nvidia",
    "NVD_BACKEND,direct",
}

local exec_once = {
    "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 || /usr/libexec/polkit-gnome-authentication-agent-1",
    "gnome-keyring-daemon --start --components=secrets",
    "systemctl --user start --ignore-dependencies xdg-desktop-portal-hyprland.service xdg-desktop-portal.service",
    -- dms is started by dms.service (the user unit, NOT `dms run`
    -- directly). The wiki "Services / dms.service" pattern relies
    -- on hyprland-session.target being live at session start —
    -- hyprland.lua calls `systemctl --user start
    -- hyprland-session.target`, which propagates BindsTo=
    -- graphical-session.target live, which satisfies dms.service's
    -- `Requisite=graphical-session.target` line, which in turn fires
    -- dms.service via `WantedBy=graphical-session.target`. We do NOT
    -- `dms run` here — running dms twice (once from exec-once, once
    -- via systemd) races the IPC socket and breaks notifications.
    "wl-clip-persist --clipboard regular",
    "sh -c 'sleep 3 && easyeffects --gapplication-service'",
}

local nvidia_exec_once_optional = {
    "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
    "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP",
}

-- Optional NVIDIA-specific tweaks. Auto-detected: if any NVIDIA PCI
-- device is present (vendor ID 10de), the optional env+exec_once
-- blocks below are enabled automatically. The auto-detect runs once
-- at config-load via `lspci -d 10de::0300` (NVIDIA display class).
-- The check is non-fatal: if lspci is missing the env falls back to
-- the false branch, no error.
--
-- Override: set OMEDORA_DISABLE_NVIDIA_AUTODETECT=1 in the Hyprland
-- process environment to force the false branch.
local function has_nvidia_gpu()
    if os.getenv("OMEDORA_DISABLE_NVIDIA_AUTODETECT") == "1" then
        return false
    end
    local handle = io.popen("lspci -d 10de::0300 -n 2>/dev/null")
    if not handle then return false end
    local out = handle:read("*a") or ""
    handle:close()
    return out:match("10de") ~= nil
end
local enable_nvidia_optional = has_nvidia_gpu()
for _, item in ipairs(env) do
    local key, value = item:match("^([^,]+),(.+)$")
    if key and value then
        hl.env(key, value)
    end
end

if enable_nvidia_optional then
    for _, item in ipairs(nvidia_optional) do
        local key, value = item:match("^([^,]+),(.+)$")
        if key and value then
            hl.env(key, value)
        end
    end
end

hl.on("hyprland.start", function()
    for _, cmd in ipairs(exec_once) do
        hl.exec_cmd(cmd)
    end

    if enable_nvidia_optional then
        for _, cmd in ipairs(nvidia_exec_once_optional) do
            hl.exec_cmd(cmd)
        end
    end

    -- Run one final reload after startup commands have had time to initialize.
    hl.exec_cmd([[bash -lc 'sleep 2; hyprctl reload']])
end)

return true
