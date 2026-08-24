import struct, sys
f = open(sys.argv[1], 'rb')
def sec(n): f.seek(n*2048); return f.read(2048)

# find PVD, root, VIDEO_TS, VTS_xx_0.IFO lbas (reuse simple walk)
lba=16
while True:
    d=sec(lba)
    if d[1:6]!=b'CD001': raise SystemExit("not iso")
    if d[0]==1: break
    lba+=1
root=d[156:190]; rlba=struct.unpack('<I',root[2:6])[0]; rlen=struct.unpack('<I',root[10:14])[0]
def walk(dlba,dlen):
    nsec=(dlen+2047)//2048; buf=b''.join(sec(dlba+i) for i in range(nsec)); out=[]
    for s in range(nsec):
        p=s*2048
        while p<s*2048+2048:
            rl=buf[p]
            if rl==0: break
            ext=struct.unpack('<I',buf[p+2:p+6])[0]; nl=buf[p+32]; nm=buf[p+33:p+33+nl]
            out.append((nm,ext)); p+=rl
    return out
vts_dir=None
for nm,ext in walk(rlba,rlen):
    if nm.upper().startswith(b'VIDEO_TS'): vts_dir=ext
# need dlen too
for nm,ext,dl,fl in [(*x,0,0) for x in []]: pass
# re-walk root to get VIDEO_TS length
nsec=(rlen+2047)//2048; buf=b''.join(sec(rlba+i) for i in range(nsec)); vdir=None
for s in range(nsec):
    p=s*2048
    while p<s*2048+2048:
        rl=buf[p]
        if rl==0: break
        ext=struct.unpack('<I',buf[p+2:p+6])[0]; dl=struct.unpack('<I',buf[p+10:p+14])[0]
        nl=buf[p+32]; nm=buf[p+33:p+33+nl]
        if nm.upper().startswith(b'VIDEO_TS') and (buf[p+25]&2): vdir=(ext,dl)
        p+=rl
ifo={}
for nm,ext in walk(*vdir):
    u=nm.upper()
    if u.startswith(b'VTS_') and u[6:12]==b'_0.IFO':
        try: ifo[int(u[4:6])]=ext
        except: pass

def be(b,o,n): return int.from_bytes(b[o:o+n],'big')
for vn in sorted(ifo):
    base=ifo[vn]; mat=sec(base)
    vts_pgcit_sec = be(mat,0xCC,4)   # VTSI_MAT vts_pgcit @204 (sector rel to VTSI)
    print(f"\n=== VTS_{vn:02d} title VTS_PGCIT (rel sector {vts_pgcit_sec}) ===")
    if vts_pgcit_sec==0:
        print("  none"); continue
    pg=sec(base+vts_pgcit_sec)
    nsrp=be(pg,0,2)
    print(f"  nr_pgc={nsrp}")
    for i in range(min(nsrp,4)):
        e=8+i*8
        pgc_off=be(pg,e+4,4)
        pgc=pg[pgc_off:pgc_off+256] if pgc_off+256<=2048 else (pg[pgc_off:]+sec(base+vts_pgcit_sec+1))[:256]
        nprog=pgc[2]; ncell=pgc[3]
        still_pgc=pgc[163]
        cell_off=be(pgc,0xE8,2)  # cell_playback @232
        print(f"  PGCN{i+1}: prog={nprog} cells={ncell} pgc_still@163={still_pgc} cell_pb_off={cell_off}")
        # dump each cell's still_time (cell entry 24 bytes: byte0 flags, byte2 still_time)
        base_c=pgc_off+cell_off
        allb=pg
        if base_c+ncell*24>2048:
            allb=pg+sec(base+vts_pgcit_sec+1)+sec(base+vts_pgcit_sec+2)
        for c in range(ncell):
            ce=base_c+c*24
            cat=allb[ce]; still_t=allb[ce+2]
            first=be(allb,ce+8,4); last=be(allb,ce+20,4)
            print(f"      cell{c}: cat=0x{cat:02x} still_time={still_t} RBN {first}-{last} ({last-first+1} blk)")
