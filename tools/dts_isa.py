#!/usr/bin/env python3
"""dts_isa.py -- the DTS engine's sequencer: its instruction set, the assembler,
the ROM images, and the instruction-level emulator (docs/dts_decoder.md sec 10).

The fabric DTS decoder is a microcoded sequencer that runs the bitstream parse
and drives hardwired vector loops on one multiplier. This file is the executable
definition of that machine. The RTL must match the emulator instruction by
instruction (register writes, stores, PC) and word by word (PCM). The emulator's
vector ops call tools/dts_fixed.py's own functions, so the emulator is checked
against an independent model rather than against itself.

Instruction word, 40 bits:
    op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6] aux[5:0]
Registers r0..r15 are 16 bits, two's complement; r0 reads 0. r8..r15 carry the
vector ops' arguments.

    alu   rd, rs, rt        rd = rs FN rt                (FN in aux)
    alui  rd, rs, imm       rd = rs FN sext16(imm)
    ld    rd, imm[rs+rt]    rd = MEM[(rs + rt + imm) & 0xFFFF]
    st    rd, imm[rs+rt]    MEM[...] = rd
    get   rd, n             the next n bits (1..16), MSB first
    getr  rd, rt            the next rt bits (0..16)
    vlc   rd, imm[rs]       the Huffman symbol of book (rs + imm), signed
    b<c>  rs, rt, label     branch if rs <c> rt, c in eq ne lt ge (signed)
    b<c>i rs, k, label      ... against a signed 10-bit constant k
                            A taken branch to ERR_BASE + code (an error vector,
                            pc 2016..2047) is `err code`: the program refuses the
                            frame without a one-word stub per error code.
    jmp / call label, ret   (call stack depth 8)
    err   code              count the error code, drop the rest of the frame,
                            restart at the label FRAME
    vop   OP                run a vector op (args in r8..r15); the sequencer waits
    frame rd                wait for the next frame; rd = its length in bytes
    fend                    discard the rest of the frame
    bpos  rd                rd = bits consumed in this frame (low 16 bits)

Memory, 16-bit words: 0x0000-0x07FF the record RAM (2K x 16; the map ends at
REC_END); 0x1000-0x1FFF the constant ROM (read-only). Everything else belongs to
the vector ops.

The trace the RTL is scored against (Machine.trace, a list): one tuple
(kind, pc, addr, value) per event, in program order --
    kind 0  a register write      addr = the register, value 16 bits
    kind 1  a store               addr = the record address, value 16 bits
    kind 2  an XQ code extracted  addr = its index 0..7, value 24 bits (two's
                                  complement): the sequencer's code reader is
                                  scored here, before any dequantisation

Usage:
    tools/dts_isa.py --asm [--check]           # assemble dvd/dts/dts.uasm -> .mem files
    tools/dts_isa.py --run <file.dts> [--frames N]   # emulate vs tools/dts_fixed.py
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dts_ref as R      # noqa: E402
import dts_fixed as F    # noqa: E402
import dts_tables as T   # noqa: E402

REPO = os.path.dirname(HERE)
UASM = os.path.join(REPO, 'dvd', 'dts', 'dts.uasm')
UMEM = os.path.join(REPO, 'dvd', 'dts', 'engine_ucode.mem')    # the programs (DTS, AC-3, MP2)
CMEM = os.path.join(REPO, 'dvd', 'dts', 'engine_const.mem')
HMEM = os.path.join(REPO, 'dvd', 'dts', 'dts_huff_lo.mem')      # nodes 0..2047
HMEM_HI = os.path.join(REPO, 'dvd', 'dts', 'dts_huff_hi.mem')   # nodes 2048..: see huff_mem_words
RMEM = os.path.join(REPO, 'dvd', 'dts', 'dts_hroot.mem')
USVH = os.path.join(REPO, 'dvd', 'dts', 'dts_ucode.svh')
VDIR = os.path.join(REPO, 'dvd', 'dts')

OPS = ['nop', 'alu', 'alui', 'ld', 'st', 'get', 'getr', 'vlc', 'br', 'bri', 'jmp', 'call',
       'ret', 'err', 'vop', 'frame', 'fend', 'bpos']
OP = {n: i for i, n in enumerate(OPS)}
FNS = ['add', 'sub', 'and', 'or', 'xor', 'shl', 'sar', 'shr', 'slt', 'sltu', 'seq', 'sne',
       'min', 'max']
FN = {n: i for i, n in enumerate(FNS)}
CONDS = ['eq', 'ne', 'lt', 'ge']
VOPS = ['xclr', 'xq', 'xvq', 'adpcm', 'joint', 'bfly', 'mixsyn', 'hclr', 'cnt']
VOP = {n: i for i, n in enumerate(VOPS)}
VOP['rclr'] = 28                  # shared with MP2 (tools/mp2_isa.py): zero the ring and b2
MEM_REC, MEM_CONST = 0x0000, 0x1000
REC_WORDS = 0x0800
STACK_DEPTH = 8
# error vectors: a taken branch to ERR_BASE + code is err. The top 32 words of the
# shared 2K microcode ROM: DTS's program sits at 0 and AC-3's after it
# (tools/ac3_isa.py), so the vectors must clear both.
ERR_BASE = 0x7E0
UC_DEPTH = 0x800
NCH_MAX = 5                       # primary channels (AMODE < 10)

# Counters the CNT op and the engine keep (telemetry ids)
CNT_DMIX_IGNORED = 0
CNT_DYNF = 1                      # DTS frames whose header sets DYNF (issue #189)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def encode(op, rd=0, rs=0, rt=0, imm=0, aux=0):
    return (OP[op] << 34) | ((rd & 15) << 30) | ((rs & 15) << 26) | ((rt & 15) << 22) | \
        ((imm & 0xFFFF) << 6) | (aux & 63)


def decode(w):
    return (OPS[(w >> 34) & 63], (w >> 30) & 15, (w >> 26) & 15, (w >> 22) & 15,
            (w >> 6) & 0xFFFF, w & 63)


# ------------------------------------------------------------------ Huffman ROM
# Book ids: every core codebook in tools/dts_tables.py order. The bit-allocation,
# transient and scale books are the sequencer's (`vlc`); the quantiser-index books
# are XQ's, found through QBOOK[abits-1] + selector.
BOOKS = list(T.VLC)
BOOK_ID = {n: i for i, n in enumerate(BOOKS)}
QBOOK = [BOOK_ID[f'quant_index_{a}_0'] for a in range(R.CODE_BOOKS)]


def build_huff_tree():
    """-> (nodes, roots). nodes[i] = (left, right); an entry is (leaf, value):
    leaf=1 -> value is the symbol; leaf=0 -> value is the child node index. The
    RTL walks it one code bit per step (53 of the 62 books are not canonical)."""
    nodes, roots = [], []
    for name in BOOKS:
        root = len(nodes)
        nodes.append([None, None])
        for code, ln, sym in T.VLC[name]['codes']:
            n = root
            for k in range(ln - 1, -1, -1):
                bit = (code >> k) & 1
                if k == 0:
                    assert nodes[n][bit] is None
                    nodes[n][bit] = (1, sym)
                else:
                    if nodes[n][bit] is None:
                        nodes.append([None, None])
                        nodes[n][bit] = (0, len(nodes) - 1)
                    n = nodes[n][bit][1]
        roots.append(root)
    assert all(e is not None for nd in nodes for e in nd), 'a codebook is incomplete'
    return nodes, roots


HUFF_NODES, HUFF_ROOTS = build_huff_tree()


def huff_mem_words():
    """18-bit node words: {right(9), left(9)}; an entry = {leaf, value[7:0]}. A leaf's
    value is the signed symbol; an internal entry's is the child's offset FORWARD from
    this node (child index - node index, 1..255). Every child follows its parent in
    build order (offsets 1..118 measured), so 8 bits hold both. The 2,647 nodes are
    split into two ROMs, 2,048 (2K x 5 mode, 4 M10K) and the rest (1K x 10, 2 M10K):
    6 blocks with a 2:1 output mux. 26-bit absolute entries in one ROM took 13 (Quartus
    put 2,647 words in 4K x 2 mode); one 18-bit ROM sliced 512 deep took 6 but a 6:1
    mux of 40 ALMs. The book roots stay absolute (dts_hroot.mem)."""
    out = []
    for n, (left, right) in enumerate(HUFF_NODES):
        def ent(e):
            leaf, v = e
            if leaf:
                assert -128 <= v <= 127, v
                return (1 << 8) | (v & 0xFF)
            off = v - n
            assert 1 <= off <= 255, (n, v)
            return off
        out.append((ent(right) << 9) | ent(left))
    assert len(out) <= 2048 + 1024, 'dts_seq.sv holds 2,048 + 1,024 nodes'
    # decode the image back, the way the RTL walks it, and compare every code
    for b, book in enumerate(BOOKS):
        for code, ln, sym in T.VLC[book]['codes']:
            n = HUFF_ROOTS[b]
            for k in range(ln - 1, -1, -1):
                e = (out[n] >> (9 if (code >> k) & 1 else 0)) & 0x1FF
                if e >> 8:
                    assert k == 0 and ((e & 0xFF) ^ 0x80) - 0x80 == sym, (book, code)
                    break
                n += e & 0xFF
    return out


# ------------------------------------------------------------------ constant ROM
def build_const():
    words, base = [], {}

    def put(name, vals):
        base[name] = MEM_CONST + len(words)
        words.extend(v & 0xFFFF for v in vals)
    put('SEL_NBITS', T.QUANT_INDEX_SEL_NBITS)
    put('GROUP_SIZE', T.QUANT_INDEX_GROUP_SIZE)
    put('CHANNELS', T.CHANNELS)
    put('BPS', T.BITS_PER_SAMPLE)
    put('DMIX_NCH', T.DMIX_PRIMARY_NCH)
    # the primary-channel index of L, R, Ls, Rs in each AMODE (-1 if absent)
    for name, spk in (('IDX_L', R.SPK_L), ('IDX_R', R.SPK_R),
                      ('IDX_LS', R.SPK_LS), ('IDX_RS', R.SPK_RS)):
        put(name, [R.PRM_CH_TO_SPKR[a].index(spk) if spk in R.PRM_CH_TO_SPKR[a] else -1
                   for a in range(10)])
    return words, base


CONST, CBASE = build_const()


# ------------------------------------------------------------------ assembler
class AsmError(Exception):
    pass


def _reg(tok, aliases):
    tok = aliases.get(tok.strip().lower(), tok.strip().lower())
    m = re.fullmatch(r'r(\d+)', tok)
    if not m or int(m.group(1)) > 15:
        raise AsmError(f'not a register: {tok!r}')
    return int(m.group(1))


def _is_reg(tok, aliases):
    tok = aliases.get(tok.strip().lower(), tok.strip().lower())
    return re.fullmatch(r'r\d+', tok) is not None


def assemble(text, mutate=None, vops=None, cbase=None, extra_equ=None, org=0):
    """-> (words, labels, line numbers). `mutate`: a name; a line carrying
    `;MUT <name>: <instruction>` assembles that instruction instead (the RED arms
    of tools/test_dts_isa.py live beside the code they break)."""
    # vops / cbase / extra_equ: another program on the same machine (tools/ac3_isa.py)
    # names its own vector ops (numbered after DTS's: one engine, one op space), its
    # constant ROM, and its own equates
    vop_map = VOP if vops is None else vops
    equ = {'C_' + k: v for k, v in (CBASE if cbase is None else cbase).items()}
    equ.update({'B_' + n.upper(): i for n, i in BOOK_ID.items()})
    equ.update({'V_' + n.upper(): i for n, i in vop_map.items()})
    equ['CNT_DMIX_IGNORED'] = CNT_DMIX_IGNORED
    equ['CNT_DYNF'] = CNT_DYNF
    equ['ERRV'] = ERR_BASE
    equ.update(extra_equ or {})
    aliases, labels, stmts = {}, {}, []
    mutated = False
    for ln, raw in enumerate(text.splitlines(), 1):
        mm = re.search(r';\s*MUT\s+(\w+)\s*:\s*(.*)$', raw)
        line = raw
        if mm and mutate == mm.group(1):
            line = re.sub(r'^(\s*(?:[A-Za-z_][\w.]*:\s*)*).*$', lambda m_: m_.group(1) + mm.group(2), raw)
            mutated = True
        line = re.sub(r';.*', '', line).strip()
        if not line:
            continue
        while True:
            m = re.match(r'([A-Za-z_][\w.]*):\s*(.*)$', line)
            if not m:
                break
            if m.group(1) in labels:
                raise AsmError(f'line {ln}: label {m.group(1)} twice')
            labels[m.group(1)] = org + len(stmts)
            line = m.group(2).strip()
        if not line:
            continue
        if line.startswith('.equ'):
            _, name, val = line.split(None, 2)
            equ[name] = int(eval(val, {'__builtins__': {}}, dict(equ)))
            continue
        if line.startswith('.reg'):
            _, name, reg = line.split(None, 2)
            aliases[name.lower()] = reg.strip().lower()
            continue
        stmts.append((ln, line, dict(aliases)))
    if mutate and not mutated:
        raise AsmError(f'no MUT {mutate} in the source')
    if org + len(stmts) > ERR_BASE:
        raise AsmError(f'words {org}..{org + len(stmts) - 1} reach the error vectors at {ERR_BASE}')

    def ev(expr, ln):
        env = dict(equ)
        env.update(labels)
        try:
            return int(eval(expr, {'__builtins__': {}}, env))
        except Exception as e:
            raise AsmError(f'line {ln}: cannot evaluate {expr!r} ({e})')

    words = []
    for ln, line, al in stmts:
        m = re.match(r'(\w+)\s*(.*)$', line)
        mn, rest = m.group(1).lower(), m.group(2)
        args = [a.strip() for a in re.split(r',(?![^\[]*\])', rest)] if rest else []

        def reg(i):
            return _reg(args[i], al)

        def memref(s):
            m2 = re.fullmatch(r'(.*?)\s*\[([^\]]*)\]', s)
            if not m2:
                return ev(s, ln), 0, 0
            imm = ev(m2.group(1), ln) if m2.group(1).strip() else 0
            rr = [r.strip() for r in m2.group(2).split('+')]
            ra = _reg(rr[0], al) if rr and rr[0] else 0
            rb = _reg(rr[1], al) if len(rr) > 1 else 0
            return imm, ra, rb
        try:
            if mn in FN:
                if _is_reg(args[2], al):
                    words.append(encode('alu', reg(0), reg(1), reg(2), 0, FN[mn]))
                else:
                    words.append(encode('alui', reg(0), reg(1), 0, ev(args[2], ln), FN[mn]))
            elif mn.endswith('i') and mn[:-1] in FN:
                words.append(encode('alui', reg(0), reg(1), 0, ev(args[2], ln), FN[mn[:-1]]))
            elif mn == 'li':
                words.append(encode('alui', reg(0), 0, 0, ev(args[1], ln), FN['add']))
            elif mn == 'mov':
                words.append(encode('alu', reg(0), reg(1), 0, 0, FN['add']))
            elif mn in ('ld', 'st'):
                imm, ra, rb = memref(args[1])
                words.append(encode(mn, reg(0), ra, rb, imm))
            elif mn == 'get':
                n = ev(args[1], ln)
                if not 1 <= n <= 16:
                    raise AsmError(f'line {ln}: get {n} bits')
                words.append(encode('get', reg(0), 0, 0, n))
            elif mn == 'getr':
                words.append(encode('getr', reg(0), 0, reg(1)))
            elif mn == 'vlc':
                imm, ra, _ = memref(args[1])
                words.append(encode('vlc', reg(0), ra, 0, imm))
            elif mn[:1] == 'b' and mn[1:3] in CONDS and len(mn) == 3:
                words.append(encode('br', CONDS.index(mn[1:3]), reg(0), reg(1), ev(args[2], ln)))
            elif mn[:1] == 'b' and mn[1:3] in CONDS and mn[3:] == 'i':
                c = ev(args[1], ln)
                if not -512 <= c <= 511:
                    raise AsmError(f'line {ln}: branch constant {c} outside -512..511')
                c &= 0x3FF
                words.append(encode('bri', CONDS.index(mn[1:3]), reg(0), c >> 6,
                                    ev(args[2], ln), c & 63))
            elif mn in ('jmp', 'call'):
                tgt = ev(args[0], ln)
                if tgt >= ERR_BASE:
                    raise AsmError(f'line {ln}: {mn} to an error vector (only branches may)')
                words.append(encode(mn, 0, 0, 0, tgt))
            elif mn in ('ret', 'fend', 'nop'):
                words.append(encode(mn))
            elif mn == 'err':
                words.append(encode('err', 0, 0, 0, ev(args[0], ln)))
            elif mn == 'vop':
                words.append(encode('vop', 0, 0, 0, 0, vop_map[args[0].lower()]))   # op in aux
            elif mn in ('frame', 'bpos'):
                words.append(encode(mn, reg(0)))
            else:
                raise AsmError(f'line {ln}: unknown instruction {mn!r}')
        except (IndexError, KeyError) as e:
            raise AsmError(f'line {ln}: bad operands in {line!r} ({e})')
    return words, labels, [ln for ln, _, _ in stmts]


# ------------------------------------------------------------------ emulator
class NeedFrame(Exception):
    pass


class EngineError(Exception):
    pass


# Cycle model, CALIBRATED ON THE RTL (bench/dvd/run_dts.sh, dts_top_tb +opstats,
# 2026-10-02): the sequencer's instructions as dvd/dts/dts_seq.sv takes them, and
# each vector op's start-to-done time as dvd/dts/dts_vec.sv takes it. It replaces
# P1a's estimate (which charged the IMDCT 300 cycles; the RTL's program takes ~620).
#   get n      n + 2          vlc        code bits + 3     ld 2, others 1
#   frame      2              fend/err   + 2 a byte drained (the bench's byte rate)
#   vop        2 + the op (vop_start is registered: the op begins a cycle later):
#     XCLR 1,284; HCLR 4 + 4 a band cleared; JOINT 14; BFLY 1,027; CNT 2
#     XQ    the code reading, held at its first code until the engine's setup is done
#           (12 cycles for a Huffman band, which adjusts its scale; else 10), + 3:
#           Huffman 1 + the code bits; block codes 4 x their bits (the first digit
#           divided as the bits arrive, three more in place); raw codes their bits
#     XVQ   16 + the codebook latency; ADPCM 12 unpredicted, 47 + max(5, latency + 3)
#     MIXSYN 96 + 2 x (32 x channels + 1,131): per side the mix, the IMDCT program
#           (597 terms + its stage barriers), the window (512 MACs); then 32 pairs
#           out, 3 cycles each (L and R share one RAM read port)
CYC = {
    'instr': 1, 'ld': 2, 'get': 2, 'vlc': 3, 'frame': 2, 'drain_byte': 2,
    'xclr': 1284, 'hclr': 4, 'hclr_band': 4, 'joint': 14, 'bfly': 1027, 'cnt': 2,
    'vop': 2, 'xq_setup': 10, 'xq_setup_huff': 12, 'xq_tail': 3, 'xvq': 16,
    'adpcm_plain': 12, 'adpcm_pred': 47,
    'mixsyn': 96, 'mixsyn_side': 1131, 'rclr': 2048 + 3,
}
CB_LATENCY = 20       # the codebook port's request-to-row latency (cycles), P2 measures it


class Machine:
    """The sequencer and its vector ops. feed(frame) then run(): it runs until the
    program waits for the next frame. PCM pairs land in self.pcm (L, R lists)."""

    def __init__(self, words, labels):
        self.prog = words
        self.labels = labels
        self.reg = [0] * 16
        self.pc = labels.get('RESET', 0)
        self.stack = []
        self.rec = [0] * REC_WORDS
        self.frames = []          # queued frames
        self.cur = None
        self.bitpos = 0
        self.overrun = 0
        # vector state
        self.X = [[[0] * 8 for _ in range(32)] for _ in range(NCH_MAX)]
        self.hist = [[[0] * 4 for _ in range(32)] for _ in range(NCH_MAX)]
        self.synth = [R.SynthFixed(), R.SynthFixed()]
        self.pcm = ([], [])
        self.counters = {}
        self.errors = {}
        self.cycles = 0
        self.frame_cycles = []
        self.lenient = 0
        self.by_cat = {}          # cycles by vector op; the rest is the sequencer
        self.cb_latency = CB_LATENCY
        self.trace = None        # a list to receive (kind, pc, addr, value): module doc
        self.vop_hook = None     # called as vop_hook(machine, op) after every vector op
        self.pc_prof = None      # a dict: cycles by pc (profiling)

    # -- input ------------------------------------------------------------
    def feed(self, data):
        self.frames.append(bytes(data))

    def bits(self, n):
        if n == 0:
            return 0
        v = 0
        for _ in range(n):
            byte = self.bitpos >> 3
            if byte < len(self.cur):
                b = (self.cur[byte] >> (7 - (self.bitpos & 7))) & 1
            else:
                b = 0
                self.overrun += 1
            v = (v << 1) | b
            self.bitpos += 1
        self.cycles += n
        return v

    def sbits(self, n):
        v = self.bits(n)
        return v - (1 << n) if n and v >> (n - 1) else v

    def vlc(self, book):
        """The tree walk the RTL does: one code bit per step."""
        n = HUFF_ROOTS[book]
        while True:
            leaf, val = HUFF_NODES[n][self.bits(1)]
            if leaf:
                return val
            n = val

    # -- memory --------------------------------------------------------------
    def load(self, a):
        a &= 0xFFFF
        if a < REC_WORDS:
            return s16(self.rec[a])
        const = getattr(self, 'const', CONST)
        if MEM_CONST <= a < MEM_CONST + len(const):
            return s16(const[a - MEM_CONST])
        raise EngineError(f'load from 0x{a:04x} at pc {self.pc}')

    def store(self, a, v):
        a &= 0xFFFF
        if a >= REC_WORDS:
            raise EngineError(f'store to 0x{a:04x} at pc {self.pc}')
        self.rec[a] = v & 0xFFFF
        if self.trace is not None:
            self.trace.append((1, self.pc, a, v & 0xFFFF))

    @staticmethod
    def alu(fn, a, b):
        f = FNS[fn]
        return {
            'add': lambda: a + b, 'sub': lambda: a - b, 'and': lambda: a & b,
            'or': lambda: a | b, 'xor': lambda: a ^ b, 'shl': lambda: a << (b & 15),
            'sar': lambda: a >> (b & 15), 'shr': lambda: (a & 0xFFFF) >> (b & 15),
            'slt': lambda: int(a < b), 'sltu': lambda: int((a & 0xFFFF) < (b & 0xFFFF)),
            'seq': lambda: int(a == b), 'sne': lambda: int(a != b),
            'min': lambda: min(a, b), 'max': lambda: max(a, b),
        }[f]()

    def setr(self, rd, v):
        if rd:
            self.reg[rd] = s16(v)
            if self.trace is not None:
                self.trace.append((0, self.pc, rd, self.reg[rd] & 0xFFFF))

    # -- vector ops ----------------------------------------------------------
    def vop(self, op):
        a = [self.reg[i] for i in range(8, 16)]
        name = VOPS[op] if op < len(VOPS) else {VOP['rclr']: 'rclr'}[op]
        c0, b0 = self.cycles, self.bitpos
        op_t = 0
        if name == 'rclr':                # the rings and carried sums; the offsets stay
            for s in self.synth:
                s.buf = [0] * 512
                s.buf2 = [0] * 32
            op_t = CYC['rclr']
        elif name == 'xclr':
            for ch in range(NCH_MAX):
                for b in range(32):
                    self.X[ch][b] = [0] * 8
            op_t = CYC['xclr']
        elif name == 'xq':
            ch, b, ab, qsel, sidx, adj, lossless = a[0], a[1], a[2], a[3], a[4] & 0xFFFF, a[5], a[6]
            q, huff = self.extract(ab, qsel)
            if self.trace is not None:
                self.trace.extend((2, self.pc, i, v & 0xFFFFFF) for i, v in enumerate(q))
            scale = self.scale_value(sidx)
            if huff:
                scale = F.huff_scale(scale, T.SCALE_FACTOR_ADJ[adj & 3])
            self.X[ch][b] = F.dequant_band(q, ab, bool(lossless), scale)
            nbits, first = self.bitpos - b0, self.xq_first - b0
            block = not huff and ab <= 7
            k = 4 if block else 1                 # block codes: 4 cycles a bit, divisions included
            t_first = (1 + first) if huff else k * first
            reading = (1 + nbits) if huff else k * nbits
            setup = CYC['xq_setup_huff'] if huff else CYC['xq_setup']
            op_t = max(setup, t_first) + (reading - t_first) + CYC['xq_tail']
        elif name == 'xvq':
            ch, b, vqi, ssf, sidx = a[0], a[1], a[2] & 1023, a[3], a[4] & 0xFFFF
            vec = T.HIGH_FREQ_VQ[vqi][ssf * 8:ssf * 8 + 8]
            self.X[ch][b] = F.vq_band(vec, self.scale_value(sidx))
            op_t = CYC['xvq'] + self.cb_latency
        elif name == 'adpcm':
            ch, b, pvq, pmode = a[0], a[1], a[2] & 0xFFF, a[3]
            coeff = T.ADPCM_VB[pvq] if pmode else None
            self.X[ch][b], self.hist[ch][b] = F.adpcm_band(self.X[ch][b], self.hist[ch][b], coeff)
            op_t = (CYC['adpcm_pred'] + max(5, self.cb_latency + 3)) if pmode else CYC['adpcm_plain']
        elif name == 'joint':
            ch, b, src, jidx = a[0], a[1], a[2], a[3]
            jsc = T.JOINT_SCALE_FACTORS[jidx]
            self.X[ch][b], self.hist[ch][b] = F.joint_band(self.X[src][b], jsc, self.hist[ch][b])
            op_t = CYC['joint']
        elif name == 'bfly':
            p, q = a[0], a[1]
            for b in range(32):
                self.X[p][b], self.X[q][b] = F.butterfly_band(self.X[p][b], self.X[q][b])
            op_t = CYC['bfly']
        elif name == 'mixsyn':
            j, amode, nmix, perfect = a[0], a[1], a[2:7], a[7]
            spk = R.PRM_CH_TO_SPKR[amode]
            gains = F.default_gains(amode)
            win = T.FIR_32BANDS_PERFECT_FIXED if perfect else T.FIR_32BANDS_NONPERFECT_FIXED
            x = self.X[:len(spk)]
            op_t = CYC['mixsyn'] + 2 * (32 * len(spk) + CYC['mixsyn_side'])
            for side in (0, 1):
                gs = [gains.get(spk[ch], (0, 0))[side] for ch in range(len(spk))]
                inp = F.mix_column(x, j, gs, nmix[:len(spk)])
                pcm = self.synth[side].run(inp, win)
                self.pcm[side].extend(F.to_s16(v) for v in pcm)
        elif name == 'hclr':
            ch, frm = a[0], a[1]
            for b in range(max(frm, 0), 32):
                self.hist[ch][b] = [0] * 4
            op_t = CYC['hclr'] + CYC['hclr_band'] * (32 - min(max(frm, 0), 32))
        elif name == 'cnt':
            self.counters[a[0]] = self.counters.get(a[0], 0) + 1
            op_t = CYC['cnt']
        self.cycles = c0 + CYC['vop'] - CYC['instr'] + op_t
        self.by_cat[name] = self.by_cat.get(name, 0) + self.cycles - c0
        if self.vop_hook is not None:
            self.vop_hook(self, op)

    def checksums(self):
        """The engine buffers, each as sum((i + 1) * (v mod 2^w)) mod 2^32 over the
        RTL's own address order, so the bench can read the RAMs hierarchically:
          X     {ch, band, j}  (5 x 32 x 8)    w 25 (a butterflied band is 25 bits)
          hist  {ch, band, k}  (5 x 32 x 4)    w 24 (k = 0 the oldest)
          ring  {side, i}      (2 x 512)       w 24 (the IMDCT output ring, physical)
          buf2  {side, i}      (2 x 32)        w 29 (the window's carried partial sums)
        -> (x, hist, ring, buf2)"""
        def ck(vals, w):
            m = (1 << w) - 1
            return sum((i + 1) * (v & m) for i, v in enumerate(vals)) & 0xFFFFFFFF
        x = [self.X[ch][b][j] for ch in range(NCH_MAX) for b in range(32) for j in range(8)]
        h = [self.hist[ch][b][k] for ch in range(NCH_MAX) for b in range(32) for k in range(4)]
        ring = self.synth[0].buf + self.synth[1].buf
        b2 = self.synth[0].buf2 + self.synth[1].buf2
        return ck(x, 25), ck(h, 24), ck(ring, 24), ck(b2, 29)

    def scale_value(self, sidx):
        """sidx: bit 8 selects the 7-bit table (selector 6), else the 6-bit one."""
        if sidx & 0x100:
            return T.SCALE_FACTOR_QUANT7[sidx & 0x7F]
        return T.SCALE_FACTOR_QUANT6[sidx & 0x3F]

    def extract(self, ab, qsel):
        """XQ's code reader: R.extract_audio's semantics on the engine's bit reader
        and tree walker (lenient block codes, D5)."""
        if ab <= R.CODE_BOOKS and qsel < T.QUANT_INDEX_GROUP_SIZE[ab - 1]:
            out = []
            for i in range(8):
                out.append(s16(self.vlc(QBOOK[ab - 1] + qsel)))
                if i == 0:
                    self.xq_first = self.bitpos           # (the cycle model's first code)
            return out, True
        if ab <= 7 and not (ab <= R.CODE_BOOKS and qsel < T.QUANT_INDEX_GROUP_SIZE[ab - 1]):
            nb, levels = T.BLOCK_CODE_NBITS[ab - 1], T.QUANT_LEVELS[ab]
            off = (levels - 1) // 2
            out = []
            for h in range(2):
                code = self.bits(nb)
                if h == 0:
                    self.xq_first = self.bitpos
                for _ in range(4):
                    code, r = divmod(code, levels)
                    out.append(r - off)
                if code:
                    self.lenient += 1
            return out, False
        out = []
        for i in range(8):
            out.append(self.sbits(ab - 3))
            if i == 0:
                self.xq_first = self.bitpos
        return out, False

    def drain_cycles(self):
        """fend / err: the frame's bytes the bit reader never took, drained."""
        if self.cur is None:
            return 0
        taken = (min(self.bitpos, len(self.cur) * 8) + 7) >> 3
        return 1 + CYC['drain_byte'] * (len(self.cur) - taken)

    # -- the sequencer -------------------------------------------------------
    def run(self, max_steps=50_000_000):
        steps = 0
        while steps < max_steps:
            steps += 1
            w = self.prog[self.pc]
            op, rd, rs, rt, imm, aux = decode(w)
            npc = self.pc + 1
            if self.pc_prof is not None:            # cycles by instruction (profiling)
                self._prof_pc, self._prof_c0 = self.pc, self.cycles
            self.cycles += CYC['instr']
            if op == 'nop':
                pass
            elif op == 'alu':
                self.setr(rd, self.alu(aux, self.reg[rs], self.reg[rt]))
            elif op == 'alui':
                self.setr(rd, self.alu(aux, self.reg[rs], s16(imm)))
            elif op == 'ld':
                self.cycles += CYC['ld'] - CYC['instr']
                self.setr(rd, self.load(self.reg[rs] + self.reg[rt] + s16(imm)))
            elif op == 'st':
                self.store(self.reg[rs] + self.reg[rt] + s16(imm), self.reg[rd])
            elif op == 'get':
                self.cycles += CYC['get'] - CYC['instr']
                self.setr(rd, self.bits(imm))
            elif op == 'getr':
                n = self.reg[rt]
                if not 0 <= n <= 16:
                    raise EngineError(f'getr {n} bits at pc {self.pc}')
                self.cycles += CYC['get'] - CYC['instr']
                self.setr(rd, self.bits(n))
            elif op == 'vlc':
                self.cycles += CYC['vlc'] - CYC['instr']
                self.setr(rd, self.vlc(self.reg[rs] + s16(imm)))
            elif op in ('br', 'bri'):
                a = self.reg[rs]
                b = self.reg[rt] if op == 'br' else (((rt << 6) | aux) ^ 0x200) - 0x200
                c = CONDS[rd]
                if (c == 'eq' and a == b) or (c == 'ne' and a != b) or \
                        (c == 'lt' and a < b) or (c == 'ge' and a >= b):
                    npc = imm
                    if npc >= ERR_BASE:            # an error vector: err (npc - ERR_BASE)
                        self.cycles += self.drain_cycles()
                        code = npc - ERR_BASE
                        self.errors[code] = self.errors.get(code, 0) + 1
                        self.cur = None
                        self.stack = []
                        npc = self.labels['FRAME']
            elif op == 'jmp':
                npc = imm
            elif op == 'call':
                if len(self.stack) >= STACK_DEPTH:
                    raise EngineError(f'call stack overflow at pc {self.pc}')
                self.stack.append(npc)
                npc = imm
            elif op == 'ret':
                npc = self.stack.pop()
            elif op == 'err':
                self.cycles += self.drain_cycles()
                self.errors[imm] = self.errors.get(imm, 0) + 1
                self.cur = None
                self.stack = []
                npc = self.labels['FRAME']
            elif op == 'vop':
                self.vop(aux)
                code = getattr(self, 'op_err', None)
                if code is not None:                   # an op refused the frame
                    self.op_err = None
                    self.cycles += self.drain_cycles()
                    self.errors[code] = self.errors.get(code, 0) + 1
                    self.cur = None
                    self.stack = []
                    npc = self.labels['FRAME']
            elif op == 'frame':
                if self.cur is not None:
                    self.frame_cycles.append(self.cycles - self.frame_start)
                if not self.frames:
                    self.cur = None
                    return                                 # waits here (pc unchanged)
                self.cur = self.frames.pop(0)
                self.bitpos = 0
                self.frame_start = self.cycles
                self.cycles += CYC['frame'] - CYC['instr']
                self.setr(rd, len(self.cur))
            elif op == 'fend':
                self.cycles += self.drain_cycles()
                self.bitpos = len(self.cur) * 8 if self.cur is not None else 0
            elif op == 'bpos':
                self.setr(rd, self.bitpos & 0xFFFF)
            if self.pc_prof is not None:
                self.pc_prof[self._prof_pc] = (self.pc_prof.get(self._prof_pc, 0) +
                                               self.cycles - self._prof_c0)
            self.pc = npc
        raise EngineError('step limit')


def load_program(mutate=None):
    words, labels, _ = assemble(open(UASM).read(), mutate)
    return words, labels


def emulate(path, nframes=0, mutate=None, budget=False):
    """Emulate a raw .dts stream; -> (L, R, machine)."""
    words, labels = load_program(mutate)
    m = Machine(words, labels)
    n = 0
    for _, fr in R.frames(open(path, 'rb').read()):
        if nframes and n >= nframes:
            break
        m.feed(fr)
        m.run()
        n += 1
    return m.pcm[0], m.pcm[1], m


def _packed(vals, w):
    """A packed localparam: element i at [w*i +: w] (no unpacked localparam arrays:
    the RTL keeps to what Quartus 17 is known to elaborate)."""
    v = 0
    for i, x in enumerate(vals):
        assert 0 <= x < (1 << w), (x, w)
        v |= x << (w * i)
    return f"{w * len(vals)}'h{v:0{(w * len(vals) + 3) // 4}x}"


def ucode_svh(words, labels, alabels, nconst):
    """dvd/dts/dts_ucode.svh: the sizes, both programs' entry points and XQ's
    code-reader tables the sequencer RTL needs, all derived here so --check covers
    them."""
    ab = range(1, R.CODE_BOOKS + 1)
    blk = range(1, 8)
    lines = [
        '// dvd/dts/dts_ucode.svh -- GENERATED by tools/dts_isa.py --asm; never edit.',
        '// The engine\'s sizes, both programs\' entry points (DTS at 0, AC-3 after it, in',
        '// one ROM), and XQ\'s code-reader tables (packed: element i at [w*i +: w];',
        '// index abits - 1).',
        f'localparam int UC_WORDS    = {len(words)};',
        f'localparam int CONST_WORDS = {nconst};',
        f'localparam int HUFF_NODES  = {len(HUFF_NODES)};',
        f'localparam int HUFF_BOOKS  = {len(HUFF_ROOTS)};',
        f"localparam [10:0] UC_DTS_RESET = 11'd{labels.get('RESET', 0)};",
        f"localparam [10:0] UC_DTS_FRAME = 11'd{labels['FRAME']};",
        f"localparam [10:0] UC_AC3_RESET = 11'd{alabels.get('RESET', 0)};",
        f"localparam [10:0] UC_AC3_FRAME = 11'd{alabels['FRAME']};",
        f"localparam [5:0]  UC_ERRV      = 6'd{ERR_BASE >> 5};      // error vectors: pc[10:5] == this",
        '// the first quantiser-index book of abits (book = QBOOK + selector)',
        f'localparam [{6 * R.CODE_BOOKS - 1}:0] XQ_QBOOK  = {_packed([QBOOK[a - 1] for a in ab], 6)};',
        '// selectors below this are Huffman books',
        f'localparam [{4 * R.CODE_BOOKS - 1}:0] XQ_GSIZE  = {_packed([T.QUANT_INDEX_GROUP_SIZE[a - 1] for a in ab], 4)};',
        '// block codes (abits 1..7): bits a code, and the levels (the divisor)',
        f'localparam [34:0] XQ_BNBITS = {_packed([T.BLOCK_CODE_NBITS[a - 1] for a in blk], 5)};',
        f'localparam [34:0] XQ_LEVELS = {_packed([T.QUANT_LEVELS[a] for a in blk], 5)};',
    ]
    return lines


def cb_rows():
    """The engine's codebook rows (dts_vec's cb port format, tools/dts_golden.py
    write_codebooks): ADPCM 4096 x {4 x int16 at [16i +: 16]}, VQ {index, ssf} 4096 x
    {8 x int8 at [8k +: 8]}."""
    adpcm = [sum((c & 0xFFFF) << (16 * i) for i, c in enumerate(vec)) for vec in T.ADPCM_VB]
    vq = []
    for vec in T.HIGH_FREQ_VQ:
        for ssf in range(4):
            sl = vec[8 * ssf:8 * ssf + 8]
            vq.append(sum((v & 0xFF) << (8 * k) for k, v in enumerate(sl)))
    assert len(adpcm) == 4096 and len(vq) == 4096
    return adpcm, vq


def cb_host_images():
    """D4: the three FIFOs that carry the codebooks as their power-up contents, in the
    layout dvd/dts/dts_cb_mem.sv copies them out in, and that copy's checksum (the
    RTL's Fletcher pair over every row in copy order: s1 += lo + hi; s2 += s1 + lo + hi;
    the sum is s2 ^ s1)."""
    adpcm, vq = cb_rows()
    lpcm = [w for r in adpcm[:2048] for w in (r & 0xFFFFFFFF, r >> 32)]
    mp2 = [w for r in adpcm[2048:] for w in (r & 0xFFFFFFFF, r >> 32)]
    ring = [(r >> (8 * k)) & 0xFF for r in vq for k in range(8)]
    s1 = s2 = 0
    for r in adpcm + vq:
        x = ((r & 0xFFFFFFFF) + (r >> 32)) & 0xFFFFFFFF
        s2 = (s2 + s1 + x) & 0xFFFFFFFF
        s1 = (s1 + x) & 0xFFFFFFFF
    return lpcm, mp2, ring, s2 ^ s1


def write_mems(check=False):
    words, labels, _ = assemble(open(UASM).read())
    import ac3_isa as A                          # the second program in the same ROM
    import mp2_isa as P                          # ... and the third (docs/mp2_engine.md)
    awords, alabels = A.load_program()
    pwords, plabels = P.load_program()
    assert pwords[:len(awords)] == awords and awords[:len(words)] == words
    allw = pwords
    allc = CONST + A.CONST + P.CONST
    assert len(allw) <= ERR_BASE and len(allc) <= 1024
    files = {UMEM: [f'{w:010x}' for w in allw],
             CMEM: [f'{w:04x}' for w in allc],
             HMEM: [f'{w:05x}' for w in huff_mem_words()[:2048]],
             HMEM_HI: [f'{w:05x}' for w in huff_mem_words()[2048:]],
             RMEM: [f'{r:03x}' for r in HUFF_ROOTS],
             USVH: ucode_svh(allw, labels, alabels, len(allc)) + A.svh_lines() + P.svh_lines(plabels)}
    import dts_vecrom as V                       # the vector engine's ROMs
    files.update({
        os.path.join(VDIR, 'dts_vconst.mem'): [f'{w:06x}' for w in V.vconst_words()],
        os.path.join(VDIR, 'dts_win.mem'): [f'{w:06x}' for w in V.window_words()],
        # the IMDCT program, then AC-3's dither-LFSR table at 768 (dts_vec IP_DITH)
        os.path.join(VDIR, 'dts_iprog.mem'): [f'{w:05x}' for w in A.iprog_words(V.prog_words())],
        # the IMDCT's coefficients, then MP2's C and SCF (tools/mp2_isa.py icoef_words)
        os.path.join(VDIR, 'dts_icoef.mem'): [f'{c & 0x7FFFFFF:07x}' for c in P.icoef_words(V.ICOEF)],
        os.path.join(VDIR, 'dts_vec.svh'): V.vec_svh()})
    files.update({os.path.join(VDIR, n): w for n, w in P.vec_files().items()})
    # D4: the codebooks as the power-up contents of three FIFOs, and their checksum
    lpcm, mp2, ring, csum = cb_host_images()
    files.update({
        os.path.join(VDIR, 'cb_host_lpcm.mem'): [f'{w:08x}' for w in lpcm],
        os.path.join(VDIR, 'cb_host_mp2.mem'): [f'{w:08x}' for w in mp2],
        os.path.join(VDIR, 'cb_host_ring.mem'): [f'{b:02x}' for b in ring],
        os.path.join(VDIR, 'dts_cb.svh'): [
            '// dvd/dts/dts_cb.svh -- GENERATED by tools/dts_isa.py --asm; never edit.',
            '// The DTS codebooks\' checksum as dvd/dts/dts_cb_mem.sv computes it over the',
            '// copy (docs/dts_decoder.md D4): a mismatch leaves tables_ok low.',
            f"localparam [31:0] CB_SUM = 32'h{csum:08x};"]})
    bad = []
    for path, lines in files.items():
        text = '\n'.join(lines) + '\n'
        if check:
            if not os.path.exists(path) or open(path).read() != text:
                bad.append(os.path.relpath(path, REPO))
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, 'w').write(text)
    print(f'dts_isa: {len(words)} DTS + {len(awords) - len(words)} AC-3 + {len(allw) - len(awords)} MP2 = {len(allw)} microcode '
          f'words; {len(allc)} constant words; '
          f'{len(HUFF_NODES)} Huffman nodes, {len(HUFF_ROOTS)} book roots')
    if check:
        print('dts_isa: ' + ('FAIL -- stale: ' + ', '.join(bad) if bad else 'PASS -- generated files match'))
        return 1 if bad else 0
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--asm', action='store_true')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--run')
    ap.add_argument('--frames', type=int, default=0)
    args = ap.parse_args()
    if args.asm:
        return write_mems(args.check)
    if args.run:
        R.OPT.add('lenient_block')
        L, Rr, m = emulate(args.run, args.frames)
        hw = F.StreamDecoder()
        GL, GR = [], []
        n = 0
        for _, fr in R.frames(open(args.run, 'rb').read()):
            if args.frames and n >= args.frames:
                break
            a, b, _, _ = hw.decode(fr)
            GL += a
            GR += b
            n += 1
        bad = sum(1 for x, y in zip(L + Rr, GL + GR) if x != y) + abs(len(L) - len(GL))
        fc = m.frame_cycles
        print(f'dts_isa: {n} frames, {len(L)} samples, {bad} mismatches vs dts_fixed; '
              f'errors {m.errors or "none"}; cycles a frame max {max(fc) if fc else 0}, '
              f'mean {sum(fc) // max(len(fc), 1)}')
        return 1 if bad or m.errors else 0
    ap.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main())
