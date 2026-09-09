#!/usr/bin/env python3
"""
dvd_explore.py -- drive a disc unattended and watch for anything wrong.

The hard part of a soak test is not driving the core; it is knowing that
something went wrong WITHOUT a golden image to compare against. This project
has an unusually good answer, because the oracles already exist:

  colour       CLAUDE.md characterises three failure colours with MEASURED RGB
               values from yuv2rgb.v, so a bad frame arrives pre-diagnosed:
                 black (0,0,0)      nothing scanning -- reader wedged
                 green (0,136,0)    a framestore slot being scanned that was
                                    NEVER WRITTEN
                 grey  (130,130,130) an intra picture decoded from MIS-FRAMED
                                    bytes -- suspect ps_demux framing
  popups       LINK FAIL / CSS ENCRYPTED / unsupported-image / unsupported-audio
               are self-reporting failures, and decodable as text
  HUD clock    must advance during playback and hold while paused -- state
               aware, because a menu still legitimately holds
  telemetry    lates, drops, drain-gate closures and vid_err, read from the
               core's own counters rather than inferred from pixels

⚠ SEEDED AND FULLY LOGGED. Every action goes to a JSONL log with its timestamp
and the RNG seed is recorded, so any finding replays exactly. An unreproducible
anomaly is nearly worthless here; a seeded one is a testbench waiting to be
written.

⚠ STATE-AWARE, NOT A MONKEY. It knows whether it is in a menu, a title or a
still and picks legal actions accordingly, so the walk spends its time where
bugs are rather than mashing buttons at a paused screen.

Usage:
    dvd_explore.py <image-on-the-mister> [--minutes 10] [--seed N]
                   [--out DIR] [--settle 2.5]
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mister as M            # noqa: E402  ssh/scp/fifo + the derived key table
import hud_read as H          # noqa: E402

# MEASURED failure colours (CLAUDE.md, traced through rtl/mpeg2/yuv2rgb.v).
# A frame is "flat" when it is essentially uniform; the mean then names the fault.
FAULT_COLOURS = [
    ('reader wedged (nothing scanning)', (0, 0, 0)),
    ('framestore slot never written', (0, 136, 0)),
    ('intra picture from mis-framed bytes (ps_demux)', (130, 130, 130)),
]
FLAT_STD = 6.0          # below this a frame carries no picture
COLOUR_TOL = 12

BAD_POPUPS = ('LINK FAIL', 'CSS ENCRYPTED', 'UNSUPPORTED', 'BAD IMAGE')

# Actions that legitimately disturb the counters: a seek flushes buffers and
# re-arms the audio drain gate, a menu hop stalls video against the STC.
# ⚠ THE JSON KEY IS `disp_lag_ms`, NOT `disp_lag`, AND IT IS ALREADY IN
# MILLISECONDS -- main/support/dvd/dvd_ctl.cpp converts word 11 (signed, 1 LSB =
# 16 ticks of the 90 kHz STC) before publishing. Reading `disp_lag` gets a
# MISSING KEY, which `.get(k, 0)` turns into a constant zero and a dead oracle.
# That is exactly how this check's predecessor died, and I repeated it here on
# the first attempt; the liveness report below is what surfaced it. Take field
# names from dvd_ctl.cpp's fprintf, never from the RTL port names.
DISP_LAG_KEY = 'disp_lag_ms'
# Threshold, MEASURED not guessed: 90/90 steady-playback samples of a real film
# sat at -16.7 ms (exactly one 59.94 Hz refresh -- a fire-when-due scheduler is
# one frame behind by construction), worst excursion 25.1 ms, 3 distinct values.
# 120 ms is ~5x that worst case: quiet on healthy content, and still catches a
# display several frames off its schedule.
DISP_LAG_MAX_MS = 120.0

# Fields that MUST move while a picture is playing. A constant one is a RETIRED
# INSTRUMENT, not a quiet disc, and any oracle reading it is dead. Fields that
# may legitimately stay put (aud_gate, drops, lates on healthy content) are
# deliberately NOT listed -- flagging those would cry wolf on every clean run.
MUST_VARY = ('refreshes', 'pickups', DISP_LAG_KEY)

PERTURBING = {'next-chapter', 'prev-chapter', 'menu', 'title', 'return',
              'select', 'pause', 'up', 'down', 'left', 'right'}

MENU_ACTIONS = ['up', 'down', 'left', 'right', 'select', 'select', 'menu', 'return']
TITLE_ACTIONS = ['next-chapter', 'prev-chapter', 'audio', 'subtitle', 'angle',
                 'display', 'pause', 'menu', 'title', 'next-chapter']


class Finding(Exception):
    pass


class Explorer:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.out = args.out or os.path.join(
            os.environ.get('TMPDIR', '/tmp'),
            f'dvd_explore_{time.strftime("%Y%m%d_%H%M%S")}')
        os.makedirs(self.out, exist_ok=True)
        self.log_path = os.path.join(self.out, 'actions.jsonl')
        self.findings = []
        self.last_clock = None
        self.clock_stuck = 0
        self.step = 0
        # Steps to skip telemetry oracles for after the harness perturbs the
        # core itself. A seek or a menu hop legitimately disturbs every counter.
        self.quiet = 0
        # Downsampled previous frame, for "is the picture actually moving?".
        self.prev_small = None
        self.frozen_for = 0
        # key -> (min, max) across the run, for the liveness report
        self.telem_range = {}

    def log(self, **kw):
        kw['step'] = self.step
        kw['t'] = round(time.time(), 3)
        with open(self.log_path, 'a') as f:
            f.write(json.dumps(kw) + '\n')

    # -- observation --------------------------------------------------------
    def shot(self):
        """-> path, or None.

        A screenshot can legitimately fail: mister_scaler_init bails when the
        VBUF has no header yet (scaler.cpp:60), which is exactly the state right
        after a core load. A soak must ride that out rather than die on step 1.
        """
        path = os.path.join(self.out, f'step{self.step:04d}.png')
        rc, _ = M.ssh(f'''
rm -f /media/fat/screenshots/expl.png
echo 'screenshot expl.png' > /dev/MiSTer_cmd
for i in $(seq 1 20); do
  sleep 0.25
  if [ -f /media/fat/screenshots/expl.png ]; then
    a=$(stat -c %s /media/fat/screenshots/expl.png); sleep 0.2
    b=$(stat -c %s /media/fat/screenshots/expl.png)
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
exit 1
''', check=False)
        if rc != 0:
            self.log(event='no_shot', note='scaler had no frame yet')
            return None
        r = subprocess.run(['scp', *M.SSH_OPTS, '-q',
                            f'{M.host()}:/media/fat/screenshots/expl.png', path],
                           capture_output=True)
        return path if r.returncode == 0 else None

    def telem(self):
        _, out = M.ssh('cat /tmp/dvd_telem.json 2>/dev/null\n', check=False)
        for line in out.splitlines():
            if line.strip().startswith('{'):
                try:
                    return json.loads(line)
                except ValueError:
                    pass
        return {}

    # -- oracles ------------------------------------------------------------
    def check_frame(self, png):
        import numpy as np
        w, h, buf = H.load_image(png)
        a = np.frombuffer(buf, dtype=np.uint8).reshape(h, w, 3).astype(float)
        mean = a.mean(axis=(0, 1))
        # PER-CHANNEL spatial spread. Taking std over all channels at once makes
        # a uniform GREEN frame measure std 64 (its channels are 0/136/0), so
        # the most diagnostic signature of the three would never have registered
        # as flat. Caught by the selftest's green arm, not by a soak.
        std = float(a.std(axis=(0, 1)).max())
        # Track picture motion. A still is not a fault, and the core does not
        # always say it is on one: a title-domain interactive still (Cluedo,
        # Scooby's maze) sets neither `menu` nor `still`, so the flags alone
        # cannot distinguish "parked on a menu" from "video died".
        small = a[::8, ::8].mean(axis=2)
        if self.prev_small is not None and small.shape == self.prev_small.shape:
            moved = float(np.abs(small - self.prev_small).mean())
            self.frozen_for = self.frozen_for + 1 if moved < 1.0 else 0
        self.prev_small = small
        if std < FLAT_STD:
            for name, ref in FAULT_COLOURS:
                if all(abs(m - r) <= COLOUR_TOL for m, r in zip(mean, ref)):
                    raise Finding(f'flat frame: {name} '
                                  f'(mean {tuple(round(m) for m in mean)}, std {std:.1f})')
            raise Finding(f'flat frame, unrecognised colour '
                          f'(mean {tuple(round(m) for m in mean)}, std {std:.1f})')
        return H.decode(H.Frame(w, h, buf))

    def check_hud(self, hud, tel):
        pop = (hud.get('popup_text') or '').upper()
        for bad in BAD_POPUPS:
            if bad in pop:
                raise Finding(f'popup reports a failure: {pop!r}')
        # The clock must move during playback. A menu still or a pause holds it
        # legitimately, so both are excluded rather than treated as a stall.
        playing = (tel.get('flags', {}).get('video_live')
                   and not tel.get('flags', {}).get('pause')
                   and not tel.get('flags', {}).get('still')
                   and not tel.get('flags', {}).get('menu'))
        clock = hud.get('elapsed')
        if playing and clock:
            if clock == self.last_clock:
                self.clock_stuck += 1
                if self.clock_stuck >= 4:
                    raise Finding(f'HUD clock stuck at {clock} for '
                                  f'{self.clock_stuck} samples while playing')
            else:
                self.clock_stuck = 0
            self.last_clock = clock

    def check_telem(self, tel, prev):
        """Telemetry oracles, gated on the harness NOT having just perturbed things.

        ⚠ The first version flagged 15 faults in 24 steps, all of them its own
        doing. vid_err measures video content against the STC, so a menu, a
        still or a pause legitimately stalls video while the clock runs on, and
        a seek re-arms the audio drain gate by design. An oracle that does not
        know what the harness just PRESSED reports the harness.
        """
        if not tel or not prev or self.quiet > 0:
            return
        flags, pflags = tel.get('flags', {}), prev.get('flags', {})
        steady = all(f.get('video_live') and not f.get('pause')
                     and not f.get('still') and not f.get('menu')
                     for f in (flags, pflags))
        if not steady:
            return

        # ⚠ A FROZEN PICTURE IS A STILL, NOT A STALLED TIMELINE. On a still the
        # governor misses its deadline every refresh (there is no new picture to
        # show), so vid_err climbs at exactly the refresh rate -- 50.0/s on PAL,
        # which is what Cluedo's interactive board screen produced. Judging that
        # by the flags alone fails, because a title-domain still sets neither
        # `menu` nor `still`. The picture itself is the reliable witness.
        if self.frozen_for:
            return

        d_gate = (tel.get('aud_gate', 0) - prev.get('aud_gate', 0)) & 0xFFFF
        if d_gate:
            raise Finding(f'audio drain gate closed {d_gate}x during steady '
                          'playback -- audio is being held')
        # ⚠⚠ THIS ORACLE USED TO READ `vid_err`, WHICH PR #63 RETIRED -- emu.sv
        # now ties telemetry word 5 to a literal 16'd0. The check therefore
        # computed a slope of exactly zero on every sample and COULD NOT FIRE,
        # on hardware, silently, for as long as it shipped. The selftest kept
        # passing because it feeds synthetic dicts: it proves the oracle's LOGIC
        # fires, and says nothing about whether its INPUT is alive. See the
        # liveness report at the end of a run, which is the guard for that.
        #
        # `disp_lag` (word 11) is the modern signal and a better one: it is the
        # displayed picture's PTS minus the STC, so it is a BOUNDED error, not
        # an accumulator -- an absolute threshold means something, where
        # vid_err's magnitude never did.
        if DISP_LAG_KEY in tel:
            lag_ms = tel[DISP_LAG_KEY]
            if abs(lag_ms) > DISP_LAG_MAX_MS:
                raise Finding(f'display {lag_ms:+.0f} ms from its schedule '
                              'during steady playback')
        d_drop = (tel.get('drops', 0) - prev.get('drops', 0)) & 0xFFFF
        if d_drop > 60:
            raise Finding(f'{d_drop} frames dropped between samples')

    # -- the walk -----------------------------------------------------------
    def pick_action(self, tel):
        flags = tel.get('flags', {})
        if flags.get('menu'):
            return self.rng.choice(MENU_ACTIONS)
        if flags.get('pause'):
            return 'pause'                     # never leave it paused
        return self.rng.choice(TITLE_ACTIONS)

    def record_finding(self, msg, png, tel, hud):
        self.findings.append(msg)
        print(f'  !! FINDING (step {self.step}): {msg}')
        ev = os.path.join(self.out, f'finding{len(self.findings):02d}')
        os.makedirs(ev, exist_ok=True)
        if png and os.path.exists(png):
            os.replace(png, os.path.join(ev, 'frame.png'))
        with open(os.path.join(ev, 'evidence.json'), 'w') as f:
            json.dump({'step': self.step, 'finding': msg, 'seed': self.args.seed,
                       'telemetry': tel, 'hud': hud,
                       'image': self.args.image}, f, indent=2)
        # the last 30 actions are what reproduces it
        if os.path.exists(self.log_path):
            tail = open(self.log_path).read().splitlines()[-30:]
            open(os.path.join(ev, 'actions_tail.jsonl'), 'w').write('\n'.join(tail))
        self.log(event='finding', message=msg)
        notify = os.path.join(HERE, 'notify.sh')
        if os.path.exists(notify):
            subprocess.run([notify, f'dvd_explore: {msg} (step {self.step})'],
                           capture_output=True)

    def run(self):
        print(f'dvd_explore: {self.args.image}')
        print(f'  seed {self.args.seed}, budget {self.args.minutes} min, out {self.out}')
        M.cmd_launch(argparse.Namespace(
            image=self.args.image, opt=['Debug Overlay=On', 'Video Output=Progressive'],
            delay=2, timeout=90, no_wait=False))
        self.log(event='launch', image=self.args.image, seed=self.args.seed)
        # Let the disc get past its boot chain before judging anything: a First
        # Play logo reel is not a fault, and the scaler needs a frame.
        time.sleep(8)

        deadline = time.time() + self.args.minutes * 60
        prev_tel = {}
        while time.time() < deadline:
            self.step += 1
            png, tel, hud = None, {}, {}
            try:
                tel = self.telem()
                for k, v in tel.items():
                    if isinstance(v, (int, float)):
                        lo, hi = self.telem_range.get(k, (v, v))
                        self.telem_range[k] = (min(lo, v), max(hi, v))
                png = self.shot()
                if png:
                    hud = self.check_frame(png)
                    self.check_hud(hud, tel)
                self.check_telem(tel, prev_tel)
            except Finding as f:
                self.record_finding(str(f), png, tel, hud)
                prev_tel = tel
                time.sleep(self.args.settle)
                continue
            except Exception as exc:                    # keep soaking
                self.log(event='error', message=f'{type(exc).__name__}: {exc}')
            prev_tel = tel

            if self.quiet:
                self.quiet -= 1
            act = self.pick_action(tel)
            if act in PERTURBING:
                self.quiet = 2
            self.log(event='action', key=act,
                     hud=hud.get('status', {}).get('text'),
                     flags=tel.get('flags'))
            try:
                M.cmd_key(argparse.Namespace(names=[act]))
            except SystemExit:
                pass
            if png and os.path.exists(png):
                os.remove(png)                          # keep only findings
            time.sleep(self.args.settle)

        # ⚠ LIVENESS: an oracle whose input never moved could not have fired,
        # however green its selftest is. This is what would have caught the
        # retired vid_err word within one run instead of shipping dead.
        if self.telem_range:
            dead = [k for k in MUST_VARY
                    if k in self.telem_range
                    and self.telem_range[k][0] == self.telem_range[k][1]]
            missing = [k for k in MUST_VARY if k not in self.telem_range]
            if dead or missing:
                print('\n  !! TELEMETRY LIVENESS:')
                for k in dead:
                    print(f'     {k} never changed (constant '
                          f'{self.telem_range[k][0]}) -- retired instrument? '
                          'any oracle reading it is DEAD')
                for k in missing:
                    print(f'     {k} absent from the telemetry -- core/Main '
                          'older than the field, or the word was removed')

        print(f'\ndvd_explore: {self.step} steps, {len(self.findings)} finding(s)')
        for i, f in enumerate(self.findings, 1):
            print(f'  {i}. {f}')
        print(f'  log: {self.log_path}')
        return 1 if self.findings else 0


def selftest():
    """Prove every oracle CAN fire, and does not fire on healthy input.

    Gating the oracles on "the harness did not just perturb things" fixed a
    flood of false positives -- and the obvious next failure is an oracle so
    gated it can never fire at all. Each check below has a fault arm AND a
    control arm for exactly that reason.
    """
    import numpy as np
    from PIL import Image
    import tempfile

    args = argparse.Namespace(image='x', minutes=0, seed=1, out=tempfile.mkdtemp(),
                              settle=0)
    e = Explorer(args)
    fails = 0

    def arm(name, fn, want_fire):
        nonlocal fails
        try:
            fn()
            fired, msg = False, ''
        except Finding as f:
            fired, msg = True, str(f)
        ok = (fired == want_fire)
        print(f"  {'PASS' if ok else 'FAIL'} {name}: "
              f"{'fired' if fired else 'quiet'}{' -- ' + msg if fired else ''}")
        if not ok:
            fails += 1

    def png(rgb, noise=0):
        a = np.zeros((480, 720, 3), dtype=np.uint8)
        a[:, :] = rgb
        if noise:
            a = np.clip(a.astype(int) + np.random.RandomState(1)
                        .randint(-noise, noise, a.shape), 0, 255).astype(np.uint8)
        p = os.path.join(args.out, f'c{rgb}{noise}.png')
        Image.fromarray(a).save(p)
        return p

    print('[colour signatures]')
    for name, rgb in FAULT_COLOURS:
        arm(f'flat {rgb} -> {name[:28]}', lambda r=rgb: e.check_frame(png(r)), True)
    arm('CONTROL: normal picture', lambda: e.check_frame(png((110, 90, 70), 60)), False)

    print('[popups]')
    playing = {'flags': {'video_live': 1, 'pause': 0, 'still': 0, 'menu': 0}}
    arm('LINK FAIL popup', lambda: e.check_hud({'popup_text': 'LINK FAIL 12'}, playing), True)
    arm('CONTROL: benign popup',
        lambda: e.check_hud({'popup_text': 'AUDIO 2/4 EN'}, playing), False)

    print('[HUD clock]')
    def stuck():
        e.last_clock, e.clock_stuck = None, 0
        for _ in range(6):
            e.check_hud({'elapsed': '0:01:00', 'popup_text': ''}, playing)
    arm('clock frozen during play', stuck, True)
    def moving():
        e.last_clock, e.clock_stuck = None, 0
        for i in range(6):
            e.check_hud({'elapsed': f'0:01:0{i}', 'popup_text': ''}, playing)
    arm('CONTROL: clock advancing', moving, False)
    def held_in_menu():
        e.last_clock, e.clock_stuck = None, 0
        menu = {'flags': {'video_live': 1, 'pause': 0, 'still': 0, 'menu': 1}}
        for _ in range(6):
            e.check_hud({'elapsed': '0:01:00', 'popup_text': ''}, menu)
    arm('CONTROL: clock held in a menu', held_in_menu, False)

    print('[telemetry]')
    base = dict(t=0.0, aud_gate=0, **{DISP_LAG_KEY: 0.0},
                drops=0, flags=playing['flags'])
    def gate():
        e.quiet = 0
        e.check_telem(dict(base, t=2.0, aud_gate=3), base)
    arm('drain gate closed during steady play', gate, True)
    def gate_quiet():
        e.quiet = 2
        e.check_telem(dict(base, t=2.0, aud_gate=3), base)
    arm('CONTROL: same, just after a seek', gate_quiet, False)
    # disp_lag is in units of 16 STC ticks; 1000 LSB = 178 ms, over the threshold.
    def lag():
        e.quiet = 0
        e.check_telem(dict(base, t=2.0, **{DISP_LAG_KEY: 178.0}), base)
    arm('display far from its schedule', lag, True)
    def lag_ok():
        e.quiet = 0
        e.check_telem(dict(base, t=2.0, **{DISP_LAG_KEY: 36.0}), base)  # healthy
    arm('CONTROL: small lag is normal', lag_ok, False)
    def lag_menu():
        e.quiet = 0
        menu = dict(base, flags={'video_live': 1, 'pause': 0, 'still': 0, 'menu': 1})
        e.check_telem(dict(menu, t=2.0, **{DISP_LAG_KEY: 178.0}), menu)
    arm('CONTROL: same, but in a menu', lag_menu, False)
    def lag_frozen():
        e.quiet = 0
        e.frozen_for = 3
        e.check_telem(dict(base, t=2.0, **{DISP_LAG_KEY: 178.0}), base)
        e.frozen_for = 0
    arm('CONTROL: same, but the picture is a still', lag_frozen, False)

    print('[liveness guard]')
    # The failure this exists for: an oracle wired to a RETIRED telemetry word.
    e2 = Explorer(args)
    for _ in range(4):
        e2.telem_range = {'refreshes': (1, 900), 'pickups': (1, 450),
                          DISP_LAG_KEY: (0.0, 0.0)}
    dead = [k for k in MUST_VARY
            if k in e2.telem_range
            and e2.telem_range[k][0] == e2.telem_range[k][1]]
    ok = dead == [DISP_LAG_KEY]
    print(f"  {'PASS' if ok else 'FAIL'} names a constant field as dead: {dead}")
    if not ok:
        fails += 1
    e2.telem_range = {'refreshes': (1, 900), 'pickups': (1, 450),
                      DISP_LAG_KEY: (-40.0, 55.0)}
    dead = [k for k in MUST_VARY
            if k in e2.telem_range
            and e2.telem_range[k][0] == e2.telem_range[k][1]]
    ok = dead == []
    print(f"  {'PASS' if ok else 'FAIL'} CONTROL: a live field is not flagged")
    if not ok:
        fails += 1

    print('dvd_explore selftest:', 'ALL GREEN' if not fails else f'{fails} FAILURE(S)')
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('image', help='absolute path ON THE MISTER, or "selftest"')
    ap.add_argument('--minutes', type=float, default=10)
    ap.add_argument('--seed', type=int, default=None)
    ap.add_argument('--out')
    ap.add_argument('--settle', type=float, default=2.5,
                    help='seconds between actions (a seek needs time to land)')
    args = ap.parse_args()
    if args.image == 'selftest':
        return selftest()
    if args.seed is None:
        args.seed = random.randrange(1 << 30)
    return Explorer(args).run()


if __name__ == '__main__':
    sys.exit(main())
