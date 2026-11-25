#!/usr/bin/env python3
"""Gate for trick play's seams in dvd/emu.sv (docs/trick_play.md "Wiring").

Each module has its own bench (run_trick_ctrl, run_trick_reader, run_trick_demux,
run_trick_es_filter, run_disp_sched [15]), and each is handed its inputs. What no
module bench can see is whether emu.sv connects them: a reader port left on the
tie-off, the filter bypassed, the cadence fed from the wrong clock domain. emu.sv has
no bench, so this reads the connections out of it.

Checked:
  * trick_ctrl: FF/REW, `allowed`, the playhead, the reader's arm/nav/edge in; its
    outputs are the nets the rest use; `allowed` is a DVD title with no menu,
    in-title menu, armed buttons, still or stop; trick_claim = allowed | owns;
  * scrub_ctrl sees FF/REW only through ~trick_claim;
  * the seek: trick_seek_pulse/rbn reach the reader through seek_any (mode_realign's
    arbitration) and NOT through seek_tm_req (a sector seek, not a time seek);
  * the reader's trick ports are the controller's nets (not the tie-offs);
  * ps_demux: .aud_drop(trick_active); sp_enable and pci_enable gated by ~trick_active;
  * the ES filter sits between ps_demux and es_stuff, enabled by trick_active and
    reset by pipe_rst_n (the entry seek restarts its hunt);
  * mpeg2video .trick_cad is trick_active crossed into clk_dec by two flops;
  * DVD.qsf names dvd/trick_ctrl.sv and dvd/trick_es_filter.sv (a file it does not
    name is invisible to Quartus);
  * the HUD's user event includes trick play's seek;
  * the HUD clock adds a cell start and a c_eltm latched TOGETHER at dsi_commit
    (dropped by pipe_rst_n), not the reader-timed cell start.

    python3 tools/check_trick_wiring.py [emu.sv]
    python3 tools/check_trick_wiring.py --red    # each re-regression must FAIL

Walks to each instantiation's matching ')' and strips comments: do NOT "simplify" it
to a grep (the comments above these instances quote the nets).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')


def strip_comments(src):
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
        else:
            out.append(src[i])
            i += 1
    return ''.join(out)


def inst(src, module):
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(', src, re.S)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def inst_named(src, module, name):
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+' + re.escape(name) + r'\s*\(', src)
    if not m:
        return None
    i, depth = m.end() - 1, 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    return None


def port(body, name):
    """The expression connected to .name( ... ), balanced parentheses."""
    m = re.search(r'\.' + re.escape(name) + r'\s*\(', body)
    if not m:
        return None
    i, depth = m.end() - 1, 0
    for j in range(i, len(body)):
        if body[j] == '(':
            depth += 1
        elif body[j] == ')':
            depth -= 1
            if depth == 0:
                return ' '.join(body[i + 1:j].split())
    return None


def assign_rhs(src, name):
    m = re.search(r'(?:wire|assign)\s+(?:\[[^\]]*\]\s*)?' + re.escape(name) + r'\s*=\s*([^;]*);', src)
    return None if not m else ' '.join(m.group(1).split())


def check(emu_src, qsf_src):
    src = strip_comments(emu_src)
    bad = []

    def want(cond, msg):
        if not cond:
            bad.append(msg)

    tc = inst(src, 'trick_ctrl')
    rd = inst(src, 'dvd_iso_reader')
    pd = inst(src, 'ps_demux')
    tf = inst(src, 'trick_es_filter')
    sh = inst(src, 'es_stuff')
    sc = inst(src, 'scrub_ctrl')
    mv = inst(src, 'mpeg2video')
    for n, b in (('trick_ctrl', tc), ('dvd_iso_reader', rd), ('ps_demux', pd),
                 ('trick_es_filter', tf), ('es_stuff', sh), ('scrub_ctrl', sc), ('mpeg2video', mv)):
        want(b is not None, f'{n} is not instantiated in emu.sv')
    if bad:
        return bad

    # the controller
    for p, net in (('held_ff', 'joy_ff | kbd_ff_held'), ('held_rew', 'joy_rew | kbd_rew_held'),
                   ('allowed', 'trick_allowed'),
                   ('cur_rbn', 'dsi_nv_pck_lbn'), ('trick_vobu', 'trick_vobu_w'),
                   ('trick_nav', 'trick_nav_w'), ('trick_edge', 'trick_edge_w'),
                   ('active', 'trick_active'), ('tier', 'trick_tier'), ('rev', 'trick_rev'),
                   ('go', 'trick_go'), ('seek_pulse', 'trick_seek_pulse'),
                   ('seek_rbn', 'trick_seek_rbn'), ('owns', 'trick_owns')):
        want(port(tc, p) == net, f'trick_ctrl .{p} is {port(tc, p)!r}, must be {net}')
    al = assign_rhs(src, 'trick_allowed') or ''
    for need in ('cell_ready', '!menu_active', '!in_title_menu', '!menu_nav',
                 '!hl_btns_armed', '!still_active', '!stopped_w'):
        want(need in al.replace(' ', ''), f'trick_allowed lacks {need}: {al!r}')
    want(assign_rhs(src, 'trick_claim') == 'trick_allowed || trick_owns',
         f"trick_claim must be trick_allowed || trick_owns, is {assign_rhs(src, 'trick_claim')!r}")

    # the scrub never sees a gesture trick play owns
    want(port(sc, 'held_right') == 'joy_ff & ~trick_claim',
         f"scrub_ctrl .held_right is {port(sc, 'held_right')!r}, must be joy_ff & ~trick_claim")
    want(port(sc, 'held_left') == 'joy_rew & ~trick_claim',
         f"scrub_ctrl .held_left is {port(sc, 'held_left')!r}, must be joy_rew & ~trick_claim")

    # the seek: through the arbitration, and not a time seek
    sap = assign_rhs(src, 'seek_any_pulse') or ''
    sar = assign_rhs(src, 'seek_any_rbn') or ''
    want(re.search(r'\btrick_seek_pulse\b', sap), f'seek_any_pulse lacks trick_seek_pulse: {sap!r}')
    want('trick_seek_pulse ? trick_seek_rbn' in sar, f'seek_any_rbn lacks trick_seek_rbn: {sar!r}')
    tm = port(rd, 'seek_tm_req') or ''
    want('trick' not in tm and 'seek_any' not in tm, f'reader .seek_tm_req carries trick play: {tm!r}')
    hud = assign_rhs(src, 'hud_user_evt') or ''
    want(re.search(r'\btrick_seek_pulse\b', hud), 'hud_user_evt lacks trick_seek_pulse')

    # the reader
    for p, net in (('trick_en', 'trick_active'), ('trick_tier', 'trick_tier'),
                   ('trick_rev', 'trick_rev'), ('trick_go', 'trick_go'),
                   ('trick_vobu', 'trick_vobu_w'), ('trick_nav', 'trick_nav_w'),
                   ('trick_edge', 'trick_edge_w')):
        want(port(rd, p) == net, f'dvd_iso_reader .{p} is {port(rd, p)!r}, must be {net}')

    # the demux
    want(port(pd, 'aud_drop') == 'trick_active', f"ps_demux .aud_drop is {port(pd, 'aud_drop')!r}")
    want(re.search(r'&\s*~\s*trick_active\b', port(pd, 'sp_enable') or ''),
         f"ps_demux .sp_enable is not gated by ~trick_active: {port(pd, 'sp_enable')!r}")
    want(re.search(r'&\s*~\s*trick_active\b', port(pd, 'pci_enable') or ''),
         f"ps_demux .pci_enable is not gated by ~trick_active: {port(pd, 'pci_enable')!r}")

    # the ES filter between the demux and the shim
    want(port(tf, 'en') == 'trick_active', f"trick_es_filter .en is {port(tf, 'en')!r}")
    want(port(tf, 'rst_n') == 'pipe_rst_n', f"trick_es_filter .rst_n is {port(tf, 'rst_n')!r}, must be pipe_rst_n")
    for dp, fi, fo, sp in (('vid_byte', 'in_byte', 'out_byte', 'in_byte'),
                           ('vid_mark', 'in_mark', 'out_mark', 'in_mark'),
                           ('vid_valid', 'in_valid', 'out_valid', 'in_valid'),
                           ('vid_ready', 'in_ready', 'out_ready', 'in_ready')):
        want(port(pd, dp) == port(tf, fi), f'ps_demux .{dp} ({port(pd, dp)!r}) != trick_es_filter .{fi} ({port(tf, fi)!r})')
        want(port(tf, fo) == port(sh, sp), f'trick_es_filter .{fo} ({port(tf, fo)!r}) != es_stuff .{sp} ({port(sh, sp)!r})')

    # the cadence: trick_active, two flops into clk_dec
    want(port(mv, 'trick_cad') == 'trick_cad_dec', f"mpeg2video .trick_cad is {port(mv, 'trick_cad')!r}")
    m = re.search(r'always\s*@\s*\(\s*posedge\s+clk_dec\s*\)\s*begin\s*trick_cad_s1\s*<=\s*trick_active\s*;'
                  r'\s*trick_cad_dec\s*<=\s*trick_cad_s1\s*;\s*end', src)
    want(m, 'trick_cad_dec is not trick_active through two clk_dec flops')

    # keyboard / remote FF/REW: a tap is the 10 s jump, a hold is trick play (kbd_hold)
    km = inst(src, 'kbd_map')
    want(km is not None and port(km, 'rel') == 'kbd_rel', 'kbd_map .rel is not kbd_rel')
    for name, press, rel, tap, held in (('kbd_hold_ff', 'kbd_joy[13]', 'kbd_rel[0]', 'kbd_ff_tap', 'kbd_ff_held'),
                                        ('kbd_hold_rew', 'kbd_joy[14]', 'kbd_rel[1]', 'kbd_rew_tap', 'kbd_rew_held')):
        b = inst_named(src, 'kbd_hold', name)
        want(b is not None, f'kbd_hold {name} is not instantiated')
        if b is not None:
            for p, net in (('press', press), ('release_', rel), ('tap', tap), ('held', held)):
                want(port(b, p) == net, f'{name} .{p} is {port(b, p)!r}, must be {net}')
    want(assign_rhs(src, 'kbd_ff_jump') == 'trick_claim ? kbd_ff_tap : kbd_joy[13]',
         f"kbd_ff_jump is {assign_rhs(src, 'kbd_ff_jump')!r}")
    want(assign_rhs(src, 'kbd_rew_jump') == 'trick_claim ? kbd_rew_tap : kbd_joy[14]',
         f"kbd_rew_jump is {assign_rhs(src, 'kbd_rew_jump')!r}")
    ds = inst(src, 'dpad_seek')
    if ds is not None:
        want(re.search(r'\bkbd_ff_jump\b', port(ds, 'rt_edge') or '') and 'kbd_joy' not in (port(ds, 'rt_edge') or ''),
             f"dpad_seek .rt_edge is not the keyboard FF tap: {port(ds, 'rt_edge')!r}")
        want(re.search(r'\bkbd_rew_jump\b', port(ds, 'lf_edge') or '') and 'kbd_joy' not in (port(ds, 'lf_edge') or ''),
             f"dpad_seek .lf_edge is not the keyboard REW tap: {port(ds, 'lf_edge')!r}")

    # the HUD: the line stays up, the direction arrows show the tier
    th = inst(src, 'transport_hud')
    want(th is not None, 'transport_hud is not instantiated')
    if th is not None:
        want(re.search(r'\btrick_active\b', port(th, 'bar_active') or ''),
             f"transport_hud .bar_active lacks trick_active: {port(th, 'bar_active')!r}")
        want(re.search(r'\btrick_active\b', port(th, 'scrub_held') or ''),
             f"transport_hud .scrub_held lacks trick_active: {port(th, 'scrub_held')!r}")
        want((port(th, 'scrub_tier') or '').startswith('trick_active ? trick_tier'),
             f"transport_hud .scrub_tier is not trick_tier in trick play: {port(th, 'scrub_tier')!r}")
        want((port(th, 'scrub_dir') or '').startswith('trick_active ? ~trick_rev'),
             f"transport_hud .scrub_dir is not ~trick_rev in trick play: {port(th, 'scrub_dir')!r}")
    sb = inst(src, 'seek_bar')
    if sb is not None:
        want('trick' not in (port(sb, 'active') or port(sb, 'bar_active') or ''),
             'seek_bar shows in trick play (it is the scrub\'s bar: base and target are stale)')
        want(re.search(r'\|\s*trick_active\s*\)?\s*$', (port(sb, 'force_show') or '').strip()),
             f"seek_bar .force_show lacks trick_active (no progress bar in trick play): {port(sb, 'force_show')!r}")

    # the HUD clock: cell start and cell-elapsed from the SAME NAV pack (latched
    # together at dsi_commit), else a cell crossing reads a cell ahead, then back
    ta = inst(src, 'bcd_time_add')
    want(ta is not None, 'bcd_time_add (the HUD clock) is not instantiated')
    if ta is not None:
        want(re.sub(r'\s+', ' ', port(ta, 'a') or '') == 'hud_pair_v ? hud_cs_l : cur_cell_start_w',
             f"hud_time_add .a is not the latched cell start: {port(ta, 'a')!r}")
        want(re.sub(r'\s+', ' ', port(ta, 'b') or '') == 'hud_pair_v ? hud_eltm_l : dsi_c_eltm',
             f"hud_time_add .b is not the latched c_eltm: {port(ta, 'b')!r}")
    want(re.search(r'else if \(dsi_commit\) begin\s*hud_pair_v <= 1\'b1; hud_cs_l <= cur_cell_start_w; '
                   r'hud_eltm_l <= dsi_c_eltm;', src),
         'the HUD clock pair is not latched together at dsi_commit')
    want(re.search(r'always @\(posedge clk_sys or negedge pipe_rst_n\) begin\s*if \(!pipe_rst_n\) begin\s*'
                   r'hud_pair_v <= 1\'b0;', src),
         'the HUD clock pair is not dropped by a flush (pipe_rst_n)')

    # Quartus sees the files
    for f in ('dvd/trick_ctrl.sv', 'dvd/trick_es_filter.sv', 'dvd/kbd_hold.sv'):
        want(re.search(r'(?m)^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+' + re.escape(f) + r'\s*$',
                       qsf_src), f'DVD.qsf does not name {f}')
    return bad


RED = [
    ('R1 the reader left on the tie-off', '.trick_en       (trick_active),', ".trick_en       (1'b0),"),
    ('R2 the scrub still takes FF', '.held_right      (joy_ff  & ~trick_claim),', '.held_right      (joy_ff),'),
    ('R3 the seek bypasses the arbitration',
     'wire        seek_any_pulse = scrub_seek_pulse | rst_seek_pulse | trick_seek_pulse;',
     'wire        seek_any_pulse = scrub_seek_pulse | rst_seek_pulse;'),
    ('R4 audio not dropped', '.aud_drop     (trick_active),', ".aud_drop     (1'b0),"),
    ('R5 subtitles over trick frames', '.sp_enable    (sp_route_en & ~trick_active),', '.sp_enable    (sp_route_en),'),
    ('R6 buttons over trick frames', '.pci_enable       (menus_on & ~trick_active),', '.pci_enable       (menus_on),'),
    ('R7 the filter bypassed', '.in_byte    (tf_byte),', '.in_byte    (ps_vid_byte),'),
    ('R8 the filter never reset', '.rst_n     (pipe_rst_n),\n    .en        (trick_active),',
     '.rst_n     (reset_n),\n    .en        (trick_active),'),
    ('R9 the cadence from clk_sys', '.trick_cad    (trick_cad_dec),', '.trick_cad    (trick_active),'),
    ('R10 a still allowed', '!hl_btns_armed && !still_active && !stopped_w;', '!hl_btns_armed && !stopped_w;'),
    ('R11 the claim forgets an exit in progress', 'assign trick_claim   = trick_allowed || trick_owns;',
     'assign trick_claim   = trick_allowed;'),
    ('R14 the HUD line hides mid-gesture', '.bar_active   (bar_active_w | trick_active),', '.bar_active   (bar_active_w),'),
    ('R15 the arrows ignore the tier', '.scrub_tier   (trick_active ? trick_tier : hold_freeze ? hud_tier_w : 2\'d0),',
     '.scrub_tier   (hold_freeze ? hud_tier_w : 2\'d0),'),
    ('R16 a keyboard hold never reaches trick play', '.held_ff    (joy_ff  | kbd_ff_held),', '.held_ff    (joy_ff),'),
    ('R17 a keyboard hold also jumps 10 s', 'wire kbd_ff_jump  = trick_claim ? kbd_ff_tap  : kbd_joy[13];',
     'wire kbd_ff_jump  = kbd_joy[13];'),
    ('R18 the jump bypasses the tap', '.rt_edge        ((dpad_seek_en & rt_edge) | kbd_ff_jump),',
     '.rt_edge        ((dpad_seek_en & rt_edge) | kbd_joy[13]),'),
    ('R19 the HUD clock adds the reader-timed cell start', '.a   (hud_pair_v ? hud_cs_l   : cur_cell_start_w),',
     '.a   (cur_cell_start_w),'),
    ('R20 the pair not latched at a NAV pack', 'end else if (dsi_commit) begin\n        hud_pair_v',
     'end else if (1\'b0) begin\n        hud_pair_v'),
    ('R21 the pair survives a flush', "hud_pair_v <= 1'b0; hud_cs_l <= 32'd0;", "hud_cs_l <= 32'd0;"),
    ('R22 no progress bar in trick play', '.force_show ((cdda_mode_w && hud_persist_w) | trick_active),',
     '.force_show ((cdda_mode_w && hud_persist_w)),'),
    ('R12 connection only in a comment', '.trick_go       (trick_go),', ".trick_go       (1'b0), // (trick_go)"),
]
RED_QSF = ('R13 Quartus does not see the filter',
           'set_global_assignment -name SYSTEMVERILOG_FILE dvd/trick_es_filter.sv\n', '')


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    emu = args[0] if args else os.path.join(ROOT, 'dvd', 'emu.sv')
    qsf = os.path.join(ROOT, 'DVD.qsf')
    e, q = open(emu).read(), open(qsf).read()
    if '--red' not in sys.argv:
        bad = check(e, q)
        for b in bad:
            print('FAIL:', b)
        if bad:
            return 1
        print('OK: trick play is wired: controller, scrub claim, seek, reader, demux, ES filter, cadence, qsf')
        return 0
    rc = 0
    for name, old, new in RED:
        if e.count(old) != 1:
            print(f'  BAD    {name}: anchor not found once'); rc = 1; continue
        bad = check(e.replace(old, new), q)
        print(f"  {'ok  ' if bad else 'MISS'}   {name} -> {bad[0] if bad else 'survived'}")
        rc |= not bad
    name, old, new = RED_QSF
    if q.count(old) != 1:
        print(f'  BAD    {name}: anchor not found once'); rc = 1
    else:
        bad = check(e, q.replace(old, new))
        print(f"  {'ok  ' if bad else 'MISS'}   {name} -> {bad[0] if bad else 'survived'}")
        rc |= not bad
    if check(e, q):
        print('  BAD    the shipping emu.sv itself fails'); rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
