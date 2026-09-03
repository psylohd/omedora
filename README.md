
# omedora

**_omarchy without the DHH. ✨ And on fedora ✨_**

> **This is a personal-use post install script. Largely Vibecoded. Not for distribution.**
> Also depends on some fedora coprs, so there's some risk here. Slightly better than `curl | sh` but still of note.
> Probably don't use this.  ¯\\_(ツ)_/¯
> Clone it, fork it, twist it, bop it! I don't care

## But Whyyyy? This seems like a waste of time.

It is. But I think it's a fun waste of time.

I recently tried omarchy and **really** liked hyprland. I didn't like the bloatware, the terrible security, and a lot of choices DHH made. And I don't really want to use a system with packages maintained by vibecoders. Sounds like a nightmare. 

I also couldn't find a decent hypraland fedora spin online. And the last thing I wanted is to use a random fedora-based distro. Eew

Now that I've been converted from pretty but clunky gnome, I wanted to build my dream desktop.

btw, I don't use arch



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
repo. The installer clones tuigreet from
`https://github.com/psylohd/tuigreet.git` and builds at install time.



# Quick start

## 0. Install Fedora Everything Server Image
Make sure Common NetworkManager Submodules and Standard are selected in software selection
 
## 1. Clone + edit config

    sudo dnf install git -y
    git clone https://github.com/psylohd/omedora.git
    cd omedora

## 2. Run

     sudo ./install.sh

## 3. Reboot. You should see Plymouth → tuigreet → Hyprland → dms.
Profit!



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

## What this does NOT do

- No GNOME desktop — just Nautilus, Disks, Loupe, Text Editor (the apps).
- No `dms-greeter` (I use a custom `tuigreet` as the login greeter).
- No "agentic os" bs. No weird non-standard tmux bindings. 
- Provide a beginner-friendly installation for new linux users.
- Raise 10M in funding lol

## License: YOLO
Do whatever you want with this.
If it breaks then soz, but it's ur fault - u looked at it funny.
No warranty. No refunds. No blaming me.
I did not make you use this.
