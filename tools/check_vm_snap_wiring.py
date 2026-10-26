#!/usr/bin/env python3
"""check_vm_snap_wiring.py -- the VM state snapshot's seams (dvd/vm_snap.sv, dvd_vm's
E_SNAP; docs/nav_engine.md "State snapshot").

WHY A SCRIPT: vm_snap_tb instantiates dvd_vm and vm_snap together and hands both their
inputs, so it is correct for what it is given. Whether the core gives them the RIGHT
things -- the playhead (nav_dsi's NAV-pack LBN, not the reader's fetch pointer), the
picture flag from 1stref_ea, freshness cleared by the flush that makes nav_dsi stale,
the request and stream between the two modules, the reply bus shared with dvd_telem
and nav_trace, the Main's command and magic -- is a chain of connections no bench
instantiates (emu.sv has no bench). A position taken from the wrong counter compiles,
passes every bench, and saves a place the viewer was never at.

WHAT IS PINNED
  emu.sv        every vm_snap port, by expression; dvd_vm's five snap_* ports on the
                same nets; nav_dsi's 1stref_ea / prev_video connected to the nets
                vm_snap reads (it left them open before); the EXT_BUS OR and mux
  dvd_vm.sv     snap_we is the O_SNAP output strobe; snap_d the output bus; the
                request is offered only after every event and only with no held part
  vm_snap.sv    CMD 0x7D, MAGIC 0x5E02 with bit 15 clear, HDR 13; no other EXT_BUS
                module answers 0x7D
  DVD.qsf       names dvd/vm_snap.sv
  dvd_ctl.cpp   UIO_DVD_VMSNAP / DVD_VMSNAP_MAGIC / DVD_VMSNAP_HDR equal the RTL's;
                DVD_VMSNAP_MAXW holds the snapshot (>= USNAP_WORDS, <= the buffer)

strip_comments() first (comments quote the pre-fix code). A missing instance is a
named FAIL, never a skip.

Usage: check_vm_snap_wiring.py [--red]
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
    'emu': 'dvd/emu.sv', 'vm': 'dvd/dvd_vm.sv', 'snap': 'dvd/vm_snap.sv',
    'trace': 'dvd/nav_trace.sv', 'telem': 'dvd/dvd_telem.sv', 'qsf': 'DVD.qsf',
    'ctl': 'main/support/dvd/dvd_ctl.cpp', 'svh': 'dvd/nav/nav_ucode.svh',
}

# vm_snap port -> the emu.sv expression it must be connected to (whitespace-free)
SNAP_PORTS = {
    'clk': 'clk_sys', 'rst_n': 'reset_n',
    'io_enable': 'ext_bus[34]', 'io_strobe': 'ext_bus[33]', 'io_din': 'ext_bus[31:16]',
    'drive': 'snap_drive', 'dout': 'snap_dout',
    'snap_req': 'vm_snap_req', 'snap_we': 'vm_snap_we', 'snap_d': 'vm_snap_d',
    'snap_done': 'vm_snap_done', 'snap_fmt': 'vm_snap_fmt',
    'pos_clr': 'load_flush', 'pos_commit': 'dsi_commit',
    'nv_pck_lbn': 'dsi_nv_pck_lbn', 'first_ref_ea': 'dsi_1stref_ea',
    'prev_video': 'dsi_prev_video', 'c_eltm': 'dsi_c_eltm', 'vob_idn': 'dsi_vob_idn',
    'c_idn': 'dsi_c_idn',
}
VM_PORTS = {'snap_req': 'vm_snap_req', 'snap_we': 'vm_snap_we', 'snap_d': 'vm_snap_d',
            'snap_done': 'vm_snap_done', 'snap_fmt': 'vm_snap_fmt'}
DSI_PORTS = {'dsi_nv_pck_lbn': 'dsi_nv_pck_lbn', 'dsi_1stref_ea': 'dsi_1stref_ea',
             'dsi_prev_video': 'dsi_prev_video', 'dsi_c_eltm': 'dsi_c_eltm',
             'dsi_vob_idn': 'dsi_vob_idn', 'dsi_c_idn': 'dsi_c_idn', 'dsi_commit': 'dsi_commit'}


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

    s = {k: strip_comments(v) if k not in ('qsf', 'svh') else v for k, v in txt.items()}

    if verbose:
        print('== emu.sv ==')
    em = s['emu']
    sn = connections(em, 'vm_snap')
    ok(sn is not None, 'vm_snap is instantiated')
    ok(re.search(r'\bvm_snap\s*#', em) is None, 'vm_snap takes its default CMD/MAGIC (no #() override)')
    for port, want in SNAP_PORTS.items():
        pin(sn, 'vm_snap', port, want)
    vm = connections(em, 'dvd_vm')
    for port, want in VM_PORTS.items():
        pin(vm, 'dvd_vm', port, want)
    ds = connections(em, 'nav_dsi')
    for port, want in DSI_PORTS.items():
        pin(ds, 'nav_dsi', port, want)
    pin(ds, 'nav_dsi', 'rst_n', 'pipe_rst_n')          # why pos_clr must be the flush
    ok(re.search(r'\bassign\s+ext_bus\[32\]\s*=\s*[^;]*\bsnap_drive\b[^;]*;', em) is not None,
       'ext_bus[32] includes snap_drive')
    ok(re.search(r'\bassign\s+ext_bus\[15:0\]\s*=\s*[^;]*\bsnap_drive\s*\?\s*snap_dout\b[^;]*;', em) is not None,
       'ext_bus[15:0] selects snap_dout on snap_drive')

    if verbose:
        print('== dvd_vm.sv ==')
    v = s['vm']
    ok(re.search(r'\bassign\s+snap_we\s*=\s*o_we\s*&&\s*\(\s*out_port\s*==\s*UOUT_SNAP\s*\)\s*;', v) is not None,
       'snap_we = o_we && (out_port == UOUT_SNAP)')
    ok(re.search(r'\bassign\s+snap_d\s*=\s*od\s*;', v) is not None, 'snap_d = od (the output bus)')
    ok(re.search(r'\bassign\s+snap_fmt\s*=\s*USNAP_FMT\s*;', v) is not None, 'snap_fmt = USNAP_FMT')
    ok(re.search(r'if\s*\(\s*!ev_valid\s*&&\s*snap_pend\s*&&\s*!ptt_pend\s*\)\s*begin\s*ev_valid\s*=\s*1\'b1;'
                 r'\s*ev_idx\s*=\s*UWEV_SNAP;', v) is not None,
       'the snapshot is offered last, with no held SPRM7 part')
    ok(re.search(r'if\s*\(\s*od\[UPB_SNAPDONE\]\s*\)\s*snap_done\s*<=\s*1\'b1;', v) is not None,
       'snap_done follows the microcode\'s SNAPDONE pulse')

    if verbose:
        print('== vm_snap.sv / nav_trace.sv / dvd_telem.sv ==')
    t = s['snap']
    mc = re.search(r"parameter\s*\[15:0\]\s*CMD\s*=\s*16'h([0-9A-Fa-f]+)", t)
    mm = re.search(r"parameter\s*\[15:0\]\s*MAGIC\s*=\s*16'h([0-9A-Fa-f]+)", t)
    mh = re.search(r"localparam\s*\[3:0\]\s*HDR\s*=\s*4'd(\d+)", t)
    rtl_cmd = int(mc.group(1), 16) if mc else None
    rtl_magic = int(mm.group(1), 16) if mm else None
    rtl_hdr = int(mh.group(1)) if mh else None
    ok(rtl_cmd == 0x7D, 'vm_snap CMD = 0x007D')
    ok(rtl_magic is not None and rtl_magic != 0 and not (rtl_magic & 0x8000),
       'vm_snap MAGIC non-zero with bit 15 clear')
    ok(rtl_hdr == 13, 'vm_snap HDR = 13')
    tr = re.search(r"parameter\s*\[15:0\]\s*CMD\s*=\s*16'h([0-9A-Fa-f]+)", s['trace'])
    others = [int(x, 16) for x in re.findall(r"parameter\s*\[15:0\]\s*CMD(?:_AF)?\s*=\s*16'h([0-9A-Fa-f]+)",
                                              s['telem'])] + ([int(tr.group(1), 16)] if tr else [])
    ok(len(others) == 3 and rtl_cmd not in others, f'no other EXT_BUS module answers 0x7D ({[hex(c) for c in others]})')
    mbuf = re.search(r'reg\s*\[15:0\]\s*buf_m\s*\[0:(\d+)\]', t)
    rtl_buf = int(mbuf.group(1)) + 1 if mbuf else None
    mw = re.search(r'localparam integer USNAP_WORDS = (\d+);', s['svh'])
    words = int(mw.group(1)) if mw else None
    ok(rtl_buf is not None and words is not None and words <= rtl_buf - 1,
       f'the buffer ({rtl_buf}) holds USNAP_WORDS ({words}) below its saturating last slot')

    if verbose:
        print('== DVD.qsf ==')
    ok(re.search(r'^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+dvd/vm_snap\.sv\s*$',
                 s['qsf'], re.M) is not None, 'DVD.qsf names dvd/vm_snap.sv')

    if verbose:
        print('== dvd_ctl.cpp ==')
    c = s['ctl']

    def define(name):
        m = re.search(r'#define\s+%s\s+(0x[0-9A-Fa-f]+|\d+)\b' % name, c)
        return int(m.group(1), 0) if m else None
    ok(define('UIO_DVD_VMSNAP') == rtl_cmd, 'UIO_DVD_VMSNAP == the RTL CMD')
    ok(define('DVD_VMSNAP_MAGIC') == rtl_magic, 'DVD_VMSNAP_MAGIC == the RTL MAGIC')
    ok(define('DVD_VMSNAP_HDR') == rtl_hdr, 'DVD_VMSNAP_HDR == the RTL HDR')
    mx = define('DVD_VMSNAP_MAXW')
    ok(mx is not None and words is not None and rtl_buf is not None and words <= mx <= rtl_buf,
       f'DVD_VMSNAP_MAXW ({mx}) holds a snapshot and no more than the buffer')
    ok(re.search(r'spi_uio_cmd_cont\(\s*UIO_DVD_VMSNAP\s*\)', c) is not None, 'the Main issues UIO_DVD_VMSNAP')
    return fails


MUTATIONS = [
    ('emu', '.nv_pck_lbn   (dsi_nv_pck_lbn),', '.nv_pck_lbn   (lin_blk_w),', 'position from the fetch pointer'),
    ('emu', '.first_ref_ea (dsi_1stref_ea),', '.first_ref_ea (dsi_vobu_ea),', 'has_video from the VOBU end'),
    ('emu', '.pos_clr      (load_flush),', ".pos_clr      (1'b0),", 'freshness never cleared'),
    ('emu', '.dsi_1stref_ea  (dsi_1stref_ea),', '.dsi_1stref_ea  (),', 'nav_dsi 1stref_ea left open'),
    ('emu', '.snap_req      (vm_snap_req),', ".snap_req      (1'b0),", 'the VM never sees a request'),
    ('emu', 'assign ext_bus[15:0] = trc_drive ? trc_dout : snap_drive ? snap_dout : telem_dout;',
     'assign ext_bus[15:0] = trc_drive ? trc_dout : telem_dout;', 'the snapshot never reaches the bus'),
    ('emu', 'assign ext_bus[32]   = telem_drive | trc_drive | snap_drive;',
     'assign ext_bus[32]   = telem_drive | trc_drive;', 'the snapshot never takes the bus'),
    ('vm', 'assign snap_we  = o_we && (out_port == UOUT_SNAP);', 'assign snap_we  = o_we;',
     'every microcode output written into the snapshot'),
    ('qsf', 'set_global_assignment -name SYSTEMVERILOG_FILE dvd/vm_snap.sv\n', '', 'qsf forgets the module'),
    ('ctl', '#define DVD_VMSNAP_MAGIC    0x5E02', '#define DVD_VMSNAP_MAGIC    0x5E01', 'Main magic drifts'),
    ('ctl', '#define UIO_DVD_VMSNAP      0x7D', '#define UIO_DVD_VMSNAP      0x7C', 'Main asks nav_trace'),
    ('ctl', '#define DVD_VMSNAP_HDR      13', '#define DVD_VMSNAP_HDR      12', 'Main header one short'),
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
                print(f'  FAIL wiring mutation NOT caught: {what}')
                bad += 1
        print('RESULT: ' + ('PASS' if not bad else 'FAIL'))
        return 1 if bad else 0
    fails = run(txt)
    print('RESULT: ' + ('PASS' if not fails else f'FAIL ({len(fails)})'))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
