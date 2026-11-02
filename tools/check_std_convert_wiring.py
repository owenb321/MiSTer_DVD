#!/usr/bin/env python3
"""check_std_convert_wiring.py -- Standard Convert's seams in dvd/emu.sv.

WHY THIS IS A SCRIPT AND NOT A BENCH (docs/standard_convert.md)
---------------------------------------------------------------
bench/dvd/std_rate_tb.sv proves the rate module is exact, but it hands the module its mode and
cannot see what emu.sv connects. Each seam below fails silently when wrong:

  stc_tog on stc_div     the picture plays at true speed while the raster and audio do not:
                         a steady A/V walk of 4 %.
  nav_trace on the rate  HIL trace timestamps stop mapping onto the HPS clock, and every
                         latency a harness computes is quietly wrong by 4 %.
  no trim                the same walk the other way: audio at true speed under a scaled STC.
  pal_eff inverted       overlays, half_scan and disp_fps follow the raster instead of the
                         source: subtitles land wrong and cell_secs grants false stills.
  pass_mode unguarded    a bitstream with no valid timing goes to the receiver.
  vsync arm missing      NTSC's vsync lands inside the 576-line cross mode.

strip_comments() runs first: the comments quote these nets, so a grep would pass a reverted file.
A lookup that returns None is a named FAIL, never a skip.

Usage: check_std_convert_wiring.py [--emu P]   (the runner mutates a copy and passes it here)
Exit 0 = wired as designed.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_field_blend_wiring import strip_comments, connections  # noqa: E402


def tight(s):
    return re.sub(r'\s+', '', s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emu', default=os.path.join(HERE, '..', 'dvd', 'emu.sv'))
    a = ap.parse_args()
    raw = open(a.emu).read()
    src = strip_comments(raw)
    t = tight(src)
    fails = []

    def has(name, frag, why):
        if tight(frag) not in t:
            fails.append(f'{name}: {why}\n      missing: {frag}')

    def inst_port(inst, port):
        m = re.search(r'\b' + inst + r'\s*\((.*?)\)\s*;', src, re.S)
        if not m:
            return None
        p = re.search(r'\.' + port + r'\s*\(((?:[^()]|\([^()]*\))*)\)', m.group(1))
        return tight(p.group(1)) if p else None

    def port(name, inst, pname, want, why):
        got = inst_port(inst, pname)
        if got != tight(want):
            fails.append(f'{name}: {why}\n      {inst}.{pname} is {got!r}, want {tight(want)!r}')

    # The tick: scaled for the STC, true for nav_trace.
    port('rate_mode', 'std_rate_i', 'mode', "~std_conv_active ? 2'd0 : pal_eff ? 2'd1 : 2'd2",
         'a PAL source must slow and an NTSC source must speed up, and only while converting')
    port('rate_tick', 'std_rate_i', 'tick', 'stc_rate_tick', 'the rate tick must leave the module')
    has('stc_tog', "if (stc_rate_tick) stc_tog <= ~stc_tog;", 'the STC must run from the rate tick')
    has('stc_cdc', "stc_t1 <= stc_tog;", 'the STC toggle must still cross into clk_dec')
    has('stc_div', "stc_div <= (stc_div == 9'd299) ? 9'd0 : stc_div + 9'd1;",
        'stc_div must stay a true clk_sys/300')
    port('trace_tick', 'nav_trace_inst', 'tick', "stc_div == 9'd299",
         "nav_trace's free counter must not scale with the STC")

    # The NCO follows the same ratio.
    port('trim_out', 'std_rate_i', 'nco_trim', 'dec_nco_trim', 'the trim must leave the module')
    port('trim_fs', 'std_rate_i', 'nco_fs', 'dec_nco_fs', 'the trim must see the rate the NCO runs at')
    if re.search(r'dec_nco_trim\s*=', src):
        fails.append('trim_tied: dec_nco_trim has another driver (the old tie to 0?)')
    if not re.search(r'\.nco_trim\s*\(\s*dec_nco_trim\s*\)[^;]*\.nco_fs_out\s*\(\s*dec_nco_fs\s*\)', src, re.S):
        fails.append('trim_in: dvd_audio_decode must take dec_nco_trim and report dec_nco_fs')

    # Who is the source and who is the raster.
    has('active', "assign std_conv_active = pal_val_s2 & ~sif_det_s2 & ~cdda_mode_w & ~interlaced_eff"
                  " & ~analog_want & (pal_det_s2 ? (std_conv_sel == 2'd1) : (std_conv_sel == 2'd2));",
        'every gate on conversion, and each target acting on the other standard only')
    has('sel', "wire [1:0] std_conv_sel = status[54:53];", 'the option must be O[54:53]')
    has('conf', '"P1O[54:53],Standard Convert,Off,To NTSC,To PAL;"', 'the OSD row')
    has('src_pal', "assign pal_eff = std_conv_active ? pal_det_s2 :",
        'while converting pal_eff is the source, past the force row')
    has('raster', "wire pal_out = pal_eff ^ std_conv_active;", 'only the modeline takes the target standard')
    has('half_scan', "pal_s1_dec <= pal_eff;", 'half_scan must be in source ticks')
    has('disp_fps', "film24_eff ? 6'd24 : film25_eff ? 6'd25 :",
        'cell_secs must count source pictures per authored second')
    has('film24', "wire film24_eff = filmp_eff & ~pal_eff;", 'film24_eff follows the source')
    has('filmp', "wire filmp_eff = (film_want & ~interlaced_eff & (film_forced | ~analog_want)) | std_conv_active;",
        'converting holds the film raster')
    for inst in ('transport_hud_inst', 'seek_bar_inst', 'idle_logo_inst'):
        port('overlay', inst, 'pal_mode', 'pal_eff', 'overlays are authored for the active lines, the source')

    # The modeline walk.
    has('walk_kick', "|| (conv_s2 != conv_prev)", 'a conversion change must re-walk the modeline')
    has('walk_latch', "conv_prev <= conv_s2;", 'the walk must apply one consistent mode')
    has('walk_sync', "conv_s1 <= std_conv_active;", 'the cross modes follow the verdict')
    has('walk_ver', "wr_data = conv_prev ? (pal_prev ? {4'b0, 12'd480, 4'b0, 12'd1249} : {4'b0, 12'd576, 4'b0, 12'd1286})",
        'cross modes: the raster totals with the source active lines, checked first')
    has('walk_vsync', "wr_data = conv_prev ? {4'b0, 12'd581, 4'b0, 12'd586}",
        'vsync must sit below 576 active lines on the cross modes')
    has('dec_valid', ".valid (pal_valid_dec)", "pal_detect's per-file verdict")
    has('val_sync', "pal_val_s1 <= pal_valid_dec;", 'the verdict-valid flag crosses into clk_sys')

    # Audio.
    has('pass', "wire pass_mode = status[6] & ~cdda_mode_w & ~std_conv_active;",
        'a speed change cannot be passed through')

    if fails:
        print(f'FAIL check_std_convert_wiring: {len(fails)}')
        for f in fails:
            print('  FAIL ' + f)
        return 1
    print('PASS check_std_convert_wiring')
    return 0


if __name__ == '__main__':
    sys.exit(main())
