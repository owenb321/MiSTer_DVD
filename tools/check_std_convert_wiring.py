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
  no std_conv_wait       passthrough starts in the gap after a mount and is torn down just as
                         audio starts: lip sync up to 210 ms off, intermittently.
  vsync arm missing      NTSC's vsync lands inside the 576-line cross mode.
  analog path (Phase 3): the plain NTSC raster with disp_vscale at 5/6 or 5/8. A wrong ratio,
                         bar or band misplaces the picture or its overlays; HUD/seek bar/logo/
                         csync/captions on the SOURCE's standard draw for 576 lines on a 480-line
                         raster; the cross modes leaking into it give a raster no CRT holds.

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
    port('rate_mode', 'std_rate_i', 'slow', 'std_conv_active',
         'the PAL source must slow by 960/1001, and only while converting')
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
    has('active', "wire std_conv_req = pal_val_s2 & pal_det_s2 & ~sif_det_s2 & ~cdda_mode_w & std_conv_on;",
        'every gate on conversion; To NTSC acts on a PAL disc only')
    has('film', "assign std_conv_film = std_conv_req & ~interlaced_eff & ~analog_want;",
        'the scaler path: only where no analog display carries the raster')
    has('analog', "assign std_conv_an = std_conv_req & (interlaced_eff | analog_want);",
        'the analog path: wherever the scaler path is not')
    has('either', "assign std_conv_active = std_conv_film | std_conv_an;", 'both flavours change the rate')
    has('ov_pal', "assign ov_pal = pal_eff & ~std_conv_an;", 'overlays after the scaler follow the raster')
    has('sel', "wire std_conv_on = status[53];", 'the option must be O[53]')
    has('conf', '"P1O[53],Standard Convert,Off,To NTSC;"', 'the OSD row')
    has('src_pal', "assign pal_eff = std_conv_active ? pal_det_s2 :",
        'while converting pal_eff is the source, past the force row')
    has('raster', "wire pal_out = pal_eff ^ std_conv_active;", 'only the modeline takes the target standard')
    has('half_scan', "pal_s1_dec <= pal_eff;", 'half_scan must be in source ticks')
    has('disp_fps', "film24_eff ? 6'd24 : film25_eff ? 6'd25 :",
        'cell_secs must count source pictures per authored second')
    has('film24', "wire film24_eff = filmp_eff & ~pal_eff;", 'film24_eff follows the source')
    has('filmp', "wire filmp_eff = (film_want & ~interlaced_eff & (film_forced | ~analog_want)) | std_conv_film;",
        'the scaler path holds the film raster; the analog path must not')
    for inst in ('transport_hud_inst', 'seek_bar_inst', 'idle_logo_inst'):
        port('overlay', inst, 'pal_mode', 'ov_pal', 'overlays are drawn on the raster after the scaler')
    has('act_vres', "wire [11:0] act_vres = p240_eff ? (ov_pal ? 12'd288 : 12'd240) : (ov_pal ? 12'd576 : 12'd480);",
        'the overlays\' active window is the raster\'s')
    port('csync', 'csync_smpte_inst', 'pal', 'ov_pal', 'composite sync is the raster\'s standard')
    has('cc_pal', ".flush (load_flush), .pal (ov_pal),", 'line-21 captions are timed on the raster')
    has('disp_fps', ".disp_fps (std_conv_an ? 6'd62 :", 'cell_secs: 62.5 refreshes per authored second, rounded down')
    has('half_scan', "wire [15:0] half_scan_dec = conv_an_dec ? 16'd720",
        'one 59.94 Hz field is 1440 ticks of the slowed STC')
    has('half_sync', "conv_an_s1_dec <= std_conv_an;", 'half_scan follows the analog path')
    port('cadence', 'mpeg2video_inst', 'std_cad', 'conv_an_dec',
         'the synthetic 3:2 runs on the analog path only (480i film would be 2-2-2-4 without it)')
    has('vscale_en', "wire disp_vscale_en = analog_letterbox | std_conv_an;", 'the analog path always scales')
    has('ratio', "assign disp_vscale_ratio = ~std_conv_an ? 2'd0 : analog_letterbox ? 2'd2 : 2'd1;",
        '5/6 for Fit and Crop, one 5/8 pass for Letterbox, 3/4 otherwise')
    port('map_en', 'crt_ov_map_inst', 'letterbox_en', 'disp_vscale_en & sp_map_en',
         'menus and highlights must follow any vertical scale, not only Letterbox')
    port('map_ratio', 'crt_ov_map_inst', 'ratio', 'disp_vscale_ratio', 'the inverse must invert the scale in use')
    port('map_bar', 'crt_ov_map_inst', 'v_bar',
         "(disp_vscale_ratio == 2'd1) ? 12'd0 : (disp_vscale_ratio == 2'd2) ? 12'd60 : pal_eff ? 12'd72 : 12'd60",
         'the bars disp_vscale\'s ratio leaves on the raster')
    port('map_band', 'crt_ov_map_inst', 'v_band',
         "(disp_vscale_ratio == 2'd1) ? 12'd480 : (disp_vscale_ratio == 2'd2) ? 12'd360 : pal_eff ? 12'd432 : 12'd360",
         'the scaled content height')
    port('sub_ratio', 'sub_anchor_i', 'ratio', "(std_conv_an & ~sp_map_en) ? disp_vscale_ratio : 2'd0",
         'only raw (dialogue) subtitles are moved; a mapped context already follows the scale')
    port('sub_sy', 'sub_anchor_i', 'sy', 'sp_area_sy', 'the committed subtitle box')
    port('sub_off', 'spu_decode_inst', 'q_y_off', 'sp_y_off', 'the offset must reach the bitmap read')

    # The modeline walk.
    has('walk_kick', "|| (conv_s2 != conv_prev)", 'a conversion change must re-walk the modeline')
    has('walk_latch', "conv_prev <= conv_s2;", 'the walk must apply one consistent mode')
    has('walk_sync', "conv_s1 <= std_conv_film;", 'the cross modes are the scaler path\'s only')
    has('walk_ver', "wr_data = conv_prev ? {4'b0, 12'd576, 4'b0, 12'd1286}",
        'cross mode: the NTSC film raster totals with the PAL source active lines, checked first')
    has('walk_vsync', "wr_data = conv_prev ? {4'b0, 12'd581, 4'b0, 12'd586}",
        'vsync must sit below 576 active lines on the cross modes')
    has('dec_valid', ".valid (pal_valid_dec)", "pal_detect's per-file verdict")
    has('val_sync', "pal_val_s1 <= pal_valid_dec;", 'the verdict-valid flag crosses into clk_sys')

    # Audio.
    has('pass', "wire pass_mode = status[6] & ~cdda_mode_w & ~std_conv_active & ~std_conv_wait;",
        'a speed change cannot be passed through, nor may a session start before the verdict')
    has('pass_wait', "assign std_conv_wait = std_conv_on & ~pal_val_s2;",
        'passthrough rising in the post-mount gap delays audio by up to 210 ms')

    if fails:
        print(f'FAIL check_std_convert_wiring: {len(fails)}')
        for f in fails:
            print('  FAIL ' + f)
        return 1
    print('PASS check_std_convert_wiring')
    return 0


if __name__ == '__main__':
    sys.exit(main())
