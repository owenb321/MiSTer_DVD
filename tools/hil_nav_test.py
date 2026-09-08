#!/usr/bin/env python3
"""hil_nav_test.py -- automated on-rig regression for the DVD navigation fixes.

WHAT THIS IS FOR

Two navigation fixes need hardware evidence that a screenshot-by-eye cannot give
repeatably:

  menu-highlight (issues #60/#61) -- menus resolve their subpicture stream
      through the PGC's subp_control instead of being pinned to substream 0x20.
      The core's own O[2] diagnostic blocks are an exact discriminator here, so
      the verdict is machine-read rather than judged:

        hl_btns_armed GREEN + hl_on GREEN + spu_bytes_seen RED
            = nav_pci armed and fetched, but ps_demux filtered the SPU away
            = the wrong substream = the bug.

      A highlight is a RECOLOUR of subpicture pixels, so with no SPU the
      rectangle and colours can all be right and nothing is drawn.

  still-audio (issue #65) -- the menu-still cold re-decode replays the cell's
      audio. That symptom is AUDIBLE, so this suite captures A/V from the
      capture card and autocorrelates the audio envelope: a clip played twice
      shows a peak at a lag equal to its own length.

Everything here composes tools/mister.py and tools/hud_read.py; it adds no new
mechanism and changes nothing on the core or in Main.

Usage:
    tools/hil_nav_test.py --suite menu-highlight [--only NAME ...]
    tools/hil_nav_test.py --suite still-audio
    tools/hil_nav_test.py --list

Exit code 1 if any arm fails. Run it against the PRE-FIX build first: a suite
that cannot fail is not evidence (see bench/dvd conventions and the
`bench-that-cannot-fail` note in the project's memory).
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MISTER = os.path.join(HERE, 'mister.py')
HUDREAD = os.path.join(HERE, 'hud_read.py')

# The rig's CIFS disc share. Overridable because nothing in this repo may hardcode
# one machine's layout.
SHARE = os.environ.get('MISTER_DVD_SHARE', '/media/fat/cifs/games/DVD')


def sh(args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def mister(*argv, timeout=300):
    return sh([sys.executable, MISTER] + list(argv), timeout=timeout)


# ---------------------------------------------------------------------------
# menu-highlight suite
# ---------------------------------------------------------------------------
# Each arm: (name, disc path under SHARE, extra OSD options, key script, note)
#
# ATFIRSTSIGHT is the POSITIVE arm and the only real disc available that
# exercises the new path: its VTS_01 VTSM is 16:9 (V_ATR 0x4d00) and authors
# subp_control[0] = 0x80010000 (wide=1), and its menu VOB carries BOTH 0x20 and
# 0x21 -- so the fix routes it to the 16:9 wide art, which exists. Every other
# arm is a regression arm and must be unchanged. Neither reporter's disc can be
# played here: their bundles are nav tables only, with no VOB payload.
MENU_ARMS = [
    # ⚠ Title VTS Units=1 is LOAD-BEARING. The changed PGCs are VTS_01 VTSM 1-3;
    # left on Auto this disc boots to VTS 2 (measured: the O[2] readout showed
    # {PGCN 1, VTS 2}), whose menu map is unchanged -- so the arm compared two
    # identical screens and read 0.0%, looking like the fix had done nothing.
    # The debug title picker is the same lever the GET_SMART audio A/B used.
    # ⚠ TWO menu presses, also load-bearing: the boot-chain shortcut sends the
    # FIRST Menu press after a mount to best_menu_vts (VTS 2 here) rather than
    # the playing title's own VTSM (docs/dvd_vm.md "Boot-chain menu shortcut").
    # It self-limits -- that press latches menu_seen -- so the second press
    # takes the spec path to VTS_01's Root.
    ('atfirstsight', 'ATFIRSTSIGHT_20260809_133726.iso',
     ['Title VTS Units=1'], ['menu', 'menu'],
     'POSITIVE: VTS_01 VTSM is 16:9 with wide id 1; 0x20 and 0x21 differ in '
     '61.7% of their bytes, so a correct route is VISIBLE'),
    ('t2',          'ULTIMATE_T2.iso', [], ['menu'],
     'regression: authors 0x80000100 (wide=0) -- must stay on 0x20'),
    ('t2_letterbox', 'ULTIMATE_T2.iso', ['Analog Aspect=Letterbox'], ['menu'],
     'regression: forced-wide means Letterbox must NOT change the stream'),
    ('matrix',      'THE_MATRIX_16X9LB_N_AMERICA.ISO', [], ['menu'],
     'regression: in-title HLI path (white rabbit) must keep its own table'),
    ('mib_force43', 'MEN_IN_BLACK.iso', ['Force 4:3 Subpics=On'], ['menu'],
     'regression: the user-path mapping is untouched'),
    ('tombraider',  'tomb_raider_pal.iso', [], ['menu'],
     'regression: PAL, 39/41 menu PGCs non-identity with wide=0'),
    ('office_pal',  'THE_OFFICE_UK_DISC1_PAL.iso', [], ['menu'],
     'regression: PAL 16:9 menus'),
    ('akira',       'Akira (1988).iso', [], ['menu'],
     'regression: 12/12 menu PGCs non-identity, wide=0'),
    ('sceneit',     'Scene_It.iso', [], [],
     'regression: in-title multi-button menu (sp_menu_early joins the mapping)'),
    ('hpotter',     'Harry Potter Interactive DVD Game (HOGWARTS CHALLENGE).iso',
     [], [], 'regression: still-heavy menu disc'),
    ('cluedo',      'Cluedo_20051206_AUS_PAL.iso', [], [],
     'regression: PAL game disc'),
]

# Discs live in subdirectories; probe these in order.
SUBDIRS = ['', 'interactive/', 'film/', 'pal/', 'tv/', 'DVDs/', 'concert/', 'dvdi/']


def resolve(disc):
    """Find `disc` under SHARE, returning the absolute path ON THE RIG."""
    cand = ' '.join("'%s%s%s'" % (SHARE + '/', d, disc) for d in SUBDIRS)
    r = mister('shell', '--', 'for f in %s; do [ -f "$f" ] && echo "$f" && break; done' % cand)
    path = r.stdout.strip().splitlines()
    return path[-1] if path else None


SAVE_DIR = os.environ.get('TMPDIR', '/tmp')


def blocks_now(tag):
    """Screenshot the core raster and decode the O[2] diagnostic blocks."""
    png = os.path.join(SAVE_DIR, 'hil_%s.png' % tag)
    mister('shot', '-o', png)
    if not os.path.exists(png):
        return None, None
    r = sh([sys.executable, HUDREAD, 'blocks', png, '--json'])
    try:
        return json.loads(r.stdout), png
    except ValueError:
        return None, png


def val(b, name):
    """True / False / None(not shown) for one block."""
    d = b.get(name) if b else None
    return d.get('value') if isinstance(d, dict) else None


def run_menu_arm(name, disc, opts, keys, note, results):
    path = resolve(disc)
    if not path:
        results.append((name, 'SKIP', 'disc not on the share: %s' % disc))
        return
    o = []
    for kv in ['Disc Menus=On', 'Debug Overlay=On'] + opts:
        o += ['--opt', kv]
    r = mister('launch', path, *o, '--delay', '2', timeout=240)
    if r.returncode != 0:
        results.append((name, 'FAIL', 'launch failed: %s' % r.stderr.strip()[:120]))
        return
    time.sleep(12)                      # boot chain + first menu
    for k in keys:
        mister('key', k)
        time.sleep(4)
    # A looping motion menu changes every frame, so sample and take the majority.
    samples = []
    for i in range(3):
        b, _ = blocks_now('%s_%d' % (name, i))
        if b:
            samples.append(b)
        time.sleep(1)
    if not samples:
        results.append((name, 'FAIL', 'no screenshot decoded'))
        return

    def majority(field):
        vs = [val(b, field) for b in samples]
        for cand in (True, False):
            if vs.count(cand) >= 2:
                return cand
        return None

    armed = majority('hl_btns_armed')
    on    = majority('hl_on')
    spu   = majority('spu_bytes_seen')
    shown = majority('subpic_shown')
    detail = 'armed=%s hl_on=%s spu_bytes=%s subpic=%s' % (armed, on, spu, shown)

    if armed is None:
        results.append((name, 'SKIP', 'blocks not shown (menus_on gate off?) -- ' + detail))
    elif armed and on and spu and shown:
        results.append((name, 'PASS', detail))
    elif armed and on and not spu:
        # the exact signature of issues #60/#61
        results.append((name, 'FAIL', 'SPU filtered away = wrong substream -- ' + detail))
    else:
        results.append((name, 'FAIL', detail))


def suite_menu(only):
    results = []
    for arm in MENU_ARMS:
        if only and arm[0] not in only:
            continue
        print('--- %s (%s)' % (arm[0], arm[4]))
        run_menu_arm(*arm, results=results)
        print('    %s' % results[-1][1])
    return results


# ---------------------------------------------------------------------------
# still-audio suite (issue #65)
# ---------------------------------------------------------------------------
def suite_still_audio(only):
    """Capture A/V on Atmosfear's character screens and look for a repeat.

    A clip that plays twice back to back puts a strong peak in the audio
    envelope's autocorrelation at a lag equal to the clip's own length. The
    check is on that peak, never on a transcript.
    """
    results = []
    path = resolve('ATMOSFEAR_NTSC.ISO')
    if not path:
        results.append(('atmosfear', 'SKIP', 'ATMOSFEAR_NTSC.ISO not on the share'))
        return results
    o = []
    for kv in ['Disc Menus=On', 'Debug Overlay=Off']:
        o += ['--opt', kv]
    mister('launch', path, *o, '--delay', '2', timeout=240)
    time.sleep(15)
    # Boot chain -> main menu -> character selection. The exact key script is
    # disc-specific and is the one thing here that wants a human's eye once.
    for k in ['menu', 'select', 'down', 'select']:
        mister('key', k)
        time.sleep(3)
    out = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'atmos_still.mkv')
    r = mister('capture', '-t', '15', '-o', out, timeout=180)
    if r.returncode != 0 or not os.path.exists(out):
        results.append(('atmosfear', 'SKIP',
                        'capture card unavailable: %s' % r.stderr.strip()[:100]))
        return results
    results.append(('atmosfear', 'CAPTURED',
                    '%s -- analyse with: tools/hil_nav_test.py --analyse %s' % (out, out)))
    return results


def analyse_repeat(path):
    """Report the audio-envelope autocorrelation peak outside a small lag guard."""
    import wave
    import array
    wav = path + '.wav'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', path, '-ac', '1', '-ar', '8000', wav], check=True)
    w = wave.open(wav, 'rb')
    n = w.getnframes()
    a = array.array('h', w.readframes(n))
    w.close()
    # 50 ms envelope
    step = 400
    env = [max(abs(x) for x in a[i:i + step]) or 0 for i in range(0, len(a) - step, step)]
    if len(env) < 40:
        print('capture too short to analyse')
        return 1
    m = sum(env) / len(env)
    e = [x - m for x in env]
    denom = sum(x * x for x in e) or 1.0
    best, best_lag = 0.0, 0
    # ignore lags under 1 s (that is the clip's own structure, not a repeat)
    for lag in range(20, len(e) // 2):
        c = sum(e[i] * e[i + lag] for i in range(len(e) - lag)) / denom
        if c > best:
            best, best_lag = c, lag
    print('envelope autocorrelation: peak %.3f at lag %.1f s' % (best, best_lag * 0.05))
    print('  a clip played TWICE shows a strong peak (>0.4) at its own length;')
    print('  after the fix that peak should be gone.')
    return 0


# ---------------------------------------------------------------------------
# still-redecode suite (issue #65) -- does a menu still land WITHOUT the
# §5 cold re-decode?
# ---------------------------------------------------------------------------
# The hard part is reaching a deep still menu without knowing each disc's key
# sequence. So this does not try to: it walks a FIXED key script and shoots at
# every step, and it discriminates stills from motion menus by MEASUREMENT --
# two shots 1.2 s apart at the same step. Identical => a still (the thing under
# test). Different => an animated menu, skipped, because a frame-exact
# comparison across builds is meaningless there.
#
# Run it on the shipping build and again with the re-decode disabled, then
# --compare-stills. A still that lands either way is byte-identical; a still
# that NEEDS the re-decode diverges, because without it the screen would still
# be showing the previous transition frame.
STILL_ARMS = [
    # Route verified against the golden VM model, not guessed:
    #   tools/atmos_trace.py <iso> "1"     -> PARK at VTSM vts=1 PGCN 8 still=255
    #                                "1 1"  -> PGCN 9,  "1 1 1" -> PGCN 10
    # The disc parks at PGCN 7 (a looping 23 s video menu) on its OWN after the
    # FP chain, so there is NO menu press: pressing it fires the boot-chain
    # shortcut to best_menu_vts and lands in a Gatekeeper clip instead (observed).
    # Digit keys select+activate button N directly, which is what the trace models.
    ('atmos',    'ATMOSFEAR_NTSC.ISO',
     ['1', '1', '1'],
     'the reported disc: PGCN 8/9/10 are still=255 character screens with narration'),
    ('t2',       'ULTIMATE_T2.iso',
     ['menu', 'select', 'down', 'select', 'select', 'down', 'select'],
     'Jump-Into-Timeline cubes + mission-profile slides: what §5 was built for'),
    ('matrix',   'THE_MATRIX_16X9LB_N_AMERICA.ISO',
     ['menu', 'down', 'select', 'select', 'next-chapter', 'select'],
     'scene pages: the "images lag the highlight" case'),
    ('mib',      'MEN_IN_BLACK.iso',
     ['menu', 'down', 'select', 'select', 'next-chapter'],
     'scene pages'),
    ('hpotter',  'Harry Potter Interactive DVD Game (HOGWARTS CHALLENGE).iso',
     ['menu', 'select', 'select', 'down', 'select'],
     '70 real cells, every still_time=255 still is SEQ GOP PIC:I SEQ_END'),
]


def _frame(path):
    """hud_read.load_image returns a bare (w, h, rgb) tuple; wrap it so the
    comparison can index pixels the same way hud_read's own decoders do."""
    import hud_read
    w, h, buf = hud_read.load_image(path)
    return hud_read.Frame(w, h, buf)


def frame_diff(a, b):
    """Fraction of sampled pixels differing by more than a noise tolerance."""
    if a.w != b.w or a.h != b.h:
        return 1.0
    step = 4
    tot = ch = 0
    for y in range(0, a.h, step):
        for x in range(0, a.w, step):
            tot += 1
            pa, pb = a.px(x, y), b.px(x, y)
            if max(abs(pa[i] - pb[i]) for i in range(3)) > 24:
                ch += 1
    return ch / float(tot or 1)


def suite_still_redecode(only):
    """Walk each disc's menus and shoot every step, tagging stills vs motion."""
    import hud_read
    results = []
    for name, disc, keys, note in STILL_ARMS:
        if only and name not in only:
            continue
        print('--- %s (%s)' % (name, note))
        path = resolve(disc)
        if not path:
            results.append((name, 'SKIP', 'not on the share'))
            continue
        o = []
        for kv in ['Disc Menus=On', 'Debug Overlay=Off']:
            o += ['--opt', kv]
        if mister('launch', path, *o, '--delay', '2', timeout=240).returncode != 0:
            results.append((name, 'FAIL', 'launch failed'))
            continue
        time.sleep(14)
        stills = motion = 0
        for step in range(len(keys) + 1):
            if step:
                mister('key', keys[step - 1])
            # 12 s, not 4: with the §5 re-decode ON, entering a still plays the
            # cell (~3-4 s here), then flushes and re-streams it, so the screen is
            # not static until both passes are done. Too short a settle reports a
            # still as "motion" and silently drops it from the comparison.
            time.sleep(12)
            a = os.path.join(SAVE_DIR, 'still_%s_%02d_a.png' % (name, step))
            b = os.path.join(SAVE_DIR, 'still_%s_%02d_b.png' % (name, step))
            mister('shot', '-o', a)
            time.sleep(1.2)
            mister('shot', '-o', b)
            tag = 'motion'
            if os.path.exists(a) and os.path.exists(b):
                if frame_diff(_frame(a), _frame(b)) <= 0.005:
                    tag = 'STILL'
                    stills += 1
                else:
                    motion += 1
            if os.path.exists(b):
                os.remove(b)                    # b was only the discriminator
            print('    step %d (%s) -> %s'
                  % (step, keys[step - 1] if step else 'boot', tag))
        results.append((name, 'WALKED', '%d still step(s), %d motion' % (stills, motion)))
    return results


def compare_stills(dir_a, dir_b):
    """Compare two still-redecode walks step by step.

    Every step must render the same in both runs. A divergence means the cold
    re-decode was doing real work there -- the still does NOT land without it
    and the §5 mechanism must stay.
    """
    import hud_read
    files = sorted(f for f in os.listdir(dir_a)
                   if f.startswith('still_') and f.endswith('_a.png'))
    if not files:
        print('no still-walk shots in %s' % dir_a)
        return 1
    print('%-26s %-9s %s' % ('STEP', 'PIXELS', 'VERDICT'))
    bad = missing = 0
    for f in files:
        fa, fb = os.path.join(dir_a, f), os.path.join(dir_b, f)
        if not os.path.exists(fb):
            print('%-26s %-9s only in one run' % (f[6:-6], '-'))
            missing += 1
            continue
        d = frame_diff(_frame(fa), _frame(fb))
        ok = d <= 0.01
        if not ok:
            bad += 1
        print('%-26s %-9s %s' % (f[6:-6], '%.1f%%' % (d * 100),
                                 'same' if ok else '*** DIVERGED ***'))
    print()
    print('%d step(s) diverged, %d missing' % (bad, missing))
    if bad == 0:
        print('=> the stills land WITHOUT the cold re-decode: it is vestigial.')
    else:
        print('=> the re-decode still does real work; the §5 mechanism must stay.')
    return 1 if bad else 0


def compare_runs(dir_a, dir_b):
    """Which arms' menus look DIFFERENT between two runs?

    This is the arm that can actually see the #60/#61 fix take effect on a disc
    the maintainer owns. ATFIRSTSIGHT carries BOTH subpicture variants (0x20 4:3
    and 0x21 16:9 wide) of the same menu art, so it renders a highlight either
    way -- the O[2] blocks read GREEN before and after and cannot tell them
    apart. What DOES change is the pixels: the fix swaps which variant is
    decoded. So:

        atfirstsight  MUST differ   (the routing changed)
        every other   MUST match    (the routing is confined)

    Note this is deliberately the inverse of the usual reading. A screenshot
    difference is normally a regression; here, on exactly one named arm, it is
    the evidence.
    """
    import hud_read
    names = sorted({f.split('_')[1] for f in os.listdir(dir_a)
                    if f.startswith('hil_') and f.endswith('.png')})
    if not names:
        print('no screenshots in %s' % dir_a)
        return 1
    print('%-14s %-10s %s' % ('ARM', 'PIXELS', 'VERDICT'))
    bad = 0
    for n in names:
        fa = os.path.join(dir_a, 'hil_%s_0.png' % n)
        fb = os.path.join(dir_b, 'hil_%s_0.png' % n)
        if not (os.path.exists(fa) and os.path.exists(fb)):
            print('%-14s %-10s missing a shot' % (n, '-'))
            continue
        a, b = _frame(fa), _frame(fb)
        if a.w != b.w or a.h != b.h:
            diff = 1.0
        else:
            step = 4
            tot = ch = 0
            for y in range(0, a.h, step):
                for x in range(0, a.w, step):
                    tot += 1
                    pa, pb = a.px(x, y), b.px(x, y)
                    if max(abs(pa[i] - pb[i]) for i in range(3)) > 24:
                        ch += 1
            diff = ch / float(tot or 1)
        want_change = (n == 'atfirstsight')
        changed = diff > 0.01
        ok = (changed == want_change)
        if not ok:
            bad += 1
        print('%-14s %-10s %s (%s)' % (
            n, '%.1f%%' % (diff * 100),
            'PASS' if ok else 'FAIL',
            'must differ' if want_change else 'must match'))
    print()
    print('%d arm(s) wrong' % bad)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--suite', choices=['menu-highlight', 'still-audio',
                                       'still-redecode'])
    ap.add_argument('--only', nargs='*', help='run only these arm names')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--analyse', metavar='MKV', help='analyse a capture for a repeat')
    ap.add_argument('--save-dir', metavar='DIR',
                    help='write screenshots here (use two dirs + --compare)')
    ap.add_argument('--compare', nargs=2, metavar=('DIR_A', 'DIR_B'),
                    help='compare two saved runs: which arms changed on screen')
    ap.add_argument('--compare-stills', nargs=2, metavar=('DIR_A', 'DIR_B'),
                    help='compare two still-redecode walks step by step')
    args = ap.parse_args()

    if args.list:
        for a in MENU_ARMS:
            print('  %-14s %-52s %s' % (a[0], a[1], a[4]))
        return 0
    if args.analyse:
        return analyse_repeat(args.analyse)
    if args.compare:
        return compare_runs(*args.compare)
    if args.compare_stills:
        return compare_stills(*args.compare_stills)
    if args.save_dir:
        global SAVE_DIR
        SAVE_DIR = args.save_dir
        os.makedirs(SAVE_DIR, exist_ok=True)
    if not args.suite:
        ap.error('need --suite, --list or --analyse')

    st = mister('state')
    print(st.stdout.strip()[:400])
    print()
    if args.suite == 'menu-highlight':
        results = suite_menu(args.only)
    elif args.suite == 'still-redecode':
        results = suite_still_redecode(args.only)
    else:
        results = suite_still_audio(args.only)

    print()
    print('%-14s %-9s %s' % ('ARM', 'VERDICT', 'DETAIL'))
    bad = 0
    for name, verdict, detail in results:
        print('%-14s %-9s %s' % (name, verdict, detail))
        if verdict == 'FAIL':
            bad += 1
    print()
    print('%d arm(s), %d failed' % (len(results), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
