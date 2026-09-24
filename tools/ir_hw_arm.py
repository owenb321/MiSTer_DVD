#!/usr/bin/env python3
"""Inject a raw keycode and capture the HUD popup it produces, for the IR remap.

★ WHY IT SEQUENCES ON THE TARGET. A HUD popup lives ~2.5 s, and an ssh round
trip is 1-2 s, so `key` then `shot` as two calls is a race that loses the popup
about as often as it catches it -- the documented trap. The press and the
screenshot go down ONE ssh session with a target-side sleep between them.

★ THE POPUP IS THE INSTRUMENT, not the status line. A popup appears ONLY if the
button fired, so it cannot be confused with state left over from a previous
press -- whereas the status line's 2.5 s auto-show makes a Display toggle
unreadable right after any press (which is how the first attempt at this round
produced an ambiguous reading).

Usage:
    ir_hw_arm.py <code> [<code> ...] [--delay 0.6] [--label NAME]
"""

import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import importlib.util
_spec = importlib.util.spec_from_file_location("mister", os.path.join(HERE, "mister.py"))
M = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(M)


def arm(codes, delay, out):
    keys = " ".join(str(c) for c in codes)
    M.ssh(f'''
rm -f {M.SHOT_DIR}/irarm.png
echo 'keys {keys}' > /tmp/mister_hil
sleep {delay}
echo 'screenshot irarm.png' > /dev/MiSTer_cmd
for i in $(seq 1 24); do
  sleep 0.25
  if [ -f {M.SHOT_DIR}/irarm.png ]; then
    a=$(stat -c %s {M.SHOT_DIR}/irarm.png); sleep 0.2
    b=$(stat -c %s {M.SHOT_DIR}/irarm.png)
    [ "$a" = "$b" ] && [ "$a" != 0 ] && exit 0
  fi
done
echo NOSHOT; exit 1
''', check=False)
    M.scp(f'{M.SHOT_DIR}/irarm.png', out, to_target=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("codes", nargs="+", type=int)
    ap.add_argument("--delay", default="0.6")
    ap.add_argument("--label", default="")
    ap.add_argument("-o", "--out")
    args = ap.parse_args()

    out = args.out or os.path.join("/tmp", "irarm_%s.png" % time.strftime("%H%M%S"))
    arm(args.codes, args.delay, out)
    if args.label:
        print("== %s ==" % args.label)
    subprocess.run([sys.executable, os.path.join(HERE, "hud_read.py"), "read", out])
    return 0


if __name__ == "__main__":
    sys.exit(main())
