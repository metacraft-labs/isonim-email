"""tools/social-icons/generate.py — the built-in social icons.

Draws the icons `mailSocial` ships (catalogue R-IMG-12): for each
network, a monogram plate — a filled circle with the network's initials,
or a mark drawn from shapes — 64×64 px (2× the largest size shown at the
default density), in two variants:

- `light`: a dark plate (#374151) with a white mark, for light backgrounds;
- `dark`: a light plate (#e5e7eb) with a near-black mark (#111827), for
  dark backgrounds.

The plates are not the networks' brand marks (an application that wants
those passes its own `icon`). Letters are drawn from Roboto Bold, the
capture environment's pinned face, located with `fc-match` under the dev
shell's `FONTCONFIG_FILE`; outlines are read with fonttools, flattened and
filled by a small scanline rasteriser with 4×4 supersampling, so the
output depends on the font bytes only: regenerating on the same font is a
byte-identical no-op (`tests/t3_icons_reproducible.nim`).

Usage: generate.py <out-dir>   (run by `just social-icons`)
"""

import math
import os
import struct
import subprocess
import sys
import zlib

from fontTools.pens.basePen import BasePen
from fontTools.ttLib import TTFont

SIZE = 64
SS = 4  # supersampling per axis
FONT = ("Roboto:style=Bold", "Roboto-Bold.ttf")

# network -> (kind, mark): "text" marks are drawn in Roboto Bold,
# "play" is a triangle.
NETWORKS = [
    ("facebook", "text", "f"),
    ("x", "text", "X"),
    ("linkedin", "text", "in"),
    ("instagram", "text", "IG"),
    ("youtube", "play", ""),
    ("github", "text", "GH"),
    ("mastodon", "text", "M"),
    ("bluesky", "text", "B"),
    ("email", "text", "@"),
    ("website", "text", "W"),
]

VARIANTS = [
    ("light", (0x37, 0x41, 0x51), (0xFF, 0xFF, 0xFF)),
    ("dark", (0xE5, 0xE7, 0xEB), (0x11, 0x18, 0x27)),
]


def locate(pattern, basename):
    path = subprocess.run(
        ["fc-match", "-f", "%{file}", pattern],
        check=True, capture_output=True, text=True).stdout.strip()
    if os.path.basename(path) != basename:
        sys.exit("generate.py: fc-match '%s' gave %s, not %s (is the dev "
                  "shell's FONTCONFIG_FILE in effect?)" % (pattern, path, basename))
    return path


class FlattenPen(BasePen):
    """Collects a glyph's contours as polygons, curves flattened."""

    def __init__(self, glyphset):
        super().__init__(glyphset)
        self.contours = []
        self.cur = None

    def _moveTo(self, p):
        self.cur = [p]
        self.contours.append(self.cur)

    def _lineTo(self, p):
        self.cur.append(p)

    def _curveToOne(self, p1, p2, p3):
        p0 = self.cur[-1]
        for i in range(1, 17):
            t = i / 16
            mt = 1 - t
            x = mt ** 3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t ** 3 * p3[0]
            y = mt ** 3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t ** 3 * p3[1]
            self.cur.append((x, y))

    def _qCurveToOne(self, p1, p2):
        p0 = self.cur[-1]
        for i in range(1, 17):
            t = i / 16
            mt = 1 - t
            x = mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0]
            y = mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1]
            self.cur.append((x, y))

    def _closePath(self):
        self.cur = None

    def _endPath(self):
        self.cur = None


def text_polygons(font, text):
    """The text's outline polygons in font units, laid out left to right."""
    cmap = font.getBestCmap()
    glyphset = font.getGlyphSet()
    hmtx = font["hmtx"]
    polys = []
    x = 0
    for ch in text:
        name = cmap[ord(ch)]
        pen = FlattenPen(glyphset)
        glyphset[name].draw(pen)
        for c in pen.contours:
            polys.append([(px + x, py) for (px, py) in c])
        x += hmtx[name][0]
    return polys


def bbox(polys):
    xs = [p[0] for c in polys for p in c]
    ys = [p[1] for c in polys for p in c]
    return min(xs), min(ys), max(xs), max(ys)


def fit(polys, box_w, box_h):
    """Polygons scaled to fit box_w × box_h (px) and centred in the plate,
    y flipped (font units grow upward)."""
    x0, y0, x1, y1 = bbox(polys)
    w, h = x1 - x0, y1 - y0
    k = min(box_w / w, box_h / h)
    ox = (SIZE - w * k) / 2
    oy = (SIZE - h * k) / 2
    return [[(ox + (px - x0) * k, oy + (y1 - py) * k) for (px, py) in c]
            for c in polys]


def coverage(polys):
    """Per-pixel coverage (0..1) of the polygons, nonzero winding."""
    n = SIZE * SS
    cov = [[0.0] * SIZE for _ in range(SIZE)]
    edges = []
    for c in polys:
        for i in range(len(c)):
            (xa, ya), (xb, yb) = c[i], c[(i + 1) % len(c)]
            if ya != yb:
                edges.append((xa * SS, ya * SS, xb * SS, yb * SS))
    for sy in range(n):
        y = sy + 0.5
        xs = []
        for (xa, ya, xb, yb) in edges:
            if (ya <= y < yb) or (yb <= y < ya):
                t = (y - ya) / (yb - ya)
                xs.append((xa + t * (xb - xa), 1 if yb > ya else -1))
        xs.sort()
        wind = 0
        start = None
        for (x, d) in xs:
            before = wind
            wind += d
            if before == 0 and wind != 0:
                start = x
            elif before != 0 and wind == 0 and start is not None:
                a = max(0, int(math.ceil(start - 0.5)))
                b = min(n - 1, int(math.floor(x - 0.5)))
                for sx in range(a, b + 1):
                    cov[sy // SS][sx // SS] += 1.0 / (SS * SS)
    return cov


def circle(cx, cy, r, steps=256):
    return [[(cx + r * math.cos(2 * math.pi * i / steps),
              cy + r * math.sin(2 * math.pi * i / steps)) for i in range(steps)]]


def mark_polygons(font, kind, mark):
    if kind == "play":
        # A right-pointing triangle, optically centred.
        return [[(25.0, 19.0), (25.0, 45.0), (46.0, 32.0)]]
    polys = text_polygons(font, mark)
    letters = len(mark)
    box_h = 26 if letters == 1 else 22
    box_w = 30 if letters == 1 else 36
    return fit(polys, box_w, box_h)


def png(pixels):
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render(font, kind, mark, plate, ink):
    plate_cov = coverage(circle(32.0, 32.0, 32.0))
    mark_cov = coverage(mark_polygons(font, kind, mark))
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            a = min(1.0, plate_cov[y][x])
            m = min(1.0, mark_cov[y][x])
            rgb = [round(plate[i] * (1 - m) + ink[i] * m) for i in range(3)]
            row.extend(rgb + [round(255 * a)])
        rows.append(row)
    return png(rows)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: generate.py <out-dir>")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    font = TTFont(locate(*FONT))
    for (network, kind, mark) in NETWORKS:
        for (variant, plate, ink) in VARIANTS:
            path = os.path.join(out, "social-%s-%s.png" % (network, variant))
            with open(path, "wb") as f:
                f.write(render(font, kind, mark, plate, ink))


if __name__ == "__main__":
    main()
