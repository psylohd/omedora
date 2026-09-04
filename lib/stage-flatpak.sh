# lib/stage-flatpak.sh — install Flatpak apps from omedora.toml.
#
# Zen Browser is the obvious one: not in any dnf repo, lives on Flathub.
# Flathub is added once. System-scope installs use --system (run as root,
# land in /var/lib/flatpak). User-scope installs use --user and MUST be
# invoked as the desktop user (sudo -u) so they land in their own
# ~/.local/share/flatpak, not /root's.

# `desktop-file-utils` (provides `update-desktop-database`) is required
# by this stage to keep Flatpak .desktop entries visible to dms without
# a re-login. Install it on entry if missing — Fedora Server's "Standard"
# environment already pulls it in via glib's weak deps, but a bare
# minimal install will not. The dnf5 install is a no-op on re-runs.
command -v update-desktop-database >/dev/null 2>&1 \
  || dnf5 -y install desktop-file-utils >/dev/null 2>&1 \
  || warn "desktop-file-utils install failed; Flatpak .desktop entries may not appear until re-login"

stage_flatpak() {
  require_root
  section "flatpak"

  command -v flatpak >/dev/null 2>&1 || {
    info "flatpak not installed — installing"
    dnf5 -y install flatpak || die "failed to install flatpak"
  }
  # Idempotent: --if-not-exists is supported by recent flatpak.
  flatpak remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo \
    || die "failed to add Flathub remote"

  # Resolve the desktop user's home ONCE; used both by the user-scope
  # flatpak install (--user) and by the user-scope desktop-database
  # refresh below. stage-dms.sh / stage-configs.sh do this the same way.
  local target_user="${OMEDORA_TARGET_USER}"
  local user_home
  if [[ -n "${target_user}" ]] && id "${target_user}" >/dev/null 2>&1; then
    user_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  fi

  # System-scope flatpak CLI reads /var/lib/flatpak/repo (added above is
  # already visible there). User-scope reads ~/.local/share/flatpak/repo,
  # which is a separate repo and needs flathub added again for the
  # desktop user's own remote list. Without this, `flatpak install --user
  # flathub ...` errors with "Remote 'flathub' not found" because the
  # system remote isn't visible from the user repo.
  if [[ ${#OMEDORA_FLATPAK_USER[@]} -gt 0 ]]; then
    info "adding flathub to user-scope remote for ${OMEDORA_TARGET_USER}"
    sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
      flatpak remote-add --if-not-exists --user flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo \
      || warn "failed to add user-scope flathub (user Flatpaks will fail)"
  fi

  if [[ ${#OMEDORA_FLATPAK_SYSTEM[@]} -gt 0 ]]; then
    info "installing ${#OMEDORA_FLATPAK_SYSTEM[@]} system Flatpak(s)"
    # --or-update: install if missing, update if already installed.
    # positional app-id after remote name (not --flag app-id).
    flatpak install -y --system flathub --or-update "${OMEDORA_FLATPAK_SYSTEM[@]}" \
      || warn "system Flatpak install had failures (continuing)"
  fi

  # ── Zen Browser extensions ──────────────────────────────────────────────────
  #
  # Zen Browser is a Flatpak, so extensions must be installed INSIDE the
  # sandbox. Strategy: use `flatpak run --command=python3` with a compact
  # Python -c one-liner that runs ENTIRELY inside the sandbox — it downloads
  # each XPI from AMO, extracts it to the profile's extensions/ dir, and reads
  # the extension ID from manifest.json. No file paths cross the sandbox
  # boundary at all.
  #
  # Extensions activate on next browser launch.
  if [[ ${#OMEDORA_ZEN_EXTENSIONS[@]} -gt 0 ]]; then

    # Confirm Zen Browser Flatpak is actually installed before attempting.
    if sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
      flatpak list --user --app 2>/dev/null | grep -q 'app\.zen_browser\.zen'; then
      info "installing ${#OMEDORA_ZEN_EXTENSIONS[@]} extension(s) into Zen Browser"

      # Build a single-quoted Python -c argument that runs inside the sandbox.
      # shellcheck disable=SC2016  # single quotes prevent expansion — intentional
      sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
        flatpak run --command=python3 \
        app.zen_browser.zen \
        -c '
import sys, os, json, zipfile, re, urllib.request, tempfile
xpi_urls = sys.argv[1:]
if not xpi_urls:
    print("No extension URLs provided", file=sys.stderr)
    sys.exit(0)
profile_base = os.path.expanduser("~/.var/app/app.zen_browser.zen/.zen")
ini_path = os.path.join(profile_base, "profiles.ini")
profile_dir = None
in_default = False
with open(ini_path) as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("["):
            in_default = False
            m = re.match(r"^\[Profile\d+\]$", line)
            if m:
                section = m.group(0).strip("[]")
        elif line.startswith("Default=") and line.split("=", 1)[1].strip() == "1":
            in_default = True
        elif line.startswith("Path=") and in_default:
            profile_dir = line.split("=", 1)[1].strip()
            break
if not profile_dir:
    sys.exit("ERROR: could not determine profile path from profiles.ini")
profile_path = os.path.join(profile_base, profile_dir)
ext_dir = os.path.join(profile_path, "extensions")
os.makedirs(ext_dir, exist_ok=True)
for url in xpi_urls:
    with tempfile.NamedTemporaryFile(suffix=".xpi", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        print(f"INFO: downloading {url}")
        urllib.request.urlretrieve(url, tmp_path)
        xpi_id = None
        try:
            with zipfile.ZipFile(tmp_path, "r") as z:
                if "manifest.json" in z.namelist():
                    with z.open("manifest.json") as mf:
                        manifest = json.loads(mf.read().decode("utf-8"))
                        xpi_id = manifest.get("applications", {}).get("gecko", {}).get("id")
                        if not xpi_id:
                            xpi_id = manifest.get("browser_specific_settings", {}).get("gecko", {}).get("id")
        except Exception as e:
            print(f"WARNING: could not read manifest from {url}: {e}", file=sys.stderr)
        if not xpi_id:
            xpi_id = os.path.splitext(os.path.basename(url))[0]
            print(f"INFO: using filename as extension ID: {xpi_id}")
        ext_target = os.path.join(ext_dir, xpi_id)
        os.makedirs(ext_target, exist_ok=True)
        with zipfile.ZipFile(tmp_path, "r") as z:
            z.extractall(ext_target)
        print(f"INFO: installed {xpi_id} to {ext_target}")
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
print("INFO: all extensions installed successfully")
' \
        "${OMEDORA_ZEN_EXTENSIONS[@]}" \
        || warn "Zen Browser extension install had failures (continuing)"
    else
      [[ ${#OMEDORA_ZEN_EXTENSIONS[@]} -gt 0 ]] \
        && warn "Zen Browser Flatpak not installed; skipping extensions"
    fi
  fi


  # ── Refresh desktop-entry caches so dms / xdg-desktop-portal see Flatpaks ──
  #
  # Without this step, freshly-installed Flatpaks DO exist on disk (under
  # /var/lib/flatpak/exports/share/applications for system installs and
  # ~/.local/share/flatpak/exports/share/applications for user installs),
  # but the desktop-database cache at $XDG_DATA_DIRS/applications/
  # desktop.cache is stale. dms enumerates desktop entries through the
  # cache (xdg-desktop-portal's "recent files" / "open with" UIs read it,
  # and dms's own launcher menu reads it via glib's GDesktopAppInfo), so
  # an un-refreshed cache means: app icons are present but unselectable
  # from the launcher, "Open With" menus are empty, and the .desktop
  # file is invisible until the user logs out and back in (which forces
  # glib to re-scan on startup).
  #
  # `update-desktop-database` is in the `desktop-file-utils` RPM, which
  # ships in the Fedora Server "Standard" environment. If it's missing
  # on a bare-minimal install, fall back to a plain find that triggers
  # glib's auto-rescan on next launch (a no-op rather than an error).
  #
  # `flatpak update --appstream` refreshes the AppStream metadata that
  # dms's plugin installer / Software Center integration consumes. It
  # is a no-op when the AppStream cache is already fresh; cheap to run.
  if command -v update-desktop-database >/dev/null 2>&1; then
    info "refreshing desktop-entry caches for Flatpak installs"
    update-desktop-database /var/lib/flatpak/exports/share/applications 2>/dev/null \
      || warn "system flatpak desktop-database refresh failed (entries may not appear until re-login)"
    if [[ -n "${user_home:-}" && -d "${user_home}/.local/share/flatpak/exports/share/applications" ]]; then
      sudo -u "${OMEDORA_TARGET_USER}" env HOME="${user_home}" \
        update-desktop-database "${user_home}/.local/share/flatpak/exports/share/applications" \
        2>/dev/null \
        || warn "user flatpak desktop-database refresh failed (entries may not appear until re-login)"
    fi
  else
    warn "update-desktop-database not installed; Flatpak .desktop entries may not appear until re-login"
  fi

  # AppStream metadata refresh (system scope). Cheap, idempotent, no-op
  # when cache is fresh. User scope has its own AppStream cache but the
  # system one is what dms reads by default.
  flatpak update --appstream 2>/dev/null \
    || warn "flatpak update --appstream failed (AppStream metadata stale; cosmetic)"
 }

