#!/usr/bin/env python3
"""
mister.py -- drive a MiSTer running the DVD core, over ssh.

The hardware-in-the-loop harness: deploy a build, launch a disc, press buttons,
and pull back a screenshot -- so a session can SEE the core instead of asking
someone to test and report. Design notes and the facts it relies on are in
docs/hil_harness.md.

Nothing here needs a change to the core or to MiSTer's Main. It composes four
stock mechanisms:

  load_core   /dev/MiSTer_cmd accepts an .mgl, which loads a core AND mounts
              media in one command (input.cpp:6238, user_io.cpp:1518).
  screenshot  the same FIFO writes a PNG of the CORE's raw raster -- read from
              ascal's INPUT buffer (sys_top.v:680), so it carries no MiSTer OSD
              (composited after ascal, sys_top.v:1149), no popups and no
              scaling. MEASURED: a shot taken with the OSD open shows no OSD.
  DVD_v2.CFG  the core's saved settings are a raw dump of Main's 128-bit status
              word (user_io.cpp:600), read at core init before reset is released
              -- so writing 16 bytes sets any OSD option for the next launch.
  uinput      a virtual keyboard on the target reaches dvd/kbd_map.sv, which
              maps every transport action (see tools/mister_keyd.py).

Configuration, in precedence order -- NEVER hardcode a host, this repo is
public:
    $MISTER_HOST                 e.g. root@192.168.1.10
    tools/.mister_host           one line, gitignored
    $MISTER_CORE_DIR             default /media/fat/_Other
    $MISTER_CFG_DIR              default /media/fat/config

Usage:
    mister.py state
    mister.py deploy [--rbf PATH] [--agent]
    mister.py launch <image> [--opt "Video Output=Progressive"] ... [--delay N]
    mister.py key <name> [<name> ...]
    mister.py shot [-o FILE] [--decode]
    mister.py log [-n N]
    mister.py options
    mister.py shell -- <command>
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import docs_check                                    # noqa: E402  (CONF_STR parser)

CORE_DIR = os.environ.get('MISTER_CORE_DIR', '/media/fat/_Other')
CFG_DIR = os.environ.get('MISTER_CFG_DIR', '/media/fat/config')
SHOT_DIR = '/media/fat/screenshots'
# A FIXED name, deliberately. MGL <rbf> resolution takes the lexicographically
# GREATEST match (mra_loader.cpp:1288), not the newest file -- with ~75 DVD_*
# builds in _Other/ a bare "DVD" selects whichever sorts last, which on this rig
# is a MARGINAL build from weeks ago. The core name comes from CONF_STR[0], not
# the filename, so renaming costs nothing: it is still "DVD" and still uses
# DVD_v2.CFG.
HIL_RBF = 'DVD_hil.rbf'
HIL_MGL = 'DVD_hil.mgl'
CFG_NAME = 'DVD_v2.CFG'
AGENT_SRC = os.path.join(HERE, 'mister_keyd.py')
AGENT_DST = '/tmp/mister_keyd.py'
AGENT_FIFO = '/tmp/mister_hil'

SSH_OPTS = [
    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ControlMaster=auto', '-o', 'ControlPath=~/.ssh/cm-mister-%C',
    '-o', 'ControlPersist=120',
]


# Remote helpers kept as plain strings: they contain shell heredocs, which do
# not survive being nested inside f-strings.
_INI_REWRITE = """
python3 - <<'PYEND'
import re
p = '/media/fat/MiSTer.ini'
s = open(p, encoding='utf-8', errors='replace').read()
s = re.sub(r'(?s)(\\[DVD\\]\\n)(.*?)(?=\\n\\[|\\Z)',
           lambda m: m.group(1) + re.sub(r'(?m)^main=.*$', 'main=@TARGET@', m.group(2)),
           s, count=1)
open(p, 'w').write(s)
print('  [DVD] ' + [l for l in s.splitlines() if l.startswith('main=')][0])
PYEND
"""

INI_MAIN_SCRIPT = """
chmod +x /media/fat/@NAME@
[ -f /media/fat/MiSTer.ini.hilbak ] || cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.hilbak
""" + _INI_REWRITE.replace('@TARGET@', '@NAME@') + """
# Garbage-collect earlier harness binaries that are neither the target nor
# currently running -- /media/fat is nearly full and these are 1 MB each.
for f in /media/fat/MiSTer_DVDcss_hil_*; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  [ "$b" = "@NAME@" ] && continue
  running=0
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$f" ] && running=1
  done
  [ $running = 0 ] && rm -f "$f" && echo "  removed stale $b"
done
"""

RESTORE_SCRIPT = _INI_REWRITE.replace('@TARGET@', 'MiSTer_DVDcss') + """
pkill -f @AGENT@ 2>/dev/null
rm -f /media/fat/dvd_hil
rm -f @FIFO@ @AGENT@ @COREDIR@/@RBF@ @COREDIR@/@MGL@
for f in /media/fat/MiSTer_DVDcss_hil_*; do
  [ -e "$f" ] || continue
  running=0
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$f" ] && running=1
  done
  [ $running = 0 ] && rm -f "$f"
done
echo "  harness files removed (core, mgl, agent, spare Mains)"
echo "  NOTE: config/@CFG@ still holds whatever options the harness last set,"
echo "        and the running Main stays until the next core load."
"""


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
def host():
    h = os.environ.get('MISTER_HOST')
    if h:
        return h.strip()
    path = os.path.join(HERE, '.mister_host')
    if os.path.exists(path):
        h = open(path).read().strip()
        if h:
            return h
    sys.exit('mister: no host. Set $MISTER_HOST or write tools/.mister_host '
             '(one line, e.g. root@192.168.1.10). It is gitignored.')


def ssh(script, check=True, timeout=120):
    """Run a shell script on the target. Returns (rc, stdout)."""
    p = subprocess.run(['ssh', *SSH_OPTS, host(), 'bash -s'],
                       input=script, capture_output=True, text=True,
                       timeout=timeout)
    # ssh chatters on stderr (host-key notes, PQ warnings); only surface it on
    # failure, and never let it contaminate stdout.
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: remote command failed (rc={p.returncode})')
    return p.returncode, p.stdout


def scp(src, dst, to_target=True, timeout=180):
    a, b = (src, f'{host()}:{dst}') if to_target else (f'{host()}:{src}', dst)
    p = subprocess.run(['scp', *SSH_OPTS, '-q', a, b],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f'mister: scp failed ({a} -> {b})')


def fifo(cmd):
    """Write ONE command to /dev/MiSTer_cmd.

    One per write, always: Main does a single read() then a single if/else-if
    chain (input.cpp:6230), so two commands in one write means the second is
    silently discarded.
    """
    ssh(f'echo {shlex.quote(cmd)} > /dev/MiSTer_cmd\n')


# ---------------------------------------------------------------------------
# key names, derived from the RTL rather than hand-listed
# ---------------------------------------------------------------------------
# PS/2 set-2 -> Linux keycode, inverted from Main's own ev2ps2[]
# (input.cpp:366). Regenerate with tools/tests/test_mister.py if Main's table
# ever changes.
PS2_TO_LINUX = {
    (0x04, False): 61, (0x05, False): 59, (0x06, False): 60, (0x0C, False): 62,
    (0x0D, False): 15, (0x1B, False): 31, (0x1C, False): 30, (0x22, False): 45,
    (0x23, False): 32, (0x29, False): 57, (0x2B, False): 33, (0x2C, False): 20,
    (0x2D, False): 19, (0x31, False): 49, (0x32, False): 48, (0x34, False): 34,
    (0x3A, False): 50, (0x4D, False): 25, (0x5A, False): 28, (0x66, False): 14,
    (0x76, False): 1,
    (0x5A, True): 96, (0x6B, True): 105, (0x72, True): 108, (0x74, True): 106,
    (0x75, True): 103, (0x7A, True): 109, (0x7D, True): 104,
}
DPAD = {0: 'right', 1: 'left', 2: 'down', 3: 'up'}
KEY_F12 = 88


def kbd_map_table():
    """Parse dvd/kbd_map.sv -> {joy bit: [(ps2 code, extended), ...]}.

    Derived, not transcribed: a new binding in the RTL is usable the same day,
    and the two cannot drift apart.
    """
    src = open(os.path.join(ROOT, 'dvd', 'kbd_map.sv')).read()
    m = re.search(r'if \(ps2_key\[8\]\) begin(.*?)\n\s*end else begin(.*?)\n\s*end\b',
                  src, re.S)
    if not m:
        sys.exit('mister: could not find the kbd_map.sv decode table')
    out = {}
    for extended, body in ((True, m.group(1)), (False, m.group(2))):
        body = re.sub(r'//[^\n]*', '', body)
        for code, bit in re.findall(r"8'h([0-9A-Fa-f]{2}):\s*hit\[(\d+)\]", body):
            out.setdefault(int(bit), []).append((int(code, 16), extended))
    return out


def key_names():
    """{name: linux keycode} for every transport action the core exposes."""
    lits = docs_check.extract_conf_str(open(os.path.join(ROOT, 'dvd', 'emu.sv')).read())
    _, buttons, _ = docs_check.parse(lits)
    table = kbd_map_table()
    names = {}
    for bit, codes in sorted(table.items()):
        # A bit may have several keys (M / X / F1 all mean Menu). Pick
        # deterministically: the first entry the RTL lists for that bit.
        linux = None
        for code, ext in codes:
            linux = PS2_TO_LINUX.get((code, ext))
            if linux is not None:
                break
        if linux is None:
            continue
        if bit in DPAD:
            label = DPAD[bit]
        elif bit - 4 < len(buttons):
            label = buttons[bit - 4]
        else:
            continue
        names[label.lower().replace(' ', '-')] = linux
    names['osd'] = KEY_F12          # Main's OSD toggle, not a core action
    for d in range(10):             # digits select+activate menu button N
        names[str(d)] = (11 if d == 0 else 1 + d)
    return names


# ---------------------------------------------------------------------------
# OSD options -> the 16-byte saved-settings blob
# ---------------------------------------------------------------------------
def options():
    lits = docs_check.extract_conf_str(open(os.path.join(ROOT, 'dvd', 'emu.sv')).read())
    return docs_check.parse_bits(lits)


def build_status(opts):
    """[('Video Output', 'Progressive'), ...] -> 16 bytes of cur_status.

    ALL 16 bytes are always written from the full option set: the blob carries
    no version or checksum, so patching bytes in place would silently give a
    bit a new meaning if CONF_STR were ever relaid out.
    """
    table = options()
    by_label = {label.lower(): (label, s, e, vals) for label, s, e, vals in table}
    word = 0
    for name, value in opts:
        entry = by_label.get(name.strip().lower())
        if entry is None:
            sys.exit(f'mister: unknown option {name!r}. Try: mister.py options')
        label, start, end, vals = entry
        value = value.strip()
        idx = None
        for i, v in enumerate(vals):
            if v.strip().lower() == value.lower():
                idx = i
                break
        if idx is None:
            if re.fullmatch(r'\d+', value):
                idx = int(value)
            else:
                sys.exit(f'mister: {label!r} has no value {value!r}. '
                         f'Choices: {", ".join(vals)}')
        width = end - start + 1
        if idx >= (1 << width):
            sys.exit(f'mister: value {idx} does not fit {label!r} ({width} bits)')
        word |= idx << start
    return word.to_bytes(16, 'little')


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
def newest_rbf():
    rel = os.path.join(ROOT, 'releases')
    cands = [os.path.join(rel, f) for f in os.listdir(rel)] if os.path.isdir(rel) else []
    cands = [c for c in cands if c.endswith('.rbf')]
    if not cands:
        sys.exit('mister: no .rbf in releases/ -- build one, or pass --rbf')
    return max(cands, key=os.path.getmtime)


def deploy_main(path):
    """Install a new custom Main SAFELY, without a reboot.

    NEVER overwrite /media/fat/MiSTer_DVDcss in place. Once the DVD core has
    been entered, that binary is the RUNNING process for the rest of the boot
    (returning to the menu re-execs the same exe via getappname()). Writing over
    it makes readlink /proc/self/exe return "... (deleted)", so the next
    load_core's execl fails and app_restart falls through to reboot(1)
    (fpga_io.cpp:611-645); writing in place instead fails with ETXTBSY.

    So: install under a name derived from the binary's own hash -- which is
    definitionally not the running one -- and point [DVD] main= at it.
    fpga_load_rbf then execs the still-present current binary, whose
    user_io_init() sees cfg.main != getappname() and re-execs into the new one
    (user_io.cpp:1483-1488). No reboot, and fully reversible with `restore`.
    """
    import hashlib
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()[:8]
    name = 'MiSTer_DVDcss_hil_' + sha
    target = '/media/fat/' + name
    print('deploy: %s -> %s' % (os.path.basename(path), target))
    # ⚠ The hash-derived name is normally not the running binary -- but it IS if
    # the same build is deployed twice, and then the scp would overwrite the
    # running process, which is precisely the reboot landmine this function
    # exists to avoid. Identical content, so there is nothing to copy anyway.
    _, running = ssh("for p in $(ls /proc | grep -E '^[0-9]+$'); do "
                     "readlink /proc/$p/exe 2>/dev/null; done | grep MiSTer | head -1\n",
                     check=False)
    if running.strip() == target:
        print('  already running this exact binary -- nothing to copy')
        return
    scp(path, target)
    script = INI_MAIN_SCRIPT.replace('@NAME@', name).replace('@AGENT@', AGENT_DST)
    _, out = ssh(script)
    print(out.rstrip())
    print('  (takes effect on the next core load; the running Main is untouched)')


def cmd_restore(args):
    """Put the rig back to stock: main=MiSTer_DVDcss, harness files removed."""
    script = RESTORE_SCRIPT.replace('@AGENT@', AGENT_DST) \
                           .replace('@FIFO@', AGENT_FIFO) \
                           .replace('@COREDIR@', CORE_DIR) \
                           .replace('@RBF@', HIL_RBF).replace('@MGL@', HIL_MGL) \
                           .replace('@CFG@', CFG_NAME)
    _, out = ssh(script)
    print('restore:')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        os.remove(st)
    return 0


def cmd_deploy(args):
    if args.main:
        deploy_main(args.main)
        if not args.rbf and not args.agent:
            return 0
    ssh(f'mkdir -p {SHOT_DIR}; touch /media/fat/dvd_hil\n')   # arms dvd_ctl
    if args.agent or not args.rbf_only:
        scp(AGENT_SRC, AGENT_DST)
        # restart it: one device for its lifetime, so a stale one must go first
        _, out = ssh(f'''
pkill -f {AGENT_DST} 2>/dev/null
rm -f {AGENT_FIFO}
setsid python3 {AGENT_DST} </dev/null >>/tmp/mister_keyd.log 2>&1 &
sleep 2
[ -p {AGENT_FIFO} ] && echo "agent: listening" || echo "agent: FIFO MISSING"
''')
        print(out.strip())
    if not args.agent:
        rbf = args.rbf or newest_rbf()
        print(f'deploy: {os.path.basename(rbf)} -> {CORE_DIR}/{HIL_RBF}')
        scp(rbf, f'{CORE_DIR}/{HIL_RBF}')
        meta = rbf + '.json'
        state = {'rbf': os.path.basename(rbf), 'deployed': time.strftime('%F %T')}
        if os.path.exists(meta):
            try:
                j = json.load(open(meta))
                state.update({k: j.get(k) for k in
                              ('core_version', 'git_sha', 'git_branch', 'seed',
                               'fmax_slow_100c', 'marginal') if k in j})
            except Exception:
                pass
        with open(os.path.join(HERE, '.mister_state.json'), 'w') as f:
            json.dump(state, f, indent=2)
        for k, v in state.items():
            print(f'  {k}: {v}')


def cmd_launch(args):
    img = args.image
    opts = [tuple(o.split('=', 1)) for o in (args.opt or [])]
    for o in opts:
        if len(o) != 2:
            sys.exit('mister: --opt takes "Name=Value"')
    blob = build_status(opts)
    print(f'launch: {img}')
    if opts:
        print('  options: ' + ', '.join(f'{k}={v}' for k, v in opts))
    print(f'  status word: {blob.hex()}')
    mgl = (f'<mistergamedescription>\n'
           f'  <rbf>{os.path.basename(CORE_DIR)}/{HIL_RBF[:-4]}</rbf>\n'
           f'  <file delay="{args.delay}" type="s" index="0" '
           f'path="{img}"/>\n'
           f'</mistergamedescription>\n')
    ssh(f'''
python3 -c "import sys;open('{CFG_DIR}/{CFG_NAME}','wb').write(bytes.fromhex('{blob.hex()}'))"
cat > {CORE_DIR}/{HIL_MGL} <<'MGLEOF'
{mgl}MGLEOF
''')
    fifo(f'load_core {CORE_DIR}/{HIL_MGL}')
    if not args.no_wait:
        cmd_wait(args)


def cmd_wait(args):
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        _, out = ssh('cat /tmp/CORENAME 2>/dev/null\n', check=False, timeout=30)
        if out.strip() == 'DVD':
            break
        time.sleep(0.5)
    else:
        sys.exit('mister: timed out waiting for the DVD core')
    # then wait for the MGL to finish mounting -- never a fixed sleep
    while time.time() < deadline:
        _, out = ssh('tail -20 /tmp/dvd_report.log 2>/dev/null\n', check=False, timeout=30)
        if 'MGL finished' in out:
            print('  ' + [l for l in out.splitlines() if 'MGL finished' in l][-1].strip())
            return
        time.sleep(0.5)
    print('  (no "MGL finished" seen; continuing)')


def cmd_key(args):
    names = key_names()
    codes = []
    for n in args.names:
        n = n.lower()
        if n not in names:
            sys.exit(f'mister: unknown key {n!r}. Known: {", ".join(sorted(names))}')
        codes.append(names[n])
    rc, out = ssh(f'''
[ -p {AGENT_FIFO} ] || {{ echo "NOAGENT"; exit 0; }}
echo "keys {' '.join(str(c) for c in codes)}" > {AGENT_FIFO}
echo sent
''')
    if 'NOAGENT' in out:
        sys.exit('mister: key daemon is not running -- `mister.py deploy --agent`')
    print(f'key: {" ".join(args.names)}  ({", ".join(str(c) for c in codes)})')


def cmd_shot(args):
    name = 'hil.png'
    ssh(f'''
rm -f {SHOT_DIR}/{name}
echo 'screenshot {name}' > /dev/MiSTer_cmd
for i in $(seq 1 20); do
  sleep 0.25
  if [ -f {SHOT_DIR}/{name} ]; then
    a=$(stat -c %s {SHOT_DIR}/{name}); sleep 0.25
    b=$(stat -c %s {SHOT_DIR}/{name})
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
echo "NOSHOT"; exit 1
''', check=False)
    out = args.out or os.path.join(
        os.environ.get('TMPDIR', '/tmp'), f'mister_{time.strftime("%H%M%S")}.png')
    scp(f'{SHOT_DIR}/{name}', out, to_target=False)
    print(f'shot: {out}')
    if args.decode:
        subprocess.run([sys.executable, os.path.join(HERE, 'hud_read.py'),
                        'read', out])


def cmd_capture(args):
    """Record A/V from the capture card with the settings known to work here.

    Centralised because two of the settings are non-obvious and both cost time
    when guessed:

      * DISCARD A WARM-UP. The card emits ~1 s of black while it locks, at every
        resolution. Grabbing a frame inside that window looks exactly like "no
        signal" and led to a round of blaming the cable -- ffplay appeared to
        work only because it kept running past the lock.
      * 720x480 rather than 1080p. Detection is a whole-region luma step, so
        resolution buys nothing, while 1080p60 MJPEG is ~4x the USB bandwidth
        and delivery jitter is what actually limits timing precision.
    """
    cal = {}
    if os.path.exists(os.path.join(HERE, '.mister_capture.json')):
        cal = json.load(open(os.path.join(HERE, '.mister_capture.json')))
    vdev = args.vdev or cal.get('video_device', '/dev/video0')
    adev = args.adev or cal.get('audio_device', 'hw:1,0')
    out = args.out or os.path.join(os.environ.get('TMPDIR', '/tmp'),
                                   f'hilcap_{time.strftime("%H%M%S")}.mkv')
    total = args.seconds + args.warmup
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'v4l2', '-input_format', args.pixfmt,
           '-video_size', args.video_size, '-framerate', str(args.fps),
           '-i', vdev,
           '-f', 'alsa', '-ac', '2', '-ar', '48000', '-i', adev,
           '-t', str(total), '-c:v', 'copy', '-c:a', 'pcm_s16le', out]
    print(f'capture: {args.video_size}@{args.fps} {args.pixfmt} from {vdev} + {adev}')
    print(f'  {args.seconds}s (+{args.warmup}s warm-up) -> {out}')
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        sys.exit(f'mister: ffmpeg capture failed (rc={rc})')
    print(f'  measure with: tools/lipsync_measure.py capture {out} --raw')
    return 0


def cmd_telem(args):
    """Read the core's pacing counters (dvd/dvd_telem.sv -> dvd_ctl -> JSON).

    `--watch N` samples for N seconds in ONE ssh session and reports rates. The
    number this exists for is refreshes/pickups: the governor is supposed to
    show each content frame for exactly show_next refreshes, so for 29.97
    content on a 59.94 Hz raster it must be 2.000. A measured ~450 ppm
    video-fast A/V drift says it may be slightly under.
    """
    if not args.watch:
        _, out = ssh('cat /tmp/dvd_telem.json 2>/dev/null\n')
        if not out.strip():
            sys.exit('mister: no telemetry. Needs a core build with dvd_telem '
                     'and a Main with dvd_ctl (mister.py state).')
        print(out.strip())
        return 0

    n = int(args.watch / 0.5)
    _, out = ssh(f'for i in $(seq 1 {n}); do cat /tmp/dvd_telem.json 2>/dev/null; '
                 f'sleep 0.5; done\n', timeout=args.watch + 60)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('{'):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    if len(rows) < 4:
        sys.exit(f'mister: only {len(rows)} telemetry samples -- is the core playing?')

    def unwrap(key):
        """16-bit counters wrap; sum the deltas modulo 65536."""
        total, prev = 0, rows[0][key]
        for r in rows[1:]:
            total += (r[key] - prev) & 0xFFFF
            prev = r[key]
        return total

    span = rows[-1]['t'] - rows[0]['t']
    refr, pick = unwrap('refreshes'), unwrap('pickups')
    late, drop = unwrap('lates'), unwrap('drops')
    errs = [r['vid_err'] for r in rows]
    print(f'telemetry over {span:.1f} s ({len(rows)} samples)')
    print(f'  refreshes {refr:6d}  ({refr / span:7.3f}/s)')
    print(f'  pickups   {pick:6d}  ({pick / span:7.3f}/s)')
    if pick:
        print(f'  refreshes per picked-up frame: {refr / pick:.5f}')
    # pickups/s IS the content display rate, and comparing it to the rate the
    # disc was authored at is the whole measurement -- no assumed ratio needed.
    # (A ratio of 2.000 only holds for 29.97 progressive; 23.976 film displayed
    # via 3:2 on a 59.94 raster averages 2.5.)
    rate = pick / span
    print(f'  content display rate: {rate:.5f} fps')
    for name, ideal in (('29.97 (30000/1001)', 30000 / 1001.0),
                        ('23.976 (24000/1001)', 24000 / 1001.0),
                        ('25 (PAL)', 25.0)):
        if abs(rate - ideal) / ideal < 0.02:
            print(f'    vs authored {name}: {(rate / ideal - 1) * 1e6:+.0f} ppm')
    rrate = refr / span
    print(f'  raster refresh rate:  {rrate:.5f} Hz')
    for name, ideal in (('59.94', 60000 / 1001.0), ('50', 50.0),
                        ('23.976', 24000 / 1001.0)):
        if abs(rrate - ideal) / ideal < 0.02:
            print(f'    vs nominal {name} Hz: {(rrate / ideal - 1) * 1e6:+.0f} ppm')
    # --- audio, and the ratio that needs no external reference ------------
    if 'aud_play' in rows[0]:
        samples = unwrap('aud_play') * 16          # counter is prescaled by 16
        gates = unwrap('aud_gate')
        print(f'  audio samples {samples}  ({samples / span:9.3f} Hz)')
        print(f'    vs nominal 48000 Hz: {(samples / span / 48000 - 1) * 1e6:+.0f} ppm')
        if refr:
            per = samples / refr
            ideal = 48000.0 / (60000 / 1001.0)     # 800.8008 samples per refresh
            print(f'  samples per raster refresh: {per:.4f}  (ideal {ideal:.4f})')
            print(f'    -> AUDIO vs RASTER: {(per / ideal - 1) * 1e6:+.0f} ppm'
                  '   <-- internal ratio, no external clock')
        print(f'  drain-gate closures: {gates}'
              + ('   <-- audio is being held' if gates else ''))
    print(f'  lates {late} ({late / span:.2f}/s)   drops {drop} ({drop / span:.2f}/s)')
    print(f'  vid_err {min(errs):+d} .. {max(errs):+d} refreshes')
    if args.csv:
        cols = [k for k in rows[0] if k != 'flags']      # dict order, not a set
        with open(args.csv, 'w') as f:
            f.write(','.join(cols) + '\n')
            for r in rows:
                f.write(','.join(str(r[k]) for k in cols) + '\n')
        print(f'  wrote {args.csv}')
    return 0


def cmd_osd(args):
    """Set an OSD option LIVE, without relaunching the core."""
    name, _, value = args.setting.partition('=')
    table = {label.lower(): (label, s, e, vals) for label, s, e, vals in options()}
    ent = table.get(name.strip().lower())
    if ent is None:
        sys.exit(f'mister: unknown option {name!r}. Try: mister.py options')
    label, start, end, vals = ent
    idx = next((i for i, v in enumerate(vals)
                if v.strip().lower() == value.strip().lower()), None)
    if idx is None:
        if not re.fullmatch(r'\d+', value.strip()):
            sys.exit(f'mister: {label!r} has no value {value!r}. '
                     f'Choices: {", ".join(vals)}')
        idx = int(value)
    opt = f'[{end}:{start}]' if end != start else f'[{start}]'
    ssh(f'echo "osd {opt} {idx}" > /tmp/dvd_ctl\n')
    print(f'osd: {label} = {vals[idx] if idx < len(vals) else idx}  ({opt} <= {idx})')
    return 0


def cmd_state(args):
    _, out = ssh('''
echo "corename=$(cat /tmp/CORENAME 2>/dev/null)"
echo "osd_visible=$(cat /tmp/OSD_VISIBLE 2>/dev/null || echo '(needs log_file_entry=1 in MiSTer.ini)')"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  e=$(readlink /proc/$p/exe 2>/dev/null)
  case "$e" in *MiSTer*) echo "main=$e";; esac
done
[ -p ''' + AGENT_FIFO + ''' ] && echo "agent=listening" || echo "agent=down"
echo "--- dvd_report.log ---"
tail -5 /tmp/dvd_report.log 2>/dev/null
''')
    print(out.rstrip())
    st = os.path.join(HERE, '.mister_state.json')
    if os.path.exists(st):
        print('--- deployed ---')
        for k, v in json.load(open(st)).items():
            print(f'{k}={v}')


def cmd_log(args):
    _, out = ssh(f'tail -{args.n} /tmp/dvd_report.log 2>/dev/null\n')
    print(out.rstrip())


def cmd_options(args):
    print('OSD options (from dvd/emu.sv CONF_STR):')
    for label, s, e, vals in options():
        print(f'  {label:<20} bits[{e}:{s}]  {", ".join(vals)}')
    print('\nKeys (from dvd/kbd_map.sv):')
    print('  ' + ', '.join(sorted(key_names())))


def cmd_shell(args):
    rc, out = ssh(' '.join(args.rest) + '\n', check=False)
    print(out.rstrip())
    return rc


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('deploy', help='copy a build (and the key daemon) to the rig')
    p.add_argument('--rbf', help='default: newest releases/*.rbf')
    p.add_argument('--main', metavar='PATH',
                   help='install a custom Main safely (never overwrites the running one)')
    p.add_argument('--agent', action='store_true', help='only (re)start the key daemon')
    p.add_argument('--rbf-only', action='store_true')
    p.set_defaults(fn=cmd_deploy)

    sub.add_parser('restore',
                   help='put the rig back to stock Main and remove harness files') \
       .set_defaults(fn=cmd_restore)

    p = sub.add_parser('launch', help='set options, mount an image, load the core')
    p.add_argument('image', help='absolute path ON THE MISTER')
    p.add_argument('--opt', action='append', metavar='"Name=Value"')
    p.add_argument('--delay', type=int, default=2)
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--no-wait', action='store_true')
    p.set_defaults(fn=cmd_launch)

    p = sub.add_parser('wait')
    p.add_argument('--timeout', type=int, default=60)
    p.set_defaults(fn=cmd_wait)

    p = sub.add_parser('key', help='press one or more transport keys')
    p.add_argument('names', nargs='+')
    p.set_defaults(fn=cmd_key)

    p = sub.add_parser('shot', help='screenshot and pull it back')
    p.add_argument('-o', '--out')
    p.add_argument('--decode', action='store_true')
    p.set_defaults(fn=cmd_shot)

    for name, fn in (('state', cmd_state), ('options', cmd_options)):
        sub.add_parser(name).set_defaults(fn=fn)

    p = sub.add_parser('telem', help="read the core's pacing counters")
    p.add_argument('--watch', type=float, help='sample for N seconds and report rates')
    p.add_argument('--csv')
    p.set_defaults(fn=cmd_telem)

    p = sub.add_parser('osd', help='set an OSD option live (no relaunch)')
    p.add_argument('setting', metavar='"Name=Value"')
    p.set_defaults(fn=cmd_osd)

    p = sub.add_parser('capture', help='record A/V from the capture card')
    p.add_argument('-t', '--seconds', type=float, default=45)
    p.add_argument('-o', '--out')
    p.add_argument('--warmup', type=float, default=2.0)
    p.add_argument('--video-size', default='720x480')
    p.add_argument('--fps', type=int, default=60)
    p.add_argument('--pixfmt', default='mjpeg')
    p.add_argument('--vdev')
    p.add_argument('--adev')
    p.set_defaults(fn=cmd_capture)

    p = sub.add_parser('log')
    p.add_argument('-n', type=int, default=20)
    p.set_defaults(fn=cmd_log)

    p = sub.add_parser('shell')
    p.add_argument('rest', nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_shell)

    args = ap.parse_args()
    return args.fn(args) or 0


if __name__ == '__main__':
    sys.exit(main())
