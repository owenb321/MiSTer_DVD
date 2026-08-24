#!/usr/bin/env python3
"""Golden reference for exact chapters / PTT (Phase 6).

Ports the two libdvdnav algorithms that the fabric must match byte-for-byte:

  * FORWARD  set_VTS_PTT(vtsN, vts_ttn, part)      getset.c:60
      chapter `part` of title `vts_ttn`  ->  {pgcn, pgn}  (which PGC + which
      program to start).  This is what JumpVTS_PTT / LinkPTTN resolve to, and
      what a user "skip to chapter N" resolves to.  Today the reader
      APPROXIMATES this as "entry PGC + program == part" (ptt ~= pg); exact
      only when the title is single-PGC and pgn == part (all our MOVIE discs).

  * REVERSE  vm_get_current_title_part()           vmget.c:56
      current {pgcn, pgn}  ->  chapter (part).  This is the HUD "CH n/N" n.
      Scans the title's PTT list for an exact pgn match, else the chapter whose
      program range straddles pgn (a PGC with more programs than chapters).

Usage:
  tools/ptt_ref.py <iso> [vts_ttn]          human dump of the main title's PTTs
  tools/ptt_ref.py --vectors <iso>          emit $readmemh-style TB vectors

All IFO fields are BIG-ENDIAN.  Offsets verified against the reader RTL and
libdvdread ifo_read.c / ifo_types.h.
"""
import struct, sys, collections

# ---------------------------------------------------------------------------
# ISO9660 + IFO plumbing (mirrors tools/iso_nav_check.py so the two agree)
# ---------------------------------------------------------------------------
class Disc:
    def __init__(self, path):
        self.f = open(path, 'rb')
    def sec(self, n): self.f.seek(n*2048); return self.f.read(2048)
    def rd(self, a, n): self.f.seek(a); return self.f.read(n)

def _walk(d, dlba, dlen):
    nsec = (dlen + 2047)//2048
    buf = b''.join(d.sec(dlba+i) for i in range(nsec))
    out = []
    for s in range(nsec):
        p = s*2048
        while p < s*2048 + 2048:
            rl = buf[p]
            if rl == 0: break
            ext = struct.unpack('<I', buf[p+2:p+6])[0]
            dl  = struct.unpack('<I', buf[p+10:p+14])[0]
            fl  = buf[p+25]; nl = buf[p+32]; nm = buf[p+33:p+33+nl]
            out.append((nm, ext, dl, fl)); p += rl
    return out

def load_layout(d):
    """Return (vmgi_lba, {vtsn: ifo_lba}, {vtsn: [(ext,dl),..]})."""
    lba = 16
    while True:
        b = d.sec(lba)
        if b[1:6] != b'CD001': raise RuntimeError("not ISO9660")
        if b[0] == 1: break
        if b[0] == 255: raise RuntimeError("no PVD")
        lba += 1
    root = b[156:156+34]
    rl = struct.unpack('<I', root[2:6])[0]; rn = struct.unpack('<I', root[10:14])[0]
    vts_dir = None
    for nm, ext, dl, fl in _walk(d, rl, rn):
        if nm.upper().startswith(b'VIDEO_TS') and (fl & 2): vts_dir = (ext, dl)
    if not vts_dir: raise RuntimeError("no VIDEO_TS")
    vmgi = None; ifo = {}; grp = collections.OrderedDict()
    for nm, ext, dl, fl in _walk(d, *vts_dir):
        u = nm.upper()
        if u.startswith(b'VIDEO_TS.IFO'): vmgi = ext
        if u.startswith(b'VTS_') and u[6:12] == b'_0.IFO':
            try: ifo[int(u[4:6])] = ext
            except ValueError: pass
        if u.startswith(b'VTS_') and b'.VOB' in u:
            try: vn = int(u[4:6]); part = int(u[7:8])
            except ValueError: continue
            if 1 <= part <= 9: grp.setdefault(vn, []).append((ext, dl))
    return vmgi, ifo, grp

def tt_srpt(d, vmgi_lba):
    """VMGI TT_SRPT -> list of (global_title, title_set_nr, vts_ttn, nr_of_ptts, nr_of_angles)."""
    mat = d.sec(vmgi_lba)
    ptr = struct.unpack('>I', mat[196:200])[0]
    if not (0 < ptr <= 0xFFFF): return []
    tt = d.sec(vmgi_lba + ptr)
    nr = struct.unpack('>H', tt[0:2])[0]
    out = []
    for i in range(nr):
        e = tt[8+i*12 : 8+i*12+12]
        out.append((i+1, e[6], e[7], struct.unpack('>H', e[2:4])[0], e[1]))
    return out

def read_ptt_table(d, ifo_lba, vts_ttn):
    """VTS_PTT_SRPT[vts_ttn] -> (nr_of_ptts, [(pgcn, pgn), ...]).  getset.c indexing."""
    mat = d.sec(ifo_lba)
    ptt_off = struct.unpack('>I', mat[200:204])[0]        # VTSI_MAT.vts_ptt_srpt @200 (sectors)
    if not (0 < ptt_off <= 0xFFFFF): return 0, []
    base = (ifo_lba + ptt_off) * 2048
    nr_srpt   = struct.unpack('>H', d.rd(base, 2))[0]     # VTS_PTT_SRPT.nr_of_srpts @0
    last_byte = struct.unpack('>I', d.rd(base+4, 4))[0]   # last_byte @4
    if not (1 <= vts_ttn <= nr_srpt): return 0, []
    off  = struct.unpack('>I', d.rd(base + 8 + (vts_ttn-1)*4, 4))[0]
    noff = struct.unpack('>I', d.rd(base + 8 + vts_ttn*4, 4))[0] if vts_ttn < nr_srpt \
           else (last_byte + 1)
    n = (noff - off)//4
    ptts = []
    for c in range(n):
        e = d.rd(base + off + c*4, 4)
        ptts.append((struct.unpack('>H', e[0:2])[0], struct.unpack('>H', e[2:4])[0]))
    return n, ptts

def pgc_program_map(d, ifo_lba, pgcn):
    """Entry cell (1-based) per program of PGC pgcn -> (nr_programs, [entry_cell,...])."""
    mat = d.sec(ifo_lba)
    pgcit_off = struct.unpack('>I', mat[204:208])[0]
    pgcit_abs = (ifo_lba + pgcit_off) * 2048
    srp = d.rd(pgcit_abs + 8 + (pgcn-1)*8, 8)
    pa  = pgcit_abs + struct.unpack('>I', srp[4:8])[0]
    h   = d.rd(pa, 234)
    nprog = h[2]
    pmoff = struct.unpack('>H', h[230:232])[0]
    pm = list(d.rd(pa + pmoff, nprog)) if pmoff else []
    return nprog, pm

# ---------------------------------------------------------------------------
# The two golden algorithms (exact libdvdnav ports)
# ---------------------------------------------------------------------------
def resolve_ptt(ptts, part):
    """set_VTS_PTT: chapter `part` (1-based) -> (pgcn, pgn) or None if invalid."""
    if part < 1 or part > len(ptts): return None
    return ptts[part-1]                       # {pgcn, pgn}

def current_part(ptts, pgcN, pgN):
    """vm_get_current_title_part restricted to one title: (pgcN,pgN) -> part (1-based) or 0.

    Exact pgn match wins; else the chapter within the same PGC whose program
    range straddles pgN (ptt[k-1].pgn < pgN < ptt[k].pgn -> k-1).
    """
    for part in range(len(ptts)):
        p_pgcn, p_pgn = ptts[part]
        if p_pgcn == pgcN:
            if p_pgn == pgN:
                return part + 1
            if part > 0 and p_pgn > pgN and ptts[part-1][1] < pgN:
                return part          # part-1 (0-based) +1
    return 0

# ---------------------------------------------------------------------------
def main_title(d, vmgi_lba, grp):
    """Auto pick = largest VTS; its first title unit (vts_ttn=1)."""
    best = max(grp.items(), key=lambda kv: sum(dl for _, dl in kv[1]))[0]
    return best, 1

def dump(path, force_ttn=None):
    d = Disc(path)
    vmgi, ifo, grp = load_layout(d)
    titles = tt_srpt(d, vmgi) if vmgi else []
    vtsn, vts_ttn = main_title(d, vmgi, grp)
    if force_ttn: vts_ttn = force_ttn
    ifo_lba = ifo.get(vtsn)
    print("main VTS_%02d  vts_ttn=%d  ifo_lba=%d" % (vtsn, vts_ttn, ifo_lba))
    nr, ptts = read_ptt_table(d, ifo_lba, vts_ttn)
    print("VTS_PTT_SRPT[ttn=%d]: nr_of_ptts=%d" % (vts_ttn, nr))
    pgcns = sorted(set(p[0] for p in ptts))
    entry_pgcn = ptts[0][0] if ptts else None
    nprog, pm = pgc_program_map(d, ifo_lba, entry_pgcn) if entry_pgcn else (0, [])
    trivial = (len(pgcns) == 1 and all(p[1] == c+1 for c, p in enumerate(ptts)) and nr == nprog)
    print("  entry PGCN=%s  entry-PGC programs=%d  distinct pgcns=%d  %s"
          % (entry_pgcn, nprog, len(pgcns),
             "TRIVIAL (program==ptt: reader already exact)" if trivial else ">>> DIVERGES <<<"))
    for c in range(min(nr, 40)):
        print("  chapter %3d -> pgcn %3d  pgn %3d" % (c+1, ptts[c][0], ptts[c][1]))
    if nr > 40: print("  ... (%d more)" % (nr-40))
    # reverse spot-check: every chapter's own {pgcn,pgn} must map back to itself
    bad = [c+1 for c in range(nr) if current_part(ptts, ptts[c][0], ptts[c][1]) != c+1]
    print("  reverse self-check: %s" % ("OK" if not bad else "MISMATCH at %s" % bad[:8]))

def vectors(path):
    """Emit $readmemh PTT table + resolve/reverse vectors for a testbench."""
    d = Disc(path)
    vmgi, ifo, grp = load_layout(d)
    vtsn, vts_ttn = main_title(d, vmgi, grp)
    ifo_lba = ifo.get(vtsn)
    nr, ptts = read_ptt_table(d, ifo_lba, vts_ttn)
    print("// VTS_%02d ttn=%d nr_of_ptts=%d  {pgcn[8],pgn[8]} per chapter" % (vtsn, vts_ttn, nr))
    for c, (pgcn, pgn) in enumerate(ptts):
        print("%04x  // ch %d" % (((pgcn & 0xff) << 8) | (pgn & 0xff), c+1))

if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--vectors": vectors(a[1])
    else: dump(a[0], int(a[1]) if len(a) > 1 else None)
