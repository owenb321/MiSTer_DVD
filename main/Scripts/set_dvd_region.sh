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
# until you confirm, and every screen waits for a keypress before it closes.
#
# !! A region change is close to permanent. Drives allow only a handful of user
# !! changes — typically five — and when the counter reaches zero the region is
# !! locked to whatever was set last. There is no "un-set": the region cannot be
# !! returned to none, only changed to another region at the cost of one change.
#
# Needs only what a stock MiSTer already has: python3. Run it with no disc playing —
# the DVD core holds the drive open while a disc is mounted. If several drives are
# connected it only ever touches the first, and says so; connect just the one you
# mean to change.
#
# Everything printed is also appended to a log (/media/fat/DVD_reports if that
# exists, else /tmp), so a result that scrolls past can still be read afterwards.
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

Two rules this tool exists to obey, both learned from issue #52 (a region change
that WORKED and reported itself as an error):

  * A failure to read the region back is NOT a failure to set it. The SEND KEY
    either succeeded or it didn't; everything after it is reporting.
  * Nothing may exit without waiting for a keypress. MiSTer's framebuffer script
    runner ignores keys while the script runs, then closes the terminal on the
    first key RELEASE once it exits — so the press that confirms the last menu
    wipes the result screen of any script that finishes quickly.
"""

import fcntl
import glob
import os
import select
import sys
import termios
import time
import traceback
import tty
from collections import namedtuple

DVD_AUTH            = 0x5392   # linux/cdrom.h: DVD authentication ioctl
LU_SEND_RPC_STATE   = 10       # drive -> host: report the current RPC state
HOST_SEND_RPC_STATE = 11       # host -> drive: set the region
AUTHINFO_SIZE       = 16       # sizeof(dvd_authinfo) — 16 on x86-64 AND armv7 EABI

SG_IO           = 0x2285       # scsi/sg.h: send one SCSI command
SG_DXFER_TO_DEV = -2
SEND_KEY        = 0xa3         # MMC: SEND KEY
KF_RPC_STATE    = 6            # ... key format 6 = Send RPC State

# Sense codes worth naming. Everything else is printed as its raw triple, which is
# what a bug report needs anyway.
SENSE_TEXT = {
    (5, 0x26, 0x00): "invalid field in parameter list",
    (5, 0x24, 0x00): "invalid field in CDB",
    (5, 0x20, 0x00): "the drive does not support this command",
    (5, 0x6f, 0x05): "the drive's region-change counter is exhausted",
    (2, 0x3a, 0x00): "no disc in the drive",
    (2, 0x04, 0x01): "the drive is still becoming ready - try again in a moment",
}

VERIFY_TRIES = 6               # read-backs after a change ...
VERIFY_WAIT  = 0.5             # ... spaced this far apart

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

# The transcript. First writable location wins; /tmp always is, so there is always
# somewhere to point a bug report at.
LOG_PATHS = ("/media/fat/DVD_reports/set_dvd_region.log", "/tmp/set_dvd_region.log")


# --------------------------------------------------------------------- the log

log_file = None
log_path = None


def log_open():
    """Best effort: no logging is a nuisance, a crash trying to log is a bug."""
    global log_file, log_path
    for path in LOG_PATHS:
        folder = os.path.dirname(path)
        if not os.path.isdir(folder):
            # Create it only where it belongs — under an existing /media/fat.
            if not os.path.isdir(os.path.dirname(folder)):
                continue
            try:
                os.mkdir(folder)
            except OSError:
                continue
        try:
            log_file = open(path, "a")
            log_path = path
            return
        except OSError:
            continue


def note(text):
    """Log without printing — diagnostics nobody needs on a television."""
    if log_file is None:
        return
    try:
        log_file.write(text.rstrip("\n") + "\n")
        log_file.flush()
    except OSError:
        pass


# ---------------------------------------------------------------- drive access

State = namedtuple("State", "region changes resets scheme rpc_type raw")


def decode_state(raw):
    """Three bytes of struct dvd_lu_send_rpcstate -> State.

    {type:2, vra:3, ucca:3, region_mask, rpc_scheme}, the bitfields packed from
    the low end. Two independent answers to "is a region set?" come back and both
    are kept, because a drive that has just been changed can update one before the
    other: `type` is the drive's own verdict (0 = none set, 1 = set), while
    region_mask has a CLEAR bit per PLAYABLE region, so 0xff means none is set and
    exactly one clear bit names the drive's region. rpc_scheme 0 is an RPC-1 drive,
    which enforces no region at all.
    """
    rpc_type      = raw[0] & 3
    vendor_resets = (raw[0] >> 2) & 7
    changes_left  = (raw[0] >> 5) & 7
    mask, scheme  = raw[1], raw[2]
    playable = [n + 1 for n in range(8) if not (mask >> n) & 1]
    region = playable[0] if len(playable) == 1 else None
    return State(region, changes_left, vendor_resets, scheme, rpc_type, raw)


def raw_hex(state):
    return " ".join("%02x" % b for b in state.raw)


def region_pdrc(region):
    """Region 1-8 -> the Preferred Drive Region Code byte SEND KEY wants.

    ⚠ pdrc is a MASK with one bit CLEAR — the same polarity as the region_mask
    REPORT KEY returns — and NOT the region number. Region 1 is 0xfe, region 2
    is 0xfd. Sending the plain number is what a drive answers with sense
    05/26/00, "invalid field in parameter list": as a mask, 0x01 claims seven
    playable regions. Measured on a real drive via sg_raw, and it is what
    regionset has always sent (regionset.c `~(1 << (n-1))` -> dvd_udf.c
    UDFRPCSet -> `ai.hrpcs.pdrc`).
    """
    return ~(1 << (region - 1)) & 0xff


class SenseError(OSError):
    """A drive refusal we can actually explain, unlike the ioctl's bare EIO."""
    def __init__(self, key, asc, ascq):
        self.key, self.asc, self.ascq = key, asc, ascq
        text = SENSE_TEXT.get((key, asc, ascq))
        OSError.__init__(self, "sense %02x/%02x/%02x%s"
                         % (key, asc, ascq, " (%s)" % text if text else ""))


def sg_send_key(fd, payload, key_format=KF_RPC_STATE, timeout_ms=15000):
    """SEND KEY over SG_IO, the way sg_raw does it.

    WHY THIS EXISTS: the `DVD_AUTH` ioctl builds the identical command, but the
    kernel funnels every drive refusal through `sr_do_ioctl`, which collapses
    Illegal Request and most Not Ready conditions alike into a bare **EIO** — no
    use at all when the operation is one-way and the user needs to know WHY. Here
    the sense data comes straight back. (A drive that answered this route while
    refusing the ioctl is what sent us looking; either way this is the route that
    can explain itself.)

    Returns None on success, raises SenseError on a refusal the drive explained,
    and lets OSError through if SG_IO is unusable — the caller falls back then.
    """
    import ctypes

    class sg_io_hdr(ctypes.Structure):
        # ctypes lays this out for whatever ABI it is running on, which is the
        # point: 64 bytes on the MiSTer's armv7, 88 on an x86-64 desktop.
        _fields_ = [("interface_id", ctypes.c_int), ("dxfer_direction", ctypes.c_int),
                    ("cmd_len", ctypes.c_ubyte), ("mx_sb_len", ctypes.c_ubyte),
                    ("iovec_count", ctypes.c_ushort), ("dxfer_len", ctypes.c_uint),
                    ("dxferp", ctypes.c_void_p), ("cmdp", ctypes.c_void_p),
                    ("sbp", ctypes.c_void_p), ("timeout", ctypes.c_uint),
                    ("flags", ctypes.c_uint), ("pack_id", ctypes.c_int),
                    ("usr_ptr", ctypes.c_void_p), ("status", ctypes.c_ubyte),
                    ("masked_status", ctypes.c_ubyte), ("msg_status", ctypes.c_ubyte),
                    ("sb_len_wr", ctypes.c_ubyte), ("host_status", ctypes.c_ushort),
                    ("driver_status", ctypes.c_ushort), ("resid", ctypes.c_int),
                    ("duration", ctypes.c_uint), ("info", ctypes.c_uint)]

    n = len(payload)
    cdb = bytes((SEND_KEY, 0, 0, 0, 0, 0, 0, 0, (n >> 8) & 0xff, n & 0xff, key_format, 0))
    cdb_buf = ctypes.create_string_buffer(cdb, len(cdb))
    data    = ctypes.create_string_buffer(bytes(payload), n)
    sense   = ctypes.create_string_buffer(32)

    hdr = sg_io_hdr()
    ctypes.memset(ctypes.byref(hdr), 0, ctypes.sizeof(hdr))
    hdr.interface_id = ord("S")
    hdr.dxfer_direction = SG_DXFER_TO_DEV
    hdr.cmd_len = len(cdb)
    hdr.mx_sb_len = ctypes.sizeof(sense)
    hdr.dxfer_len = n
    hdr.dxferp = ctypes.cast(data, ctypes.c_void_p)
    hdr.cmdp = ctypes.cast(cdb_buf, ctypes.c_void_p)
    hdr.sbp = ctypes.cast(sense, ctypes.c_void_p)
    hdr.timeout = timeout_ms

    note("  SG_IO cdb %s payload %s"
         % (" ".join("%02x" % b for b in cdb), " ".join("%02x" % b for b in payload)))
    fcntl.ioctl(fd, SG_IO, hdr)   # OSError here = SG_IO unusable, not a refusal
    note("  SG_IO status %02x host %02x driver %02x sb_len %d"
         % (hdr.status, hdr.host_status, hdr.driver_status, hdr.sb_len_wr))

    if hdr.host_status or hdr.driver_status & 0x0f:
        raise OSError(5, "SG_IO transport error (host %02x driver %02x)"
                      % (hdr.host_status, hdr.driver_status))
    if hdr.status == 0:
        return None

    sb = sense.raw[:hdr.sb_len_wr or 18]
    note("  SG_IO sense %s" % " ".join("%02x" % b for b in sb))
    if len(sb) >= 14 and (sb[0] & 0x7e) == 0x70:        # fixed format
        raise SenseError(sb[2] & 0x0f, sb[12], sb[13])
    if len(sb) >= 4 and (sb[0] & 0x7e) == 0x72:         # descriptor format
        raise SenseError(sb[1] & 0x0f, sb[2], sb[3])
    raise OSError(5, "the drive refused it (SCSI status %02x)" % hdr.status)


class Drive:
    def __init__(self, path, fd):
        self.path = path
        self.fd = fd

    def reopen(self):
        """Fresh handle, used before reading back a change.

        A drive answers the command after SEND KEY with a unit attention — its RPC
        state just changed — and re-opening is the cheapest way to start clean.
        """
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK)

    def read_state(self):
        buf = bytearray(AUTHINFO_SIZE)
        buf[0] = LU_SEND_RPC_STATE
        fcntl.ioctl(self.fd, DVD_AUTH, buf, True)
        return decode_state(bytes(buf[:3]))

    def set_region(self, region):
        """Set the region, over SG_IO if we can and DVD_AUTH if we cannot.

        Both routes carry the SAME bytes — the kernel builds this exact command
        from the ioctl (cdrom.c: setup_send_key, then buf[1] = 6, buf[4] = pdrc).
        SG_IO is preferred only because it hands back the drive's sense data
        instead of the ioctl's bare EIO. The ioctl remains the fallback for a
        python without ctypes or a device that refuses SG_IO, so this can only
        add outcomes, never remove the one that worked before.
        """
        pdrc = region_pdrc(region)
        payload = bytes((0, 6, 0, 0, pdrc, 0, 0, 0))
        note("  send pdrc %02x for region %d" % (pdrc, region))
        try:
            sg_send_key(self.fd, payload)
            note("  route: SG_IO, accepted")
            return
        except SenseError:
            note("  route: SG_IO, refused with sense")
            raise                    # the drive explained itself; do not re-send
        except (OSError, ImportError, AttributeError) as err:
            note("  SG_IO unusable (%s) - falling back to DVD_AUTH" % err)

        buf = bytearray(AUTHINFO_SIZE)
        buf[0] = HOST_SEND_RPC_STATE
        buf[1] = pdrc
        fcntl.ioctl(self.fd, DVD_AUTH, buf, True)
        note("  route: DVD_AUTH, accepted")


class FakeDrive:
    """Test stand-in so the menus can be exercised without an optical drive.

    Enable with DVD_REGION_FAKE=<region>:<changes>:<resets>:<scheme>[:<fault>],
    region 0 meaning none set, e.g. DVD_REGION_FAKE=0:5:4:1. Several drives can be
    simulated by separating them with commas. Touches no hardware.

    <fault> reproduces what a real drive does around a change, which is where the
    reporting has to be right: "rbfail" makes every read AFTER a change raise (the
    unit attention), "stale" makes the drive keep reporting the old region for a
    while, "setfail" makes the change itself fail.
    """
    def __init__(self, spec, index=0):
        parts = spec.split(":")
        self.fault = parts[4] if len(parts) > 4 else ""
        region, changes, resets, scheme = (int(p) for p in (parts + ["0", "5", "4", "1"])[:4])
        self.path = "(simulated sr%d)" % index
        self.region, self.changes, self.resets, self.scheme = region, changes, resets, scheme
        self.changed = False

    def encode(self):
        mask = 0xff
        if self.region:
            mask &= ~(1 << (self.region - 1)) & 0xff
        head = (1 if self.region else 0) | (self.resets << 2) | (self.changes << 5)
        return bytes((head, mask, self.scheme))

    def reopen(self):
        pass

    def read_state(self):
        if self.fault == "rbfail" and self.changed:
            raise OSError(5, "Input/output error")
        return decode_state(self.encode())

    def set_region(self, region):
        # Encode exactly what the ioctl would carry and decode it back, so a
        # wrong pdrc fails here the way a real drive fails: strictly.
        pdrc = region_pdrc(region)
        note("  send pdrc %02x for region %d" % (pdrc, region))
        clear = [n + 1 for n in range(8) if not (pdrc >> n) & 1]
        if clear != [region]:
            raise OSError(22, "Invalid argument")   # sense 05/26/00 on real iron
        if self.fault == "setfail" or self.changes <= 0:
            raise OSError(5, "Input/output error")
        self.changes -= 1
        self.changed = True
        if self.fault != "stale":
            self.region = region


def find_drives():
    fake = os.environ.get("DVD_REGION_FAKE")
    if fake:
        return [FakeDrive(spec, n) for n, spec in enumerate(fake.split(","))]
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

def draw(text=""):
    """Screen only. Menu redraws must not fill the log with themselves."""
    # Raw mode turns off the newline translation, so line ends must be explicit.
    sys.stdout.write(text + "\r\n")
    sys.stdout.flush()


def out(text=""):
    draw(text)
    note(text)


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


def pause():
    """Hold the screen until a key is pressed. Every interactive exit goes here.

    MiSTer's framebuffer script runner (menu.cpp, MENU_SCRIPTS_FB2) ignores key
    events while the script's process lives, then tears the terminal down on the
    first key RELEASE after it is reaped. A script that finishes inside the
    duration of the press that confirmed it therefore has its last screen erased
    by that very press — which is how a successful region change came back as
    "an error that vanished before I could read it". Staying alive until a FRESH
    press spends that release on us instead.
    """
    if not sys.stdin.isatty():
        return
    out()
    out("  Press B1 / Enter to close%s"
        % ("      (log: %s)" % log_path if log_path else ""))
    fd = sys.stdin.fileno()
    try:
        saved = termios.tcgetattr(fd)
    except termios.error:
        return
    try:
        tty.setcbreak(fd)
        # Drain what the confirming press left behind — auto-repeat included —
        # before waiting, or the pause dismisses itself. Bounded, so a key stuck
        # down cannot hold the drain open forever.
        deadline = time.time() + 2.0
        while time.time() < deadline and select.select([fd], [], [], 0.25)[0]:
            os.read(fd, 256)
        os.read(fd, 1)
    except OSError:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def menu(header, items, footer, selected=0):
    """Cursor menu. Returns the chosen index, or None if cancelled."""
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while True:
            clear()
            for row in header:
                draw(row)
            draw()
            for n, item in enumerate(items):
                draw(("  > " if n == selected else "    ") + item)
            draw()
            for row in footer:
                draw(row)
            key = read_key(fd)
            if key == "up":
                selected = (selected - 1) % len(items)
            elif key == "down":
                selected = (selected + 1) % len(items)
            elif key == "enter":
                note("[menu] %s -> %s" % (header[0].strip(), items[selected]))
                return selected
            elif key == "esc":
                note("[menu] %s -> cancelled" % header[0].strip())
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


def describe_rpc(state):
    if state.scheme == 0:
        return "RPC-1, region-free"
    return "RPC-2, region %s" % ("set" if state.rpc_type else "not set")


def sibling_lines(drives):
    """Warning + inventory when more than one optical drive is connected.

    Only the first drive is ever touched. Reading the others is harmless (the RPC
    state ioctl changes nothing), and naming them with their regions is what makes
    the warning actionable: you can tell which drive is which without unplugging
    anything, and see that the one about to change is the one you meant.
    """
    if len(drives) < 2:
        return []
    lines = ["",
             "  !! %d optical drives are connected. This tool only looks at" % len(drives),
             "  !! %s, the first one:" % drives[0].path]
    for drive in drives:
        try:
            state = drive.read_state()
            what = "region-free (RPC-1)" if state.scheme == 0 else describe(state.region)
        except OSError:
            what = "(could not be read)"
        lines.append("       %-16s %s%s"
                     % (drive.path, what, "   <- this one" if drive is drives[0] else ""))
    lines.append("  !! Connect only the drive you want to change, to be certain.")
    return lines


def status_lines(drive, state):
    lines = ["  DVD drive region                    %s" % drive.path, ""]
    lines.append("  Current region : %s" % describe(state.region))
    if state.region is None and state.scheme != 0:
        lines.append("                   CSS keys must be cracked - slow first play")
    lines.append("  Changes left   : %d       (vendor resets: %d)" % (state.changes, state.resets))
    lines.append("  RPC state      : %s   (%s)" % (raw_hex(state), describe_rpc(state)))
    return lines


# --------------------------------------------------------------------- actions

def apply_region(drive, want):
    out()
    out("  Setting region %d ..." % want)
    try:
        drive.set_region(want)
    except OSError as err:
        out("  The drive REJECTED the change: %s" % err)
        out("  The region was not changed. Run this script again to check")
        out("  whether the change counter moved.")
        return 1

    # The command succeeded, so the region IS set. Everything from here is only an
    # attempt to READ IT BACK, and a drive that will not answer yet — or answers
    # with a mask it has not refreshed — has still taken the change. Reporting that
    # as a failure is what issue #52 was.
    state, err = None, None
    for attempt in range(VERIFY_TRIES):
        if attempt:
            time.sleep(VERIFY_WAIT)
        try:
            drive.reopen()
            state = drive.read_state()
        except OSError as exc:
            err, state = exc, None
            continue
        note("  verify %d: %s" % (attempt, raw_hex(state)))
        if state.region == want:
            break

    if state is not None and state.region == want:
        out("  Done. The drive is now region %d, with %d changes left."
            % (want, state.changes))
        return 0

    out("  The change was sent and the drive accepted it, but it has not")
    if state is None:
        out("  reported the new region back yet (%s)." % err)
    else:
        out("  reported the new region back yet - it still says %s." % describe(state.region))
    out("  This is normal on some drives. The change was sent ONCE; do not")
    out("  repeat it. Run this script again to see the region it settles on.")
    return 3


def interactive(drive, state, extra=()):
    header = status_lines(drive, state) + list(extra)
    if state.changes == 0:
        header += ["", "  This drive has NO changes left - its region is locked",
                   "  permanently and cannot be altered."]
        menu(header, ["Exit"], ["  B1 / Enter = exit"])
        clear()
        for row in status_lines(drive, state):
            out(row)
        out()
        out("  No changes left - the region is locked permanently.")
        pause()
        return 0

    header += ["", "  Pick the region your discs come from:"]
    items = ["%d  %s" % (num, name) for num, name in CHOOSABLE] + ["Cancel - change nothing"]
    footer = ["  D-pad = move    B1 = select    B2 = cancel",
              "",
              "  A change costs one of the drive's %d remaining changes" % state.changes,
              "  and cannot be undone."]
    # Default the cursor to Cancel so an accidental B1 changes nothing.
    choice = menu(header, items, footer, selected=len(items) - 1)
    if choice is None or choice == len(items) - 1:
        clear()
        out("  Cancelled. Nothing was changed.")
        pause()
        return 0

    want = CHOOSABLE[choice][0]
    if want == state.region:
        clear()
        out("  The drive is already set to region %d. Nothing was changed." % want)
        pause()
        return 0

    confirm_header = ["  Set %s to region %d?" % (drive.path, want), ""]
    confirm_header.append("  %s" % describe(want))
    confirm_header += ["",
                       "  This uses one of the %d changes the drive has left" % state.changes,
                       "  and CANNOT be undone."]
    if state.changes == 1:
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
        pause()
        return 0
    for row in status_lines(drive, state):
        out(row)
    rc = apply_region(drive, want)
    pause()
    return rc


def main():
    argv = sys.argv[1:]
    note("--- %s  argv=%s" % (time.strftime("%Y-%m-%d %H:%M:%S"), " ".join(argv)))
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
        pause()
        return 1
    drive = drives[0]

    try:
        state = drive.read_state()
    except OSError as err:
        out("  Could not read the drive's region state: %s" % err)
        out("  The drive may not report RPC state, or the disc may be in use -")
        out("  stop playback and try again.")
        pause()
        return 1

    extra = sibling_lines(drives)

    if state.scheme == 0:
        for row in status_lines(drive, state) + extra:
            out(row)
        out()
        out("  This drive is RPC-1: it enforces no region at all. That is the best")
        out("  case - it answers the CSS key exchange whatever region a disc comes")
        out("  from, so there is nothing to set here and nothing to gain.")
        pause()
        return 0

    if want is None:
        # No controllable console (fb_terminal=0 runs scripts through the OSD with
        # no stdin at all, and a pipe has none either): report and stop rather than
        # block on input nobody can give.
        if not sys.stdin.isatty():
            for row in status_lines(drive, state) + extra:
                out(row)
            out()
            out("  Run this from the MiSTer Scripts menu (with fb_terminal=1) to")
            out("  change the region, or pass the region number as an argument.")
            return 0
        return interactive(drive, state, extra)

    # Argument form (SSH): same safety rules, minus the cursor menu.
    for row in status_lines(drive, state) + extra:
        out(row)
    if want == state.region:
        out()
        out("  Already region %d. Nothing was changed." % want)
        return 0
    if state.changes == 0:
        out()
        out("  No changes left - the region is locked permanently.")
        return 1
    if not assume_yes:
        if not sys.stdin.isatty():
            out()
            out("  Nothing to confirm with: this is not a terminal. Re-run with")
            out("  --yes if you are sure, or use the MiSTer Scripts menu.")
            return 1
        verdict = menu(["  Set %s to region %d?" % (drive.path, want),
                        "",
                        "  Uses one of %d remaining changes; cannot be undone." % state.changes],
                       ["No  - leave the drive alone", "Yes - set region %d" % want],
                       ["  arrows = move    Enter = select    Esc = cancel"],
                       selected=0)
        clear()
        if verdict != 1:
            out("  Cancelled. Nothing was changed.")
            return 0
    return apply_region(drive, want)


# Guarded so the payload can be IMPORTED as a module and its pure functions
# tested directly (tools/test_set_dvd_region.py extracts it) — running it the
# normal way, `python3 <file>`, is unaffected.
if __name__ == "__main__":
    log_open()
    try:
        code = main()
    except KeyboardInterrupt:
        code = 1
    except Exception as exc:
        # A traceback on a television tells the user nothing and scrolls the
        # useful part off the screen. One line here, the whole thing in the log.
        out()
        out("  Something went wrong: %s: %s" % (type(exc).__name__, exc))
        if log_path:
            out("  The details are in %s" % log_path)
        note(traceback.format_exc())
        pause()
        code = 1
    note("exit %s" % code)
    sys.exit(code)
PYEOF

python3 "$PY" "$@"
