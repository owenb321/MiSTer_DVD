#!/usr/bin/env python3
"""scene_card.py -- what a player sees and hears at one input point of a choice-driven
disc, rendered straight from the image, so the choice can be made the way a human makes
it: by reading the scene (docs/hil_play_harness.md "Playing by the scene").

    tools/scene_card.py <iso> --script "1 1 1 1 1 1" -o card_dir/
    tools/scene_card.py <iso> --script "..." --try          # also: where each button leads

The card is one PNG plus a JSON:
  - SCENE: frames from the cells that played since the previous input point (the core's
    own VM decides which: tools/nav_offline.py), sampled every --every seconds with the
    disc's first subtitle stream burnt in -- on discs like Thayer's Quest that is the
    speaker-tagged dialogue, i.e. the narration that poses the choice;
  - CHOICE: the input point's screen with every button's rectangle drawn and numbered,
    and below it each button's command;
  - with --try, the landing of each button (VTS/PGC/cell, and whether play stopped).

Rendering is ffmpeg over the cells' own sectors, so it needs no rig. What it cannot give:
the AUDIO (only what the subtitles carry), and anything the VM model gets wrong -- a card
is the model's view; the rig confirms the route.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import choice_graph as CG   # noqa: E402
import nav_offline as N     # noqa: E402

DOM = {0: 'FP', 1: 'VMGM', 2: 'VTSM', 3: 'TT'}
W, H = 360, 240


def _font(sz):
    for f in ('/usr/share/fonts/TTF/DejaVuSans.ttf', '/usr/share/fonts/dejavu/DejaVuSans.ttf',
              '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'):
        if os.path.exists(f):
            return ImageFont.truetype(f, sz)
    return ImageFont.load_default()


def _cut(iso, cells, path):
    with open(iso, 'rb') as f, open(path, 'wb') as o:
        for c in cells:
            if c[4] is None:
                continue
            f.seek(c[4] * 2048)
            o.write(f.read((c[5] - c[4] + 1) * 2048))


def _frames(vob, every, with_subs):
    """PIL frames sampled every `every` s; the first subtitle stream burnt in if any."""
    with tempfile.TemporaryDirectory() as td:
        # probe the WHOLE cut: a subtitle stream whose first packet comes late in the
        # scene is otherwise never found, and its dialogue silently goes missing
        big = ['-probesize', '2G', '-analyzeduration', '2000M']
        probe = subprocess.run(['ffprobe', '-v', 'error', *big, '-show_entries', 'stream=codec_name',
                                '-of', 'csv=p=0', vob], capture_output=True, text=True).stdout
        has_sub = with_subs and 'dvd_subtitle' in probe
        flt = ('[0:v:0][0:s:0]overlay,' if has_sub else '[0:v:0]') + \
            'fps=1/%g,scale=%d:%d' % (every, W, H)
        subprocess.run(['ffmpeg', '-v', 'error', *big, '-i', vob, '-filter_complex', flt + '[o]',
                        '-map', '[o]', os.path.join(td, 'f%04d.png')], capture_output=True)
        return [Image.open(os.path.join(td, n)).copy() for n in sorted(os.listdir(td))], has_sub


def _last_frame(vob):
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, 'last.png')
        subprocess.run(['ffmpeg', '-v', 'error', '-sseof', '-0.5', '-i', vob, '-map', '0:v:0',
                        '-update', '1', out], capture_output=True)
        if not os.path.exists(out):
            subprocess.run(['ffmpeg', '-v', 'error', '-i', vob, '-map', '0:v:0', '-frames:v', '1',
                            out], capture_output=True)
        return Image.open(out).copy() if os.path.exists(out) else None


def card(iso, script, out_dir, every=2.5, try_buttons=False, max_scene_frames=24):
    os.makedirs(out_dir, exist_ok=True)
    P = N.Player(iso)
    P.run(' '.join(map(str, script)), park_on_buttons=True)
    here = list(P.trace)
    btns = CG._buttons(P, None)
    st = P.state(len(btns))
    prev = []
    if script:
        Q = N.Player(iso)
        Q.run(' '.join(map(str, script[:-1])), park_on_buttons=True)
        prev = Q.trace
    scene = here[len(prev):] if here[:len(prev)] == prev else here[-8:]
    landing = {}
    if try_buttons:
        for b in btns:
            rows, Pb = CG.play(iso, list(script) + [b['n']])
            if Pb.pgc is None or len(rows) < len(script) + 1:
                landing[b['n']] = 'play stops'
            else:
                s2 = rows[-1][1]
                landing[b['n']] = '%s VTS %d PGC %d cell %d (%d buttons)' % (
                    CG.DOMS.get(s2['dom'], s2['dom']), s2['vts'], s2['pgcn'], s2['cell'], s2['buttons'])
    return _render(iso, scene, btns, st, script, out_dir, every, landing,
                   'card_%s.png' % ('_'.join(map(str, script)) or 'start'),
                   'script: %s' % (' '.join(map(str, script)) or '(power-on)'))


def _render(iso, scene, btns, st, script, out_dir, every, landing, name, label, max_scene_frames=24):
    os.makedirs(out_dir, exist_ok=True)
    choice_cell = scene[-1:]
    with tempfile.TemporaryDirectory() as td:
        sv, cv = os.path.join(td, 'scene.vob'), os.path.join(td, 'choice.vob')
        _cut(iso, scene[:-1] or scene, sv)
        _cut(iso, choice_cell, cv)
        frames, has_sub = _frames(sv, every, True) if os.path.getsize(sv) else ([], False)
        choice = _last_frame(cv)
    if len(frames) > max_scene_frames:           # keep the end: the lines that pose the choice
        frames = frames[-max_scene_frames:]
    # the choice screen, buttons numbered (rects are in 720x480 picture coordinates)
    cw, ch = 720, 480
    # draw the buttons on the frame at its OWN size: button rects are in the picture's
    # coordinates (720x576 on PAL), so drawing them after a resize to 480 lines puts every
    # rectangle ~20 % too low
    ci = (choice or Image.new('RGB', (cw, ch))).convert('RGB')
    d = ImageDraw.Draw(ci)
    fnt = _font(22)
    for b in btns:
        if b.get('x2', 0) > b.get('x1', 0):
            d.rectangle([b['x1'], b['y1'], b['x2'], b['y2']], outline=(255, 0, 255), width=3)
            d.text((b['x1'] + 4, b['y1'] + 2), str(b['n']), fill=(255, 255, 0), font=fnt,
                   stroke_width=3, stroke_fill=(0, 0, 0))
    ci = ci.resize((cw, ch))
    # compose: scene grid on top, choice + legend below
    cols = 4
    rows_ = (len(frames) + cols - 1) // cols
    legend = ['%d: %s%s' % (b['n'], b['cmd'], ('   -> ' + landing[b['n']]) if b['n'] in landing else '')
              for b in btns]
    lh = 22
    top = rows_ * H
    img = Image.new('RGB', (cols * W, top + ch + 30 + lh * (len(legend) + 2)), (16, 16, 16))
    for i, fr in enumerate(frames):
        img.paste(fr.convert('RGB').resize((W, H)), ((i % cols) * W, (i // cols) * H))
    img.paste(ci, (0, top))
    d = ImageDraw.Draw(img)
    f2 = _font(16)
    head = '%s VTS %d PGC %d cell %d  --  %s' % (
        CG.DOMS.get(st['dom'], st['dom']), st['vts'], st['pgcn'], st['cell'], label)
    d.text((cw + 12, top + 8), head, fill=(255, 255, 255), font=f2)
    d.text((cw + 12, top + 32), 'scene: %d cells, %d frames, subtitles %s' % (
        len(scene), len(frames), 'burnt in' if has_sub else 'NONE on this disc/scene'),
        fill=(200, 200, 200), font=f2)
    for i, line in enumerate(legend):
        d.text((8, top + ch + 12 + lh * i), line, fill=(255, 255, 160), font=f2)
    png = os.path.join(out_dir, name)
    img.save(png)
    meta = {'script': list(script), 'at': {k: st[k] for k in ('dom', 'vts', 'pgcn', 'cell')},
            'gprm': st['gprm'], 'scene_cells': [list(c[:4]) for c in scene],
            'subtitles': has_sub, 'buttons': btns, 'landing': landing, 'png': png}
    with open(png[:-4] + '.json', 'w') as f:
        json.dump(meta, f, indent=1)
    return png, meta


def card_at(iso, at, out_dir, every=2.5):
    """A card for a TITLE-domain screen named by its location ("TT/vts/pgcn/cell"),
    rendered from the disc without playing to it -- for discs whose draws (rnd) make a
    script from power-on unrepeatable. The scene is the cells after the previous input
    point of the same PGC; no landing (the VM is not run)."""
    import disc_timing as DT
    dom, vts, pgcn, cell = at.split('/')
    vts, pgcn, cell = int(vts), int(pgcn), int(cell)
    if dom != 'TT':
        raise SystemExit('--at renders title-domain screens (TT/vts/pgcn/cell)')
    d = DT.dump(iso, vts, pgcn)
    cells = d['cells']
    first = cell - 1
    while first > 0 and not (cells[first - 1]['hli'] and cells[first - 1]['hli'][0]['btn_ns']):
        first -= 1
    scene = [(3, vts, pgcn, c['cell'] - 1, c['lba_first'], c['lba_last']) for c in cells[first:cell]]
    h = cells[cell - 1]['hli'][0] if cells[cell - 1]['hli'] else None
    btns = [dict(b, fosl=h['fosl'], sptm_lo=h['s_ptm'] & 0xFFFFF) for b in (h['buttons'] if h else [])]
    return _render(iso, scene, btns, {'dom': 2, 'vts': vts, 'pgcn': pgcn, 'cell': cell,
                                      'gprm': [0] * 16}, [], out_dir, every, {},
                   'card_at_%d_%d_%d.png' % (vts, pgcn, cell), 'at %s' % at)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('iso')
    ap.add_argument('--script', default='', help='button numbers from power-on, space-separated')
    ap.add_argument('--at', help='render a title-domain screen by location instead, e.g. TT/5/7/2 '
                    '(no playing: for discs whose draws make a script unrepeatable)')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('--every', type=float, default=2.5, help='scene sampling period (s)')
    ap.add_argument('--try', dest='try_', action='store_true', help='show where each button leads')
    a = ap.parse_args()
    if a.at:
        png, meta = card_at(a.iso, a.at, a.out, a.every)
    else:
        png, meta = card(a.iso, [int(x) for x in a.script.split()], a.out, a.every, a.try_)
    print(png)
    print(json.dumps({k: meta[k] for k in ('at', 'scene_cells', 'subtitles', 'landing')}))


if __name__ == '__main__':
    main()
