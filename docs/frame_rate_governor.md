# Frame-rate governor — design spec (playback-speed fix)

> **Related (2026-06-28):** audio is now genlocked to the video presentation timeline
> by **`docs/av_sync.md`** (`dvd/av_sync.sv`). The governor still paces video to the
> display refresh; av_sync builds an STC from that same refresh cadence (anchored on
> `vid_pts`) and slews the audio NCO to it. The governor's NTSC-only `SHOW_N=2` and the
> av_sync `REFRESH_MHZ=59940` share the same PAL TODO (drive both from `frame_rate_code`).

> ✅ Status (2026-06-25): **RE-IMPLEMENTED on the clean 54 MHz main** (branch
> `feature/av-sync`), in `dvd/resample_addrgen.v`. Gates the frame-advance sites with
> `ofv_paced = output_frame_valid & frame_due`, and the STATE_REPEAT persistence path
> re-scans the last image while a frame is not yet due (resolves the "underrun" open
> question — that path already existed). Holding a frame backpressures the shared
> demux, so video AND audio throttle together → **A/V locks** (HW-confirmed in sync).
>
> **v1 (cycle counter) — REPLACED.** `PACE_N = 1,801,800` 54 MHz cycles. HW: A/V was
> in sync but video ran **~75%** speed (choppy audio) and **interlaced ~50%**. Cause:
> a frame is only released at the end of a display scan, so a free-running counter
> quantizes the period to scan boundaries (~75% + jitter), and interlaced's 2
> field-scans/frame halved the release rate.
>
> **v2 (display-refresh-locked) — ✅ HW-CONFIRMED WORKING (`DVD_governor3`).**
> Count completed image scans (each = one display refresh: a progressive frame OR an
> interlaced field) at the image's last macroblock; release every **SHOW_N=2**
> refreshes. On 59.94 Hz that is exactly 29.97 fps for BOTH progressive (frame + 1
> persistence re-scan) and interlaced (top + bottom field) — no beat/jitter, and
> interlaced matches progressive. PAL 25/50 Hz would use a different SHOW_N.
> **HW result:** DVD/progressive clips play smooth at full speed with audio in sync
> the whole time (no stutter/pause). The pacing lives ONLY in the STATE_REPEAT hold +
> the refresh counter; `STATE_INIT` advances on `output_frame_valid` so scanning
> always bootstraps (a `DVD_governor2` build that also gated STATE_INIT on frame_due
> deadlocked at startup — no video, watchdog-pulsed audio — fixed in `governor3`).
>
> **UPDATE (2026-07-02, `feature/film-32-governor-cadence`) — film 3:2 cadence added
> (SIM-VERIFIED, HW-PENDING).** The flat `SHOW_N=2` deadline (`frame_due`) is now a
> per-frame **`cur_show`**: a soft-telecined progressive frame with `repeat_first_field`
> is held for **3** refreshes instead of 2 (`show_next = (progressive_sequence &&
> ~interlaced && repeat_first_field) ? 3 : SHOW_N`, latched per frame at pickup). This
> gives 24 fps film its correct 3,2,3,2 cadence (2.5 avg = 60/24) — previously it ran
> ~26.7–30 fps because upstream only granted the 3rd refresh on `rff && top_field_first`
> (wrong for progressive frame display, where `tff` is irrelevant). The extra refresh
> rides the existing persistence re-scan, so both `tff` cases display identically and the
> image-build is untouched. Also banks a `film_slack` credit per `rff` frame so the
> frame-drop governor (`O[12]`) no longer counts film's structural short-window misses as
> late (see `docs/motcomp_throughput.md`). Only the progressive-display path changes;
> interlaced/field modes keep `SHOW_N` (no 480i regression).
>
> NEXT-SESSION follow-ups: (1) PAL/25fps → `SHOW_N` from `frame_rate_code` (the
> originally-planned v2 threading); (2) ~~film 3:2~~ **DONE (above)** — 24 fps film paces
> correctly via `cur_show`; (3) 24-bit LPCM (ps_demux must
> forward quantization); (4) DTS (libdca + syncframe reassembly like AC-3).
>
> Daemon note: the ALSA device that actually reaches HDMI is **"default"** (not
> `hw:0,0`, which opens but doesn't mix through); the daemon defaults to it now.
>
> ⚠️ Status (2026-06-22): **REVERTED OUT OF MAIN (revert of PR fj#12).** Two problems:
> (1) the governor branch was based on the `decoder-clock-81` branch, so merging PR fj#12
> dragged the rejected **81 MHz** clock into main (green chroma fringe); (2) on hardware the
> governor **slows 480p at 54 MHz** (PR fj#10 @54 is full-speed; +governor @54 drags). Main is
> back to the clean 54 MHz / no-governor baseline. This doc is kept as the design reference for
> **redoing** the governor properly: rebase on 54 (NOT 81), and fix the 480p slowdown (the
> decode-limited-edge interaction). The "v1 MERGED/confirmed" notes below are historical.
>
> Status (2026-06-22): **v1 IMPLEMENTED & MERGED (PR fj#12)** — hardware-confirmed: SD/susi now plays
> at correct speed, D1/matrix unaffected. v1 hardcodes PACE_N for 29.97 fps in `dvd/resample_addrgen.v`.
> **NEXT = v2:** pick PACE_N from `frame_rate_code` (thread vld→regfile→resample, copy `resample.v` +
> `mpeg2video.v` to `dvd/`, swap qsf) so 25/24/23.976 sources are also correct automatically. The
> "OPEN QUESTION" below is RESOLVED (persistence path feeds the display while paused — no underrun).
>
> Status (2026-06-22): DESIGNED, not yet implemented. The decoder-clock fix (27→54 MHz, merged)
> made D1 full-speed but **easily-decoded content (susi/SD) now plays too fast** because the upstream
> decoder has **no rate control** — it advances frames as fast as it can scan them out, calibrated for
> clk≈27. This spec paces frame output to the source rate so speed is correct at any compute clock.

## Approach (approved: integer ratios first, approximate film)
Hold each source frame for **N = round(clk_dec_Hz / source_fps)** compute-clock cycles, then release
the next. `clk_dec` is exactly 54.000 MHz, so N is exact. Let the display show the current frame
asynchronously (it repeats it until the next is released). This needs NO display-vsync dependency and
NO pulldown math for a first cut.

N per rate @ 54 MHz:
| frame_rate_code | fps        | N (cycles) |
|-----------------|------------|------------|
| 1               | 23.976     | 2,252,250  |
| 2               | 24         | 2,250,000  |
| 3               | 25         | 2,160,000  |
| 4               | 29.97      | 1,801,800  |
| 5               | 30         | 1,800,000  |
| 6               | 50         | 1,080,000  |
| 7               | 59.94      |   900,900  |
| 8               | 60         |   900,000  |

**No-regression property:** the gate only ever *slows* content that out-decodes the cadence. Matrix/D1
is decode-rate-limited (frames arrive slower than N), so `frame_due` is already true when each frame
lands → released immediately → matrix unaffected. susi/SD (frames arrive faster than N) is held to N.

## Injection point (verified)
`rtl/mpeg2/resample_addrgen.v` (copy to `dvd/`). The frame-advance gate is `output_frame_valid`:
- FSM `STATE_INIT: if (output_frame_valid) next=STATE_NEXT_IMG; else stay` (line 172) — this is the
  per-loop frame pickup.
- `output_frame_rd` (consume next frame) = `(state==STATE_INIT) && output_frame_valid` (line 222).
- Several STATE_INIT setup blocks gate on `output_frame_valid` (lines 264, 403, 411, 417).
- `persistence` repeat path (line 180) reuses the last image when no new frame — **persistence
  defaults to 1** (`regfile.v:463`, never overwritten since emu ties off reg writes), so the
  repeat-last-frame behavior is available.

Plan: compute `frame_due` from a pace counter, form `ofv_paced = output_frame_valid && frame_due`,
and substitute `ofv_paced` for `output_frame_valid` in the frame-advance triggers (172, 222, 264, 403,
411, 417 — and 180 so it repeats while not-due). Counter:
```
reg [21:0] pace_cnt;  wire frame_due = (pace_cnt >= PACE_N);
wire ofv_paced = output_frame_valid && frame_due;
always @(posedge clk)
  if (~rst) pace_cnt <= 0;
  else if (clk_en) begin
    if ((state==STATE_INIT) && ofv_paced) pace_cnt <= 0;   // released: restart interval
    else if (~frame_due)                  pace_cnt <= pace_cnt + 1'b1;
  end
```
v1: `PACE_N` a localparam (default 29.97 = 1,801,800) — one-file change, proves the concept, can't
regress matrix. v2: thread `frame_rate_code` (vld→regfile, exists as a wire in `mpeg2video.v`) down
through `resample.v`→`resample_addrgen.v` (copy all three to `dvd/`, swap the qsf entries) and pick
PACE_N per source rate via the table above. v3 (optional): true 3:2 pulldown for film cadence.

## OPEN QUESTION to resolve BEFORE coding (the one real risk)
Does the display read a **persistent full-frame buffer** that resample writes (`disp_wr_addr/_dta`
into the framestore), or a **streaming FIFO** (e.g. pixel_queue) that underruns if resample pauses?
- If persistent full-frame: holding the FSM at STATE_INIT (not-due) just freezes the last frame in the
  buffer → display repeats it cleanly. **Governor works as designed.**
- If streaming/underrun: pausing resample starves the display → glitch/black while held. Then the gate
  must instead drive the persistence *repeat* path (re-scan last_image every display period while
  not-due) rather than sit idle at STATE_INIT.
Trace `disp_wr_*` consumers and the display read path (syncgen/pixel_queue/mixer) to decide. This is
the only thing standing between this spec and a confident one-file v1 build.

## Test plan
- Build v1 (PACE_N=29.97). HW: susi should slow to ~30fps (correct if susi is 30fps); matrix unchanged.
- Tune PACE_N for susi's actual rate if needed (localparam, quick rebuild) — confirms the mechanism.
- Then v2 (frame_rate_code threading) for automatic per-content correctness on both 240p and 480p.
