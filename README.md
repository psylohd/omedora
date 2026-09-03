# omedora

Personal postinstall script for **Fedora Server + Hyprland + dms + Plymouth + tuigreet**.

> **This is a personal-use script. Largely Vibecoded. Not for distribution.**
> I built it because I wanted a single declarative config file (`omedora.toml`)
> that maps to the handful of files I actually need to keep in sync across
> reinstalls. There is no ISO, no Fedora Spin, no `bootc` image, no
> signature verification, no hardening. If something breaks, I fix it for
> myself.
> 
> I don't really expect anyone else to use this.
>
> Clone it, fork it, copy bits. Don't expect issues to be triaged.

---
## But Whyyy?

I recently tried omarchy and really liked hyprland. I didn't like the bloatware, the terrible security, and a lot of choices DHH made. And I don't really want to use a system with packages maintained by vibecoders. Now that I've been converted from pretty but clunky gnome, I wanted to build my dream desktop. And I like fedora. 

---

## What's here

```
omedora.toml       the entire config: packages, COPRs, vendored dms,
                  tuigreet fork URL, greeter backend, paths, services
install.sh        run once on a fresh Fedora Server install
tweaks.sh         re-apply individual tweaks after the install
lib/              stage functions shared by both scripts
hyprland/         Hyprland Lua configs + dms/binds-user.lua + Scripts/
DankMaterialShell/  dms settings.json, themes/, plugin_settings.json
plymouth/         Plymouth omedora theme (script module)
tuigreet/         tuigreet theme + palette.sh + brand.txt
```
The vendored dms binaries and the tuigreet Cargo workspace are NOT in the
repo. The installer downloads dms from the internet (no sha256 check —
see the warning above) and clones tuigreet from
`https://github.com/psylohd/tuigreet.git` at install time.

---

## Quick start

# 0. Install Fedora Server (DVD ISO, minimal layout, no DE).
#    Verify the ISO sha256 against the published CHECKSUM before booting.

# 1. Clone + edit config
git clone https://github.com/psylohd/omedora.git
cd omedora

# 2. Run
sudo ./install.sh --dry-run # preview
sudo ./install.sh           # go

# 3. Reboot. You should see Plymouth → tuigreet → Hyprland → dms.
systemctl reboot
```

Re-runs are idempotent: every overwritten file gets a timestamped `.bak.<date>`
backup.

---

## `install.sh` vs `tweaks.sh`

| Use case                   | Script        |
|----------------------------|---------------|
| Fresh Fedora Server install | `./install.sh` |
| Try a single tweak / roll back | `./tweaks.sh` |

`tweaks.sh` calls into the same `lib/stage-*.sh` functions, so a tweak
applied via `tweaks.sh` produces the same result as re-running `install.sh`
with `--only <stage>`.

```sh
sudo ./tweaks.sh --list           # see available tweaks
sudo ./tweaks.sh --diff hyprland  # preview what would change
sudo ./tweaks.sh hyprland         # re-apply Hyprland configs
sudo ./tweaks.sh --revert dms     # restore .bak files
```

Available tweaks: `plymouth`, `tuigreet`, `greetd`, `hyprland`, `quickshell`,
`dms`, `services`.

---

## Stages (toggle in omedora.toml `[stages]`)

Default order: `copr → dnf → vendor → flatpak → greetd → plymouth → tuigreet → hyprland → quickshell → dms → services`.

```toml
[stages]
copr       = true   # enable lionheartp/Hyprland + a couple of small COPRs
dnf        = true   # install Hyprland stack + quickshell + apps + rust/cargo
vendor     = true   # download dms + dgop from AvengeMedia/DankMaterialShell
flatpak    = true   # add Flathub, install zen-browser
greetd     = true   # write /etc/greetd/config.toml + /usr/local/bin/start-hyprland
plymouth   = true   # drop Plymouth theme, run dracut -f
tuigreet   = true   # clone + build tuigreet from your fork, install binary
hyprland   = true   # deploy hyprland/ → ~/.config/hypr/
quickshell = true   # deploy quickshell/ → ~/.config/quickshell/
dms        = true   # deploy DankMaterialShell/ + install plugins from [dms_plugins]
services   = true   # systemctl enable greetd; set-default graphical.target
```

CLI overrides:

```sh
sudo ./install.sh --only dnf,vendor
sudo ./install.sh --skip flatpak
```

---

## What this does NOT do

- No ISO, no bootc / atomic / rpm-ostree. Plain mutable Fedora Server.
- No signature verification on dms downloads.
- No NVIDIA-specific Plymouth / driver config.
- No GNOME desktop — just Nautilus, Disks, Loupe, Text Editor (the apps).
- No `dms-greeter` (we use `tuigreet` as the login greeter).

---

## Bumping dms

```sh
# 1. Update [vendored.dms].version in omedora.toml.
# 2. (Optional) sanity-check the new release at
#    https://github.com/AvengeMedia/DankMaterialShell/releases
# 3. Refresh:
sudo ./install.sh --only vendor
```

---

## License

YOLO
