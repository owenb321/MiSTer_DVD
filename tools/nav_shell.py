#!/usr/bin/env python3
"""nav_shell.py -- the hardwired half of the DVD VM (dvd/dvd_vm.sv's wrapper)
around the microcode emulator (tools/nav_isa.py), driven by a stimulus script.

The wrapper owns everything real-time, and this models it at the level the
microcode sees it: the event latches and their priority (`wev`), the wait
timeout, the output fields and pulses, the SPRM8 shadow / activation latch /
freeze, the SPRM3 write-back, the last-good-menu latch, menu_seen, pre_done and
the LFSR. Together with nav_isa.Machine it is the whole VM in Python.

A STIMULUS is applied one line at a time, each at quiescence (the sequencer
parked at a wev with nothing to dispatch), which is what makes the RTL and this
model comparable without a cycle model of the wrapper:

    set <input> <value>            a level input (see INPUTS)
    cmd <index> <16 hex digits>    an 8-byte command into the command table
    pm  <index> <value>            a program-map byte
    pulse <name>[=<value>] ...     one-cycle pulses, together in one cycle:
        loaded error cellcmd=<nr> pgcend btn=<16 hex> menu title return cmenu
        chedge=<dir> start tick stir=<value> agl=<value>
    timeout                        the wait timer expires (only while waiting)
    # ...                          a comment

After each line the model runs to quiescence and appends to its log:
    P <step> <pulse> <fields>      an output pulse, in order
    L <step> <reg> <value>         a change of SPRM1/2/3/8 (each register in order)
    S <step> <name>=<hex> ...      the state at quiescence (after pulse/timeout/settle)
The A/B (tools/vm_ab.py) compares these against the same script run on the RTL.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nav_isa as N  # noqa: E402

INPUTS = {   # name: (width, reset value). The cfg defaults are libdvdnav's constants.
    'enable': (1, 1), 'cfg_lang': (16, 0x656E), 'cfg_sprm14': (16, 0x0100),
    'cfg_sprm15': (16, 0x7CFC), 'cfg_sprm20': (16, 0x0001), 'nav_ready': (1, 0),
    'auto_vts': (8, 0), 'best_menu_vts': (8, 0), 'res_ttn': (7, 0), 'rnd_seed': (16, 0xACE1),
    'nr_pre': (8, 0), 'nr_post': (8, 0), 'nr_cell': (8, 0), 'nr_pgms': (8, 0),
    'menu_active': (1, 0), 'cur_vts': (8, 0), 'cur_pgcn': (16, 0), 'cur_cell': (8, 0),
    'cell_count': (8, 0), 'next_pgcn': (16, 0), 'prev_pgcn': (16, 0), 'goup_pgcn': (16, 0),
    'btn_sel': (6, 0), 'btns_armed': (1, 0), 'wait_hold': (1, 0),
}
PULSES = ['loaded', 'error', 'cellcmd', 'pgcend', 'btn', 'menu', 'title', 'return',
          'cmenu', 'chedge', 'start', 'tick', 'stir', 'agl']
DOM_VMGM, DOM_VTSM, DOM_TT = 1, 2, 3
EVB = N.EV

# the state dump, in order (the RTL bench prints the same names)
STATE = (['g%d' % i for i in range(16)] +
         ['gmode', 'sprm1', 'sprm2', 'sprm3', 'sprm4', 'sprm5', 'sprm6', 'sprm7', 'sprm8',
          'sprm9', 'sprm10', 'sprm13', 'rsm_vts', 'rsm_pgcn', 'rsm_cell', 'rsm_r4', 'rsm_r5',
          'rsm_r6', 'rsm_r7', 'rsm_r8', 'fb', 'cvm', 'skip_pre', 'tt_resolve', 'menu_seen',
          'vm_dom', 'vm_vts', 'de_seen', 'de_vts', 'de_pgcn', 'lfsr', 'frozen', 'chain',
          'fuse', 'blk', 'nat', 'usr', 'lm_v', 'lm_dom', 'lm_vts', 'lm_pgcn', 'events',
          'tick', 'mode'])


def lfsr_next(v):
    return (((v ^ (v >> 2) ^ (v >> 3) ^ (v >> 5)) & 1) << 15) | (v >> 1)


class Shell:
    def __init__(self, words=None, mutate=None, trace=False):
        self.trace = trace
        self.c0 = 0
        if words is None:
            words, _, _ = N.load_program(mutate)
        self.inp_lv = {k: v for k, (w, v) in INPUTS.items()}
        self.cmem = [0] * 4096
        self.pmem = [0] * 128
        self.log = []
        self.step_no = 0
        self.m = N.Machine(words, self)
        self.power_on()

    # ------------------------------------------------------------ resets
    def _mount_hw(self, log=False):
        """The wrapper's part of a mount (old: the `if (start)` block)."""
        self.events = 0
        self.tick_pending = False
        if log:
            for r, v in ((1, 15), (2, 62), (3, 1), (8, 0x400)):
                self._level(r, v)
        else:
            self.sprm = {1: 15, 2: 62, 3: 1, 8: 0x400}
        self.frozen = False
        seed = self.inp_lv['rnd_seed']
        self.lfsr = seed if seed else 0xACE1
        self.vm_dom, self.vm_vts = DOM_TT, 0
        self.menu_seen = False
        self.lm = (DOM_VTSM, 0, 0)
        self.lm_v = False
        self.flags = 0
        self.timeout = False

    def power_on(self):
        self._mount_hw()
        self.j = {'dom': DOM_TT, 'entry': 0, 'vts': 0, 'pgcn': 0, 'ttn': 0, 'pgn': 0,
                  'ptt': 0, 'cell': 0}
        self.seek_cell = 0
        self.btnf_val = 1
        self.lf_pgcn = 0
        self.pre_armed = False
        self.cc_nr = 0
        self.btn_cmd = 0
        self.chedge_dir = 0
        self.nav_ready_d = 0
        self.m.reset()
        self.m.run()
        self.m.trace = []
        self.c0 = self.m.cycles

    # ------------------------------------------------------------ helpers
    def _emit(self, *f):
        self.log.append('P %d %s' % (self.step_no, ' '.join(str(x) for x in f)))

    def _level(self, r, v):
        v &= 0xFFFF
        if self.sprm[r] != v:
            self.sprm[r] = v
            self.log.append('L %d sprm%d %04x' % (self.step_no, r, v))

    def _shadow(self):
        if self.inp_lv['btns_armed'] and not self.frozen:
            self._level(8, self.inp_lv['btn_sel'] << 10)

    def sprm8_eff(self):
        if self.inp_lv['btns_armed'] and not self.frozen:
            return self.inp_lv['btn_sel'] << 10
        return self.sprm[8]

    def _blk(self):
        return self.flags & 3

    def _from_wait(self):
        return int(self._blk() in (1, 2) and bool(self.flags & N.base_equ()['F_NAT']))

    def _pre_done_check(self):
        if self.pre_armed and not (self.events & EVB['LOADED']):
            self.pre_armed = False
            self._emit('PREDONE')

    # ------------------------------------------------------------ the machine's I/O
    def inp(self, p):
        L = self.inp_lv
        if p >= 32:
            n = p - 32
            if n in (0, 16, 18):
                return L['cfg_lang']
            if n in (1, 2, 3):
                return self.sprm[n]
            if n == 8:
                return self.sprm8_eff()
            if n == 12:
                return 0x5553
            if n == 14:
                return L['cfg_sprm14']
            if n == 15:
                return L['cfg_sprm15']
            if n == 20:
                return L['cfg_sprm20']
            return 0
        name = N.IN_PORTS[p]
        direct = {'CUR_VTS': 'cur_vts', 'CUR_PGCN': 'cur_pgcn', 'CUR_CELL': 'cur_cell',
                  'CELL_COUNT': 'cell_count', 'NEXT_PGCN': 'next_pgcn',
                  'PREV_PGCN': 'prev_pgcn', 'GOUP_PGCN': 'goup_pgcn', 'NR_PRE': 'nr_pre',
                  'NR_POST': 'nr_post', 'NR_CELL': 'nr_cell', 'NR_PGMS': 'nr_pgms',
                  'AUTO_VTS': 'auto_vts', 'BEST_MENU_VTS': 'best_menu_vts',
                  'RES_TTN': 'res_ttn', 'MENU_ACTIVE': 'menu_active'}
        if name in direct:
            return L[direct[name]]
        if name.startswith('BTN'):
            k = int(name[3])
            return (self.btn_cmd >> (48 - 16 * k)) & 0xFFFF
        return {'CC_NR': self.cc_nr, 'CHEDGE_DIR': self.chedge_dir, 'LFSR': self.lfsr,
                'VM_DOM': self.vm_dom, 'VM_VTS': self.vm_vts,
                'MENU_SEEN': int(self.menu_seen), 'LM_V': int(self.lm_v),
                'LM_DOM': self.lm[0], 'LM_VTS': self.lm[1], 'LM_PGCN': self.lm[2],
                'JPGCN': self.j['pgcn'], 'EVENTS': self.events, 'ZERO27': 0}[name]

    def out(self, p, v):
        name = N.OUT_PORTS[p]
        if name == 'J_DE':
            self.j['dom'], self.j['entry'] = v & 3, (v >> 4) & 15
        elif name == 'J_VTS':
            self.j['vts'] = v & 0xFF
        elif name == 'J_PGCN':
            self.j['pgcn'] = v
        elif name == 'J_TTN':
            self.j['ttn'] = v & 0x7F
        elif name == 'J_PGN':
            self.j['pgn'] = v & 0xFF
        elif name == 'J_PTT':
            self.j['ptt'] = v & 0x3FF
        elif name == 'J_CELL':
            self.j['cell'] = v & 0xFF
        elif name == 'SEEK_CELL':
            self.seek_cell = v & 0xFF
        elif name == 'BTNF_VAL':
            self.btnf_val = v & 0x3F
        elif name == 'LF_PGCN':
            self.lf_pgcn = v & 0xFF
        elif name in ('SPRM1', 'SPRM2', 'SPRM3', 'SPRM8'):
            self._level(int(name[4:]), v)
            if name == 'SPRM8':
                self._shadow()            # the shadow takes it back next cycle
        elif name == 'VM_DOM':
            self.vm_dom = v & 3
        elif name == 'VM_VTS':
            self.vm_vts = v & 0xFF
        elif name == 'FLAGS':
            self.flags = v & 0x1F
        elif name == 'EVCLR':
            self.events &= ~v
        elif name == 'EVSET':
            self.events |= v & ((1 << len(N.EVENTS)) - 1)
        elif name == 'PULSE':
            if v & N.PB['BTNF']:
                self._emit('BTNF', self.btnf_val)
            if v & N.PB['LINKFAIL']:
                self._emit('LINKFAIL', self.lf_pgcn)
            if v & N.PB['JUMP']:
                j = self.j
                self._emit('JUMP', j['dom'], j['vts'], j['pgcn'], j['entry'], j['ttn'],
                           j['pgn'], j['ptt'], j['cell'], self._from_wait())
            if v & N.PB['SEEK']:
                self._emit('SEEK', self.seek_cell, self._from_wait())
            if v & N.PB['REPLAY']:
                self._emit('REPLAY')
            if v & N.PB['ADV'] and not (self.flags & N.base_equ()['F_USR']):
                self._emit('ADV')
            if v & N.PB['JUMP']:
                self._pre_done_check()
            if v & N.PB['LFSTEP']:
                self.lfsr = lfsr_next(self.lfsr)
            if v & N.PB['WARM']:
                self.timeout = False
            if v & N.PB['TICKDONE']:
                self.tick_pending = False
        else:
            raise N.SeqError(f'output port {p}')

    def ldc(self, a):
        return (self.cmem[2 * a] << 8) | self.cmem[2 * a + 1]

    def ldp(self, a):
        return self.pmem[a]

    def wev(self, mode):
        if mode == 0:
            self._pre_done_check()
            if self.tick_pending:
                return 0
            if not self.inp_lv['enable'] and self.events:
                return 1
            for i, n in enumerate(N.EVENTS):
                if self.events & EVB[n]:
                    self.events &= ~EVB[n]
                    return i + 2
            return None
        if self.events & EVB['LOADED']:
            return 0
        if self.events & EVB['ERROR']:
            return 1
        if self.timeout:
            return 2
        return None

    # ------------------------------------------------------------ stimulus
    def at_idle(self):
        return self.m.waiting == 0 or bool(self.flags & N.base_equ()['F_WALK'])

    def pulse(self, ps):
        """One cycle of pulses (old dvd_vm.sv's clocked block, in its order)."""
        L = self.inp_lv
        if 'start' in ps:
            # the mount overrides every same-cycle write; only pre_armed survives
            if 'loaded' in ps:
                self.pre_armed = True
            self._mount_hw(log=True)
            self.m.pc, self.m.stack, self.m.waiting = 0, [], None
            self.run()
            return
        self._shadow()
        if 'agl' in ps:
            self._level(3, ps['agl'] & 15)
        if 'loaded' in ps and self.vm_dom in (DOM_VMGM, DOM_VTSM):
            self.lm = (self.vm_dom, self.vm_vts, L['cur_pgcn'])
            self.lm_v = True
            self.menu_seen = True
        if 'tick' in ps:
            self.tick_pending = True
        if 'loaded' in ps:
            self.pre_armed = True
        if L['enable']:
            if 'loaded' in ps:
                self.events |= EVB['LOADED']
            if 'error' in ps:
                self.events |= EVB['ERROR']
            if 'cellcmd' in ps:
                self.events |= EVB['CELLCMD']
                self.cc_nr = ps['cellcmd'] & 0xFF
            if 'pgcend' in ps:
                self.events |= EVB['PGCEND']
            if 'btn' in ps:
                self.events |= EVB['BTN']
                self.btn_cmd = ps['btn']
                self._level(8, L['btn_sel'] << 10)
                self.frozen = True
            if 'loaded' in ps:
                self.frozen = False
            for k, n in (('menu', 'MENU'), ('title', 'TITLE'), ('return', 'RETURN'),
                         ('cmenu', 'CMENU')):
                if k in ps:
                    self.events |= EVB[n]
            if 'chedge' in ps:
                self.events |= EVB['CHEDGE']
                self.chedge_dir = ps['chedge'] & 1
        if 'stir' in ps and self.at_idle():
            x = self.lfsr ^ (ps['stir'] & 0xFFFF)
            self.lfsr = x if x else 0xACE1
        self._shadow()        # the next cycle's write-back lands before any command runs
        self.run()

    def run(self):
        self.m.run()
        self._shadow()

    def dump(self):
        r = self.m.ram
        M = N.RAM_MAP
        v = {('g%d' % i): r[i] for i in range(16)}
        v.update(gmode=r[M['GMODE']], sprm1=self.sprm[1], sprm2=self.sprm[2],
                 sprm3=self.sprm[3], sprm8=self.sprm[8], fb=r[M['FB']], cvm=r[M['CVM']],
                 skip_pre=r[M['SKIP_PRE']], tt_resolve=r[M['TT_RESOLVE']],
                 menu_seen=int(self.menu_seen), vm_dom=self.vm_dom, vm_vts=self.vm_vts,
                 de_seen=r[M['DE_SEEN']], de_vts=r[M['DE_VTS']], de_pgcn=r[M['DE_PGCN']],
                 lfsr=self.lfsr, frozen=int(self.frozen), chain=r[M['CHAIN']],
                 fuse=self.m.reg[11], blk=self.flags & 3, nat=(self.flags >> 2) & 1,
                 usr=(self.flags >> 3) & 1, lm_v=int(self.lm_v), lm_dom=self.lm[0],
                 lm_vts=self.lm[1], lm_pgcn=self.lm[2], events=self.events,
                 tick=int(self.tick_pending), mode=self.m.waiting)
        for n in (4, 5, 6, 7, 9, 10, 13):
            v['sprm%d' % n] = r[M['SPRMI'] + n]
        for n in ('VTS', 'PGCN', 'CELL', 'R4', 'R5', 'R6', 'R7', 'R8'):
            v['rsm_' + n.lower()] = r[M['RSM_' + n]]
        return v

    def apply(self, line):
        """One stimulus line. -> True if it was a step the logs are compared at."""
        t = line.split('#', 1)[0].split()
        if not t:
            return False
        self.step_no += 1
        op = t[0]
        if op == 'set':
            name, val = t[1], int(t[2], 0)
            w = INPUTS[name][0]
            old = self.inp_lv[name]
            self.inp_lv[name] = val & ((1 << w) - 1)
            if name == 'nav_ready' and val and not old and self.inp_lv['enable']:
                self.events |= EVB['BOOT']
            self.run()
        elif op == 'cmd':
            i, b = int(t[1], 0), bytes.fromhex(t[2])
            assert len(b) == 8
            self.cmem[8 * i:8 * i + 8] = list(b)
            return False
        elif op == 'pm':
            self.pmem[int(t[1], 0)] = int(t[2], 0) & 0xFF
            return False
        elif op == 'pulse':
            ps = {}
            for a in t[1:]:
                k, _, v = a.partition('=')
                if k not in PULSES:
                    raise ValueError(f'pulse {k}')
                ps[k] = int(v, 16) if k == 'btn' else (int(v, 0) if v else 1)
            self.pulse(ps)
        elif op == 'timeout':
            if self.m.waiting == 1:
                self.timeout = True
            self.run()
        elif op == 'settle':
            self.run()
        else:
            raise ValueError(f'stimulus: {line!r}')
        if self.trace:
            for k, pc, a, v in self.m.trace:
                self.log.append('T %d %d %d %d %d' % (self.step_no, k, pc, a, v))
            self.log.append('C %d %d' % (self.step_no, self.m.cycles - self.c0))
        self.m.trace = []
        self.c0 = self.m.cycles
        d = self.dump()
        self.log.append('S %d ' % self.step_no + ' '.join(
            '%s=%x' % (k, d[k]) if d[k] is not None else '%s=-' % k for k in STATE))
        return True


def run_script(lines, mutate=None, trace=False):
    sh = Shell(mutate=mutate, trace=trace)
    for ln in lines:
        sh.apply(ln)
    return sh


if __name__ == '__main__':
    sh = run_script(open(sys.argv[1]).read().splitlines())
    print('\n'.join(sh.log))
