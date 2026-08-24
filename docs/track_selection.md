# DVD Audio / Subtitle Track Selection (Phase 10)

Status: **✅ HW-CONFIRMED (2026-07-10, PR fj#100)** — track switching + the audio-switch
A/V re-sync (round 3) both confirmed working on real hardware (MiB).

DVD track *routing* already worked before this phase — `ps_demux` filters to one
audio substream (`aud_track`) and one subpicture substream (`sp_track`), subtitles
decode and render with the disc's authored IFO palette (`spu_decode` +
`subpic_blend` + `pgc_palette`, HW-confirmed PR fj#71/#73). What was missing was
*enumeration*: the core had no idea how many audio/subpicture tracks a title
actually has, so the OSD offered a blind 0–7 and a pick past the real count fed
`ps_demux` a substream id that doesn't exist → the demux dropped everything →
silence / no subtitle.

Phase 10 parses each title's IFO stream attributes (count, codec, channels,
language), **bounds the selectors to the real track count**, and moves selection
onto **gamepad cycle buttons** (the authentic DVD-remote surface).

## Why gamepad buttons, not the OSD

The original plan (roadmap Phases 10/11) assumed the track list would live in the
MiSTer OSD "at near-zero fabric cost." That premise is **wrong**: MiSTer `CONF_STR`
value labels (`"O68,Audio Track,0,1,2,3…"`) are **compile-time static strings**.
`sys/hps_io.sv` offers `status_menumask` (hide whole items at runtime) and a
numeric `info` popup, but **no mechanism to inject per-disc language strings**
("English 5.1", "Français") into an item's value labels. So a dynamic,
disc-specific track list simply cannot be an OSD menu item.

The DVD-remote answer is a **cycle button**: press "Audio" to rotate through the
available audio tracks, "Subtitle" to rotate through subtitle tracks (and off).
This needs no dynamic OSD strings, matches how a real set-top player works, and the
on-screen "which track / what language" indicator becomes a Phase-11 in-video
overlay (reusing the subpicture blend), fed by the per-track metadata this phase
exposes.

Even without that indicator, Phase 10 is HW-testable: an audio switch is *audible*
(MiB: English 2.0 / English 5.1 / French / English commentary) and a subtitle
switch is *visible* (en/fr/es/en / off).

## IFO layout (verified against real MiB VTS_21)

All fields BIG-ENDIAN, within the VTS IFO's first sector (VTSI_MAT). Offsets from
libdvdread `ifo_types.h` `vtsi_mat_t`, confirmed byte-exact by
`tools/nav_extract.py --vts-attr`:

| Field | Offset | Size |
|---|---|---|
| `nr_of_vts_audio_streams` | **515** (0x203) | u8 |
| `vts_audio_attr[8]` (`audio_attr_t`) | **516** (0x204) | 8 B each |
| `nr_of_vts_subp_streams` | **597** (0x255) | u8 |
| `vts_subp_attr[32]` (`subp_attr_t`) | **598** (0x256) | 6 B each |

`audio_attr_t` (first bytes only):
- byte0 = `[audio_format:3][multichannel_ext:1][lang_type:2][application_mode:2]`
  (MSB→LSB). `audio_format`: 0 = AC-3, 2 = MPEG-1, 3 = MPEG-2 ext, 4 = LPCM, 6 = DTS.
- byte1 = `[quantization:2][sample_freq:2][unknown:1][channels:3]`. **Channel count
  = `channels + 1`.**
- bytes 2–3 = `lang_code` (2 ASCII chars, valid when `lang_type == 1`).
- byte5 = `code_extension`.

`subp_attr_t`:
- byte0 = `[code_mode:3][zero:3][type:2]`.
- bytes 2–3 = `lang_code` (2 ASCII chars).

MiB VTS_21 dump: audio = {AC3 2ch en, AC3 6ch en, AC3 2ch fr, AC3 2ch en};
subp = {en, fr, es, en}.

Only the low **8** substreams of each range (0x80–0x87 audio, 0x20–0x27 subp) are
routable — `ps_demux`'s `aud_track`/`sp_track` selects are 3-bit — so the parse
stores at most 8 of each even though the subpicture table has room for 32.

## RTL

### `dvd/dvd_iso_reader.sv` — the S_ATTR sweep

The reader already reads the title VTSI_MAT sector at `S_PGC_BEGIN` (to fetch
`vts_pgcit`@204 / `vts_ptt_srpt`@200). Both attribute tables live in that same
resident sector, so the parse is a small sweep hooked in **before** the PGC parse
resumes:

- `S_PGC_BEGIN` loads the VTSI_MAT sector as before, but sets `fetch_ret = S_ATTR_RD`
  and stashes the real next state in `attr_resume` (`S_PGC_MAT` or `S_PTT_MAT`). The
  `@200`/`@204` rbuf shadow fetch is untouched (the sweep reads `parse_buf`
  directly), so the resume state proceeds exactly as before.
- `S_ATTR_RD` / `S_ATTR_CAP` walk `parse_buf`: audio count @515 then
  `vts_audio_attr[8]` @516 (stride 8), then subp count @597 then `vts_subp_attr` @598
  (stride 6, first 8). Two cycles/byte (address then latch the 1-cycle-late
  `pb_rdata`), ~120 cycles total, one-off at the title mount. Then `→ attr_resume`.

**Fit discipline:** the sweep reads `parse_buf` (the sync-read M10K) through the
existing `pb_raddr` mux — a single registered read port, NOT an async multi-offset
register file (which blew ALMs to 226% in the ISO-navigator bring-up). The per-track
store is 8 audio + 8 subp small registers, read by emu through one indexed mux
(`attr_a_sel`/`attr_s_sel`) — again a single select, not 30 async offsets.

Outputs: `audio_ntracks`/`subp_ntracks` (1..8, **default 8** = unconstrained until a
real IFO parses, so non-ISO / linear playback is unchanged), and a selected-track
readout (`attr_a_fmt`/`attr_a_ch`/`attr_a_lang`, `attr_s_lang`) for the Phase-11
indicator. The counts reset only on `rst_n` (title-level state — must survive seeks;
cf. the `pgc-palette-seek-reset-bug` lesson) and are re-parsed at each title mount.

### `dvd/emu.sv` — gamepad selection + clamp

- New buttons **B7 "Audio"** (`joystick_0[10]`) and **B8 "Subtitle"**
  (`joystick_0[11]`), edges `audio_edge`/`sub_edge` (same idiom as the Angle button).
  `CONF_STR` `J1` gains `,Audio,Subtitle`.
- Internal state replaces the OSD selectors: `aud_cur` cycles `0..audio_ntracks-1`;
  the Subtitle button cycles `off → 0..subp_ntracks-1 → off` (`sub_on` + `sub_idx`).
  Both bounded by the parsed counts, so a cycle can never land on a missing stream.
  Reset to {track 0, subs off} on a fresh mount.
- `aud_track_eff`/`sp_track_eff` clamp the effective select (including a VM `SetSTN`
  pick) to `min(sel, ntracks-1)`. The VM↔user last-writer-wins arbitration is kept;
  the "user moved" signal is now the button edge instead of an OSD status change.
- The old OSD items `O68` (Audio Track), `O[15]` (Subtitle on/off), `O[26:24]`
  (Subtitle Track) are **removed** from `CONF_STR`; those status bits are freed. The
  subtitle enable is now `sub_on`.

### Audio-switch A/V re-sync (HW round 1 follow-up)

HW round 1 (MiB) confirmed track switching works, but **switching the audio track
drifted A/V a little**, and a transport seek/chapter snapped it back. Root cause: a
switch changes which substream `ps_demux` forwards, so the audio pipeline restarts
at a new fill level while the video STC keeps running — the audio playback phase
(set at the PCM-FIFO exit, per the lip-sync saga) is established for the *old* track
and no longer matches. A seek fixes it because `seek_ack` pulses **`load_flush`**
(drain the audio pipeline + re-anchor `av_sync`'s STC).

**Round 1 (reverted — made it worse):** pulsing `load_flush` on the switch also
reset `ps_demux` — but `ps_demux` carries the **video** bitstream on the same byte
stream, and a mid-PES reset **corrupts the picture** (black-then-green frame) with no
vbuf re-lock to recover. The `keep_vbuf` comparison was wrong: a menu transition also
*seeks* to a clean pack boundary, so its demux restart is clean; a mid-stream audio
switch is not.

**Round 2 (right idea, didn't fit):** re-sync the audio chain — `ac3_reframer`,
`audio_ring`, `dvd_audio_decode`, `av_sync` — via a dedicated `aud_resync` reset,
leaving `ps_stream_fifo`/`ps_demux` (video) untouched. Functionally correct, but the
new **4-module high-fanout reset net** failed to route on this fit-congestion-marginal
design (~87% ALM): Quartus "Can't fit" / "Final fitting attempt was unsuccessful"
(Error 11802 / 170143) — **twice**. (Builds 1 & 2, without the net, fit fine.)

**Round 3 (the fix):** same idea, **minimal scope** — `aud_resync` (via
`aud_rst_n = pipe_rst_n & ~aud_resync`) resets only **`audio_ring` + `dvd_audio_decode`**
(2 modules), which is all the drift fix needs:
- the **ring** reset DISCARDS the old track's queued frames, so the first frame the
  decoder sees is a NEW-track frame with the correct PTS (a decoder reset *alone*
  would re-phase to the stale old-track PTS still in the ring = no fix);
- the **decoder** reset drains the PCM FIFO so its drain-gate re-establishes the
  playback phase against the (video-continuous, still-correct) `av_sync` STC.

`av_sync` is **not** reset — its STC never drifts across the switch (video is
continuous) and `nco_trim` is retired, so it's telemetry-only. `ac3_reframer` is
**not** reset — it self-heals on the next `0x0B77` boundary (the ring discards its
transient output during the reset window anyway). Cutting the new reset net from 4 to
2 modules is what lets it route. `ps_stream_fifo`/`ps_demux` still on `pipe_rst_n`
(video untouched — no green frame). Safe against a shared-stream stall because
`audio_ring.almost_full` (which gates `ps_demux.aud_ready`) is combinational from
`fill`, which resets to 0 → low. Subtitle switches do **not** trigger it (subpicture
timing is STC-referenced independently of audio).

## Tooling & tests

- `tools/nav_extract.py --vts-attr --vts N [--attr-hex FILE]` dumps a title's
  audio/subpicture attribute tables and writes the VTSI_MAT sector as a `$readmemh`
  fixture (with the expected counts/langs in the comment header).
- `bench/dvd/iso_reader_attr_tb.sv` serves the real MiB ISO metadata (so nav selects
  VTS_21) plus the real VTS_21_0.IFO VTSI_MAT sector, runs the sweep, and checks the
  parsed counts + per-track codec/channels/language **byte-exact** against the disc.
- Regression: all `iso_reader_*`, `ps_demux*`, `nav_*` suites stay green (the new
  reader ports are unconnected in the older tbs).

## HW gate (MiB, VTS_21)

- Press **Audio** during playback → audio cycles English 2.0 → English 5.1 → French
  → English commentary → back to English 2.0 (4 tracks, no silence, no garbage).
- Press **Subtitle** → off → English → French → Spanish → English → off (visible).
- A cycle never lands on a non-existent track (bounded by the parsed count = 4).

## Follow-ups

- **Phase 11: on-screen track indicator** ("AUD 2/4 · fr") using the `attr_*` readout
  + the subpicture blend. This is the piece the OSD *cannot* do.
- Menu-domain title entry (VM First Play path) currently leaves the counts at the
  default 8 if the title is reached without passing `S_PGC_BEGIN`; verify on MiB with
  `O[1]` on. Safe (default = unconstrained), but tighten if a menu-entry title needs
  bounding.
