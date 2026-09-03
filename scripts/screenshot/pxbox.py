#!/usr/bin/env python3
"""Report the bounding box of everything painted in a PNG, ignoring the page background.

This exists because the failure it catches is invisible to the eye. A capture whose bottom rows
are silently clipped looks like a correct screenshot of a slightly different screen — the
statusline is simply absent, and every row above it is right. Measuring the painted region turns
that into a number you can compare against `rows x line-height`.

Decodes the PNG with nothing but zlib, so it needs no image library.
"""

import argparse
import struct
import sys
import zlib


def read_png(path):
    """Decode an 8-bit RGB/RGBA PNG to (width, height, channels, rows-as-bytes)."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG")
    pos, idat, ihdr = 8, bytearray(), None
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    width, height, depth, ctype = ihdr[0], ihdr[1], ihdr[2], ihdr[3]
    if depth != 8 or ctype not in (2, 6):
        sys.exit(f"{path}: only 8-bit RGB/RGBA is supported (depth={depth} type={ctype})")
    channels = 3 if ctype == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[p]
        line = bytearray(raw[p + 1 : p + 1 + stride])
        p += 1 + stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, channels, rows


def background_colour(width, height, channels, rows):
    """The page background, taken as the most common colour along the image border.

    The page ansi2html.py renders carries padding on all four sides, so its outermost pixels are
    background whatever the terminal drew. Reading a single pixel instead — the earlier version
    sampled one at the right edge, half way down — inverts the whole measurement the moment that
    pixel lands on something painted, such as a full-width statusline in a two-pane layout: the
    tool then reports the background as the painted region and can call a clipped capture fine,
    which is the one answer it must never give.
    """
    counts = {}

    def tally(x, y):
        key = bytes(rows[y][x * channels : x * channels + 3])
        counts[key] = counts.get(key, 0) + 1

    for x in range(width):
        tally(x, 0)
        tally(x, height - 1)
    for y in range(height):
        tally(0, y)
        tally(width - 1, y)
    return tuple(max(counts, key=counts.get))


def main():
    """Report the painted bounding box, and fail if --expect-height is not reached."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("png")
    ap.add_argument("--tolerance", type=int, default=12,
                    help="per-channel distance from the background that counts as painted")
    ap.add_argument("--expect-height", type=int, default=None,
                    help="fail if the painted region is shorter than this many pixels")
    a = ap.parse_args()

    width, height, channels, rows = read_png(a.png)
    bg = background_colour(width, height, channels, rows)

    x0, y0, x1, y1, painted = width, height, -1, -1, 0
    for y, row in enumerate(rows):
        for x in range(width):
            px = row[x * channels : x * channels + 3]
            if max(abs(px[i] - bg[i]) for i in range(3)) > a.tolerance:
                painted += 1
                x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)

    print(f"{a.png}: {width}x{height}px  bg={bg}  painted={painted}px")
    if not painted:
        print("  nothing painted")
        sys.exit(1)
    box_h = y1 - y0 + 1
    print(f"  x {x0}..{x1} (w={x1 - x0 + 1})   y {y0}..{y1} (h={box_h})")
    if a.expect_height is not None and box_h < a.expect_height:
        sys.exit(f"  painted height {box_h} < expected {a.expect_height}: the capture is clipped")


if __name__ == "__main__":
    main()
