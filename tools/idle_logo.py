#!/usr/bin/env python3
"""idle_logo.py -- generate + convert the idle-screen bouncing-logo bitmap.

The core shows a bouncing logo (dvd/idle_logo.sv) while no disc image is
mounted. The logo ROM is 4 M10K, 2048 x 16-bit words, TWO banks:

  bank 0 (words    0..1023) = the BUILT-IN default -- up to 256 x 64 px,
                              1 bpp, 16 words/row, MSB = leftmost pixel.
  bank 1 (words 1024..2047) = the USER bitmap, streamed in at core load from
                              /media/fat/games/DVD/boot.rom over ioctl. The
                              write port is hard-gated to bank 1, so a
                              corrupt or truncated file can never touch the
                              default.

Word address = {bank, row[5:0], col[7:4]} -- pure concatenation in the RTL.
Each logo declares its display scale: 1x (native, crisp) or 2x (classic
chunky); the bounce box follows the displayed size.

Default artwork policy: ORIGINAL only. The oval-with-"DVD" mark belongs to
the DVD Format/Logo Licensing Corp. -- do not draw it or anything close.
The default here is the project's own mark: an optical-disc glyph plus a
plain "MiSTer DVD" wordmark (plain letterforms are descriptive, the oval
composition is the trademark).

Modes:
  (no args)                 regenerate dvd/idle_logo.mem +
                            tools/idle_logo_preview.png +
                            bench/dvd/idle_logo_user.hex (tb fixture)
  --png IN.png --out boot.rom [--fit] [--invert] [--colour RRGGBB]
                            [--speed SX,SY]
                            convert a PNG to the user boot.rom format
                            (stdlib-only reader: non-interlaced, bit depth
                            1/8, grey/RGB/RGBA/palette; all 5 row filters)
  --verify boot.rom         decode a boot.rom back and ASCII-preview it

PNG conversion TRIMS the image to its lit bounding box by default (blank
margins make the bounce fire early on that side); --no-trim keeps them.

boot.rom byte layout (16-byte header + 16 bytes per row):
  0..3   magic "MDL1"
  4      width_px   1..128
  5      height_px  1..32
  6      format     0x00 = 1 bpp packed, MSB-first, fixed 16-byte stride
  7      flags      bit0 = use fixed colour (else the RTL cycles a palette)
  8..10  R, G, B    fixed colour
  11     speed      [3:0] = x, [7:4] = y, in 1/16 px per frame; 0 = default
  12..15 reserved (write 0)
  16..   height_px rows x 16 bytes; art narrower than 128 px is left-packed,
         the tool zero-pads the remainder (the RTL bounce box uses width_px)
"""

import os
import struct
import sys
import zlib

LOGO_W, LOGO_H = 256, 64     # mask geometry (4 M10K, upgraded from 128x32)
STRIDE = 32                  # fmt-1 bytes per row (256 px / 8)
STRIDE0 = 16                 # legacy fmt-0 stride (128 px / 8)
MAGIC = b'MDL1'
HDR_LEN = 16

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# ---------------------------------------------------------------------------
# default artwork
# ---------------------------------------------------------------------------
# 5x7 letterforms for the wordmark (subset; '#' = set). Row 0 = top.
L = {}
L['M'] = """
#...#
##.##
#.#.#
#.#.#
#...#
#...#
#...#
"""
L['i'] = """
..#..
.....
.##..
..#..
..#..
..#..
.###.
"""
L['S'] = """
.####
#....
#....
.###.
....#
....#
####.
"""
L['T'] = """
#####
..#..
..#..
..#..
..#..
..#..
..#..
"""
L['e'] = """
.....
.....
.###.
#...#
#####
#....
.###.
"""
L['r'] = """
.....
.....
#.##.
##..#
#....
#....
#....
"""
L['D'] = """
####.
#...#
#...#
#...#
#...#
#...#
####.
"""
L['V'] = """
#...#
#...#
#...#
#...#
.#.#.
.#.#.
..#..
"""
L[' '] = """
.....
.....
.....
.....
.....
.....
.....
"""


def parse_art(art, w, h):
    rows = art.strip('\n').split('\n')
    assert len(rows) == h, f"art has {len(rows)} rows, want {h}"
    grid = [[0] * w for _ in range(h)]
    for y, r in enumerate(rows):
        assert len(r) <= w, f"row {y} wider than {w}: {r!r}"
        for x, c in enumerate(r):
            if c == '#':
                grid[y][x] = 1
    return grid


def draw_text(g, text, x0, y0):
    """5x7 letterforms at 2x (10x14 px each, 12/10 px advance). Kept for the
    tb fixture; the default wordmark uses draw_text2's native glyphs."""
    for ch in text:
        art = parse_art(L[ch], 5, 7)
        for yy in range(7):
            for xx in range(5):
                if art[yy][xx]:
                    for sy in range(2):
                        for sx in range(2):
                            px, py = x0 + 2 * xx + sx, y0 + 2 * yy + sy
                            assert px < LOGO_W and py < LOGO_H, \
                                f"text {text!r} clips at ({px},{py})"
                            g[py][px] = 1
        x0 += 12 if ch != 'i' else 10


def draw_text2(g, text, x0, y0):
    """10x14 letterforms at 2x (20x28 px, 24/16 advance): the same displayed
    size as the old 5x7-doubled-twice wordmark, at twice its detail."""
    for ch in text:
        art = parse_art(L2[ch], 10, 14)
        for yy in range(14):
            for xx in range(10):
                if art[yy][xx]:
                    for sy in range(2):
                        for sx in range(2):
                            px, py = x0 + 2 * xx + sx, y0 + 2 * yy + sy
                            assert px < LOGO_W and py < LOGO_H, \
                                f"text {text!r} clips at ({px},{py})"
                            g[py][px] = 1
        x0 += 24 if ch != 'i' else 16


def default_grid():
    """Native-resolution (1x-displayed) default: optical-disc glyph + two-line
    wordmark, ~206x58 after trim -- the same on-screen size as the old
    103x29-at-2x default, at double the detail."""
    g = [[0] * LOGO_W for _ in range(LOGO_H)]

    # optical-disc glyph: annulus centred in a 64-px column -- outer r 28,
    # hub hole r 9, a 2-px data-groove ring gap at r ~19 so it reads as a
    # disc rather than a filled donut. At this radius the circle edge is
    # visibly smooth where the old r-14 one stair-stepped.
    import math
    cx, cy = 32.0, 31.5
    for y in range(LOGO_H):
        for x in range(64):
            r = math.hypot(x - cx, y - cy)
            if 9.0 <= r <= 28.0 and not (18.6 <= r <= 19.9):
                g[y][x] = 1

    # wordmark, two lines right of the disc (10x14 glyphs at 2x = 20x28):
    #   "MiSTer" rows 3..30, "DVD" rows 35..62, DVD centred under MiSTer.
    draw_text2(g, "MiSTer", 76, 3)
    w_mister = 5 * 24 + 16 - 4     # 5 wide letters + narrow i, minus trail
    w_dvd = 3 * 24 - 4
    draw_text2(g, "DVD", 76 + (w_mister - w_dvd) // 2, 35)
    return g


def fixture_grid():
    """64x16 tb-fixture pattern, deliberately DIFFERENT from the default:
    a border + diagonal + 'USR' block letters, so a frame compare can't
    confuse the two banks."""
    w, h = 64, 16
    g = [[0] * w for _ in range(h)]
    for x in range(w):
        g[0][x] = g[h - 1][x] = 1
    for y in range(h):
        g[y][0] = g[y][w - 1] = 1
        g[y][(y * 4) % w] = 1
    for i, ch in enumerate("USr"):   # reuse letterforms where they exist
        art = parse_art(L.get(ch, L['S']), 5, 7)
        for yy in range(7):
            for xx in range(5):
                if art[yy][xx]:
                    g[4 + yy][8 + i * 8 + xx] = 1
    return g


L['U'] = """
#...#
#...#
#...#
#...#
#...#
#...#
.###.
"""


# 10x14 letterforms for the NATIVE-resolution (1x) default wordmark -- same
# displayed size as the old 5x7-at-2x letters, but real curves instead of
# doubled pixels. Only the glyphs the default needs.
L2 = {}
L2['M'] = """
##......##
###....###
####..####
##.####.##
##..##..##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
##......##
"""
L2['i'] = """
....##....
....##....
..........
...###....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
...####...
..######..
"""
L2['S'] = """
..#######.
.##.....##
.##.......
.##.......
..##......
...####...
.....###..
.......##.
........##
........##
........##
.##.....##
..##...##.
...#####..
"""
L2['T'] = """
##########
##########
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
....##....
"""
L2['e'] = """
..........
..........
..........
...####...
..##..##..
.##....##.
.##....##.
.########.
.##.......
.##.......
.##.......
..##....#.
...######.
..........
"""
L2['r'] = """
..........
..........
..........
.##..###..
.##.##.##.
.####...#.
.###......
.##.......
.##.......
.##.......
.##.......
.##.......
.##.......
..........
"""
L2['D'] = """
########..
##....###.
##.....##.
##......##
##......##
##......##
##......##
##......##
##......##
##......##
##.....##.
##....###.
########..
..........
"""
L2['V'] = """
##......##
##......##
##......##
##......##
.##....##.
.##....##.
.##....##.
..##..##..
..##..##..
..##..##..
...####...
...####...
....##....
..........
"""


# ---------------------------------------------------------------------------
# packing
# ---------------------------------------------------------------------------
def trim_grid(grid):
    """Crop to the lit bounding box. The RTL bounce box is the DECLARED
    w x h, so any blank margin in the mask makes the logo bounce early on
    that side (HW round 2: the untrimmed default had a 22-column right
    margin = a 44 px early right bounce). Returns (grid, w, h); an all-blank
    grid comes back 1x1."""
    h = len(grid)
    w = len(grid[0]) if h else 0
    cols = [x for x in range(w) if any(grid[y][x] for y in range(h))]
    rows = [y for y in range(h) if any(grid[y][x] for x in range(w))]
    if not cols:
        return [[0]], 1, 1
    x0, x1, y0, y1 = min(cols), max(cols), min(rows), max(rows)
    out = [[grid[y][x] for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)]
    return out, x1 - x0 + 1, y1 - y0 + 1


def grid_to_words(grid):
    """One bank: 1024 16-bit words, 16 words/row, MSB = leftmost pixel.
    Grids narrower/shorter than 256x64 are zero-padded (left/top packed)."""
    words = []
    h = len(grid)
    w = len(grid[0]) if h else 0
    for y in range(LOGO_H):
        for wx in range(16):
            word = 0
            for b in range(16):
                x = wx * 16 + b
                bit = grid[y][x] if (y < h and x < w) else 0
                word = (word << 1) | bit
            words.append(word)
    return words


def grid_to_rows(grid, w, h):
    """fmt-1 boot.rom pixel rows: h rows x 32 bytes, MSB-first, left-packed."""
    out = bytearray()
    for y in range(h):
        row = 0
        for x in range(LOGO_W):
            bit = grid[y][x] if (y < len(grid) and x < w and x < len(grid[y])) else 0
            row = (row << 1) | bit
        out += row.to_bytes(STRIDE, 'big')
    return bytes(out)


def make_bootrom(grid, w, h, colour=None, speed=(0, 0), scale1x=False):
    """fmt-1 (format byte 0x01): 256x64-capable. width/height stored MINUS
    ONE (so 256/64 fit a byte); flags bit0 = fixed colour, bit1 = 1x display
    scale (else the logo is shown at 2x like fmt-0 always was)."""
    assert 1 <= w <= LOGO_W and 1 <= h <= LOGO_H
    flags = (1 if colour else 0) | (2 if scale1x else 0)
    r, g, b = colour if colour else (0, 0, 0)
    sx, sy = speed
    hdr = MAGIC + bytes([w - 1, h - 1, 0x01, flags, r, g, b,
                         ((sy & 0xF) << 4) | (sx & 0xF), 0, 0, 0, 0])
    assert len(hdr) == HDR_LEN
    return hdr + grid_to_rows(grid, w, h)


# ---------------------------------------------------------------------------
# writers
# ---------------------------------------------------------------------------
def write_mem(path, words):
    with open(path, 'w') as f:
        f.write("// generated by tools/idle_logo.py -- DO NOT EDIT\n")
        f.write("// 2048 x 16-bit, addr = {bank, row[5:0], col[7:4]}; MSB = left px.\n")
        f.write("// bank 0 = built-in default; bank 1 = its power-up copy (user-\n")
        f.write("// overwritable at runtime via boot.rom -> ioctl, bank-1-gated).\n")
        for w in words:
            f.write(f"{w:04x}\n")


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


def preview(path, grid, scale=4):
    W, H = LOGO_W * scale, LOGO_H * scale
    ON, OFF = (255, 255, 255), (24, 32, 72)
    img = []
    for y in range(LOGO_H):
        row = []
        for x in range(LOGO_W):
            on = y < len(grid) and x < len(grid[y]) and grid[y][x]
            row += [ON if on else OFF] * scale
        for _ in range(scale):
            img.append(row)
    rgb_rows = [b''.join(bytes(p) for p in row) for row in img]
    write_png(path, W, H, rgb_rows)


# ---------------------------------------------------------------------------
# stdlib PNG reader (non-interlaced; bit depth 1/8; grey/RGB/RGBA/palette)
# ---------------------------------------------------------------------------
def read_png(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f"{path}: not a PNG")
    pos, W = 8, None
    idat, plte, trns = b'', None, None
    while pos < len(data):
        (ln,) = struct.unpack('>I', data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if tag == b'IHDR':
            W, H, depth, ctype, comp, filt, ilace = struct.unpack('>IIBBBBB', body)
            if ilace:
                sys.exit(f"{path}: interlaced PNG unsupported -- re-export non-interlaced")
            if depth not in (1, 8):
                sys.exit(f"{path}: bit depth {depth} unsupported (want 1 or 8)")
            if ctype not in (0, 2, 3, 6):
                sys.exit(f"{path}: colour type {ctype} unsupported")
        elif tag == b'PLTE':
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif tag == b'tRNS':
            trns = body
        elif tag == b'IDAT':
            idat += body
        elif tag == b'IEND':
            break
    raw = zlib.decompress(idat)
    nch = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    bpp_bits = depth * nch
    stride = (W * bpp_bits + 7) // 8
    fbpp = max(1, bpp_bits // 8)          # filter byte distance
    rows, prev = [], bytearray(stride)
    p = 0
    for _ in range(H):
        ft = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ft == 1:
            for i in range(fbpp, stride):
                line[i] = (line[i] + line[i - fbpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - fbpp] if i >= fbpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - fbpp] if i >= fbpp else 0
                b = prev[i]
                c = prev[i - fbpp] if i >= fbpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            sys.exit(f"{path}: bad filter {ft}")
        rows.append(bytes(line))
        prev = line

    def px(x, y):
        """-> (r, g, b, a)"""
        row = rows[y]
        if depth == 1:
            bit = (row[x >> 3] >> (7 - (x & 7))) & 1
            if ctype == 3:
                r, g, b = plte[bit]
                a = trns[bit] if trns and bit < len(trns) else 255
                return r, g, b, a
            v = 255 * bit
            return v, v, v, 255
        i = x * nch
        if ctype == 0:
            v = row[i]; return v, v, v, 255
        if ctype == 2:
            return row[i], row[i + 1], row[i + 2], 255
        if ctype == 3:
            r, g, b = plte[row[i]]
            a = trns[row[i]] if trns and row[i] < len(trns) else 255
            return r, g, b, a
        return row[i], row[i + 1], row[i + 2], row[i + 3]

    return W, H, px


def png_to_grid(path, fit=False, invert=False):
    """PNG -> 1-bpp grid. Two fixes from HW round 4 (the old version point-
    sampled every Nth pixel and thresholded on luma>127, which turned a
    1920-wide colour logo into an all-blank grid -> a useless 1x1 rom):
      - "on" = differs from the BACKGROUND, not "is bright": alpha is the
        mask when the PNG really uses it, else colour distance from the
        median corner colour (so dark-on-light, colour-on-black etc. all
        work; --invert still flips the result);
      - --fit box-AVERAGES each cell (lit at >=30% coverage) instead of
        point-sampling, so thin strokes survive a 15x downscale."""
    W, H, px = read_png(path)
    if (W > LOGO_W or H > LOGO_H) and not fit:
        sys.exit(f"{path}: {W}x{H} exceeds {LOGO_W}x{LOGO_H} -- pass --fit to downscale")
    scale = max((W + LOGO_W - 1) // LOGO_W, (H + LOGO_H - 1) // LOGO_H)         if (fit and (W > LOGO_W or H > LOGO_H)) else 1
    w, h = (W + scale - 1) // scale, (H + scale - 1) // scale

    # background estimate: median of the four corner pixels; alpha counts as
    # "uses alpha" only if some pixel is actually transparent
    corners = [px(0, 0), px(W - 1, 0), px(0, H - 1), px(W - 1, H - 1)]
    br = sorted(c[0] for c in corners)[1]
    bg = sorted(c[1] for c in corners)[1]
    bb = sorted(c[2] for c in corners)[1]
    has_alpha = any(px(x, y)[3] < 128
                    for y in range(0, H, max(1, H // 16))
                    for x in range(0, W, max(1, W // 16)))

    def is_on(x, y):
        r, g, b, a = px(x, y)
        if has_alpha:
            return a > 127
        return max(abs(r - br), abs(g - bg), abs(b - bb)) > 64

    grid = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            x0s, y0s = x * scale, y * scale
            n_on = n_tot = 0
            for yy in range(y0s, min(y0s + scale, H)):
                for xx in range(x0s, min(x0s + scale, W)):
                    n_tot += 1
                    if is_on(xx, yy):
                        n_on += 1
            on = n_tot > 0 and (n_on * 10 >= n_tot * 3)   # >=30% coverage
            grid[y][x] = int(on ^ invert)
    return grid, w, h


# ---------------------------------------------------------------------------
# verify / preview text
# ---------------------------------------------------------------------------
def decode_bootrom(path):
    d = open(path, 'rb').read()
    if len(d) < HDR_LEN or d[:4] != MAGIC:
        sys.exit(f"{path}: bad magic (want MDL1)")
    fmt, flags = d[6], d[7]
    if fmt == 0:            # legacy 128x32, dims stored as-is, 16-byte stride
        w, h, stride, wbits = d[4], d[5], STRIDE0, 128
        if not (1 <= w <= 128) or not (1 <= h <= 32):
            sys.exit(f"{path}: bad fmt-0 header w={w} h={h}")
    elif fmt == 1:          # 256x64, dims stored minus one, 32-byte stride
        w, h, stride, wbits = d[4] + 1, d[5] + 1, STRIDE, 256
    else:
        sys.exit(f"{path}: unknown format {fmt}")
    want = HDR_LEN + stride * h
    if len(d) != want:
        sys.exit(f"{path}: length {len(d)}, want {want}")
    grid = [[0] * w for _ in range(h)]
    for y in range(h):
        row = int.from_bytes(d[HDR_LEN + y * stride:HDR_LEN + (y + 1) * stride], 'big')
        for x in range(w):
            grid[y][x] = (row >> (wbits - 1 - x)) & 1
    meta = dict(w=w, h=h, fmt=fmt, flags=flags, rgb=(d[8], d[9], d[10]),
                sx=d[11] & 0xF, sy=(d[11] >> 4) & 0xF,
                scale1x=bool(flags & 2) if fmt == 1 else False)
    return grid, meta


def ascii_preview(grid):
    for row in grid:
        print(''.join('#' if v else '.' for v in row))


# ---------------------------------------------------------------------------
def main():
    args = sys.argv[1:]

    def take(flag, val=True):
        if flag in args:
            i = args.index(flag)
            if val:
                v = args[i + 1]
                del args[i:i + 2]
                return v
            del args[i:i + 1]
            return True
        return None

    png_in = take('--png')
    out = take('--out')
    verify = take('--verify')
    fit = bool(take('--fit', val=False))
    invert = bool(take('--invert', val=False))
    notrim = bool(take('--no-trim', val=False))
    scale_arg = take('--scale')
    colour = take('--colour')
    speed = take('--speed')
    if args:
        sys.exit(f"unknown args: {args}")

    if verify:
        grid, meta = decode_bootrom(verify)
        print(f"{verify}: fmt{meta['fmt']} {meta['w']}x{meta['h']} "
              f"shown at {1 if meta['scale1x'] else 2}x "
              f"flags={meta['flags']} rgb={meta['rgb']} "
              f"speed=({meta['sx']},{meta['sy']})")
        ascii_preview(grid)
        return

    if png_in:
        if not out:
            sys.exit("--png needs --out boot.rom")
        grid, w, h = png_to_grid(png_in, fit=fit, invert=invert)
        if not notrim:
            grid, w, h = trim_grid(grid)   # margins would bounce early (--no-trim to keep)
        if w < 8 or h < 4:
            sys.exit(f"{png_in}: extraction produced only {w}x{h} lit pixels -- "
                     f"not writing a useless rom. The logo/background split "
                     f"probably failed: try --invert, or a PNG with a plain "
                     f"background or real transparency.")
        col = None
        if colour:
            v = int(colour, 16)
            col = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        spd = (0, 0)
        if speed:
            sx, sy = speed.split(',')
            spd = (int(sx), int(sy))
        # display scale: auto = 1x (native) when the art is bigger than the
        # old 128x32 canvas, else 2x (the classic chunky look); --scale 1|2
        # overrides.
        if scale_arg:
            scale1x = (scale_arg == '1')
        else:
            scale1x = (w > 128 or h > 32)
        blob = make_bootrom(grid, w, h, colour=col, speed=spd, scale1x=scale1x)
        with open(out, 'wb') as f:
            f.write(blob)
        # self-check: decode what we wrote and compare
        back, meta = decode_bootrom(out)
        assert meta['w'] == w and meta['h'] == h
        for y in range(h):
            for x in range(w):
                assert back[y][x] == grid[y][x], f"round-trip mismatch at {x},{y}"
        print(f"wrote {out}: {w}x{h} shown at {1 if scale1x else 2}x, "
              f"{len(blob)} bytes (round-trip verified)")
        return

    # default: regenerate the committed artifacts
    dgrid, dw, dh = trim_grid(default_grid())
    print(f"default art bounding box: {dw}x{dh} -- MUST equal idle_logo.sv's "
          f"power-up u_w/u_h (idle_logo_tb asserts this)")
    words = grid_to_words(dgrid)
    words = words + words[:]        # bank 1 = power-up copy of bank 0
    assert len(words) == 2048
    mem = os.path.join(ROOT, 'dvd', 'idle_logo.mem')
    png = os.path.join(HERE, 'idle_logo_preview.png')
    write_mem(mem, words)
    preview(png, dgrid)

    # tb fixture: a 64x16 user bitmap as boot.rom bytes, one hex byte/line
    fgrid = fixture_grid()
    blob = make_bootrom(fgrid, 64, 16, colour=(0xFF, 0xC8, 0x20), speed=(0, 0),
                        scale1x=False)   # fmt-1, classic 2x
    fx = os.path.join(ROOT, 'bench', 'dvd', 'idle_logo_user.hex')
    with open(fx, 'w') as f:
        f.write("// generated by tools/idle_logo.py -- boot.rom fixture, 64x16 'USr'\n")
        for b in blob:
            f.write(f"{b:02x}\n")
    print(f"wrote {mem} ({len(words)} words), {png}, {fx} ({len(blob)} bytes)")


if __name__ == '__main__':
    main()
