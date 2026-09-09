#!/usr/bin/env python3
"""acmod_scan.py -- what audio coding mode does each AC-3 track ACTUALLY carry?

`dvd/ac3/bsi_parse.sv` accepts a fixed set of acmod values and sets sticky
`err_unsupported` for the rest -> `ac3_err` -> an `ac3_front` self-heal reset
EVERY frame -> TOTAL SILENCE. That failure reached users as bug reports twice
(mono, and the 2/2 quad Residents disc) because nothing measured it.

★ THE IFO'S CHANNEL COUNT IS NOT THE ACMOD. It is a number the AUTHORING TOOL
wrote -- the same class as `progressive_frame` being a bit the ENCODER wrote.
Screening this library on the IFO flagged three discs; the bitstream cleared one
of them outright (a disc declaring 4 channels carries plain acmod 2) and moved
another's acmod. So this tool reads the SYNCFRAME.

⚠ AND IT LOCATES THE SYNCFRAME VIA THE PES `first_access_unit_pointer`, NOT by
searching for 0x0B77 -- that pattern occurs inside compressed payload often
enough to give a false sync and a plausible-looking WRONG acmod.

⚠ Scope, stated honestly: it samples the first `--sectors` of each VTS's VOBS
and stops once every declared AC-3 substream has been seen `--frames` times.
acmod is a per-stream constant, so more frames buy nothing -- but a substream
that first appears LATER than that window is not sampled.

Usage:
    tools/acmod_scan.py                       # the whole library
    tools/acmod_scan.py <iso> [<iso> ...]
    tools/acmod_scan.py --all                 # list every stream, not just gaps
"""
import argparse
import glob
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                                   # noqa: E402
from nav_extract import parse_vts_attr                          # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BSI_PARSE = os.path.join(REPO, 'dvd', 'ac3', 'bsi_parse.sv')

# ATSC A/52 Table 5.8.
ACMOD = {0: '1+1 dual-mono', 1: '1/0 mono', 2: '2/0 stereo', 3: '3/0',
         4: '2/1', 5: '3/1', 6: '2/2 quad', 7: '3/2'}


def supported_acmods():
    """Read the accepted set OUT OF THE RTL rather than restating it here.

    ⚠ THIS FUNCTION IS THE POINT OF THE TOOL AS MUCH AS THE SCAN IS. The
    previous census's verdict lived only as prose in CLAUDE.md; when the RTL
    grew acmod 3..6 the prose did not follow, and a later session spent a
    hardware session hunting a defect that had been fixed months earlier. A
    table that cannot go stale is worth more than a correct one.

    `bsi_parse.sv`'s B_ACMOD state rejects by comparing `data_in[2:0]` against
    literals; everything it does not name is accepted. If the shape ever stops
    matching we say so loudly instead of guessing.
    """
    try:
        src = open(BSI_PARSE).read()
    except OSError as e:
        print(f'acmod_scan: cannot read {BSI_PARSE} ({e}); assuming 1..7',
              file=sys.stderr)
        return {1, 2, 3, 4, 5, 6, 7}, 'ASSUMED'
    # ⚠ There are TWO `B_ACMOD: begin` sites -- a one-line REQUEST stage that
    # only sets req/nbits, and the DECODE stage that carries the guard. Taking
    # the first match reads the wrong one and silently reports "unverified", so
    # pick the block that actually contains the rejection.
    body = ''
    for m in re.finditer(r'B_ACMOD:\s*begin', src):
        chunk = src[m.end():m.end() + 2000]
        chunk = re.split(r'\n\s*B_[A-Z]+\s*:', chunk)[0]
        if 'err_unsupported' in chunk:
            body = chunk
            break
    # every literal compared against data_in[2:0] inside the guard is a REJECT
    rejected = {int(v) for v in
                re.findall(r"data_in\[2:0\]\s*==\s*3'd(\d)", body)}
    if not body or not re.search(r'err_unsupported\s*<=\s*1\'b1', body):
        print('acmod_scan: WARNING -- could not read the acmod guard out of '
              f'{os.path.relpath(BSI_PARSE, REPO)}; the supported set below may '
              'be stale. Check B_ACMOD by hand.', file=sys.stderr)
        return {1, 2, 3, 4, 5, 6, 7}, 'UNVERIFIED'
    return set(range(8)) - rejected, 'from bsi_parse.sv'


def scan_vob(f, start_lba, n_sectors, frames_wanted, expect_subs):
    """-> {substream_id: {acmod: count}} over the head of one VTS's VOBS."""
    seen = {}
    for i in range(n_sectors):
        f.seek((start_lba + i) * 2048)
        sec = f.read(2048)
        if len(sec) < 2048 or sec[:4] != b'\x00\x00\x01\xba':
            continue
        p = 14 + (sec[13] & 7)          # pack header + its stuffing
        while p + 6 < 2048:
            if sec[p:p + 3] != b'\x00\x00\x01':
                break
            sid = sec[p + 3]
            plen = struct.unpack('>H', sec[p + 4:p + 6])[0]
            body = p + 6
            if sid == 0xBD:                          # private_stream_1
                sub = body + 3 + sec[body + 2]       # past the PES opt header
                ssid = sec[sub] if sub < 2048 else 0
                if 0x80 <= ssid <= 0x87:             # AC-3 substream
                    nframes = sec[sub + 1]
                    fap = struct.unpack('>H', sec[sub + 2:sub + 4])[0]
                    # fap counts from the byte AFTER the 4-byte substream header
                    q = sub + 4 + (fap - 1)
                    if nframes and fap and q + 7 < 2048 and \
                            sec[q] == 0x0B and sec[q + 1] == 0x77:
                        acmod = (sec[q + 6] >> 5) & 7
                        seen.setdefault(ssid, {})
                        seen[ssid][acmod] = seen[ssid].get(acmod, 0) + 1
            p = body + plen
        if (len(seen) >= expect_subs and seen and
                all(sum(v.values()) >= frames_wanted for v in seen.values())):
            break
    return seen


def scan_iso(path, args, ok):
    nav = IsoNav(path)
    rows, bad = [], []
    for vn, ifo_lba in sorted(nav.vts_ifo.items()):
        mat = nav.sec(ifo_lba)
        vobs = struct.unpack('>I', mat[0xC0:0xC4])[0]   # VTS_VOBS, IFO-relative
        if not vobs:
            continue
        declared = parse_vts_attr(mat)[2]
        nsub = sum(1 for a in declared if a[0] == 0)    # fmt 0 == AC-3
        seen = scan_vob(nav.f, ifo_lba + vobs, args.sectors, args.frames,
                        max(nsub, 1))
        for ssid in sorted(seen):
            for acmod, n in sorted(seen[ssid].items()):
                row = (vn, ssid, acmod, n)
                rows.append(row)
                if acmod not in ok:
                    bad.append(row)
    nav.f.close()
    return rows, bad


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('images', nargs='*')
    ap.add_argument('--sectors', type=int, default=3000,
                    help='sectors of each VTS VOBS to sample (default 3000)')
    ap.add_argument('--frames', type=int, default=8,
                    help='syncframes per substream before moving on (default 8)')
    ap.add_argument('--all', action='store_true',
                    help='list every stream, not just unsupported ones')
    args = ap.parse_args()

    ok, prov = supported_acmods()
    print('acmod_scan: core accepts {' +
          ', '.join(str(a) for a in sorted(ok)) + '}  (' + prov + ')')

    images = args.images
    if not images:
        root = os.environ.get('DVD_ISO_DIR', os.path.expanduser('~/dvd-isos'))
        images = sorted(glob.glob(os.path.join(root, '**', '*.iso'),
                                  recursive=True) +
                        glob.glob(os.path.join(root, '**', '*.ISO'),
                                  recursive=True))
        print(f'acmod_scan: {len(images)} images under {root}')

    tally, n_bad, n_err = {}, 0, 0
    for path in images:
        name = os.path.basename(path)
        try:
            rows, bad = scan_iso(path, args, ok)
        except Exception as e:                       # a bad rip is not a crash
            print(f'ERR  {name}: {e}')
            n_err += 1
            continue
        for _, _, acmod, _ in rows:
            tally[acmod] = tally.get(acmod, 0) + 1
        show = rows if args.all else bad
        if show:
            print(f'\n{"" if args.all else "!! "}{name}')
            for vn, ssid, acmod, n in show:
                mark = '' if acmod in ok else '   <-- UNSUPPORTED (SILENT)'
                print(f'    VTS_{vn:02d} sub 0x{ssid:02x}: acmod {acmod} '
                      f'({ACMOD[acmod]}) x{n}{mark}')
        n_bad += len(bad)

    print('\n=== acmod tally (streams seen) ===')
    for a in sorted(tally):
        mark = '' if a in ok else '   <-- UNSUPPORTED (SILENT)'
        print(f'  acmod {a} ({ACMOD[a]:14}) {tally[a]:5}{mark}')
    print(f'\n{n_bad} unsupported stream(s), {n_err} unreadable image(s)')
    return 1 if n_bad else 0


if __name__ == '__main__':
    sys.exit(main())
