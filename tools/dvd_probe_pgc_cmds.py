import struct, sys, subprocess
sys.path.insert(0,'tools')
import iso_nav_check as N
# reuse its command decoder
f=open(sys.argv[1],'rb')
def sec(n): f.seek(n*2048); return f.read(2048)
lba=16
while True:
    d=sec(lba)
    if d[0]==1: break
    lba+=1
root=d[156:190]; rlba=struct.unpack('<I',root[2:6])[0]; rlen=struct.unpack('<I',root[10:14])[0]
nsec=(rlen+2047)//2048; buf=b''.join(sec(rlba+i) for i in range(nsec)); vdir=None
for s in range(nsec):
    p=s*2048
    while p<s*2048+2048:
        rl=buf[p]
        if rl==0: break
        ext=struct.unpack('<I',buf[p+2:p+6])[0]; dl=struct.unpack('<I',buf[p+10:p+14])[0]
        nm=buf[p+33:p+33+buf[p+32]]
        if nm.upper().startswith(b'VIDEO_TS') and (buf[p+25]&2): vdir=(ext,dl)
        p+=rl
def walk(dlba,dlen):
    ns=(dlen+2047)//2048; b=b''.join(sec(dlba+i) for i in range(ns)); out=[]
    for s in range(ns):
        p=s*2048
        while p<s*2048+2048:
            rl=b[p]
            if rl==0: break
            e=struct.unpack('<I',b[p+2:p+6])[0]; nm=b[p+33:p+33+b[p+32]]
            out.append((nm,e)); p+=rl
    return out
ifo={}
for nm,e in walk(*vdir):
    u=nm.upper()
    if u.startswith(b'VTS_') and u[6:12]==b'_0.IFO':
        try: ifo[int(u[4:6])]=e
        except: pass
def be(b,o,n): return int.from_bytes(b[o:o+n],'big')
for vn in [1,2]:
    base=ifo[vn]; mat=sec(base); pgcit=be(mat,0xCC,4)
    pg=sec(base+pgcit)+sec(base+pgcit+1)
    nsrp=be(pg,0,2)
    for i in range(nsrp):
        pgc_off=be(pg,8+i*8+4,4); pgc=pg[pgc_off:]
        nprog=pgc[2]; ncell=pgc[3]
        cmd_off=be(pgc,0xE4,2)  # command_tbl_offset @228
        print(f"VTS_{vn:02d} PGCN{i+1}: prog={nprog} cells={ncell} cmd_tbl_off={cmd_off}")
        if cmd_off==0: continue
        ct=pgc[cmd_off:]
        npre=be(ct,0,2); npost=be(ct,2,2); ncellc=be(ct,4,2)
        print(f"    nr_pre={npre} nr_post={npost} nr_cell={ncellc}")
        o=8
        for k in range(npre):
            print(f"    pre[{k}]: "+N.decode_vmcmd(ct[o:o+8])); o+=8
        for k in range(npost):
            print(f"    post[{k}]: "+N.decode_vmcmd(ct[o:o+8])); o+=8
        for k in range(ncellc):
            print(f"    cell[{k}]: "+N.decode_vmcmd(ct[o:o+8])); o+=8
