#!/usr/bin/env python3
"""test_set_dvd_region.py — drive main/Scripts/set_dvd_region.sh's menus and check them.

Run from the repository root:  ./tools/test_set_dvd_region.py

The script's one real action is an ioctl to a DVD drive, which cannot be tested
without one; what CAN be tested is everything guarding that ioctl, and that is where
the risk lives — a region change spends one of a drive's ~5 permanent changes, so a
menu that selects the wrong entry or treats a stray keypress as consent does real,
unrecoverable damage. So the drive is faked (DVD_REGION_FAKE, honoured by the script
itself) and the menus are driven through a pty with the exact key sequences MiSTer
sends for a gamepad: D-pad -> arrows, B1 -> Enter, B2 -> Esc.

Issue #52 added the second thing worth testing: what the script SAYS about a change
it cannot read back. The drive there took the region and the script called it an
error. The fake drive can now reproduce all three post-change behaviours — the
read-back raising (rbfail), the region_mask lagging (stale), and the change itself
failing (setfail) — and only the last of those may be reported as a failure.
"""
import os, pty, subprocess, select, time, sys, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
# SET_DVD_REGION_SH points the suite at another copy — used to prove the issue-52
# checks RED against the pre-fix script (git show <rev>:main/Scripts/...).
SCRIPT = os.environ.get("SET_DVD_REGION_SH",
                        os.path.join(HERE, os.pardir, "main", "Scripts", "set_dvd_region.sh"))

UP, DOWN, ENTER, ESC = b"\x1b[A", b"\x1b[B", b"\r", b"\x1b"
PROMPT = "Press B1 / Enter to close"

def drain(fd, wait=0.25):
    buf = b""
    end = time.time() + wait
    while time.time() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
    return buf

def poke(fd, key):
    """The script may already have exited; a write to a dead pty is not a failure."""
    try:
        os.write(fd, key)
    except OSError:
        pass

def run(keys, fake="0:5:4:1", args=(), expect_pause=True, dismiss=True):
    m, s = pty.openpty()
    env = dict(os.environ, DVD_REGION_FAKE=fake, TERM="linux",
               # Keep the transcript out of the developer's /tmp between runs.
               HOME=os.environ.get("HOME", "/tmp"))
    p = subprocess.Popen([SCRIPT, *args],
                         stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
    os.close(s)
    out = b""
    for k in keys:
        out += drain(m)
        poke(m, k)
    # Every interactive path now ends by waiting for a keypress, so the result
    # screen survives MiSTer closing the terminal on the confirming key's RELEASE.
    # Wait for that prompt before answering it: a key sent while the script is
    # still verifying would be eaten by the pause's own input drain.
    if expect_pause:
        end = time.time() + 8
        while PROMPT not in out.decode(errors="replace") and time.time() < end:
            if p.poll() is not None:
                break
            out += drain(m, 0.2)
        time.sleep(0.4)   # let the pause finish draining before we press a key
    if dismiss:
        poke(m, ENTER)
    out += drain(m, 0.6)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); out += b"<<TIMEOUT>>"
    os.close(m)
    return out.decode(errors="replace"), p.returncode

FAIL = 0

# --- unit checks on the payload's pure functions ------------------------------
# The script is a python payload inside a shell heredoc; extract it and import
# it (its entry point is under a __main__ guard) so the encoders and the SG_IO
# structure can be checked directly rather than only through the menus.
def load_payload():
    src = open(SCRIPT).read()
    body = src.split('cat > "$PY" <<\'PYEOF\'\n', 1)[1].split("\nPYEOF\n", 1)[0]
    path = os.path.join(os.getenv("TMPDIR", "/tmp"), "set_dvd_region_payload.py")
    open(path, "w").write(body)
    spec = importlib.util.spec_from_file_location("set_dvd_region_payload", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def unit(name, ok, detail=""):
    global FAIL
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        if detail:
            print("        " + detail)
        FAIL += 1

M = load_payload()

unit("pdrc is a mask with one bit clear",
     [M.region_pdrc(n) for n in range(1, 9)] == [0xfe, 0xfd, 0xfb, 0xf7,
                                                 0xef, 0xdf, 0xbf, 0x7f],
     repr([hex(M.region_pdrc(n)) for n in range(1, 9)]))

st = M.decode_state(b"\x91\xfd\x01")
unit("RPC state decodes as the kernel packs it",
     (st.region, st.changes, st.resets, st.scheme, st.rpc_type) == (2, 4, 4, 1, 1),
     repr(st))
unit("an all-ones mask is no region set", M.decode_state(b"\xb0\xff\x01").region is None)
unit("rpc_scheme 0 is carried through", M.decode_state(b"\xb0\xff\x00").scheme == 0)

# SG_IO on something that is not a SCSI device must raise a plain OSError, not a
# SenseError — that is what makes set_region() fall back to the ioctl rather than
# reporting a refusal the drive never made.
with open(os.devnull, "rb") as devnull:
    try:
        M.sg_send_key(devnull.fileno(), bytes(8))
        ok, why = False, "no error at all"
    except M.SenseError as e:
        ok, why = False, "raised SenseError (%s) - would suppress the fallback" % e
    except OSError as e:
        ok, why = True, str(e)
unit("SG_IO on a non-SCSI fd falls back rather than blaming the drive", ok, why)

def check(name, keys, must_have, must_not=(), fake="0:5:4:1", rc=0, expect_pause=True):
    global FAIL
    text, code = run(keys, fake, expect_pause=expect_pause)
    bad = [n for n in must_have if n not in text]
    bad += ["(unexpected) " + n for n in must_not if n in text]
    if code != rc:
        bad.append("exit=%s want %s" % (code, rc))
    print(("PASS  " if not bad else "FAIL  ") + name)
    for b in bad:
        print("        missing/wrong: " + b)
        FAIL += 1

# The cursor starts on Cancel, so a stray B1 must change nothing.
check("Enter on entry = cancel (safe default)", [ENTER],
      ["Cancelled. Nothing was changed."], ["Setting region"])
check("Esc/B2 backs out", [ESC],
      ["Cancelled. Nothing was changed."], ["Setting region"])
# Down from Cancel wraps to region 1; the confirm screen defaults to No.
check("confirm defaults to No", [DOWN, ENTER, ENTER],
      ["Set (simulated sr0) to region 1?", "Cancelled. Nothing was changed."],
      ["Setting region"])
check("Down+Enter on confirm applies", [DOWN, ENTER, DOWN, ENTER],
      ["Setting region 1 ...", "Done. The drive is now region 1, with 4 changes left."])
check("digit key jumps the cursor", [b"3", ENTER, DOWN, ENTER],
      ["Set (simulated sr0) to region 3?", "Done. The drive is now region 3"])
check("last-change warning shown", [DOWN, ENTER, ESC],
      ["This is the LAST change this drive allows."], fake="0:1:4:1")
check("locked drive offers only Exit", [ENTER],
      ["NO changes left", "Exit"], ["Pick the region"], fake="2:0:4:1")
check("picking the current region is a no-op", [b"2", ENTER],
      ["already set to region 2"], ["Setting region"], fake="2:4:4:1")
# 7 (unassigned) and 8 (aircraft/cruise) are not offered - no disc carries them,
# and choosing one would spend a permanent change for nothing.
check("menu offers regions 1-6 only", [ESC],
      ["6  China"], ["7  reserved", "international venues"])

# Only the first drive is ever touched, so a second one must be called out by
# name - "which drive am I about to change?" is unanswerable otherwise, and the
# change cannot be undone.
check("multi-drive warning names every drive", [ESC],
      ["2 optical drives are connected", "(simulated sr0)  NONE set   <- this one",
       "(simulated sr1)  1  (US, Canada)", "Connect only the drive you want"],
      fake="0:5:4:1,1:3:4:1")
check("single drive gets no warning", [ESC],
      ["Current region : NONE set"], ["optical drives are connected"])
check("confirm screen names the drive", [DOWN, ENTER, ESC],
      ["Set (simulated sr0) to region 1?"], fake="0:5:4:1,1:3:4:1")

# --- issue #52: what the script says about a change it cannot read back -------
# The drive took the region; only the verification failed. Reporting that as an
# error (or as a traceback) is the bug, so none of these may look like failure.
check("read-back that raises is not a failure", [DOWN, ENTER, DOWN, ENTER],
      ["the drive accepted it", "do not", "Run this script again"],
      ["Traceback", "FAILED", "did not take the change"],
      fake="0:5:4:1:rbfail", rc=3)
check("a lagging region_mask is not a failure", [DOWN, ENTER, DOWN, ENTER],
      ["the drive accepted it", "it still says NONE set"],
      ["Traceback", "FAILED", "did not take the change"],
      fake="0:5:4:1:stale", rc=3)
# The one thing that IS a failure: the change command itself refused.
check("a rejected change says so, and does not claim the counter",
      [DOWN, ENTER, DOWN, ENTER],
      ["The drive REJECTED the change", "The region was not changed"],
      ["Traceback", "Done."], fake="0:5:4:1:setfail", rc=1)

# The raw RPC bytes make a second-hand bug report diagnosable: a photo of this
# screen answers "what did the drive actually say?" without another round trip.
check("raw RPC state is on screen", [ESC],
      ["RPC state      : b0 ff 01   (RPC-2, region not set)"])
check("a set region reads back in both fields", [ESC],
      ["RPC state      : 91 fd 01   (RPC-2, region set)"], fake="2:4:4:1")
# An RPC-1 drive enforces no region at all - there is nothing to set, and the
# menu must not offer to spend a change on it.
check("RPC-1 drive is described as region-free", [],
      ["RPC-1: it enforces no region at all"], ["Pick the region"], fake="0:5:4:0")

# The byte on the wire. pdrc is a region MASK with one bit CLEAR, not the region
# number — a real drive answers the number with sense 05/26/00, "invalid field in
# parameter list". The fake drive decodes the mask strictly, so the scenarios above
# already fail if this regresses; this pins the actual value so the next reader can
# see what is meant to go out.
def check_pdrc(region, want_byte):
    global FAIL
    logs = ["/media/fat/DVD_reports/set_dvd_region.log", "/tmp/set_dvd_region.log"]
    logs = [f for f in logs if os.path.isdir(os.path.dirname(f))]
    for f in logs:
        if os.path.exists(f):
            os.truncate(f, 0)
    run([str(region).encode(), ENTER, DOWN, ENTER], fake="0:5:4:1")
    want = "send pdrc %02x for region %d" % (want_byte, region)
    seen = any(want in open(f).read() for f in logs if os.path.exists(f))
    print(("PASS  " if seen else "FAIL  ") + "region %d goes out as pdrc %02x"
          % (region, want_byte))
    if not seen:
        FAIL += 1

check_pdrc(1, 0xfe)
check_pdrc(4, 0xf7)

# --- issue #52: the result screen must outlive the press that caused it -------
# MiSTer closes the framebuffer terminal on the first key RELEASE after the
# script exits, so a script that returns immediately loses its last screen. The
# script must still be alive, holding the prompt, until a FRESH key arrives.
def check_pause_holds():
    global FAIL
    m, s = pty.openpty()
    env = dict(os.environ, DVD_REGION_FAKE="0:5:4:1", TERM="linux")
    p = subprocess.Popen([SCRIPT], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
    os.close(s)
    out = drain(m)
    poke(m, ESC)                      # cancel: the fastest possible exit path
    out += drain(m, 1.5)
    text = out.decode(errors="replace")
    bad = []
    if PROMPT not in text:
        bad.append("no pause prompt")
    if p.poll() is not None:
        bad.append("exited without waiting for a key")
    poke(m, ENTER)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); bad.append("did not exit after the key")
    os.close(m)
    print(("PASS  " if not bad else "FAIL  ") + "result screen waits for a keypress")
    for b in bad:
        print("        missing/wrong: " + b)
        FAIL += 1

check_pause_holds()

# Non-interactive callers (a pipe, or fb_terminal=0) must never block on a key:
# there is nothing to press. run() hands the script a pty, so this one goes direct.
p = subprocess.run([SCRIPT], env=dict(os.environ, DVD_REGION_FAKE="0:5:4:1"),
                   stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
piped = p.stdout.decode(errors="replace")
ok = p.returncode == 0 and PROMPT not in piped and "Run this from the MiSTer Scripts menu" in piped
print(("PASS  " if ok else "FAIL  ") + "piped run reports and exits without blocking")
if not ok:
    print("        rc=%s out=%r" % (p.returncode, piped))
    FAIL += 1

text, code = run([], args=("8",), expect_pause=False)
print(("PASS  " if code == 2 and "not consumer regions" in text else "FAIL  ")
      + "argument form refuses region 8")
if code != 2 or "not consumer regions" not in text:
    FAIL += 1

print("\n%s" % ("ALL PASS" if not FAIL else "%d FAILURES" % FAIL))
sys.exit(1 if FAIL else 0)
