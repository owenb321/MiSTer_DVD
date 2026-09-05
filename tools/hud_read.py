#!/usr/bin/env python3
"""
hud_read.py -- decode the DVD core's on-screen state from a SCREENSHOT.

This is the readback half of the hardware-in-the-loop harness
(docs/hil_harness.md). MiSTer's `screenshot` command writes the CORE's raw
raster -- it is read from ascal's INPUT buffer (sys/sys_top.v:680), while the
MiSTer OSD is composited AFTER ascal (sys_top.v:1149) -- so a shot contains the
core's own compositing and nothing else: no OSD, no Info popups, no shadowmask,
no scaler filtering, at native 720x480 (or 720x576 PAL).

That makes the transport HUD exactly machine-readable.  dvd/transport_hud.sv
draws from a 64-glyph ROM (dvd/hud_font.mem) at fixed coordinates, and the
glyph classes are OPAQUE (alpha 15, transport_hud.sv:612-627), so there is no
calibration, no affine fit and no blending ambiguity -- unlike tools/osd_read.py,
which decodes a capture-card recording and needs both.

Two readouts:

  read   -- the transport HUD: icon, elapsed/total time, chapter, popup line.
            With the core's O[2] "Debug Overlay" On, hud_dbg (dvd/emu.sv:1283)
            forces the status line always-visible and repurposes the "CH n/N"
            field as {reader PGCN, VTS} -- so a shot carries playback state
            from frame one, with no keypress, in a RELEASE build.

  blocks -- the O[2] diagnostic blocks that survive in a release build
            (dvd/emu.sv:5156-5219): 13 named green/red booleans plus the VBUF
            fill bar, whose WIDTH is the 8-bit fill value.

            Blocks are GATED: 1-8 need `menus_on`, 9-13 need `interlaced_eff`.
            A gated-off block is reported as "not shown", NEVER as red --
            conflating "false" with "not displayed" is exactly the misreading
            that has cost this project hardware rounds.

Usage:
    hud_read.py read   <image> [--json] [--tol N] [--dbg]
    hud_read.py blocks <image> [--json] [--tol N]
    hud_read.py selftest

`image` is a .png (via PIL, else ffmpeg) or a .ppm (P3/P6, parsed natively).
`selftest` decodes the committed golden frame bench/dvd/hud_frame.ppm, which
bench/dvd/hud_frame_tb.sv renders from the REAL transport_hud + subpic_blend --
so the decoder is verified against the same RTL that draws the pixels, with no
hardware.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# Reuse the generator's glyph order rather than duplicating it: hud_font.py is
# the file that DEFINES which index is which character, and it guards main().
from hud_font import GLYPH_ORDER, NGLYPH, CELL_W, CELL_H   # noqa: E402

FONT_MEM = os.path.join(ROOT, 'dvd', 'hud_font.mem')
GOLDEN   = os.path.join(ROOT, 'bench', 'dvd', 'hud_frame.ppm')
# A real 720x480 screenshot's bottom 112 rows (popup + seek bar + status),
# captured off the board. The shipped build draws the HUD 14 px LEFT of the
# nominal X0 -- close enough to the 16 px cell pitch that a grid one cell over
# also fits every glyph exactly. This fixture locks that case.
REAL_BAND = os.path.join(ROOT, 'bench', 'dvd', 'hud_real_band.png')
REAL_BAND_H = 112          # crop height; status row top sits at 112-64
REAL_BAND_XOFF = -14       # measured on hardware, build DVD_holdparity_20260904

# ---- layout, from dvd/transport_hud.sv:137-145 -----------------------------
X0     = 104          # (720 - 32*16)/2
NCELL  = 32
CELLW  = 16           # 8 px glyph at 2x
ROW_H  = 32           # 16 glyph rows at 2x
STATUS_DY = -64       # status row top    = active_h - 64
POPUP_DY  = -112      # popup  row top    = active_h - 112

# Glyph pixel classes (transport_hud.sv:612-627). Only class 2 (fill) has an
# unambiguous colour; 1 (outline) and 0 (backing) are black at different alpha
# and become indistinguishable over a dark picture. So matching uses the FILL
# MASK ALONE -- the outline is a dilation of the fill, so the fill IS the shape.
FILL_WHITE  = (255, 255, 255)
FILL_ACCENT = (255, 200, 32)

# A real HUD row matches exactly; anything above this is picture content
# being mistaken for glyphs, not a HUD.
MAXERR_OK = 4

ICONS = {'PLAY': 42, 'PAUSE': 43, 'REV': 44}
ICON_NAME = {42: 'PLAY', 43: 'PAUSE', 44: 'REV'}


# ---------------------------------------------------------------------------
# image loading
# ---------------------------------------------------------------------------
def _load_ppm(path):
    """P3 (ASCII) or P6 (binary) PPM -> (w, h, bytes RGB)."""
    with open(path, 'rb') as f:
        blob = f.read()
    if not blob.startswith(b'P3') and not blob.startswith(b'P6'):
        raise ValueError(f'{path}: not a P3/P6 PPM')
    magic = blob[:2]
    # header: magic, width, height, maxval -- comments (#...) allowed between
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(blob) and blob[pos:pos + 1].isspace():
            pos += 1
        if blob[pos:pos + 1] == b'#':
            while pos < len(blob) and blob[pos:pos + 1] != b'\n':
                pos += 1
            continue
        start = pos
        while pos < len(blob) and not blob[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(blob[start:pos]))
    w, h, _maxval = fields
    if magic == b'P6':
        pos += 1                      # exactly one whitespace byte after maxval
        return w, h, blob[pos:pos + w * h * 3]
    vals = re.findall(rb'\d+', blob[pos:])
    return w, h, bytes(int(v) for v in vals[:w * h * 3])


def load_image(path):
    """-> (w, h, bytes RGB). PPM natively; anything else via PIL, then ffmpeg."""
    if path.lower().endswith(('.ppm', '.pnm')):
        return _load_ppm(path)
    try:
        from PIL import Image
        with Image.open(path) as im:
            im = im.convert('RGB')
            return im.width, im.height, im.tobytes()
    except ImportError:
        pass
    # ffmpeg fallback -- already a dependency of tools/osd_read.py
    probe = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
         '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', path],
        capture_output=True, text=True, check=True).stdout.strip()
    w, h = (int(v) for v in probe.split('x')[:2])
    raw = subprocess.run(
        ['ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo',
         '-pix_fmt', 'rgb24', '-'],
        capture_output=True, check=True).stdout
    return w, h, raw[:w * h * 3]


class Frame:
    def __init__(self, w, h, buf):
        self.w, self.h, self.buf = w, h, buf

    def px(self, x, y):
        if x < 0 or y < 0 or x >= self.w or y >= self.h:
            return (0, 0, 0)
        i = (y * self.w + x) * 3
        return (self.buf[i], self.buf[i + 1], self.buf[i + 2])


# ---------------------------------------------------------------------------
# font ROM
# ---------------------------------------------------------------------------
def load_font(path=FONT_MEM):
    """dvd/hud_font.mem -> [glyph][row] = list of 8 class values (0..3).

    addr = {glyph[5:0], row[3:0]}; each word is 8 px x 2 bpp, MSB pair = left.
    """
    words = []
    with open(path) as f:
        for line in f:
            line = line.split('//')[0].strip()
            if line:
                words.append(int(line, 16))
    want = NGLYPH * CELL_H
    if len(words) != want:
        raise ValueError(f'{path}: {len(words)} words, expected {want}')
    font = []
    for g in range(NGLYPH):
        rows = []
        for r in range(CELL_H):
            word = words[g * CELL_H + r]
            rows.append([(word >> ((CELL_W - 1 - k) * 2)) & 3 for k in range(CELL_W)])
        font.append(rows)
    return font


def fill_masks(font):
    """Per glyph, the class-2 (fill) mask as a tuple of CELL_H ints."""
    masks = []
    for g in range(NGLYPH):
        rows = []
        for r in range(CELL_H):
            bits = 0
            for k in range(CELL_W):
                if font[g][r][k] == 2:
                    bits |= 1 << k
            rows.append(bits)
        masks.append(tuple(rows))
    return masks


# ---------------------------------------------------------------------------
# decode
# ---------------------------------------------------------------------------
def _is_fill(rgb, tol):
    for ref in (FILL_WHITE, FILL_ACCENT):
        if all(abs(a - b) <= tol for a, b in zip(rgb, ref)):
            return True, ref is FILL_ACCENT
    return False, False


def _sample_row(frame, y_top, xoff, yoff, tol):
    """-> ([per-cell fill mask], [per-cell accent flag])."""
    cells, accents = [], []
    for c in range(NCELL):
        rows, acc_n, fill_n = [], 0, 0
        for gy in range(CELL_H):
            bits = 0
            for gx in range(CELL_W):
                x = X0 + xoff + c * CELLW + gx * 2
                y = y_top + yoff + gy * 2
                is_f, is_acc = _is_fill(frame.px(x, y), tol)
                if is_f:
                    bits |= 1 << gx
                    fill_n += 1
                    if is_acc:
                        acc_n += 1
            rows.append(bits)
        cells.append(tuple(rows))
        accents.append(fill_n > 0 and acc_n * 2 > fill_n)
    return cells, accents


def _match(cell, masks):
    """-> (glyph index, hamming distance)."""
    best, best_d = 63, 10 ** 9
    for g in range(NGLYPH):
        d = sum(bin(cell[r] ^ masks[g][r]).count('1') for r in range(CELL_H))
        if d < best_d:
            best, best_d = g, d
    return best, best_d


def _glyph_char(g):
    if g < len(GLYPH_ORDER):
        name = GLYPH_ORDER[g]
        return f'[{name}]' if len(name) > 1 else name
    return ' '


def decode_row(frame, y_top, masks, tol=8, xrange=24, yrange=2, hint=None):
    """Decode one 32-cell text row, auto-aligning x/y.

    The alignment search exists because HUD_QX_ADJ (a pipeline lead) differs
    between the testbench (4) and emu.sv (5), and a real capture may sit a
    pixel either way. The shift is constant across a row, so one search fixes
    the whole line.
    """
    def attempt(xoff, yoff):
        cells, accents = _sample_row(frame, y_top, xoff, yoff, tol)
        res = [_match(c, masks) for c in cells]
        glyphs = [g for g, _ in res]
        # Cells carrying actual information. Used to break ties -- see below.
        content = sum(1 for g in glyphs if g not in (14, 63))
        return {'total': sum(d for _, d in res), 'content': content,
                'xoff': xoff, 'yoff': yoff, 'glyphs': glyphs,
                'dist': [d for _, d in res], 'accent': accents}

    # The offset is constant for a given build+capture path, so a caller that
    # has already aligned one row passes it as a hint. A perfect match ends the
    # search immediately -- which is the normal case on a real screenshot,
    # because the pixels are digital-exact.
    order = [hint] if hint else []
    order += [(x, y) for y in range(-yrange, yrange + 1)
              for x in range(-xrange, xrange + 1)]
    best = None
    for xoff, yoff in order:
        cand = attempt(xoff, yoff)
        # MEASURED on hardware: this build's HUD sits ~15 px left of the nominal
        # X0, which is close enough to the 16 px cell pitch that a grid one cell
        # to the right ALSO matches every glyph exactly -- it just shifts the
        # leading icon off the left edge. So a perfect fit is NOT sufficient to
        # stop, and among equally-perfect fits the right one is the one that
        # decodes the MOST content. (A search that ended at the first zero-error
        # hit read a real '[PLAY] 0:01:56/...' as '    0:01:56/...'.)
        # Rank: fewest mismatched pixels, then most content decoded, then
        # closest to the nominal geometry. The last term matters because two
        # alignments a whole cell apart can tie on BOTH of the first two (the
        # same glyphs, shifted, with a blank falling off either end) -- without
        # it the winner is just whichever the loop reached first.
        key = (cand['total'], -cand['content'], abs(cand['xoff']), abs(cand['yoff']))
        if best is None or key < best['_key']:
            cand['_key'] = key
            best = cand
    best['text'] = ''.join(_glyph_char(g) for g in best['glyphs'])
    best['maxerr'] = max(best['dist'])
    # Is a HUD actually on screen? The fill class is digital-exact, so a genuine
    # row matches with zero error; bright PICTURE content in the HUD band can
    # otherwise be matched to plausible-looking glyphs (a real capture with no
    # HUD decoded as '[REV]' at maxerr 44). Require both an exact fit AND some
    # content -- an all-space row is a hidden HUD, not a reading.
    best['present'] = best['maxerr'] <= MAXERR_OK and best['content'] > 0
    return best


def decode(frame, tol=8):
    active_h = frame.h
    masks = fill_masks(load_font())
    status = decode_row(frame, active_h + STATUS_DY, masks, tol)
    popup = decode_row(frame, active_h + POPUP_DY, masks, tol,
                       hint=(status['xoff'], status['yoff']))
    out = {
        'width': frame.w, 'height': frame.h,
        'standard': 'PAL' if active_h >= 576 else 'NTSC',
        'status': {'text': status['text'], 'maxerr': status['maxerr'],
                   'xoff': status['xoff'], 'yoff': status['yoff'],
                   'present': status['present']},
        'popup': {'text': popup['text'], 'maxerr': popup['maxerr'],
                  'xoff': popup['xoff'], 'yoff': popup['yoff'],
                  'present': popup['present']},
        'hud_visible': status['present'] or popup['present'],
    }
    out.update(parse_status(status) if status['present'] else
               {'icon': None, 'elapsed': None, 'total': None,
                'chapter': None, 'chapters': None})
    out['popup_text'] = popup['text'].strip() if popup['present'] else None
    return out


def parse_status(status):
    """Pull the structured fields out of the decoded status line.

    Layout (transport_hud.sv:8-16): '[icon] H:MM:SS/H:MM:SS CH n/N'.
    Times are BCD on the core side, so digits map straight to glyph indices --
    the decode is a lookup, not an OCR guess.
    """
    text = status['text']
    fields = {'icon': None, 'elapsed': None, 'total': None,
              'chapter': None, 'chapters': None}
    for g in status['glyphs'][:2]:
        if g in ICON_NAME:
            fields['icon'] = ICON_NAME[g]
            break
    times = re.findall(r'\d:\d\d:\d\d', text)
    if len(times) >= 1:
        fields['elapsed'] = times[0]
    if len(times) >= 2:
        fields['total'] = times[1]
    m = re.search(r'CH\s*(\d+)\s*/\s*(\d+)', text)
    if m:
        # With O[2] on, hud_dbg repurposes this field as {reader PGCN, VTS}
        # (dvd/emu.sv:4953-4954) -- same glyphs, different meaning, so the
        # caller decides. We report both readings rather than guessing.
        fields['chapter'] = int(m.group(1))
        fields['chapters'] = int(m.group(2))
        fields['dbg_pgcn'] = int(m.group(1))
        fields['dbg_vts'] = int(m.group(2))
    return fields


# ---------------------------------------------------------------------------
# O[2] release-build diagnostic blocks (dvd/emu.sv:5156-5219)
# ---------------------------------------------------------------------------
# name, x0, x1, y0, y1, gate
BLOCKS = [
    ('hl_btns_armed', 8, 24, 8, 24, 'menus_on'),
    ('video_live', 28, 44, 8, 24, 'menus_on'),
    ('subpic_shown', 48, 64, 8, 24, 'menus_on'),
    ('spu_bytes_seen', 68, 84, 8, 24, 'menus_on'),
    ('vbuf_deep', 8, 24, 30, 46, 'menus_on'),
    ('still_active', 28, 44, 30, 46, 'menus_on'),
    ('hl_on', 48, 64, 30, 46, 'menus_on'),
    ('hl_recolour_fired', 68, 84, 30, 46, 'menus_on'),
    ('watchdog_fired', 8, 24, 62, 78, 'interlaced'),
    ('il_switch_fired', 28, 44, 62, 78, 'interlaced'),
    ('pal_changed', 48, 64, 62, 78, 'interlaced'),
    ('vsize_zero', 68, 84, 62, 78, 'interlaced'),
    ('cfg_rewritten', 88, 104, 62, 78, 'interlaced'),
]
VBAR_Y0, VBAR_Y1, VBAR_X0 = 50, 58, 8


def read_blocks(frame, tol=8):
    """Decode the O[2] blocks. Green = true, red = false, absent = not shown.

    dbg_px_q is REGISTERED (emu.sv:5280), so the painted blocks sit ~1 px right
    of the coordinates above; sampling each block's centre absorbs that.
    """
    out = {}
    for name, x0, x1, y0, y1, gate in BLOCKS:
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        r, g, b = frame.px(cx, cy)
        if g > 128 and r <= tol and b <= tol:
            out[name] = {'value': True, 'gate': gate}
        elif r > 128 and g <= tol and b <= tol:
            out[name] = {'value': False, 'gate': gate}
        else:
            # NOT the same as False: the gate is off, so nothing was drawn.
            out[name] = {'value': None, 'gate': gate, 'shown': False}
    # VBUF bar: width IS the 8-bit fill value (emu.sv:5219).
    y = (VBAR_Y0 + VBAR_Y1) // 2
    width = 0
    for x in range(VBAR_X0, min(VBAR_X0 + 256, frame.w)):
        r, g, b = frame.px(x, y)
        if not (r > 128 or g > 128):
            break
        width += 1
    out['vbuf_fill'] = width if width else None
    return out


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------
EXPECT_STATUS = '[PLAY]    0:12:34/1:37:05 CH 12/23   '
EXPECT_POPUP = 'AUDIO  2/ 4 FR                  '


def selftest():
    """Decode the committed golden frame and assert the exact strings.

    bench/dvd/hud_frame_tb.sv renders bench/dvd/hud_frame.ppm from the REAL
    transport_hud + subpic_blend, so this checks the decoder against the same
    RTL that draws the pixels. The noise arm proves the fill-mask approach is
    independent of whatever picture sits behind the HUD -- the real reason to
    match on fill alone rather than on all three glyph classes.
    """
    fails = 0
    w, h, buf = load_image(GOLDEN)
    frame = Frame(w, h, buf)
    res = decode(frame)
    print(f'[golden] {GOLDEN} {w}x{h}')
    for key, want in (('status', EXPECT_STATUS), ('popup', EXPECT_POPUP)):
        got = res[key]['text']
        err = res[key]['maxerr']
        ok = (got == want) and err == 0
        print(f"  {'PASS' if ok else 'FAIL'} {key:6s} maxerr={err} "
              f"xoff={res[key]['xoff']} yoff={res[key]['yoff']} {got!r}")
        if not ok:
            print(f'       expected {want!r}')
            fails += 1
    for key, want in (('elapsed', '0:12:34'), ('total', '1:37:05'),
                      ('icon', 'PLAY'), ('chapter', 12), ('chapters', 23)):
        ok = res.get(key) == want
        print(f"  {'PASS' if ok else 'FAIL'} field {key} = {res.get(key)!r}")
        if not ok:
            fails += 1

    # Background independence: the HUD's fill class is opaque, so re-decoding
    # over pseudo-random picture content must give the identical result.
    import random
    rnd = random.Random(1234)
    noisy = bytearray(buf)
    for i in range(0, len(noisy), 3):
        y, x = divmod(i // 3, w)
        r, g, b = buf[i], buf[i + 1], buf[i + 2]
        if (r, g, b) == (96, 96, 96):            # the tb's flat background
            noisy[i] = rnd.randrange(256)
            noisy[i + 1] = rnd.randrange(256)
            noisy[i + 2] = rnd.randrange(256)
    res2 = decode(Frame(w, h, bytes(noisy)))
    for key in ('status', 'popup'):
        ok = res2[key]['text'] == res[key]['text']
        print(f"  {'PASS' if ok else 'FAIL'} noise-bg {key} stable")
        if not ok:
            print(f"       {res2[key]['text']!r}")
            fails += 1

    # --- real hardware geometry -------------------------------------------
    # The golden frame is rendered by the testbench at the NOMINAL X0. Only a
    # real screenshot exercises the cell-pitch aliasing, so this arm is what
    # actually guards the alignment tie-break.
    if os.path.exists(REAL_BAND):
        w2, h2, buf2 = load_image(REAL_BAND)
        masks = fill_masks(load_font())
        row = decode_row(Frame(w2, h2, buf2), REAL_BAND_H + STATUS_DY, masks)
        print(f'[real] {os.path.basename(REAL_BAND)} {w2}x{h2}')
        checks = [
            ('present', row['present'], True),
            ('xoff', row['xoff'], REAL_BAND_XOFF),
            ('maxerr', row['maxerr'], 0),
            ('icon kept', row['text'].startswith('[PLAY]'), True),
            ('time', '0:01:24/0:09:59' in row['text'], True),
        ]
        for name, got, want in checks:
            ok = got == want
            print(f"  {'PASS' if ok else 'FAIL'} {name}: {got!r}")
            if not ok:
                fails += 1
                print(f'       expected {want!r}  (text {row["text"]!r})')
    else:
        print(f'[real] SKIP -- {REAL_BAND} not present')

    print('hud_read selftest:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
    return 1 if fails else 0


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('read', 'blocks'):
        p = sub.add_parser(name)
        p.add_argument('image')
        p.add_argument('--json', action='store_true')
        p.add_argument('--tol', type=int, default=8,
                       help='per-channel colour tolerance (default 8)')
    sub.add_parser('selftest')
    args = ap.parse_args()

    if args.cmd == 'selftest':
        return selftest()

    w, h, buf = load_image(args.image)
    frame = Frame(w, h, buf)
    if args.cmd == 'read':
        res = decode(frame, args.tol)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"{res['standard']} {w}x{h}  hud_visible={res['hud_visible']}")
            for key in ('status', 'popup'):
                r = res[key]
                if r['present']:
                    print(f"  {key:6s}: {r['text']!r} (maxerr {r['maxerr']}, "
                          f"xoff {r['xoff']})")
                else:
                    print(f"  {key:6s}: -- not on screen -- "
                          f"(best fit maxerr {r['maxerr']})")
            if res['status']['present']:
                print(f"  icon={res['icon']} elapsed={res['elapsed']} "
                      f"total={res['total']} ch={res['chapter']}/{res['chapters']}")
    else:
        res = read_blocks(frame, args.tol)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            for name, _, _, _, _, _ in BLOCKS:
                v = res[name]['value']
                state = 'not shown' if v is None else ('GREEN' if v else 'red')
                print(f'  {name:20s} {state}')
            print(f"  vbuf_fill            {res['vbuf_fill']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
