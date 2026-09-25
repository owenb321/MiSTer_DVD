#!/usr/bin/env python3
"""pause_match.py -- does the HUD clock tell the time of the picture on screen?

Presses a key on the target (optional), waits, PAUSES, screenshots, and matches the
paused picture against ffmpeg's own decode of the same title -- a decoder that shares
no code with the core -- to get the picture's TRUE title time. Pausing freezes the
display, so one screenshot pairs one picture with one clock reading:
    err = HUD clock - picture time      (the HUD shows whole seconds: floor)
Written for issue #127 (docs/transport_hud.md "The preview must agree with the
clock"), where it refuted the first design's premise.

    ISO=$DVD_ISO_DIR/film/big-buck-bunny-NTSC.iso TITLE=2 REF_SPAN=600 \
        tools/pause_match.py ARM steady:-:0 left:left:1.5 right:right:1.5
    tools/pause_match.py --rescore ARM          # re-analyse saved shots

Plan items are name:key:delay (key '-' = none, '+' joins keys). Each item prints the
clock, the matched picture time (`near` = within T-6..T+2, `wide` = T-30..T+8, each
with its correlation), and the PRESS/PAUSE target uptimes, so a seek's CONTENT jump
can be computed as delta(picture) - delta(wall) between items. Every paused item
costs ~3.7 s of wall time with the picture frozen: subtract that.

⚠ Three traps, each of which produced a confident wrong reading first:
  1. The board raster is LETTERBOXED for 16:9 content (360 picture lines from row
     60); ffmpeg's frame is full-height anamorphic. Unmatched geometry scores
     r ~ 0.3-0.7 and lands on lookalikes -- it produced a false "+18 s" once.
     Matching correctly scores r ~ 0.99+.
  2. `-ss` with ffmpeg's dvdvideo demuxer is NOT frame accurate: labelling frames
     from a seek's nominal start mislabels them. Decode ONCE from zero (cached).
  3. Long near-static shots (Men in Black's dragonfly title sequence) repeat
     almost identically for seconds; prefer bright, moving material (Big Buck
     Bunny's film: Title VTS Tens=0 / Units=2 with Disc Menus Off).
Also: ffmpeg's title timeline can disagree with the IFO late in a title (MiB title
1: ffprobe 5471 s vs IFO 5872 s) -- check ffprobe's duration against the HUD total
first, and stay early in the title if they differ.
"""

import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mister, hud_read
import numpy as np
from PIL import Image

ISO = os.environ.get('ISO')
if not ISO:
    sys.exit('pause_match: set ISO=<path to the same disc image, on this machine>')
TITLE = os.environ.get('TITLE', '1')
OUT = os.environ.get('OUT', os.path.join(os.environ.get('TMPDIR', '/tmp'), 'pause_match'))
os.makedirs(OUT, exist_ok=True)
KEYS = mister.key_names()
# The board raster is LETTERBOXED (16:9 content in a 4:3 frame: 360 picture lines
# from row 60); ffmpeg's frame is full-height anamorphic. Compare board rows
# 60..330 (above the seek-bar popup) with ffmpeg scaled to 360 lines, rows 0..270.
LB_TOP, LB_ROWS = 60, 270
SIG = (128, 68)

_ref = {}


REF_SPAN = float(os.environ.get('REF_SPAN', '420'))


def ref_frames(t0, t1):
    """ffmpeg's decode of the title: [(t, sig)] with t0 <= t <= t1.
    ⚠ ONE decode FROM ZERO, cached: `-ss` with the dvdvideo demuxer is not frame
    accurate, and labelling frames from a seek's nominal start mislabels them."""
    if 'all' not in _ref:
        cache = os.path.join(OUT, f'ref_{os.path.basename(ISO)}_t{TITLE}_{int(REF_SPAN)}_lb.npy')
        if os.path.exists(cache):
            arr = np.load(cache)
        else:
            arr = _decode_all()
            np.save(cache, arr)
        fps = 30000 / 1001
        _ref['all'] = [(i / fps, arr[i].astype(np.float32)) for i in range(len(arr))]
    return [(t, f) for t, f in _ref['all'] if t0 <= t <= t1]


def _decode_all():
    cmd = ['ffmpeg', '-hide_banner', '-v', 'error', '-f', 'dvdvideo', '-title', TITLE,
           '-i', ISO, '-t', str(REF_SPAN),
           '-vf', f'scale=720:360,crop=720:{LB_ROWS}:0:0,scale={SIG[0]}:{SIG[1]},format=gray',
           '-f', 'rawvideo', '-']
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = len(raw) // (SIG[0] * SIG[1])
    return np.frombuffer(raw[:n * SIG[0] * SIG[1]], dtype=np.uint8).reshape(n, SIG[1], SIG[0]).copy()


def corr(a, b):
    a = a - a.mean(); b = b - b.mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d > 0 else 0.0


def shot_sig(path):
    img = Image.open(path).convert('L').crop((0, LB_TOP, 720, LB_TOP + LB_ROWS)).resize(SIG)
    return np.asarray(img, dtype=np.float32)


def analyse(path):
    w, h, buf = hud_read.load_image(path)
    res = hud_read.decode(hud_read.Frame(w, h, buf))
    clk = res.get('elapsed')
    if not clk:
        return {'clock': None}
    hh, mm, ss = (int(x) for x in clk.split(':'))
    T = hh * 3600 + mm * 60 + ss
    sig = shot_sig(path)
    def best(t0, t1):
        sc = sorted(((corr(sig, f), t) for t, f in ref_frames(t0, t1)), reverse=True)
        if not sc:
            return None, 0.0, 0.0
        r, t = sc[0]
        second = next((x for x, u in sc[1:] if abs(u - t) > 0.5), 0.0)
        return t, r, second
    tw, rw, sw = best(T - 30, T + 8)
    tn, rn, sn = best(T - 6, T + 2)
    return {'clock': clk, 'T': T,
            'wide': round(tw, 2), 'r_w': round(rw, 3), 'r2_w': round(sw, 3),
            'near': round(tn, 2), 'r_n': round(rn, 3),
            'err_w': round(T - tw, 2), 'err_n': round(T - tn, 2),
            'icon': res.get('icon'), 'popup': res.get('popup_text')}


def target_seq(tag, press=None, delay=0.0, shots=(0.3, 2.5)):
    """On the target: [press], sleep delay, PAUSE, then screenshots at the given
    offsets after the pause, then un-pause."""
    k = lambda n: ' '.join(str(KEYS[x]) for x in n.split())
    lines = [f'rm -f /media/fat/screenshots/{tag}_*.png']
    if press:
        lines.append('read up _ < /proc/uptime; echo "PRESS $up"')
        lines.append(f'echo "keys {k(press)}" > /tmp/mister_hil')
    lines.append(f'sleep {delay}')
    lines.append('read up _ < /proc/uptime; echo "PAUSE $up"')
    lines.append(f'echo "keys {k("pause")}" > /tmp/mister_hil')
    last = 0.0
    for i, t in enumerate(shots):
        lines.append(f'sleep {t - last}')
        last = t
        lines.append(f'echo "screenshot {tag}_{i}.png" > /dev/MiSTer_cmd')
        lines.append(f'for w in $(seq 1 60); do sleep 0.05; [ -f /media/fat/screenshots/{tag}_{i}.png ] && break; done; sleep 0.5')
    lines.append(f'echo "keys {k("pause")}" > /tmp/mister_hil')
    _, so = mister.ssh('\n'.join(lines) + '\n', timeout=120)
    stamps = {l.split()[0]: float(l.split()[1]) for l in so.splitlines()
              if l.split() and l.split()[0] in ('PRESS', 'PAUSE')}
    subprocess.run(['scp', *mister.SSH_OPTS, '-q',
                    f'{mister.host()}:/media/fat/screenshots/{tag}_*.png', OUT + '/'],
                   capture_output=True)
    out = []
    for i, _ in enumerate(shots):
        p = os.path.join(OUT, f'{tag}_{i}.png')
        out.append(analyse(p) if os.path.exists(p) else {'missing': True})
        out[-1]['pause_up'] = stamps.get('PAUSE')
        out[-1]['press_up'] = stamps.get('PRESS')
    return out


def run(arm, plan):
    res = {}
    for name, press, delay in plan:
        r = target_seq(f'{arm}_{name}', press, delay)
        res[name] = r
        for i, x in enumerate(r):
            print(f'{arm:8s} {name:10s} shot{i}: ' + json.dumps(x))
        time.sleep(3)
    json.dump(res, open(os.path.join(OUT, f'{arm}.json'), 'w'), indent=1)


def rescore(arm):
    import glob
    for p in sorted(glob.glob(os.path.join(OUT, f'{arm}_*_[0-9].png'))):
        print(os.path.basename(p), json.dumps(analyse(p)))


if __name__ == '__main__':
    if sys.argv[1] == '--rescore':
        rescore(sys.argv[2]); sys.exit(0)
    arm = sys.argv[1]
    if len(sys.argv) > 2:          # name:key:delay ...  (key '-' = none)
        plan = [(a, None if b == '-' else b.replace('+', ' '), float(c))
                for a, b, c in (x.split(':') for x in sys.argv[2:])]
        run(arm, plan); sys.exit(0)
    sys.exit('usage: pause_match.py ARM name:key:delay ...   (see the header)')
