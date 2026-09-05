#!/usr/bin/env python3
"""
mister_keyd.py -- key-injection daemon, runs ON the MiSTer.

Creates ONE uinput keyboard and feeds keystrokes to the core from a FIFO.
tools/mister.py deploys and drives it; see docs/hil_harness.md.

Why this works with no change to MiSTer's Main:

  * Main watches /dev/input with inotify and enumerates new devices
    (input.cpp:5164), skipping only its OWN, which is named exactly
    "MiSTer virtual input" (input.cpp:41, :5207).
  * Device classification is purely by event code -- any EV_KEY below 256 is
    treated as a keystroke (input.cpp:3601) and handed to user_io_kbd()
    (input.cpp:3894). No name, VID/PID or mapping file is required.
  * user_io_kbd() translates to a PS/2 set-2 scancode and sends it to the core,
    where dvd/kbd_map.sv turns it into a joystick bit. HDMI-CEC already uses
    this same non-HID route (hdmi_cec.cpp:331), so it is a supported path.

Two things this daemon exists to get right:

  * ONE device for its whole lifetime. Destroying a uinput device fires
    inotify IN_DELETE, which makes Main close and re-enumerate EVERY input
    device (input.cpp:5626). Creating one per keypress would do that per press.
  * A settle delay after UI_DEV_CREATE, before the first key, so Main's
    enumeration has actually picked the device up.

Keys are sent as make+break: dvd/kbd_map.sv pulses on the PRESS edge only and
Main drops auto-repeat (user_io.cpp:4059), so holding a key buys nothing. The
core's two LEVEL inputs (Fast Fwd / Rewind) are deliberately not reachable this
way -- emu.sv masks them out of the keyboard path and routes them to
dvd/dpad_seek.sv instead, because an IR remote's "hold" is really ~9 discrete
taps a second and each release would issue a real seek.

Protocol (one command per line, echoing 'ok'/'err' so the caller can tell):
    key <linux_keycode> [hold_ms]
    keys <code> <code> ...
    ping
    quit
"""

import fcntl
import os
import struct
import sys
import time

UI_DEV_CREATE = 0x5501
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0

FIFO = os.environ.get('MISTER_KEYD_FIFO', '/tmp/mister_hil')
LOG = os.environ.get('MISTER_KEYD_LOG', '/tmp/mister_keyd.log')
SETTLE = float(os.environ.get('MISTER_KEYD_SETTLE', '1.0'))
DEV_NAME = b'MiSTer HIL keyboard'      # must NOT be "MiSTer virtual input"

# Every Linux keycode dvd/kbd_map.sv can act on, plus F12 (Main's OSD toggle).
KEYCODES = sorted({
    1, 14, 15, 19, 20, 25, 28, 30, 31, 32, 33, 34, 45, 48, 49, 50,
    57, 59, 60, 61, 62, 88, 96, 103, 104, 105, 106, 108, 109,
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11,                    # digits: menu buttons
    71, 72, 73, 75, 76, 77, 79, 80, 81, 82,            # keypad digits
})


def log(msg):
    with open(LOG, 'a') as f:
        f.write(f'{time.strftime("%H:%M:%S")} {msg}\n')


def main():
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in KEYCODES:
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)

    # struct uinput_user_dev: char name[80]; struct input_id{4 x u16};
    # int ff_effects_max; int absmax/absmin/absfuzz/absflat[64]  -> 1116 bytes.
    # No EV_LED bits are set, so has_led() is false (input.cpp:5204) and Main
    # never writes LED state back at us.
    dev = (DEV_NAME.ljust(80, b'\0')
           + struct.pack('<HHHH', 0x03, 0xDEAD, 0xBEEF, 1)
           + struct.pack('<i', 0) + b'\0' * (4 * 64 * 4))
    assert len(dev) == 1116, len(dev)
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    log(f'device created ({len(KEYCODES)} keys), settling {SETTLE}s')
    time.sleep(SETTLE)

    def emit(t, c, v):
        os.write(fd, struct.pack('<llHHi', 0, 0, t, c, v))

    def press(code, hold_ms):
        emit(EV_KEY, code, 1)
        emit(EV_SYN, SYN_REPORT, 0)
        time.sleep(hold_ms / 1000.0)
        emit(EV_KEY, code, 0)
        emit(EV_SYN, SYN_REPORT, 0)

    if os.path.exists(FIFO):
        os.unlink(FIFO)
    os.mkfifo(FIFO, 0o666)
    log(f'listening on {FIFO}')

    while True:
        # Reopen per batch: a FIFO read returns EOF when the last writer closes,
        # which is exactly how one `echo >` is framed.
        with open(FIFO) as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                cmd, args = parts[0], parts[1:]
                try:
                    if cmd == 'key':
                        press(int(args[0]), float(args[1]) if len(args) > 1 else 50)
                        log(f'key {args[0]}')
                    elif cmd == 'keys':
                        for a in args:
                            press(int(a), 50)
                            time.sleep(0.12)
                        log(f'keys {" ".join(args)}')
                    elif cmd == 'ping':
                        log('ping')
                    elif cmd == 'quit':
                        log('quit')
                        return 0
                    else:
                        log(f'unknown command {cmd!r}')
                except Exception as exc:                      # keep serving
                    log(f'ERROR on {line.strip()!r}: {exc}')


if __name__ == '__main__':
    sys.exit(main())
