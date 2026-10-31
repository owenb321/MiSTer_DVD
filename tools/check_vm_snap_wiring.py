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
  emu.sv        every vm_snap port, by expression; the Save State rows' bits in
                CONF_STR (Slot O[59:57], Save R[55], Load R[56]) and their edges; dvd_vm's five snap_* ports on the
                same nets; nav_dsi's 1stref_ea / prev_video connected to the nets
                vm_snap reads (it left them open before); the EXT_BUS OR and mux
  dvd_vm.sv     snap_we is the O_SNAP output strobe; snap_d the output bus; the
                request is offered only after every event and only with no held part
  vm_snap.sv    CMD 0x7D, MAGIC 0x5E03 with bit 15 clear, HDR 13; no other EXT_BUS
                module answers 0x7D
  DVD.qsf       names dvd/vm_snap.sv
  dvd_vmsnap.h  UIO_DVD_VMSNAP / DVD_VMSNAP_MAGIC / DVD_VMSNAP_HDR equal the RTL's;
                DVD_VMSNAP_MAXW holds the snapshot (>= USNAP_WORDS, <= the buffer);
                the VMSNAP_* word-2 field macros sit where vm_snap.sv packs them

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
    'ctl': 'main/support/dvd/dvd_vmsnap.h', 'vcpp': 'main/support/dvd/dvd_vmsnap.cpp',
    'svh': 'dvd/nav/nav_ucode.svh',
    'pci': 'dvd/nav_pci.sv',
}

# vm_snap port -> the emu.sv expression it must be connected to (whitespace-free)
SNAP_PORTS = {
    'clk': 'clk_sys', 'rst_n': 'reset_n',
    'io_enable': 'ext_bus[34]', 'io_strobe': 'ext_bus[33]', 'io_din': 'ext_bus[31:16]',
    'drive': 'snap_drive', 'dout': 'snap_dout',
    'snap_req': 'vm_snap_req', 'snap_we': 'vm_snap_we', 'snap_d': 'vm_snap_d',
    'snap_done': 'vm_snap_done', 'snap_fmt': 'vm_snap_fmt',
    'restore_req': 'vm_rst_req', 'rst_ra': 'vm_rst_ra', 'rst_q': 'vm_rst_q',
    'rst_done': 'vm_rst_done',
    'pos_clr': 'load_flush', 'pos_commit': 'dsi_commit',
    'nv_pck_lbn': 'dsi_nv_pck_lbn', 'first_ref_ea': 'dsi_1stref_ea',
    'prev_video': 'dsi_prev_video', 'c_eltm': 'dsi_c_eltm', 'vob_idn': 'dsi_vob_idn',
    'c_idn': 'dsi_c_idn',
    # the displayed time's raw parts and the landing (docs/nav_engine.md §10): the HUD
    # clock, the front VOBU's s_ptm, the STC; the reader's load, the first picture, a
    # menu, a mount; and the seek it fires
    'eltm': 'whole_eltm_w', 'vobu_sptm': 'hl_vobu_sptm_w', 'stc': 'av_stc',
    'pgc_loaded': 'pgc_loaded', 'video_live': 'video_live_s2', 'menu_active': 'menu_active',
    'mount': 'start_streaming', 'rst_seek_pulse': 'rst_seek_pulse',
    'rst_seek_secs': 'rst_seek_secs', 'rst_seek_rbn': 'rst_seek_rbn',
    # the OSD's Save State rows (save states step 4, docs/nav_engine.md §11): one edge
    # per press, the Slot row, and Disc Menus (the VM's own enable: a restore needs it)
    'ui_save': 'ss_save_edge', 'ui_load': 'ss_load_edge', 'ui_slot': 'status[59:57]',
    'vm_en': 'menus_on',
    # the restored highlight (docs/nav_engine.md §11c): nav_pci's arms end keep_sel,
    # which nav_pci reads (pinned on both ends below)
    'hli_arm': 'hli_arm_w', 'keep_sel': 'ss_keep_sel',
}
VM_PORTS = {'snap_req': 'vm_snap_req', 'snap_we': 'vm_snap_we', 'snap_d': 'vm_snap_d',
            'snap_done': 'vm_snap_done', 'snap_fmt': 'vm_snap_fmt',
            'restore_req': 'vm_rst_req', 'rst_ra': 'vm_rst_ra', 'rst_q': 'vm_rst_q',
            'rst_done': 'vm_rst_done', 'jump_ttn_hint': 'vm_jump_ttn_hint',
            'jump_ttn': 'vm_jump_ttn', 'jump_pgcn': 'vm_jump_pgcn'}
# the reader takes the restore's jump from the same nets (a hint on another net would
# land the right PGC with another title's chapter map)
RD_PORTS = {'jump_ttn_hint': 'vm_jump_ttn_hint', 'jump_ttn': 'vm_jump_ttn',
            'jump_pgcn': 'vm_jump_pgcn'}
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
    rd = connections(em, 'dvd_iso_reader')
    for port, want in RD_PORTS.items():
        pin(rd, 'dvd_iso_reader', port, want)
    pin(vm, 'dvd_vm', 'enable', 'menus_on')            # vm_en must be the VM's own enable
    # the user's Audio / Subtitle choice written back to SPRM1 / SPRM2 (a save state
    # carries it; a disc command reads it), and the user side synced on a restore
    for port, want in (('ast_set', 'ast_wb'), ('ast_set_val', 'ast_wb_val'),
                       ('spst_set', 'spst_wb'), ('spst_set_val', 'spst_wb_val')):
        pin(vm, 'dvd_vm', port, want)
    ok(re.search(r'\baud_step_q\s*<=\s*aud_step_w\s*;', em) is not None and
       re.search(r'if\s*\(\s*aud_step_q\s*\)\s*begin\s*ast_wb\s*<=\s*1\'b1;\s*ast_wb_val\s*<=\s*\{5\'d0,\s*aud_log\}\s*;', em) is not None,
       'ast_wb: one cycle after the Audio step, the effective aud_log')
    ok(re.search(r'spst_wb_val\s*<=\s*sub_on_eff\s*\?\s*\{2\'b01,\s*1\'b0,\s*sp_sel\}\s*:\s*\{2\'b00,\s*vm_spstn\[5:0\]\}\s*;', em) is not None,
       'spst_wb_val: {display, the effective stream}, or SPRM2\'s stream with display off')
    ok(re.search(r'else\s+if\s*\(\s*vm_rst_done\s*\)\s*begin\s*aud_cur\s*<=', em) is not None,
       'a restore syncs aud_cur / sub_on / sub_idx from the restored SPRMs')
    for bits, row in (('O[59:57]', 'Slot,1,2,3,4,5,6,7,8'), ('R[55]', 'Save to Slot'), ('R[56]', 'Load Slot')):
        ok(re.search(r'"P6' + re.escape(bits + ',' + row) + r';"', em) is not None,
           f'CONF_STR has P6{bits},{row}')
    # the page shows only with a DVD-Video disc (H1) and greys with Disc Menus off (D2):
    # the menu mask's bit 1 must be ~the reader's dvd_video, bit 2 Disc Menus Off
    ok(re.search(r'"H1D2P6,Save State;"', em) is not None,
       'CONF_STR has H1D2P6,Save State (hidden with no DVD-Video, greyed with Disc Menus off)')
    hp = connections(em, 'hps_io')
    mm = norm((hp or {}).get('status_menumask'))
    ok(re.fullmatch(r"\{13'd0,status\[1\],~(\w+),interlaced_eff\}", mm or '') is not None,
       "hps_io.status_menumask = {13'd0, status[1], ~<dvd_video net>, interlaced_eff}"
       + ('' if mm else '   got: None'))
    dv = re.fullmatch(r"\{13'd0,status\[1\],~(\w+),interlaced_eff\}", mm or '')
    pin(rd, 'dvd_iso_reader', 'dvd_video', dv.group(1) if dv else 'rdr_dvd_video_w')
    for n, b in (('save', 55), ('load', 56)):
        ok(re.search(r'\bss_%s_q\s*<=\s*status\[%d\]\s*;' % (n, b), em) is not None and
           re.search(r'\bwire\s+ss_%s_edge\s*=\s*status\[%d\]\s*&\s*~\s*ss_%s_q\s*;' % (n, b, n), em) is not None,
           f'ss_{n}_edge = the rising edge of status[{b}]')
    pc = connections(em, 'nav_pci')
    pin(pc, 'nav_pci', 'vobu_sptm', 'hl_vobu_sptm_w')
    pin(pc, 'nav_pci', 'keep_sel', 'ss_keep_sel')      # a restore's landing keeps its button
    pin(pc, 'nav_pci', 'hli_arm', 'hli_arm_w')         # ...and the arm that ends it is nav_pci's
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
    mh = re.search(r"localparam\s*\[4:0\]\s*HDR\s*=\s*5'd(\d+)", t)
    rtl_cmd = int(mc.group(1), 16) if mc else None
    rtl_magic = int(mm.group(1), 16) if mm else None
    rtl_hdr = int(mh.group(1)) if mh else None
    ok(rtl_cmd == 0x7D, 'vm_snap CMD = 0x007D')
    ok(rtl_magic is not None and rtl_magic != 0 and not (rtl_magic & 0x8000),
       'vm_snap MAGIC non-zero with bit 15 clear')
    ok(rtl_hdr == 19, 'vm_snap HDR = 19')
    ok(re.search(r'\bassign\s+vobu_sptm\s*=\s*f_vptm\s*;', strip_comments(txt['pci'])) is not None,
       'nav_pci vobu_sptm = f_vptm (pci_gi.vobu_s_ptm)')
    mwd = re.search(r"parameter\s*\[7:0\]\s*WORDS\s*=\s*8'd(\d+)", t)
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
    ok(mwd is not None and words is not None and int(mwd.group(1)) == words,
       f'vm_snap WORDS ({mwd.group(1) if mwd else None}) = USNAP_WORDS ({words}): a load is checked against it')
    ok(re.search(r'q\s*<=\s*buf_m\[\s*rbusy\s*\?\s*rst_ra\s*:\s*raddr\s*\]\s*;', t) is not None,
       'the buffer read port is the VM\'s while a restore is pending')

    if verbose:
        print('== DVD.qsf ==')
    ok(re.search(r'^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+dvd/vm_snap\.sv\s*$',
                 s['qsf'], re.M) is not None, 'DVD.qsf names dvd/vm_snap.sv')

    if verbose:
        print('== dvd_vmsnap.h / .cpp ==')
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
    ok(re.search(r'spi_uio_cmd_cont\(\s*UIO_DVD_VMSNAP\s*\)', s['vcpp']) is not None, 'the Main issues UIO_DVD_VMSNAP')
    # word 2's fields: the RTL's concatenation, MSB first, against the Main's shifts
    m2 = re.search(r"5'd2:\s*dout_r\s*<=\s*\{([^}]*)\}\s*;", t)
    order = [x.strip() for x in m2.group(1).split(',')] if m2 else []
    widths = {'busy_s': 1, 'vm_en': 1, 'slot_l': 3, 'ld_n': 2, 'sv_n': 2, 'len_s': 7}
    pos, at = {}, 16
    for f in order:
        at -= widths.get(f, 99)
        pos[f] = at
    want = {'busy_s': ('VMSNAP_BUSY', 1), 'vm_en': ('VMSNAP_VM_EN', 1), 'slot_l': ('VMSNAP_SLOT', 7),
            'ld_n': ('VMSNAP_LOAD_N', 3), 'sv_n': ('VMSNAP_SAVE_N', 3)}
    ok(at == 0 and set(order) == set(widths), f'vm_snap word 2 is the six fields, 16 bits ({order})')
    for f, (mac, mask) in want.items():
        mm2 = re.search(r'#define\s+%s\(w2\)\s+\(\(\(w2\)\s*>>\s*(\d+)\)\s*&\s*(\d+)\)' % mac, c)
        ok(mm2 is not None and int(mm2.group(1)) == pos.get(f) and int(mm2.group(2)) == mask,
           f'{mac} reads bit {pos.get(f)} (mask {mask}), where vm_snap packs {f}')
    return fails


MUTATIONS = [
    ('emu', ".keep_sel   (ss_keep_sel),", ".keep_sel   (1'b0),", 'nav_pci never keeps the restored button'),
    ('emu', ".hli_arm        (hli_arm_w),        // the landing's HLI ends keep_sel",
     ".hli_arm        (1'b0),        // the landing's HLI ends keep_sel", 'keep_sel never ends (no HLI arm)'),
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
    ('emu', '.jump_ttn_hint  (vm_jump_ttn_hint),', ".jump_ttn_hint  (1'b0),", 'the reader never sees the hint'),
    ('emu', '.rst_q         (vm_rst_q),', ".rst_q         (16'd0),", 'the VM restores zeros'),
    ('emu', '.rst_done     (vm_rst_done),', ".rst_done     (1'b0),", 'vm_snap never hears the restore end'),
    ('snap', "parameter [7:0]  WORDS = 8'd96", "parameter [7:0]  WORDS = 8'd95", 'loads checked against the wrong length'),
    ('qsf', 'set_global_assignment -name SYSTEMVERILOG_FILE dvd/vm_snap.sv\n', '', 'qsf forgets the module'),
    ('ctl', '#define DVD_VMSNAP_MAGIC    0x5E03', '#define DVD_VMSNAP_MAGIC    0x5E02', 'Main magic drifts (a 4-slot-layout Main)'),
    ('ctl', '#define UIO_DVD_VMSNAP      0x7D', '#define UIO_DVD_VMSNAP      0x7C', 'Main asks nav_trace'),
    ('ctl', '#define DVD_VMSNAP_HDR      19', '#define DVD_VMSNAP_HDR      18', 'Main header one short'),
    ('ctl', '#define VMSNAP_SLOT(w2)     (((w2) >> 11) & 7)', '#define VMSNAP_SLOT(w2)     (((w2) >> 11) & 3)',
     'the Main reads the load count as the slot'),
    ('snap', "5'd2: dout_r <= {busy_s, vm_en, slot_l, ld_n, sv_n, len_s};",
     "5'd2: dout_r <= {busy_s, vm_en, slot_l, sv_n, ld_n, len_s};", 'the RTL swaps the two counts'),
    ('emu', '.stc          (av_stc),             // ...and the displayed picture\'s PTS',
     '.stc          (33\'d0),', 'the displayed PTS tied off'),
    ('emu', '.eltm         (whole_eltm_w),       // the HUD clock, at the demux front',
     '.eltm         (dsi_c_eltm),', 'the cell clock instead of the PGC clock'),
    ('emu', '.video_live   (video_live_s2),', ".video_live   (1'b1),", 'the seek fires before a picture'),
    ('emu', '.ui_slot      (status[59:57]),', '.ui_slot      (status[58:56]),', 'the slot read off the wrong bits'),
    ('emu', '.ui_load      (ss_load_edge),', '.ui_load      (ss_save_edge),', 'a save press counted as a load'),
    ('emu', '.vm_en        (menus_on),', ".vm_en        (1'b1),", 'loads sent to a disabled VM'),
    ('emu', 'wire ss_save_edge = status[55] & ~ss_save_q;', 'wire ss_save_edge = status[55];', 'a held bit is many saves'),
    ('emu', '"P6R[56],Load Slot;",', '"P6R[57],Load Slot;",', 'the Load row on a bit the core never reads'),
    ('emu', '"H1D2P6,Save State;",', '"P6,Save State;",', 'the Save State page shown with no DVD-Video disc'),
    ('emu', "status[1], ~rdr_dvd_video_w, interlaced_eff}", "status[1], rdr_dvd_video_w, interlaced_eff}",
     'the Save State page hidden exactly when a DVD-Video disc IS mounted'),
    ('emu', '.dvd_video      (rdr_dvd_video_w),', ".dvd_video      (),", 'the reader\'s dvd_video left open'),
    ('emu', '.ast_set       (ast_wb),', ".ast_set       (1'b0),", 'the Audio write-back never reaches the VM'),
    ('emu', 'if (aud_step_q) begin ast_wb <= 1\'b1; ast_wb_val <= {5\'d0, aud_log}; end',
     'if (aud_step_q) begin ast_wb <= 1\'b1; ast_wb_val <= {5\'d0, aud_cur}; end', 'the write-back from the user register, not the effective track'),
    ('emu', '    end else if (vm_rst_done) begin', '    end else if (1\'b0) begin', 'a restore leaves the user side as it was'),
    ('pci', 'assign vobu_sptm     = f_vptm;', 'assign vobu_sptm     = f_sptm;', 'the HLI start PTS, not the VOBU\'s'),
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
