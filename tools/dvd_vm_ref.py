#!/usr/bin/env python3
# dvd_vm_ref.py - GOLDEN MODEL for dvd/dvd_vm.sv (the Phase-4 DVD-VM interpreter).
#
# The command evaluator is a faithful port of libdvdnav src/vm/decoder.c
# (eval_command / vmEval_CMD and helpers), byte-for-byte in semantics:
# compare ops (incl. op 1 = bitwise AND), set-op clamping (add/mul clamp to
# 0xFFFF, sub clamps to 0, div/mod by zero => 0xFFFF), Goto/Break line flow,
# and the per-type cond/set/link ordering of the eval_command switch.
#
# ONE DELIBERATE DEVIATION: command types 5 and 6 use the vmcmd.c bit layout
# (if_version_5 / set_version_3) instead of decoder.c's if_version_4 /
# set_version_2. decoder.c itself marks its type-5/6 handling "FIXME: These
# are wrong. Need to be updated from vmcmd.c" (the same bits 51:48 are read
# as both the compare register and the set register there). Our Phase-2
# decode_vmcmd (a vmcmd.c port) validated on MiB/Matrix/T2 with zero
# unknown-bit warnings, so vmcmd.c's layout is what dvd_vm.sv freezes.
#
# The VM class above that mirrors libdvdnav vm.c process_command / play.c
# (play_PGC pre-commands, play_PGC_post, play_Cell_post cell commands,
# LinkRSM/CallSS resume, JumpTT via TT_SRPT, JumpSS via PGCI_UT entry scan)
# at the granularity dvd_vm.sv implements: cell-granular resume, no angle
# blocks, PTT ~= program (exact VTS_PTT_SRPT map = Phase 6). GPRM counter mode
# ticks via Regs.tick() (the DVD-game entropy path, see dvd/dvd_vm.sv); NVTMR
# (SPRM9) is stored but never fires (libdvdnav doesn't fire it either).
#
# Usage:
#   python3 tools/dvd_vm_ref.py selftest                # synthetic eval vectors
#   python3 tools/dvd_vm_ref.py selftest --emit         # + write tb fixtures
#   python3 tools/dvd_vm_ref.py boot disc.iso           # trace FP boot chain
#   python3 tools/dvd_vm_ref.py menu disc.iso VTS       # trace a Menu-key press
#   python3 tools/dvd_vm_ref.py press disc.iso VTS BTN  # menu + button activate
#
# The boot/menu traces are the golden reference for the dvd_vm_tb real-disc
# cases and for eyeballing against VLC behaviour on the same ISO.
import sys, os, struct, random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iso_nav_check import decode_vmcmd, _VMCmd   # the vmcmd.c pretty-printer

# =============================================================================
# Registers (vm_reset defaults from libdvdnav vm.c)
# =============================================================================
class Regs(object):
    def __init__(self):
        self.gprm      = [0] * 16
        self.gprm_mode = [0] * 16          # bit0 = counter mode (ticks via tick())
        self.sprm      = [0] * 24
        self.sprm[0]  = (ord('e') << 8) | ord('n')   # player menu language
        self.sprm[1]  = 15                 # ASTN  (15 = none selected)
        self.sprm[2]  = 62                 # SPSTN (62 = none selected)
        self.sprm[3]  = 1                  # AGLN
        self.sprm[4]  = 1                  # TTN
        self.sprm[5]  = 1                  # VTS_TTN
        self.sprm[6]  = 0                  # TT_PGCN
        self.sprm[7]  = 1                  # PTTN
        self.sprm[8]  = 1 << 10            # HL_BTNN
        self.sprm[12] = (ord('U') << 8) | ord('S')
        self.sprm[13] = 15                 # parental level
        self.sprm[14] = 0x100
        self.sprm[15] = 0x7CFC
        self.sprm[16] = (ord('e') << 8) | ord('n')
        self.sprm[18] = (ord('e') << 8) | ord('n')
        self.sprm[20] = 1

    def tick(self):
        """One elapsed second: counter-mode GPRMs +1 (16-bit wrap). Mirrors the
        RTL's idle-gated sec_tick (dvd_vm.sv) and libdvdnav's wall-clock GPRM
        counters (decoder.c get_GPRM). The ONLY entropy on a DVD player is real
        time -- Scene It harvests a counter GPRM into its question-selection
        index (g[14] += g[13]); without the tick every playthrough is identical.
        The selftest vectors never call this (sec_tick=0), so they are
        unaffected; it documents the reference behaviour for the entropy path."""
        for i in range(16):
            if self.gprm_mode[i] & 1:
                self.gprm[i] = (self.gprm[i] + 1) & 0xFFFF

def eval_reg(c, regs, r):
    if r & 0x80:
        return regs.sprm[r & 0x1F] if (r & 0x1F) < 24 else 0
    return regs.gprm[r & 0x0F]

def reg_or_data(c, regs, imm, start):
    if imm:
        return c.bits(start, 16)
    return eval_reg(c, regs, c.bits(start - 8, 8))

def reg_or_data_2(c, regs, imm, start):
    if imm:
        return c.bits(start - 1, 7)
    return regs.gprm[c.bits(start - 4, 4)]

def reg_or_data_3(c, regs, imm, start):   # vmcmd.c print_reg_or_data_3
    if imm:
        return c.bits(start, 16)
    return eval_reg(c, regs, c.bits(start, 8))

def compare(op, a, b):
    if op == 1: return (a & b) != 0
    if op == 2: return a == b
    if op == 3: return a != b
    if op == 4: return a >= b
    if op == 5: return a > b
    if op == 6: return a <= b
    if op == 7: return a < b
    return False

def if_v1(c, regs):
    op = c.bits(54, 3)
    if not op: return True
    return compare(op, eval_reg(c, regs, c.bits(39, 8)),
                   reg_or_data(c, regs, c.bits(55, 1), 31))

def if_v2(c, regs):
    op = c.bits(54, 3)
    if not op: return True
    return compare(op, eval_reg(c, regs, c.bits(15, 8)),
                   eval_reg(c, regs, c.bits(7, 8)))

def if_v3(c, regs):
    op = c.bits(54, 3)
    if not op: return True
    return compare(op, eval_reg(c, regs, c.bits(47, 8)),
                   reg_or_data(c, regs, c.bits(55, 1), 15))

def if_v4(c, regs):
    op = c.bits(54, 3)
    if not op: return True
    return compare(op, eval_reg(c, regs, c.bits(51, 4)),
                   reg_or_data(c, regs, c.bits(55, 1), 31))

def if_v5(c, regs):                        # vmcmd.c layout (types 5/6)
    op = c.bits(54, 3)
    if not op: return True
    if c.bits(60, 1):                      # set_immediate
        return compare(op, regs.gprm[c.bits(31, 8) & 0xF],
                       eval_reg(c, regs, c.bits(23, 8)))
    return compare(op, regs.gprm[c.bits(39, 8) & 0xF],
                   reg_or_data(c, regs, c.bits(55, 1), 31))

# LFSR16 (x^16+x^15+x^13+x^4+1, Fibonacci) - the RTL's rnd source. The golden
# model steps the same LFSR so rnd vectors match bit-exactly.
class Lfsr(object):
    def __init__(self, seed=0xACE1):
        self.v = seed
    def step(self):
        b = ((self.v >> 0) ^ (self.v >> 2) ^ (self.v >> 3) ^ (self.v >> 5)) & 1
        self.v = ((self.v >> 1) | (b << 15)) & 0xFFFF
        return self.v

def set_op(regs, op, reg, reg2, data, lfsr):
    g = regs.gprm
    if   op == 1: g[reg] = data & 0xFFFF
    elif op == 2:                              # swap
        g[reg2] = g[reg]
        g[reg]  = data & 0xFFFF
    elif op == 3: g[reg] = min(g[reg] + data, 0xFFFF)
    elif op == 4: g[reg] = max(g[reg] - data, 0)
    elif op == 5: g[reg] = min(g[reg] * data, 0xFFFF)
    elif op == 6: g[reg] = (g[reg] // data) if data else 0xFFFF
    elif op == 7: g[reg] = (g[reg] %  data) if data else 0xFFFF
    elif op == 8:                              # rnd: 1..data (RTL: (lfsr%data)+1)
        g[reg] = ((lfsr.step() % data) + 1) if data else 0
    elif op == 9:  g[reg] &= data
    elif op == 10: g[reg] |= data
    elif op == 11: g[reg] ^= data

def set_v1(c, regs, cond, lfsr):
    op = c.bits(59, 4)
    if op and cond:
        set_op(regs, op, c.bits(35, 4), c.bits(19, 4),
               reg_or_data(c, regs, c.bits(60, 1), 31), lfsr)

def set_v2(c, regs, cond, lfsr):
    op = c.bits(59, 4)
    if op and cond:
        set_op(regs, op, c.bits(51, 4), c.bits(35, 4),
               reg_or_data(c, regs, c.bits(60, 1), 47), lfsr)

def set_v3(c, regs, cond, lfsr):           # vmcmd.c layout (types 5/6)
    op = c.bits(59, 4)
    if op and cond:
        set_op(regs, op, c.bits(51, 4), c.bits(19, 4),
               reg_or_data_3(c, regs, c.bits(60, 1), 47), lfsr)

# link_t equivalents. (name, data1, data2, data3)
LINKSUB = {0: "LinkNoLink", 1: "LinkTopC", 2: "LinkNextC", 3: "LinkPrevC",
           5: "LinkTopPG", 6: "LinkNextPG", 7: "LinkPrevPG",
           9: "LinkTopPGC", 10: "LinkNextPGC", 11: "LinkPrevPGC",
           12: "LinkGoUpPGC", 13: "LinkTailPGC", 16: "LinkRSM"}

def link_subins(c, cond):
    button = c.bits(15, 6)
    linkop = c.bits(4, 5)                  # decoder.c: LOW 5 bits of byte 7
    if linkop > 0x10 or linkop not in LINKSUB:
        return None
    return (LINKSUB[linkop], button, 0, 0) if cond else None

def link_instruction(c, cond):
    op = c.bits(51, 4)
    if op == 1: return link_subins(c, cond)
    if op == 4: return ("LinkPGCN", c.bits(14, 15), 0, 0) if cond else None
    if op == 5: return ("LinkPTTN", c.bits(9, 10), c.bits(15, 6), 0) if cond else None
    if op == 6: return ("LinkPGN",  c.bits(6, 7),  c.bits(15, 6), 0) if cond else None
    if op == 7: return ("LinkCN",   c.bits(7, 8),  c.bits(15, 6), 0) if cond else None
    return None

def jump_instruction(c, cond):
    op = c.bits(51, 4)
    r = None
    if op == 1: r = ("Exit", 0, 0, 0)
    if op == 2: r = ("JumpTT",      c.bits(22, 7), 0, 0)
    if op == 3: r = ("JumpVTS_TT",  c.bits(22, 7), 0, 0)
    if op == 5: r = ("JumpVTS_PTT", c.bits(22, 7), c.bits(41, 10), 0)
    if op == 6:
        d = c.bits(23, 2)
        if d == 0: r = ("JumpSS_FP", 0, 0, 0)
        if d == 1: r = ("JumpSS_VMGM_MENU", c.bits(19, 4), 0, 0)
        if d == 2: r = ("JumpSS_VTSM", c.bits(30, 7), c.bits(38, 7), c.bits(19, 4))
        if d == 3: r = ("JumpSS_VMGM_PGC", c.bits(46, 15), 0, 0)
    if op == 8:
        d = c.bits(23, 2)
        if d == 0: r = ("CallSS_FP", c.bits(31, 8), 0, 0)
        if d == 1: r = ("CallSS_VMGM_MENU", c.bits(19, 4), c.bits(31, 8), 0)
        if d == 2: r = ("CallSS_VTSM", c.bits(19, 4), c.bits(31, 8), 0)
        if d == 3: r = ("CallSS_VMGM_PGC", c.bits(46, 15), c.bits(31, 8), 0)
    return r if (r and cond) else None

def system_set(c, regs, cond):
    op = c.bits(59, 4)
    if op == 1:                            # SetSTN -> SPRM 1/2/3
        for i in (1, 2, 3):
            if c.bits(63 - (2 + i) * 8, 1):
                data = reg_or_data_2(c, regs, c.bits(60, 1), 47 - i * 8)
                if cond:
                    regs.sprm[i] = data
    elif op == 2:                          # SetNVTMR (SPRM9/10) - stub, stored
        data  = reg_or_data(c, regs, c.bits(60, 1), 47)
        data2 = c.bits(23, 8)
        if cond:
            regs.sprm[9]  = data
            regs.sprm[10] = data2
    elif op == 3:                          # SetGPRMMD (mode is set even if !cond)
        data  = reg_or_data(c, regs, c.bits(60, 1), 47)
        data2 = c.bits(19, 4)
        if c.bits(23, 1): regs.gprm_mode[data2] |= 1
        else:             regs.gprm_mode[data2] &= ~1
        if cond:
            regs.gprm[data2] = data & 0xFFFF
    elif op == 6:                          # SetHL_BTNN -> SPRM8
        data = reg_or_data(c, regs, c.bits(60, 1), 31)
        if cond:
            regs.sprm[8] = data

def eval_command(b, regs, lfsr):
    """Returns (line, link): line>0 = Goto line (1-based), line==256 = Break,
    line==0 = continue; link != None terminates the block with that link."""
    c = _VMCmd(b)
    t = c.bits(63, 3)
    link = None
    line = 0
    if t == 0:
        cond = if_v1(c, regs)
        sop = c.bits(51, 4)
        if sop == 1 and cond: line = c.bits(7, 8)          # Goto
        if sop == 2 and cond: line = 256                   # Break
        if sop == 3:                                       # SetTmpPML + Goto
            if cond:
                regs.sprm[13] = c.bits(11, 4)
                line = c.bits(7, 8)
    elif t == 1:
        if c.bits(60, 1):
            cond = if_v2(c, regs)
            link = jump_instruction(c, cond)
        else:
            cond = if_v1(c, regs)
            link = link_instruction(c, cond)
    elif t == 2:
        cond = if_v2(c, regs)
        system_set(c, regs, cond)
        if c.bits(51, 4):
            link = link_instruction(c, cond)
    elif t == 3:
        cond = if_v3(c, regs)
        set_v1(c, regs, cond, lfsr)
        if c.bits(51, 4):
            link = link_instruction(c, cond)
    elif t == 4:                           # Set ALWAYS, Compare -> LinkSIns
        set_v2(c, regs, True, lfsr)
        cond = if_v4(c, regs)
        link = link_subins(c, cond)
    elif t == 5:                           # if (cond) { Set, LinkSIns }
        cond = if_v5(c, regs)
        set_v3(c, regs, cond, lfsr)
        link = link_subins(c, cond)
    elif t == 6:                           # if (cond) { Set }, LinkSIns ALWAYS
        cond = if_v5(c, regs)
        set_v3(c, regs, cond, lfsr)
        link = link_subins(c, True)
    # unknown type 7: Nop (decoder.c only warns)
    return line, link

def eval_block(cmds, regs, lfsr, fuse=4096, trace=None):
    """vmEval_CMD: run a command block; returns the terminating link or None
    (fell off the end). The RTL fuse is 4096 (decoder.c uses 100000)."""
    i = 0
    total = 0
    while i < len(cmds) and total < fuse:
        line, link = eval_command(cmds[i], regs, lfsr)
        if trace is not None:
            trace.append("    exec[%d]: %s" % (i, decode_vmcmd(cmds[i])))
        if link is not None:
            return link
        i = (line - 1) if line > 0 else (i + 1)
        total += 1
    return None

# =============================================================================
# ISO navigation (mirrors dvd_iso_reader's IFO walks)
# =============================================================================
DOM_FP, DOM_VMGM, DOM_VTSM, DOM_TT = 0, 1, 2, 3
DOM_NAME = {0: "FP", 1: "VMGM", 2: "VTSM", 3: "TT"}

class IsoNav(object):
    def __init__(self, path):
        self.f = open(path, 'rb')
        self._walk()

    def sec(self, n):
        self.f.seek(n * 2048)
        return self.f.read(2048)

    def rd(self, a, n):
        self.f.seek(a)
        return self.f.read(n)

    def _walk(self):
        lba = 16
        while True:
            d = self.sec(lba)
            assert d[1:6] == b'CD001', "not ISO9660"
            if d[0] == 1: break
            assert d[0] != 255, "no PVD"
            lba += 1
        root_lba = struct.unpack('<I', d[158:162])[0]
        root_len = struct.unpack('<I', d[166:170])[0]

        def walk(dlba, dlen):
            nsec = (dlen + 2047) // 2048
            buf = b''.join(self.sec(dlba + i) for i in range(nsec))
            out = []
            for s in range(nsec):
                p = s * 2048
                while p < s * 2048 + 2048:
                    rl = buf[p]
                    if rl == 0: break
                    ext = struct.unpack('<I', buf[p+2:p+6])[0]
                    dl  = struct.unpack('<I', buf[p+10:p+14])[0]
                    fl  = buf[p+25]; nl = buf[p+32]; nm = buf[p+33:p+33+nl]
                    out.append((nm.upper(), ext, dl, fl)); p += rl
            return out

        vts_dir = None
        for nm, ext, dl, fl in walk(root_lba, root_len):
            if nm.startswith(b'VIDEO_TS') and (fl & 2):
                vts_dir = (ext, dl)
        assert vts_dir, "no VIDEO_TS"

        self.vmgi_lba = None
        self.vts_ifo = {}
        self.groups = {}
        self.menu_vob = {}
        for nm, ext, dl, fl in walk(*vts_dir):
            if nm.startswith(b'VIDEO_TS.IFO'): self.vmgi_lba = ext
            if nm.startswith(b'VTS_') and nm[6:12] == b'_0.IFO':
                try: self.vts_ifo[int(nm[4:6])] = ext
                except ValueError: pass
            if nm.startswith(b'VTS_') and b'.VOB' in nm:
                try: vn = int(nm[4:6]); part = int(nm[7:8])
                except ValueError: continue
                if 1 <= part <= 9:
                    self.groups.setdefault(vn, []).append((ext, dl))
                elif part == 0:
                    self.menu_vob[vn] = (ext, dl)
        self.best_vts = max(self.groups.items(),
                            key=lambda kv: sum(d for _, d in kv[1]))[0] \
                        if self.groups else 0
        # best_menu_vts: the VTS with the largest VTS_xx_0.VOB (emu fallback)
        self.best_menu_vts = max(self.menu_vob.items(),
                                 key=lambda kv: kv[1][1])[0] if self.menu_vob else 0
        # TT_SRPT
        self.tt = {}
        if self.vmgi_lba is not None:
            mat = self.sec(self.vmgi_lba)
            tsp = struct.unpack('>I', mat[196:200])[0]
            self.fp_off = struct.unpack('>I', mat[132:136])[0]
            self.vmgm_ut = struct.unpack('>I', mat[200:204])[0]
            if 0 < tsp <= 0xFFFFF:
                tt = self.sec(self.vmgi_lba + tsp)
                for i in range(min(struct.unpack('>H', tt[0:2])[0], 99)):
                    e = tt[8 + i*12: 8 + i*12 + 12]
                    self.tt[i + 1] = (e[6], e[7])      # (vts, vts_ttn)

    def pgc(self, abs_byte):
        """Parse one PGC: header fields + command blocks + program map."""
        h = self.rd(abs_byte, 236)
        p = {"nr_pgms": h[2], "nr_cells": h[3],
             "next": struct.unpack('>H', h[156:158])[0] & 0xFF,
             "prev": struct.unpack('>H', h[158:160])[0] & 0xFF,
             "goup": struct.unpack('>H', h[160:162])[0] & 0xFF,
             "still": h[163],
             "cmd_off":  struct.unpack('>H', h[228:230])[0],
             "pm_off":   struct.unpack('>H', h[230:232])[0],
             "cell_off": struct.unpack('>H', h[232:234])[0],
             "pre": [], "post": [], "cellc": [], "pm": [], "cells": []}
        if p["cmd_off"]:
            ct = self.rd(abs_byte + p["cmd_off"], 8)
            npre, npost, ncell = struct.unpack('>HHH', ct[0:6])
            base = abs_byte + p["cmd_off"] + 8
            if npre + npost + ncell <= 255:
                p["pre"]   = [self.rd(base + i*8, 8) for i in range(npre)]
                p["post"]  = [self.rd(base + (npre+i)*8, 8) for i in range(npost)]
                p["cellc"] = [self.rd(base + (npre+npost+i)*8, 8) for i in range(ncell)]
        if p["pm_off"] and p["nr_pgms"]:
            p["pm"] = list(self.rd(abs_byte + p["pm_off"], p["nr_pgms"]))
        if p["cell_off"] and p["nr_cells"]:
            for i in range(p["nr_cells"]):
                e = self.rd(abs_byte + p["cell_off"] + i*24, 24)
                # C_PBTM (cell playback time) @4: BCD hh mm ss ff, byte7 top2=rate
                bcd = lambda b: (b >> 4) * 10 + (b & 0xF)
                secs = bcd(e[4]) * 3600 + bcd(e[5]) * 60 + bcd(e[6])
                p["cells"].append({"still": e[2], "cmd_nr": e[3], "pbtime": secs})
        return p

    def pgcit(self, dom, vts):
        """Return (list of (entry_id, pgc_abs)) for the domain's PGCIT."""
        if dom == DOM_TT:
            ifo = self.vts_ifo.get(vts)
            if ifo is None: return None
            ptr = struct.unpack('>I', self.rd(ifo*2048 + 204, 4))[0]
            if not ptr: return None
            pit_abs = (ifo + ptr) * 2048
        else:
            if dom == DOM_VMGM:
                if self.vmgi_lba is None or not self.vmgm_ut: return None
                ut_abs = (self.vmgi_lba + self.vmgm_ut) * 2048
            else:
                ifo = self.vts_ifo.get(vts)
                if ifo is None: return None
                ptr = struct.unpack('>I', self.rd(ifo*2048 + 208, 4))[0]
                if not ptr: return None
                ut_abs = (ifo + ptr) * 2048
            nr_lus = struct.unpack('>H', self.rd(ut_abs, 2))[0]
            if not (1 <= nr_lus < 100): return None
            lu0 = struct.unpack('>I', self.rd(ut_abs + 12, 4))[0]
            pit_abs = ut_abs + lu0
        nr_srp = struct.unpack('>H', self.rd(pit_abs, 2))[0]
        out = []
        # PGCN is a 15-bit DVD field and real discs DO exceed 255 PGCs per PGCIT
        # (Weakest Link VTS_02 = 1394). The old min(nr_srp, 99) cap silently hid
        # that from every tool built on IsoNav -- including the capacity audit
        # that was supposed to catch exactly this. Bound only by the spec.
        for i in range(min(nr_srp, 32767)):
            srp = self.rd(pit_abs + 8 + i*8, 8)
            out.append((srp[0], pit_abs + struct.unpack('>I', srp[4:8])[0]))
        return out

    def fp_pgc(self):
        if self.vmgi_lba is None or not self.fp_off: return None
        return self.pgc(self.vmgi_lba * 2048 + self.fp_off)

# =============================================================================
# The VM dispatcher (mirrors dvd_vm.sv + the reader's jump services)
# =============================================================================
ENTRY_ROOT = 3
FUSE = 4096

class VM(object):
    def __init__(self, nav, verbose=True):
        self.nav = nav
        self.regs = Regs()
        self.lfsr = Lfsr()
        self.dom = DOM_FP
        self.vts = 0
        self.pgcn = 0
        self.pgc = None
        self.cell = 0                       # 0-based (reader cur_cell)
        self.rsm = None                     # (vts, pgcn, cell, sprm4..8)
        # TRUE while the current menu was reached by pressing Menu FROM a title
        # (title -> CallSS VTSM Root). Only then does a second Menu press LinkRSM
        # back to the title (the movie menu<->title toggle). See dvd_vm.sv.
        self.came_via_menukey = False
        self.trace = []
        self.verbose = verbose
        self.fuse = 0
        self.stopped = False

    def log(self, s):
        self.trace.append(s)
        if self.verbose: print(s)

    # ---- reader jump services -------------------------------------------
    def _load_pgcn(self, dom, vts, pgcn, entry=None, ttn=None, pgn=None, cell=0):
        """The reader's generalized jump: load a PGC and run its PRE block.
        Returns False on pgc_error."""
        self.fuse += 1
        if self.fuse > 64:                  # jump-chain fuse (RTL: total 4096 ops)
            self.log("  !! jump-chain fuse blown")
            return False
        if dom == DOM_FP:
            pgc = self.nav.fp_pgc()
            if pgc is None: return False
            self.dom, self.vts, self.pgcn, self.pgc = DOM_FP, 0, 0, pgc
            self.log("  [reader] loaded FP PGC (cells=%d)" % pgc["nr_cells"])
            return self._run_pre()
        pit = self.nav.pgcit(dom, vts)
        if pit is None: return False
        if ttn is not None:                 # title-entry scan (entry bit7, low7=ttn)
            pick = None
            for i, (eid, _) in enumerate(pit):
                if (eid & 0x80) and (eid & 0x7F) == ttn:
                    pick = i + 1; break
            pgcn = pick if pick else 1
        elif pgcn == 0:                     # menu entry scan
            pick = None
            for i, (eid, _) in enumerate(pit):
                if (eid & 0x80) and (eid & 0x0F) == entry:
                    pick = i + 1; break
            pgcn = pick if pick else 1
        if pgcn < 1 or pgcn > len(pit):
            return False
        self.dom, self.vts, self.pgcn = dom, vts, pgcn
        self.pgc = self.nav.pgc(pit[pgcn - 1][1])
        if pgn and self.pgc["pm"] and pgn <= len(self.pgc["pm"]):
            cell = self.pgc["pm"][pgn - 1] - 1
        self.cell = cell if cell < max(self.pgc["nr_cells"], 1) else 0
        self.log("  [reader] loaded %s vts=%d PGCN %d (cells=%d, start cell %d)"
                 % (DOM_NAME[dom], vts, pgcn, self.pgc["nr_cells"], self.cell))
        if self.dom == DOM_TT:
            self.regs.sprm[6] = pgcn        # TT_PGCN
            self.came_via_menukey = False   # a title plays -> drop the toggle state
        return self._run_pre()

    def _run_pre(self):
        link = eval_block(self.pgc["pre"], self.regs, self.lfsr, FUSE, self.trace)
        if link is not None:
            return self._process(link)
        if self.pgc["nr_cells"] == 0:
            # 0-cell PGC whose pre fell through: dead end (RTL: pgc_error)
            self.log("  !! 0-cell PGC pre fell through -> pgc_error")
            return False
        self.log("  -> PLAYING %s vts=%d PGCN %d from cell %d"
                 % (DOM_NAME[self.dom], self.vts, self.pgcn, self.cell))
        return True

    def _run_post(self):
        link = eval_block(self.pgc["post"], self.regs, self.lfsr, FUSE, self.trace)
        if link is not None:
            return self._process(link)
        # post fell through -> authored next_pgcn (reader vm_adv policy)
        if self.pgc["next"] and self.pgc["next"] != 0:
            self.log("  [post fall-through] -> next_pgcn %d" % self.pgc["next"])
            return self._load_pgcn(self.dom, self.vts, self.pgc["next"])
        self.log("  [post fall-through] no next_pgcn -> hold/stop")
        self.stopped = True
        return True

    # ---- link/jump processing (vm.c process_command) --------------------
    def _btn(self, n):
        if n:
            self.regs.sprm[8] = n << 10
            self.log("    SPRM8 = button %d" % n)

    def _pg_of_cell(self, cell):
        pm = self.pgc["pm"]
        pg = 1
        for i, c1 in enumerate(pm):
            if cell >= c1 - 1: pg = i + 1
        return pg

    def _process(self, link):
        cmd, d1, d2, d3 = link
        self.log("  LINK %s %d %d %d" % (cmd, d1, d2, d3))
        if cmd == "LinkNoLink":
            self._btn(d1); return True
        if cmd == "LinkTopC":
            self._btn(d1)
            self.log("  -> REPLAY cell %d" % self.cell); return True
        if cmd == "LinkNextC":
            self._btn(d1); self.cell += 1
            if self.cell >= self.pgc["nr_cells"]: return self._run_post()
            self.log("  -> SEEK cell %d" % self.cell); return True
        if cmd == "LinkPrevC":
            self._btn(d1); self.cell = max(self.cell - 1, 0)
            self.log("  -> SEEK cell %d" % self.cell); return True
        if cmd in ("LinkTopPG", "LinkNextPG", "LinkPrevPG"):
            self._btn(d1)
            pg = self._pg_of_cell(self.cell)
            if cmd == "LinkNextPG": pg += 1
            if cmd == "LinkPrevPG": pg = max(pg - 1, 1)
            if pg > max(self.pgc["nr_pgms"], 1): return self._run_post()
            self.cell = (self.pgc["pm"][pg - 1] - 1) if self.pgc["pm"] else 0
            self.log("  -> SEEK cell %d (pg %d)" % (self.cell, pg)); return True
        if cmd == "LinkTopPGC":
            self._btn(d1)
            return self._load_pgcn(self.dom, self.vts, self.pgcn)
        if cmd in ("LinkNextPGC", "LinkPrevPGC", "LinkGoUpPGC"):
            self._btn(d1)
            n = {"LinkNextPGC": self.pgc["next"], "LinkPrevPGC": self.pgc["prev"],
                 "LinkGoUpPGC": self.pgc["goup"]}[cmd]
            if not n:
                self.log("  !! %s with no target -> stop" % cmd)
                self.stopped = True; return True
            return self._load_pgcn(self.dom, self.vts, n)
        if cmd == "LinkTailPGC":
            self._btn(d1)
            return self._run_post()
        if cmd == "LinkRSM":
            if self.rsm is None:
                self.log("  !! RSM without resume info -> stop")
                self.stopped = True; return True
            vts, pgcn, cell, saved = self.rsm
            for i in range(5): self.regs.sprm[4 + i] = saved[i]
            self._btn(d1)
            self.log("  -> RESUME TT vts=%d pgcn=%d cell=%d" % (vts, pgcn, cell))
            self.dom = DOM_TT
            return self._load_title(vts, pgcn=pgcn, cell=cell, run_pre=False)
        if cmd == "LinkPGCN":
            return self._load_pgcn(self.dom, self.vts, d1)
        if cmd == "LinkPTTN":                  # ptt ~= program (Phase-6 exact)
            self._btn(d2)
            pg = min(d1, max(self.pgc["nr_pgms"], 1))
            self.cell = (self.pgc["pm"][pg - 1] - 1) if self.pgc["pm"] else 0
            self.log("  -> SEEK cell %d (ptt~pg %d)" % (self.cell, pg)); return True
        if cmd == "LinkPGN":
            self._btn(d2)
            pg = min(d1, max(self.pgc["nr_pgms"], 1))
            if self.pgc["pm"] and pg <= len(self.pgc["pm"]):
                self.cell = self.pgc["pm"][pg - 1] - 1
            self.log("  -> SEEK cell %d (pg %d)" % (self.cell, pg)); return True
        if cmd == "LinkCN":
            self._btn(d2)
            self.cell = max(d1 - 1, 0)
            self.log("  -> SEEK cell %d" % self.cell); return True
        if cmd == "Exit":
            self.log("  -> EXIT (hold)"); self.stopped = True; return True
        if cmd == "JumpTT":
            t = self.nav.tt.get(d1)
            if not t: return False
            self.regs.sprm[4] = d1
            self.regs.sprm[7] = 1
            return self._load_title(t[0], ttn=t[1])
        if cmd == "JumpVTS_TT":
            self.regs.sprm[5] = d1
            self.regs.sprm[7] = 1
            return self._load_title(self.vts, ttn=d1)
        if cmd == "JumpVTS_PTT":               # ptt ~= program (Phase-6 exact)
            self.regs.sprm[5] = d1
            self.regs.sprm[7] = d2
            return self._load_title(self.vts, ttn=d1, pgn=d2)
        if cmd == "JumpSS_FP":
            return self._load_pgcn(DOM_FP, 0, 0)
        if cmd == "JumpSS_VMGM_MENU":
            return self._load_pgcn(DOM_VMGM, 0, 0, entry=d1)
        if cmd == "JumpSS_VTSM":
            vts = d1 if d1 else self.vts
            self.regs.sprm[5] = d2
            return self._load_pgcn(DOM_VTSM, vts, 0, entry=d3)
        if cmd == "JumpSS_VMGM_PGC":
            return self._load_pgcn(DOM_VMGM, 0, d1)
        if cmd.startswith("CallSS"):
            self._save_rsm(d2 if cmd != "CallSS_FP" else d1)
            if cmd == "CallSS_FP":
                return self._load_pgcn(DOM_FP, 0, 0)
            if cmd == "CallSS_VMGM_MENU":
                return self._load_pgcn(DOM_VMGM, 0, 0, entry=d1)
            if cmd == "CallSS_VTSM":
                return self._load_pgcn(DOM_VTSM, self.vts, 0, entry=d1)
            if cmd == "CallSS_VMGM_PGC":
                return self._load_pgcn(DOM_VMGM, 0, d1)
        self.log("  !! unhandled link %s" % cmd)
        return True

    def _save_rsm(self, rsm_cell):
        cell = (rsm_cell - 1) if rsm_cell else self.cell
        self.rsm = (self.vts, self.pgcn, cell,
                    [self.regs.sprm[4 + i] for i in range(5)])
        self.log("    RSM saved: vts=%d pgcn=%d cell=%d"
                 % (self.rsm[0], self.rsm[1], self.rsm[2]))

    def _load_title(self, vts, ttn=None, pgcn=None, pgn=None, cell=0, run_pre=True):
        self.dom = DOM_TT
        if pgcn is not None:
            pit = self.nav.pgcit(DOM_TT, vts)
            if pit is None or pgcn < 1 or pgcn > len(pit): return False
            self.vts, self.pgcn = vts, pgcn
            self.pgc = self.nav.pgc(pit[pgcn - 1][1])
            self.cell = cell
            self.regs.sprm[6] = pgcn
            self.log("  [reader] loaded TT vts=%d PGCN %d (cells=%d, cell %d)"
                     % (vts, pgcn, self.pgc["nr_cells"], cell))
            return self._run_pre() if run_pre else True
        return self._load_pgcn(DOM_TT, vts, 0, ttn=ttn, pgn=pgn)

    # ---- public events ---------------------------------------------------
    def boot(self):
        self.log("== BOOT: FP PGC ==")
        self.fuse = 0
        if not self._load_pgcn(DOM_FP, 0, 0):
            self.log("  FP failed -> fallback: title of largest VTS %d"
                     % self.nav.best_vts)
            return self._load_title(self.nav.best_vts, pgcn=1)
        return True

    def _menu_call_root(self):
        """menu_call(Root): jump to the Root menu with the VTSM->best_menu->VMGM
        fallback chain. Used by Menu-in-title AND (the TP_SW case) Menu-in-menu
        when we did NOT enter this menu via the Menu key."""
        if not self._load_pgcn(DOM_VTSM, self.vts, 0, entry=ENTRY_ROOT):
            self.log("  own VTSM failed -> best_menu_vts %d"
                     % self.nav.best_menu_vts)
            if not self._load_pgcn(DOM_VTSM, self.nav.best_menu_vts, 0,
                                   entry=ENTRY_ROOT):
                if not self._load_pgcn(DOM_VMGM, 0, 0, entry=2):
                    return self._process(("LinkRSM", 0, 0, 0))
        return True

    def menu_key(self):
        self.fuse = 0
        if self.dom == DOM_TT:
            self.log("== MENU key: CallSS VTSM root ==")
            self._save_rsm(0)
            self.came_via_menukey = True
            return self._menu_call_root()
        # Menu key while a menu is up. Only toggle back to the title (LinkRSM) if
        # we reached this menu via the Menu key; otherwise (TP_SW's authored game
        # menus, whose RSM points at the boot FP copyright/intro) re-invoke Root.
        if self.came_via_menukey and self.rsm is not None:
            self.log("== MENU key in a menu (toggle): RSM ==")
            return self._process(("LinkRSM", 0, 0, 0))
        self.log("== MENU key in a menu (no toggle): re-invoke Root ==")
        return self._menu_call_root()

    def button(self, cmd8, btn_n=None):
        self.log("== BUTTON activate: %s ==" % decode_vmcmd(cmd8))
        # Mirror dvd_vm.sv: activating button K durably latches it into SPRM8
        # (HL_BTNN = K << 10) BEFORE its command runs, so a dispatch PRE that
        # reads HL_BTNN (TP Star Wars "g15 = HL_BTNN; if g15==0x400 ...",
        # Atmosfear's GPRM jump table) sees the activated button, not the reset
        # default (button 1). Matches libdvdnav vm.c HL_BTNN_REG = data1 << 10.
        if btn_n is not None:
            self.regs.sprm[8] = btn_n << 10
        self.fuse = 0
        link = eval_block([cmd8], self.regs, self.lfsr, FUSE, self.trace)
        if link is not None:
            return self._process(link)
        return True

    def cell_cmd(self, n):
        if not self.pgc["cellc"] or n > len(self.pgc["cellc"]):
            return True
        self.log("== CELL command %d ==" % n)
        self.fuse = 0
        link = eval_block([self.pgc["cellc"][n - 1]], self.regs, self.lfsr,
                          FUSE, self.trace)
        if link is not None:
            return self._process(link)
        return True

    def pgc_end(self):
        self.log("== PGC END: post commands ==")
        self.fuse = 0
        return self._run_post()

    # ---- full-playback driver (mirrors the reader's cell/cell-cmd/post loop) --
    # boot() and the _process chain walk through PRE blocks and command-only
    # PGCs until a PGC actually PLAYS (pre falls through to cells). This driver
    # then does what the RTL reader does at *playback* granularity: play the
    # current cell, run its cell command (play_Cell_post), advance, and at the
    # last cell run the POST block (play_PGC_post) -- chaining until it parks on
    # an indefinite still, stops, or loops (a menu). The goal is a step-by-step
    # golden path to diff against the libdvdnav trace (the boot-ordering oracle).
    def run(self, max_steps=800):
        self.log("== RUN: full playback drive ==")
        if not self.boot():
            self.log(">>> boot failed"); return
        seen = []                           # (dom,vts,pgcn,cell) visit order
        for step in range(max_steps):
            if self.stopped:
                self.log(">>> STOPPED"); return
            cells = self.pgc["cells"]
            if not cells:
                # a PLAYING 0-cell PGC shouldn't happen (pre would have linked);
                # guard and run post.
                self.log("  [drive] 0-cell playing PGC -> post")
                self.fuse = 0
                if not self._run_post(): self.log(">>> post error"); return
                continue
            state = (self.dom, self.vts, self.pgcn, self.cell)
            if state in seen:
                self.log(">>> PARKED (loop) at %s vts=%d PGCN %d cell %d  <-- menu"
                         % (DOM_NAME[self.dom], self.vts, self.pgcn, self.cell))
                return
            seen.append(state)
            meta = cells[self.cell] if self.cell < len(cells) else {"still": 0, "cmd_nr": 0, "pbtime": 0}
            still, cmd_nr = meta["still"], meta["cmd_nr"]
            self.log("  [drive] %s vts=%d PGCN %d cell %d/%d still=%d cell_cmd=%d pb=%ds"
                     % (DOM_NAME[self.dom], self.vts, self.pgcn, self.cell,
                        self.pgc["nr_cells"], still, cmd_nr, meta.get("pbtime", 0)))
            if still == 0xFF:
                self.log(">>> PARKED (indefinite still) at %s vts=%d PGCN %d cell %d"
                         % (DOM_NAME[self.dom], self.vts, self.pgcn, self.cell))
                return
            before = (self.dom, self.vts, self.pgcn, self.pgc)
            # play_Cell_post: run the cell command (if any). A link takes over
            # (no auto-advance); a no-link cell cmd (e.g. SetGPRM) falls through.
            linked = False
            if cmd_nr and self.pgc["cellc"] and cmd_nr <= len(self.pgc["cellc"]):
                self.fuse = 0
                link = eval_block([self.pgc["cellc"][cmd_nr - 1]], self.regs,
                                  self.lfsr, FUSE, self.trace)
                if link is not None:
                    self.log("  [cell cmd %d]" % cmd_nr)
                    if not self._process(link):
                        self.log(">>> cell-cmd link error"); return
                    linked = True
            if linked and (self.dom, self.vts, self.pgcn, self.pgc) != before:
                continue                    # link changed PGC -> resume there
            # advance within the PGC; last cell -> POST
            self.cell += 1
            if self.cell >= self.pgc["nr_cells"]:
                self.fuse = 0
                if not self._run_post(): self.log(">>> post error"); return
        self.log(">>> step cap (%d) reached without parking" % max_steps)

# =============================================================================
# Self-test: synthetic eval vectors (committed fixture for dvd_vm_tb)
# =============================================================================
def _cmd(hexstr):
    return bytes.fromhex(hexstr.replace(' ', ''))

def selftest(emit=False):
    """Synthetic single-block programs with hand-checkable results. Each case:
    (name, [cmds], setup(regs), check(regs, link))."""
    cases = []

    # --- arithmetic + clamping (type 3: set_v1, reg@bits35:32, imm16@31:16)
    def t3(op, reg, imm):     # 0x30 | imm-flag(bit60 of byte0 -> 0x10), op in b0[3:0]? no:
        # type 3 layout: bits63:61=011, bit60=imm, bits59:56=op ->
        # byte0 = 0110_oooo | (imm<<4)... bit60 sits in byte0 bit4.
        b0 = (3 << 5) | (1 << 4) | op
        b  = bytes([b0, 0, 0, reg, (imm >> 8) & 0xFF, imm & 0xFF, 0, 0])
        return b
    cases.append(("mov",       [t3(1, 3, 0x1234)], None,
                  lambda r, l: r.gprm[3] == 0x1234))
    cases.append(("add_clamp", [t3(1, 3, 0xFFF0), t3(3, 3, 0x0020)], None,
                  lambda r, l: r.gprm[3] == 0xFFFF))
    cases.append(("sub_clamp", [t3(1, 3, 0x0010), t3(4, 3, 0x0020)], None,
                  lambda r, l: r.gprm[3] == 0))
    cases.append(("mul_clamp", [t3(1, 3, 0x0300), t3(5, 3, 0x0100)], None,
                  lambda r, l: r.gprm[3] == 0xFFFF))
    cases.append(("mul",       [t3(1, 3, 0x0012), t3(5, 3, 0x0034)], None,
                  lambda r, l: r.gprm[3] == 0x12 * 0x34))
    cases.append(("div",       [t3(1, 3, 1000),  t3(6, 3, 33)], None,
                  lambda r, l: r.gprm[3] == 1000 // 33))
    cases.append(("div0",      [t3(1, 3, 1000),  t3(6, 3, 0)], None,
                  lambda r, l: r.gprm[3] == 0xFFFF))
    cases.append(("mod",       [t3(1, 3, 1000),  t3(7, 3, 33)], None,
                  lambda r, l: r.gprm[3] == 1000 % 33))
    cases.append(("mod0",      [t3(1, 3, 1000),  t3(7, 3, 0)], None,
                  lambda r, l: r.gprm[3] == 0xFFFF))
    cases.append(("and",       [t3(1, 3, 0xF0F0), t3(9, 3, 0x3C3C)], None,
                  lambda r, l: r.gprm[3] == 0x3030))
    cases.append(("or",        [t3(1, 3, 0xF0F0), t3(10, 3, 0x0F0F)], None,
                  lambda r, l: r.gprm[3] == 0xFFFF))
    cases.append(("xor",       [t3(1, 3, 0xF0F0), t3(11, 3, 0xFFFF)], None,
                  lambda r, l: r.gprm[3] == 0x0F0F))
    cases.append(("rnd",       [t3(1, 5, 7), t3(8, 3, 6)], None,
                  lambda r, l: 1 <= r.gprm[3] <= 6))

    # --- Goto/Break flow (type 0)
    goto3  = _cmd("00 01 00 00 00 00 00 03")     # Goto 3
    brk    = _cmd("00 02 00 00 00 00 00 00")     # Break
    cases.append(("goto_skips", [goto3, t3(1, 4, 0xDEAD), t3(1, 5, 0x0055)], None,
                  lambda r, l: r.gprm[4] == 0 and r.gprm[5] == 0x55))
    cases.append(("break_stops", [brk, t3(1, 4, 0xDEAD)], None,
                  lambda r, l: r.gprm[4] == 0))

    # --- conditional Goto (type 0 + if_v1: reg@byte3, imm@bytes4-5)
    # if (g5 == 0x55) Goto 3: byte1 = imm-flag(bit55=0x80) | cmpop<<4 | Goto op
    cgoto = bytes([0x00, 0x80 | (2 << 4) | 1, 0, 5, 0x00, 0x55, 0, 4])
    cases.append(("cond_goto_taken",
                  [t3(1, 5, 0x55), cgoto, t3(1, 4, 0xDEAD), t3(1, 6, 0x66)], None,
                  lambda r, l: r.gprm[4] == 0 and r.gprm[6] == 0x66))
    cases.append(("cond_goto_not",
                  [t3(1, 5, 0x54), cgoto, t3(1, 4, 0xBEEF), brk, t3(1, 6, 0x66)], None,
                  lambda r, l: r.gprm[4] == 0xBEEF and r.gprm[6] == 0))

    # --- compare & (bitwise) - type 1 link: if (g5 & 0x0F00) LinkTopC btn 2
    andlink = bytes([0x10 | 0x01, (1 << 4) | 1, 0, 5, 0x0F, 0x00, 2 << 2, 1])
    # ^ type1(001), bit60=0 -> link, if_v1 op=1(&) imm... byte0 = 001_0_1000?
    # build precisely below instead:
    def t1_link_cond(op, reg, imm16, btn, linkop):
        b0 = (1 << 5) | (1 << 4)             # type 1, compare-imm flag (bit60=0? no)
        # type 1 LINK variant needs bit60=0; if_v1 imm flag is bit55 (byte1 bit7).
        b0 = (1 << 5)                        # 0010_0000
        b1 = 0x80 | (op << 4) | 0x01         # imm compare, link op 1 (subins)
        return bytes([b0, b1, 0, reg, (imm16 >> 8) & 0xFF, imm16 & 0xFF,
                      btn << 2, linkop])
    cases.append(("and_link_taken",
                  [t3(1, 5, 0x0800), t1_link_cond(1, 5, 0x0F00, 2, 1)], None,
                  lambda r, l: l == ("LinkTopC", 2, 0, 0)))
    cases.append(("and_link_not",
                  [t3(1, 5, 0x3000), t1_link_cond(1, 5, 0x0F00, 2, 1), brk], None,
                  lambda r, l: l is None))

    # --- SetSTN (type 2 system_set op1): audio=3, subpic=0x41, angle=1 (all imm).
    # byte0 = 010(type2) 1(imm) 0001(op1) = 0x51. Slots: audio@BYTE3 (set flag =
    # bit39 = byte3[7], value = bits(38,7)), subpic@byte4, angle@byte5.
    setstn = bytes([0x51, 0x00, 0x00, 0x83, 0xC1, 0x81, 0, 0])
    cases.append(("setstn",
                  [setstn], None,
                  lambda r, l: r.sprm[1] == 3 and r.sprm[2] == 0x41 and r.sprm[3] == 1))

    # --- SetHL_BTNN (system_set op 6, imm): SPRM8 = 0x0800 (button 2)
    sethl = bytes([0x56, 0x00, 0x00, 0x00, 0x08, 0x00, 0, 0])
    cases.append(("sethl", [sethl], None,
                  lambda r, l: r.sprm[8] == 0x0800))

    # --- type 2 set + link: SetHL_BTNN 0x0C00 , LinkPGCN 5
    sethl_link = bytes([0x56, 0x04, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x05])
    cases.append(("sethl_linkpgcn", [sethl_link], None,
                  lambda r, l: r.sprm[8] == 0x0C00 and l == ("LinkPGCN", 5, 0, 0)))

    # --- type 4: g9 = g9 + 1 ALWAYS, if (g9 >= 3) LinkTailPGC (the MiB loop shape)
    #   set_v2: op bits59:56=3(add), reg bits51:48=9, data=reg_or_data imm@47
    #   if_v4: op bits54:52... shares bits with set op! type4 layout:
    #   byte0 = 100_1_0011 (type4, imm set, op add) = 0x93; byte1 = cmp-imm(bit55)
    #   + cmpop(54:52) + reg(51:48): 1_100_1001 = 0xC9; bytes2-3 = set imm16 = 1;
    #   bytes4-5 = cmp imm16 = 3; byte6/7 = btn/linkop.
    t4loop = bytes([0x93, 0xC9, 0x00, 0x01, 0x00, 0x03, 0x00, 0x0D])
    def setup_t4(r): r.gprm[9] = 1
    cases.append(("t4_inc_below", [t4loop], setup_t4,
                  lambda r, l: r.gprm[9] == 2 and l is None))
    def setup_t4b(r): r.gprm[9] = 2
    cases.append(("t4_inc_hits", [t4loop], setup_t4b,
                  lambda r, l: r.gprm[9] == 3 and l == ("LinkTailPGC", 0, 0, 0)))

    # --- jump ops (type 1, bit60=1)
    jtt   = bytes([0x30, 0x02, 0x00, 0x00, 0x00, 0x42, 0, 0])   # JumpTT 66
    cases.append(("jumptt", [jtt], None,
                  lambda r, l: l == ("JumpTT", 66, 0, 0)))
    jss   = bytes([0x30, 0x06, 0x00, 0x02, 0x43, 0x83, 0, 0])
    # JumpSS VTSM: op6, dom bits23:22=2 -> byte5[7:6]=10; vts bits30:24=byte4[6:0];
    # title bits38:32=byte3 low7; menu bits19:16=byte5[3:0]
    jss   = bytes([0x30, 0x06, 0x00, 0x01, 0x02, 0x83, 0, 0])
    cases.append(("jumpss_vtsm", [jss], None,
                  lambda r, l: l == ("JumpSS_VTSM", 2, 1, 3)))
    cses  = bytes([0x30, 0x08, 0x00, 0x00, 0x05, 0x42, 0, 0])
    # CallSS VTSM: op8, dom byte5[7:6]=01? dom bits23:22 -> VTSM=2 -> 10;
    # menu bits19:16; rsm_cell bits31:24 = byte4
    cses  = bytes([0x30, 0x08, 0x00, 0x00, 0x05, 0x83, 0, 0])
    cases.append(("callss_vtsm", [cses], None,
                  lambda r, l: l == ("CallSS_VTSM", 3, 5, 0)))

    # run
    fails = 0
    vec_lines = []
    exp_lines = []
    for name, cmds, setup, check in cases:
        regs = Regs()
        lfsr = Lfsr()
        if setup: setup(regs)
        link = eval_block(cmds, regs, lfsr)
        ok = check(regs, link)
        print("%-18s %s   link=%s g3=%04x g4=%04x g5=%04x g9=%04x sprm8=%04x "
              "sprm1=%d sprm2=%d"
              % (name, "PASS" if ok else "FAIL", link, regs.gprm[3], regs.gprm[4],
                 regs.gprm[5], regs.gprm[9], regs.sprm[8], regs.sprm[1],
                 regs.sprm[2]))
        for i, cmd in enumerate(cmds):
            print("    [%d] %s   %s" % (i, cmd.hex(' '), decode_vmcmd(cmd)))
        if not ok: fails += 1
        if emit:
            # fixture: one line per case:
            #   name ncmds setup_g9 cmdbytes... : expected g3 g4 g5 g9 sprm1 sprm2 sprm8 link
            g9init = 0
            if setup:
                rr = Regs(); setup(rr); g9init = rr.gprm[9]
            lk = link if link else ("None", 0, 0, 0)
            vec_lines.append("%s %d %04x %s" % (
                name, len(cmds), g9init,
                " ".join(c.hex() for c in cmds)))
            exp_lines.append("%s %04x %04x %04x %04x %04x %04x %04x %s %d %d %d" % (
                name, regs.gprm[3], regs.gprm[4], regs.gprm[5], regs.gprm[9],
                regs.sprm[1], regs.sprm[2], regs.sprm[8],
                lk[0], lk[1], lk[2], lk[3]))
    print("\n%d/%d selftest cases pass" % (len(cases) - fails, len(cases)))
    if emit:
        base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "bench", "dvd", "test_vobs")
        with open(os.path.join(base, "vm_selftest_cmds.txt"), "w") as fh:
            fh.write("\n".join(vec_lines) + "\n")
        with open(os.path.join(base, "vm_selftest_expect.txt"), "w") as fh:
            fh.write("\n".join(exp_lines) + "\n")
        print("fixtures written to bench/dvd/test_vobs/vm_selftest_{cmds,expect}.txt")
    return fails == 0

# =============================================================================
def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    mode = sys.argv[1]
    if mode == "selftest":
        ok = selftest(emit="--emit" in sys.argv)
        sys.exit(0 if ok else 1)
    nav = IsoNav(sys.argv[2])
    vm = VM(nav)
    if mode == "boot":
        vm.boot()
    elif mode == "runboot":
        vm.run()
    elif mode == "menu":
        # simulate: boot -> (land wherever) -> force title vts -> Menu key
        vm.boot()
        if vm.dom != DOM_TT:
            vts = int(sys.argv[3]) if len(sys.argv) > 3 else nav.best_vts
            vm._load_title(vts, pgcn=1)
        vm.menu_key()
    elif mode == "press":
        # press <iso> <vts> <btn_cmd_hex> [btn_n]
        # btn_n (optional) = the activated button number; sets HL_BTNN like the
        # RTL latch so a HL_BTNN-reading dispatch resolves to the right button.
        vts = int(sys.argv[3]); btn_hex = sys.argv[4]
        btn_n = int(sys.argv[5]) if len(sys.argv) > 5 else None
        vm.boot()
        if vm.dom != DOM_TT:
            vm._load_title(vts, pgcn=1)
        vm.menu_key()
        vm.button(bytes.fromhex(btn_hex), btn_n)
    elif mode == "postend":
        vm.boot()
        vm.pgc_end()
    else:
        print("unknown mode %s" % mode); sys.exit(1)

if __name__ == "__main__":
    main()
