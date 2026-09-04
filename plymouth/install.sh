#!/bin/bash
# Install the Omedora Plymouth theme (FEDORA ASCII wordmark on Fedora blue).
# Run as root or with sudo.

set -euo pipefail

THEME_NAME="omedora"
THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..." >&2
  exec sudo bash "$0" "$@"
fi

echo "Installing Omedora Plymouth theme..."

# ModuleName=script in omedora.plymouth requires plymouth-plugin-script
# (ships /usr/lib64/plymouth/script.so). Without it plymouth-set-default-theme
# fails and Plymouth silently falls back to text mode.
if ! ls /usr/lib64/plymouth/script.so &>/dev/null; then
  echo "plymouth-plugin-script is not installed." >&2
  echo "Install it with:  dnf install plymouth-plugin-script" >&2
  exit 1
fi

# Copy theme files into place
install -m 644 \
    "$SOURCE_DIR/omedora.plymouth" \
    "$SOURCE_DIR/omedora.script" \
    "$SOURCE_DIR/logo.png" \
    "$SOURCE_DIR/lock.png" \
    "$SOURCE_DIR/entry.png" \
    "$SOURCE_DIR/bullet.png" \
    "$SOURCE_DIR/progress_box.png" \
    "$SOURCE_DIR/progress_bar.png" \
    "$THEME_DIR/"


# Register theme with Plymouth. Run before dracut so hostonly detection
# sees the new default and includes the plymouth module in the initramfs.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  if ! plymouth-set-default-theme "$THEME_NAME"; then
    echo "plymouth-set-default-theme failed" >&2
    exit 1
  fi
fi

# Rebuild initramfs so the new theme is baked into the boot image.
if command -v dracut >/dev/null 2>&1; then
  echo "Rebuilding initramfs..."
  dracut -f --regenerate-all
elif command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P
else
  echo "No initramfs rebuild tool found (dracut or mkinitcpio required)." >&2
  exit 1
fi

echo "Done. Theme '$THEME_NAME' is now the default. Reboot to test."