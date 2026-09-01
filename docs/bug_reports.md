# Navigation bug reports — the sparse-sector repro bundle

**Status: ✅ implemented (`tools/dvd_report.py`), validated across 23 library discs.
User-facing entry point is the manual page `site/content/reference/reporting-a-bug.md`
(Reference → Reporting a bug); the README is a landing page and deliberately does not
carry this.**

## Why this exists

The core is public, and the discs that break it are overwhelmingly discs the
maintainer does not own. Every nav bug in this project's history arrived as a
sentence — *"link failure on every menu option"*, *"picks Play All whatever you
choose"*, *"the floor maze starts the player in the wrong position"* — with no
way to get at the disc. A DVD-Video ISO is 4–8 GB; nobody is uploading that to
an issue tracker, and asking them to is what makes a report never happen.

But a navigation bug does not need the disc. It needs the **nav tables**, which
are the IFO files, and those are minuscule. Measured on a real 4.47 GB rip:

| | Size | vs image |
|---|---|---|
| `VIDEO_TS.IFO` + `VTS_01_0.IFO` | 104 KB | 0.0023% |
| Typical finished bundle (compressed) | **36–100 KB** | ~0.005% |

Every host-side nav tool in `tools/` — `iso_nav_check.py`, `dvd_vm_ref.py`,
`dvd_census.py` — reads *only* those tables plus the ISO9660 directory records
that locate them. So the bug is fully reproducible from about a hundred
kilobytes, and always was; there just was no way for a reporter to produce it.

## Why sparse sectors rather than "just send the IFO files"

Loose IFO files are not usable by anything we have. The tools take an **image**:
`IsoNav` (`tools/dvd_vm_ref.py:324`) asserts `CD001` at sector 16 and then
follows absolute LBAs everywhere. Accepting loose files would mean rewriting
every tool, and would throw away the LBAs — which the RTL reader consumes too.

So the bundle stores `{LBA → 2048-byte sector}` pairs **at their original disc
addresses**, and `unpack` writes them back into a **sparse** file of the original
image's size. Every captured sector sits at its true offset; everything else
reads as zero. Consequences, all of which are the point:

- **No tool needed changing.** Not one. The reconstruction is an ISO as far as
  anything is concerned.
- **The filesystem stores only the real bytes.** A 6.77 GB reconstruction
  occupies 480 KB on disk.
- **It matches the existing testbench idiom.** The committed `*_meta.hex`
  fixtures are the same thing in `$readmemh` form —
  `bench/dvd/iso_reader_atmos_tb.sv` reproduces a real title-selection bug on an
  8.26 GB disc from 16 sectors, its header noting "everything else reads as zero
  in the TB". A received bundle is therefore already in the shape a regression
  fixture wants, rather than being a one-off debugging session.

## What is captured

1. The volume descriptor set (sector 16 to the terminator).
2. The root directory extent, and the `VIDEO_TS` directory extent.
3. **Every `.IFO` file, whole.** Not a computed subset of tables — taking them
   entire costs tens of KB and removes any chance of a bundle that is missing
   the one table the bug turns on.
4. With `--nav-packs`: NAV packs (PCI/HLI — the button rectangles) from the menu
   VOBs, for menu-highlight bugs. Off by default; it is the only part that scans
   VOB payload, and it is bounded by `--nav-scan-mb` (default 512).

Deliberately **not** captured: title VOB payload. Subpicture, closed-caption,
film-cadence and A/V-sync evidence all live in the elementary stream, which is
megabytes and a different problem — those report better in prose.

## The content guarantee, and why it is structural

A bundle contains **only unencrypted navigation structures: no picture, no
sound, no decryption keys.** That is worth being able to say plainly, so it is
enforced by `audit()` rather than left as an intention.

Before anything is written, `audit()` walks every gathered sector and applies one
total rule: *if a sector parses as an MPEG program-stream pack at all, every
packet in it must be a system header, padding, or `private_stream_2`* — the only
stream ids that carry no elementary stream data. Anything else aborts the run
with no bundle produced. Because it runs over the **final** captured set, it also
catches a mistake upstream of the nav-pack scanner (an IFO extent length spilling
into a VOB, say), not merely a bad nav-pack verdict. The counts land in the
manifest as `content_audit` and are printed as `content audit: PASS`.

Proven RED, not merely observed green: pointed at a real title-VOB sector from
`Dinosaur` (stream id `0xE0`) it refuses, and passes a real NAV pack from the
same disc. Then re-swept across the library with `--nav-packs` on — every disc
audits clean, bundles 38–596 KB.

The **no keys** half needs no enforcement, because a bundle cannot carry key
material even in principle: CSS title keys live in the headers of scrambled
sectors, which are never captured, and the disc key block lives in the lead-in
control area, which is not part of an ISO filesystem image at all.

This is also why the IFO tables and NAV packs are capturable in the first place.
CSS cannot scramble them — every player has to read them to navigate — which
this project's own CSS implementation states outright:
`main/support/dvd/dvd_css.cpp:341` ("a filesystem/IFO sector (never scrambled ->
must be read raw)") and `:393` ("The NAV pack (VOBU sector 0) is never
scrambled"). A bundle is, by construction, exactly the part of a DVD that is
already in the clear.

⚠ **Never relax this to accept VOB payload "just for one bug".** The guarantee is
the whole reason the bundle is something a stranger can hand over without
thinking about it, and it is what keeps the tool clearly distinct from the CSS
key cache, which must never be shared (see the `css-key-cache-never-ship` rule).

## The bundle

A plain `.zip` — **not** a custom extension, because GitHub only accepts a fixed
set of attachment types on issues and a `.dvdrep` would simply be rejected.

```
manifest.json   schema, tool version, core version as typed by the reporter,
                symptom/expected/steps, disc identity, extent list
sectors.bin     the captured sectors, concatenated in extent order
README.txt      what this is, for whoever opens it without context
```

Disc identity is the **fingerprint** `v1:<sha1>` — SHA-1 over `VIDEO_TS.IFO`,
capped at 1 MiB and at its own `vmgi_last_sector`. Same construction the ripper
tooling uses, chosen because the IFO area is never CSS-scrambled and so reads
identically from a drive and from a finished ISO. It makes reports de-duplicate
by disc, and answers "do I already own this one?" against the local library
without opening anything.

## Working a received bundle

```bash
python3 tools/dvd_report.py info   dvdreport-FOO-1a2b3c4d.zip
python3 tools/dvd_report.py unpack dvdreport-FOO-1a2b3c4d.zip -o repro.iso
python3 tools/iso_nav_check.py repro.iso
python3 tools/dvd_vm_ref.py boot repro.iso
python3 tools/dvd_vm_ref.py menu repro.iso
python3 tools/dvd_census.py repro.iso
python3 tools/nav_extract.py repro.iso --vts N --cmds   # needs --nav-packs
```

⚠ **Playback of a reconstruction is not expected to work** — the video is not
there. It is an analysis artifact. (It will still *mount*, and the nav decisions
it drives are real, so loading one on hardware to watch which PGC the reader
lands on is legitimate; the picture will not be.)

## Validation

Correctness here means one thing: **the tools must produce byte-identical output
on the reconstruction and on the original disc.** That is checked two ways.

**Per bundle, automatically.** `dvd_report.py` rebuilds every bundle it writes
into a temporary sparse image, re-walks it, and compares the IFO bytes against
the source before reporting `self-check: PASS`. A bundle that cannot be walked is
worse than no bundle, because the reporter has moved on by the time anyone opens
it — so this is not optional and not a flag.

**Across the library, once.** A sweep over 23 discs sampled from every category
(`bugs/`, `interactive/`, `pal/`, `tv/`, `film/`, `concert/`) built a bundle,
unpacked it, and diffed `iso_nav_check.py` output against the original: **23/23
identical**, up to 9,143 lines of nav analysis per disc, bundles 36–705 KB (the
two largest are DVD game discs with many VTS). Spot-checked further on
`dvd_vm_ref.py boot`/`menu`, `dvd_census.py`, and — for a `--nav-packs` bundle —
`nav_extract.py`, all identical. The sweep included the three discs named in
this project's own bug history (Scooby-Doo 2, Dinosaur, The Residents).

One disc, `bugs/br.iso`, fails `iso_nav_check.py` **on the original as well**: it
is a hand-made metadata-only extract with no title VOBs at all, and
`iso_nav_check.py:294` does `max()` over an empty VOB group list. Unrelated to
bundles (a bundle preserves the directory records, so the VOB entries still
exist), but worth knowing before it is mistaken for a bundle defect. Its VM
traces are identical between original and reconstruction.

That disc is also the argument for the whole feature: it is a 5 MB image
assembled by hand to investigate a remote Blade Runner report, and the bundle
reproduces it at 46 KB automatically.

## Notes for future work on this file

- **`tools/dvd_report.py` is deliberately self-contained** — it duplicates a
  small ISO9660 walk instead of importing `IsoNav`. A bug reporter downloads
  *one file* from the repository and runs it; they have no checkout. Keep it
  that way, and keep it dependency-free (standard library only). If the walk
  ever diverges from `IsoNav`, the per-bundle self-check is what catches it.
- ⚠ **NAV pack detection is not "`0x000001BF` at offset 14".** Real discs put a
  **system header** (`0x000001BB`) between the pack header and the PCI packet,
  which lands the PCI start code at `0x26` and its payload at `0x2D`. The first
  version of `is_nav_pack()` used the fixed offset, found **zero** nav packs on
  the first disc tried, and reported success while doing nothing — the same
  silent-miss that cost an earlier NAV scan in this project (see CLAUDE.md,
  forced-select). It now walks the packets by length.
- The manifest carries the raw `DVD_v1.CFG` bytes when the reporter passes
  `--cfg`, **undecoded on purpose**. The `O[..]` bit layout moves with almost
  every feature, so a decoder embedded in a file that users download and keep
  would go stale silently and mislead. The raw status word never does.

## Not done (deliberate)

- **No GitHub issue template.** Would raise report quality further and is
  independent of this tool.
- **No on-device generation.** A `Scripts/dvd_report.sh` on the MiSTer itself
  would remove the PC from the loop, but MiSTer scripts take no arguments and
  the gamepad injects only arrow keys and Enter, so disc/timestamp selection
  would need a cursor menu with no precedent anywhere in this tree.
- **No decoder-side (video) evidence.** See scope above.
- **No `--from-drive` mode.** Reading the IFOs straight off `/dev/sr0` would
  work — they are unscrambled, so no decryption is involved — and would mean a
  reporter never needed a rip at all. Rejected 2026-08-31 by user decision, for
  two reasons: it asks users to point a tool at their optical drive, and a report
  from someone who has already ripped and decrypted their own ISO is a better
  report — they can answer follow-up questions and re-run tools against the disc.
  The target reporter is a capable one, and the workflow should assume that.
