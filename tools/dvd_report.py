#!/usr/bin/env python3
# =============================================================================
# dvd_report.py -- build a tiny, shareable repro bundle for a DVD NAVIGATION bug
# =============================================================================
# THE PROBLEM THIS SOLVES
#
# Nearly every navigation bug reported against this core happens on a disc the
# maintainer does not own: "LINK FAIL 12", "it plays the wrong title", "the menu
# button does nothing", "no audio in this one VTS". Diagnosing those needs the
# disc's nav tables -- and nothing else. But a DVD-Video ISO is 4-8 GB, which
# nobody can attach to an issue.
#
# The nav tables are the IFO files, and they are TINY. Measured on a real 4.47 GB
# rip: VIDEO_TS.IFO + VTS_01_0.IFO together are 104 KB -- 0.0023% of the image,
# about 43,000x smaller. Every host-side nav tool in tools/ (iso_nav_check.py,
# dvd_vm_ref.py, dvd_census.py) reads ONLY those tables plus the ISO9660
# directory records that locate them. So a nav bug is fully reproducible from
# roughly a hundred kilobytes.
#
# WHY A SPARSE-SECTOR BUNDLE AND NOT "JUST SEND THE IFO FILES"
#
# The tools do not take loose IFO files -- they take an ISO, and IsoNav starts by
# asserting 'CD001' at sector 16 and then follows absolute LBAs. Loose IFOs would
# mean rewriting every tool, and the LBAs (which the RTL reader also consumes)
# would be lost.
#
# So this bundle stores {LBA -> 2048-byte sector} pairs at their ORIGINAL disc
# addresses. `unpack` writes them back into a SPARSE file of the original image
# size: every captured sector sits at its true offset and everything else reads
# as zero. The filesystem stores only the real bytes (a 4.47 GB reconstruction
# occupies ~100 KB on disk), and:
#
#   * every existing tool works UNMODIFIED -- no tool needed changing for this,
#   * the RTL testbenches already use exactly this idiom (see the *_meta.hex
#     fixtures and bench/dvd/iso_reader_atmos_tb.sv, whose header notes
#     "everything else reads as zero in the TB"), so a submission can become a
#     regression fixture rather than a one-off debugging session.
#
# SCOPE -- deliberately navigation only
#
# Subpicture, closed-caption, film-cadence and A/V-sync bugs need real VOB
# payload bytes (the evidence lives in the elementary stream, not in any nav
# table), which is megabytes and a different problem. Those are better reported
# in prose. This tool does not try to cover them. The one exception is the
# optional --nav-packs flag, which captures menu NAV packs (PCI/HLI button
# rectangles) for menu-highlight bugs -- still nav-domain data.
#
# That scope line is ENFORCED, not merely intended. audit() runs over the final
# captured set before anything is written, and refuses to produce a bundle if
# any captured sector that parses as an MPEG-PS pack contains a packet other
# than a system header, padding or private_stream_2. A bundle therefore cannot
# carry picture or sound even if the collector is wrong.
#
# It also cannot carry decryption keys, and not by choice: CSS title keys live
# in the headers of scrambled sectors (which are never captured), and the disc
# key block lives in the lead-in control area, which is not part of an ISO
# filesystem image at all. The IFO tables and NAV packs a bundle does contain
# are the parts of a DVD that CSS leaves in the clear by design, because every
# player must read them to navigate -- see main/support/dvd/dvd_css.cpp:341,393.
#
# The corollary matters for who can file a report: a bundle built from an
# ENCRYPTED rip is byte-identical to one built from the decrypted disc, because
# every sector this reads is one CSS never touches. So asking a user for a bundle
# never asks them to decrypt anything. Verified on a real CSS disc, not argued
# from the spec -- see docs/bug_reports.md "Validation".
#
# PRIVACY -- bundles are meant to be attached to PUBLIC issues
#
# The manifest records the image's BASENAME only, never a full path, and no
# username, hostname or directory layout. The bundle is summarised on stdout
# after it is written so the reporter can see exactly what they are sharing.
#
# This file is deliberately SELF-CONTAINED (it duplicates a small ISO9660 walk
# rather than importing dvd_vm_ref.IsoNav) because a bug reporter downloads this
# ONE file from the repository and runs it -- they do not have a checkout.
#
# Usage (reporter, on a PC, with their own rip -- encrypted or decrypted):
#   python3 dvd_report.py disc.iso
#   python3 dvd_report.py disc.iso --nav-packs        # menu highlight bugs
#   python3 dvd_report.py disc.iso --core-version "v0.4.0 260910" --no-prompt
#
# Usage (maintainer, on a received bundle):
#   python3 tools/dvd_report.py info    dvdreport-*.zip
#   python3 tools/dvd_report.py unpack  dvdreport-*.zip -o repro.iso
#   python3 tools/iso_nav_check.py repro.iso
#   python3 tools/dvd_vm_ref.py boot repro.iso
# =============================================================================

import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import sys
import tempfile
import zipfile

SEC = 2048
SCHEMA = 1
TOOL_VERSION = "1"

# GitHub only accepts a fixed set of attachment extensions on issues, and a
# custom one (.dvdrep) is not among them -- so the bundle is a plain .zip.
BUNDLE_EXT = ".zip"

BUNDLE_README = """\
MiSTer DVD core -- navigation bug repro bundle
=============================================

This archive contains only the UNENCRYPTED NAVIGATION STRUCTURES of a DVD --
the ISO9660 directory records, the IFO navigation tables, and optionally the
NAV packs that describe menu buttons -- stored at their original disc
addresses.

It contains NO video, NO audio and NO decryption keys, and it cannot be used
to watch anything. Every sector was checked before the archive was written:
any sector that parses as an MPEG program-stream pack carries navigation
packets only (system header, padding, private_stream_2), never picture or
sound. See "content_audit" in manifest.json.

To use it (from a MiSTer_DVD checkout):

    python3 tools/dvd_report.py info   <this-file>
    python3 tools/dvd_report.py unpack <this-file> -o repro.iso
    python3 tools/iso_nav_check.py repro.iso
    python3 tools/dvd_vm_ref.py boot repro.iso

`unpack` writes a sparse image of the original disc's size: the captured
sectors sit at their true offsets and every other sector reads as zero, so the
existing navigation tools work on it unmodified. Playback of the reconstructed
image is NOT expected to work -- the video is not here.
"""


# ---------------------------------------------------------------- ISO9660 walk

class IsoWalk(object):
    """Minimal ISO9660 reader: volume descriptors, root, VIDEO_TS.

    Mirrors the walk in tools/dvd_vm_ref.py IsoNav._walk, but records the LBA
    *spans* it visits so they can be captured, and is standalone so this file
    can be downloaded and run on its own.
    """

    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        self.file_size = self._size(path)
        self.vd_lbas = []        # volume descriptor sectors
        self.dir_spans = []      # (lba, nsec) for root + VIDEO_TS
        self.ifo = {}            # NAME -> (lba, length)
        self.menu_vob = {}       # vts -> (lba, length); 0 = VIDEO_TS.VOB
        self.title_vob = {}      # vts -> [(lba, length), ...]
        self._walk()

    def _size(self, path):
        """Byte size of an image file OR a block device (/dev/sr0).

        os.path.getsize() returns 0 for a device node, which would poison
        image_bytes and so the size of the reconstruction. Seek to the end
        instead; if even that fails, the caller falls back to the PVD's own
        volume_space_size, which is the disc's true size anyway.
        """
        try:
            n = os.path.getsize(path)
            if n:
                return n
        except OSError:
            pass
        try:
            return self.f.seek(0, os.SEEK_END) or 0
        except OSError:
            return 0

    def sec(self, n):
        self.f.seek(n * SEC)
        d = self.f.read(SEC)
        return d + b"\0" * (SEC - len(d)) if len(d) < SEC else d

    def close(self):
        self.f.close()

    def _dir(self, dlba, dlen):
        nsec = (dlen + SEC - 1) // SEC
        self.dir_spans.append((dlba, nsec))
        buf = b"".join(self.sec(dlba + i) for i in range(nsec))
        out = []
        for s in range(nsec):
            p = s * SEC
            end = p + SEC
            while p < end:
                rl = buf[p]
                if rl == 0:
                    break
                ext = struct.unpack("<I", buf[p + 2:p + 6])[0]
                dl = struct.unpack("<I", buf[p + 10:p + 14])[0]
                fl = buf[p + 25]
                nl = buf[p + 32]
                nm = buf[p + 33:p + 33 + nl]
                out.append((nm.upper(), ext, dl, fl))
                p += rl
        return out

    def _walk(self):
        lba = 16
        pvd = None
        while lba < 16 + 32:
            d = self.sec(lba)
            if d[1:6] != b"CD001":
                raise SystemExit(
                    "%s is not an ISO9660 image (no CD001 at sector %d).\n"
                    "This tool needs a DVD-Video .iso rip (encrypted is fine)."
                    % (os.path.basename(self.path), lba))
            self.vd_lbas.append(lba)
            if d[0] == 1 and pvd is None:
                pvd = d
            if d[0] == 255:
                break
            lba += 1
        if pvd is None:
            raise SystemExit("no Primary Volume Descriptor found")

        self.volume_label = pvd[40:72].decode("latin-1").strip() or "(unnamed)"
        self.volume_sectors = struct.unpack("<I", pvd[80:84])[0]
        root_lba = struct.unpack("<I", pvd[158:162])[0]
        root_len = struct.unpack("<I", pvd[166:170])[0]

        vts_dir = None
        for nm, ext, dl, fl in self._dir(root_lba, root_len):
            if nm.startswith(b"VIDEO_TS") and (fl & 2):
                vts_dir = (ext, dl)
        if not vts_dir:
            raise SystemExit(
                "no VIDEO_TS directory -- this is not a DVD-Video image.\n"
                "(UDF-only images are not supported by this tool, and are not\n"
                "supported by the core either.)")

        for nm, ext, dl, fl in self._dir(*vts_dir):
            base = nm.split(b";")[0]
            if base.endswith(b".IFO"):
                self.ifo[base.decode("latin-1")] = (ext, dl)
            elif base == b"VIDEO_TS.VOB":
                self.menu_vob[0] = (ext, dl)
            elif base.startswith(b"VTS_") and base.endswith(b".VOB"):
                try:
                    vn = int(base[4:6])
                    part = int(base[7:8])
                except ValueError:
                    continue
                if part == 0:
                    self.menu_vob[vn] = (ext, dl)
                else:
                    self.title_vob.setdefault(vn, []).append((ext, dl))

        if "VIDEO_TS.IFO" not in self.ifo:
            raise SystemExit("no VIDEO_TS.IFO -- image is not a DVD-Video disc")

    # -- summary numbers for the manifest (cheap, IFO-only) -------------------

    def summary(self):
        vmgi_lba = self.ifo["VIDEO_TS.IFO"][0]
        mat = self.sec(vmgi_lba)
        tsp = struct.unpack(">I", mat[196:200])[0]
        n_titles = 0
        if 0 < tsp <= 0xFFFFF:
            n_titles = struct.unpack(">H", self.sec(vmgi_lba + tsp)[0:2])[0]
        return {
            "volume_label": self.volume_label,
            "volume_sectors": self.volume_sectors,
            "n_vts": len([k for k in self.ifo if k.startswith("VTS_")]),
            "n_titles": n_titles,
            "ifo_files": sorted(self.ifo),
        }

    def fingerprint(self):
        """SHA-1 over VIDEO_TS.IFO, capped at 1 MiB and at its own length.

        Same construction as the disc fingerprint used by the ripper tooling:
        the IFO area is never CSS-scrambled, so it reads identically from a
        drive and from a finished ISO, which makes it a stable disc identity
        for de-duplicating reports.
        """
        lba, _ = self.ifo["VIDEO_TS.IFO"]
        mat = self.sec(lba)
        vmgi_last = struct.unpack(">I", mat[28:32])[0]
        cap = 1 << 20
        length = min((vmgi_last + 1) * SEC, cap) if vmgi_last else cap
        self.f.seek(lba * SEC)
        return "v1:" + hashlib.sha1(self.f.read(length)).hexdigest()


# ------------------------------------------------------------ sector selection

def merge(lbas):
    """Sorted unique LBAs -> list of [start, count] runs."""
    out = []
    for l in sorted(set(lbas)):
        if out and l == out[-1][0] + out[-1][1]:
            out[-1][1] += 1
        else:
            out.append([l, 1])
    return out


# The only PES stream ids that carry NO elementary stream data: system header,
# padding, and private_stream_2 (which on a DVD is PCI/DSI navigation only).
# A sector built exclusively from these cannot contain picture or sound.
NAV_ONLY_IDS = {0xBB, 0xBE, 0xBF}


def pack_packets(d):
    """Walk a 2048-byte MPEG-PS pack. -> [(stream_id, payload_off)] or None."""
    if d[0:4] != b"\x00\x00\x01\xba":
        return None
    p = 14 + (d[13] & 7)                      # pack header + stuffing
    out = []
    while p + 6 <= len(d) and d[p:p + 3] == b"\x00\x00\x01":
        ln = struct.unpack(">H", d[p + 4:p + 6])[0]
        out.append((d[p + 3], p + 6))
        if ln == 0:
            break
        p += 6 + ln
    return out


def is_nav_pack(d):
    """True iff this sector is a DVD NAV pack AND carries nothing else.

    Both halves matter. The second is what makes "no audiovisual content" a
    property of the code rather than an intention: a sector is only ever taken
    from a VOB if EVERY packet in it is a system header, padding or
    private_stream_2, and one of those is a PCI. Proven by walking the packet
    lengths -- not assumed from the layout.

    ⚠ Do NOT shortcut this as "0x000001BF at offset 14". Real discs put a
    SYSTEM HEADER (0x000001BB) between the pack header and the PCI packet, so
    the PCI start code lands at 0x26 and its payload at 0x2D. A fixed-offset
    check finds ZERO nav packs on such a disc and reports success while doing
    nothing -- the same silent-miss that cost a NAV scan elsewhere in this
    project (see CLAUDE.md, forced-select fix). Walk the packets by length.
    """
    pkts = pack_packets(d)
    if not pkts:
        return False
    if any(sid not in NAV_ONLY_IDS for sid, _ in pkts):
        return False
    # private_stream_2 carries no PES optional header: its payload starts
    # immediately, and the first byte is the substream id (0x00 = PCI).
    return any(sid == 0xBF and d[off:off + 1] == b"\x00" for sid, off in pkts)


def audit(iso, extents):
    """Prove that no captured sector carries elementary stream data.

    This is the structural form of the promise the bundle makes: it contains
    only unencrypted navigation structures, never picture or sound. Rather than
    trusting the collector's intent, it runs over the FINAL captured set --
    filesystem and IFO sectors included, so it also catches a mistake upstream
    of the nav-pack scanner (a bad extent length spilling into a VOB, say).

    The rule is total and simple: if a captured sector parses as an MPEG-PS pack
    at all, every packet in it must be nav-only.
    """
    meta = navp = 0
    for lba, count in extents:
        for i in range(count):
            d = iso.sec(lba + i)
            if pack_packets(d) is None:
                meta += 1                     # not a media pack: PVD/dir/IFO
            elif is_nav_pack(d):
                navp += 1
            else:
                raise SystemExit(
                    "INTERNAL ERROR: sector %d carries elementary stream data, "
                    "so no bundle was written.\nPlease report this -- it is a "
                    "bug in this tool, not in your disc." % (lba + i))
    return meta, navp


def collect(iso, nav_packs=False, nav_scan_mb=512, verbose=True):
    lbas = list(iso.vd_lbas)
    for lba, nsec in iso.dir_spans:
        lbas.extend(range(lba, lba + nsec))
    for name, (lba, dl) in sorted(iso.ifo.items()):
        lbas.extend(range(lba, lba + (dl + SEC - 1) // SEC))

    if nav_packs:
        budget = (nav_scan_mb * 1024 * 1024) // SEC
        found = 0
        for vts, (lba, dl) in sorted(iso.menu_vob.items()):
            n = min((dl + SEC - 1) // SEC, budget)
            if n <= 0:
                break
            for i in range(n):
                if is_nav_pack(iso.sec(lba + i)):
                    lbas.append(lba + i)
                    found += 1
            budget -= n
        if verbose:
            print("  menu NAV packs captured: %d" % found)
    return merge(lbas)


# ------------------------------------------------------------------- bundling

def read_cfg(path):
    if not path:
        return None
    with open(path, "rb") as f:
        raw = f.read(64)
    return {"file": os.path.basename(path), "hex": raw.hex()}


def prompt(label, default=""):
    try:
        v = input("%s: " % label).strip()
    except EOFError:
        return default
    return v or default


def safe_slug(s):
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("_")
    return s[:40] or "disc"


def cmd_make(args):
    iso = IsoWalk(args.iso)
    summ = iso.summary()
    fp = iso.fingerprint()

    print("Disc: %s  (%d VTS, %d titles)"
          % (summ["volume_label"], summ["n_vts"], summ["n_titles"]))
    print("Fingerprint: %s" % fp)

    core_version = args.core_version
    symptom = args.symptom
    expected = args.expected
    steps = args.steps
    if not args.no_prompt and sys.stdin.isatty():
        print()
        print("A few questions -- all optional, press Enter to skip.")
        print("(Everything you type here goes into the bundle, which is meant")
        print(" to be attached to a public issue. Do not include personal info.)")
        print()
        if not core_version:
            core_version = prompt(
                "Core version, exactly as shown in the OSD "
                "(e.g. v0.4.0 260910, or dev-seekrealign 260903)")
        if not symptom:
            symptom = prompt("What happened")
        if not expected:
            expected = prompt("What you expected instead")
        if not steps:
            steps = prompt("Steps (e.g. 'boot disc, press Menu, choose Scenes')")
        print()

    extents = collect(iso, args.nav_packs, args.nav_scan_mb)
    n_sec = sum(c for _, c in extents)
    n_meta, n_nav = audit(iso, extents)

    blob = bytearray()
    for lba, count in extents:
        for i in range(count):
            blob += iso.sec(lba + i)

    image_bytes = max(iso.file_size, iso.volume_sectors * SEC)
    manifest = {
        "schema": SCHEMA,
        "tool": "dvd_report.py",
        "tool_version": TOOL_VERSION,
        "created_utc": datetime.datetime.now(
            datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "core_version": core_version or None,
        "symptom": symptom or None,
        "expected": expected or None,
        "steps": steps or None,
        "disc": {
            "image_name": os.path.basename(args.iso),
            "image_bytes": image_bytes,
            "fingerprint": fp,
            **{k: v for k, v in summ.items() if k != "volume_sectors"},
        },
        "settings_cfg": read_cfg(args.cfg),
        # Present only when the bundle was generated on the player itself,
        # where the Main knows things a reporter cannot state from memory:
        # the exact sector being served when the problem was seen, and the
        # live status word (= the OSD settings, without hunting for the CFG).
        "player": None if not (args.lba is not None or args.status
                               or args.generated_on) else {
            "generated_on": args.generated_on,
            "lba": args.lba,
            "status_hex": args.status,
        },
        "includes_nav_packs": bool(args.nav_packs),
        "sector_count": n_sec,
        "content_audit": {
            "metadata_sectors": n_meta,
            "nav_pack_sectors": n_nav,
            "elementary_stream_sectors": 0,   # enforced by audit(), not asserted
        },
        "extents": extents,
    }

    # Auto-name carries BOTH the disc identity and a timestamp: the identity so
    # two discs never collide and the maintainer can see what it is without
    # opening it, the timestamp so a second run on the SAME disc -- a follow-up
    # after a fix, or a second bug -- does not silently overwrite the first.
    out = args.out or ("dvdreport-%s-%s-%s%s"
                       % (safe_slug(summ["volume_label"]), fp[3:11],
                          datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
                          BUNDLE_EXT))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        z.writestr("sectors.bin", bytes(blob))
        z.writestr("README.txt", BUNDLE_README)
    iso.close()

    ok = verify(out, args.iso)

    size = os.path.getsize(out)
    print()
    print("Wrote %s" % out)
    print("  %d sectors (%.1f KB of disc data) -> %.1f KB compressed"
          % (n_sec, len(blob) / 1024.0, size / 1024.0))
    print("  %.5f%% of the original %.2f GB image"
          % (100.0 * len(blob) / image_bytes, image_bytes / 1e9))
    print("  self-check:    %s" % ("PASS" if ok else "FAILED -- please report this"))
    print("  content audit: PASS -- %d navigation-table sectors, %d NAV packs,"
          % (n_meta, n_nav))
    print("                 0 sectors carrying picture or sound data")
    print()
    print("This bundle contains only the UNENCRYPTED NAVIGATION STRUCTURES of the")
    print("disc: ISO9660 directory records, the IFO tables%s,"
          % (", menu NAV packs" if args.nav_packs else ""))
    print("and what you typed above. No video, no audio, no decryption keys, and")
    print("no file paths from this machine. It cannot be used to watch anything.")
    print("Attach it to a GitHub issue.")
    return 0 if ok else 1


def verify(bundle, original):
    """Rebuild to a temp sparse image, re-walk it, and compare IFO bytes.

    A bundle that cannot be walked is worse than no bundle -- the reporter has
    moved on by the time anyone opens it -- so this runs unconditionally.
    """
    tmp = tempfile.NamedTemporaryFile(prefix="dvdrepro-", suffix=".iso",
                                      delete=False)
    tmp.close()
    try:
        unpack_to(bundle, tmp.name)
        a = IsoWalk(tmp.name)
        b = IsoWalk(original)
        for name, (lba, dl) in sorted(b.ifo.items()):
            n = (dl + SEC - 1) // SEC
            for i in range(n):
                if a.sec(lba + i) != b.sec(lba + i):
                    a.close(); b.close()
                    return False
        a.summary()
        a.close(); b.close()
        return True
    except Exception as e:
        print("  self-check error: %s" % e)
        return False
    finally:
        os.unlink(tmp.name)


# ------------------------------------------------------------------ unpacking

def unpack_to(bundle, out):
    with zipfile.ZipFile(bundle) as z:
        man = json.loads(z.read("manifest.json"))
        if man.get("schema") != SCHEMA:
            raise SystemExit("unsupported bundle schema %r (this tool: %d)"
                             % (man.get("schema"), SCHEMA))
        blob = z.read("sectors.bin")
    need = man["sector_count"] * SEC
    if len(blob) != need:
        raise SystemExit("bundle is truncated: sectors.bin is %d bytes, "
                         "manifest declares %d" % (len(blob), need))
    with open(out, "wb") as f:
        f.truncate(man["disc"]["image_bytes"])   # sparse: costs no disk
        pos = 0
        for lba, count in man["extents"]:
            f.seek(lba * SEC)
            f.write(blob[pos:pos + count * SEC])
            pos += count * SEC
    return man


def cmd_unpack(args):
    out = args.out or "repro.iso"
    man = unpack_to(args.bundle, out)
    du = os.stat(out).st_blocks * 512
    print("Wrote %s -- %.2f GB sparse image, %.1f KB actually on disk"
          % (out, man["disc"]["image_bytes"] / 1e9, du / 1024.0))
    print()
    print("Next:")
    print("  python3 tools/iso_nav_check.py %s" % out)
    print("  python3 tools/dvd_vm_ref.py boot %s" % out)
    print("  python3 tools/dvd_census.py %s" % out)
    return 0


def cmd_info(args):
    with zipfile.ZipFile(args.bundle) as z:
        man = json.loads(z.read("manifest.json"))
    d = man["disc"]
    print("bundle       %s" % os.path.basename(args.bundle))
    print("created      %s  (tool v%s, schema %s)"
          % (man["created_utc"], man["tool_version"], man["schema"]))
    print("core version %s" % (man.get("core_version") or "(not stated)"))
    print("disc         %s  [%s]" % (d["volume_label"], d["image_name"]))
    print("fingerprint  %s" % d["fingerprint"])
    print("size         %.2f GB, %d VTS, %d titles"
          % (d["image_bytes"] / 1e9, d["n_vts"], d["n_titles"]))
    print("captured     %d sectors, nav packs: %s"
          % (man["sector_count"], "yes" if man["includes_nav_packs"] else "no"))
    ca = man.get("content_audit")
    if ca:
        print("audit        %d nav-table sectors, %d NAV packs, %d carrying A/V"
              % (ca["metadata_sectors"], ca["nav_pack_sectors"],
                 ca["elementary_stream_sectors"]))
    if man.get("settings_cfg"):
        print("settings     %s = %s"
              % (man["settings_cfg"]["file"], man["settings_cfg"]["hex"]))
    pl = man.get("player")
    if pl:
        print("generated on %s" % (pl.get("generated_on") or "?"))
        if pl.get("lba") is not None:
            print("playhead     sector %d" % pl["lba"])
        if pl.get("status_hex"):
            print("status word  %s  (live OSD settings)" % pl["status_hex"])
    for k in ("symptom", "expected", "steps"):
        if man.get(k):
            print("%-12s %s" % (k, man[k]))
    return 0


# ----------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description="Build a small, shareable repro bundle for a DVD "
                    "navigation bug in the MiSTer DVD core.",
        epilog="Run with just an .iso path to build a bundle.")
    sub = ap.add_subparsers(dest="cmd")

    def add_make(p):
        p.add_argument("iso", help="DVD-Video .iso rip (encrypted or decrypted)")
        p.add_argument("-o", "--out", help="output .zip (default: auto-named)")
        p.add_argument("--core-version",
                       help="core version line from the OSD, e.g. 'v0.4.0 260910' "
                            "for a release or 'dev-seekrealign 260903' for a test build")
        p.add_argument("--symptom", help="what happened")
        p.add_argument("--expected", help="what you expected")
        p.add_argument("--steps", help="how to reach it")
        p.add_argument("--cfg", help="path to config/DVD_v1.CFG from the SD card")
        p.add_argument("--nav-packs", action="store_true",
                       help="also capture menu NAV packs (PCI/HLI button "
                            "rectangles) -- add this for menu HIGHLIGHT bugs")
        p.add_argument("--nav-scan-mb", type=int, default=512,
                       help="cap on menu VOB bytes scanned for NAV packs "
                            "(default 512)")
        p.add_argument("--no-prompt", action="store_true",
                       help="do not ask any questions")
        # Set by MiSTer_DVDcss when it generates a bundle on the player; see
        # main/support/dvd/dvd_report.cpp and docs/support_bundle_hps.md.
        p.add_argument("--lba", type=int,
                       help="sector being served when the problem was seen")
        p.add_argument("--status",
                       help="core status word as hex (the live OSD settings)")
        p.add_argument("--generated-on",
                       help="where this was generated, e.g. 'mister'")

    pm = sub.add_parser("make", help="build a bundle from an ISO")
    add_make(pm)
    pm.set_defaults(func=cmd_make)

    pu = sub.add_parser("unpack", help="rebuild a sparse ISO from a bundle")
    pu.add_argument("bundle")
    pu.add_argument("-o", "--out", help="output image (default repro.iso)")
    pu.set_defaults(func=cmd_unpack)

    pi = sub.add_parser("info", help="print a bundle's manifest")
    pi.add_argument("bundle")
    pi.set_defaults(func=cmd_info)

    # Bare `dvd_report.py disc.iso` is the reporter's path -- no subcommand.
    argv = sys.argv[1:]
    if argv and argv[0] not in ("make", "unpack", "info", "-h", "--help"):
        argv = ["make"] + argv
    if not argv:
        # Reached with no arguments -- most likely picked from the MiSTer
        # Scripts menu, where a script gets no arguments at all. An argparse
        # usage dump is useless there, so say what this is and how it is used.
        print("MiSTer DVD -- support bundle builder")
        print()
        print("This packages a disc's navigation tables (no video, no audio) so a")
        print("navigation bug can be reproduced without the disc.")
        print()
        print("On the MiSTer: hold Audio + Subtitle for 2 seconds while a disc is")
        print("playing. The bundle is written to /media/fat/DVD_reports/.")
        print()
        print("On a PC:  python3 dvd_report.py MY_DISC.iso")
        print()
        print("https://owenb321.github.io/MiSTer_DVD/reference/reporting-a-bug/")
        return 0

    args = ap.parse_args(argv)
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
