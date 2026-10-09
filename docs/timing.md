# Timing: what is checked, and why

Engineering note. The history of individual timing fights is in `docs/history.md` §7–§10
(the clk_dec chroma fringe) and `docs/status_log.md` "clk_mem timing"; the per-netlist
seed choices are the ledger in `DVD.qsf`. This page is the map of the checks themselves.

## The clocks

| Short name | TimeQuest name | Rate | What runs on it |
|---|---|---|---|
| `clk_dec` | `emu\|sys_pll\|…general[3]…divclk` | 81 MHz | the MPEG-2 decoder |
| `clk_mem` | `emu\|sys_pll\|…general[1]…divclk` | 90 MHz | the DDR3 bridge and the decoder's memory side (`mem_shim_burst`) |
| `clk_sys` | `emu\|sys_pll\|…general[0]…divclk` | 27 MHz | video raster, reader, demux, nav/VM, audio engine, HUD |
| `clk_hdmi` | `pll_hdmi\|…counter[0]…divclk` | 148.5 MHz constraint | ascal's output side; the real rate follows `video_mode` |
| `h2f_user0` | `sysmem\|…h2f_user0_clk` | 100 MHz | HPS bridge |
| `clk_audio` | `pll_audio\|…divclk` | 24.58 MHz | audio output |
| `FPGA_CLK1_50`, `FPGA_CLK2_50` | board pins | 50 MHz | framework |

The three `sys_pll` outputs are one clock group in `sys_top.sdc`, so the crossings between
them are timed on purpose (`docs/history.md` §10). Every other clock is its own exclusive
group.

## Intra-domain versus crossings

The `DVD.sta.rpt` summary panels (Fmax, Setup, Hold, Recovery, Removal) report the worst
path **ending** in each clock, which includes every crossing into it. The sys_pll crossings
all sit in dual-clock FIFOs (`xilinx_fifo_dc`) and `sync_reset` releases, which tolerate it,
so their negative slack (setup to about −4.9 ns, recovery to −6.2, hold to −0.45) is
expected. The consequence is that the summaries cannot say whether a domain's own logic
closes. That blind spot let `clk_mem` sit at 55–93 MHz unwatched until PR #157.

The only reliable reading is `report_timing -from_clock X -to_clock X`, which is what
`tools/clock_check.sh` does.

## The checks

| Tool | Reads | Covers | Role |
|---|---|---|---|
| `tools/fmax_check.sh` | `DVD.sta.rpt` (free) | `clk_dec` FAIL < 86 MHz; `clk_mem` FAIL < 90 (a WARN until 2026-10-09) | the gate `build_release.sh` and `seed_sweep.sh` run on every fit |
| `tools/clock_check.sh` | a `quartus_sta` run on the fit on disk (about 30 s) | every clock: intra-domain setup, hold, recovery, removal, all four corners | run on the fit a release ships; record the result |
| `tools/timing_paths.sh` | a `quartus_sta` run | top N intra-clock setup paths: `TIMING_CLOCK=dec` (default) / `mem` / a clock name, `TIMING_TEMP=100` (default) / `-40`, `TIMING_OUT=<file in the repo>` | finding the cluster to retime; dump the corner that is failing |

`fmax_check`'s "Restricted Fmax" for `clk_dec` and `clk_mem` is exactly `clock_check`'s
`1000 / (period − worst intra setup slack)`: on the first run both read 91.60 and 88.90 MHz.

### `clock_check` rules (`tools/clock_check.py`)

- **Intra-domain hold or removal below 0 at any corner: FAIL.** A hold violation does not
  improve at a lower clock rate or a cooler die, so no margin argument rescues it.
- **Setup:** `clk_dec` FAILs below 86 MHz and `clk_mem` below its 90 MHz run rate at a slow
  corner (both mirror `fmax_check`; `clk_mem` was a WARN until the 2026-10-09 retime cleared
  it on 7 of 7 seeds, user decision); every other clock WARNs on negative slack.
- **Recovery below 0: WARN.**
- **A clock not in `POLICY` is judged by the generic rules and flagged as INFO**, so a new
  PLL output is never skipped. Clocks with no paths (the PLL VCO phases) are silent.
- **Known waivers (`KNOWN`)** downgrade a setup miss to INFO only while the worst path
  starts and ends inside a named block and stays above a floor. A regression past the floor,
  or the worst path moving into our logic, WARNs again.
- `--selftest`: 14 arms, each of which must produce exactly its own finding.

## `clk_hdmi`: the one standing miss

`clk_hdmi` misses its 148.5 MHz constraint by about 2.2–2.5 ns (108–112 MHz), on every fit
measured. The worst path is entirely inside `ascal` (`o_vacpt → o_adrs_pre`, the output-side
line counter into the read-address calculation). `sys/ascal.vhd` is unmodified since the
upstream import, so this is the stock MiSTer scaler, not this fork's logic. It applies only
to a 1080p (148.5 MHz) `video_mode`; at 720p (74.25 MHz) the same paths pass easily. It is
waived in `clock_check` with a −3.0 ns floor.

Not yet established: whether stock cores built from the MiSTer template show the same
number. If a 1080p HDMI artefact is ever reported, this is the first place to look.

## Measurements

The release netlist of 2026-10-07 (the dither-latin netlist plus the release version string).

**SEED 17** (rejected for `clk_mem`), worst over all four corners:

| Clock | Runs | Fmax (slow) | Setup ns | Hold ns | Recovery ns | Removal ns |
|---|---|---|---|---|---|---|
| `clk_dec` | 81.00 | 91.60 | +1.428 | +0.103 | +4.873 | +0.603 |
| `clk_mem` | 90.00 | 88.90 | −0.137 | +0.136 | – | – |
| `clk_sys` | 27.00 | 33.10 | +6.822 | +0.116 | +26.585 | +0.553 |
| `clk_hdmi` | 148.54 | 108.13 | −2.516 | +0.086 | +2.243 | +0.580 |
| `h2f_user0` | 100.00 | 116.69 | +1.430 | +0.119 | +6.849 | +0.638 |
| `clk_audio` | 24.58 | 35.07 | +12.166 | +0.122 | +37.355 | +0.444 |
| `FPGA_CLK1_50` | 50.00 | 78.70 | +7.294 | +0.144 | +17.196 | +0.625 |
| `FPGA_CLK2_50` | 50.00 | 133.07 | +12.485 | +0.167 | – | – |

- **Every domain's own hold is positive** (worst +0.086 ns). The negative hold in the
  summaries is crossings, as `status_log.md` had stated without measuring.
- `clk_mem`'s worst path is `mem_shim_burst` again: `cur_addr[6] → cache_valid[46][0]`.
- `clk_sys`'s heaviest paths are the audio engine's `imdct_512` RAM writes (about 29 ns of
  the 37 ns period on an earlier fit); it is the domain to watch as the engine grows.

**SEED 5** (the fit that ships), worst over all four corners:

| Clock | Runs | Fmax (slow) | Setup ns | Hold ns | Recovery ns | Removal ns |
|---|---|---|---|---|---|---|
| `clk_dec` | 81.00 | 89.87 | +1.218 | +0.116 | +4.784 | +0.534 |
| `clk_mem` | 90.00 | 90.13 | +0.016 | +0.103 | – | – |
| `clk_sys` | 27.00 | 33.15 | +6.872 | +0.080 | +26.570 | +0.659 |
| `clk_hdmi` | 148.54 | 109.40 | −2.409 | +0.118 | +2.557 | +0.236 |
| `h2f_user0` | 100.00 | 111.71 | +1.048 | +0.136 | +6.221 | +0.431 |
| `clk_audio` | 24.58 | 38.13 | +14.455 | +0.169 | +38.227 | +0.422 |
| `FPGA_CLK1_50` | 50.00 | 73.38 | +6.372 | +0.131 | +17.419 | +0.605 |
| `FPGA_CLK2_50` | 50.00 | 110.89 | +10.982 | +0.167 | – | – |

Verdict `PASS (0 fail, 0 warn)`; `clk_hdmi` INFO only (in `ascal`, above the floor).
`clk_mem` passes by **+0.016 ns**: one seed of eight cleared it on this netlist, so the
next `mem_shim_burst` retime is needed before the next feature adds logic.

**Done (2026-10-09, `feature/clkmem-retime`):** the speculative-pop retime took the
bridge's pop off the stage-A verdict and put a credit queue (`dvd/mem_req_prefetch.sv`) on
the request FIFO's read side. 7 of 7 seeds then cleared `clk_mem` (≥ 94.2 MHz); SEED 17
`clock_check` PASS with 0 warnings (`docs/status_log.md` "clk_mem retime").
