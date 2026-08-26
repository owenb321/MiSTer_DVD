#!/usr/bin/env python3
"""idle_logo.py -- generate + convert the idle-screen bouncing-logo bitmap.

The core shows a bouncing logo (dvd/idle_logo.sv) while no disc image is
mounted. The logo ROM is one M10K, 512 x 16-bit words, TWO banks:

  bank 0 (words   0..255) = the BUILT-IN default -- 128 x 32 px, 1 bpp,
                            8 words/row (fixed stride), MSB = leftmost pixel.
  bank 1 (words 256..511) = the USER bitmap, streamed in at core load from
                            /media/fat/games/DVD/boot.rom over ioctl. The
                            write port is hard-gated to bank 1, so a corrupt
                            or truncated file can never touch the default.

Word address = {bank, row[4:0], col[6:4]} -- pure concatenation in the RTL.

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

LOGO_W, LOGO_H = 128, 32
STRIDE = 16                  # bytes per row, always (128 px / 8)
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
    """5x7 letterforms at 2x (10x14 px each, 12/10 px advance)."""
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


def default_grid():
    """128x32 1-bpp default: optical-disc glyph + two-line wordmark."""
    g = [[0] * LOGO_W for _ in range(LOGO_H)]

    # optical-disc glyph: clean annulus centred in a 32-px column -- outer
    # r 14, hub hole r 4.5, plus a 1-px data-groove ring gap at r ~9.5 so it
    # reads as a disc rather than a filled donut.
    import math
    cx, cy = 16.0, 15.5
    for y in range(LOGO_H):
        for x in range(32):
            r = math.hypot(x - cx, y - cy)
            if 4.5 <= r <= 14.0 and not (9.2 <= r <= 9.9):
                g[y][x] = 1

    # wordmark, two lines right of the disc:
    #   "MiSTer"  (6 letters, 70 px)  rows  2..15
    #   "DVD"     (3 letters, 34 px)  rows 17..30, centred under it
    draw_text(g, "MiSTer", 38, 2)
    draw_text(g, "DVD", 38 + (70 - 34) // 2, 17)
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


# ---------------------------------------------------------------------------
# packing
# ---------------------------------------------------------------------------
def grid_to_words(grid):
    """One bank: 256 16-bit words, 8 words/row, MSB = leftmost pixel.
    Grids narrower/shorter than 128x32 are zero-padded (left/top packed)."""
    words = []
    h = len(grid)
    w = len(grid[0]) if h else 0
    for y in range(LOGO_H):
        for wx in range(8):
            word = 0
            for b in range(16):
                x = wx * 16 + b
                bit = grid[y][x] if (y < h and x < w) else 0
                word = (word << 1) | bit
            words.append(word)
    return words


def grid_to_rows(grid, w, h):
    """boot.rom pixel rows: h rows x 16 bytes, MSB-first, left-packed."""
    out = bytearray()
    for y in range(h):
        row = 0
        for x in range(LOGO_W):
            bit = grid[y][x] if (y < len(grid) and x < w and x < len(grid[y])) else 0
            row = (row << 1) | bit
        out += row.to_bytes(STRIDE, 'big')
    return bytes(out)


def make_bootrom(grid, w, h, colour=None, speed=(0, 0)):
    flags = 1 if colour else 0
    r, g, b = colour if colour else (0, 0, 0)
    sx, sy = speed
    hdr = MAGIC + bytes([w & 0xFF if w < 256 else 0, h, 0x00, flags, r, g, b,
                         ((sy & 0xF) << 4) | (sx & 0xF), 0, 0, 0, 0])
    assert len(hdr) == HDR_LEN
    return hdr + grid_to_rows(grid, w, h)


# ---------------------------------------------------------------------------
# writers
# ---------------------------------------------------------------------------
def write_mem(path, words):
    with open(path, 'w') as f:
        f.write("// generated by tools/idle_logo.py -- DO NOT EDIT\n")
        f.write("// 512 x 16-bit, addr = {bank, row[4:0], col[6:4]}; MSB = left px.\n")
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
    W, H, px = read_png(path)
    if (W > LOGO_W or H > LOGO_H) and not fit:
        sys.exit(f"{path}: {W}x{H} exceeds {LOGO_W}x{LOGO_H} -- pass --fit to downscale")
    if fit and (W > LOGO_W or H > LOGO_H):
        scale = max((W + LOGO_W - 1) // LOGO_W, (H + LOGO_H - 1) // LOGO_H)
    else:
        scale = 1
    w, h = (W + scale - 1) // scale, (H + scale - 1) // scale
    grid = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            r, g, b, a = px(min(x * scale, W - 1), min(y * scale, H - 1))
            luma = (54 * r + 183 * g + 19 * b) >> 8
            on = (a > 127) and (luma > 127)
            grid[y][x] = int(on ^ invert)
    return grid, w, h


# ---------------------------------------------------------------------------
# verify / preview text
# ---------------------------------------------------------------------------
def decode_bootrom(path):
    d = open(path, 'rb').read()
    if len(d) < HDR_LEN or d[:4] != MAGIC:
        sys.exit(f"{path}: bad magic (want MDL1)")
    w, h, fmt, flags = d[4], d[5], d[6], d[7]
    if not (1 <= w <= LOGO_W) or not (1 <= h <= LOGO_H) or fmt != 0:
        sys.exit(f"{path}: bad header w={w} h={h} fmt={fmt}")
    want = HDR_LEN + STRIDE * h
    if len(d) != want:
        sys.exit(f"{path}: length {len(d)}, want {want}")
    grid = [[0] * w for _ in range(h)]
    for y in range(h):
        row = int.from_bytes(d[HDR_LEN + y * STRIDE:HDR_LEN + (y + 1) * STRIDE], 'big')
        for x in range(w):
            grid[y][x] = (row >> (LOGO_W - 1 - x)) & 1
    meta = dict(w=w, h=h, flags=flags, rgb=(d[8], d[9], d[10]),
                sx=d[11] & 0xF, sy=(d[11] >> 4) & 0xF)
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
    colour = take('--colour')
    speed = take('--speed')
    if args:
        sys.exit(f"unknown args: {args}")

    if verify:
        grid, meta = decode_bootrom(verify)
        print(f"{verify}: {meta['w']}x{meta['h']} flags={meta['flags']} "
              f"rgb={meta['rgb']} speed=({meta['sx']},{meta['sy']})")
        ascii_preview(grid)
        return

    if png_in:
        if not out:
            sys.exit("--png needs --out boot.rom")
        grid, w, h = png_to_grid(png_in, fit=fit, invert=invert)
        col = None
        if colour:
            v = int(colour, 16)
            col = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
        spd = (0, 0)
        if speed:
            sx, sy = speed.split(',')
            spd = (int(sx), int(sy))
        blob = make_bootrom(grid, w, h, colour=col, speed=spd)
        with open(out, 'wb') as f:
            f.write(blob)
        # self-check: decode what we wrote and compare
        back, meta = decode_bootrom(out)
        assert meta['w'] == w and meta['h'] == h
        for y in range(h):
            for x in range(w):
                assert back[y][x] == grid[y][x], f"round-trip mismatch at {x},{y}"
        print(f"wrote {out}: {w}x{h}, {len(blob)} bytes (round-trip verified)")
        return

    # default: regenerate the committed artifacts
    dgrid = default_grid()
    words = grid_to_words(dgrid)
    words = words + words[:]        # bank 1 = power-up copy of bank 0
    assert len(words) == 512
    mem = os.path.join(ROOT, 'dvd', 'idle_logo.mem')
    png = os.path.join(HERE, 'idle_logo_preview.png')
    write_mem(mem, words)
    preview(png, dgrid)

    # tb fixture: a 64x16 user bitmap as boot.rom bytes, one hex byte/line
    fgrid = fixture_grid()
    blob = make_bootrom(fgrid, 64, 16, colour=(0xFF, 0xC8, 0x20), speed=(0, 0))
    fx = os.path.join(ROOT, 'bench', 'dvd', 'idle_logo_user.hex')
    with open(fx, 'w') as f:
        f.write("// generated by tools/idle_logo.py -- boot.rom fixture, 64x16 'USr'\n")
        for b in blob:
            f.write(f"{b:02x}\n")
    print(f"wrote {mem} (512 words), {png}, {fx} ({len(blob)} bytes)")


if __name__ == '__main__':
    main()
