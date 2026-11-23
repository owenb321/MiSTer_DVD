#!/usr/bin/env python3
"""trick_scan.py - library sweep for trick play (docs/trick_play.md).

Trick play reads only each VOBU's first reference picture ([nv_pck .. nv_pck +
vobu_1stref_ea]) and jumps by the DSI's VOBU_SRI table (fwda/bwda). This sweep measures
the premises that design rests on, per disc, on the main feature (the title VTS with the
most title-VOB sectors):

  - 1stref_ea: how many sectors one I-frame read costs (and how often it is 0 = no video)
  - the first picture of the VOBU: its coding type (I?) and structure (frame / field pair)
  - whether the first reference picture is COMPLETE inside the range, and what follows it
    in the cut sector (the start of the next picture = what the ES filter must drop)
  - fwda/bwda validity per table index, and END_OF_CELL rates (where a jump must fall back)
  - the ILVU (angle / seamless-branch) share of VOBUs

The walk samples VOBUs by chasing fwda at STEP seconds (default 10 s), which is itself a
trick-play walk. A disc field is a claim an authoring tool wrote: the ES parse checks
1stref_ea against the bitstream rather than trusting it.

  tools/trick_scan.py <disc.iso>...                 # one line per disc
  tools/trick_scan.py --library DIR --limit 150 --jobs 8 --json out.json
"""
import argparse, json, os, random, struct, sys
from collections import Counter
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nav_extract import walk_dir, be32, is_nav_pack, STIME, sri_offset  # noqa: E402

SEC = 2048
DSI = 0x407                     # DSI data start inside a NAV sector
DSI_ILVU_BLOCK = 1 << 14


def title_extents(f):
    """{vts: [(lba, len_bytes), ...]} for VTS_xx_1..9.VOB."""
    f.seek(16 * SEC)
    pvd = f.read(SEC)
    if pvd[1:6] != b'CD001':
        raise ValueError('not ISO9660')
    root = walk_dir(f, struct.unpack('<I', pvd[158:162])[0],
                    struct.unpack('<I', pvd[166:170])[0])
    vdir = [(e, d) for n, e, d in root if n.startswith(b'VIDEO_TS')]
    if not vdir:
        raise ValueError('no VIDEO_TS')
    out = {}
    for n, e, d in walk_dir(f, *vdir[0]):
        if n.startswith(b'VTS_') and n[6:7] == b'_' and n[7:8] in b'123456789' and b'.VOB' in n:
            out.setdefault(int(n[4:6]), []).append((e, d))
    return out


def video_es(buf):
    """Concatenate the payload of every video PES (stream 0xE0) in a run of packs."""
    es = bytearray()
    for s in range(len(buf) // SEC):
        p = s * SEC
        sec = buf[p:p + SEC]
        if sec[0:4] != b'\x00\x00\x01\xba':
            continue
        q = 14 + (sec[13] & 7)
        while q + 6 <= SEC and sec[q:q + 3] == b'\x00\x00\x01':
            sid = sec[q + 3]
            ln = struct.unpack('>H', sec[q + 4:q + 6])[0]
            if sid == 0xE0:
                hl = sec[q + 8]
                es += sec[q + 9 + hl:q + 6 + ln]
            q += 6 + ln
    return bytes(es)


def pictures(es):
    """[(offset, coding_type, structure)] for each picture header in an ES chunk."""
    pics, i = [], 0
    while True:
        i = es.find(b'\x00\x00\x01', i)
        if i < 0 or i + 6 > len(es):
            return pics
        code = es[i + 3]
        if code == 0x00:
            pics.append([i, (es[i + 5] >> 3) & 7, None])
        elif code == 0xB5 and pics and pics[-1][2] is None and (es[i + 4] >> 4) == 8:
            if i + 7 <= len(es):
                pics[-1][2] = es[i + 6] & 3     # picture_structure
        i += 3


def first_ref(es):
    """Classify the first reference frame of a VOBU's ES.
    Returns (kind, n_ref_pics, tail) where tail = what follows the reference frame inside
    the range: 'none' (range ends at it), 'next_pic' (a later picture header starts)."""
    pics = pictures(es)
    if not pics:
        return 'no_pic', 0, 'none'
    t0, s0 = pics[0][1], pics[0][2]
    kind = {1: 'I', 2: 'P', 3: 'B'}.get(t0, 'type%d' % t0)
    n = 1
    if s0 in (1, 2):                     # field picture: the frame is two fields
        kind += '_field'
        if len(pics) >= 2 and pics[1][2] in (1, 2) and pics[1][2] != s0:
            n = 2
            kind += ('+' + {1: 'I', 2: 'P', 3: 'B'}.get(pics[1][1], '?'))
        else:
            kind += '+missing'
    elif s0 == 3:
        kind += '_frame'
    else:
        kind += '_mpeg1?'
    tail = 'next_pic' if len(pics) > n else 'none'
    return kind, n, tail


def scan(path, step_s=10.0, max_vobus=400):
    fi = STIME.index(int(step_s * 2))
    r = {'iso': os.path.basename(path)}
    try:
        with open(path, 'rb') as f:
            ext = title_extents(f)
            if not ext:
                r['err'] = 'no title VOBs'
                return r
            vts = max(ext, key=lambda v: sum(d for _, d in ext[v]))
            lo = min(e for e, _ in ext[vts])
            hi = max(e + (d + SEC - 1) // SEC for e, d in ext[vts])
            r['vts'] = vts
            sizes, kinds, tails = [], Counter(), Counter()
            fw_ok, bw_ok = Counter(), Counter()
            n = ilvu = zero = bad = 0
            pos = lo
            while lo <= pos < hi and n < max_vobus:
                f.seek(pos * SEC)
                nav = f.read(SEC)
                if not is_nav_pack(nav):
                    bad += 1
                    pos += 1             # resync forward one sector
                    if bad > 2000:
                        break
                    continue
                d = nav[DSI:]
                n += 1
                cat = struct.unpack('>H', d[0x20:0x22])[0]
                if cat & DSI_ILVU_BLOCK:
                    ilvu += 1
                ref = be32(d, 0x0C)
                for i in range(19):
                    ok, _ = sri_offset(be32(d, 0xEE + i * 4))
                    fw_ok[i] += ok
                    ok, _ = sri_offset(be32(d, 0x142 + i * 4))
                    bw_ok[i] += ok
                if ref == 0:
                    zero += 1
                else:
                    sizes.append(ref)
                    f.seek(pos * SEC)
                    kind, _, tail = first_ref(video_es(f.read((ref + 1) * SEC)))
                    kinds[kind] += 1
                    tails[tail] += 1
                ok, off = sri_offset(be32(d, 0xEE + fi * 4))
                if ok and off:
                    pos += off
                else:                    # END_OF_CELL at this rung: next VOBU
                    nx = be32(d, 0x13A)
                    ok2, o2 = sri_offset(nx)
                    pos += o2 if ok2 and o2 else be32(d, 0x08) + 1
            sizes.sort()
            q = lambda p: sizes[min(len(sizes) - 1, int(p * len(sizes)))] if sizes else None
            r.update(vobus=n, ilvu=ilvu, ref0=zero, resync=bad,
                     ref_p50=q(.5), ref_p95=q(.95), ref_max=sizes[-1] if sizes else None,
                     kinds=dict(kinds), tails=dict(tails),
                     fwda_ok=[fw_ok[i] for i in range(19)],
                     bwda_ok=[bw_ok[i] for i in range(19)])
    except Exception as e:      # a damaged image is a row, not a crash
        r['err'] = '%s: %s' % (type(e).__name__, e)
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('isos', nargs='*')
    ap.add_argument('--library', default=os.environ.get('DVD_ISO_DIR'))
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--step', type=float, default=10.0, help='walk step in seconds (fwda rung)')
    ap.add_argument('--json')
    a = ap.parse_args()
    isos = list(a.isos)
    if not isos and a.library:
        isos = sorted(os.path.join(a.library, x) for x in os.listdir(a.library)
                      if x.lower().endswith('.iso'))
        if a.limit:
            random.Random(a.seed).shuffle(isos)
            isos = isos[:a.limit]
    if not isos:
        ap.error('no images (pass paths or --library / $DVD_ISO_DIR)')
    with Pool(a.jobs) as p:
        rows = p.starmap(scan, [(x, a.step) for x in isos])
    for r in rows:
        if 'err' in r:
            print('%-48s ERR %s' % (r['iso'][:48], r['err']))
        else:
            print('%-48s vts%-2d vobus %4d ref p50/p95/max %s/%s/%s ref0 %d ilvu %d %s %s'
                  % (r['iso'][:48], r['vts'], r['vobus'], r['ref_p50'], r['ref_p95'],
                     r['ref_max'], r['ref0'], r['ilvu'], r['kinds'], r['tails']))
    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=1)


if __name__ == '__main__':
    main()
