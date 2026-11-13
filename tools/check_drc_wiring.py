#!/usr/bin/env python3
"""check_drc_wiring.py -- the OSD's Dynamic Range reaches the DRC term (issue #189).

WHY THIS IS A SCRIPT AND NOT A BENCH
------------------------------------
bench/dvd/run_imdct_eng.sh proves dts_vec's op 25 applies each drc_mode exactly, and
tools/imdct_isa.py [drc] proves the gains themselves -- but both are HANDED the mode.
Whether the OSD row moves it is a chain of connections, the first in dvd/emu.sv (no
bench):

  emu               CONF_STR "O[62:61],Dynamic Range,Normal,Full,Night" (bits 61-62 no
                    other row's), wire [1:0] aud_drc = status[62:61],
                    dvd_audio_decode .drc_mode(aud_drc)
  dvd_audio_decode  audio_engine .drc_mode(drc_mode)
  audio_engine      dts_top .drc_mode
  dts_top           dts_vec .drc_mode
and back out, the two sticky flags into telemetry word 26 (dvd_telem dts_flags [3]
DYNF seen, [4] Night cap engaged): engine -> decode -> emu -> dts_flags.

A tie-off anywhere (2'd0) is a setting that silently does nothing; a bench sees none
of it. Traps written against: strip_comments() first (the comments quote the rows);
identifiers by whole token. A lookup that finds nothing or two is a NAMED FAIL.

Usage: check_drc_wiring.py [--emu F] [--dec F] [--eng F] [--top F] [--qsf F]
(the runner mutates copies and passes them here). Exit 0 = wired; 1 = named failures.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from check_hl_btnn_wiring import strip_comments, instantiation_body, port_net  # noqa: E402
from check_dac_dither_wiring import conf_rows_bits                              # noqa: E402

BITS = {61, 62}
ROW = ',Dynamic Range,Normal,Full,Night'
FLAGS = "{3'd0,eng_last_err_w,3'd0,drc_capped_w,dts_dynf_w,dts_active_w,cb_tables_ok,~cb_busy}"


def conn(body, port):
    """The net on .port(net), the port name for an implicit .port, else None."""
    if body is None:
        return None
    net = port_net(body, port)
    if net is not None:
        return re.sub(r'\s+', '', net)
    if re.search(r'\.' + re.escape(port) + r'\s*(?=[,)]|$)', body):
        return port
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emu', default=os.path.join(ROOT, 'dvd', 'emu.sv'))
    ap.add_argument('--dec', default=os.path.join(ROOT, 'dvd', 'dvd_audio_decode.sv'))
    ap.add_argument('--eng', default=os.path.join(ROOT, 'dvd', 'audio_engine.sv'))
    ap.add_argument('--top', default=os.path.join(ROOT, 'dvd', 'dts', 'dts_top.sv'))
    ap.add_argument('--qsf', default=os.path.join(ROOT, 'DVD.qsf'))
    a = ap.parse_args()
    fails = []

    def want(where, body, port, net):
        got = conn(body, port)
        if got != net:
            fails.append(f'{where}: .{port}({got}), want .{port}({net})')

    # ---- emu.sv: the row, the decode, the instance, the flags
    emu = strip_comments(open(a.emu).read())
    rows = conf_rows_bits(emu)
    named = [s for s, b in rows if s.rstrip(';').endswith(ROW)]
    if len(named) != 1:
        fails.append(f'emu: expected one CONF_STR row "P3O[62:61]{ROW}", found {len(named)}')
    elif conf_rows_bits(f'"{named[0]}"')[0][1] != BITS:
        fails.append(f'emu: the Dynamic Range row claims {sorted(conf_rows_bits(chr(34) + named[0] + chr(34))[0][1])}, '
                     f'want {sorted(BITS)}')
    shared = [s for s, b in rows if b & BITS and not s.rstrip(';').endswith(ROW)]
    if shared:
        fails.append(f'emu: status[62:61] is also claimed by {shared} -- another option\'s saved '
                     f'value would set the dynamic range')
    sel = [re.sub(r'\s+', '', m.group(1))
           for m in re.finditer(r'\bwire\s*\[1:0\]\s*aud_drc\s*=\s*([^;]*);', emu)]
    if sel != ['status[62:61]']:
        fails.append(f'emu: expected one `wire [1:0] aud_drc = status[62:61];`, found {sel}')
    dec = instantiation_body(emu, 'dvd_audio_decode')
    if dec is None:
        fails.append('emu: dvd_audio_decode instance not found')
    else:
        want('emu dvd_audio_decode', dec, 'drc_mode', 'aud_drc')
        want('emu dvd_audio_decode', dec, 'dbg_dts_dynf', 'dts_dynf_w')
        want('emu dvd_audio_decode', dec, 'dbg_drc_capped', 'drc_capped_w')
    tel = instantiation_body(emu, 'dvd_telem')
    if conn(tel, 'dts_flags') != FLAGS:
        fails.append(f'emu dvd_telem: .dts_flags({conn(tel, "dts_flags")}), want {FLAGS} '
                     f'(bit 3 DYNF seen, bit 4 Night cap)')

    # ---- the chain down to dts_vec, and the flags back up
    d = strip_comments(open(a.dec).read())
    eng = instantiation_body(d, 'audio_engine')
    if eng is None:
        fails.append('dvd_audio_decode: audio_engine instance not found')
    want('dvd_audio_decode audio_engine', eng, 'drc_mode', 'drc_mode')
    want('dvd_audio_decode audio_engine', eng, 'n_dynf', 'eng_n_dynf')
    want('dvd_audio_decode audio_engine', eng, 'drc_capped', 'eng_drc_capped')
    for flag, src in (('dbg_dts_dynf', r'eng_n_dynf\s*!=\s*16\'d0'), ('dbg_drc_capped', r'eng_drc_capped')):
        if not re.search(r'if\s*\(\s*' + src + r'\s*\)\s*' + flag + r'\s*<=\s*1\'b1\s*;', d):
            fails.append(f'dvd_audio_decode: {flag} is not set from {src.replace(chr(92), "")}')

    e = strip_comments(open(a.eng).read())
    top = instantiation_body(e, 'dts_top')
    if top is None:
        fails.append('audio_engine: dts_top instance not found')
    want('audio_engine dts_top', top, 'drc_mode', 'drc_mode')
    want('audio_engine dts_top', top, 'dynf_frames', 'n_dynf')
    want('audio_engine dts_top', top, 'drc_capped', 'drc_capped')

    t = strip_comments(open(a.top).read())
    vec = instantiation_body(t, 'dts_vec')
    if vec is None:
        fails.append('dts_top: dts_vec instance not found')
    want('dts_top dts_vec', vec, 'drc_mode', 'drc_mode')

    # ---- DVD.qsf: every module of the chain is compiled
    qsf = open(a.qsf).read()
    for f in ('dvd/dvd_audio_decode.sv', 'dvd/audio_engine.sv', 'dvd/dts/dts_top.sv', 'dvd/dts/dts_vec.sv'):
        if not re.search(r'(?m)^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+' + re.escape(f) + r'\s*$', qsf):
            fails.append(f'DVD.qsf does not name {f}')

    if fails:
        for f in fails:
            print(f'FAIL: {f}')
        return 1
    print('OK: Dynamic Range wired (O[62:61] -> aud_drc -> dvd_audio_decode -> audio_engine -> '
          'dts_top -> dts_vec; DYNF / Night-cap flags -> dts_flags [3]/[4])')
    return 0


if __name__ == '__main__':
    sys.exit(main())
