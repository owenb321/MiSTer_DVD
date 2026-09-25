#!/usr/bin/env python3
"""tmap_check.py -- is a disc's VTS time map (TMAP) good enough to seek by time?

For the title the core plays with Disc Menus Off (the largest VTS, its longest PGC --
dvd_iso_reader's Auto rule), this reads VTS_TMAPT (VTSI_MAT byte 0xD4) and checks it
against the DISC ITSELF: at sampled entries it reads the NAV pack the entry points at
and compares that VOBU's authored whole-title time (the PGC's cell-start prefix sum +
the DSI's c_eltm) with the time the entry claims, (k+1) * tmu.

Layout (libdvdread ifo_types.h, libdvdnav searching.c):
  VTS_TMAPT: nr_of_tmaps u16, zero u16, last_byte u32, tmap_offset u32[nr] (from TMAPT)
  VTS_TMAP : tmu u8 (seconds), zero u8, nr_of_entries u16, map_ent u32[nr]
             entry k = VTS title-VOBS sector of the VOBU at time (k+1)*tmu;
             bit 31 = discontinuity. One TMAP per title PGC (index = PGCN-1).

    tools/tmap_check.py <iso> [...]          # one line per disc
    tools/tmap_check.py --json <iso> [...]

issue #127 (docs/transport_hud.md): the reopened Phase 8b, time-based seeking.
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav  # noqa: E402

SAMPLES = int(os.environ.get('TMAP_SAMPLES', '24'))


def bcd(b):
    return (b >> 4) * 10 + (b & 0xF)


def dvd_time(b4):
    """dvd_time_t -> seconds (float). Frame byte: rate in [7:6] (01 = 25 fps, else 30)."""
    fps = 25.0 if (b4[3] >> 6) == 1 else 29.97
    return bcd(b4[0]) * 3600 + bcd(b4[1]) * 60 + bcd(b4[2]) + bcd(b4[3] & 0x3F) / fps


def check(path):
    nav = IsoNav(path)
    vts = nav.best_vts
    ifo = nav.vts_ifo[vts]
    mat = nav.sec(ifo)
    pgcit_ptr = struct.unpack('>I', mat[204:208])[0]
    tmapt_ptr = struct.unpack('>I', mat[212:216])[0]
    out = {'disc': os.path.basename(path), 'vts': vts, 'tmapt': tmapt_ptr}
    pit = (ifo + pgcit_ptr) * 2048
    nr_srp = struct.unpack('>H', nav.rd(pit, 2))[0]
    # the longest PGC (the core's Auto rule)
    best = None
    for i in range(nr_srp):
        off = struct.unpack('>I', nav.rd(pit + 8 + i * 8 + 4, 4))[0]
        hdr = nav.rd(pit + off, 0xEC)
        secs = dvd_time(hdr[4:8])
        if best is None or secs > best[1]:
            best = (i + 1, secs, pit + off, hdr)
    pgcn, pgc_secs, pgc_abs, hdr = best
    out.update(pgcn=pgcn, pgc_secs=round(pgc_secs, 1))
    if tmapt_ptr == 0:
        out['verdict'] = 'NO_TMAPT'
        return out
    t_abs = (ifo + tmapt_ptr) * 2048
    nr_tmaps = struct.unpack('>H', nav.rd(t_abs, 2))[0]
    out['nr_tmaps'] = nr_tmaps
    if pgcn > nr_tmaps:
        out['verdict'] = 'NO_TMAP_FOR_PGC'
        return out
    toff = struct.unpack('>I', nav.rd(t_abs + 8 + (pgcn - 1) * 4, 4))[0]
    tm = t_abs + toff
    tmu, _, nent = struct.unpack('>BBH', nav.rd(tm, 4))
    out.update(tmu=tmu, entries=nent, map_secs=nent * tmu)
    if tmu == 0 or nent == 0:
        out['verdict'] = 'EMPTY_TMAP'
        return out
    ents = struct.unpack('>%dI' % nent, nav.rd(tm + 4, 4 * nent))
    out['disc_bits'] = sum(1 for e in ents if e & 0x80000000)
    mono = all((ents[i] & 0x7FFFFFFF) <= (ents[i + 1] & 0x7FFFFFFF) for i in range(nent - 1))
    out['monotonic'] = mono

    # the PGC's cells: title time of each cell's start, and (vob_id, cell_id) -> start
    ncell = hdr[3]
    cpb = struct.unpack('>H', hdr[0xE8:0xEA])[0]
    cpo = struct.unpack('>H', hdr[0xEA:0xEC])[0]
    starts, t = {}, 0.0
    cells = []
    for c in range(ncell):
        cb = nav.rd(pgc_abs + cpb + c * 24, 24)
        pos = nav.rd(pgc_abs + cpo + c * 4, 4)
        vob_id, cell_id = struct.unpack('>H', pos[0:2])[0], pos[3]
        blk_type, blk_mode = (cb[0] >> 4) & 3, (cb[0] >> 6) & 3
        dur = dvd_time(cb[4:8])
        sibling = (blk_type == 1 and blk_mode >= 2)     # an angle, not new time
        starts.setdefault((vob_id, cell_id), t if not sibling else cells[-1][1])
        cells.append(((vob_id, cell_id), t if not sibling else cells[-1][1]))
        if not sibling:
            t += dur
    out['cells'] = ncell

    vobs_lba = sorted(nav.groups[vts])[0][0]
    idxs = sorted(set(int(i * (nent - 1) / max(1, SAMPLES - 1)) for i in range(SAMPLES)))
    errs, bad = [], 0
    for k in idxs:
        s = ents[k] & 0x7FFFFFFF
        sec = nav.sec(vobs_lba + s)
        if not (sec[0:4] == b'\x00\x00\x01\xba' and sec[0x400:0x404] == b'\x00\x00\x01\xbf'):
            bad += 1
            continue
        vob_id = struct.unpack('>H', sec[0x407 + 0x18:0x407 + 0x1A])[0]
        c_id = sec[0x407 + 0x1B]
        key = (vob_id, c_id)
        if key not in starts:
            bad += 1
            continue
        actual = starts[key] + dvd_time(sec[0x407 + 0x1C:0x407 + 0x20])
        errs.append(round(actual - (k + 1) * tmu, 2))
    out['samples'] = len(idxs)
    out['not_nav'] = bad
    if errs:
        out['err_min'], out['err_max'] = min(errs), max(errs)
        out['err_abs_max'] = max(abs(e) for e in errs)
    # verdict: an entry should sit within one VOBU (~0.5-1 s) of its claimed time
    if bad:
        out['verdict'] = 'BAD_POINTERS'
    elif not errs:
        out['verdict'] = 'UNCHECKED'
    elif out['err_abs_max'] <= 1.1:
        out['verdict'] = 'GOOD'
    elif max(errs) - min(errs) <= 1.1:
        out['verdict'] = 'OFFSET'      # consistent shift (e.g. an unseekable lead-in cell)
    else:
        out['verdict'] = 'DRIFT'
    return out


def main():
    args = sys.argv[1:]
    as_json = False
    if args and args[0] == '--json':
        as_json, args = True, args[1:]
    for p in args:
        try:
            r = check(p)
        except Exception as e:  # noqa: BLE001 -- a sweep must survive odd images
            r = {'disc': os.path.basename(p), 'verdict': 'ERROR', 'error': str(e)[:80]}
        if as_json:
            print(json.dumps(r), flush=True)
        else:
            print('%-44s %-15s tmu=%-3s ent=%-5s map=%-6s pgc=%-7s disc=%-3s err=[%s..%s] notnav=%s' % (
                r['disc'][:44], r['verdict'], r.get('tmu'), r.get('entries'), r.get('map_secs'),
                r.get('pgc_secs'), r.get('disc_bits'), r.get('err_min'), r.get('err_max'),
                r.get('not_nav')), flush=True)


if __name__ == '__main__':
    main()
