# mpeg2fpga Decoder Audit — 2026-08-26

**Trigger.** The pixelated-menu-still fix (branch `fix/picbuf-display-slot-alias`) found a
genuine upstream bug in `rtl/mpeg2/motcomp_picbuf.v` — a missing `~vld_last_frame` guard that
let the decoder write into the frame slot being displayed. This audit swept the rest of the
upstream decoder for more of the same, plus the other defect classes this fork has actually
hit on hardware (CE-domain mismatches, FIFO margins, counter wraps, netlist-semantics traps).

**Scope.** The `rtl/mpeg2/*.v` files in the active build (per `DVD.qsf`), plus the
fork-owned memory shims where the decoder's correctness depends on them. Display-side
(`dvd/resample_addrgen.v`, mixer/syncgen) and the drop/A-V machinery were NOT re-audited —
they have had dedicated multi-round HW sagas with their own TBs (see `docs/history.md`,
`docs/lipsync_pickup.md`, `docs/crt_480i.md`).

## Verdict

One real bug was found and fixed (the picbuf slot alias — see
`docs/dvd_menu_refinements.md` §5). The remaining sweep found **no further fix-now defects**:
the upstream design is defensively built in exactly the places that looked most dangerous.
Findings below are ranked; F1–F3 are robustness/cosmetic corners, F4–F6 hygiene.

## Audited and CLEAN (with the evidence that closed each)

- **Memory-address bounds (`mem_addr.v`).** The scariest class — a corrupt slice scribbling
  across frame slots — is already contained: macroblock x/y only ever advance by 0/+1 from a
  known origin (`:132-174`, anything else raises `error`), and every computed address is
  bounds-checked against `end_address` with errors redirected to the parked `ADDR_ERR` word
  (`:1176-1273`, `mem_codes.v:235`). Cross-slot writes are impossible even on garbage input.
- **getbits/vld advance interlock (`getbits.v:106`, `vld.v:1184-1191`).** `cursor` adds
  `advance` unconditionally in `STATE_READY`, which is only safe because the VLD's `clk_en`
  IS `vld_en` and its `advance`/`align` registers fall to 0 when frozen. Verified both halves.
- **VBUF ring + flush (`framestore_request.v:463-501`).** `vb_flush` outranks the increment
  paths; the whole chain (byte packer alignment, write fifo, pointers, read fifo) resets via
  `vbuf_rst`, so no stale beat survives a flush. Wrap arithmetic (incl. the `VBUF_END`/`VBUF`
  corner in `next_vbuf_full`) is correct. The no-back-to-back-writes holdoff's bitrate
  assumption is covered by the reader's designed backpressure (STD model).
- **FIFO overflow margins (`fifo_size.v`).** RLD prog_full leaves 2 free slots vs ≤1
  write/cycle and a ~1-cycle stop latency; MVEC likewise. An MVEC overflow would lose an
  `update_picture_buffers` (display pointer wedge → watchdog), so this margin matters — it
  holds. Years of upstream use + this fork's full-stream cosims agree.
- **FWFT skid buffers (`fwft.v`).** 3-slot capacity vs exactly 3 possible in-flight reads
  (traced cycle-by-cycle). The pixel_queue-class CE hazard is moot in the decode domain:
  `mpeg2video.v` wires `clk_en(1'b1)` everywhere except the VLD's `vld_en` (producer flow
  control, not a CE domain). The only real CE domain is dot_clk — where that bug already
  happened and was fixed (PR fj#65's CE-stretch).
- **framestore_response routing.** Lock-step tag+data fifos; desync impossible while the
  memory shim honours 1:1 request:response, which `mem_shim_burst` guarantees (BIST + TB).
- **Watchdog (`watchdog.v`).** Sound; the active-low `watchdog_rst` reading gotcha is already
  documented in CLAUDE.md.
- **`sync_reg` multi-bit 2FF.** Used only on quasi-static config (sizes, matrix
  coefficients); a torn word during a seq-header change is transient. Acceptable by design.
- **`second_field` recovery (`vld.v:2222-2226`)** — frame pictures force-reset it, so an
  illegal field count self-heals. Dimension changes mid-stream recompute `mb_width/height`
  continuously; oversized streams fall into the `ADDR_ERR` clamp above.
- **Double-`sequence_end` corner** — covered by `bench/dvd/motcomp_picbuf_tb.sv` scenario
  [D], passes with the fix in.

## Findings (ranked, none fix-now)

- **F1 — Partial pictures display on parse errors (upstream design, corrupt streams only).**
  `vld.v` error recovery (`STATE_ERROR`/`dct_error` → `STATE_NEXT_START_CODE`, `:930/:979`)
  abandons the rest of the slice/picture; the frame slot keeps stale content there and the
  picture is emitted normally at the next header — there is no picture-complete gate anywhere.
  Inherent to the architecture, self-repairing, and only reachable on nonconformant/corrupt
  input. Documented so nobody hunts a "half-decoded frame" as a fork regression.
- **F2 — The aux_frame swap shares the fixed bug's shape (`motcomp_picbuf.v:350-356`)** —
  unguarded by `~vld_last_frame`, so a seq_end whose retained coding type is B rotates the
  aux pair one extra step. Traced for a displayable alias: it requires the display to be
  persisting on an AUX slot across the seq_end, which `STATE_LAST_FRAME` prevents whenever
  any I/P ever existed (it moves display to `prev_i_p_frame`) — the residual case is a
  stream with B pictures and no reference frame at all, which is undecodable garbage anyway.
  Optional same-shape guard if the file is ever touched again; deliberately NOT bundled into
  the slot-alias fix.
- **F3 — End-of-stream tail stranding (cosmetic, linear files only).** `vbuf_write` emits
  64-bit words only when full (≤7 bytes strand), and getbits needs a further full word to
  slide its window — so a stream that just STOPS (raw `.m2v` EOF; anything not ending in
  B7-at-PES-end) never decodes its last slices and never flushes the reorder hold: the final
  picture is not shown. DVD stills are covered by `ps_demux`'s `S_VID_FLUSH` filler; a
  general end-of-stream filler (e.g. on reader `strm_done`+drain) would close this for
  linear playback. Small, optional follow-up.
- **F4 — ~15 `N'(expr)` size casts survive the project ban** (`dvd/av_sync.sv`,
  `dvd/dvd_audio_decode.sv`, `dvd/iec61937_wrap.sv`, `dvd/ac3/pcm_out.sv`,
  `dvd/ac3/mantissa_dequant.sv`; `grep -nE "[0-9]+'\("`). The ban exists because Quartus 17
  mangled `signed'(27'(x >>> 16))` as a multiply operand (memory
  `quartus-sizecast-netlist-cosim`). Every survivor sits in a HW-proven path (A/V sync
  verified to the LSB; AC-3 byte-exact PCMDUMP gates), so they are grandfathered-safe under
  THIS Quartus — but convert them opportunistically whenever those files are next edited,
  and keep running the grep on new RTL.
- **F5 — Hygiene:** `dvd/mem_shim.sv` (the retired non-burst shim, whose read-retry
  gives up by synthesizing a zero beat) is still listed in `DVD.qsf` but uninstantiated;
  drop it from the file list on some future netlist-changing branch.
- **F6 — Noted, deliberate:** `mem_shim_burst.sv`'s fill timeout serves zeroes without
  validating the cache line — belt-and-suspenders for a path BIST showed never times out.

