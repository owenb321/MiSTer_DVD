`timescale 1ns/1ps
//
// resample_chain_tb.sv — FULL DISPLAY-CHAIN simulation to localise the
// "black frame above 256 lines" strobe (docs/history.md).
//
// Prior work (resample_persist_tb.sv) exonerated the addrgen+mem_addr ADDRESS
// path (disp_wr_addr stays monotonic past line 256). This bench takes the next
// step the doc asks for: instantiate the WHOLE display data path and a raster,
// and watch where the on-screen pixels go black above line 256.
//
//   resample (addrgen + dta + bilinear + resample_fifo)
//      |  disp_wr_addr  -> [framestore_reader addr fifo]
//      |                       |  rd_addr -> behavioural memory -> wr_dta
//      |  disp_rd_dta   <- [framestore_reader data fifo]
//      v
//   pixel_queue (dc fifo)  ->  mixer  <- sync_gen (raster)
//      |
//      v   y_out/u_out/v_out + syncs   (this is the core's video output)
//
// The behavioural memory returns a CONSTANT NON-BLACK word (0x40..) for every
// requested address. So the framestore never returns black: any black pixel at
// the mixer output is a DISPLAY-PATH fault, not a memory/bandwidth fault. This
// isolates exactly framestore_response -> resample_dta -> resample_bilinear ->
// pixel_queue -> mixer, which is where the doc narrowed the bug.
//
// Per raster frame we bin "did this output line show any non-black pixel?" by
// output-line number (counted from h_sync_out, reset on v_sync_out), and print
// the first fully-black visible line. Run mb_height=16 (256 lines, GOOD on HW)
// vs mb_height=17 (272 lines, STROBES on HW) and compare.
//
// Build:
//   iverilog -g2012 -D__IVERILOG__ -I rtl/mpeg2 -o bench/dvd/resample_chain_sim \
//     rtl/mpeg2/resample.v dvd/resample_addrgen.v rtl/mpeg2/resample_dta.v \
//     rtl/mpeg2/resample_bilinear.v rtl/mpeg2/mem_addr.v rtl/mpeg2/mixer.v \
//     rtl/mpeg2/pixel_queue.v rtl/mpeg2/syncgen.v rtl/mpeg2/read_write.v \
//     rtl/mpeg2/wrappers.v rtl/mpeg2/fwft.v rtl/mpeg2/xilinx_fifo_dc.v \
//     dvd/disp_vscale.sv dvd/disp_hstretch.sv rtl/mpeg2/xfifo_sc.v \
//     bench/dvd/resample_chain_tb.sv
//
// ⚠ BUILD-LINE FIX (2026-08-22): this used to name rtl/mpeg2/resample_addrgen.v — the
// UPSTREAM addrgen, which is dead code (DVD.qsf builds dvd/resample_addrgen.v) and can no
// longer satisfy the fork's rtl/mpeg2/resample.v port list (frame_late, video_live,
// pickup_hold, pause, cur_show_out, pickup_tick, ... are all missing), so the documented
// command had stopped BUILDING AT ALL. disp_vscale/disp_hstretch/xfifo_sc were also
// missing from the list even though the +vsmode arms instantiate them.
//   vvp bench/dvd/resample_chain_sim +mbh=16
//   vvp bench/dvd/resample_chain_sim +mbh=17
//
module resample_chain_tb;

  // ---- content / modeline geometry ----
  // Two geometries (selected by +wide). The narrow one is fast (for the prefetch
  // tests); the WIDE one is real 720x480 NTSC so the resample emission takes a
  // realistic fraction of a raster frame — the regime the HW splits the picture in.
  integer wide = 0;
  integer mbh = 16;                           // macroblock rows (overridden by +mbh=)

  reg [7:0]  MB_WIDTH;
  reg [7:0]  mb_height;
  reg [13:0] vertical_size;
  reg [13:0] HORIZONTAL_SIZE;
  integer    held_mode = 1;                   // 1 = hold (ofv=0) after priming
  reg [11:0] H_RES, H_SS, H_SE, H_LEN, V_RES, V_SS, V_SE, V_LEN;

  // ---- clocks (2:1 like HW clk_dec 54 / dot_clk 27) ----
  reg clk = 0;
  always #5 clk = ~clk;                        // resample / clk_dec
  reg dot_clk = 0;
  always #10 dot_clk = ~dot_clk;               // raster dot clock, exactly half rate

  reg rst = 0;                                 // active-low (released after a few cycles)

  // ---- resample stimulus ----
  reg  [2:0] output_frame = 3'd2;
  reg        output_frame_valid = 0;
  wire       output_frame_rd;
  reg        progressive_sequence = 1, progressive_frame = 1;
  reg        top_field_first = 0, repeat_first_field = 0;
  reg        interlaced = 0, deinterlace = 1, persistence = 1;
  reg  [4:0] repeat_frame = 0;

  // ---- +pace=N : model 30->60 playback (new frame every N raster frames) ----
  // When pace!=0 the pace_driver OWNS output_frame_valid/output_frame: it presents a
  // fresh decoded frame (cycling the buffer index) once every N v_sync periods and
  // drops output_frame_valid once the addrgen consumes it (output_frame_rd); the gaps
  // are filled by the persistence path. This reproduces the real A/V-paced regime the
  // HW splits the picture in (the priming/held path in `initial` is skipped for pace).
  integer pace = 0;
  integer pace_cnt = 0;

  // ---- +il=1 : interlaced/field mode (native 480i) ----
  // Drives the resample's FIELD path (deinterlace=0, interlaced display) and the
  // syncgen in interlaced mode, to reproduce the on-HW native-480i underrun (the
  // "missing/black field" that shows as a black frame in bob / a scanline field in
  // weave). +tff sets top_field_first; +rff sets repeat_first_field (3:2 pulldown
  // 3rd field); +pfr sets progressive_frame (1=film, 0=true interlaced).
  integer il = 0, tff = 0, rff = 0, pfr = 1;
  reg     il_disp = 0;   // syncgen interlaced

  // ---- +crt=1 : CRT 480i mode (native-width 13.5 MHz CE + N64-model interlace) ----
  // ⛔ LEGACY CONFIG (dual raster, 2026-07-29): the whole-core O[14] CRT mode this
  // reproduces is RETIRED from emu.sv — the main raster now always runs CE=1 and the
  // 15 kHz raster comes from dvd/re_interlace.sv (bench/dvd/re_interlace_tb.sv).
  // Kept because it still proves + guards the pixel_queue CE-stretch shim (in-tree,
  // inert at CE≡1) and the syncgen halfline model against a gated dot-CE consumer.
  // Not part of the default regression list; run on pixel_queue/syncgen changes.
  // ⚠ RUN-LENGTH / BUFFERING GOTCHA (2026-08-22). `+crt=1` halves the dot CE, so this
  // config produces frames at roughly HALF the wall-clock rate of the progressive run —
  // it needs a correspondingly longer run to accumulate enough frames for the aggregate
  // verdict. Combined with vvp buffering stdout when redirected to a file, that makes it
  // very easy to misread a still-running (or truncated) run as a failure. It is not.
  // Measured to completion 2026-08-22 (unbuffered, run to $finish):
  //   +mbh=16 +crt=1            -> VSCALE vsmode=0 (crt=1) : 11/12 good frames PASS
  //                                (the 1 miss is the frame-1 startup artifact the
  //                                 progressive run shows too)
  //   +mbh=16 +crt=1 +vsmode=1  -> VSCALE vsmode=1 (crt=1) : 12/12 good frames PASS
  //                                (FIELD + LETTERBOX, zero geometry failures)
  //   +mbh=16 +vsmode=1         -> VSCALE vsmode=1 (crt=0) : 18/18 good frames PASS
  // An earlier revision of this comment claimed "+crt=1 produces NO visible frames /
  // 0-0 good frames"; that was a MEASUREMENT ARTIFACT (output piped through `tail`), not
  // a real fault — recorded here so nobody re-derives the wrong conclusion.
  // For the field + Letterbox path specifically, the tighter guard is bench/dvd/
  // crt_ov_map_tb.sv: T2 co-sims the REAL disp_vscale field path against a closed form,
  // T3 walks the letterbox inverse over two full 480i fields (per-field re-arm), T5
  // checks spu_decode's row-base under the field-mapped walk. All pass.
  // Historical detail: reproduced the REAL O[14] CRT configuration end-to-end: the
  // whole dot-clock side (pixel_queue read, sync_gen, mixer) paced by a /2
  // clock-enable, the syncgen armed with halfline=429 + per-field 262/263 totals
  // (crt_ilace), and the field path (+il forced). This configuration showed BLACK
  // video on first HW test: the dc-fifo's raw-clock `valid` pulse fell entirely
  // inside the disabled CE cycle, so the mixer never latched a pixel (fixed by
  // the CE-stretch shim in pixel_queue.v).
  integer crt = 0;
  // ---- +vsmode=N : CRT anamorphic display mode (0 fit, 1 letterbox, 2 crop) ----
  // 0 Fit (bypass), 1 Letterbox (vertical downscale 3/4 + bars, addrgen vscale_mode=1),
  // 2 Crop (horizontal pan-scan: addrgen reads centre columns via hcrop_en, disp_hstretch
  // stretches to full width; vertical stays 1:1). Exercises the whole display chain
  // (resample -> disp_hstretch -> pixel_queue -> mixer). report_frame asserts geometry.
  integer vsmode = 0;
  // ---- +sif=1 : SIF analog fill (DVD-FORK FIX 2026-08-24) --------------------------
  // Reproduces the in-core 2x fill for MPEG-1 SIF content (352x240): content geometry
  // 352x240 (MB_WIDTH=22, mbh=15) into the WIDE 720x480 modeline, with the emu/
  // mpeg2video muxes replicated here: addrgen vscale_mode=2 (2x line repeat, v_step
  // 128), disp_hstretch 352->720 (hcrop_en forced, hdst=720), syncgen fed the
  // EFFECTIVE sizes (720 / doubled 480) — exactly mpeg2video's eff_horizontal_size /
  // eff_vertical_size mux. Composes with +vsmode=1 (letterbox over the doubled frame),
  // +crt=1 (field path) and +hgrad=1 (352->720 blend proof). Every +sif run also
  // co-sims the addrgen disp_y walk against the 2x closed form (the sif-walk block
  // below). +siftog=1 starts with the fill OFF and flips it on at a frame
  // boundary mid-run (the runtime Analog Out toggle case): the chain must re-prime
  // and settle back to passing geometry with no wedge.
  // +hfill=1 : SVCD-style h-fill-only (2026-08-24 <720 predicate widening):
  // 480x480 content, disp_hstretch 480->720 (exact 2:3), NO vertical scaling
  // (vscale_mode stays 0 — SVCD vertical is raster-native). Same sif_live
  // enable plumbing; composes with +hgrad (480->720 blend proof) and +crt.
  integer sif = 0, siftog = 0, hfill = 0;
  integer dumplines = 0;   // +dumplines=1: print the full per-line luma map (debug aid)
  reg        sif_live = 1'b0;                                 // the live enable (toggled by +siftog)
  wire [1:0] rs_vscale_mode = (sif_live && (hfill == 0)) ? 2'd2 : 2'd0;  // Fit / SIF 2x line repeat
  wire       rs_vscale_en   = (vsmode == 1);                  // letterbox -> downstream disp_vscale 2-tap blend
  wire       rs_hcrop_en    = (vsmode == 2);                  // crop
  // letterbox top-bar height (woven frame lines) = EFFECTIVE vertical_size/8 (the SIF
  // doubling happens upstream of disp_vscale, mirroring mpeg2video's eff mux); 0 for fit/crop.
  wire [13:0] eff_vsz_w  = (sif_live && (hfill == 0)) ? {vertical_size[12:0], 1'b0} : vertical_size;
  wire [13:0] sg_hsize   = sif_live ? 14'd720 : HORIZONTAL_SIZE;
  wire [11:0] mixer_voff = (vsmode == 1) ? {1'b0, eff_vsz_w[13:3]} : 12'd0;
  // crop horizontal stretch params (mirrors mpeg2video): centre 3/4 crop, stretch back to
  // the full (uncropped) line width MB_WIDTH*16 — or the 720 raster width under SIF fill.
  wire  [7:0] hcrop_mb_tb = rs_hcrop_en ? ((MB_WIDTH + 8'd4) >> 3) : 8'd0;
  wire [11:0] hsrc_w_tb   = (MB_WIDTH - (hcrop_mb_tb << 1)) << 4;
  wire [11:0] hdst_w_tb   = sif_live ? 12'd720 : (MB_WIDTH << 4);
  reg     dot_ce = 1'b1;                       // /2 CE when +crt, constant 1 otherwise
  always @(posedge dot_clk) dot_ce <= crt ? ~dot_ce : 1'b1;
  reg [11:0] HALFLINE_R = 12'd0;               // syncgen horizontal_halfline
  // (pace_driver always-blocks are below, after v_sync is declared)

  // ---- resample <-> framestore_reader nets ----
  wire        disp_wr_addr_full, disp_wr_addr_almost_full;
  wire        disp_wr_addr_en, disp_wr_addr_ack;
  wire [21:0] disp_wr_addr;
  wire        disp_rd_dta_empty, disp_rd_dta_almost_empty;
  wire        disp_rd_dta_en, disp_rd_dta_valid;
  wire [63:0] disp_rd_dta;
  wire        resample_wr_overflow;

  // ---- resample -> pixel_queue ----
  wire [7:0]  px_y, px_u, px_v, px_osd;
  wire [2:0]  px_position;
  wire        px_wr_en;
  wire        px_wr_almost_full;

  // ---- pixel_queue -> mixer ----
  wire [7:0]  mx_y, mx_u, mx_v, mx_osd;
  wire [2:0]  mx_position;
  wire        mx_rd_en, mx_rd_empty, mx_rd_valid, mx_rd_underflow;

  // ---- sync_gen -> mixer ----
  wire [11:0] h_pos, v_pos;
  wire        h_sync, v_sync, pixel_en;

  // ---- mixer outputs (the core's video) ----
  wire [7:0]  y_out, u_out, v_out, osd_out;
  wire        h_sync_out, v_sync_out, pixel_en_out;

  // ====================================================================
  // DUT chain
  // ====================================================================
  resample resample (
    .clk(clk), .rst(rst),
    .output_frame(output_frame), .output_frame_valid(output_frame_valid),
    .output_frame_rd(output_frame_rd),
    .progressive_sequence(progressive_sequence), .progressive_frame(progressive_frame),
    .top_field_first(top_field_first), .repeat_first_field(repeat_first_field),
    .mb_width(MB_WIDTH), .mb_height(mb_height),
    .horizontal_size(HORIZONTAL_SIZE), .vertical_size(vertical_size),
    .resample_wr_overflow(resample_wr_overflow),
    .disp_wr_addr_full(disp_wr_addr_full), .disp_wr_addr_almost_full(disp_wr_addr_almost_full),
    .disp_wr_addr_en(disp_wr_addr_en), .disp_wr_addr_ack(disp_wr_addr_ack), .disp_wr_addr(disp_wr_addr),
    .disp_rd_dta_empty(disp_rd_dta_empty), .disp_rd_dta_en(disp_rd_dta_en),
    .disp_rd_dta_valid(disp_rd_dta_valid), .disp_rd_dta(disp_rd_dta),
    .pixel_wr_almost_full(px_wr_almost_full),
    .interlaced(interlaced), .deinterlace(deinterlace),
    .persistence(persistence), .repeat_frame(repeat_frame),
    .y(px_y), .u(px_u), .v(px_v), .osd_out(px_osd),
    .position_out(px_position), .pixel_wr_en(px_wr_en),
    .video_live(), .pickup_hold(1'b0), .pause(1'b0),
    .vscale_mode(rs_vscale_mode),              // DVD-FORK (CRT anamorphic vscale: letterbox)
    .hcrop_en(rs_hcrop_en),                    // DVD-FORK (CRT anamorphic horizontal crop)
    .menu_ff(1'b0),                            // DVD-FORK (menu VBUF-lag §5): not exercised here
    .film24(1'b0)                              // DVD-FORK (Film 24p Out): not exercised here
  );

  // ---- disp_vscale: vertical 2-tap letterbox downscale (480->360 / field 240->180). Pure
  // pass-through when rs_vscale_en=0, so Fit/Crop are unaffected. ----
  wire [7:0] vs_y, vs_u, vs_v, vs_osd;
  wire [2:0] vs_pos;
  wire       vs_wr;
  wire       hs_in_almost_full;   // disp_hstretch.in_almost_full -> disp_vscale.out_almost_full
  disp_vscale disp_vscale (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .vscale_en(rs_vscale_en),
    .in_y(px_y), .in_u(px_u), .in_v(px_v), .in_osd(px_osd),
    .in_pos(px_position), .in_wr(px_wr_en), .in_almost_full(px_wr_almost_full),
    .out_y(vs_y), .out_u(vs_u), .out_v(vs_v), .out_osd(vs_osd),
    .out_pos(vs_pos), .out_wr(vs_wr), .out_almost_full(hs_in_almost_full)
  );

  // ---- disp_hstretch: horizontal pan-scan stretch (Crop). Pure pass-through when
  // rs_hcrop_en=0, so Fit/Letterbox are unaffected. Fed from disp_vscale. ----
  wire [7:0] hs_y, hs_u, hs_v, hs_osd;
  wire [2:0] hs_pos;
  wire       hs_wr;
  wire       pq_wr_almost_full;   // pixel_queue -> hstretch
  disp_hstretch disp_hstretch (
    .clk(clk), .clk_en(1'b1), .rst(rst),
    .hcrop_en(rs_hcrop_en | sif_live), .hsrc_width(hsrc_w_tb), .hdst_width(hdst_w_tb),
    .in_y(vs_y), .in_u(vs_u), .in_v(vs_v), .in_osd(vs_osd),
    .in_pos(vs_pos), .in_wr(vs_wr), .in_almost_full(hs_in_almost_full),
    .out_y(hs_y), .out_u(hs_u), .out_v(hs_v), .out_osd(hs_osd),
    .out_pos(hs_pos), .out_wr(hs_wr), .out_almost_full(pq_wr_almost_full)
  );

  // framestore_reader: addr-in / data-out bridge (the real disp_reader)
  wire        rd_addr_empty, rd_addr_valid;
  wire [21:0] rd_addr;
  reg         rd_addr_en;
  wire        wr_dta_full, wr_dta_almost_full, wr_dta_ack, wr_dta_overflow;
  reg         wr_dta_en;
  reg  [63:0] wr_dta;

  // disp_reader FIFO depths.  Two configurations, selected at COMPILE time:
  //   default        : upstream depths (256-entry addr+data) — the SHALLOW path.
  //   -D DEEP_DISP    : the N64-style multi-line BRAM line-prefetch depths
  //                     (2048-entry addr+data), matching dvd/mem_override/fifo_size.v.
  // For a faithful DEEP run, ALSO build with `-I dvd/mem_override` FIRST so that
  // resample.v picks up the deepened RESAMPLE_DEPTH (the run-ahead control fifo);
  // otherwise resample_addrgen stalls at 256 outstanding reads and the deeper
  // data fifo can never fill ahead.
`ifdef DEEP_DISP
  localparam [8:0] DISP_AD = 9'd10, DISP_DD = 9'd10;   // 1024 deep (prefetch, ~5-6 lines)
`else
  localparam [8:0] DISP_AD = 9'd8,  DISP_DD = 9'd8;    // 256 deep (upstream)
`endif

  framestore_reader #(   // matches mpeg2video disp_reader (DISP_*_DEPTH/THRESHOLD)
    .fifo_addr_depth(DISP_AD), .fifo_dta_depth(DISP_DD),
    .fifo_addr_threshold(9'd32), .fifo_dta_threshold(9'd64))
  disp_reader (
    .rst(rst), .clk(clk),
    .wr_addr_clk_en(1'b1),
    .wr_addr_full(disp_wr_addr_full), .wr_addr_almost_full(disp_wr_addr_almost_full),
    .wr_addr_en(disp_wr_addr_en), .wr_addr_ack(disp_wr_addr_ack),
    .wr_addr_overflow(), .wr_addr(disp_wr_addr),
    .rd_dta_clk_en(1'b1),
    .rd_dta_almost_empty(disp_rd_dta_almost_empty), .rd_dta_empty(disp_rd_dta_empty),
    .rd_dta_en(disp_rd_dta_en), .rd_dta_valid(disp_rd_dta_valid), .rd_dta(disp_rd_dta),
    .rd_addr_empty(rd_addr_empty), .rd_addr_en(rd_addr_en),
    .rd_addr(rd_addr), .rd_addr_valid(rd_addr_valid),
    .wr_dta_full(wr_dta_full), .wr_dta_almost_full(wr_dta_almost_full),
    .wr_dta_en(wr_dta_en), .wr_dta_ack(wr_dta_ack), .wr_dta_overflow(wr_dta_overflow),
    .wr_dta(wr_dta)
  );

  // behavioural memory: pop an address, push back a CONSTANT NON-BLACK word.
  // (Y bytes = 0x40 -> displayed luma 0xC0; never black. Any black at the
  //  mixer output is therefore a display-path fault, not memory.)
  //
  // Two starvation models (to test prefetch robustness):
  //  +throt=N       : 1 word / N clks CONSTANTLY (0 = full rate). A sustained
  //                   bandwidth DEFICIT — no finite buffer can survive it.
  //  +stallon=S +stalloff=F : BURSTY contention. Serve at full rate for F clks,
  //                   then accept NO reads for S clks, repeat. Average rate =
  //                   F/(F+S); choose F so the AVERAGE bandwidth is sufficient
  //                   but the display read is periodically starved for S clks
  //                   (modelling f2sdram contention with decode / refresh).
  //                   A SHALLOW buffer underruns during the stall burst; a deep
  //                   prefetch buffer rides through it. This is the realistic
  //                   case the N64 deep-FIFO design targets.
  integer throt = 0;
  integer throt_cnt = 0;
  wire    throt_ok = (throt == 0) || (throt_cnt == 0);

  integer stallon = 0, stalloff = 0;
  integer stall_phase = 0;
  reg     serving = 1'b1;               // 1 = serving window, 0 = stall (burst) window
  wire    stall_ok = (stallon == 0) || serving;

  // ---- LINE-TAG mode (+linetag=1) -------------------------------------------
  // Instead of a constant word, the memory returns the SOURCE disp_y (the line
  // resample_addrgen was on when it issued that read), replicated across all 8
  // luma bytes. So the displayed luma at output line N encodes WHICH source line
  // landed there. A correct render shows luma==N&0xFF monotonic; a vertical
  // OFFSET / WRAP / desync (the reframed strobe) shows as a jump/discontinuity in
  // the displayed source line -> directly reproduces the bug IN SIM, which the
  // old constant-word stub could not (an offset of a constant is still constant).
  //
  // The disp_y-per-address is tracked by a side FIFO that MIRRORS the in-order
  // disp_reader address FIFO: push disp_y when an address is accepted into the
  // addr fifo (disp_wr_addr_en && disp_wr_addr_ack); pop when the memory reads an
  // address out (rd_addr_en && ~rd_addr_empty). In-order => exact correspondence.
  integer linetag = 0;
  // ---- BLEND PROOF (+vgrad=S) : vertical gradient with a step > 1 -----------------
  // linetag returns the source line index, which increments by 1 per source line — so a
  // 2-tap blend of two ADJACENT integers rounds back to the nearest integer, INDISTINGUISH-
  // ABLE from nearest-neighbour. +vgrad=S scales the tag so adjacent source lines differ by
  // S (e.g. 8); a genuine 2-tap blend then lands on INTERMEDIATE values (source*S + f*S,
  // f in {1/3,2/3}) that are NOT multiples of S, whereas NN would only ever emit multiples
  // of S. The report counts output lines whose luma is not a multiple of S = proof the blend
  // is real. Forces linetag on (needs the disp_y side-fifo). S must divide 256 (8/16/32).
  integer vgrad = 0;
  // ---- BLEND PROOF (+hgrad=1) : per-COLUMN square wave (the HORIZONTAL twin) ---------
  // Crop's horizontal resample is an UPSCALE, so a plain column-index ramp cannot prove the
  // blend either — blending two adjacent integers rounds back to an integer, exactly the
  // trap +linetag hit vertically. A period-2 square wave instead makes every output with a
  // non-zero weight land STRICTLY BETWEEN the two levels, while nearest-neighbour
  // duplication can only ever emit the two levels themselves. Unlike +linetag this needs no
  // address side-fifo: every 64-bit memory word is the SAME per-column pattern, so no
  // address decode is required, and the period-2 phase is continuous across word (8 px),
  // macroblock (16 px) and crop-origin (hcrop_x0 = 96) boundaries — all even. Luma passes
  // through resample_bilinear unchanged, so the wave reaches disp_hstretch intact.
  // ⚠ resample_bilinear treats the stored luma byte as SIGNED and adds 128 on the way out
  // (resample_bilinear.v: `y <= y_pixel_5 + 8'd128`), so the MEMORY bytes and the DISPLAYED
  // levels differ by an XOR-0x80. Getting this wrong makes both levels land inside the
  // "interpolated" band and the proof reads 100% in EVERY mode (including Fit) — which is
  // exactly what the +vsmode=0 control run exists to catch. Keep the two pairs explicit.
  integer hgrad = 0;
  localparam [7:0] HG_MEM_LO = 8'hA8, HG_MEM_HI = 8'h48;   // what the memory returns...
  localparam [7:0] HG_LO     = 8'd40, HG_HI     = 8'd200;  // ...displayed as these (+128 signed)
  integer hg_seen = 0, hg_interp = 0;              // per-frame, reset in the new-frame block
  integer hg_seen_max = 0, hg_interp_max = -1;     // run-wide aggregates for the verdict
  localparam SFD = 8192;
  reg  [11:0] sfifo [0:SFD-1];
  integer s_head = 0, s_tail = 0;
  reg  [11:0] popped_line = 12'd0;
  wire        push_tag = disp_wr_addr_en && disp_wr_addr_ack;
  wire        pop_tag  = rd_addr_en && ~rd_addr_empty;
  always @(posedge clk) if (rst) begin
    if (push_tag) begin sfifo[s_tail] <= resample.resample_addrgen.disp_y;
                        s_tail <= (s_tail == SFD-1) ? 0 : s_tail + 1; end
    if (pop_tag)  begin popped_line <= sfifo[s_head];
                        s_head <= (s_head == SFD-1) ? 0 : s_head + 1; end
  end

  always @* rd_addr_en = ~rd_addr_empty && ~wr_dta_almost_full && throt_ok && stall_ok;
  always @(posedge clk)
    if (~rst) begin
      wr_dta_en   <= 1'b0;
      wr_dta      <= 64'h0;
      throt_cnt   <= 0;
      stall_phase <= 0;
      serving     <= 1'b1;
    end else begin
      wr_dta_en <= rd_addr_valid;          // one-cycle pipe after fifo read
      wr_dta    <= linetag      ? {8{ (vgrad != 0) ? (popped_line[7:0] * vgrad[7:0])
                                                   : popped_line[7:0] }}
                 : (hgrad != 0) ? {4{HG_MEM_LO, HG_MEM_HI}}   // per-column square wave
                                : 64'h4040_4040_4040_4040;
      if (throt != 0) throt_cnt <= (throt_cnt == 0) ? (throt-1) : (throt_cnt-1);
      if (stallon != 0) begin              // bursty stall phase machine
        if (serving) begin
          if (stall_phase >= stalloff-1) begin serving <= 1'b0; stall_phase <= 0; end
          else stall_phase <= stall_phase + 1;
        end else begin
          if (stall_phase >= stallon-1)  begin serving <= 1'b1; stall_phase <= 0; end
          else stall_phase <= stall_phase + 1;
        end
      end
    end

  // pixel_queue: dual-clock fifo, here driven single-clock with read enable = dot_ce
  pixel_queue pixel_queue (
    .clk_in(clk), .clk_in_en(1'b1), .rst(rst),
    .y_in(hs_y), .u_in(hs_u), .v_in(hs_v), .osd_in(hs_osd), .position_in(hs_pos),
    .pixel_wr_en(hs_wr), .pixel_wr_almost_full(pq_wr_almost_full),
    .pixel_wr_full(), .pixel_wr_overflow(),
    .clk_out(dot_clk), .clk_out_en(dot_ce),
    .y_out(mx_y), .u_out(mx_u), .v_out(mx_v), .osd_out(mx_osd), .position_out(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_empty(mx_rd_empty),
    .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow)
  );

  sync_gen sync_gen (
    .clk(dot_clk), .clk_en(dot_ce), .rst(rst),
    .horizontal_size(sg_hsize), .vertical_size(eff_vsz_w),   // SIF fill: the EFFECTIVE (filled) sizes
    .display_horizontal_size(14'd0), .display_vertical_size(14'd0),
    .horizontal_resolution(H_RES), .horizontal_sync_start(H_SS),
    .horizontal_sync_end(H_SE), .horizontal_length(H_LEN),
    .vertical_resolution(V_RES), .vertical_sync_start(V_SS),
    .vertical_sync_end(V_SE), .horizontal_halfline(HALFLINE_R), .vertical_length(V_LEN),
    .interlaced(il_disp), .clip_display_size(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en),
    .h_sync(h_sync), .v_sync(v_sync), .c_sync(), .h_blank(), .v_blank()
  );

  mixer mixer (
    .clk(dot_clk), .clk_en(dot_ce), .rst(rst),
    .pixel_repetition(1'b0),
    .y_in(mx_y), .u_in(mx_u), .v_in(mx_v), .osd_in(mx_osd), .position_in(mx_position),
    .pixel_rd_en(mx_rd_en), .pixel_rd_valid(mx_rd_valid), .pixel_rd_underflow(mx_rd_underflow),
    .h_pos(h_pos), .v_pos(v_pos), .h_sync_in(h_sync), .v_sync_in(v_sync), .pixel_en_in(pixel_en),
    .y_out(y_out), .u_out(u_out), .v_out(v_out), .osd_out(osd_out),
    .h_sync_out(h_sync_out), .v_sync_out(v_sync_out), .pixel_en_out(pixel_en_out),
    .disp_v_offset(mixer_voff)                 // DVD-FORK (CRT anamorphic letterbox bar offset)
  );

  // ====================================================================
  // Per-frame black-line instrumentation (on the mixer / core output)
  // ====================================================================
  // Output line number, counted from the mixer's own h_sync_out / v_sync_out,
  // so it is independent of the pipeline delay.
  localparam MAXLINE = 512;
  integer    out_line;
  reg        line_nonblack [0:MAXLINE-1];
  reg        line_visible  [0:MAXLINE-1];
  reg  [7:0] line_luma     [0:MAXLINE-1];  // first visible luma per output line (linetag: = source disp_y&0xFF)
  reg        line_luma_set [0:MAXLINE-1];
  reg        h_sync_out_d, v_sync_out_d, pixel_en_out_d;
  integer    frame_no = 0;
  integer    i;

  // per-frame horizontal extents (dot counter + non-black picture extent + active-region
  // extent), reset in the new-frame block; used by report_frame's horizontal-fill check.
  integer hdot = 0, hnb_min = 99999, hnb_max = -1, hact_min = 99999, hact_max = -1;

  // run-wide aggregates (set by report_frame) for the final pass/fail summary
  integer reported_frames = 0;
  integer black_frames    = 0;   // frames with >=1 fully-black visible line INSIDE the content band

  // ---- CRT anamorphic vertical-scaler checks (+vsmode) ----
  integer vs_good_frames = 0;    // good frames evaluated
  integer vs_pass_frames = 0;    // of those, ones that passed the geometry check
  integer first_video    = -1;   // first non-black visible line (set in report_frame)
  integer vs_interp_max  = -1;   // BLEND PROOF (+vgrad): max per-frame count of interpolated
                                 // (luma not a multiple of vgrad) output lines. NN => 0.

  localparam HTOL = 40;   // dot-count tolerance for horizontal edges (raster back/front porch + pipeline)
  task report_frame;
    integer last_video, vis_cnt, nb_cnt, span, hole;
    integer content_woven, exp_vpos_first, exp_vpos_last, exp_nb, TOL;
    integer dvf, dvl, fr_ok, hfill_ok, eff_vsz;
    begin
      last_video = -1; vis_cnt = 0; nb_cnt = 0; first_video = -1;
      for (i = 0; i < MAXLINE; i = i + 1) begin
        if (line_visible[i]) begin
          vis_cnt = vis_cnt + 1;
          if (line_nonblack[i]) begin
            nb_cnt = nb_cnt + 1;
            last_video = i;
            if (first_video == -1) first_video = i;
          end
        end
      end
      span = (first_video >= 0) ? (last_video - first_video + 1) : 0; // out_line span of the picture band
      hole = span - nb_cnt;                                           // >0 => a black gap inside the band (spill/starve)
      // -------- expected geometry (in true v_pos / woven-frame-line space) --------
      // The mixer latches dbg_first_vpos/dbg_last_vpos in v_pos coordinates (content top
      // = 0 for fit/zoom, vertical_size/8 for letterbox), which is coordinate-clean vs the
      // tb's out_line (which carries a raster back-porch offset). content_woven is the
      // woven-frame line count of the picture; nb_cnt (scored per v_sync = per field in
      // crt) is half that in the field path.
      // SIF fill: the display-space content height is the DOUBLED size (the addrgen 2x
      // repeat runs upstream of disp_vscale), mirroring mpeg2video's eff_vertical_size.
      eff_vsz        = (sif && sif_live) ? (vertical_size * 2) : vertical_size;
      content_woven  = (vsmode == 1) ? ((eff_vsz * 3) / 4) : eff_vsz;                // 360 / 480
      exp_vpos_first = (vsmode == 1) ? (eff_vsz >> 3) : 0;                           // 60 / 0
      exp_vpos_last  = exp_vpos_first + content_woven - 1;                           // 419 / 479
      exp_nb         = crt ? (content_woven >> 1) : content_woven;                   // per field in crt
      TOL            = 6;
      dvf = mixer.dbg_first_vpos;  dvl = mixer.dbg_last_vpos;
      // horizontal fill: the picture must span the WHOLE active region (left edge near
      // hact_min, right edge near hact_max). A Crop that failed to stretch would pillarbox
      // (non-black only in the middle ~3/4). Applies to all modes (all fill the width).
      hfill_ok = (hact_max > 0) &&
                 (hnb_min <= hact_min + HTOL) && (hnb_max >= hact_max - HTOL);
      $display("frame %0d: visible=%0d video_lines=%0d span=%0d hole=%0d  vpos %0d..%0d [exp %0d..%0d nb=%0d]  hfill %0d..%0d/act %0d..%0d %s",
               frame_no, vis_cnt, nb_cnt, span, hole, dvf, dvl, exp_vpos_first, exp_vpos_last, exp_nb,
               hnb_min, hnb_max, hact_min, hact_max, hfill_ok ? "" : "<<H-NARROW");
      // ignore the first/last partial frames (vis_cnt small) in the aggregate
      if (vis_cnt > 8) begin
        reported_frames = reported_frames + 1;
        if (hole > TOL) black_frames = black_frames + 1;
        // ---- geometry assertion (coordinate-clean) ----
        //  (1) picture placed at the right v_pos top (bars)   (2) picture ends at right v_pos
        //  (3) right number of video lines emitted            (4) no black hole inside the band
        fr_ok = ((dvf != 12'hfff) &&
                 (dvf >= exp_vpos_first - TOL) && (dvf <= exp_vpos_first + TOL) &&
                 (dvl >= exp_vpos_last  - TOL) && (dvl <= exp_vpos_last  + TOL) &&
                 (nb_cnt >= exp_nb - 2*TOL) && (nb_cnt <= exp_nb + 2*TOL) &&
                 (hole <= TOL) && hfill_ok) ? 1 : 0;
        vs_good_frames = vs_good_frames + 1;
        if (fr_ok) vs_pass_frames = vs_pass_frames + 1;
        else $display("   [vscale FAIL f%0d] mode=%0d crt=%0d: dbg_first_vpos=%0d(exp %0d) dbg_last_vpos=%0d(exp %0d) nb=%0d(exp %0d) hole=%0d hfill=%0d(hnb %0d..%0d act %0d..%0d)",
                      frame_no, vsmode, crt, dvf, exp_vpos_first, dvl, exp_vpos_last, nb_cnt, exp_nb, hole, hfill_ok, hnb_min, hnb_max, hact_min, hact_max);
      end
      // ---- BLEND PROOF (+vgrad): count interpolated output lines (luma % vgrad != 0) ----
      // A real 2-tap blend emits intermediate values on the f={1/3,2/3} lines (~2/3 of the
      // output lines); nearest-neighbour would emit only multiples of vgrad => count 0.
      if (vgrad != 0) begin : blendproof
        integer bi, interp, seen;
        interp = 0; seen = 0;
        for (bi = 0; bi < MAXLINE; bi = bi + 1)
          if (line_visible[bi] && line_luma_set[bi]) begin
            seen = seen + 1;
            if ((line_luma[bi] % vgrad) != 0) interp = interp + 1;
          end
        $display("  [blendproof f%0d] vgrad=%0d: %0d/%0d output lines interpolated (non-multiple)",
                 frame_no, vgrad, interp, seen);
        if (vis_cnt > 8 && interp > vs_interp_max) vs_interp_max = interp;
      end
      // ---- BLEND PROOF (+hgrad): count interpolated picture PIXELS (horizontal) ----
      if (hgrad != 0) begin
        $display("  [hblendproof f%0d] %0d/%0d picture pixels strictly interpolated",
                 frame_no, hg_interp, hg_seen);
        if (vis_cnt > 8 && hg_interp > hg_interp_max) begin
          hg_interp_max = hg_interp; hg_seen_max = hg_seen;
        end
      end
      if (linetag) linetag_report;
    end
  endtask

  // ---- SIF source-map check (+sif): addrgen disp_y walk co-sim ----
  // Samples the ACTUAL source line the addrgen reads for each emitted output line
  // (hierarchically, at the line-complete state), against the closed form
  //   src(i) = min(v_base + stride * floor((i+1)/2), vertical_size-1)
  // (stride 1 progressive, 2 on the field path with v_base = the field parity).
  // This is the deterministic contract crt_ov_map's v2x inverse replicates.
  // Two rejected measurement points, recorded so nobody retries them:
  //  - the MIXER-side per-frame capture: the scan loop free-runs vs the raster in
  //    this bench (the mixer discards queue entries while hunting after an
  //    underflow — see the SCANRATE instrument), so displayed frames drop/seam
  //    lines at wide geometry even in FIT (verified with +dumplines);
  //  - the +linetag memory-tag path: tags are captured at addr-fifo ACCEPT time,
  //    which lags the addrgen's disp_y by the elastic issue->accept backlog, so
  //    the tag<->line pairing is only approximate (fine for the strobe hunting it
  //    was built for, wrong for an exact co-sim).
  integer aw_bad = 0, aw_scans = 0, aw_maxline = -1;
  integer aw_exp, aw_line;
  reg     aw_armed = 1'b0, aw_done_d = 1'b0;
  wire    aw_scan_latch = (resample.resample_addrgen.state == 4'h1);                 // STATE_NEXT_IMG
  wire    aw_line_done  = (resample.resample_addrgen.state == 4'h3) &&               // STATE_NEXT_MB
                          resample.resample_addrgen.last_mb;
  always @(posedge clk) if (rst) begin
    aw_done_d <= aw_line_done;
    if (aw_scan_latch)
      aw_armed <= (sif != 0) && sif_live;          // score only scans that START with the fill on
    else if (aw_armed && aw_line_done && !aw_done_d) begin
      aw_line = resample.resample_addrgen.oline;   // output line just completed
      if (aw_line == 0) aw_scans = aw_scans + 1;
      if (aw_line > aw_maxline) aw_maxline = aw_line;
      aw_exp = resample.resample_addrgen.v_base
             + (resample.resample_addrgen.v_stride2 ? 2 : 1) * ((aw_line + 1) / 2);
      if (aw_exp > vertical_size - 1) aw_exp = vertical_size - 1;
      if (resample.resample_addrgen.disp_y !== aw_exp[11:0]) begin
        aw_bad = aw_bad + 1;
        if (aw_bad <= 12)
          $display("  [sif-walk] scan %0d line %0d: disp_y %0d expected %0d",
                   aw_scans, aw_line, resample.resample_addrgen.disp_y, aw_exp);
      end
    end
  end

  // LINE-TAG analysis: line_luma[N] = source disp_y&0xFF displayed at output line N.
  // A correct render is monotonic +1 (allowing the small bilinear wobble). Report the
  // mapping at sample points and flag the FIRST big discontinuity (the offset/wrap).
  task linetag_report;
    integer ln, prev, d, firstjump, jumpat;
    begin
      if (dumplines) begin
        for (ln = 0; ln < MAXLINE; ln = ln + 16) begin
          $display("  [dump f%0d] L%0d: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                   frame_no, ln,
                   line_luma_set[ln]    ? line_luma[ln]    : -1, line_luma_set[ln+1]  ? line_luma[ln+1]  : -1,
                   line_luma_set[ln+2]  ? line_luma[ln+2]  : -1, line_luma_set[ln+3]  ? line_luma[ln+3]  : -1,
                   line_luma_set[ln+4]  ? line_luma[ln+4]  : -1, line_luma_set[ln+5]  ? line_luma[ln+5]  : -1,
                   line_luma_set[ln+6]  ? line_luma[ln+6]  : -1, line_luma_set[ln+7]  ? line_luma[ln+7]  : -1,
                   line_luma_set[ln+8]  ? line_luma[ln+8]  : -1, line_luma_set[ln+9]  ? line_luma[ln+9]  : -1,
                   line_luma_set[ln+10] ? line_luma[ln+10] : -1, line_luma_set[ln+11] ? line_luma[ln+11] : -1,
                   line_luma_set[ln+12] ? line_luma[ln+12] : -1, line_luma_set[ln+13] ? line_luma[ln+13] : -1,
                   line_luma_set[ln+14] ? line_luma[ln+14] : -1, line_luma_set[ln+15] ? line_luma[ln+15] : -1);
        end
      end
      firstjump = -1; jumpat = -1; prev = -1;
      for (ln = 0; ln < MAXLINE; ln = ln + 1) begin
        if (line_visible[ln] && line_luma_set[ln]) begin
          if (prev != -1) begin
            d = line_luma[ln] - prev;          // expected ~ +1 (mod 256)
            if (firstjump == -1 && (d > 4 || d < -1) && !(prev >= 250 && line_luma[ln] <= 5)) begin
              firstjump = d; jumpat = ln;       // ignore the natural 255->0 byte wrap
            end
          end
          prev = line_luma[ln];
        end
      end
      $display("  [linetag f%0d] src-line @out: L8=%0d L120=%0d L200=%0d L250=%0d L255=%0d L256=%0d L257=%0d L300=%0d L400=%0d L470=%0d  | first_jump=%0d at out_line=%0d",
               frame_no,
               line_luma[8], line_luma[120], line_luma[200], line_luma[250], line_luma[255],
               line_luma[256], line_luma[257], line_luma[300], line_luma[400], line_luma[470],
               firstjump, jumpat);
    end
  endtask

  always @(posedge dot_clk) begin
    // detect start of a new output frame on v_sync_out rising edge
    if (v_sync_out && ~v_sync_out_d) begin
      if (frame_no > 0) report_frame;
      frame_no = frame_no + 1;
      out_line = 0;
      hnb_min = 99999; hnb_max = -1; hact_min = 99999; hact_max = -1;
      hg_seen = 0; hg_interp = 0;
      for (i = 0; i < MAXLINE; i = i + 1) begin
        line_nonblack[i] = 1'b0;
        line_visible[i]  = 1'b0;
        line_luma_set[i] = 1'b0;
        line_luma[i]     = 8'd0;
      end
    end
    // advance output line + reset horizontal dot counter on h_sync_out rising edge
    if (h_sync_out && ~h_sync_out_d) begin
      if (out_line < MAXLINE-1) out_line = out_line + 1;
      hdot = 0;
    end else begin
      hdot = hdot + 1;
    end
    // sample displayed pixels
    if (pixel_en_out && out_line < MAXLINE) begin
      line_visible[out_line] = 1'b1;
      // active-region horizontal extent (self-calibrating full-width reference)
      if (hdot < hact_min) hact_min = hdot;
      if (hdot > hact_max) hact_max = hdot;
      if (y_out != 8'd16) begin
        line_nonblack[out_line] = 1'b1;                    // 16 = mixer's black luma
        // horizontal extent of real (non-black) picture (crop must FILL width)
        if (hdot < hnb_min) hnb_min = hdot;
        if (hdot > hnb_max) hnb_max = hdot;
        // BLEND PROOF (+hgrad): count picture pixels landing strictly between the two
        // square-wave levels. A 2-tap resample interpolates ~14/15 of them; NN gives 0.
        if (hgrad != 0) begin
          hg_seen = hg_seen + 1;
          if (y_out > (HG_LO + 8'd4) && y_out < (HG_HI - 8'd4)) hg_interp = hg_interp + 1;
        end
      end
      if (!line_luma_set[out_line]) begin                  // first visible luma of the line
        line_luma[out_line]     = y_out;                   // linetag: encodes source disp_y&0xFF
        line_luma_set[out_line] = 1'b1;
      end
    end
    v_sync_out_d <= v_sync_out;
    h_sync_out_d <= h_sync_out;
  end

  // ---- pace_driver: owns output_frame_valid/output_frame when +pace=N (see decl) ----
  always @(negedge v_sync)
    if (rst && (pace != 0)) begin
      if (pace_cnt == 0) begin
        output_frame       <= (output_frame == 3'd2) ? 3'd0 : output_frame + 3'd1;
        output_frame_valid <= 1'b1;          // a new decoded frame is available
      end
      pace_cnt <= (pace_cnt + 1 >= pace) ? 0 : pace_cnt + 1;
    end
  always @(posedge clk)
    if (rst && (pace != 0) && output_frame_rd) output_frame_valid <= 1'b0; // consumed

  // ====================================================================
  // Drive
  // ====================================================================
  initial begin
    if (!$value$plusargs("mbh=%d", mbh)) mbh = 16;
    void'($value$plusargs("held=%d", held_mode));
    void'($value$plusargs("throt=%d", throt));
    void'($value$plusargs("stallon=%d",  stallon));
    void'($value$plusargs("stalloff=%d", stalloff));
    void'($value$plusargs("linetag=%d",  linetag));
    void'($value$plusargs("pace=%d",     pace));
    void'($value$plusargs("wide=%d",     wide));
    void'($value$plusargs("il=%d",       il));
    void'($value$plusargs("tff=%d",      tff));
    void'($value$plusargs("rff=%d",      rff));
    void'($value$plusargs("pfr=%d",      pfr));
    void'($value$plusargs("crt=%d",      crt));
    void'($value$plusargs("vsmode=%d",   vsmode));
    void'($value$plusargs("vgrad=%d",    vgrad));
    void'($value$plusargs("hgrad=%d",    hgrad));
    void'($value$plusargs("dumplines=%d", dumplines));
    void'($value$plusargs("sif=%d",      sif));
    void'($value$plusargs("siftog=%d",   siftog));
    void'($value$plusargs("hfill=%d",    hfill));
    if (vgrad != 0) linetag = 1;                 // the blend proof rides the linetag side-fifo
    if (sif) wide = 1;                           // SIF fill targets the wide 720x480 modeline
    if (hfill) wide = 1;                         // SVCD h-fill likewise
    if (crt) begin wide = 1; il = 1; end       // CRT implies the wide geometry + field path
    mb_height     = mbh[7:0];
    vertical_size = mbh * 16;
    // +vsz=N overrides vertical_size (the TRUE content height) independently of
    // mb_height*16 (the macroblock-padded EMISSION height). Real non-multiple-of-16
    // content has vertical_size < mb_height*16; the difference is the K lines that
    // spill to the next raster frame (the HW strobe). e.g. +mbh=19 +vsz=300 => K=4.
    void'($value$plusargs("vsz=%d", vertical_size));
    void'($value$plusargs("vres=%d", V_RES));   // override raster vertical_resolution (active = min(V_RES, vsz))
    if (wide) begin                              // real 720x480 NTSC (modeline.v values)
      MB_WIDTH = 8'd45;  HORIZONTAL_SIZE = 14'd720;
      H_RES = 12'd719; H_SS = 12'd735; H_SE = 12'd797; H_LEN = 12'd857;
      V_RES = 12'd511; V_SS = 12'd496; V_SE = 12'd499; V_LEN = 12'd524;
    end else begin                               // narrow/fast (prefetch tests)
      MB_WIDTH = 8'd4;   HORIZONTAL_SIZE = 14'd64;
      H_RES = 12'd64;  H_SS = 12'd70;  H_SE = 12'd78;  H_LEN = 12'd84;
      V_RES = 12'd512; V_SS = 12'd496; V_SE = 12'd499; V_LEN = 12'd505;
    end
    // ---- interlaced/field mode (native 480i) ----
    if (il) begin
      progressive_sequence = 0;     // interlaced sequence
      progressive_frame    = pfr[0];
      deinterlace          = 0;     // emit raw fields (the resample FIELD path)
      interlaced           = 1;     // interlaced display branch in resample_addrgen
      top_field_first      = tff[0];
      repeat_first_field   = rff[0];
      il_disp              = 1;      // syncgen interlaced (v_pos parity per field)
      // Keep the (working) progressive V modeline; syncgen halves the display size
      // itself when interlaced (v_display_size = vertical_resolution>>1). Overriding
      // V_LEN/V_SS broke the raster (v_sync stopped toggling) so leave them.
    end
    // ---- CRT 480i: the REAL O[14] modeline-walk values (per-field vertical,
    // native horizontal, halfline=429 arms syncgen's N64-model 2:1) ----
    if (crt) begin
      H_RES = 12'd720; H_SS = 12'd735; H_SE = 12'd797; H_LEN = 12'd857;
      V_RES = 12'd479; V_SS = 12'd244; V_SE = 12'd247; V_LEN = 12'd261;
      HALFLINE_R = 12'd429;
      $display("     CRT 480i mode: dot_ce=1/2, halfline=429, per-field 262/263");
    end
    // ---- SIF content geometry (352x240) into the wide/crt raster chosen above.
    // The modeline stays 720x480; the fill muxes (sg_hsize/eff_vsz_w, vscale_mode=2,
    // disp_hstretch 352->720) open the full active region — mirroring emu/mpeg2video.
    if (sif) begin
      MB_WIDTH = 8'd22; HORIZONTAL_SIZE = 14'd352;
      mbh = 15; mb_height = 8'd15; vertical_size = 14'd240;
      if (!siftog) sif_live = 1'b1;            // +siftog starts OFF, flips mid-run
      $display("     SIF fill mode: content 352x240, fill %s (vscale_mode=2, hstretch 352->720)",
               siftog ? "toggled mid-run" : "ON");
    end
    if (hfill) begin
      // SVCD 2/3-D1: 480x480 content, h-fill 480->720 only (vertical native)
      MB_WIDTH = 8'd30; HORIZONTAL_SIZE = 14'd480;
      mbh = 30; mb_height = 8'd30; vertical_size = 14'd480;
      sif_live = 1'b1;
      $display("     SVCD h-fill mode: content 480x480, hstretch 480->720 (no vscale)");
    end
`ifdef DEEP_DISP
    $display("\n==== resample_chain_tb [DEEP_DISP=2048] mb_height=%0d content=%0dx%0d ====",
             mbh, MB_WIDTH*16, mbh*16);
`else
    $display("\n==== resample_chain_tb [SHALLOW=256]   mb_height=%0d content=%0dx%0d ====",
             mbh, MB_WIDTH*16, mbh*16);
`endif
    if (stallon != 0)
      $display("     bursty stall model: serve %0d clks / stall %0d clks (avg rate %0d%%)",
               stalloff, stallon, (100*stalloff)/(stalloff+stallon));

    rst = 0; output_frame_valid = 0;
    repeat (8) @(posedge clk);
    rst = 1;
    repeat (8) @(posedge clk);

    // +pace=N models REAL 30->60 playback: a NEW decoded frame arrives only every
    // N raster frames (N=2 for 30fps on 60Hz), persistence fills the gaps. This is
    // the regime the HW splits in (the pace_driver block below toggles ofv).
    if (pace == 0) begin
      // Prime with a few real frames...
      output_frame_valid = 1;
      repeat (3) @(negedge v_sync);
      // ...then HOLD (clip ended): ofv=0, persistence=1 (doc's held-frame case).
      if (held_mode) output_frame_valid = 0;
    end
    // (pace mode: pace_driver drives output_frame_valid from reset; nothing here.)

    // ---- +siftog: run a few frames with the fill OFF, then flip it on at a frame
    // boundary (the runtime Analog Out toggle). The pre-toggle and settling frames are
    // excluded from the aggregates; the assertion is that the chain re-primes (hstretch
    // cfg divider, addrgen NEXT_IMG latch, syncgen sizes) and passes geometry after.
    if (sif && siftog) begin
      repeat (4) @(negedge v_sync);
      @(negedge v_sync) sif_live = 1'b1;
      $display("     SIFTOG: fill enabled at frame %0d", frame_no);
      repeat (3) @(negedge v_sync);            // settle (one garbled transition frame allowed)
      vs_good_frames = 0; vs_pass_frames = 0;
      reported_frames = 0; black_frames = 0;
    end

    // run several raster frames under the held/persistence/pace path
    // (+frames=N overrides for long scan-rate measurements)
    begin : runlen
      integer nframes;
      if (!$value$plusargs("frames=%d", nframes)) nframes = (wide ? 10 : 16);
      repeat (nframes) @(negedge v_sync);
    end
    report_frame;
    report_scanrate;
    $display("---- SUMMARY mb_height=%0d held=%0d stall=%0d/%0d : %0d frames scored, %0d BLACK %s ----",
             mbh, held_mode, stalloff, stallon, reported_frames, black_frames,
             (black_frames == 0) ? "=> CLEAN" : "=> STARVED");
    // ---- CRT anamorphic vertical-scaler verdict (all runs; +vsmode selects mode) ----
    // Pass rule: >=2 good frames evaluated and at most ONE fails (a startup frame may be
    // mid-scan when a new mode's cadence settles). FIT (vsmode 0) doubles as the bit-
    // identity check: its expected geometry IS today's top-aligned full-active render.
    begin
      integer vs_ok;
      vs_ok = (vs_good_frames >= 2) && (vs_pass_frames >= vs_good_frames - 1);
      $display("---- VSCALE vsmode=%0d (crt=%0d) : %0d/%0d good frames pass geometry => %s ----",
               vsmode, crt, vs_pass_frames, vs_good_frames, vs_ok ? "PASS" : "*** FAIL ***");
      // The geometry pass/fail is only meaningful on a clean picture (constant/gradient
      // memory). Under +linetag/+vgrad the "picture" is a source-line tag whose luma dips to
      // the mixer-black value on some lines, so skip the geometry FATAL there — the blend
      // proof below is the assertion for those runs.
      if (!vs_ok && !linetag) begin
        $display("!!!! VSCALE ASSERTION FAILED (vsmode=%0d crt=%0d) !!!!", vsmode, crt);
        $fatal(1, "vscale geometry check failed");
      end
    end
    // ---- BLEND PROOF verdict (+vgrad): the downstream disp_vscale must produce genuine
    // 2-tap interpolated lines (not nearest-neighbour picks). Threshold 40 is well below the
    // ~2/3 of ~360 (progressive) / ~180 (field) output lines that carry a non-zero weight. ----
    if (vgrad != 0) begin
      integer bp_ok;
      bp_ok = (vs_interp_max >= 40);
      $display("---- BLENDPROOF vsmode=%0d crt=%0d vgrad=%0d : max interpolated lines=%0d => %s ----",
               vsmode, crt, vgrad, vs_interp_max, bp_ok ? "PASS (2-tap real)" : "*** FAIL (looks like NN) ***");
      if (!bp_ok) $fatal(1, "disp_vscale 2-tap blend not detected (vgrad proof failed)");
    end
    // ---- BLEND PROOF verdict (+hgrad): the downstream disp_hstretch must be a genuine
    // 2-tap resampler, not the old nearest-neighbour duplicator. In Crop (vsmode 2) the
    // 528->720 walk gives a non-zero weight to ~14/15 of the columns, so "more than half
    // the picture pixels interpolated" is a wide margin; NN scores exactly 0. In Fit
    // (vsmode 0) NOTHING resamples horizontally, so the same run is the CONTROL: it must
    // score 0, which proves the pass-through really is a bypass. ----
    if (hgrad != 0) begin
      integer hp_ok, hp_exp;
      hp_exp = (vsmode == 2) || ((sif || hfill) && sif_live);  // hstretch: Crop / SIF / SVCD fill
      if (hp_exp) hp_ok = (hg_interp_max * 2 > hg_seen_max) && (hg_seen_max > 0);
      else        hp_ok = (hg_interp_max <= 0);
      $display("---- BLENDPROOF-H vsmode=%0d crt=%0d sif=%0d : max interpolated pixels=%0d/%0d => %s ----",
               vsmode, crt, sif, hg_interp_max, hg_seen_max,
               hp_ok ? (hp_exp ? "PASS (2-tap real)" : "PASS (control: no h-resample)")
                     : (hp_exp ? "*** FAIL (looks like NN) ***"
                               : "*** FAIL (pass-through is resampling!) ***"));
      if (!hp_ok) $fatal(1, "disp_hstretch horizontal 2-tap proof failed (hgrad)");
    end
    // ---- SIF source-map verdict (every +sif run): every output line of every
    // mode-2 scan must read the exact 2x-repeat source line, and scans must reach
    // the full doubled height (479 progressive / 239 per field). ----
    if (sif) begin
      integer slt_ok, exp_last;
      exp_last = il ? ((vertical_size / 2) * 2 - 1) : (vertical_size * 2 - 1);  // 239 field / 479 frame
      slt_ok = (aw_scans >= 2) && (aw_bad == 0) && (aw_maxline == exp_last);
      $display("---- SIF-WALK il=%0d : %0d scans, max line %0d (exp %0d), %0d bad lines => %s ----",
               il, aw_scans, aw_maxline, exp_last, aw_bad, slt_ok ? "PASS" : "*** FAIL ***");
      if (!slt_ok) $fatal(1, "SIF 2x line-repeat source walk check failed");
    end
    $display("==== DONE mb_height=%0d (held=%0d) ====\n", mbh, held_mode);
    $finish;
  end

  // ====================================================================
  // SCAN-vs-RASTER instrument (2026-07-04, the governor-timebase free-run
  // question): the frame-rate governor paces on completed image SCANS assuming
  // the display FIFO chain elastically locks scans 1:1 to raster frames. The
  // mixer, however, DISCARDS queue entries while hunting a line start in
  // STATE_INIT (e.g. after a mid-line pixel_rd_underflow) — discarded pixels
  // let the scan loop outrun the raster, so the governor's timebase (and
  // refresh_cnt / frame_due / frame_late) runs FAST vs the real display.
  // Count both and report the ratio: 1.000 = locked; >1 = free-run leak.
  // ====================================================================
  integer n_scans = 0, n_raster = 0, n_pickup = 0, n_late = 0, n_uf = 0, n_pops = 0;
  wire scan_done = (resample.resample_addrgen.state == 4'h3) &&      // STATE_NEXT_MB
                   resample.resample_addrgen.last_mb && resample.resample_addrgen.last_y;
  always @(posedge clk) if (rst) begin
    if (scan_done)          n_scans  = n_scans + 1;
    if (output_frame_rd)    n_pickup = n_pickup + 1;
    if (resample.frame_late) n_late  = n_late + 1;
  end
  reg v_sync_d2 = 0;
  always @(posedge dot_clk) if (rst) begin
    if (v_sync && ~v_sync_d2) n_raster = n_raster + 1;
    v_sync_d2 <= v_sync;
    if (mx_rd_underflow)      n_uf   = n_uf + 1;
    if (mx_rd_en && mx_rd_valid) n_pops = n_pops + 1;
  end
  task report_scanrate;
    begin
      $display("SCANRATE: scans=%0d raster_frames=%0d ratio=%0d.%03d  pickups=%0d lates=%0d underflow_cycles=%0d pops/frame=%0d",
               n_scans, n_raster,
               (n_raster != 0) ? n_scans / n_raster : 0,
               (n_raster != 0) ? (1000 * n_scans / n_raster) % 1000 : 0,
               n_pickup, n_late, n_uf,
               (n_raster != 0) ? n_pops / n_raster : 0);
    end
  endtask

  // ---- disp_y source-line window probe (steady-state global min/max) ----
  // Directly track the SOURCE line the addrgen reads (state in the WR_* range), after a
  // warmup, independent of the noisy linetag path. Fit reads 0..vsz-1; letterbox
  // 0..~vsz-1 (fewer distinct); zoom the CROPPED window (~vsz/8 .. ~7*vsz/8).
  integer dy_min = 99999, dy_max = -1;
  reg [31:0] dy_warmup = 0;
  always @(posedge clk) if (rst) begin
    dy_warmup <= dy_warmup + 1;
    if (dy_warmup > 200000 && resample.resample_addrgen.state >= 4'h5) begin
      if (resample.resample_addrgen.disp_y < dy_min) dy_min = resample.resample_addrgen.disp_y;
      if (resample.resample_addrgen.disp_y > dy_max) dy_max = resample.resample_addrgen.disp_y;
    end
  end
  task report_dispy;
    begin
      $display("DISPY source-line window (steady state): %0d .. %0d  (vsz=%0d, vsmode=%0d crt=%0d)",
               dy_min, dy_max, vertical_size, vsmode, crt);
    end
  endtask

  // ---- temporary flow probes ----
  integer n_pxwr = 0, n_rdvalid = 0, n_dtavalid = 0, n_mixdisp = 0, n_underflow = 0;
  always @(posedge clk) if (rst) begin
    if (px_wr_en)          n_pxwr     = n_pxwr + 1;
    if (disp_rd_dta_valid) n_dtavalid = n_dtavalid + 1;
  end
  always @(posedge dot_clk) if (rst) begin
    if (mx_rd_valid)         n_rdvalid   = n_rdvalid + 1;
    if (mx_rd_underflow)     n_underflow = n_underflow + 1;
    if (mixer.state != 3'd0) n_mixdisp   = n_mixdisp + 1;
  end
  final $display("PROBES: px_wr=%0d disp_dta_valid=%0d mix_rd_valid=%0d mix_nonINIT=%0d underflow=%0d",
                 n_pxwr, n_dtavalid, n_rdvalid, n_mixdisp, n_underflow);

  // overall watchdog
  initial begin
    #400_000_000;
    $display("TIMEOUT (mb_height=%0d, frame_no=%0d)", mbh, frame_no);
    report_frame;
    $finish;
  end
endmodule
