#!/usr/bin/env python3
"""Render a `tmux capture-pane -e` dump as an HTML page a headless browser can screenshot.

Each terminal cell becomes its own absolutely positioned element. That is far more markup than
a <pre> needs, but it is the only way to guarantee the grid survives: this repository's source
is Japanese-heavy, and no font in the container renders DejaVu Sans Mono's Latin advance and a
CJK glyph at exactly a 1:2 ratio, so a flowed <pre> drifts a little further out of alignment on
every wide character until the two window splits no longer line up.

Reads the dump on stdin, writes HTML on stdout.
"""

import argparse
import html
import sys
import unicodedata

# DejaVu Sans Mono's advance width, in em. Every cell's x position is a multiple of this, so the
# grid is exact rather than accumulated from glyph metrics.
CHAR_ADVANCE = 0.6023

FG_DEFAULT = "#e2e2ea"
BG_DEFAULT = "#14161b"

# The xterm base-16 palette, for the 30-37/90-97 and 40-47/100-107 forms.
BASE16 = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
]


def xterm256(n):
    """Colour n of the 256-colour cube, generated rather than tabulated."""
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        levels = (0, 95, 135, 175, 215, 255)
        return levels[n // 36], levels[(n // 6) % 6], levels[n % 6]
    v = 8 + (n - 232) * 10
    return v, v, v


def css_rgb(t):
    return "#%02x%02x%02x" % t


class Pen:
    """The SGR state that applies to the cell about to be emitted."""

    __slots__ = ("fg", "bg", "bold", "italic", "underline", "reverse")

    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = None
        self.bg = None
        self.bold = False
        self.italic = False
        self.underline = False
        self.reverse = False

    def copy(self):
        p = Pen.__new__(Pen)
        for s in Pen.__slots__:
            setattr(p, s, getattr(self, s))
        return p

    def apply(self, params):
        if not params:
            params = [0]
        i = 0
        while i < len(params):
            p = params[i]
            if p == 0:
                self.reset()
            elif p == 1:
                self.bold = True
            elif p == 3:
                self.italic = True
            elif p == 4:
                self.underline = True
            elif p == 7:
                self.reverse = True
            elif p == 22:
                self.bold = False
            elif p == 23:
                self.italic = False
            elif p == 24:
                self.underline = False
            elif p == 27:
                self.reverse = False
            elif 30 <= p <= 37:
                self.fg = css_rgb(BASE16[p - 30])
            elif 90 <= p <= 97:
                self.fg = css_rgb(BASE16[p - 90 + 8])
            elif 40 <= p <= 47:
                self.bg = css_rgb(BASE16[p - 40])
            elif 100 <= p <= 107:
                self.bg = css_rgb(BASE16[p - 100 + 8])
            elif p == 39:
                self.fg = None
            elif p == 49:
                self.bg = None
            elif p in (38, 48):
                target = "fg" if p == 38 else "bg"
                if i + 1 < len(params) and params[i + 1] == 2:
                    setattr(self, target, css_rgb(tuple(params[i + 2 : i + 5])))
                    i += 4
                elif i + 1 < len(params) and params[i + 1] == 5:
                    setattr(self, target, css_rgb(xterm256(params[i + 2])))
                    i += 2
            i += 1

    def style(self):
        fg, bg = self.fg or FG_DEFAULT, self.bg or BG_DEFAULT
        if self.reverse:
            fg, bg = bg, fg
        out = ["color:%s" % fg]
        if bg != BG_DEFAULT:
            out.append("background:%s" % bg)
        if self.bold:
            out.append("font-weight:700")
        if self.italic:
            out.append("font-style:italic")
        if self.underline:
            out.append("text-decoration:underline")
        return ";".join(out)


def cells(line):
    """Expand one captured line into (char, pen, columns) triples.

    Escape sequences other than SGR are dropped here rather than in a pre-pass, so a stray OSC
    title or cursor-visibility sequence cannot swallow the `m` of a colour that follows it.
    """
    pen, out, pos, n = Pen(), [], 0, len(line)
    while pos < n:
        ch = line[pos]
        if ch == "\x1b" and pos + 1 < n:
            intro = line[pos + 1]
            if intro == "[":  # CSI: parameters, then a final byte
                end = pos + 2
                while end < n and (line[end].isdigit() or line[end] in ";:?<>!"):
                    end += 1
                if end < n:
                    if line[end] == "m":
                        params = [int(x) if x.isdigit() else 0
                                  for x in line[pos + 2 : end].split(";")]
                        pen.apply(params)
                    pos = end + 1
                    continue
            elif intro == "]":  # OSC: runs to BEL or ST
                end = pos + 2
                while end < n and line[end] != "\x07":
                    if line[end] == "\x1b" and end + 1 < n and line[end + 1] == "\\":
                        end += 1
                        break
                    end += 1
                pos = min(end + 1, n)
                continue
            pos += 2
            continue
        pos += 1
        if ch == "\x1b":
            continue
        width = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        out.append((ch, pen.copy(), width))
    return out


def render(text, cols, font_px, line_px, pad_px):
    cw = font_px * CHAR_ADVANCE
    lines = text.rstrip("\n").split("\n")
    rows = len(lines)
    body = []
    for row, line in enumerate(lines):
        col = 0
        for ch, pen, width in cells(line):
            # A blank cell only needs an element if it paints a background.
            if ch != " " or pen.bg is not None or pen.reverse:
                body.append(
                    '<i style="left:%.2fpx;top:%dpx;width:%.2fpx;%s">%s</i>'
                    % (col * cw, row * line_px, width * cw, pen.style(), html.escape(ch))
                )
            col += width
    return f"""<!doctype html><meta charset="utf-8"><title>terminal capture</title><style>
  html,body{{margin:0;background:{BG_DEFAULT}}}
  #t{{position:relative;width:{cols * cw:.0f}px;height:{rows * line_px}px;padding:{pad_px}px;
     font-family:"DejaVu Sans Mono","WenQuanYi Zen Hei Mono","IPAGothic",monospace;
     font-size:{font_px}px;line-height:{line_px}px}}
  /* Each cell states its own height and line-height. Leaving them to the line box let the
     statusline row's descenders fall outside the box and get clipped by overflow:hidden. */
  #t i{{position:absolute;display:block;overflow:hidden;font-style:normal;white-space:pre;
        height:{line_px}px;line-height:{line_px}px;text-align:left}}
</style><div id="t">{"".join(body)}</div>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cols", type=int, required=True, help="pane width the dump was taken at")
    ap.add_argument("--font-px", type=int, default=15)
    ap.add_argument("--line-px", type=int, default=21)
    ap.add_argument("--pad-px", type=int, default=14)
    a = ap.parse_args()
    sys.stdout.write(render(sys.stdin.read(), a.cols, a.font_px, a.line_px, a.pad_px))


if __name__ == "__main__":
    main()
