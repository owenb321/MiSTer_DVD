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
"""
import os, pty, subprocess, select, time, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, os.pardir, "main", "Scripts", "set_dvd_region.sh")

UP, DOWN, ENTER, ESC = b"\x1b[A", b"\x1b[B", b"\r", b"\x1b"

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

def run(keys, fake="0:5:4:1", args=()):
    m, s = pty.openpty()
    env = dict(os.environ, DVD_REGION_FAKE=fake, TERM="linux")
    p = subprocess.Popen([SCRIPT, *args],
                         stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
    os.close(s)
    out = b""
    for k in keys:
        out += drain(m)
        os.write(m, k)
    out += drain(m, 0.6)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); out += b"<<TIMEOUT>>"
    os.close(m)
    return out.decode(errors="replace"), p.returncode

FAIL = 0
def check(name, keys, must_have, must_not=(), fake="0:5:4:1", rc=0):
    global FAIL
    text, code = run(keys, fake)
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

text, code = run([], args=("8",))
print(("PASS  " if code == 2 and "not consumer regions" in text else "FAIL  ")
      + "argument form refuses region 8")
if code != 2 or "not consumer regions" not in text:
    FAIL += 1

print("\n%s" % ("ALL PASS" if not FAIL else "%d FAILURES" % FAIL))
sys.exit(1 if FAIL else 0)
