#!/usr/bin/env python3
"""sstate_stress.py -- randomized save-state stress on the rig (OSD rows via /tmp/dvd_ctl).

A seeded random walk of saves, loads, seeks, chapter skips, menu jumps, track steps, load
spam, save-then-load, a relaunch with a load during the boot, Disc Menus switched off live
and a deliberately damaged slot file (docs/nav_engine.md §11b). Needs the custom Main with
dvd_sstate (tools/mister.py deploy --agent --main ...). The disc's existing slots are moved
aside for the run and always put back; a folder left by a run that died stops the next one.
NOFILM=1 keeps the walk in the menus.

Every save fetches the slot file it wrote; every load is scored against it:
  [verdict]  the Main's message is the expected one (Loaded / Slot N is empty / ...)
  [where]    VM domain, VTS, PGCN equal the saved ones
  [sprm]     SPRM1/2/3 (audio, subtitle, angle) equal the saved ones
  [gprm]     the 16 GPRMs equal the saved ones (WARN outside the title domain:
             a menu's own commands may run after the landing)
  [land]     in a title: shown time after the load - saved time in [-2, elapsed + 2]
  [alive]    in a title: the shown time advances between two snapshots 3 s apart
Usage: sstate_stress.py <iso on the rig> <ops> <seed> <outdir> [--boot S]
"""
import base64, json, os, random, re, subprocess, sys, time
REPO = os.environ.get('REPO', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, 'tools'))
import vm_snap  # noqa: E402

MP = ['python3', os.path.join(REPO, 'tools', 'mister.py')]
iso, nops, seed, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
BOOT = float(sys.argv[sys.argv.index('--boot') + 1]) if '--boot' in sys.argv else 45
os.makedirs(out, exist_ok=True)
rng = random.Random(seed)
LOG = open(os.path.join(out, 'ops.jsonl'), 'a')
saved = {}          # slot -> decoded save (this disc)
fails, warns, nload = [], [], 0


def run(args, t=90):
    return subprocess.run(MP + args, capture_output=True, text=True, timeout=t, cwd=REPO).stdout


def sh(cmd, t=60):
    return run(['shell', cmd], t)


def mark():
    m = re.search(r'\d+', sh('wc -l < /tmp/dvd_report.log 2>/dev/null || echo 0'))
    return int(m.group()) if m else 0


def new_lines(m):
    return [l for l in sh('tail -n +%d /tmp/dvd_report.log' % (m + 1)).splitlines() if 'DVD_SSTATE' in l]


def wait_msg(m, t=10):
    end = time.time() + t
    while time.time() < end:
        for l in new_lines(m):
            if re.search(r'Saved to|Loaded slot|is empty|Could not|need Disc Menus|different disc|damaged|another version|no save slots', l):
                return l, new_lines(m)
        time.sleep(0.4)
    return None, new_lines(m)


def press(bit, slot):
    sh("echo 'osd [59:57] %d' > /tmp/dvd_ctl; sleep 0.25; echo 'osd [%d] 1' > /tmp/dvd_ctl; "
       "sleep 0.3; echo 'osd [%d] 0' > /tmp/dvd_ctl" % (slot, bit, bit))


def snap():
    p = os.path.join(out, '_snap.json')
    if os.path.exists(p): os.remove(p)
    run(['snap', '-o', p], 40)
    try:
        return vm_snap.decode(json.load(open(p)))
    except Exception as e:  # noqa: BLE001
        return {'err': str(e)}


def rec(**kw):
    kw['t'] = round(time.time(), 1)
    LOG.write(json.dumps(kw) + '\n'); LOG.flush()
    print(json.dumps(kw), flush=True)


def where(s):
    return (s['in_vm_dom'], s['in_vm_vts'], s['in_cur_vts'], s['in_cur_pgcn'])


def do_save(slot):
    m = mark(); press(55, slot)
    msg, lines = wait_msg(m)
    ok = msg and ('Saved to slot %d' % (slot + 1)) in msg
    path = next((re.search(r'-> (\S+?):', l).group(1) for l in lines if '-> ' in l), None)
    if ok and path:
        if not path.startswith('/'): path = '/media/fat/' + path
        b = base64.b64decode(sh('base64 "%s"' % path).replace('\n', ''))
        lp = os.path.join(out, 'slot%d_%d.ss' % (slot + 1, int(time.time())))
        open(lp, 'wb').write(b)
        d = vm_snap.decode(vm_snap.load_ss(lp)); d['path'] = path
        saved[slot] = d
        rec(op='save', slot=slot + 1, ok=True, where=where(d['state']), disp=d['pos']['disp_secs'])
    else:
        if msg and 'Disc Menus' in msg and menus_off: ok = True
        rec(op='save', slot=slot + 1, ok=bool(ok), msg=msg)
        if not ok: fails.append(('save', slot + 1, msg))


def do_load(slot, spam=0, tag='load'):
    global nload
    nload += 1
    m = mark(); t0 = time.time()
    press(56, slot)
    for _ in range(spam):
        sh("echo 'osd [56] 1' > /tmp/dvd_ctl; sleep 0.15; echo 'osd [56] 0' > /tmp/dvd_ctl")
    msg, _ = wait_msg(m, 12)
    want = ('Loaded slot %d' % (slot + 1)) if slot in saved else ('Slot %d is empty' % (slot + 1))
    if menus_off: want = 'need Disc Menus'
    r = {'op': tag, 'slot': slot + 1, 'msg': msg, 'spam': spam}
    bad = []
    if not msg or want not in msg:
        bad.append('verdict: %r, wanted %r' % (msg, want))
    if slot in saved and not menus_off and msg and 'Loaded' in msg:
        time.sleep(2.5)   # soon: a short PGC (T2's 48 s intro) ends and its post command runs
        s1 = snap(); el = time.time() - t0
        time.sleep(3)
        s2 = snap()
        if 'err' in s1 or 'err' in s2:
            bad.append('snapshot: %s' % (s1.get('err') or s2.get('err')))
        else:
            e = saved[slot]; es, ss = e['state'], s1['state']
            r['where'] = [where(es), where(ss)]
            if where(es) != where(ss): bad.append('where: saved %s, now %s' % (where(es), where(ss)))
            for n in (1, 2, 3):
                if es['sprm%d' % n] != ss['sprm%d' % n]:
                    bad.append('sprm%d: saved %04x, now %04x' % (n, es['sprm%d' % n], ss['sprm%d' % n]))
            gd = [i for i in range(16) if es['g%d' % i] != ss['g%d' % i]]
            title = es['in_vm_dom'] == 3
            if gd:
                txt = 'gprm ' + ', '.join('g%d %04x->%04x' % (i, es['g%d' % i], ss['g%d' % i]) for i in gd)
                if title: bad.append(txt)
                else: warns.append((tag, slot + 1, txt))
            if title and e['pos']['disp_secs'] >= 0:
                d1, d2 = s1['pos']['disp_secs'], s2['pos']['disp_secs']
                lag = d1 - e['pos']['disp_secs']
                r['land'] = [e['pos']['disp_secs'], d1, round(el, 1)]
                if not (-2 <= lag <= el + 2): bad.append('land: saved %d s, shown %d s, %.1f s after the press' % (e['pos']['disp_secs'], d1, el))
                r['adv'] = d2 - d1
                if not (1 <= d2 - d1 <= 6): bad.append('alive: shown time %d -> %d over 3 s' % (d1, d2))
        run(['shot', '-o', os.path.join(out, 'load%03d_s%d.png' % (nload, slot + 1))], 40)
    r['ok'] = not bad
    if bad: r['bad'] = bad; fails.append((tag, slot + 1, bad))
    rec(**r)


NOFILM = bool(os.environ.get('NOFILM'))


def film():
    """Select from a menu until the VM is in a title (domain 3); a few tries."""
    if NOFILM:   # menu run: stay in the menus (a select may still start something)
        return False
    for _ in range(4):
        d = snap()
        if 'err' not in d and d['state']['in_vm_dom'] == 3:
            rec(op='film', ok=True); return True
        run(['key', 'select']); time.sleep(8)
    rec(op='film', ok=False); return False


def launch():
    run(['launch', iso, '--opt', 'Disc Menus=On'], 120)
    time.sleep(BOOT)


menus_off = False
m0 = mark()
launch()
ident = next((re.search(r'disc identity (\S+)', l).group(1) for l in new_lines(m0) if 'disc identity' in l), None)
if not ident: sys.exit('no disc identity logged: not a DVD-Video image?')
# The disc's existing slots go aside for the run, into a folder of this run's own, and
# come back whatever happens (finally, below). A leftover folder from an earlier run that
# never restored stops us: its files must be put back by hand first.
SSD = '/media/fat/savestates/DVD'
if sh('ls -d %s/.stress_bk_* 2>/dev/null' % SSD).strip():
    sys.exit('a previous run left %s/.stress_bk_*: restore it first' % SSD)
BK = '%s/.stress_bk_%d' % (SSD, int(time.time()))
sh('mkdir -p %s; mv %s/%s_*.ss %s/ 2>/dev/null' % (BK, SSD, ident, BK))
rec(op='launch', iso=iso, ident=ident, set_aside=sh('ls %s' % BK).split())


def restore_slots():
    sh('rm -f %s/%s_*.ss; mv %s/* %s/ 2>/dev/null; rmdir %s' % (SSD, ident, BK, SSD, BK))
    rec(op='slots-restored', now=sh('ls %s' % SSD).split())


def body():
    global menus_off
    # seed: get into the film once, so there is something other than the menu to save
    for i in range(nops):
        a = rng.choices(['wait', 'chap', 'seek', 'menu', 'select', 'nav', 'audio', 'save', 'load',
                         'spam', 'saveload', 'reboot', 'menusoff', 'damaged', 'film'],
                        [10, 8, 8, 5, 6, 6, 4, 16, 18, 4, 3, 2, 1, 1, 6])[0]
        slot = rng.randrange(4)
        if a == 'film': film()
        elif a == 'wait': time.sleep(rng.uniform(3, 25)); rec(op='wait')
        elif NOFILM and a in ('chap', 'seek', 'audio'): run(['key', 'menu']); time.sleep(8); rec(op='menu')
        elif a == 'chap': run(['key', rng.choice(['next-chapter', 'prev-chapter'])]); time.sleep(4); rec(op='chap')
        elif a == 'seek': run(['key'] + [rng.choice(['right', 'left'])] * rng.randint(1, 4)); time.sleep(5); rec(op='seek')
        elif a == 'menu': run(['key', rng.choice(['menu', 'title'])]); time.sleep(8); rec(op='menu')
        elif a == 'select': run(['key', 'select']); time.sleep(6); rec(op='select')
        elif a == 'nav': run(['key', rng.choice(['up', 'down', 'left', 'right']), 'select']); time.sleep(6); rec(op='nav')
        elif a == 'audio':
            run(['key', 'audio']); time.sleep(0.5); run(['key', 'audio']); time.sleep(3); rec(op='audio')
        elif a == 'save': do_save(slot)
        elif a == 'load': do_load(slot)
        elif a == 'spam': do_load(slot, spam=rng.randint(2, 4), tag='spam')
        elif a == 'saveload':
            do_save(slot); do_load(slot, tag='saveload')
        elif a == 'reboot':
            if saved:
                slot = rng.choice(sorted(saved))
                run(['launch', iso, '--opt', 'Disc Menus=On'], 120); time.sleep(rng.uniform(3, 10))
                do_load(slot, tag='bootload')
                time.sleep(2)
        elif a == 'menusoff':
            run(['osd', 'Disc Menus=Off']); time.sleep(2); menus_off = True
            do_save(slot); do_load(slot, tag='menusoff')
            run(['osd', 'Disc Menus=On']); time.sleep(2); menus_off = False
            rec(op='menus-on-again')
            # the reader restarted on the auto title: the VM reboots -> give it time
            time.sleep(20)
        elif a == 'damaged' and saved:
            slot = rng.choice(sorted(saved)); p = saved[slot]['path']
            sh("printf '\\x55' | dd of=\"%s\" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null" % p)
            m = mark(); press(56, slot); msg, _ = wait_msg(m)
            ok = bool(msg and 'damaged' in msg)
            rec(op='damaged', slot=slot + 1, msg=msg, ok=ok)
            if not ok: fails.append(('damaged', slot + 1, msg))
            sh('rm -f "%s"' % p); del saved[slot]

    # end: every saved slot loads once more, then the user's slots come back
    for slot in sorted(saved): do_load(slot, tag='final')


try:
    film()
    body()
finally:
    restore_slots()
rec(op='summary', loads=nload, fails=len(fails), warns=len(warns))
json.dump({'fails': fails, 'warns': warns}, open(os.path.join(out, 'summary.json'), 'w'), indent=1)
print('FAILS', len(fails)); [print(' ', f) for f in fails]
print('WARNS', len(warns)); [print(' ', w) for w in warns]
