#!/bin/bash
# Restore Plymouth to a sane default after uninstalling Omedora.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

rm -rf /usr/share/plymouth/themes/omedora

# Restore Fedora's default
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  plymouth-set-default-theme charge 2>/dev/null || \
    plymouth-set-default-theme spinner 2>/dev/null || \
    plymouth-set-default-theme text
fi

if command -v dracut >/dev/null 2>&1; then
  dracut -f
fi

echo "Omedora theme removed. Plymouth reverted to default."