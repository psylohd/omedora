#!/usr/bin/env python3
"""Render the FEDORA wordmark as PNGs from the Omarchy ascii art source.

Uses /home/intox/dev/hypra-plymouth/omarchy-ascii.sh to regenerate the ascii
text from scratch, then rasterizes it to logos/fedora.png (native res) and
logo.png (800px-wide for Plymouth).

Pure Python stdlib — no PIL needed.
"""

import os
import struct
import subprocess
import sys
import zlib

THEME_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASCII_SCRIPT = "/home/intox/dev/hypra-plymouth/omarchy-ascii.sh"
ASCII_TXT = os.path.join(THEME_DIR, "logos", "fedora.txt")
OUT_NATIVE = os.path.join(THEME_DIR, "logos", "fedora.png")
OUT_LOGO = os.path.join(THEME_DIR, "logo.png")
# Match terminal character aspect ratio: each glyph is taller than wide.
CELL_W = 12      # pixels per character width
CELL_H = 18      # pixels per character height
PAD = 32         # outer transparent padding
TERMINAL_GREEN = (0x9E, 0xCE, 0x6A, 0xFF)

def regenerate_ascii(text="Fedora"):
    """Run the omarchy-ascii.sh script to regenerate the ascii art."""
    r = subprocess.run([ASCII_SCRIPT, text], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"omarchy-ascii.sh failed: {r.stderr}")
    lines = [l.rstrip() for l in r.stdout.splitlines() if l.strip()]
    with open(ASCII_TXT, "w") as f:
        f.write("\n".join(lines) + "\n")
    return lines

def is_lit(ch, local_x, local_y):
    """Return True if the given pixel (local_x, local_y) within an 8x8 cell is lit."""
    half = CELL // 2
    if ch == '█':
        return True
    if ch == '▀':
        return local_y < half
    if ch == '▄':
        return local_y >= half
    if ch == '▌':
        return local_x < half
    if ch == '▐':
        return local_x >= half
    return False

def png_chunk(ctype, data):
    out = struct.pack('>I', len(data)) + ctype + data
    crc = zlib.crc32(ctype + data) & 0xffffffff
    return out + struct.pack('>I', crc)

def write_png(path, w, h, pixels):
    compressed = zlib.compress(bytes(pixels), 9)
    png = b'\x89PNG\r\n\x1a\n'
    png += png_chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += png_chunk(b'IDAT', compressed)
    png += png_chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)

def render(ascii_lines, cell_w=CELL_W, cell_h=CELL_H, pad=PAD):
    height = len(ascii_lines)
    width = max(len(l) for l in ascii_lines)
    print(f"ascii: {width}x{height}, cell={cell_w}x{cell_h}px")

    src_w = width * cell_w + pad * 2
    src_h = height * cell_h + pad * 2

    buf = bytearray()
    for y in range(src_h):
        buf.append(0)
        for x in range(src_w):
            if x < pad or x >= src_w - pad or y < pad or y >= src_h - pad:
                r, g, b, a = 0, 0, 0, 0
            else:
                cx = (x - pad) // cell_w
                cy = (y - pad) // cell_h
                if cy < height and cx < len(ascii_lines[cy]):
                    ch = ascii_lines[cy][cx]
                    if is_lit(ch, (x - pad) % cell_w, (y - pad) % cell_h):
                        r, g, b, a = TERMINAL_GREEN
                    else:
                        r, g, b, a = 0, 0, 0, 0
                else:
                    r, g, b, a = 0, 0, 0, 0
            buf.extend((r, g, b, a))

    write_png(OUT_NATIVE, src_w, src_h, buf)
    print(f"Wrote {OUT_NATIVE} ({src_w}x{src_h})")

    scale = 800 / src_w
    out_w = 800
    out_h = int(src_h * scale)
    buf2 = bytearray()
    for y in range(out_h):
        buf2.append(0)
        for x in range(out_w):
            sx = int(x / scale)
            sy = int(y / scale)
            idx = (sy * src_w + sx) * 4
            buf2.extend(buf[idx + 1:idx + 5])
    write_png(OUT_LOGO, out_w, out_h, buf2)
    print(f"Wrote {OUT_LOGO} ({out_w}x{out_h})")