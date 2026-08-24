# Test-disc shopping list — filling the DVD-Video edge-case gaps

Companion to `docs/conformance.md`. **⚠️ Mostly bought — read this before shopping.** The
library has grown 7 → **23 discs** (re-censused 2026-07-31) and most of the Tier-1/Tier-2 rows
below now HAVE a vehicle: LPCM (Three Tenors, Roger Waters), branching/game discs (Atmosfear,
Thayer's Quest, Tomb Raider, Cluedo, 24, Family Feud II, Weakest Link, Brain Game, Hogwarts
Challenge, Speed Racer, Fairytopia), anime (Akira), plus the original film set (MiB, Matrix,
T2 Ultimate, Paw Patrol, Scene It ×3). Beyond that it exercises 5-angle (MiB),
seamless-branch/ILVU (Matrix white rabbit, T2 extended scenes), AC-3 5.1, DTS (T2), disc
menus, the full DVD-VM, and parental commands (Fairytopia).

**Only two rows still have no vehicle after tripling the library: #2 (LPCM 24-bit/96 kHz) and
#12 (UDF-only image)** — 0/23 each. Everything else on this list is now a *testing* task, not
a *purchasing* one: see **`docs/disc_sweep.md`**. Buy only to sharpen a specific row.

**Goal when shopping:** breadth over popularity — buy discs *structurally* different from a
Hollywood feature. Non-film releases (concerts, anime, TV box sets, karaoke, DVD games,
interactive/branching) are where the untested DVD-Video corners live. Cheap used copies are
fine; a quirk doesn't care about the film.

## How to use this list

1. Rip to a decrypted `.iso` (MakeMKV / dvdbackup — CSS stays a PC-side step; the core never
   sees encrypted data).
2. Run `tools/iso_nav_check.py <iso>` and `tools/ptt_ref.py <iso>` first — they'll show the
   title/PGC/PTT/attr structure and often reveal the quirk before you even flash it.
3. Play on hardware; if it misbehaves, capture the disc + symptom and we diagnose against the
   libdvdnav golden trace (`dvd_repos/`) the same way exact-PTT and the Scene It bugs were.

---

## Tier 1 — clear gaps, easy to find, high value

| # | Quirk / gap (RTL path) | What to look for on the cover | Example titles | Verify |
|---|---|---|---|---|
| 1 | **LPCM audio** — `dvd/lpcm_unpack.sv` — ✅ **have vehicles now**: `DMDC8200_THREE_TENORS.iso` (16-bit) + `ROGER_WATERS_IN_THE_FLESH.iso` (20-bit) | "**Linear PCM**" / "PCM Stereo" in the audio list. **Concert / music DVDs** almost always carry one. ⚠️ NOT "DVD-Audio" — that's a different format the core doesn't play. ⚠️ Many concert discs are **20-bit** (not 16) — needs the 20/24-bit depack fix. | *Talking Heads – Stop Making Sense*, *Pink Floyd – Pulse*, *Nine Inch Nails – And All That Could Have Been*, most Deutsche Grammophon / classical concert DVDs | Audio switches to LPCM cleanly (16/20/24-bit @ 48 k); A/V sync holds |
| 2 | **LPCM 24-bit / 96 kHz** — the deferred hi-res LPCM path | Audiophile / hi-res music DVD-Video with "96 kHz / 24-bit PCM" (2-ch; DVD bandwidth caps it there) | Chesky Records demo discs, high-end classical/jazz concert releases, *AIX Records* samplers | 24-bit unpack + 96 k rate handled (or documents the gap) |
| 3 | **Many audio + subtitle tracks, karaoke subpictures** (track enumeration, 32-stream subpicture, possible CHG_COLCON) | **Anime** box sets: JP+EN dub + commentary, 5–10+ subtitle streams, animated **karaoke OP/ED** subtitles | *Cowboy Bebop*, *Akira*, *Neon Genesis Evangelion*, any Studio Ghibli (Disney) disc | B7/B8 cycle through all tracks; karaoke subs render/animate |
| 4 | **Branching narrative / multiple endings** (PGC branching beyond ILVU, random-ending VM) — ✅ **have the vehicle now: `CLUE.iso`** (carded in `docs/disc_sweep.md`) | "**Multiple endings**" / "choose the ending" / "interactive" | ***Clue* (1985)** — the classic 3-endings + random-ending disc; *Final Destination 3 – "Choose Their Fate"*; *Mr. Brooks* | Endings select/branch correctly; random ending varies |
| 5 | **DVD board game / interactive VM stress** (GPRM, RNG, NavTimer/SPRM9, UOP) | "DVD game" / "interactive game" | ***Atmosfear: The Gatekeeper*** (heavy timer/VM), *Trivial Pursuit DVD*, *Dungeons & Dragons DVD game*, kids' interactive discs | Timers fire, randomness varies, no VM stalls |

---

## Tier 2 — good breadth coverage, common and cheap

| # | Quirk / gap | What to look for | Example titles | Verify |
|---|---|---|---|---|
| 6 | **Many titles / "Play All" PGCs** (title enumeration, PGC chaining, program maps) | **TV series box sets** — dozens of episode titles + "Play All" | *The Simpsons* / *Friends* / *Seinfeld* / *The Sopranos* season sets | Title select + Play-All chains episodes correctly |
| 7 | **Karaoke / heavy subpicture + CHG_COLCON** (subpicture colour-change commands, unexercised) | Any **karaoke DVD** (word highlight / bouncing-ball colour cycling) | *The Singing Machine* discs, *Karaoke Bay*, *The Karaoke Channel* | Highlight colour animates in step (CHG_COLCON) |
| 8 | **4:3 and mixed-aspect** (non-anamorphic + per-title aspect) | Classic 4:3 TV/film; discs mixing 4:3 extras with a 16:9 feature | *I Love Lucy*, *The Twilight Zone*, older pre-'90s films | 4:3 renders correctly (HDMI + CRT); aspect switches per title |
| 9 | **All-rounder torture: elaborate menus + many tracks + games** | **Disney animated features** (many audio/subs, THX optimizer, set-top games, animated menus) | *The Lion King*, *Aladdin*, *Beauty and the Beast* platinum/SE | Menus, track lists, and any set-top game behave |
| 10 | **Unusual IFO / chapter counts** (parser robustness) | Discs known to stress DVD parsers | ***Ghostbusters*** (libdvdread's own `nr_of_ptts < 1000` assertion note — `ifo_read.c:2308`), discs with 99+ titles / 500+ chapters | Reader parses without wedging / mispicking |

---

## Tier 3 — rare, hard to target, or low value (opportunistic only)

| # | Quirk / gap | Note |
|---|---|---|
| 11 | **Parental multi-rating** (PTL_MAIT + SPRM13 — plays a different cut by rating setting) | Genuinely rare and hard to identify from the cover; a few unrated/theatrical-on-one-disc releases use it. Low priority (region/parental are intentionally not enforced here). Grab only if you spot one. |
| 12 | **UDF-only image** (reader is ISO9660-based) | Not a per-title trait — it's a mastering choice, and almost every DVD-Video is a **UDF-Bridge** (UDF + ISO9660) that our reader already handles. Pure-UDF-no-ISO is rare; can't shop for it by title. Opportunistic / skip. |
| 13 | **Multi-angle beyond MiB** (more `sml_agli` chains) | MiB already covers the path. Extra examples: music DVDs with band-member angle cams, instructional discs (golf/yoga) with multi-angle. Nice-to-have, not a gap. |
| 14 | **DTS variants** (DTS-ES, DTS 96/24 — passthrough) | T2 already covers DTS passthrough. A DTS 96/24 concert disc would exercise a variant, but it's the same IEC 61937 path. Low priority. |
| 15 | **Closed captions (line-21)** | CC is user_data in the MPEG stream, normally decoded by the TV, not the DVD core — likely out of scope. Note, don't chase. |

### Non-issues (don't buy for these)
- **Dual-layer / RSDL layer break** — the layer change is a *physical-disc* seek; in an `.iso`
  rip it's just contiguous sectors, so it exercises nothing new.
- **DVD-Audio** — a separate format from DVD-Video; the core plays DVD-Video only.
- **CSS / region locks** — CSS is stripped at the PC rip step; region is intentionally free.

---

## Highest-leverage single picks

If you only grab a few: **(1) one concert DVD with an LPCM track**, **(2) one anime box set**
(tracks + karaoke subs), **(3) *Clue* or *Final Destination 3*** (branching), and **(4) one DVD
game** like *Atmosfear* or *Trivial Pursuit DVD*. Those four cover the biggest untested corners
(LPCM, multi-track/subpicture, PGC branching, VM/timer stress) with popular, cheap discs.
