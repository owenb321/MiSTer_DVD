# Next session: the IEC 61937 startup / track-change lock flap

> **STATUS 2026-08-31 (session 2, `feature/bs-flap-probe`): ✅ CLOSED —
> root cause measured, fixed, HW-confirmed on optical and HDMI (title start,
> track changes, menus, A/V sync). This file is now history only.** The drain watchdog read the
> wrapper's A/V-sync hold as a wedged consumer, left the STD backpressure
> disengaged, and the ring dropped ~1130 frames in the first 46 s of a title —
> each dropped span a forward PTS hole = a multi-second wire gap = the flap.
> ⚠ The debug options this file names (`HDMI BS Variant`, `BS Hold Style`) were
> REMOVED in the pre-release cleanup, along with `BS Release Bias`.
> See `docs/iec61937.md` "FLAP ROOT CAUSE" (which also retires this file's
> `cur_period` lead and the "fill is not the variable" claim). Fix =
> `hold_active_o` re-arms the watchdog while the wrapper holds by design.

Paste the block below to start. Everything it claims has been verified on hardware
unless marked otherwise.

---

## Prompt

I want to fix a long-standing bug in the DVD core's IEC 61937 passthrough:
**the AV receiver does not lock cleanly at the start of a title, or after an
audio-track change.** It flaps between naming the codec (Dolby Digital / DTS) and
showing no decode, on **both** optical S/PDIF and HDMI. A **chapter seek locks it
immediately** and it stays locked.

Read `docs/iec61937.md` first — specifically "startup / track-change flap is still
open", the fj#110 root-cause narrative above it, and the "one-shot hold gate" entry.
That file already records what has been tried and what it cost. Reading it has twice
beaten reasoning from the RTL in this investigation.

### Established, do not re-derive

- **PRE-EXISTING, not caused by the HDMI bitstream work.** The shipped v0.2.0 build
  (`releases/DVD_20260830.rbf`) flaps over optical in exactly the same way. That is
  the control build — keep using it.
- **The hold FILL is not the variable.** `P1O[50:49] BS Hold Style` selects PCM
  silence / non-PCM hold / a real IEC 61937 **pause burst** (Pc=3). All three flap
  identically. Pc=3 is therefore a *tried negative*, distinct from round 1's Pc=0
  null bursts — this receiver does not treat a pause burst as lock-holding.
- **The A/V-sync hold must NOT be touched.** It is the continuous pacing loop, not a
  startup aligner. Making it one-shot fixed the lock and broke A/V sync (audio ~1 s
  ahead of video) — the two are the same change. The chatter *is* the controller
  working. Anything that quiets the hold will desync audio.
- A chapter seek fixes it while changing no fill at all, which points the same way:
  what a seek changes is the **flush and the re-anchor**, not the burst contents.

### The strongest untested lead

`cur_period` in `dvd/iec61937_wrap.sv` resets to `PERIOD_AC3` (1536) and only updates
once a frame is queued. So a **DTS** track's first real burst jumps the Pa/Pb
repetition grid 1536 → 512 — the exact event `docs/iec61937.md` root cause 2
identifies as dropping receiver lock. It fits startup and track changes, and not
chapter seeks (a period is already latched by then).

⚠ It does not obviously explain an AC-3-only case, so **confirm which codecs actually
flap before building anything.** If AC-3 alone flaps, the period hypothesis is wrong
and the next suspects are repeated STC re-anchors at title start (FP → title) and
ring underrun before the buffer primes.

### Method that has been working

1. **Measure before changing.** Three rounds were lost here to fixing something
   without first checking whether it was a regression; one flash of v0.2.0 settled it.
2. **Instrument rather than infer.** Reading back what the hardware itself reports
   (`0x42` on the ADV7513) ended a four-round guessing spiral. If you need a fabric
   instrument, the debug overlay is compiled out — see `CLAUDE.md`.
3. **One Quartus build at a time.** Two concurrent flows share `output_files/` and
   corrupt each other; the failure signature is a "Successful" fitter followed by
   `Can't run TimeQuest — Fitter failed or was not run`.
4. **Prefer one build with a runtime A/B over N builds each testing one guess** — a
   fit is 15–40 min, an OSD toggle or an ini key is seconds.

### Useful state

- `bench/dvd/run_hdmi_bitstream.sh` — passthrough sim suite, currently green.
- `main/.build/MiSTer_DVDcss` logs to `/tmp/dvd_hdmi_audio.log` on the target.
- Debug options: `P1O[48:46] HDMI BS Variant`, `P1O[50:49] BS Hold Style`.
- Control build: `releases/DVD_20260830.rbf` (v0.2.0).

### Definition of done

Receiver names the codec and holds it within a second or two of a title starting,
and across an audio-track switch, **without** a chapter skip — on optical and HDMI —
with **A/V sync unchanged** (check on interlaced analog out, where the earlier
desync was caught). Then update `docs/iec61937.md`, the README limitation, and the
fj#110 gate annotation.
