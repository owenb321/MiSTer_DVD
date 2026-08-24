#!/usr/bin/env python3
"""hud_font.py -- generate the Phase-11 transport-HUD glyph ROM.

Emits:
  dvd/hud_font.mem       -- $readmemh init for transport_hud's glyph ROM:
                            1024 x 16-bit words, address = {glyph[5:0], row[3:0]},
                            each word = one 8-pixel glyph row, 2 bpp per pixel
                            (MSB pair = leftmost pixel):
                              0 = transparent, 1 = outline (black), 2 = fill.
                            (Class 3 is reserved; the RTL synthesizes the
                            translucent BACKING for class-0 pixels of an
                            active text cell itself.)
  tools/hud_font_preview.png -- glyph sheet (8 x 8 glyphs, 4x scale) for eyeball
                            verification. Deterministic output; both artifacts
                            are committed.

Glyph index map (keep in sync with transport_hud.sv's GLYPH_* localparams):
  0..9   '0'..'9'
  10 ':'   11 '/'   12 '.'   13 '-'   14 ' ' (space, active/backing)
  15 'x' (multiplier cross)
  16..41 'A'..'Z'
  42 PLAY  (right triangle)   43 PAUSE (double bar)   44 REV (left triangle)
  45..62 spare (transparent)
  63 NONE (inactive cell: fully transparent, NO backing)

Text glyphs are drawn 6x12 ('#' = fill) and placed at (x=1, y=2) inside the
8x16 cell; a 1-px 8-neighbour dilation then forms the outline (clipped to the
cell). Icons are drawn full-cell 8x16. The HUD displays cells at 2x, so a cell
is 16x32 on screen.
"""

import os
import struct
import zlib

CELL_W, CELL_H = 8, 16
NGLYPH = 64

# ---------------------------------------------------------------------------
# 6x12 text glyphs ('#' = fill). Row 0 = top. All exactly 12 rows, width <= 6.
# ---------------------------------------------------------------------------
F = {}

F['0'] = """
.####.
#....#
#....#
#...##
#..#.#
#.#..#
##...#
#....#
#....#
#....#
#....#
.####.
"""

F['1'] = """
..##..
.###..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
.####.
"""

F['2'] = """
.####.
#....#
#....#
.....#
....##
...##.
..##..
.##...
##....
#.....
#.....
######
"""

F['3'] = """
.####.
#....#
.....#
.....#
....##
..###.
....##
.....#
.....#
#....#
#....#
.####.
"""

F['4'] = """
....##
...###
..#.##
.#..##
#...##
#...##
######
....##
....##
....##
....##
....##
"""

F['5'] = """
######
#.....
#.....
#.....
#####.
.....#
.....#
.....#
.....#
#....#
#....#
.####.
"""

F['6'] = """
.####.
#....#
#.....
#.....
#####.
##...#
#....#
#....#
#....#
#....#
#....#
.####.
"""

F['7'] = """
######
.....#
.....#
....#.
....#.
...#..
...#..
..#...
..#...
..#...
..#...
..#...
"""

F['8'] = """
.####.
#....#
#....#
#....#
.####.
#....#
#....#
#....#
#....#
#....#
#....#
.####.
"""

F['9'] = """
.####.
#....#
#....#
#....#
#....#
#...##
.###.#
.....#
.....#
.....#
#....#
.####.
"""

F[':'] = """
......
......
..##..
..##..
......
......
......
......
..##..
..##..
......
......
"""

F['/'] = """
.....#
.....#
....#.
....#.
...#..
...#..
..#...
..#...
.#....
.#....
#.....
#.....
"""

F['.'] = """
......
......
......
......
......
......
......
......
......
......
..##..
..##..
"""

F['-'] = """
......
......
......
......
......
#####.
#####.
......
......
......
......
......
"""

F[' '] = """
......
......
......
......
......
......
......
......
......
......
......
......
"""

F['x'] = """
......
......
......
#....#
##..##
.####.
..##..
.####.
##..##
#....#
......
......
"""

F['A'] = """
..##..
..##..
.#..#.
.#..#.
.#..#.
#....#
#....#
######
#....#
#....#
#....#
#....#
"""

F['B'] = """
#####.
#....#
#....#
#....#
#####.
#....#
#....#
#....#
#....#
#....#
#....#
#####.
"""

F['C'] = """
.####.
#....#
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#....#
.####.
"""

F['D'] = """
#####.
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#####.
"""

F['E'] = """
######
#.....
#.....
#.....
#####.
#.....
#.....
#.....
#.....
#.....
#.....
######
"""

F['F'] = """
######
#.....
#.....
#.....
#####.
#.....
#.....
#.....
#.....
#.....
#.....
#.....
"""

F['G'] = """
.####.
#....#
#.....
#.....
#.....
#..###
#....#
#....#
#....#
#....#
#....#
.####.
"""

F['H'] = """
#....#
#....#
#....#
#....#
######
#....#
#....#
#....#
#....#
#....#
#....#
#....#
"""

F['I'] = """
.####.
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
.####.
"""

F['J'] = """
..####
....#.
....#.
....#.
....#.
....#.
....#.
....#.
....#.
#...#.
#...#.
.###..
"""

F['K'] = """
#....#
#...#.
#..#..
#.#...
##....
##....
#.#...
#.#...
#..#..
#..#..
#...#.
#....#
"""

F['L'] = """
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#.....
#.....
######
"""

F['M'] = """
#....#
##..##
##..##
#.##.#
#.##.#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
"""

F['N'] = """
#....#
##...#
##...#
#.#..#
#.#..#
#..#.#
#..#.#
#...##
#...##
#....#
#....#
#....#
"""

F['O'] = """
.####.
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
.####.
"""

F['P'] = """
#####.
#....#
#....#
#....#
#....#
#####.
#.....
#.....
#.....
#.....
#.....
#.....
"""

F['Q'] = """
.####.
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#.#..#
#..#.#
#...#.
.###.#
"""

F['R'] = """
#####.
#....#
#....#
#....#
#####.
#.#...
#..#..
#..#..
#...#.
#...#.
#....#
#....#
"""

F['S'] = """
.####.
#....#
#.....
#.....
.##...
...##.
.....#
.....#
.....#
.....#
#....#
.####.
"""

F['T'] = """
######
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
"""

F['U'] = """
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
#....#
.####.
"""

F['V'] = """
#....#
#....#
#....#
#....#
#....#
.#..#.
.#..#.
.#..#.
.#..#.
..##..
..##..
..##..
"""

F['W'] = """
#....#
#....#
#....#
#....#
#....#
#....#
#.##.#
#.##.#
#.##.#
##..##
##..##
#....#
"""

F['X'] = """
#....#
#....#
.#..#.
.#..#.
..##..
..##..
..##..
..##..
.#..#.
.#..#.
#....#
#....#
"""

F['Y'] = """
#....#
#....#
.#..#.
.#..#.
..##..
..##..
..##..
..##..
..##..
..##..
..##..
..##..
"""

F['Z'] = """
######
.....#
.....#
....#.
...#..
...#..
..#...
..#...
.#....
#.....
#.....
######
"""

# ---------------------------------------------------------------------------
# Full-cell 8x16 icons.
# ---------------------------------------------------------------------------
ICONS = {}

ICONS['PLAY'] = """
........
........
##......
###.....
####....
#####...
######..
#######.
#######.
######..
#####...
####....
###.....
##......
........
........
"""

ICONS['PAUSE'] = """
........
........
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
.##..##.
........
........
"""

ICONS['REV'] = """
........
........
......##
.....###
....####
...#####
..######
.#######
.#######
..######
...#####
....####
.....###
......##
........
........
"""

GLYPH_ORDER = (
    [str(d) for d in range(10)] +
    [':', '/', '.', '-', ' ', 'x'] +
    [chr(ord('A') + i) for i in range(26)] +
    ['PLAY', 'PAUSE', 'REV']
)
assert len(GLYPH_ORDER) == 45


def parse_art(art, w, h):
    rows = [r for r in art.strip('\n').split('\n')]
    assert len(rows) == h, f"art has {len(rows)} rows, want {h}"
    grid = [[0] * w for _ in range(h)]
    for y, r in enumerate(rows):
        assert len(r) <= w, f"row {y} wider than {w}: {r!r}"
        for x, c in enumerate(r):
            if c == '#':
                grid[y][x] = 1
    return grid


def cell_bitmap(name):
    """8x16 grid of pixel classes 0/1/2 for one glyph."""
    fill = [[0] * CELL_W for _ in range(CELL_H)]
    if name in ICONS:
        g = parse_art(ICONS[name], CELL_W, CELL_H)
        for y in range(CELL_H):
            for x in range(CELL_W):
                fill[y][x] = g[y][x]
    else:
        g = parse_art(F[name], 6, 12)
        for y in range(12):
            for x in range(6):
                fill[y + 2][x + 1] = g[y][x]
    # outline = 8-neighbour dilation of fill, minus fill (clipped to the cell)
    cell = [[0] * CELL_W for _ in range(CELL_H)]
    for y in range(CELL_H):
        for x in range(CELL_W):
            if fill[y][x]:
                cell[y][x] = 2
                continue
            near = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < CELL_H and 0 <= xx < CELL_W and fill[yy][xx]:
                        near = True
            if near:
                cell[y][x] = 1
    return cell


def rom_words():
    """1024 16-bit words: {glyph[5:0], row[3:0]} -> 8 px x 2 bpp, MSB=left."""
    words = []
    for gi in range(NGLYPH):
        if gi < len(GLYPH_ORDER):
            cell = cell_bitmap(GLYPH_ORDER[gi])
        else:
            cell = [[0] * CELL_W for _ in range(CELL_H)]  # spare/NONE
        for y in range(CELL_H):
            w = 0
            for x in range(CELL_W):
                w = (w << 2) | cell[y][x]
            words.append(w)
    return words


def write_mem(path, words):
    with open(path, 'w') as f:
        f.write("// generated by tools/hud_font.py -- DO NOT EDIT\n")
        f.write("// addr = {glyph[5:0], row[3:0]}; 8 px x 2 bpp, MSB pair = left\n")
        for w in words:
            f.write(f"{w:04x}\n")


# ---- minimal PNG writer (stdlib only) -------------------------------------
def write_png(path, w, h, rgb_rows):
    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))
    raw = b''.join(b'\x00' + bytes(row) for row in rgb_rows)
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)


def preview(path, words, scale=4):
    """8x8 glyph sheet on a dark-blue backing so outline/fill both show."""
    cols, rows = 8, 8
    W, H = cols * CELL_W * scale, rows * CELL_H * scale
    CLASS_RGB = {0: (24, 32, 72), 1: (0, 0, 0), 2: (255, 255, 255)}
    img = [[CLASS_RGB[0]] * W for _ in range(H)]
    for gi in range(NGLYPH):
        gx, gy = (gi % cols) * CELL_W * scale, (gi // cols) * CELL_H * scale
        for y in range(CELL_H):
            wrd = words[gi * CELL_H + y]
            for x in range(CELL_W):
                cls = (wrd >> (2 * (CELL_W - 1 - x))) & 3
                for sy in range(scale):
                    for sx in range(scale):
                        img[gy + y * scale + sy][gx + x * scale + sx] = CLASS_RGB[cls]
    rgb_rows = [b''.join(bytes(p) for p in row) for row in img]
    write_png(path, W, H, rgb_rows)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    words = rom_words()
    mem = os.path.join(root, 'dvd', 'hud_font.mem')
    png = os.path.join(here, 'hud_font_preview.png')
    write_mem(mem, words)
    preview(png, words)
    print(f"wrote {mem} ({len(words)} words) and {png}")


if __name__ == '__main__':
    main()
