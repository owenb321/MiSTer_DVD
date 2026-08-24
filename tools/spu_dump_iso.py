#!/usr/bin/env python3
"""spu_dump_iso.py — dump the first subtitle SPU's colour/contrast straight from a
decrypted DVD-Video ISO, and resolve its SET_COLOR indices against the PGC palette.

This is the diagnostic for "subtitles show the wrong colour": it prints, for the
first subpicture unit of the largest VTS, the SET_COLOR palette indices, the
SET_CONTR alphas, and the #RRGGBB each index maps to in the PGC palette (the exact
chain the fabric does: 2bpp bitmap colour -> SET_COLOR index -> PGC palette YCbCr
-> RGB). Compare its output against what the core shows on screen.

    python3 tools/spu_dump_iso.py MEN_IN_BLACK.iso [--sub 0x20] [--vts N]

Reuses the SPU/PES parser in tools/spu_ref.py. Uses mmap + a bounded scan so it
does not load the whole (multi-GB) ISO into RAM. All IFO fields are BIG-ENDIAN.
"""
import sys, os, struct, mmap, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spu_ref

SECTOR = 2048

def ycc2rgb(Y, Cr, Cb):
    yt = max(0, Y - 16)
    clip = lambda v: 0 if v < 0 else (255 if v > 255 else v)
    r = clip((298*yt + 409*(Cr-128)) >> 8)
    g = clip((298*yt - 100*(Cb-128) - 208*(Cr-128)) >> 8)
    b = clip((298*yt + 516*(Cb-128)) >> 8)
    return r, g, b

def walk_dir(mm, dlba, dlen):
    """Yield (name, extent_lba, size, flags) for records in an ISO9660 directory."""
    data = mm[dlba*SECTOR : dlba*SECTOR + ((dlen + SECTOR - 1)//SECTOR)*SECTOR]
    p = 0
    while p < len(data):
        rlen = data[p]
        if rlen == 0:
            # advance to next sector boundary
            p = (p // SECTOR + 1) * SECTOR
            continue
        ext = struct.unpack('<I', data[p+2:p+6])[0]
        size = struct.unpack('<I', data[p+10:p+14])[0]
        flags = data[p+25]
        nlen = data[p+32]
        name = data[p+33:p+33+nlen]
        yield name, ext, size, flags
        p += rlen

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('iso')
    ap.add_argument('--sub', default='0x20', help='subpicture substream id (default 0x20)')
    ap.add_argument('--vts', type=int, default=0, help='force VTS number (0 = largest VOB)')
    ap.add_argument('--scan-mb', type=int, default=400, help='max MB of VOB to scan for an SPU')
    ap.add_argument('--unit', type=int, default=0, help='which SPU unit to dump (default first)')
    args = ap.parse_args()
    want_sub = int(args.sub, 16)

    f = open(args.iso, 'rb')
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    # PVD @ sector 16 -> root directory record @ offset 156.
    pvd = mm[16*SECTOR:17*SECTOR]
    if pvd[1:6] != b'CD001':
        print("not an ISO9660 image (no CD001 @ sector 16)"); return
    root_ext = struct.unpack('<I', pvd[156+2:156+6])[0]
    root_len = struct.unpack('<I', pvd[156+10:156+14])[0]

    # root -> VIDEO_TS
    vts_dir = None
    for name, ext, size, flags in walk_dir(mm, root_ext, root_len):
        if name.upper().startswith(b'VIDEO_TS') and (flags & 0x02):
            vts_dir = (ext, size); break
    if not vts_dir:
        print("no VIDEO_TS directory"); return

    # enumerate VTS_nn_1.VOB (title VOBs) + VTS_nn_0.IFO
    vobs = {}   # vtsn -> (lba, size)
    ifos = {}   # vtsn -> lba
    for name, ext, size, flags in walk_dir(mm, vts_dir[0], vts_dir[1]):
        nm = name.split(b';')[0].upper()
        if nm.startswith(b'VTS_') and nm.endswith(b'_1.VOB'):
            vtsn = int(nm[4:6]); vobs[vtsn] = (ext, size)
        elif nm.startswith(b'VTS_') and nm.endswith(b'_0.IFO'):
            vtsn = int(nm[4:6]); ifos[vtsn] = ext

    if not vobs:
        print("no VTS_nn_1.VOB found"); return
    if args.vts:
        vtsn = args.vts
    else:
        vtsn = max(vobs, key=lambda k: vobs[k][1])   # largest title VOB = feature
    if vtsn not in vobs:
        print("VTS_%02d has no title VOB" % vtsn); return
    vlba, vsize = vobs[vtsn]
    print("target VTS_%02d  VOB @ sector %d (%.1f MB)" % (vtsn, vlba, vsize/1e6))

    # PGC palette from VTS_nn_0.IFO (VTSI_MAT vts_pgcit@204 -> PGCIT SRP[0] -> PGC@164)
    palette = None
    if vtsn in ifos:
        il = ifos[vtsn]
        mat = mm[il*SECTOR:(il+1)*SECTOR]
        vts_pgcit = struct.unpack('>I', mat[204:208])[0]
        if 0 < vts_pgcit <= 0xFFFFF:
            pit = (il + vts_pgcit) * SECTOR
            psb = struct.unpack('>I', mm[pit+12:pit+16])[0]   # SRP[0].pgc_start_byte
            pgc = pit + psb
            pal = mm[pgc+164:pgc+164+64]
            palette = [(pal[e*4+1], pal[e*4+2], pal[e*4+3]) for e in range(16)]

    # scan a bounded window of the VOB for the first subtitle SPU
    scan_bytes = min(args.scan_mb * 1024 * 1024, vsize)
    data = mm[vlba*SECTOR : vlba*SECTOR + scan_bytes]
    try:
        spu, pts = spu_ref.extract_unit(data, want_sub, args.unit)
    except RuntimeError as e:
        print("no subtitle SPU (substream 0x%02X) in the first %d MB: %s"
              % (want_sub, args.scan_mb, e)); return
    dec = spu_ref.decode_spu(spu, pts or 0)

    # Full DCSQ command sequence + raw bytes, so a divergence vs dvd/spu_decode.sv's
    # parser (which captures SET_COLOR) can be spotted. dvd/spu_decode.sv walks ALL
    # DCSQs and commits the LAST SET_COLOR.
    print("\nSPU raw header: SPDSZ=%d DCSQT_SA=%d  total=%d bytes" % (dec['spdsz'], dec['dcsqt_sa'], len(spu)))
    print("DCSQ command sequence (%d DCSQs):" % len(dec['dcsqs']))
    for di, dq in enumerate(dec['dcsqs']):
        raw = spu[dq['off']:dq['next'] if dq['next'] > dq['off'] else dq['off']+24]
        print("  DCSQ[%d] @0x%04X delay=%d next=0x%04X: %s"
              % (di, dq['off'], dq['delay'], dq['next'],
                 ' '.join('%s%s' % (c[0], '' if len(c)==1 else c[1]) for c in dq['cmds'])))
        print("           raw: %s" % raw[:32].hex(' '))

    print("\nfirst SPU unit #%d (substream 0x%02X):  SPDSZ=%d" % (args.unit, want_sub, dec['spdsz']))
    pal_idx = dec['palette']       # [c0,c1,c2,c3] = SET_COLOR indices for the 4 bmp colours
    contrast = dec['contrast']     # [a0,a1,a2,a3]
    print("  SET_COLOR indices (bmp colour 0..3 -> PGC palette entry): %s" % pal_idx)
    print("  SET_CONTR alphas  (0=transparent..15=opaque):             %s" % contrast)
    if palette:
        print("  resolved colours the fabric SHOULD draw (index -> PGC palette RGB):")
        names = ['bg/idx0', 'idx1', 'idx2', 'idx3']
        for c in range(4):
            pi = pal_idx[c]
            Y, Cr, Cb = palette[pi]
            r, g, b = ycc2rgb(Y, Cr, Cb)
            vis = "" if contrast[c] else "  (alpha 0 = not drawn)"
            print("    %-8s -> palette[%2d] = #%02X%02X%02X  (Y%3d Cr%3d Cb%3d) alpha=%d%s"
                  % (names[c], pi, r, g, b, Y, Cr, Cb, contrast[c], vis))
    else:
        print("  (could not read the PGC palette from VTS_%02d_0.IFO)" % vtsn)

if __name__ == '__main__':
    main()
