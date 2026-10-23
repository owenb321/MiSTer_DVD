# Real-time play-and-measure harness

**Status:** 🔧 host side working end to end on the rig with the capture card (2026-10-23).
The nav event FIFO (fabric) is a separate slice; see its section when it lands.
**Tools:** `tools/disc_timing.py`, `tools/hil_play.py`, `tools/hil_timeline.py`.
**Built for:** issue #176 (Mad Dog McCree). Every fix there needed another round of the
maintainer play-testing by hand, and each round found a timing problem that the bench
sims and the NAV-packet replays had not predicted.

The harness plays an interactive disc on the real board in real time. It fires inputs at
chosen moments and records the capture card. Then it puts the captured pictures, the
captured audio, the core's telemetry, the presses and the disc's authored timing on one
clock and scores the outcome. Operating notes are in `.claude/skills/hil-testing/SKILL.md`
and the rig mechanics in `docs/hil_harness.md`.

## Decisions and why

| Decision | Why | Rejected |
|---|---|---|
| Timed presses are decided **on the board** by a Python agent. The host only deploys, records and analyses. | An ssh round trip is 1–2 s and the capture is ~0.13 s behind, so a press that must land within ±30 ms of a picture cannot be steered from the host. The agent fires within 15–30 ms of plan. | Host-side vision loop for timed shots. It is kept for slow navigation and checks only. |
| **The capture is the judge.** Scoring (which branch, pictures shown, audio present) comes from the recording. | It is the only thing that sees what a player sees, and it needs nothing inside the core. So it scores every build alike, including v0.9.1 and the earlier dev builds that predate any instrument. An A/B is only fair if both arms are measured the same way. | Scoring from new telemetry. That cannot measure the controls. |
| **Telemetry and the nav FIFO are the explanation** (why a branch was taken, when buttons went live). | One-cycle events (cell-command dispatch, button activation) are invisible to 20 ms snapshots, and only an STC-stamped FIFO keeps their order. | Eight more snapshot words. They are fine for navigation but lose pulses. |
| **Reference = the authored windows** (`hli_s_ptm`/`e_ptm`, the cell command). | They are the contract. Mad Dog was authored against set-top players that honour them, and the maintainer hits every window on one. | A libdvdnav capture. It only adds one implementation's choices about what the spec leaves open: answering buttons on NAV read (where `EARLY_LEAD` came from) and the command at the read end. Those are exactly what is suspected wrong, and its timing depends on host buffering. A short set-top recording is the tie-break if a scene contradicts its authored window. |
| **Navigate by playing the disc's own flow**, closed on telemetry predicates. | GPRM state (lives, branch history) is part of the scene. A direct VM jump would reach a different scene from the one a player reaches. | Debug "goto VTS/PGC" commands. Blind timed key sequences, which were fragile. |

## The three clocks and how they are tied

| Stream | Clock | How it reaches host wall time |
|---|---|---|
| Capture frames and samples | host wall time | `ffmpeg -f v4l2 -ts mono2abs … -copyts` (and Pulse's own wall stamps). The container PTS **is** host time, at 1 ms resolution. ⚠ `-t` must be given per input: an output `-t` with `-copyts` writes an empty file. |
| Telemetry rows, presses, agent events | board `CLOCK_MONOTONIC` | 15 ping-pongs over the agent's ssh stdin/stdout before the scenario. The lowest-RTT one sets the offset, with an uncertainty of RTT/2. Measured RTT is 0.9–1.1 ms on the LAN, so ±0.5 ms. |
| Disc PTS | MPEG PTS of the picture on screen | `hil_timeline.py align` identifies every captured frame's (cell, PTS) by matching it against thumbnails decoded from the cell's own sectors. |

**Capture latency** (`report`, per run): for picture k after the agent's `base`, the board
time its pickup counter reached k is set against the capture time that picture first
appeared. The first run measured a median of **0.129 s** (IQR 0.115–0.145 s over 299
pictures). That figure spans the core's pickup→pins delay *and* the card, so removing it
gives the picture the core had picked up at a press. That is the core's own "now", which
is what button timing is judged against, not what a viewer's eye saw at that moment.

## Picture identification (`hil_timeline.py align`)

- **Reference:** each cell's sector range (`disc_timing.py`) is cut out of the image and
  decoded by ffmpeg into 48×32 grey thumbnails stamped with their MPEG PTS (`-copyts`).
  Cells are kept apart because the PTS restarts at most Mad Dog joins.
- **Capture:** the active picture is found by `cropdetect` majority vote. The core
  pillarboxes 4:3 inside the raster: two captures measured 532×480 at x=94 and 528×480
  at x=98, so the area is detected rather than hard-coded. A central band of it is compared, clear of overscan, the HUD blocks in the
  top-left and the transport bar.
- **Match:** normalised correlation of every capture frame against every reference
  picture. Among matches within 0.01 of the best, the one that continues the previous
  frame wins. That tie-break exists because hit and miss branches share footage; without
  it, two identical cells flicker.
- **Saying "nothing":** below `--min-score` (0.80) a frame is `cell: null`, never the
  nearest guess. A uniform frame is `flat`. `margin` (best minus the best match at least
  3 pictures away) marks static shots whose PTS is uncertain. Pace measurements use only
  frames with margin > 0.02.

## What `report` measures

- **Junctions:** the last picture shown of the old cell against its last decoded
  reference picture ("unshown" = authored but never displayed), the gap, and the first
  picture of the new cell.
- **Pace steps:** within a cell, a step of more than 0.1 s in `t − pts` between
  consecutive confident matches. Up is a stall (a picture held), down is a skip (pictures
  never shown).
- **Audio:**
  - The A/V offset comes from envelope correlation against the reference audio, placed
    by the video mapping. It includes the capture chain's own skew; `lipsync_measure.py`
    calibrates that separately.
  - Every stretch where the reference cell is loud (> −35 dB) and the capture is silent
    (< −60 dB) is listed, flagged **EXACT ZERO** when the capture holds digital zero.
    That is the saloon's "gunshot missing" signature.
  - Self-test: one muted second in a real capture is reported as EXACT ZERO, and only
    there.
- **Presses:** each tap placed on the picture the core had picked up.

## Scenario format (`hil_play.py`)

See the docstring. Steps are `wait` (a Python predicate over the newest telemetry
sample: `live`, `menu`, `pause`, `still`, `pictures`, `aud_frames`, and `nav` once the
FIFO exists), `sleep`, `key`, `key` + `at_pts` (the picture-count fit inherited from
`hil_shot_sweep.py`), `base`, and `mark`.
- `"$NAME"` values are filled in by `sweep --vary NAME=a,b,c`.
- `--rbf` is repeated to A/B builds.
- Keep scenarios with a board image path out of the repo: the path names a share layout,
  and it differs between rigs.

Taps go through the key daemon's FIFO as single `key <code> 30` writes; the queued `keys`
command costs 170 ms per key. Launch aborts if this launch's `mount result` line says
FAILED. A failed mount still tells the core a disc arrived, which otherwise shows up as a
confusing timeout.

## Rigs

- The capture card is on **.236**, the maintainer's rig. Use it only when the maintainer
  says so. .201 has no capture path.
- After a reboot, the rig's CIFS share must be remounted with its own
  `Scripts/cifs_mount.sh`.
- The share layout differs between rigs (`cifs/DVD/...` vs `cifs/games/DVD/...`).
- Check `mister.py state` first, announce to peer sessions, and `mister.py restore` after.

## Findings so far

- **v0.9.1, first shootout, Select at 36.1:** HIT (cell 2 → 3 → 6), matching the hand
  table in `docs/dvd_nav.md`.
- **v0.9.1 cuts command-driven cell ends.** At cell 2→3 and 3→6, the last 0.167 s
  (5 pictures) of the cell never reaches the screen; cell 2's last decoded picture is
  37.518 and the last shown is 37.351. The seamless 1→2 junction is complete. This is
  consistent with the pre-#176 cell command running at the reader's cell end.

## Known limits / next

- `at_pts` maps PTS through picture count since `base`, so it is valid only on one
  continuous timeline. After a PTS restart (most later Mad Dog cells) it needs the nav
  FIFO's STC stamps, or a `base` re-armed per cell.
- Navigating deep into a game needs nav state (VTS/PGC/cell). On builds without the FIFO,
  routes are time- and flag-based.
- Thumbnail matching assumes the capture shows the whole picture. A zoom or crop setting
  needs `--box`.
