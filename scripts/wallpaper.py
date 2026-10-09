#!/usr/bin/env python3
"""Generate the Deeebian wallpaper as a PNG using only the standard library.

Why this exists: the image must not depend on an external asset in the repo or on a
package that can draw images, and it must work inside the build chroot. zlib + struct
can write a valid PNG, so we synthesise the wallpaper at build time.

Design (800x480, the 701's panel):
  * deep blue-black vertical gradient (easy on the eye, hides panel dirt)
  * a soft teal diagonal sheen so it reads as "designed", not "failed to load"
  * a faint grid, which makes it look deliberate at this low resolution
Deliberately NO text: rasterising glyphs in pure Python is not worth it, and the
quick-reference that matters lives on the desktop icon, the panel and the MOTD.
"""
import struct, zlib, sys

W, H = 800, 480

def lerp(a, b, t):
    return int(a + (b - a) * t)

def pixel(x, y):
    # base vertical gradient: #0b0f16 -> #14202e
    t = y / (H - 1)
    r = lerp(0x0b, 0x14, t)
    g = lerp(0x0f, 0x20, t)
    b = lerp(0x16, 0x2e, t)

    # diagonal teal sheen, brightest along y = 0.35H - 0.6x
    d = abs((y - 0.35 * H) + 0.6 * (x - 0.25 * W))
    sheen = max(0.0, 1.0 - d / 260.0) ** 2
    r += int(0x10 * sheen); g += int(0x2e * sheen); b += int(0x2a * sheen)

    # faint grid every 40px
    if x % 40 == 0 or y % 40 == 0:
        r += 5; g += 8; b += 9

    return min(r, 255), min(g, 255), min(b, 255)

raw = bytearray()
for y in range(H):
    raw.append(0)  # PNG filter type 0 for this scanline
    for x in range(W):
        raw.extend(pixel(x, y))

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
       + chunk(b"IEND", b""))

out = sys.argv[1] if len(sys.argv) > 1 else "eeepc-wallpaper.png"
with open(out, "wb") as f:
    f.write(png)
print(f"wrote {out}: {W}x{H}, {len(png)} bytes")
