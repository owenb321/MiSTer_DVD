#!/usr/bin/env python3
"""spu_ref.py — DVD Subpicture (SPU) extractor + golden reference decoder.

Two jobs, used to drive the RTL testbench (dvd/spu_decode.sv):

  extract:  walk a DVD Program Stream (.VOB), pull private_stream_1 substream
            0x20-0x3F PES payloads, concatenate them into SPU units by the SPU's
            own SPDSZ length field, and dump one unit's raw bytes (+ its PTS).

  decode:   parse an SPU (header + DCSQ command sequence + nibble RLE) into a
            2-bpp bitmap and the parsed control fields — the golden model the
            testbench checks dvd/spu_decode.sv against.

This is the same SPU/DCSQ format documented in docs/subpicture.md, cross-checked
against the ffmpeg dvdsubdec / VLC spudec algorithms.

Usage:
  tools/spu_ref.py extract VOB [--sub 0x20] [--unit 0] [--out base]
  tools/spu_ref.py decode  SPU.bin [--pts N] [--pgm out.pgm] [--dump]
"""
import sys, argparse

# ---------------------------------------------------------------------------
# Program-Stream extraction
# ---------------------------------------------------------------------------
def parse_pts(b):
    # 5 bytes -> 33-bit PTS, per the MPEG-2 PES layout (same bit map as ps_demux.sv)
    return (((b[0] >> 1) & 0x7) << 30) | (b[1] << 22) | (((b[2] >> 1) & 0x7F) << 15) \
           | (b[3] << 7) | ((b[4] >> 1) & 0x7F)

def iter_subpic_pes(data, want_sub):
    """Yield (payload_bytes, pts_or_None) for each private_stream_1 (0xBD) PES
    whose substream_id == want_sub, parsing the PS sequentially (fast: jumps by
    length)."""
    i, n = 0, len(data)
    while i + 6 < n:
        # find next start code 00 00 01
        if not (data[i] == 0 and data[i+1] == 0 and data[i+2] == 1):
            i += 1
            continue
        sid = data[i+3]
        if sid == 0xBA:                      # pack header
            # 14 bytes fixed, then stuffing (low 3 bits of byte 13)
            if i + 14 > n: break
            stuff = data[i+13] & 0x7
            i += 14 + stuff
            continue
        if sid == 0xB9:                      # program end
            break
        if sid in (0xBB,) or sid < 0xB9:     # system header / misc: has a length
            length = (data[i+4] << 8) | data[i+5]
            i += 6 + length
            continue
        # PES packet with a 2-byte length
        length = (data[i+4] << 8) | data[i+5]
        pes = data[i+6 : i+6+length]
        i += 6 + length
        if sid != 0xBD:
            continue
        if len(pes) < 3:
            continue
        pts = None
        if (pes[0] & 0xC0) == 0x80:          # MPEG-2 PES
            pts_flag = pes[1] >> 6
            hdr_len = pes[2]
            hdr = pes[3:3+hdr_len]
            if pts_flag & 0x2 and len(hdr) >= 5:
                pts = parse_pts(hdr[0:5])
            payload = pes[3+hdr_len:]
        else:
            payload = pes                     # MPEG-1 style (unlikely on DVD)
        if not payload:
            continue
        substream = payload[0]
        if substream != want_sub:
            continue
        yield payload[1:], pts               # strip substream_id (no sub-header)

def extract_unit(data, want_sub, want_index):
    """Assemble SPU units by SPDSZ; return (spu_bytes, pts) for the want_index'th."""
    unit = bytearray()
    unit_pts = None
    spdsz = None
    idx = 0
    for payload, pts in iter_subpic_pes(data, want_sub):
        if len(unit) == 0:
            unit_pts = pts                    # first PES of a unit carries the PTS
        unit += payload
        if spdsz is None and len(unit) >= 2:
            spdsz = (unit[0] << 8) | unit[1]
        if spdsz is not None and len(unit) >= spdsz:
            if idx == want_index:
                return bytes(unit[:spdsz]), unit_pts
            idx += 1
            unit = bytearray()
            unit_pts = None
            spdsz = None
    raise RuntimeError(f"no complete SPU unit #{want_index} for substream 0x{want_sub:02X}")

# ---------------------------------------------------------------------------
# SPU decode (golden model)
# ---------------------------------------------------------------------------
class NibbleReader:
    def __init__(self, data, byte_off):
        self.data = data
        self.pos = byte_off      # byte index
        self.hi = True           # next nibble is high?
    def get(self):
        b = self.data[self.pos]
        if self.hi:
            self.hi = False
            return (b >> 4) & 0xF
        else:
            self.hi = True
            self.pos += 1
            return b & 0xF
    def align(self):
        # byte-align at end of line: if we consumed only the high nibble, skip the low
        if not self.hi:
            self.hi = True
            self.pos += 1

def decode_field(data, off, width, nlines):
    """Decode one RLE field into nlines rows of `width` colour indices."""
    r = NibbleReader(data, off)
    rows = []
    for _ in range(nlines):
        line = [0] * width
        x = 0
        while x < width:
            v = r.get()
            if v < 0x4:
                v = (v << 4) | r.get()
                if v < 0x10:
                    v = (v << 4) | r.get()
                    if v < 0x40:
                        v = (v << 4) | r.get()
            run = v >> 2
            color = v & 3
            if run == 0:
                run = width - x           # fill to end of line
            run = min(run, width - x)
            for k in range(run):
                line[x+k] = color
            x += run
        r.align()
        rows.append(line)
    return rows, r.pos

def decode_spu(data, pts=0):
    spdsz = (data[0] << 8) | data[1]
    dcsqt_sa = (data[2] << 8) | data[3]
    out = dict(spdsz=spdsz, dcsqt_sa=dcsqt_sa, contrast=[0,0,0,0], palette=[0,0,0,0],
               darea=None, dspxa=None, show_tick=None, hide_tick=None, dcsqs=[])
    # walk DCSQ table
    off = dcsqt_sa
    guard = 0
    while True:
        guard += 1
        if guard > 32 or off + 4 > len(data):
            break
        delay = (data[off] << 8) | data[off+1]
        nxt = (data[off+2] << 8) | data[off+3]
        p = off + 4
        cmds = []
        while p < len(data):
            op = data[p]; p += 1
            if op == 0xFF:
                break
            elif op == 0x00:   # FSTA_DSP (forced start) — treat like STA for v1
                cmds.append(('FSTA_DSP',))
                out['show_tick'] = pts + (delay << 10)
            elif op == 0x01:   # STA_DSP
                cmds.append(('STA_DSP',))
                out['show_tick'] = pts + (delay << 10)
            elif op == 0x02:   # STP_DSP
                cmds.append(('STP_DSP',))
                out['hide_tick'] = pts + (delay << 10)
            elif op == 0x03:   # SET_COLOR — 2 bytes, nibbles [c3][c2][c1][c0]
                # Same nibble layout as SET_CONTR below: byte0=(c3<<4)|c2,
                # byte1=(c1<<4)|c0. Stored as [c0,c1,c2,c3] to match SET_CONTR's
                # [a0,a1,a2,a3] and dvd/spu_decode.sv. (Earlier this did NOT reverse
                # the nibbles — a latent bug that never surfaced because nothing
                # consumed the palette output until Phase-1 real colours.)
                c3 = (data[p] >> 4) & 0xF; c2 = data[p] & 0xF
                c1 = (data[p+1] >> 4) & 0xF; c0 = data[p+1] & 0xF
                pal = [c0, c1, c2, c3]
                out['palette'] = pal; cmds.append(('SET_COLOR', pal)); p += 2
            elif op == 0x04:   # SET_CONTR (alpha) — 2 bytes, 4 nibbles idx3..idx0
                a3 = (data[p] >> 4) & 0xF; a2 = data[p] & 0xF
                a1 = (data[p+1] >> 4) & 0xF; a0 = data[p+1] & 0xF
                out['contrast'] = [a0, a1, a2, a3]
                cmds.append(('SET_CONTR', [a0,a1,a2,a3])); p += 2
            elif op == 0x05:   # SET_DAREA — 6 bytes
                sx = (data[p] << 4) | (data[p+1] >> 4)
                ex = ((data[p+1] & 0xF) << 8) | data[p+2]
                sy = (data[p+3] << 4) | (data[p+4] >> 4)
                ey = ((data[p+4] & 0xF) << 8) | data[p+5]
                out['darea'] = (sx, ex, sy, ey)
                cmds.append(('SET_DAREA', (sx,ex,sy,ey))); p += 6
            elif op == 0x06:   # SET_DSPXA — 4 bytes: top, bottom field offsets
                top = (data[p] << 8) | data[p+1]
                bot = (data[p+2] << 8) | data[p+3]
                out['dspxa'] = (top, bot)
                cmds.append(('SET_DSPXA', (top,bot))); p += 4
            elif op == 0x07:   # CHG_COLCON — variable (2-byte length prefix) — skip
                ln = (data[p] << 8) | data[p+1]
                cmds.append(('CHG_COLCON', ln)); p += ln
            else:
                cmds.append(('UNKNOWN', op)); break
        out['dcsqs'].append(dict(delay=delay, next=nxt, off=off, cmds=cmds))
        if nxt == off or nxt == 0:
            break
        off = nxt
    # RLE decode into a DAREA-sized bitmap
    if out['darea'] and out['dspxa']:
        sx, ex, sy, ey = out['darea']
        width = ex - sx + 1
        height = ey - sy + 1
        top_off, bot_off = out['dspxa']
        ntop = (height + 1) // 2
        nbot = height // 2
        top_rows, _ = decode_field(data, top_off, width, ntop)
        bot_rows, _ = decode_field(data, bot_off, width, nbot)
        bmp = [[0]*width for _ in range(height)]
        for i, row in enumerate(top_rows):
            if 2*i < height: bmp[2*i] = row
        for i, row in enumerate(bot_rows):
            if 2*i+1 < height: bmp[2*i+1] = row
        out['width'] = width; out['height'] = height; out['bitmap'] = bmp
    return out

def idx_at(dec, X, Y):
    """Colour index at absolute screen (X,Y): DAREA-relative bitmap or 0 (transparent)."""
    if not dec.get('darea'): return 0
    sx, ex, sy, ey = dec['darea']
    if X < sx or X > ex or Y < sy or Y > ey: return 0
    return dec['bitmap'][Y - sy][X - sx]

def write_pgm(dec, path):
    if 'bitmap' not in dec: return
    lut = [0, 255, 128, 64]   # visualise idx0..3
    w, h = dec['width'], dec['height']
    with open(path, 'wb') as f:
        f.write(f"P5\n{w} {h}\n255\n".encode())
        for row in dec['bitmap']:
            f.write(bytes(lut[c] for c in row))

# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    e = sub.add_parser('extract')
    e.add_argument('vob'); e.add_argument('--sub', default='0x20')
    e.add_argument('--unit', type=int, default=0); e.add_argument('--out', default='spu')
    d = sub.add_parser('decode')
    d.add_argument('spu'); d.add_argument('--pts', type=int, default=0)
    d.add_argument('--pgm', default=None); d.add_argument('--dump', action='store_true')
    d.add_argument('--memh', default=None, help="write DAREA bitmap as $readmemh (1 idx/line, raster order)")
    d.add_argument('--params', default=None, help="write parsed fields as key=value for the SV tb")
    a = ap.parse_args()

    if a.cmd == 'extract':
        want = int(a.sub, 0)
        data = open(a.vob, 'rb').read()
        spu, pts = extract_unit(data, want, a.unit)
        open(a.out + '.bin', 'wb').write(spu)
        open(a.out + '.pts', 'w').write(str(pts if pts is not None else 0) + '\n')
        print(f"extracted SPU unit #{a.unit} sub=0x{want:02X}: {len(spu)} bytes, pts={pts}")
        dec = decode_spu(spu, pts or 0)
        print(f"  SPDSZ={dec['spdsz']} DCSQT_SA={dec['dcsqt_sa']} DAREA={dec['darea']} "
              f"DSPXA={dec['dspxa']} contrast={dec['contrast']} show={dec['show_tick']} hide={dec['hide_tick']}")
    else:
        data = open(a.spu, 'rb').read()
        dec = decode_spu(data, a.pts)
        print(f"SPDSZ={dec['spdsz']} DCSQT_SA={dec['dcsqt_sa']}")
        print(f"DAREA={dec['darea']} DSPXA={dec['dspxa']} contrast(a0..a3)={dec['contrast']} "
              f"palette={dec['palette']}")
        print(f"show_tick={dec['show_tick']} hide_tick={dec['hide_tick']}")
        for q in dec['dcsqs']:
            print(f"  DCSQ off={q['off']} delay={q['delay']} next={q['next']} "
                  f"cmds={[c[0] for c in q['cmds']]}")
        if 'bitmap' in dec:
            print(f"bitmap {dec['width']}x{dec['height']}")
        if a.pgm: write_pgm(dec, a.pgm); print(f"wrote {a.pgm}")
        if a.memh and 'bitmap' in dec:
            with open(a.memh, 'w') as f:
                for row in dec['bitmap']:
                    for c in row:
                        f.write(f"{c:x}\n")
            print(f"wrote {a.memh} ({dec['width']*dec['height']} entries)")
        if a.params:
            sx, ex, sy, ey = dec['darea']
            top, bot = dec['dspxa']
            a0, a1, a2, a3 = dec['contrast']
            with open(a.params, 'w') as f:
                f.write(f"spdsz={dec['spdsz']}\ndcsqt_sa={dec['dcsqt_sa']}\n")
                f.write(f"sx={sx}\nex={ex}\nsy={sy}\ney={ey}\nwidth={dec['width']}\nheight={dec['height']}\n")
                f.write(f"top_off={top}\nbot_off={bot}\n")
                f.write(f"a0={a0}\na1={a1}\na2={a2}\na3={a3}\n")
                f.write(f"pts={a.pts}\nshow_tick={dec['show_tick']}\nhide_tick={dec['hide_tick']}\n")
            print(f"wrote {a.params}")

if __name__ == '__main__':
    main()
