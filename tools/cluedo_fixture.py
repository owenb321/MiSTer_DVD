#!/usr/bin/env python3
"""Extract the Cluedo boot/menu-chain metadata sectors into a $readmemh fixture
for bench/dvd/iso_reader_cluedo_menu_tb.sv (real-data reader+VM Menu-key repro).

Emits bench/dvd/test_vobs/cluedo_menu_meta.hex plus (stdout) the midx() case map
to paste into the TB. Sectors served:
  - PVD (16) + root dir + all VIDEO_TS dir sectors (35-VTS enumeration)
  - VIDEO_TS.IFO: VMGI_MAT sector, FP-PGC sector, TT_SRPT sector,
    VMGM PGCI_UT (full span: UT sector .. last PGC byte)
  - VTS_01_0.IFO: VTSI_MAT, title VTS_PGCIT, VTSM PGCI_UT span
Everything else reads as zero in the TB.
"""
import struct, sys, os

ISO = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(os.environ.get("DVD_ISO_DIR", os.path.expanduser("~/dvd-isos")),
                 "Cluedo_20051206_AUS_PAL.iso")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "bench", "dvd", "test_vobs", "cluedo_menu_meta.hex")

f = open(ISO, 'rb')
def sec(n, cnt=1):
    f.seek(n * 2048)
    return f.read(2048 * cnt)

def be32(b, o): return struct.unpack('>I', b[o:o+4])[0]
def le32(b, o): return struct.unpack('<I', b[o:o+4])[0]

# --- ISO9660 walk ---------------------------------------------------------
lba = 16
while True:
    d = sec(lba)
    if d[0] == 1: break
    lba += 1
pvd_lba = lba
root_lba = le32(d[156+2:156+10], 0)
root_len = le32(d[156+10:156+18], 0)
root_secs = (root_len + 2047) // 2048

vdir = None
rb = sec(root_lba, root_secs)
for s in range(root_secs):
    p = s * 2048
    while p < s*2048 + 2048:
        rl = rb[p]
        if rl == 0: break
        nm = rb[p+33:p+33+rb[p+32]]
        if nm.upper().startswith(b'VIDEO_TS') and (rb[p+25] & 2):
            vdir = (le32(rb, p+2), le32(rb, p+10))
        p += rl
assert vdir, "no VIDEO_TS dir"
vdir_lba, vdir_len = vdir
vdir_secs = (vdir_len + 2047) // 2048

files = {}
db = sec(vdir_lba, vdir_secs)
for s in range(vdir_secs):
    p = s * 2048
    while p < s*2048 + 2048:
        rl = db[p]
        if rl == 0: break
        nm = db[p+33:p+33+db[p+32]].split(b';')[0].decode('ascii', 'replace')
        files[nm] = (le32(db, p+2), le32(db, p+10))
        p += rl

vmgi_lba = files['VIDEO_TS.IFO'][0]
vts1_lba = files['VTS_01_0.IFO'][0]

# best_menu_vts = the VTS with the largest VTS_xx_0.VOB (the RTL heuristic);
# the VM's FB_VTSM2 hop jumps to its VTSM, so serve its IFO too.
best_vts, best_sz = 0, -1
for nm, (lb, ln) in files.items():
    if nm.startswith('VTS_') and nm.endswith('_0.VOB') and ln > best_sz:
        best_vts, best_sz = int(nm[4:6]), ln
bm_lba = files['VTS_%02d_0.IFO' % best_vts][0]
bm = sec(bm_lba)
bm_vtsm_ut = be32(bm, 0xD0)
bmut = sec(bm_lba + bm_vtsm_ut, 4)
bm_lu = be32(bmut, 8+4)
bm_end = be32(bmut, bm_lu+4)
bm_secs = (bm_end + 2047) // 2048

mat = sec(vmgi_lba)
fp_pgc_byte  = be32(mat, 0x84)          # byte offset of FP PGC within VMGI
tt_srpt_sec  = be32(mat, 0xC4)          # sector offsets within VMGI
vmgm_ut_sec  = be32(mat, 0xC8)

# VMGM PGCI_UT span: UT sector + enough sectors to cover the last PGC.
ut = sec(vmgi_lba + vmgm_ut_sec, 16)
lu_start = be32(ut, 8+4)                # LU[0] start byte
nr_srp = struct.unpack('>H', ut[lu_start:lu_start+2])[0]
last_end = be32(ut, lu_start+4)         # LU end byte (covers all PGC data)
ut_secs = (last_end + 2047) // 2048

v1 = sec(vts1_lba)
vts_pgcit_sec = be32(v1, 0xCC)          # title PGCIT
vtsm_ut_sec   = be32(v1, 0xD0)
tut = sec(vts1_lba + vts_pgcit_sec, 4)
t_end = be32(tut, 4)                    # title PGCIT end byte... (srp end)
t_secs = max(1, (be32(sec(vts1_lba+vts_pgcit_sec), 4) + 2047) // 2048)
mut = sec(vts1_lba + vtsm_ut_sec, 4)
m_lu = be32(mut, 8+4)
m_end = be32(mut, m_lu+4)
m_secs = (m_end + 2047) // 2048

sectors = [pvd_lba, root_lba]
sectors += [vdir_lba + i for i in range(vdir_secs)]
sectors += [vmgi_lba]                                  # VMGI_MAT
sectors += [vmgi_lba + fp_pgc_byte // 2048]            # FP PGC
sectors += [vmgi_lba + tt_srpt_sec]                    # TT_SRPT
sectors += [vmgi_lba + vmgm_ut_sec + i for i in range(ut_secs)]
sectors += [vts1_lba]                                  # VTSI_MAT
sectors += [vts1_lba + vts_pgcit_sec + i for i in range(t_secs)]
sectors += [vts1_lba + vtsm_ut_sec + i for i in range(m_secs)]
sectors += [bm_lba]                                    # best_menu_vts VTSI_MAT
sectors += [bm_lba + bm_vtsm_ut + i for i in range(bm_secs)]
sectors = sorted(set(sectors))

with open(OUT, 'w') as out:
    for s in sectors:
        for b in sec(s):
            out.write("%02x\n" % b)

print("fixture: %s  (%d sectors)" % (os.path.normpath(OUT), len(sectors)))
print("pvd=%d root=%d vdir=%d..%d vmgi=%d fp_sec=%d tt_srpt=%d vmgm_ut=%d..%d (nr_srp=%d)"
      % (pvd_lba, root_lba, vdir_lba, vdir_lba+vdir_secs-1, vmgi_lba,
         vmgi_lba + fp_pgc_byte//2048, vmgi_lba+tt_srpt_sec,
         vmgi_lba+vmgm_ut_sec, vmgi_lba+vmgm_ut_sec+ut_secs-1, nr_srp))
print("vts1_ifo=%d title_pgcit=%d..%d vtsm_ut=%d..%d"
      % (vts1_lba, vts1_lba+vts_pgcit_sec, vts1_lba+vts_pgcit_sec+t_secs-1,
         vts1_lba+vtsm_ut_sec, vts1_lba+vtsm_ut_sec+m_secs-1))
print("best_menu_vts=%d (VTS_%02d_0.VOB %d B) ifo=%d vtsm_ut=%d..%d"
      % (best_vts, best_vts, best_sz, bm_lba,
         bm_lba+bm_vtsm_ut, bm_lba+bm_vtsm_ut+bm_secs-1))
print("\n// paste into the TB:")
print("    function integer midx(input [31:0] s);")
print("        begin")
print("            case (s)")
line = "               "
for i, s in enumerate(sectors):
    line += " 32'd%d: midx = %d;" % (s, i)
    if (i % 3) == 2:
        print(line); line = "               "
if line.strip(): print(line)
print("                default:   midx = -1;")
print("            endcase")
print("        end")
print("    endfunction")
print("    localparam N_META = %d;" % len(sectors))
