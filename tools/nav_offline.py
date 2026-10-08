#!/usr/bin/env python3
"""nav_offline.py -- diff the microcoded DVD VM against libdvdnav over the ISO
library, with no MiSTer: the offline half of tools/nav_diff.py
(docs/nav_engine.md "The offline libdvdnav diff").

nav_diff.py drives the BOARD and libdvdnav (tools/bin/trace_nav) through the same
button script and compares where each one parks -- one disc at a time, on the rig,
and only the PGCN (all the board's HUD shows). This runs the SAME microcode the core
runs (tools/nav_isa.py's emulator inside tools/nav_shell.py's wrapper model) under a
Python model of the reader's playback, so it needs no hardware, runs the library in
minutes, and can compare everything libdvdnav reports: domain, VTS, PGCN, program,
cell, and the 16 GPRMs (except
counter-mode ones, which count wall-clock seconds the model does not have).

THE READER MODEL (Player below) is what the RTL reader does, at cell granularity:
  - a VM jump (JUMP pulse) loads a PGC the way dvd_iso_reader's jump service does:
    a title by VTS_PTT_SRPT (ptt 0/1 = the first part), a menu by its entry id, a
    PGCN directly, pgn 0xFF = the last program; an unresolvable target is pgc_error;
  - a loaded PGC's PRE runs in the VM (pgc_loaded), then its cells play: a cell's
    still, then its cell command (vm_cell_cmd -> the VM's verdict: advance, replay,
    seek, jump), then at the last cell vm_pgc_end and the POST; a plain advance off
    the end follows the authored next_pgcn (the reader's own behaviour), else stops;
  - a cell's buttons are the first NV_PCK in it whose PCI carries an HLI.
THE PARK RULE is trace_nav's, so both sides stop in the same places: an indefinite
still is a park; a cell with buttons is a CANDIDATE, confirmed by a still on it
(finite or not) or by returning to the same cell (a looping menu). A button press is
nav_pci's: the selection set to N, then the button's command (btn_cmd_valid).

WHAT IT CANNOT SEE: anything timing-dependent (no clock: a finite still is skipped
at once, a natural tail drain does not exist), angle blocks, and the reader's own
state machine (the model is a model). A difference is therefore a LEAD, not a
verdict: it names a disc, a script and a step to reproduce on the rig with
nav_diff.py. Discs that use `rnd` are skipped (the core's LFSR and libdvdnav's RNG
differ by design), as nav_diff does.

A disc's status (docs/nav_engine.md sec 5):
    ok          every compared landing agrees (dom, PGCN, VTS in a VTS domain, GPRMs
                outside counter mode)
    ok-gprm     the same screens, different registers, no rnd: a LEAD
    DIFF        a different screen: a LEAD
    rnd         libdvdnav executed a rnd set, and a difference (or a second seed)
                followed it
    oracle-err  libdvdnav could not use the disc after the action (read error, IFO
                rejected, a PTT naming PGC 0)
    cap-edge    both stopped at the block cap on the same screen, one park apart
    nolanding   the model never reached the landing libdvdnav did: a LEAD
    udf-only    no VIDEO_TS in the ISO9660 tree (the reader cannot open it)

Usage:
    tools/nav_offline.py <disc.iso> --script "1 2 mR 1"
    tools/nav_offline.py <disc.iso> --auto 4            # a valid script from the oracle
    tools/nav_offline.py --library [--limit N] [--auto 3] [--jobs N]
                                                        # $DVD_ISO_DIR (default ~/dvd-isos)
    tools/nav_offline.py --library --red ARM            # a ;MUT arm must make differences
"""
import argparse
import concurrent.futures
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dvd_vm_ref as R      # noqa: E402
import nav_shell as S       # noqa: E402

TRACE_NAV = os.path.join(HERE, 'bin', 'trace_nav')
LIB = os.environ.get('DVD_ISO_DIR', os.path.expanduser('~/dvd-isos'))
DOM_FP, DOM_VMGM, DOM_VTSM, DOM_TT = 0, 1, 2, 3
DVDNAV_DOM = {DOM_FP: 1, DOM_TT: 2, DOM_VMGM: 4, DOM_VTSM: 8}   # libdvdnav's codes
CELL_CAP = 4000
# trace_nav's [block cap]: playback is charged in sectors against the SAME cap trace_nav
# uses (it reads TRACE_BLOCK_CAP; --block-cap sets both). A sweep lowers it because the
# library is a network share and a title that plays into the cap is most of a run's I/O.
BLOCK_CAP = int(os.environ.get('TRACE_BLOCK_CAP', 400000))
SKIP_DIRS = {'umd'}      # PSP UMD Video images: not DVD-Video
VOBU_SCAN = 256          # VOBUs of a cell searched for an HLI


class Disc(R.IsoNav):
    """IsoNav plus what playback needs: each cell's sectors, the VOB sets' starts,
    VTS_PTT_SRPT, and the HLI of a cell."""

    def __init__(self, path):
        super().__init__(path)
        self._hli = {}
        self.vobs = {}                  # (dom, vts) -> absolute LBA of the VOB set
        if self.vmgi_lba is not None:
            m = self.sec(self.vmgi_lba)
            off = struct.unpack('>I', m[0xC0:0xC4])[0]
            if off:
                self.vobs[(DOM_VMGM, 0)] = self.vmgi_lba + off
                self.vobs[(DOM_FP, 0)] = self.vmgi_lba + off
        for v, ifo in self.vts_ifo.items():
            m = self.sec(ifo)
            mo, to = struct.unpack('>II', m[0xC0:0xC8])
            if mo:
                self.vobs[(DOM_VTSM, v)] = ifo + mo
            if to:
                self.vobs[(DOM_TT, v)] = ifo + to

    def pgc(self, abs_byte):
        p = super().pgc(abs_byte)
        for i, c in enumerate(p['cells']):
            e = self.rd(abs_byte + p['cell_off'] + i * 24, 24)
            c['first'], c['last_vobu'], c['last'] = struct.unpack('>III', e[8:12] + e[16:24])
        return p

    def ptt(self, vts, ttn, part):
        """VTS_PTT_SRPT[ttn][part-1] -> (pgcn, pgn), or None."""
        ifo = self.vts_ifo.get(vts)
        if ifo is None:
            return None
        ptr = struct.unpack('>I', self.rd(ifo * 2048 + 0xC8, 4))[0]
        if not ptr:
            return None
        base = (ifo + ptr) * 2048
        n, _, last = struct.unpack('>HHI', self.rd(base, 8))
        if not 1 <= ttn <= n:
            return None
        offs = [struct.unpack('>I', self.rd(base + 8 + 4 * i, 4))[0] for i in range(n)]
        start = offs[ttn - 1]
        end = offs[ttn] if ttn < n else last + 1
        nparts = (end - start) // 4
        if not 1 <= part <= nparts:
            return None
        return struct.unpack('>HH', self.rd(base + start + 4 * (part - 1), 4))

    def hli(self, dom, vts, cell):
        """The first HLI in the cell: (btn_ns, fosl, [8-byte commands]) or None."""
        base = self.vobs.get((dom, vts if dom in (DOM_VTSM, DOM_TT) else 0))
        if base is None or 'first' not in cell:
            return None
        key = (base, cell['first'])
        if key in self._hli:
            return self._hli[key]
        out = None
        s = cell['first']
        for _ in range(VOBU_SCAN):
            b = self.sec(base + s)
            if len(b) < 2048 or b[0:4] != b'\x00\x00\x01\xba':
                break
            if not (b[0x26:0x2A] == b'\x00\x00\x01\xbf' and b[0x2C] == 0):
                break
            pci = 0x2D
            if ((b[pci + 0x60] << 8 | b[pci + 0x61]) & 3) and (b[pci + 0x71] & 0x3F):
                ns = b[pci + 0x71] & 0x3F
                cmds = [bytes(b[pci + 0x8E + 18 * i + 10: pci + 0x8E + 18 * i + 18]) for i in range(ns)]
                out = (ns, b[pci + 0x74] & 0x3F, cmds)
                break
            ea = struct.unpack('>I', b[0x40F:0x413])[0]
            if ea == 0 or s + ea + 1 > cell['last_vobu']:
                break
            s += ea + 1
        self._hli[key] = out
        return out


def still_of(p, ci):
    """The still libdvdnav shows at cell ci's end (vm.c vm_position_get), which is what
    trace_nav parks on: the cell's still time, plus the PGC's on its last cell, else
    its "rough fix" -- a single-VOBU cell under 1,024 sectors at a low data rate is
    held for its whole playback time (e.g. ULTIMATE_T2's VTSM menu: a 5 s still with
    buttons up, 2026-10-08). 0xFF = indefinite."""
    c = p['cells'][ci]
    st = c['still'] + (p['still'] if ci == p['nr_cells'] - 1 else 0)
    if st:
        return st
    if 'last' in c and c['last'] == c['last_vobu'] and c['last'] - c['first'] < 1024:
        t = c['pbtime']
        if t and (c['last'] - c['first']) // t <= 30:
            return min(t, 0xFF)
    return 0


class Player:
    """The reader's playback around the microcoded VM (see the module docstring)."""

    def __init__(self, iso, mutate=None, words=None):
        self.d = Disc(iso)
        self.sh = S.Shell(words=words, mutate=mutate)
        self.dom, self.vts, self.pgcn, self.pgc, self.cell = DOM_FP, 0, 0, None, 0
        self.cells = 0
        self.blocks = 0
        self.log = []
        self.set('auto_vts', self.d.best_vts)
        self.set('best_menu_vts', self.d.best_menu_vts)

    # ---- the VM ------------------------------------------------------------
    def set(self, name, v):
        self.sh.apply(f'set {name} {v}')

    def vm(self, line):
        """Apply a stimulus line; -> the pulses it produced (P lines, split)."""
        n = len(self.sh.log)
        self.sh.apply(line)
        out = [ln.split()[2:] for ln in self.sh.log[n:] if ln.startswith('P ')]
        # neither log is read back here, and both grow without bound: a library disc
        # that kept the VM busy took a sweep worker to 11 GB
        del self.sh.log[:]
        del self.sh.m.trace[:]
        return out

    def verdict(self, pulses):
        """The VM's answer: ('jump', fields) / ('seek', cell) / ('replay',) /
        ('adv',) / None. A jump wins (a seek or replay cannot follow one)."""
        out = None
        for p in pulses:
            if p[0] == 'JUMP':
                return ('jump', [int(x) for x in p[1:]])
            if p[0] == 'SEEK':
                out = ('seek', int(p[1]))
            elif p[0] == 'REPLAY':
                out = ('replay',)
            elif p[0] == 'ADV' and out is None:
                out = ('adv',)
        return out

    # ---- loads (the reader's jump service) ----------------------------------
    def load(self, f):
        """Resolve a VM jump and report pgc_loaded / pgc_error. -> the verdict of
        whatever the VM did next (a PRE may jump again)."""
        dom, vts, pgcn, entry, ttn, pgn, ptt, cell, _nat = f
        d = self.d
        pgc = None
        res_ttn = 0
        if dom == DOM_FP:
            pgc, vts, pgcn = d.fp_pgc(), 0, 0
        elif dom in (DOM_VMGM, DOM_VTSM):
            if dom == DOM_VMGM:
                vts = 0
            pit = d.pgcit(dom, vts)
            if pit:
                if pgcn == 0:
                    pgcn = next((i + 1 for i, (e, _) in enumerate(pit)
                                 if (e & 0x80) and (e & 0x0F) == entry), 1)
                if 1 <= pgcn <= len(pit):
                    pgc = d.pgc(pit[pgcn - 1][1])
        else:
            if vts == 0 and ttn:                       # JumpTT: a global title
                t = d.tt.get(ttn)
                if t:
                    vts, ttn = t
            res_ttn = ttn
            pit = d.pgcit(DOM_TT, vts)
            if pit:
                if pgcn == 0 and ttn:
                    r = d.ptt(vts, ttn, max(ptt, 1))
                    if r:
                        pgcn, ppg = r
                        if not pgn:
                            pgn = ppg
                if 1 <= pgcn <= len(pit):
                    pgc = d.pgc(pit[pgcn - 1][1])
        if pgc is None:
            return self.verdict(self.vm('pulse error'))
        self.dom, self.vts, self.pgcn, self.pgc = dom, vts, pgcn, pgc
        nc = pgc['nr_cells']
        if pgn == 0xFF and pgc['pm']:
            cell = pgc['pm'][-1] - 1
        elif pgn and pgc['pm'] and pgn <= len(pgc['pm']):
            cell = pgc['pm'][pgn - 1] - 1
        self.cell = cell if cell < max(nc, 1) else 0
        self.write_pgc(pgc, res_ttn)
        self.log.append(f'load dom={dom} vts={vts} pgcn={pgcn} cell={self.cell}')
        return self.verdict(self.vm('pulse loaded'))

    def write_pgc(self, p, res_ttn):
        cmds = p['pre'] + p['post'] + p['cellc']
        for i, c in enumerate(cmds[:511]):
            self.sh.apply(f'cmd {i} {c.hex()}')
        for i, v in enumerate(p['pm'][:99]):
            self.sh.apply(f'pm {i} {v}')
        for k, v in (('nr_pre', len(p['pre'])), ('nr_post', len(p['post'])),
                     ('nr_cell', len(p['cellc'])), ('nr_pgms', min(len(p['pm']), 99)),
                     ('cell_count', p['nr_cells']), ('cur_vts', self.vts),
                     ('cur_pgcn', self.pgcn), ('next_pgcn', p['next']),
                     ('prev_pgcn', p['prev']), ('goup_pgcn', p['goup']),
                     ('menu_active', int(self.dom in (DOM_VMGM, DOM_VTSM))),
                     ('res_ttn', res_ttn & 0x7F), ('cur_cell', self.cell),
                     ('btns_armed', 0)):
            self.sh.inp_lv[k] = v
        self.sh.run()

    def follow(self, v):
        """Act on a VM verdict until playback can continue. -> 'play' / 'stop'."""
        for _ in range(256):
            if v is None:
                return 'play'
            if v[0] == 'jump':
                v = self.load(v[1])
                continue
            if v[0] == 'seek':
                self.cell = v[1]
                return 'play'
            return 'play'
        return 'stop'

    # ---- the player -----------------------------------------------------------
    def state(self, buttons):
        p = self.pgc or {'pm': []}
        pg = 1
        for i, c1 in enumerate(p['pm']):
            if self.cell >= c1 - 1:
                pg = i + 1
        g = [self.sh.m.ram[i] for i in range(16)]
        return dict(dom=DVDNAV_DOM[self.dom], vts=self.vts, pgcn=self.pgcn, pg=pg,
                    cell=self.cell + 1, buttons=buttons, gprm=g,
                    gmode=self.sh.m.ram[S.N.RAM_MAP['GMODE']])

    def run(self, script):
        """-> [(action, landing state)] in trace_nav's pairing (the LAST park after
        an action is its landing)."""
        toks = script.split()
        ti = 0
        rows, pending = [], None
        cand, loops, wait, acted = None, 0, 0, False
        st = self.follow(self.verdict(self.vm('set nav_ready 1')))
        prev = None
        while st == 'play' and self.cells < CELL_CAP and self.blocks < BLOCK_CAP:
            p = self.pgc
            if p is None:                    # nothing ever loaded: the VM has given up
                st = 'stop'
                break
            if not p['cells']:
                # a command-only PGC: POST, then as at any PGC end -- a plain advance
                # takes the authored next_pgcn or stops (it spun here, re-raising the end)
                v = self.verdict(self.vm('pulse pgcend')) or ('adv',)
                if v[0] in ('adv', 'replay'):
                    st = (self.follow(self.load([self.dom, self.vts, p['next'], 0, 0, 0,
                                                 0, 0, 0])) if p['next'] else 'stop')
                else:
                    st = self.follow(v)
                continue
            if self.cell >= p['nr_cells']:
                self.cell = 0
            key = (self.dom, self.vts, self.pgcn, self.cell)
            if key != prev or True:          # every entry into a cell is a cell change
                self.cells += 1
                if wait > 0:
                    wait -= 1
                if cand is not None and key == cand:
                    loops += 1
                acted = False
            prev = key
            c = p['cells'][self.cell]
            self.sh.inp_lv['cur_cell'] = self.cell
            h = self.d.hli(self.dom, self.vts, c)
            park, nb = False, 0
            if h:
                nb = h[0]
                cur = self.sh.sprm[8] >> 10
                self.sh.inp_lv['btn_sel'] = h[1] or (cur if 1 <= cur <= nb else 1)
                self.sh.inp_lv['btns_armed'] = 1
                self.sh.run()
                if not acted and wait == 0:
                    if cand != key:
                        cand, loops = key, 0
                    elif loops > 0:
                        park = True
            still = still_of(p, self.cell)
            if still == 0xFF:
                park, cand = True, None
            elif still and cand is not None and cand[:3] == key[:3] and not acted:
                park, cand = True, None
            if park and not acted:
                if pending is not None:
                    rows.append((pending, self.state(nb)))
                    pending = None
                if ti >= len(toks):
                    break
                t = toks[ti]
                ti += 1
                pending = t
                acted = True
                v = None
                if t.isdigit():
                    n = int(t)
                    if h and 1 <= n <= nb:
                        self.sh.inp_lv['btn_sel'] = n
                        v = self.verdict(self.vm(f'pulse btn={h[2][n - 1].hex()}'))
                elif t == 'mR':
                    v = self.verdict(self.vm('pulse menu'))
                elif t == 'mT':
                    v = self.verdict(self.vm('pulse title'))
                elif t.startswith('w'):
                    # trace_nav prints a wait as an action too, and pairs it with the
                    # next park after N cell changes: keep it pending (it was dropped,
                    # which left every 'w1' script with nothing to compare)
                    wait = int(t[1:] or 1)
                if v is not None and v[0] in ('jump', 'seek'):
                    cand = None
                    st = self.follow(v)
                    continue
                if v is not None and v[0] == 'replay':
                    continue
                # nothing moved: the still is skipped, the cell plays on
            # the cell ends (it played: charge its sectors, as trace_nav counts blocks)
            self.blocks += max(c.get('last', 0) - c.get('first', 0) + 1, 1)
            if self.blocks >= BLOCK_CAP:
                break
            self.sh.inp_lv['btns_armed'] = 0
            self.sh.run()
            v = ('adv',)
            if c['cmd_nr']:
                v = self.verdict(self.vm(f'pulse cellcmd={c["cmd_nr"]}')) or ('adv',)
            if v[0] in ('jump', 'seek'):
                st = self.follow(v)
                continue
            if v[0] == 'replay':
                continue
            self.cell += 1
            if self.cell < p['nr_cells']:
                continue
            # the PGC ends (its still was the last cell's: still_of)
            v = self.verdict(self.vm('pulse pgcend')) or ('adv',)
            if v[0] == 'adv':
                if p['next']:
                    st = self.follow(self.load([self.dom, self.vts, p['next'], 0, 0, 0, 0, 0, 0]))
                else:
                    st = 'stop'
                continue
            if v[0] == 'replay':
                self.cell = p['nr_cells'] - 1
                continue
            st = self.follow(v)
        if pending is not None:
            rows.append((pending, self.state(0)))
        return rows


# ------------------------------------------------------------------ the oracle
def oracle(iso, script, seed=None):
    """trace_nav's landings -> [(action, state)] with GPRMs (nav_diff's pairing)."""
    cmd = [TRACE_NAV, iso, script] + ([str(seed)] if seed is not None else [])
    pr = subprocess.run(cmd, capture_output=True, text=True, errors='replace', timeout=900)
    out = pr.stdout
    # libdvdnav logs to BOTH streams (the link values on stdout, an IFO rejection and
    # the Exit it substitutes on stderr), so their order cannot be recovered: a failure
    # on stderr voids only a FINAL landing that ended without a park (see below)
    err_fail = bool(re.search(r'ifoRead_\w+ failed|No such pgcN|BLOCK ERR', pr.stderr))
    vm_re = re.compile(r'VM\[([\w-]+)\]\s+dom=(-?\d+)\s+vtsN=(-?\d+)\s+pgcN=(-?\d+)'
                       r'\s+pgN=(-?\d+)\s+cellN=(-?\d+).*?GPRM\[([\d,]+)\]')
    park_re = re.compile(r'^===== PARK #(\d+)\s+title=(-?\d+)\s+part=(-?\d+)\s+buttons=(\d+)')
    act_re = re.compile(r'^>> action: (.+)$')
    rows, last, pending, idx = [], None, None, None
    blockerr = False
    for ln in out.splitlines():
        if ln.startswith('BLOCK ERR') or re.search(r'ifoRead_\w+ failed|No such pgcN', ln):
            # libdvdnav could not use the disc: a read error ('Expected NAV packet but
            # none found': a VOB not where the IFO says), an IFO libdvdread rejects
            # (ifoRead_PGCIT failed), or a malformed link target (VTS_PTT_SRPT naming
            # PGC 0 -> 'No such pgcN', then Exit). Its landing after that is its own
            # failure, not navigation -- reported as oracle-err, not compared.
            blockerr = True
            continue
        m = vm_re.search(ln)
        if m:
            last = dict(dom=int(m.group(2)), vts=int(m.group(3)), pgcn=int(m.group(4)),
                        pg=int(m.group(5)), cell=int(m.group(6)),
                        gprm=[int(x) for x in m.group(7).split(',')])
            continue
        m = park_re.match(ln)
        if m:
            if pending is not None:
                row = (pending, dict(last or {}, buttons=int(m.group(4))))
                if idx is None:
                    rows.append(row)
                    idx = len(rows) - 1
                else:
                    rows[idx] = row
            continue
        if act_re.match(ln):
            if pending is not None and idx is None:
                rows.append((pending, dict(last or {}, buttons=0, cap=True, blockerr=blockerr)))
            pending, idx = act_re.match(ln).group(1), None
            blockerr = False                     # only errors AFTER the action void it
    if pending is not None and idx is None:
        # no park after the last action (a title plays into the block cap): its
        # landing is where the trace ended
        rows.append((pending, dict(last or {}, buttons=0, cap=True,
                                   blockerr=blockerr or err_fail)))
    if not rows and pending is None and last is not None:
        # libdvdnav never parked, so no action ran: the disc boots straight into
        # playback. Where it stands at the cap is still the boot chain's verdict
        # (First Play -> the feature); compare that. A third of the library is this.
        rows.append(('boot', dict(last, buttons=0, cap=True, blockerr=err_fail)))
    # the commands libdvdnav lists and runs are on stderr (ran_rnd reads them); stdout
    # first, so auto_script's park parse sees the same text it always did
    return rows, out + '\n' + pr.stderr


def tok_of(action):
    m = re.match(r'select\+activate button (\d+)', action)
    if m:
        return m.group(1)
    m = re.match(r'menu_call\((\w+)\)', action)
    if m:
        return 'mT' if m.group(1) == 'Title' else 'mR'
    return action


def auto_script(iso, steps, seed=1):
    import random
    rng = random.Random(seed)
    script = []
    for _ in range(steps):
        _, raw = oracle(iso, ' '.join(script) if script else 'w1', seed=1)
        parks = re.findall(r'^===== PARK #\d+.*?buttons=(\d+)', raw, re.M)
        n = int(parks[-1]) if parks else 0
        if n < 1:
            break
        script.append(str(rng.randint(1, min(n, 9))))
    return script


def diff_disc(iso, script, mutate=None, words=None):
    """-> dict(disc, script, rows=[...], status). A row compares one action.
    A disc that differs is re-run under a second libdvdnav seed: if that moves the
    oracle's landings, the disc uses `rnd` and is reported as such, not as a DIFF."""
    name = os.path.relpath(iso, LIB) if iso.startswith(LIB) else os.path.basename(iso)
    if Disc(iso).vmgi_lba is None:
        # no VIDEO_TS in the ISO9660 tree: libdvdnav finds it through UDF, the core's
        # reader cannot (UDF-only images are a known gap). MILLIONAIRERUS.
        return dict(disc=name, script='', rows=[], status='udf-only')
    a, raw = oracle(iso, script, seed=1)
    res = compare_disc(iso, name, script, a, mutate, words)
    gdiff = any(r['verdict'] == 'ok-gprm' for r in res['rows'])
    if res['status'] == 'DIFF' or gdiff:
        # libdvdnav EXECUTED an rnd: the core's LFSR and libdvdnav's RNG differ by
        # design, so nothing after it compares. This replaced a two-seed test (does
        # seed 99 move the landings?), which missed Die Another Day 2: its `g0 = rnd
        # 12` sent both seeds down the same branch.
        if ran_rnd(raw):
            res['status'] = 'rnd'
        elif res['status'] == 'ok':
            res['status'] = 'ok-gprm'        # same screens, different registers: a lead
    elif res['status'] == 'ok' and ran_rnd(raw):
        # agreement after an rnd may be luck (SpacePirates: seed 1's rand() and the
        # LFSR gave the same g9). If another seed moves libdvdnav, the ok proves nothing.
        b, _ = oracle(iso, script, seed=99)
        if [(r[1].get('pgcn'), r[1].get('gprm')) for r in a] != \
           [(r[1].get('pgcn'), r[1].get('gprm')) for r in b]:
            res['status'] = 'rnd'
    return res


def ran_rnd(out):
    """Did libdvdnav execute a `rnd` set? (`out` is oracle()'s, stderr included.)
    Its trace LISTS a block's commands under
    'Full list of commands to execute' (up to the '----' rule), then prints the ones it
    runs; only the latter count."""
    listing = False
    for ln in out.splitlines():
        if 'Full list of commands to execute' in ln:
            listing = True
        elif ln.startswith('libdvdnav: ---'):
            listing = False
        elif not listing and re.match(r'^\(\d+\) .*\| g\[\d+\] rnd ', ln):
            return True
    return False


def compare_disc(iso, name, script, a, mutate, words=None):
    try:
        pl = Player(iso, mutate, words)
        ours = pl.run(script)
        capped = pl.blocks >= BLOCK_CAP
        at_end = pl.state(0)
    except Exception as e:                       # a model or emulator failure is a finding too
        return dict(disc=name, script=script, rows=[], status=f'error: {e!r}')
    rows = []
    menu_calls = 0
    for i, (act, o) in enumerate(a):
        t = tok_of(act)
        menu_calls += t.startswith('m')
        u = ours[i][1] if i < len(ours) else None
        if t == 'boot':
            u = at_end                           # the model's position at the cap
        if o.get('blockerr'):
            rows.append(dict(tok=t, o=o, u=u, verdict='oracle-err'))
            break                                # libdvdnav failed to read: not a landing
        if u is None:
            # both sides stopped at the block cap: they count blocks differently near
            # it (whole cells here, block by block in trace_nav), so one can reach one
            # more park than the other -- a boundary artefact, not a landing
            # ...but only when we stopped on the screen libdvdnav applied this action
            # at (the previous landing): a run that never parked at all is a real
            # difference (ISLAM_TRAILER: libdvdnav parks on a First Play menu)
            prev = a[i - 1][1] if i > 0 else None
            same = prev is not None and all(
                prev.get(k) == at_end.get(k)
                for k in ['dom', 'pgcn'] + (['vts'] if prev.get('dom') in (2, 8) else []))
            v = 'cap-edge' if (o.get('cap') and capped and same) else 'nolanding'
            rows.append(dict(tok=t, o=o, u=None, verdict=v))
            break
        keys = ['dom', 'pgcn'] + (['vts'] if o.get('dom') in (2, 8) else [])
        same = all(o.get(k) == u.get(k) for k in keys)
        # a counter-mode GPRM counts wall-clock seconds, and the model has no clock
        cm = u.get('gmode', 0)
        og, ug = o.get('gprm') or [], u.get('gprm') or []
        gsame = len(og) == len(ug) and all(a == b for i, (a, b) in enumerate(zip(og, ug))
                                           if not (cm >> i) & 1)
        first_menu = t.startswith('m') and menu_calls == 1 and i == 0
        v = 'ok' if same and gsame else ('ok-gprm' if same else
                                          ('boot-shortcut' if first_menu else 'DIFF'))
        rows.append(dict(tok=t, o=o, u=u, verdict=v))
        if v == 'DIFF':
            break                                # everything after is downstream
    st = 'DIFF' if any(r['verdict'] == 'DIFF' for r in rows) else \
         ('nolanding' if any(r['verdict'] == 'nolanding' for r in rows) else
          ('oracle-err' if any(r['verdict'] == 'oracle-err' for r in rows) else
           ('cap-edge' if any(r['verdict'] == 'cap-edge' for r in rows) else 'ok')))
    return dict(disc=name, script=script, rows=rows, status=st)


def show(res):
    print(f"{res['disc']}  script '{res['script']}': {res['status']}")
    for r in res['rows']:
        o, u = r['o'], r['u'] or {}
        print(f"  [{r['verdict']:>13}] {r['tok']:<3} libdvdnav dom={o.get('dom')} vts={o.get('vts')} "
              f"pgc={o.get('pgcn')} pg={o.get('pg')} cell={o.get('cell')} | ucode dom={u.get('dom')} "
              f"vts={u.get('vts')} pgc={u.get('pgcn')} pg={u.get('pg')} cell={u.get('cell')}")
        if r['verdict'] == 'ok-gprm':
            print(f"       GPRM libdvdnav {o.get('gprm')}\n            ucode     {u.get('gprm')}")


def lib_job(args):
    iso, steps, mutate, words = args
    try:
        script = ' '.join(auto_script(iso, steps)) or 'w1'
        return diff_disc(iso, script, mutate, words)
    except Exception as e:
        return dict(disc=os.path.relpath(iso, LIB), script='', rows=[], status=f'error: {e!r}')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso', nargs='?')
    ap.add_argument('--script')
    ap.add_argument('--auto', type=int, default=3)
    ap.add_argument('--library', action='store_true')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    ap.add_argument('--red', help='run with this ;MUT arm: it must produce differences')
    ap.add_argument('--out', help='write the per-disc results here (JSON lines, as each '
                    'disc finishes)')
    ap.add_argument('--resume', action='store_true', help='with --out: skip discs already in it')
    ap.add_argument('--only', metavar='FILE', help='run only the discs listed in FILE (paths '
                    'relative to $DVD_ISO_DIR, one per line): a second pass over a sweep\'s '
                    'differences and its discs that compared nothing')
    ap.add_argument('--block-cap', type=int, help='trace_nav\'s and the model\'s block cap '
                    '(default 400000; a sweep uses less, see BLOCK_CAP)')
    a = ap.parse_args()
    if a.block_cap:
        os.environ['TRACE_BLOCK_CAP'] = str(a.block_cap)       # trace_nav and the workers
        global BLOCK_CAP
        BLOCK_CAP = a.block_cap
    if not os.path.exists(TRACE_NAV):
        sys.exit(f'nav_offline: {TRACE_NAV} not built (tools/build_dvd_trace.sh)')
    if not a.library:
        if not a.iso:
            ap.error('a disc, or --library')
        script = a.script or ' '.join(auto_script(a.iso, a.auto)) or 'w1'
        res = diff_disc(a.iso, script, a.red)
        show(res)
        return 0 if res['status'] in ('ok', 'rnd') else 1
    import json
    isos = sorted(os.path.join(dp, f) for dp, _, fs in os.walk(LIB) for f in fs
                  if f.lower().endswith('.iso')
                  and not (set(os.path.relpath(dp, LIB).split(os.sep)) & SKIP_DIRS))
    if a.only:
        want = {ln.strip() for ln in open(a.only) if ln.strip()}
        isos = [i for i in isos if os.path.relpath(i, LIB) in want]
    if a.limit:
        isos = isos[:a.limit]
    results = []
    done = set()
    if a.out and a.resume and os.path.exists(a.out):
        for ln in open(a.out):
            r = json.loads(ln)
            results.append(r)
            done.add(r['disc'])
    todo = [i for i in isos if os.path.relpath(i, LIB) not in done]
    print(f'nav_offline: {len(isos)} discs, {len(todo)} to run, block cap {BLOCK_CAP}', flush=True)
    out = open(a.out, 'a') if a.out else None
    with concurrent.futures.ProcessPoolExecutor(max_workers=a.jobs) as ex:
        # the program is assembled ONCE, here: a sweep runs for hours, and a worker that
        # re-read dvd/nav/vm.uasm would pick up an edit made meanwhile (it did, 2026-10-08)
        words, _, _ = S.N.load_program(a.red)
        futs = [ex.submit(lib_job, (i, a.auto, None, words)) for i in todo]
        for n, fu in enumerate(concurrent.futures.as_completed(futs), 1):
            res = fu.result()
            results.append(res)
            if out:
                out.write(json.dumps(res) + '\n')
                out.flush()
            if res['status'] not in ('ok', 'rnd'):
                show(res)
            if n % 25 == 0:
                print(f'  ... {n}/{len(todo)}', flush=True)
    from collections import Counter
    c = Counter(r['status'].split(':')[0] for r in results)
    print(f"nav_offline: {len(results)} discs: " + ', '.join(f'{k} {v}' for k, v in sorted(c.items())))
    if a.red:
        bit = c.get('DIFF', 0) > 0
        print(f"RED {a.red}: " + ('differences found' if bit else 'BLIND -- no difference'))
        return 0 if bit else 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
