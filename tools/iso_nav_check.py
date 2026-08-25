#!/usr/bin/env python3
# iso_nav_check.py - predict what dvd/dvd_iso_reader.sv will select for an ISO.
#
# Mirrors the in-fabric ISO9660 navigator: parses the PVD -> root dir -> VIDEO_TS
# dir, enumerates VTS_xx_y.VOB title VOBs (part 1..9), and reports the largest
# title set (the "main feature" heuristic the core uses). Run against a decrypted
# DVD-Video ISO to sanity-check which title the core will play, before HW testing.
#
#   python3 tools/iso_nav_check.py disc.iso
import sys, struct, collections

# =============================================================================
# libdvdnav still-detection heuristic (src/vm/vm.c get_current_position 561-596).
# The RTL (dvd_iso_reader.sv) must reproduce this so authored menu/ad/copyright
# stills (which carry NO cell still_time on many discs) are HELD, not flashed.
# =============================================================================
def _bcd_secs(pbtime):   # dvd_time_t: [hour, minute, second, frame], each BCD
    h = ((pbtime[0] >> 4) * 10) + (pbtime[0] & 0x0f)
    m = ((pbtime[1] >> 4) * 10) + (pbtime[1] & 0x0f)
    s = ((pbtime[2] >> 4) * 10) + (pbtime[2] & 0x0f)
    return h*3600 + m*60 + s

def still_heuristic(cell_still, pgc_still, is_last, first, lvobu, last, pbtime):
    still = cell_still + (pgc_still if is_last else 0)
    if still:
        return min(still, 255), 'explicit'
    if last == lvobu and (last - first) < 1024:
        t = _bcd_secs(pbtime)
        size = last - first
        if t == 0 or size / t > 30:
            return 0, 'hi-datarate'
        return min(t, 255), 'HEURISTIC'
    return 0, '-'

# =============================================================================
# DVD-VM command decoder - a FAITHFUL port of libdvdnav src/vm/vmcmd.c
# (vm_print_mnemonic and helpers). This is the golden pretty-printer the
# Phase-4 dvd_vm.sv decode tables will be checked against, so it mirrors the
# C code's bit numbering exactly: bits are numbered 63 (MSB of byte 0) .. 0,
# and getbits(start, count) = bits [start .. start-count+1]. The "unknown
# bits" trailer replicates vmcmd.c's examined-bits check - any non-empty
# trailer on a real disc means our decode (or the disc) is off.
# =============================================================================
_CMP_OP  = ["", "&", "==", "!=", ">=", ">", "<=", "<"]
_SET_OP  = ["", "=", "<->", "+=", "-=", "*=", "/=", "%=", "rnd", "&=", "|=", "^="]
_LINK_TBL = ["LinkNoLink", "LinkTopC", "LinkNextC", "LinkPrevC",
             "", "LinkTopPG", "LinkNextPG", "LinkPrevPG",
             "", "LinkTopPGC", "LinkNextPGC", "LinkPrevPGC",
             "LinkGoUpPGC", "LinkTailPGC", "", "", "RSM"]
_SREG_ABBR = ["MENULANG", "ASTN", "SPSTN", "AGLN", "TTN", "VTS_TTN", "TT_PGCN",
              "PTTN", "HL_BTNN", "NVTMR", "NV_PGCN", "AMXMD", "CC_PLT", "PLT",
              "SPRM14", "SPRM15", "AUDLANG", "AUDEXT", "SPLANG", "SPEXT",
              "REGION", "SPRM21", "SPRM22", "SPRM23"]

class _VMCmd(object):
    def __init__(self, b):
        self.ins = int.from_bytes(bytes(b[:8]), 'big')
        self.ex  = 0
    def bits(self, start, count):
        self.ex |= ((1 << count) - 1) << (start + 1 - count)
        return (self.ins >> (start + 1 - count)) & ((1 << count) - 1)

def _sreg(r):
    return _SREG_ABBR[r] if r < len(_SREG_ABBR) else "SPRM%d?" % r

def _reg(r):
    return _sreg(r & 0x7F) if (r & 0x80) else "g[%d]" % (r & 0x7F)

def _reg_or_data(c, imm, start):      # print_reg_or_data
    if imm:
        v = c.bits(start, 16)
        s = "0x%x" % v
        lo, hi = v & 0xFF, (v >> 8) & 0xFF
        if 0x20 <= lo < 0x7F and 0x20 <= hi < 0x7F:
            s += ' ("%c%c")' % (hi, lo)
        return s
    return _reg(c.bits(start - 8, 8))

def _reg_or_data_2(c, imm, start):    # print_reg_or_data_2
    if imm: return "0x%x" % c.bits(start - 1, 7)
    return "g[%d]" % c.bits(start - 4, 4)

def _reg_or_data_3(c, imm, start):    # print_reg_or_data_3
    if imm:
        v = c.bits(start, 16)
        return "0x%x" % v
    return _reg(c.bits(start, 8))

def _if_v1(c):
    op = c.bits(54, 3)
    if not op: return ""
    return "if (g[%d] %s %s) " % (c.bits(39, 8), _CMP_OP[op],
                                  _reg_or_data(c, c.bits(55, 1), 31))
def _if_v2(c):
    op = c.bits(54, 3)
    if not op: return ""
    return "if (%s %s %s) " % (_reg(c.bits(15, 8)), _CMP_OP[op], _reg(c.bits(7, 8)))
def _if_v3(c):
    op = c.bits(54, 3)
    if not op: return ""
    return "if (g[%d] %s %s) " % (c.bits(43, 4), _CMP_OP[op],
                                  _reg_or_data(c, c.bits(55, 1), 15))
def _if_v4(c):
    op = c.bits(54, 3)
    if not op: return ""
    return "if (g[%d] %s %s) " % (c.bits(51, 4), _CMP_OP[op],
                                  _reg_or_data(c, c.bits(55, 1), 31))
def _if_v5(c):
    op = c.bits(54, 3)
    if not op: return ""
    if c.bits(60, 1):   # set_immediate
        return "if (g[%d] %s %s) " % (c.bits(31, 8), _CMP_OP[op], _reg(c.bits(23, 8)))
    return "if (g[%d] %s %s) " % (c.bits(39, 8), _CMP_OP[op],
                                  _reg_or_data(c, c.bits(55, 1), 31))

def _special(c):
    op = c.bits(51, 4)
    if op == 0: return "Nop"
    if op == 1: return "Goto %d" % c.bits(7, 8)
    if op == 2: return "Break"
    if op == 3: return "SetTmpPML %d, Goto %d" % (c.bits(11, 4), c.bits(7, 8))
    return "?special(%d)" % op

def _linksub(c):
    lop = c.bits(7, 8); btn = c.bits(15, 6)
    if lop < len(_LINK_TBL) and _LINK_TBL[lop]:
        return "%s (button %d)" % (_LINK_TBL[lop], btn)
    return "?linksub(%d)" % lop

def _link(c, optional):
    op = c.bits(51, 4)
    if op == 0: return "" if optional else "?NOP-link"
    pre = ", " if optional else ""
    if op == 1: return pre + _linksub(c)
    if op == 4: return pre + "LinkPGCN %d" % c.bits(14, 15)
    if op == 5: return pre + "LinkPTT %d (button %d)" % (c.bits(9, 10), c.bits(15, 6))
    if op == 6: return pre + "LinkPGN %d (button %d)" % (c.bits(6, 7), c.bits(15, 6))
    if op == 7: return pre + "LinkCN %d (button %d)" % (c.bits(7, 8), c.bits(15, 6))
    return pre + "?link(%d)" % op

def _jump(c):
    op = c.bits(51, 4)
    if op == 1: return "Exit"
    if op == 2: return "JumpTT %d" % c.bits(22, 7)
    if op == 3: return "JumpVTS_TT %d" % c.bits(22, 7)
    if op == 5: return "JumpVTS_PTT %d:%d" % (c.bits(22, 7), c.bits(41, 10))
    if op == 6:
        dom = c.bits(23, 2)
        if dom == 0: return "JumpSS FP"
        if dom == 1: return "JumpSS VMGM (menu %d)" % c.bits(19, 4)
        if dom == 2: return "JumpSS VTSM (vts %d, title %d, menu %d)" % (
                            c.bits(30, 7), c.bits(38, 7), c.bits(19, 4))
        if dom == 3: return "JumpSS VMGM (pgc %d)" % c.bits(46, 15)
    if op == 8:
        dom = c.bits(23, 2)
        if dom == 0: return "CallSS FP (rsm_cell %d)" % c.bits(31, 8)
        if dom == 1: return "CallSS VMGM (menu %d, rsm_cell %d)" % (
                            c.bits(19, 4), c.bits(31, 8))
        if dom == 2: return "CallSS VTSM (menu %d, rsm_cell %d)" % (
                            c.bits(19, 4), c.bits(31, 8))
        if dom == 3: return "CallSS VMGM (pgc %d, rsm_cell %d)" % (
                            c.bits(46, 15), c.bits(31, 8))
    return "?jump(%d)" % op

def _system_set(c):
    op = c.bits(59, 4); out = []
    if op == 1:      # SetSTN: SPRM 1/2/3 (audio, subpicture, angle)
        for i in (1, 2, 3):
            if c.bits(47 - i*8, 1):
                out.append("%s = %s" % (_sreg(i),
                           _reg_or_data_2(c, c.bits(60, 1), 47 - i*8)))
        return "SetSTN " + " ".join(out) if out else "SetSTN (none)"
    if op == 2:
        return "%s = %s %s = %d" % (_sreg(9),
               _reg_or_data(c, c.bits(60, 1), 47), _sreg(10), c.bits(30, 15))
    if op == 3:
        return "SetMode %s g[%d] = %s" % (
               "Counter" if c.bits(23, 1) else "Register",
               c.bits(19, 4), _reg_or_data(c, c.bits(60, 1), 47))
    if op == 6:
        if c.bits(60, 1):
            return "%s = 0x%x (button %d)" % (_sreg(8), c.bits(31, 16), c.bits(31, 6))
        return "%s = g[%d]" % (_sreg(8), c.bits(19, 4))
    return "?system_set(%d)" % op

def _set_v1(c):
    op = c.bits(59, 4)
    if not op: return "NOP"
    return "g[%d] %s %s" % (c.bits(35, 4), _SET_OP[op],
                            _reg_or_data(c, c.bits(60, 1), 31))
def _set_v2(c):
    op = c.bits(59, 4)
    if not op: return "NOP"
    return "g[%d] %s %s" % (c.bits(51, 4), _SET_OP[op],
                            _reg_or_data(c, c.bits(60, 1), 47))
def _set_v3(c):
    op = c.bits(59, 4)
    if not op: return "NOP"
    return "g[%d] %s %s" % (c.bits(51, 4), _SET_OP[op],
                            _reg_or_data_3(c, c.bits(60, 1), 47))

def decode_vmcmd(b):
    """Faithful port of libdvdnav vmcmd.c vm_print_mnemonic (returns a string)."""
    c = _VMCmd(b)
    t = c.bits(63, 3)
    if t == 0:
        s = _if_v1(c) + _special(c)
    elif t == 1:
        if c.bits(60, 1): s = _if_v2(c) + _jump(c)
        else:             s = _if_v1(c) + _link(c, 0)
    elif t == 2:
        s = _if_v2(c) + _system_set(c) + _link(c, 1)
    elif t == 3:
        s = _if_v3(c) + _set_v1(c) + _link(c, 1)
    elif t == 4:
        s = _set_v2(c) + ", " + _if_v4(c) + _linksub(c)
    elif t == 5:
        s = _if_v5(c) + "{ " + _set_v3(c) + ", " + _linksub(c) + " }"
    elif t == 6:
        s = _if_v5(c) + "{ " + _set_v3(c) + " } " + _linksub(c)
    else:
        s = "?type(%d)" % t
    unk = c.ins & ~c.ex
    if unk:
        s += "  [WARNING unknown bits: %016x]" % unk
    return s

def main(path):
    f = open(path, 'rb')
    def sec(n): f.seek(n*2048); return f.read(2048)

    lba = 16
    while True:
        d = sec(lba)
        if d[1:6] != b'CD001':
            print("not ISO9660 (no CD001 at sector 16) -> core uses flat-file fallback")
            return
        if d[0] == 1: break
        if d[0] == 255:
            print("ISO9660 but no PVD -> core reports iso_error"); return
        lba += 1
    root = d[156:156+34]
    root_lba = struct.unpack('<I', root[2:6])[0]
    root_len = struct.unpack('<I', root[10:14])[0]

    def walk(dlba, dlen):
        nsec = (dlen + 2047)//2048
        buf = b''.join(sec(dlba+i) for i in range(nsec))
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

    vts_dir = None
    for nm, ext, dl, fl in walk(root_lba, root_len):
        if nm.upper().startswith(b'VIDEO_TS') and (fl & 2):
            vts_dir = (ext, dl)
    if not vts_dir:
        print("no VIDEO_TS directory -> core reports iso_error"); return

    groups = collections.OrderedDict()
    vmgi_lba = None
    vts_ifo_lba = {}                # per-VTS VTS_xx_0.IFO (VTSI) start LBA
    vmgm_vob = None                 # VIDEO_TS.VOB = VMGM_VOBS (VMG menu VOB) {lba, bytes}
    vtsm_vob = {}                   # per-VTS VTS_xx_0.VOB = VTSM_VOBS (VTS menu VOB)
    for nm, ext, dl, fl in walk(*vts_dir):
        u = nm.upper()
        if u.startswith(b'VIDEO_TS.IFO'):
            vmgi_lba = ext          # the VMGI (VIDEO_TS.IFO) start LBA
        if u.startswith(b'VIDEO_TS.VOB'):
            vmgm_vob = (ext, dl)    # menu-domain (Phase 2): VMGM menu VOB extent
        if u.startswith(b'VTS_') and u[6:12] == b'_0.IFO':
            try: vts_ifo_lba[int(u[4:6])] = ext   # VTS_xx_0.IFO
            except ValueError: pass
        if u.startswith(b'VTS_') and b'.VOB' in u:
            try: vn = int(u[4:6]); part = int(u[7:8])
            except ValueError: continue
            if 1 <= part <= 9:
                groups.setdefault(vn, []).append((ext, dl))
            elif part == 0:
                vtsm_vob[vn] = (ext, dl)   # VTS_xx_0.VOB = the VTS menu VOB

    for vn, exts in groups.items():
        tot = sum(dl for _, dl in exts)
        print("VTS_%02d: %d title VOB(s), %10d bytes  first_lba=%d"
              % (vn, len(exts), tot, exts[0][0]))
    best = max(groups.items(), key=lambda kv: sum(dl for _, dl in kv[1]))
    print("LARGEST-VTS heuristic -> VTS_%02d" % best[0])

    # ---- IFO (VMGI / TT_SRPT) title 1 selection (BIG-ENDIAN fields) ----
    # VMGI_MAT.tt_srpt @196 = sector ptr rel. to IFO start; TT_SRPT.nr_of_srpts
    # @0; TT_SRP[0].title_set_nr @14 = the VTS holding title 1 (main feature).
    ifo_vtsn = None
    ifo_vts_ttn = None       # TT_SRP[0].vts_ttn @15 (the title's number within its VTS)
    if vmgi_lba is not None:
        mat = sec(vmgi_lba)
        tt_srpt_ptr = struct.unpack('>I', mat[196:200])[0]
        if 0 < tt_srpt_ptr <= 65535:
            tt = sec(vmgi_lba + tt_srpt_ptr)
            nr_srpts = struct.unpack('>H', tt[0:2])[0]
            title1_vtsn = tt[14]
            ifo_vts_ttn = tt[15]
            if nr_srpts >= 1 and title1_vtsn != 0:
                ifo_vtsn = title1_vtsn
                print("IFO TT_SRPT title 1 -> VTS_%02d  (nr_of_srpts=%d)"
                      % (ifo_vtsn, nr_srpts))
            else:
                print("IFO TT_SRPT malformed (nr_of_srpts=%d, title_set_nr=%d) -> fallback"
                      % (nr_srpts, title1_vtsn))
        else:
            print("IFO tt_srpt pointer out of range (%d) -> fallback" % tt_srpt_ptr)
    else:
        print("no VIDEO_TS.IFO record -> IFO selection unavailable, fallback")

    # Core AUTO selection = the LARGEST VTS (longest-title proxy). The VMGI
    # TT_SRPT "title 1" pick above is now diagnostic only (retired from Auto -
    # it chose short logo/license clips on multi-feature discs). A manual OSD
    # "DVD Title" = N overrides Auto to play VTS_0N.
    sel = best[0]
    via = "Auto = largest VTS"
    exts = groups[sel]
    print("\nMAIN FEATURE (Auto) -> VTS_%02d  via %s  (%d extents, first ISO LBA=%d, sd 512-block=%d)"
          % (sel, via, len(exts), exts[0][0], exts[0][0]*4))
    print("  (OSD 'DVD Title' = N overrides Auto to play VTS_0N; see the title list below)")

    def rd(a, n): f.seek(a); return f.read(n)               # absolute-byte read
    def bcd(b): return (b >> 4) * 10 + (b & 0xF)
    def dvd_time(t4): return "%02d:%02d:%02d" % (bcd(t4[0]), bcd(t4[1]), bcd(t4[2]))
    def dvd_secs(t4): return bcd(t4[0])*3600 + bcd(t4[1])*60 + bcd(t4[2])

    # Dump a PGC's full command table (pre/post/cell), each command decoded by
    # the faithful vmcmd.c port above. The exact byte layout here (counts @0/2/4,
    # 8-byte commands from @8, pre|post|cell contiguous) is what the Phase-2 RTL
    # streams into the VM command BRAM - this doubles as its golden reference.
    def dump_pgc_cmds(label, pgc_abs):
        pgc = rd(pgc_abs, 256)
        # PGC offset fields: command_tbl@228, program_map@230, cell_playback@232,
        # cell_position@234 (each u16, rel. to PGC start).
        cmd_off = struct.unpack('>H', pgc[228:230])[0]     # command_tbl_offset @228
        print("  %s: programs=%d cells=%d command_tbl_offset=%d"
              % (label, pgc[2], pgc[3], cmd_off))
        if not cmd_off: return
        ct = rd(pgc_abs + cmd_off, 8)
        nr_pre  = struct.unpack('>H', ct[0:2])[0]
        nr_post = struct.unpack('>H', ct[2:4])[0]
        nr_cell = struct.unpack('>H', ct[4:6])[0]
        print("    nr_pre=%d nr_post=%d nr_cell=%d" % (nr_pre, nr_post, nr_cell))
        idx = 0
        for kind, n in (("pre", nr_pre), ("post", nr_post), ("cell", nr_cell)):
            for i in range(min(n, 128)):
                cmd = rd(pgc_abs + cmd_off + 8 + (idx + i)*8, 8)
                print("    %s[%d]: %s   %s" % (kind, i, cmd.hex(' '), decode_vmcmd(cmd)))
            idx += n

    # ---- First Play PGC (VMGI_MAT.first_play_pgc @132). This is the program
    # libdvdnav/VLC EXECUTE on disc open to reach the author's intended start
    # title -- the real reason VLC "just knows". If it's a single JumpTT we can
    # follow it in fabric; if it chains into a menu (JumpSS), auto-play needs the
    # menu's PGC commands (or a manual picker).
    # Full VMGI TT_SRPT dump: title# -> VTS + vts_ttn (to resolve a JumpTT).
    tt_map = {}   # global title number -> (vtsn, vts_ttn)
    if vmgi_lba is not None:
        vmgi = sec(vmgi_lba)
        tsp = struct.unpack('>I', vmgi[196:200])[0]
        if 0 < tsp <= 0xFFFFF:
            tt = sec(vmgi_lba + tsp)
            nts = struct.unpack('>H', tt[0:2])[0]
            print("\n--- VMGI TT_SRPT (%d titles) ---" % nts)
            for i in range(min(nts, 99)):
                e = tt[8 + i*12 : 8 + i*12 + 12]
                vtsn = e[6]; vttn = e[7]
                tt_map[i+1] = (vtsn, vttn)
                dur = ""
                if vtsn in vts_ifo_lba:
                    try:
                        il = vts_ifo_lba[vtsn]; vm2 = sec(il)
                        vp = struct.unpack('>I', vm2[204:208])[0]
                        pit2 = il + vp
                        psb2 = struct.unpack('>I', sec(pit2)[12:16])[0]
                        dur = "  (%s)" % dvd_time(rd(pit2*2048 + psb2 + 4, 4))
                    except Exception: pass
                print("  title %2d -> VTS_%02d (vts_ttn=%d)%s" % (i+1, vtsn, vttn, dur))

    if vmgi_lba is not None:
        fp_off = struct.unpack('>I', vmgi[132:136])[0]
        print("\n--- First Play PGC (VMGI@132 offset=%d) - VLC/libdvdnav execute this ---" % fp_off)
        if fp_off == 0:
            print("  no First Play PGC -> disc relies on menu / TT_SRPT")
        else:
            fp_abs = vmgi_lba*2048 + fp_off
            dump_pgc_cmds("FP_PGC", fp_abs)
            # Resolve the FP title jump: scan pre-commands for JumpTT/JumpVTS_TT
            # (vmcmd.c numbering: type=1 + bit60=jump, op@bits[51:48]: 2=JumpTT
            # [GLOBAL title, bits(22,7)], 3=JumpVTS_TT [vts_ttn, needs VM state]).
            # NOTE: the pre-rewrite decoder had these op codes WRONG (it read
            # op 2 as JumpVTS_TT and op 6 as JumpTT) - re-check any conclusions
            # drawn from its output on earlier discs.
            pgc = rd(fp_abs, 256)
            cmd_off = struct.unpack('>H', pgc[228:230])[0]
            if cmd_off:
                nr_pre = struct.unpack('>H', rd(fp_abs + cmd_off, 2)[0:2])[0]
                for i in range(min(nr_pre, 16)):
                    cb = rd(fp_abs + cmd_off + 8 + i*8, 8)
                    c = _VMCmd(cb)
                    if c.bits(63, 3) == 1 and c.bits(60, 1) == 1:
                        op = c.bits(51, 4)
                        if op == 2:
                            n = c.bits(22, 7); tgt = tt_map.get(n)   # JumpTT: GLOBAL title
                            print(">>> First Play JumpTT %d -> global title %d -> VTS_%02d (vts_ttn=%d)"
                                  % (n, n, tgt[0], tgt[1]) if tgt else
                                  ">>> First Play JumpTT %d (not in TT_SRPT)" % n)
                            break
                        if op == 3:
                            # JumpVTS_TT: operand is a vts_ttn in the CURRENT VTS, which
                            # First Play (VMG domain) does not define without running the
                            # DVD-VM. NOT a global title -> cannot resolve from IFO alone.
                            print(">>> First Play JumpVTS_TT %d  (vts_ttn in the current VTS;"
                                  " needs DVD-VM state - not resolvable from the IFO tables)"
                                  % c.bits(22, 7))
                            break
    else:
        print("\nFirst Play: no VIDEO_TS.IFO record -> cannot read FP_PGC")

    # ==== MENU DOMAIN (Phase-2 disc menus) ====================================
    # Dumps every menu PGCI Unit Table exactly the way dvd_iso_reader's jump
    # path walks it: VMGM_PGCI_UT (VMGI@200, sector ptr) / VTSM_PGCI_UT
    # (VTSI@208, sector ptr) -> LU[0] (lang_start_byte u32 @LU+4, rel UT) ->
    # menu PGCIT (nr_srp@0, SRP[i]@8+8i {entry_id u8@0, pgc_start_byte u32@4})
    # -> PGC {cells@3, next/prev/goup@156/158/160, pg_playback_mode@162,
    # still_time@163, cmd_tbl@228, cell_playback@232}. Cell first/last are
    # 2048-RBNs relative to the DOMAIN's menu VOB (VIDEO_TS.VOB / VTS_xx_0.VOB).
    # Field offsets verified against libdvdread ifo_types.h/ifo_read.c 2026-07-07.
    ENTRY_TYPE = {2: "Title", 3: "Root", 4: "SubPic", 5: "Audio",
                  6: "Angle", 7: "Chapter"}

    def dump_menu_ut(label, ut_lba, menu_vob, want_entry):
        ut_abs = ut_lba * 2048
        nr_lus = struct.unpack('>H', rd(ut_abs, 2))[0]
        print("\n--- %s PGCI_UT @sector %d (nr_of_lus=%d) ---" % (label, ut_lba, nr_lus))
        if not (1 <= nr_lus < 100):
            print("  malformed nr_of_lus -> RTL jump would fail (pgc_error)"); return
        for li in range(nr_lus):
            lu = rd(ut_abs + 8 + li*8, 8)
            lu_start = struct.unpack('>I', lu[4:8])[0]
            print("  LU[%d]: lang=%s exists=0x%02x lang_start_byte=%d%s"
                  % (li, lu[0:2].decode('ascii', 'replace'), lu[3], lu_start,
                     "   <== RTL uses LU[0] unconditionally" if li == 0 else ""))
        lu0_start = struct.unpack('>I', rd(ut_abs + 8 + 4, 4))[0]
        pit_abs = ut_abs + lu0_start
        nr_srp = struct.unpack('>H', rd(pit_abs, 2))[0]
        print("  LU[0] menu PGCIT @UT+%d (in-sector off=%d): nr_srp=%d"
              % (lu0_start, pit_abs % 2048, nr_srp))
        pick = None                     # RTL jump pick: first entry match
        for i in range(min(nr_srp, 99)):
            srp = rd(pit_abs + 8 + i*8, 8)
            eid = srp[0]
            psb = struct.unpack('>I', srp[4:8])[0]
            pa  = pit_abs + psb
            h   = rd(pa, 234)
            nxt, prv, gup = struct.unpack('>HHH', h[156:162])
            mode, still   = h[162], h[163]
            cmd_off       = struct.unpack('>H', h[228:230])[0]
            pgc_off       = pa % 2048
            ent = (" ENTRY:%s" % ENTRY_TYPE.get(eid & 0xF, "?%d" % (eid & 0xF))) \
                  if (eid & 0x80) else ""
            if pick is None and (eid & 0x80) and (eid & 0xF) == want_entry:
                pick = i + 1
            print("  SRP[%d] = PGCN %d: entry_id=0x%02x%s  cells=%d next=%d prev=%d "
                  "goup=%d mode=0x%02x still=0x%02x  (pgc in-sector off=%d%s)"
                  % (i, i+1, eid, ent, h[3], nxt, prv, gup, mode, still, pgc_off,
                     # The RTL's Phase-1 "skip straddling PGCs" limitation is
                     # RETIRED (sector-crossing walker + rbuf shadow fetch, see
                     # docs/dvd_nav.md "Sector-straddle audit"): a PGC starting
                     # this late parses fine now. Kept as a note because it is
                     # still the interesting case to re-check after reader work.
                     " *straddles the sector boundary (walker handles it)*"
                     if pgc_off > 1816 else ""))
            dump_pgc_cmds("cmds", pa)
            cpo = struct.unpack('>H', h[232:234])[0]
            if cpo and h[3]:
                for cx in range(min(h[3], 32)):
                    e  = rd(pa + cpo + cx*24, 24)
                    fs = struct.unpack('>I', e[8:12])[0]
                    lv = struct.unpack('>I', e[16:20])[0]   # last_vobu_start_sector
                    ls = struct.unpack('>I', e[20:24])[0]
                    blk = ("  sd_blk=%d" % (menu_vob[0]*4 + fs*4)) if menu_vob else ""
                    # libdvdnav still heuristic (vm.c get_current_position 561-596):
                    eff, how = still_heuristic(e[2], still, cx == h[3]-1, fs, lv, ls, e[4:8])
                    hint = ("  *** HELD %ds (%s)" % (eff, how)) if eff else ""
                    print("    cell %d: RBN first=%d last=%d  still=%d cell_cmd=%d"
                          " pbtime=%ds%s%s"
                          % (cx, fs, ls, e[2], e[3], _bcd_secs(e[4:8]), blk, hint))
        print("  RTL jump pick (entry=%d%s): %s"
              % (want_entry, "/" + ENTRY_TYPE.get(want_entry, "?"),
                 ("PGCN %d" % pick) if pick else "no entry match -> fallback PGCN 1"))

    print("\n=== MENU DOMAIN (Phase-2 disc menus) ===")
    print("VMGM_VOBS (VIDEO_TS.VOB): %s"
          % ("lba=%d bytes=%d (sd base blk=%d)" % (vmgm_vob[0], vmgm_vob[1],
             vmgm_vob[0]*4) if vmgm_vob else "ABSENT"))
    if vmgi_lba is not None:
        vmgm_ut = struct.unpack('>I', sec(vmgi_lba)[200:204])[0]   # VMGI_MAT@200
        if vmgm_ut:
            dump_menu_ut("VMGM", vmgi_lba + vmgm_ut, vmgm_vob, want_entry=2)
        else:
            print("VMGM_PGCI_UT: absent (VMGI@200 = 0) -> no VMG menu")
    for vn in sorted(vts_ifo_lba):
        il = vts_ifo_lba[vn]
        ut = struct.unpack('>I', sec(il)[208:212])[0]              # VTSI_MAT@208
        mv = vtsm_vob.get(vn)
        print("\nVTS_%02d: VTSM_VOBS (VTS_%02d_0.VOB): %s   vtsm_pgci_ut(@208)=%d"
              % (vn, vn, ("lba=%d bytes=%d (sd base blk=%d)"
                 % (mv[0], mv[1], mv[0]*4)) if mv else "ABSENT", ut))
        if ut:
            dump_menu_ut("VTS_%02d VTSM" % vn, il + ut, mv, want_entry=3)
        else:
            print("  no VTSM PGCI_UT -> Menu key on this VTS falls back to VMGM")

    # ---- All-VTS PGCN-1 duration scan. The current core picks the VTS holding
    # TT_SRPT title 1; on some discs (e.g. Big Buck Bunny) that title is a short
    # license/special clip and the FEATURE is a different VTS. This scan shows
    # every VTS's PGCN-1 runtime so we can see whether a "longest title/PGC"
    # heuristic would land on the real movie. (Diagnostic only; RTL still v1.)
    print("\n--- all-VTS PGCN-1 duration scan (feature is usually the longest) ---")
    longest_vts = (0, None)   # (seconds, vtsn)
    for vn in sorted(vts_ifo_lba):
        il = vts_ifo_lba[vn]
        try:
            vm = sec(il)
            vp = struct.unpack('>I', vm[204:208])[0]
            if not (0 < vp <= 0xFFFFF): raise ValueError("vts_pgcit")
            pit = il + vp
            hdr = sec(pit)
            nsrp = struct.unpack('>H', hdr[0:2])[0]
            psb = struct.unpack('>I', hdr[12:16])[0]        # SRP[0].pgc_start_byte
            t4 = rd(pit*2048 + psb + 4, 4)                  # PGC.playback_time @4
            secs = dvd_secs(t4)
            mark = "  <- selected" if vn == sel else ""
            print("  VTS_%02d: nr_pgc=%d  PGCN1 time=%s  (%d s)%s"
                  % (vn, nsrp, dvd_time(t4), secs, mark))
            if secs > longest_vts[0]: longest_vts = (secs, vn)
        except Exception as e:
            print("  VTS_%02d: PGC parse error (%s)" % (vn, e))
    if longest_vts[1] is not None:
        print("longest PGCN-1 -> VTS_%02d (%d s)%s"
              % (longest_vts[1], longest_vts[0],
                 "  == selected (heuristic agrees)" if longest_vts[1] == sel
                 else "  != selected VTS_%02d  <-- 'longest title' would pick the FEATURE" % sel))

    # ---- PGC / cell timeline (Phase 7) + full VTS PGC diagnostic. Parse the
    # selected VTS's VTS_xx_0.IFO (VTSI_MAT -> VTS_PGCIT -> PGC) and dump: EVERY
    # PGC (playback time / cells) so the real feature (usually the longest PGC)
    # is visible, the VTS_PTT_SRPT TTN->PGC map (the CORRECT entry PGC for the
    # title), AND PGCN 1's cell list (what the core plays TODAY). All IFO fields
    # BIG-ENDIAN. Cell first/last are 2048-sector RBNs relative to VTSTT_VOBS
    # (= the title VOB start = exts[0][0]). Mirrors dvd_iso_reader v1 (PGCN 1).
    ifo_lba = vts_ifo_lba.get(sel)
    if ifo_lba is None:
        print("PGC: no VTS_%02d_0.IFO record -> core streams the VTS linearly" % sel)
        return
    mat = sec(ifo_lba)
    vts_pgcit    = struct.unpack('>I', mat[204:208])[0]     # VTSI_MAT.vts_pgcit    @204
    vts_ptt_srpt = struct.unpack('>I', mat[200:204])[0]     # VTSI_MAT.vts_ptt_srpt @200
    if not (0 < vts_pgcit <= 0xFFFFF):
        print("PGC: vts_pgcit out of range (%d) -> linear fallback" % vts_pgcit); return
    pgcit_lba = ifo_lba + vts_pgcit
    pgcit_abs = pgcit_lba*2048
    pgcit = sec(pgcit_lba)
    nr_srp = struct.unpack('>H', pgcit[0:2])[0]             # VTS_PGCIT.nr_of_pgci_srp @0
    if nr_srp == 0:
        print("PGC: nr_of_pgci_srp=0 -> linear fallback"); return
    base = exts[0][0]*4     # concatenated title-VOB 512-block base (VTSTT_VOBS)

    def pgc_info(pgcn):     # 1-based; returns (nr_programs, nr_cells, cell_pb_off, pgc_abs)
        srp = rd(pgcit_abs + 8 + (pgcn-1)*8, 8)
        pgc_start = struct.unpack('>I', srp[4:8])[0]        # SRP[i].pgc_start_byte @+4
        pa = pgcit_abs + pgc_start
        h = rd(pa, 234)
        return h[2], h[3], struct.unpack('>H', h[232:234])[0], pa, h[4:8]

    print("\n--- VTS_%02d PGC table (nr_of_pgci_srp=%d) ---" % (sel, nr_srp))
    longest = (0, 0)   # (total_sectors, pgcn)
    for i in range(1, nr_srp+1):
        try:
            nprog, ncell, cpo, pa, t4 = pgc_info(i)
        except Exception as e:
            print("  PGCN %d: parse error (%s)" % (i, e)); continue
        tot = 0; f0 = None
        for c in range(min(ncell, 128)):
            ent = rd(pa + cpo + c*24, 24)
            fs = struct.unpack('>I', ent[8:12])[0]
            ls = struct.unpack('>I', ent[20:24])[0]
            if f0 is None: f0 = fs
            tot += max(0, ls - fs + 1)
        print("  PGCN %2d: time=%s  programs=%d  cells=%d  ~%d sectors  first RBN=%s"
              % (i, dvd_time(t4), nprog, ncell, tot, f0))
        if tot > longest[0]: longest = (tot, i)

    # PGC palette @164 (16 x {0,Y,Cr,Cb}); PGCN 1 is what the RTL loads into
    # pgc_palette. Print YCbCr + the BT.601 studio-swing RGB the fabric derives
    # (298/409/100/208/516, >>8, clamp) so it doubles as a HW colour predictor.
    def ycc2rgb(Y, Cr, Cb):
        yt = max(0, Y - 16)
        clip = lambda v: 0 if v < 0 else (255 if v > 255 else v)
        r = clip((298*yt + 409*(Cr-128)) >> 8)
        g = clip((298*yt - 100*(Cb-128) - 208*(Cr-128)) >> 8)
        b = clip((298*yt + 516*(Cb-128)) >> 8)
        return r, g, b
    def dump_palette(pgcn):
        try:
            srp = rd(pgcit_abs + 8 + (pgcn-1)*8, 8)
            pgc_start = struct.unpack('>I', srp[4:8])[0]
            pa = pgcit_abs + pgc_start
            pgc_off = pgc_start % 2048          # RTL's pgc_off = pgc_start_byte & 0x7FF
            straddle = pgc_off > 1820           # RTL SKIPS the palette load if this is True
            pal = rd(pa + 164, 64)
            print("  PGCN %d palette @164  (pgc_off=%d%s):" %
                  (pgcn, pgc_off, "  *** RTL SKIPS palette (pgc_off>1820, straddle) -> "
                                  "subtitle uses the grayscale default -> looks white ***"
                                  if straddle else ""))
            line = "    "
            for e in range(16):
                Y, Cr, Cb = pal[e*4+1], pal[e*4+2], pal[e*4+3]
                r, g, b = ycc2rgb(Y, Cr, Cb)
                line += "%2d:#%02X%02X%02X(Y%3d Cr%3d Cb%3d) " % (e, r, g, b, Y, Cr, Cb)
                if e % 4 == 3:
                    print(line); line = "    "
        except Exception as ex:
            print("  PGCN %d palette parse error (%s)" % (pgcn, ex))

    # PGCN 1 is what the RTL loads today; also dump the LONGEST PGC (usually the
    # feature) in case the feature isn't PGCN 1 (the largest-VTS mispick discs).
    print("\n--- subpicture palette (Y Cr Cb -> BT.601 studio-swing RGB the fabric derives) ---")
    dump_palette(1)
    if longest[1] and longest[1] != 1:
        print("  (longest PGC = PGCN %d; if the on-screen feature is this one, its palette:)" % longest[1])
        dump_palette(longest[1])

    # VTS_PTT_SRPT: the CORRECT entry PGC for the title (deferred in RTL v1).
    entry_pgcn = None
    if 0 < vts_ptt_srpt <= 0xFFFFF and ifo_vts_ttn:
        ptt_abs = (ifo_lba + vts_ptt_srpt) * 2048
        nr_ttu = struct.unpack('>H', rd(ptt_abs, 2))[0]    # nr of titles in this VTS
        if 1 <= ifo_vts_ttn <= nr_ttu:
            off = struct.unpack('>I', rd(ptt_abs + 8 + (ifo_vts_ttn-1)*4, 4))[0]
            ptt0 = rd(ptt_abs + off, 4)                     # PTT[0] {pgcn u16, pgn u16}
            entry_pgcn = struct.unpack('>H', ptt0[0:2])[0]
        print("VTS_PTT_SRPT: title vts_ttn=%d -> ENTRY PGCN %s  (nr_titles_in_vts=%d)"
              % (ifo_vts_ttn, entry_pgcn, nr_ttu))
    else:
        print("VTS_PTT_SRPT: unavailable (ptr=%d, vts_ttn=%s)" % (vts_ptt_srpt, ifo_vts_ttn))

    print("longest PGC (by sectors) -> PGCN %d" % longest[1] if longest[1] else "no PGC cells")
    core_pgcn = 1
    print("CORE PLAYS: PGCN %d (v1 = first PGC).  entry-PGCN=%s  longest-PGCN=%s%s"
          % (core_pgcn, entry_pgcn, longest[1] if longest[1] else "?",
             "" if (entry_pgcn in (None, core_pgcn)) else "   <-- MISMATCH: core plays the wrong PGC"))

    # PGCN 1 cell list (what the core streams today, in program order).
    nprog, nr_cells, cell_pb_off, pgc_abs, _ = pgc_info(core_pgcn)
    if nr_cells == 0 or nr_cells > 128:
        print("PGCN 1: nr_of_cells=%d (0 or >128) -> core uses linear fallback" % nr_cells); return
    print("PGCN 1 program-order cell list (title VOB RBN base -> sd 512-block=%d):" % base)
    reordered = False; prev = -1
    for c in range(nr_cells):
        ent = rd(pgc_abs + cell_pb_off + c*24, 24)
        first = struct.unpack('>I', ent[8:12])[0]          # cell first_sector @+8
        last  = struct.unpack('>I', ent[20:24])[0]         # cell last_sector  @+20
        flag = ""
        if first < prev: reordered = True; flag = "  <-- earlier RBN than prev cell"
        prev = first
        print("  cell %2d: RBN first=%d last=%d  (%d sectors)  sd 512-block=%d%s"
              % (c, first, last, last-first+1, base + first*4, flag))
    print("*** cells are OUT OF PHYSICAL ORDER -> this disc EXERCISES the reorder path ***"
          if reordered else
          "cells are physically monotonic (continuous) -> cell-mode plays same order as linear")

    # ---- Phase-8 CHAPTER map: PGC program_map@230 -> entry cell -> RBN/sector.
    # program_map is nr_programs bytes; pmap[p] = entry cell # (1-based) of
    # program (chapter) p+1. Chapter skip in the reader = seek to that cell.
    # This is the golden reference bench/dvd/iso_reader_chapter_tb.sv checks.
    pgc_hdr = rd(pgc_abs, 232)
    pm_off = struct.unpack('>H', pgc_hdr[230:232])[0]        # program_map_offset @230
    print("PGC chapter (PTT) map: nr_programs=%d program_map_offset=%d" % (nprog, pm_off))
    if pm_off and 0 < nprog <= 99:
        pmap = rd(pgc_abs + pm_off, nprog)
        for p in range(nprog):
            entry_cell = pmap[p]                             # 1-based cell #
            ci = entry_cell - 1
            if 0 <= ci < nr_cells:
                ent = rd(pgc_abs + cell_pb_off + ci*24, 24)
                first = struct.unpack('>I', ent[8:12])[0]
                print("  chapter %2d -> cell %d (0-based %d)  RBN first=%d  sd 512-block=%d"
                      % (p+1, entry_cell, ci, first, base + first*4))
            else:
                print("  chapter %2d -> cell %d  (OUT OF RANGE)" % (p+1, entry_cell))
    else:
        print("  (no program_map / nr_programs out of range -> chapters unavailable)")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: iso_nav_check.py disc.iso"); sys.exit(1)
    main(sys.argv[1])
