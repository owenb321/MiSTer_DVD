#!/bin/bash
# set_dvd_region.sh — show or set the region code of a USB DVD drive, on the MiSTer.
#
# WHY THIS EXISTS: a drive with no region set refuses the CSS key exchange, so
# libdvdcss has to crack every title key out of the disc data — that is the
# multi-second wait before a physical disc starts playing. Set the drive's region to
# match your discs and the drive hands the keys over directly instead.
#
# HOW TO USE IT: run "set_dvd_region" from the MiSTer Scripts menu. It shows the
# drive's current region and how many changes it has left; picking a new region is a
# menu, driven with the D-pad and B1 (or arrow keys and Enter). Nothing is changed
# until you confirm.
#
# !! A region change is close to permanent. Drives allow only a handful of user
# !! changes — typically five — and when the counter reaches zero the region is
# !! locked to whatever was set last. There is no "un-set": the region cannot be
# !! returned to none, only changed to another region at the cost of one change.
#
# Needs only what a stock MiSTer already has: python3. Run it with no disc playing —
# the DVD core holds the drive open while a disc is mounted.
#
# Over SSH you can skip the menu:
#   ./set_dvd_region.sh          show the current region and changes remaining
#   ./set_dvd_region.sh 2        set region 2, 1-6 (asks to confirm)
#   ./set_dvd_region.sh 2 --yes  set region 2 without asking

set -u

# The python payload goes to a FILE rather than python3's stdin: the MiSTer Scripts
# menu runs this script on a real console (agetty on tty2), and stdin is the console
# the menu is read from. A `python3 - <<EOF` heredoc would consume it and the menu
# could not be driven at all.
PY="/tmp/set_dvd_region.$$.py"
trap 'rm -f "$PY"' EXIT

cat > "$PY" <<'PYEOF'
"""Read or set a DVD drive's RPC region, with a gamepad-driveable menu.

The region lives in the drive's own firmware and is read/written with one ioctl,
DVD_AUTH (linux/cdrom.h), which the kernel turns into the SCSI REPORT KEY /
SEND KEY commands for RPC state. No external tool and no compiled helper needed.

Gamepad support is not our doing: while a Scripts-menu script runs, MiSTer's Main
injects real keyboard events from the gamepad (D-pad -> arrows, B1 -> Enter,
B2 -> Esc, B3 -> Space, B4 -> Tab). There are no digits or letters in that mapping,
which is why every choice here is a cursor menu and never a typed value.
"""

import fcntl
import glob
import os
import select
import sys
import termios
import tty

DVD_AUTH            = 0x5392   # linux/cdrom.h: DVD authentication ioctl
LU_SEND_RPC_STATE   = 10       # drive -> host: report the current RPC state
HOST_SEND_RPC_STATE = 11       # host -> drive: set the region
AUTHINFO_SIZE       = 16       # sizeof(dvd_authinfo)

REGIONS = [
    (1, "US, Canada"),
    (2, "Europe, Japan, Middle East, South Africa"),
    (3, "Southeast Asia, South Korea, Taiwan, Hong Kong"),
    (4, "Latin America, Australia, New Zealand"),
    (5, "Africa, Russia, South Asia"),
    (6, "China"),
    (7, "reserved"),
    (8, "international venues (aircraft, cruise ships)"),
]

# Regions 7 and 8 are named above so a drive reporting one is still described
# correctly, but they are never OFFERED: 7 is unassigned and 8 is for aircraft and
# cruise ships, so no disc a user owns carries either. Spending one of a drive's
# handful of permanent changes on one would be a mistake with no way back.
CHOOSABLE = [entry for entry in REGIONS if entry[0] <= 6]


# ---------------------------------------------------------------- drive access

class Drive:
    def __init__(self, path, fd):
        self.path = path
        self.fd = fd

    def read_state(self):
        """-> (region or None, changes_left, vendor_resets, rpc_scheme).

        struct dvd_lu_send_rpcstate is {type:2, vra:3, ucca:3, region_mask,
        rpc_scheme} — three bytes, the bitfields packed from the low end.
        region_mask has a CLEAR bit per PLAYABLE region, so 0xff means no region
        is set and exactly one clear bit means that region is the drive's.
        """
        buf = bytearray(AUTHINFO_SIZE)
        buf[0] = LU_SEND_RPC_STATE
        fcntl.ioctl(self.fd, DVD_AUTH, buf, True)
        vendor_resets = (buf[0] >> 2) & 7
        changes_left  = (buf[0] >> 5) & 7
        mask, scheme  = buf[1], buf[2]
        playable = [n + 1 for n in range(8) if not (mask >> n) & 1]
        region = playable[0] if len(playable) == 1 else None
        return region, changes_left, vendor_resets, scheme

    def set_region(self, region):
        """struct dvd_host_send_rpcstate is {type, pdrc}; pdrc is the region 1-8."""
        buf = bytearray(AUTHINFO_SIZE)
        buf[0] = HOST_SEND_RPC_STATE
        buf[1] = region
        fcntl.ioctl(self.fd, DVD_AUTH, buf, True)


class FakeDrive:
    """Test stand-in so the menus can be exercised without an optical drive.

    Enable with DVD_REGION_FAKE=<region>:<changes>:<resets>:<scheme>, region 0
    meaning none set, e.g. DVD_REGION_FAKE=0:5:4:1. Touches no hardware.
    """
    def __init__(self, spec):
        parts = (spec.split(":") + ["0", "5", "4", "1"])[:4]
        region, changes, resets, scheme = (int(p) for p in parts)
        self.path = "(simulated drive)"
        self.state = [region or None, changes, resets, scheme]

    def read_state(self):
        return tuple(self.state)

    def set_region(self, region):
        if self.state[1] <= 0:
            raise OSError(5, "Input/output error")
        self.state[0] = region
        self.state[1] -= 1


def find_drives():
    fake = os.environ.get("DVD_REGION_FAKE")
    if fake:
        return [FakeDrive(fake)]
    drives = []
    for path in sorted(glob.glob("/dev/sr[0-9]*")):
        try:
            # Read-only + non-blocking: opens whether or not media is loaded, and
            # cannot disturb a disc.
            drives.append(Drive(path, os.open(path, os.O_RDONLY | os.O_NONBLOCK)))
        except OSError:
            continue
    return drives


# ------------------------------------------------------------------ console UI

def out(text=""):
    # Raw mode turns off the newline translation, so line ends must be explicit.
    sys.stdout.write(text + "\r\n")
    sys.stdout.flush()


def clear():
    sys.stdout.write("\x1b[2J\x1b[H")
    sys.stdout.flush()


def read_key(fd):
    """One keypress -> 'up'/'down'/'enter'/'esc'/'1'..'8'/'' (anything else)."""
    ch = os.read(fd, 1)
    if ch == b"\x1b":
        # Could be a bare Esc (B2 on the gamepad) or the start of an arrow's CSI
        # sequence. Only a timeout tells them apart.
        if not select.select([fd], [], [], 0.05)[0]:
            return "esc"
        seq = os.read(fd, 2)
        return {b"[A": "up", b"[B": "down", b"[C": "right", b"[D": "left"}.get(seq, "")
    if ch in (b"\r", b"\n"):
        return "enter"
    if ch in (b"q", b"Q"):
        return "esc"
    if ch.isdigit():
        return ch.decode()
    return ""


def menu(header, items, footer, selected=0):
    """Cursor menu. Returns the chosen index, or None if cancelled."""
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while True:
            clear()
            for row in header:
                out(row)
            out()
            for n, item in enumerate(items):
                out(("  > " if n == selected else "    ") + item)
            out()
            for row in footer:
                out(row)
            key = read_key(fd)
            if key == "up":
                selected = (selected - 1) % len(items)
            elif key == "down":
                selected = (selected + 1) % len(items)
            elif key == "enter":
                return selected
            elif key == "esc":
                return None
            elif key.isdigit() and 1 <= int(key) <= len(items):
                selected = int(key) - 1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def describe(region):
    if region is None:
        return "NONE set"
    for num, name in REGIONS:
        if num == region:
            return "%d  (%s)" % (num, name)
    return str(region)


def status_lines(drive, region, changes, resets, rpc1=False):
    lines = ["  DVD drive region                    %s" % drive.path, ""]
    lines.append("  Current region : %s" % describe(region))
    if region is None and not rpc1:
        lines.append("                   CSS keys must be cracked - slow first play")
    lines.append("  Changes left   : %d       (vendor resets: %d)" % (changes, resets))
    return lines


# --------------------------------------------------------------------- actions

def apply_region(drive, want):
    out()
    out("  Setting region %d ..." % want)
    try:
        drive.set_region(want)
    except OSError as err:
        out("  FAILED: %s" % err)
        out("  The drive rejected the change; nothing was altered.")
        return 1
    region, changes, _resets, _scheme = drive.read_state()
    if region == want:
        out("  Done. The drive is now region %d, with %d changes left."
            % (region, changes))
        return 0
    out("  The drive did not take the change (it now reports %s)." % describe(region))
    return 1


def interactive(drive, region, changes, resets):
    header = status_lines(drive, region, changes, resets)
    if changes == 0:
        header += ["", "  This drive has NO changes left - its region is locked",
                   "  permanently and cannot be altered."]
        menu(header, ["Exit"], ["  B1 / Enter = exit"])
        return 0

    header += ["", "  Pick the region your discs come from:"]
    items = ["%d  %s" % (num, name) for num, name in CHOOSABLE] + ["Cancel - change nothing"]
    footer = ["  D-pad = move    B1 = select    B2 = cancel",
              "",
              "  A change costs one of the drive's %d remaining changes" % changes,
              "  and cannot be undone."]
    # Default the cursor to Cancel so an accidental B1 changes nothing.
    choice = menu(header, items, footer, selected=len(items) - 1)
    if choice is None or choice == len(items) - 1:
        clear()
        out("  Cancelled. Nothing was changed.")
        return 0

    want = CHOOSABLE[choice][0]
    if want == region:
        clear()
        out("  The drive is already set to region %d. Nothing was changed." % want)
        return 0

    confirm_header = ["  Set this drive to region %d?" % want, ""]
    confirm_header.append("  %s" % describe(want))
    confirm_header += ["",
                       "  This uses one of the %d changes the drive has left" % changes,
                       "  and CANNOT be undone."]
    if changes == 1:
        confirm_header += ["",
                           "  *** This is the LAST change this drive allows.",
                           "  *** It will be locked to region %d forever." % want]
    verdict = menu(confirm_header,
                   ["No  - leave the drive alone", "Yes - set region %d" % want],
                   ["  D-pad = move    B1 = select    B2 = cancel"],
                   selected=0)
    clear()
    if verdict != 1:
        out("  Cancelled. Nothing was changed.")
        return 0
    for row in status_lines(drive, region, changes, resets):
        out(row)
    return apply_region(drive, want)


def main():
    argv = sys.argv[1:]
    assume_yes = "--yes" in argv
    args = [a for a in argv if a != "--yes"]
    want = None
    if args:
        if args[0] in ("7", "8"):
            out("  Regions 7 and 8 are not consumer regions (7 is unassigned, 8 is")
            out("  aircraft and cruise ships), so this tool does not set them.")
            return 2
        if not args[0].isdigit() or not 1 <= int(args[0]) <= 6:
            out("usage: set_dvd_region.sh [1-6] [--yes]")
            return 2
        want = int(args[0])

    drives = find_drives()
    if not drives:
        out("  No optical drive found at /dev/sr0.")
        out("  Check that the drive is plugged in and has power (some USB drives")
        out("  need a powered hub or a second USB lead).")
        return 1
    drive = drives[0]

    try:
        region, changes, resets, scheme = drive.read_state()
    except OSError as err:
        out("  Could not read the drive's region state: %s" % err)
        out("  The drive may not report RPC state, or the disc may be in use -")
        out("  stop playback and try again.")
        return 1

    if scheme == 0:
        for row in status_lines(drive, region, changes, resets, rpc1=True):
            out(row)
        out()
        out("  This drive is RPC-1 (region-free): it ignores disc regions and")
        out("  needs no region set. Nothing to do.")
        return 0

    if want is None:
        # No controllable console (fb_terminal=0 runs scripts through the OSD with
        # no stdin at all, and a pipe has none either): report and stop rather than
        # block on input nobody can give.
        if not sys.stdin.isatty():
            for row in status_lines(drive, region, changes, resets):
                out(row)
            out()
            out("  Run this from the MiSTer Scripts menu (with fb_terminal=1) to")
            out("  change the region, or pass the region number as an argument.")
            return 0
        return interactive(drive, region, changes, resets)

    # Argument form (SSH): same safety rules, minus the cursor menu.
    for row in status_lines(drive, region, changes, resets):
        out(row)
    if want == region:
        out()
        out("  Already region %d. Nothing was changed." % want)
        return 0
    if changes == 0:
        out()
        out("  No changes left - the region is locked permanently.")
        return 1
    if not assume_yes:
        if not sys.stdin.isatty():
            out()
            out("  Nothing to confirm with: this is not a terminal. Re-run with")
            out("  --yes if you are sure, or use the MiSTer Scripts menu.")
            return 1
        verdict = menu(["  Set this drive to region %d?" % want,
                        "",
                        "  Uses one of %d remaining changes; cannot be undone." % changes],
                       ["No  - leave the drive alone", "Yes - set region %d" % want],
                       ["  arrows = move    Enter = select    Esc = cancel"],
                       selected=0)
        clear()
        if verdict != 1:
            out("  Cancelled. Nothing was changed.")
            return 0
    return apply_region(drive, want)


sys.exit(main())
PYEOF

python3 "$PY" "$@"
