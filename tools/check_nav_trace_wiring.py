#!/usr/bin/env python3
"""check_nav_trace_wiring.py -- the nav event FIFO's seams (dvd/nav_trace.sv;
docs/hil_play_harness.md "Nav event FIFO (fabric)").

WHY A SCRIPT: nav_trace_tb is handed its inputs and is correct for what it is
given. Whether the log says what HAPPENED -- the activation pulse into the
activation source, the promoted HLI's s_ptm into HLI_ARM, the GPRM write snoop
rather than some other data-RAM write, the reply bus shared with dvd_telem
without either clobbering the other, the Main's magic and command matching the
RTL's -- is a chain of connections no bench instantiates (emu.sv has no bench).
A swapped pair would pass the bench and log a button activation as a cell
command, which is exactly the confusion the log exists to remove.

WHAT IS PINNED
  emu.sv        every nav_trace port, by expression; the EXT_BUS OR/mux with
                dvd_telem; the dvd_vm / nav_pci outputs feeding it
  dvd_vm.sv     trc_gprm_* = the data-RAM write snoop filtered to 0x00..0x0F, and
                the snoop IS the RAM's write port (d_we/d_a/vd); UM_GPRM = 0x00
  nav_pci.sv    dbg_h_sptm = h_sptm
  nav_trace.sv  CMD 0x7C, MAGIC 0x5E01 with bit 15 clear, MAXN 64; dvd_telem's two
                commands are not 0x7C
  DVD.qsf       names dvd/nav_trace.sv
  dvd_ctl.cpp   UIO_DVD_NAVTRACE / DVD_NAVTRACE_MAGIC / DVD_NAVTRACE_MAXN equal the
                RTL's; the drain runs only under telem_fast

strip_comments() first (comments quote the pre-fix code). A missing instance is a
named FAIL, never a skip.

Usage: check_nav_trace_wiring.py [--red]
Exit 0 = wired as designed, 1 = not.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from check_field_blend_wiring import strip_comments, connections  # noqa: E402

FILES = {
    'emu': 'dvd/emu.sv', 'vm': 'dvd/dvd_vm.sv', 'pci': 'dvd/nav_pci.sv',
    'trace': 'dvd/nav_trace.sv', 'telem': 'dvd/dvd_telem.sv', 'qsf': 'DVD.qsf',
    'ctl': 'main/support/dvd/dvd_ctl.cpp',
}

# nav_trace port -> the emu.sv expression it must be connected to (whitespace-free)
TRACE_PORTS = {
    'clk': 'clk_sys', 'rst_n': 'reset_n',
    'io_enable': 'ext_bus[34]', 'io_strobe': 'ext_bus[33]', 'io_din': 'ext_bus[31:16]',
    'drive': 'trc_drive', 'dout': 'trc_dout',
    'tick': "stc_div==9'd299", 'stc': 'av_stc',
    'gprm_we': 'trc_gprm_we', 'gprm_a': 'trc_gprm_a', 'gprm_d': 'trc_gprm_d',
    'joy_rise': 'joy_eff[24:0]&~joy_prev[24:0]', 'kbd_joy': 'kbd_joy', 'ps2_key': 'ps2_key',
    'btn_act': 'hl_btn_cmd_valid', 'btn_sel': 'hl_btn_sel', 'btn_ns': 'hl_btn_ns',
    'cell_cmd': 'vm_cell_cmd_w', 'cell_cmdnr': 'cur_cell_cmdnr_w',
    'hli_arm': 'hli_arm_w', 'h_sptm': 'hl_sptm_w', 'btns_armed': 'hl_btns_armed',
    'cur_cell': 'cur_cell', 'cur_vts': 'cur_vts', 'cur_pgcn': 'cur_pgcn_rd',
    'menu_active': 'menu_active',
    'flush': '{soft_flush,mount_flush,seek_flush,aud_resync,aud_flush,load_flush}',
    'aud_low': 'aud_ring_low', 'aud_frames': 'aud_frames_avail',
    'pause': 'pause_q', 'still': 'still_active', 'video_live': 'video_live_s2',
}


def norm(e):
    return re.sub(r'\s+', '', e or '')


def run(txt, verbose=True):
    fails = []

    def ok(cond, msg):
        if verbose:
            print(f"  {'ok  ' if cond else 'FAIL'} {msg}")
        if not cond:
            fails.append(msg)

    def pin(conns, inst, port, want):
        got = None if conns is None else conns.get(port)
        ok(conns is not None and norm(got) == want,
           f'{inst}.{port}({want})' + ('' if norm(got) == want else f'   got: {got!r}'))

    s = {k: strip_comments(v) if k != 'qsf' else v for k, v in txt.items()}

    if verbose:
        print('== emu.sv ==')
    em = s['emu']
    nt = connections(em, 'nav_trace')
    ok(nt is not None, 'nav_trace is instantiated')
    ok(re.search(r'\bnav_trace\s*#', em) is None, 'nav_trace takes its default CMD/MAGIC (no #() override)')
    for port, want in TRACE_PORTS.items():
        pin(nt, 'nav_trace', port, want)
    ok(re.search(r'\bassign\s+ext_bus\[32\]\s*=\s*telem_drive\s*\|\s*trc_drive\s*;', em) is not None,
       'ext_bus[32] = telem_drive | trc_drive')
    ok(re.search(r'\bassign\s+ext_bus\[15:0\]\s*=\s*trc_drive\s*\?\s*trc_dout\s*:\s*telem_dout\s*;', em)
       is not None, 'ext_bus[15:0] = trc_drive ? trc_dout : telem_dout')
    tl = connections(em, 'dvd_telem')
    pin(tl, 'dvd_telem', 'drive', 'telem_drive')
    pin(tl, 'dvd_telem', 'dout', 'telem_dout')
    vm = connections(em, 'dvd_vm')
    for p in ('we', 'a', 'd'):
        pin(vm, 'dvd_vm', f'trc_gprm_{p}', f'trc_gprm_{p}')
    pin(vm, 'dvd_vm', 'vm_cell_cmd', 'vm_cell_cmd_w')
    pin(vm, 'dvd_vm', 'cell_cmd_nr', 'cur_cell_cmdnr_w')
    pc = connections(em, 'nav_pci')
    for port, want in (('dbg_h_sptm', 'hl_sptm_w'), ('hli_arm', 'hli_arm_w'),
                       ('btn_cmd_valid', 'hl_btn_cmd_valid'), ('btn_sel', 'hl_btn_sel'),
                       ('dbg_btn_ns', 'hl_btn_ns'), ('btns_armed', 'hl_btns_armed')):
        pin(pc, 'nav_pci', port, want)
    km = connections(em, 'kbd_map')
    pin(km, 'kbd_map', 'joy', 'kbd_joy')

    if verbose:
        print('== dvd_vm.sv ==')
    v = s['vm']
    ok(re.search(r"\bassign\s+trc_gprm_we\s*=\s*snoop_we\s*&&\s*\(\s*snoop_a\[7:4\]\s*==\s*4'd0\s*\)\s*;", v)
       is not None, "trc_gprm_we = snoop_we && (snoop_a[7:4] == 4'd0)")
    ok(re.search(r'\bassign\s+trc_gprm_a\s*=\s*snoop_a\[3:0\]\s*;', v) is not None, 'trc_gprm_a = snoop_a[3:0]')
    ok(re.search(r'\bassign\s+trc_gprm_d\s*=\s*snoop_d\s*;', v) is not None, 'trc_gprm_d = snoop_d')
    for a, b in (('snoop_we', 'd_we'), ('snoop_a', 'd_a'), ('snoop_d', 'vd')):
        ok(re.search(r'\bassign\s+%s\s*=\s*%s\s*;' % (a, b), v) is not None, f'{a} = {b} (the RAM write port)')
    ok(re.search(r'\bif\s*\(\s*d_we\s*\)\s*dram\[d_a\]\s*<=\s*vd\s*;', v) is not None,
       'dram is written by (d_we, d_a, vd)')
    ok(len(re.findall(r"localparam\s*\[7:0\]\s*UM_GPRM\s*=\s*8'h00\s*;", v)) >= 1, "UM_GPRM = 8'h00")

    if verbose:
        print('== nav_pci.sv ==')
    ok(re.search(r'\bassign\s+dbg_h_sptm\s*=\s*h_sptm\s*;', s['pci']) is not None, 'dbg_h_sptm = h_sptm')

    if verbose:
        print('== nav_trace.sv / dvd_telem.sv ==')
    t = s['trace']
    mc = re.search(r"parameter\s*\[15:0\]\s*CMD\s*=\s*16'h([0-9A-Fa-f]+)", t)
    mm = re.search(r"parameter\s*\[15:0\]\s*MAGIC\s*=\s*16'h([0-9A-Fa-f]+)", t)
    mn = re.search(r"parameter\s*\[6:0\]\s*MAXN\s*=\s*7'd(\d+)", t)
    rtl_cmd = int(mc.group(1), 16) if mc else None
    rtl_magic = int(mm.group(1), 16) if mm else None
    rtl_maxn = int(mn.group(1)) if mn else None
    ok(rtl_cmd == 0x7C, 'nav_trace CMD = 0x007C')
    ok(rtl_magic is not None and rtl_magic != 0 and not (rtl_magic & 0x8000),
       'nav_trace MAGIC non-zero with bit 15 clear')
    ok(rtl_maxn == 64, 'nav_trace MAXN = 64')
    tcmds = [int(x, 16) for x in re.findall(r"parameter\s*\[15:0\]\s*CMD(?:_AF)?\s*=\s*16'h([0-9A-Fa-f]+)",
                                            s['telem'])]
    ok(len(tcmds) == 2 and rtl_cmd not in tcmds, f'dvd_telem answers {[hex(c) for c in tcmds]}, not 0x7C')

    if verbose:
        print('== DVD.qsf ==')
    ok(re.search(r'^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+dvd/nav_trace\.sv\s*$',
                 s['qsf'], re.M) is not None, 'DVD.qsf names dvd/nav_trace.sv')

    if verbose:
        print('== dvd_ctl.cpp ==')
    c = s['ctl']

    def define(name):
        m = re.search(r'#define\s+%s\s+(0x[0-9A-Fa-f]+|\d+)\b' % name, c)
        return int(m.group(1), 0) if m else None
    ok(define('UIO_DVD_NAVTRACE') == rtl_cmd, 'UIO_DVD_NAVTRACE == the RTL CMD')
    ok(define('DVD_NAVTRACE_MAGIC') == rtl_magic, 'DVD_NAVTRACE_MAGIC == the RTL MAGIC')
    ok(define('DVD_NAVTRACE_MAXN') == rtl_maxn, 'DVD_NAVTRACE_MAXN == the RTL MAXN')
    ok(re.search(r'spi_uio_cmd_cont\(\s*UIO_DVD_NAVTRACE\s*\)', c) is not None, 'the drain issues UIO_DVD_NAVTRACE')
    ok(re.search(r'if\s*\(\s*telem_fast\s*\)\s*\{[^}]*navtrace_drain\(', c) is not None,
       'navtrace_drain runs only under telem_fast')
    return fails


MUTATIONS = [
    ('emu', '.btn_act     (hl_btn_cmd_valid),', '.btn_act     (vm_cell_cmd_w),', 'activation fed the cell-command pulse'),
    ('emu', '.cell_cmd    (vm_cell_cmd_w),', '.cell_cmd    (hl_btn_cmd_valid),', 'cell command fed the activation'),
    ('emu', '.h_sptm      (hl_sptm_w),', '.h_sptm      (32\'d0),', 'HLI s_ptm tied off'),
    ('emu', '.stc         (av_stc),\n    .gprm_we', '.stc         (33\'d0),\n    .gprm_we', 'STC tied off'),
    ('emu', 'assign ext_bus[15:0] = trc_drive ? trc_dout : telem_dout;',
     'assign ext_bus[15:0] = telem_dout;', 'nav_trace reply never reaches the bus'),
    ('emu', '.dbg_h_sptm (hl_sptm_w)', '.dbg_h_sptm ()', 'nav_pci s_ptm left unconnected'),
    ('vm', "assign trc_gprm_we = snoop_we && (snoop_a[7:4] == 4'd0);", 'assign trc_gprm_we = snoop_we;',
     'every data-RAM write logged as a GPRM'),
    ('qsf', 'set_global_assignment -name SYSTEMVERILOG_FILE dvd/nav_trace.sv\n', '', 'qsf forgets the module'),
    ('ctl', '#define DVD_NAVTRACE_MAGIC 0x5E01', '#define DVD_NAVTRACE_MAGIC 0xD7D1', 'Main magic drifts'),
    ('ctl', '#define UIO_DVD_NAVTRACE   0x7C', '#define UIO_DVD_NAVTRACE   0x7A', 'Main asks dvd_telem'),
]


def main():
    txt = {k: open(os.path.join(ROOT, p)).read() for k, p in FILES.items()}
    if '--red' in sys.argv:
        if run(txt, verbose=False):
            print('  FAIL green fails on the working tree -- fix that first')
            return 1
        bad = 0
        for key, old, new, what in MUTATIONS:
            if txt[key].count(old) != 1:
                print(f'  FAIL mutation anchor moved ({what}): {old!r}')
                bad += 1
                continue
            m = dict(txt)
            m[key] = txt[key].replace(old, new)
            if run(m, verbose=False):
                print(f'  ok   wiring mutation caught: {what}')
            else:
                print(f'  FAIL wiring mutation survived: {what}')
                bad += 1
        print('RESULT:', 'PASS' if bad == 0 else f'FAIL ({bad})')
        return 1 if bad else 0
    fails = run(txt)
    print('RESULT:', 'PASS' if not fails else f'FAIL ({len(fails)})')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
