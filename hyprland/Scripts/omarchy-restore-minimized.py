#!/usr/bin/env python3
"""Restore the most recently minimized window to the current workspace.
No flash."""
import subprocess
import re
import sys

LOG = "/tmp/restore_minimized.log"

def log(msg):
    with open(LOG, "a") as f:
        f.write(msg + "\n")

def run(args):
    result = subprocess.run(args, capture_output=True, text=True)
    return result.stdout, result.stderr, result.returncode

def main():
    open(LOG, "w").close()
    log("Starting")

    # Get current workspace
    out, err, _ = run(["hyprctl", "activeworkspace"])
    log(f"activeworkspace: {out!r}")
    # Parse: "workspace ID N (name):" or "workspace ID N:"
    m = re.search(r"\(([^)]+)\)", out)
    if m:
        dest = m.group(1)
    else:
        m = re.search(r"ID\s+([-\d]+)", out)
        dest = m.group(1) if m else "1"
    log(f"dest: {dest}")

    # Get lastwindow on special:minimized
    out, err, _ = run(["hyprctl", "workspaces"])
    log(f"workspaces: {len(out)} bytes")

    special = False
    addr = None
    for line in out.split("\n"):
        if "special:minimized" in line:
            special = True
            log(f"found special: {line.strip()}")
        elif special and "lastwindow:" in line:
            # Extract address
            parts = line.split("lastwindow:", 1)
            if len(parts) > 1:
                addr = parts[1].strip().split()[0]
                log(f"addr: {addr}")
            break

    if not addr:
        log("no window found")
        return

    # Move silently
    out, err, rc = run(["hyprctl", "dispatch", "movetoworkspacesilent", addr, dest])
    log(f"movetoworkspacesilent rc={rc} out={out!r} err={err!r}")

    # Focus
    out, err, rc = run(["hyprctl", "dispatch", "focuswindow", f"address:{addr}"])
    log(f"focuswindow rc={rc} out={out!r} err={err!r}")
    log("done")

if __name__ == "__main__":
    main()
