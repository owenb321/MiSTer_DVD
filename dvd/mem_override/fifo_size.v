/*
 * fifo_size.v  —  DVD-fork OVERRIDE  (shadows rtl/mpeg2/fifo_size.v)
 *
 * Copyright (c) 2007 Koen De Vleeschauwer.   (upstream original)
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/* ===========================================================================
 * DVD-FORK OVERRIDE — N64-STYLE DISPLAY LINE-PREFETCH (doc "fix-direction 1b")
 * ===========================================================================
 *
 * This file SHADOWS rtl/mpeg2/fifo_size.v.  It is found FIRST because the .qsf
 * lists `set_global_assignment -name SEARCH_PATH dvd/mem_override` BEFORE
 * `... rtl/mpeg2` — the same `include`-shadow mechanism already used for
 * dvd/mem_override/mem_codes.v.  NO rtl/ file is modified (CLAUDE.md rule).
 *
 * WHAT CHANGED vs upstream:  ONLY the disp_reader (display framestore read)
 * and the resample run-ahead FIFO are deepened.  Every other FIFO is byte-for-
 * byte identical to the upstream original below.
 *
 *   DISP_ADDR_DEPTH : 8 (256)  -> 10 (1024)
 *   DISP_DTA_DEPTH  : 8 (256)  -> 10 (1024)   <- the multi-line BRAM line buffer
 *   RESAMPLE_DEPTH  : 8 (256)  -> 10 (1024)   <- lets resample_addrgen run as far
 *                                                ahead as the line buffer is deep
 *
 * DEPTH CHOICE (1024, not 2048): at the real 720-wide geometry one display line
 * is ~180 framestore words, so 1024 words ~= 5-6 lines — squarely in N64's 4-8
 * line range.  An earlier 2048 build PLACED fine (26% M10K) but the Fitter could
 * not ROUTE it (Error 11802 after ~8000 ns of added hold delay — a localized
 * hold/congestion knot from the oversized 1024-deep-x-64-bit FIFO at clk_dec).
 * 1024 halves that footprint and fits.
 *
 * WHY THIS *IS* the N64 line-prefetch, expressed in this decoder's structure:
 *   - N64 VI (VI_linefetch.vhd/DDR3Mux.vhd): prefetch whole display lines AHEAD
 *     into a deep, triple-buffered BRAM; the framebuffer reader is lowest
 *     priority BUT has a very deep FIFO, so it can be starved by other DDR3
 *     traffic without ever underrunning scanout.
 *   - Here the display read is `disp_reader` (a framestore_reader = a pair of
 *     fifo_sc BRAM FIFOs: an address FIFO out to the arbiter, a DATA FIFO back).
 *     `resample_addrgen` already FREE-RUNS ahead of scanout: it emits a whole
 *     frame's read addresses as fast as the FIFOs accept them (it is gated only
 *     by disp_wr_addr_almost_full and resample_wr_almost_full, NOT by the dot
 *     clock).  And `framestore_request` makes the display read HIGHEST priority
 *     (do_disp), serving it until `disp_wr_dta_almost_full`.
 *   - So the run-ahead ENGINE and the priority already exist; the only thing
 *     missing is BUFFER DEPTH.  Deepening DISP_DTA_DEPTH turns the disp data
 *     FIFO into a multi-line BRAM buffer (1024 x 64b = 8 KB ~= 5-6 display
 *     lines); deepening DISP_ADDR_DEPTH + RESAMPLE_DEPTH lets resample_addrgen
 *     keep that many reads outstanding so the buffer actually fills far ahead.
 *     The display pipeline (pixel_queue -> mixer -> syncgen) then drains from
 *     BRAM and cannot be starved by a burst of f2sdram latency or by contention
 *     with decode reads/writes.
 *
 * COST:  ~9 M10K (disp data 1024x64=7, disp addr 1024x22=3, resample 1024x3=1)
 *   out of ~553 M10K on the 5CSEBA6.  A full 720x480 frame (~520 KB) would not
 *   fit; this prefetches a FEW lines, exactly as N64 does (4-8 lines).
 *
 * IMPORTANT HONESTY NOTE (see docs/history.md): this is primarily
 * a ROBUSTNESS / shear-mitigation improvement.  It MAY mask the long-standing
 * "black frame above line 256, every other frame" strobe by making the display
 * read immune to f2sdram latency/contention — but the strobe was shown to be
 * line-INDEX-256-keyed and ADDRESS-independent, i.e. NOT obviously a
 * latency/bandwidth effect, so deepening is NOT a proven root-cause fix.  If the
 * strobe is "memory returns zeros for the off-frame display read pattern", the
 * prefetch re-reads the SAME addresses each frame and would inherit the zeros.
 * Treat "does the strobe go away?" as an OPEN empirical question to verify on
 * hardware — do not claim it fixes the strobe until observed.
 *
 * Constraint preserved:  DISP_DTA_THRESHOLD (64) stays > 2**MEMTAG_DEPTH (32),
 * as the upstream comment requires, so in-flight reads cannot overflow the FIFO.
 * Run-ahead thresholds (DISP_ADDR_THRESHOLD=32, RESAMPLE_THRESHOLD=4) are kept
 * small relative to the new depths so resample_addrgen runs nearly the full
 * depth ahead before back-pressuring.
 * =========================================================================== */


/*
 * dct_coeff fifo. 31 bits wide.
 * Run/Length Values fifo from vld. Input for rld.
 */

parameter
  RLD_DEPTH          = 9'd7, // one 4:2:0 macroblock = 6 blocks at 64 run/length values per block maximum = 384 entries maximum
  RLD_THRESHOLD      = 9'd2,

/*
 * predict_err_fifo. 72 bits wide.
 * Inverse Discrete Cosine Transform Output. Contains prediction error.
 */

  PREDICT_DEPTH      = 9'd8,
  PREDICT_THRESHOLD  = 9'd64, // big enough so 1 macroblock ( 6 blocks @ 8 rows each ) fits.

/*
 * mvec fifo. 206 bits wide.
 * prediction motion vector fifo from vld. Input for motvec.
 */

  MVEC_DEPTH          = 9'd3,
  MVEC_THRESHOLD      = 9'd2,

/*
 *
 */

  ADDR_DEPTH      = 9'd8,
  ADDR_THRESHOLD  = 9'd8,
  DTA_DEPTH       = 9'd8,
  DTA_THRESHOLD   = 9'd64,
  MOTCOMP_ADDR_THRESHOLD  = 9'd144, /* enough for motcomp_addrgen to produce all reads necessary to process a complete macroblock
                                       number of addresses produced by motcomp_addrgen = no. of lumi blocks * lumi_rows * columns + no. of chromi blocks * max. chromi rows * colums = 4 * 9 * 2 + 2 * 10 * 2 = 112 (see motcomp_addrgen)
                                       number of addresses in the mem_addr pipe: 13 (13 tages, numbered 0 to 12)
                                       together: 112 + 13 = 125.
                                       144: safety margin, just in case.
                                       */

/*
 * Circular Video Buffer. vbuf_write_fifo and vbuf_read_fifo are both 64 bits wide.
 * from stream input to getbits.
 */

  VBUF_WR_DEPTH      = DTA_DEPTH,
  VBUF_WR_THRESHOLD  = 9'd128,
  VBUF_RD_DEPTH      = DTA_DEPTH,
  VBUF_RD_THRESHOLD  = 9'd32,

/*
 * fwd_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads the data for forward motion compensation.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 */

  /* DVD-FORK OVERRIDE — REFERENCE-READ RUN-AHEAD PREFETCH (motcomp throughput).
   * Reference-side twin of the display line-prefetch above.  High-motion stutter is
   * recon STARVED of reference pixels (rtl/mpeg2/motcomp_recon.v dbg_ref_stall ~91%
   * on Matrix): the f2sdram bridge goes idle while the run-ahead window is too small
   * to hide miss latency + display-read contention.  Deepen the fwd/bwd reference
   * read-ahead the same way display was deepened: raise the DEPTH (8->10 = 256->1024)
   * and KEEP the small free-slot threshold (prog_full asserts at fill = depth-thresh,
   * so depth 1024 + thresh 64 free => ~960 rows buffered; thresh stays > 2**MEMTAG_DEPTH
   * (=32) so in-flight reads can't overflow).  The DST + dct_block fifos (below) and the
   * fwd/bwd ADDRESS fifos are deepened in lockstep, because motcomp_addrgen STATE_INIT
   * stalls on the shallowest of {fwd_addr, bwd_addr, dst, dct_block} — all four must run
   * ahead for the deep data buffer to actually fill.  Runtime A/B: the fwd/bwd DATA
   * almost-full is gated back to the baseline fill (~192) when O[18] Ref Prefetch=Off,
   * in mpeg2video.v — so a single bitstream toggles deep vs baseline run-ahead.
   * DEPTH CHOICE (9 = 512, was 10 = 1024): the 1024 build (DVD_refpf) fixed the MiB
   * high-motion stutter but showed activity-correlated HDMI blackout WAVES (worse on
   * high-motion) + chroma fringing on ALL clips — the shared output path went marginal,
   * aggravated by this build's extra congestion (~25 M10K) and the extra reference bridge
   * traffic during heavy motion.  512 halves both the added M10K (~13) and the run-ahead
   * depth (still 2x the upstream 256 baseline, so most of the MiB win should survive) to
   * back off that pressure.  prog_full now asserts at fill 512-64 = ~448.  Cost ~13 M10K. */
  FWD_ADDR_DEPTH     = 9'd9,                  // was 1024; 512-deep ref-addr run-ahead (2x baseline)
  FWD_ADDR_THRESHOLD = MOTCOMP_ADDR_THRESHOLD,
  FWD_DTA_DEPTH      = 9'd9,                  // was 1024; 512x64 ref-row buffer (~448 rows)
  FWD_DTA_THRESHOLD  = DTA_THRESHOLD, // 64 free slots reserved (> 2**MEMTAG_DEPTH=32)

/*
 * bwd_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads the data for backward motion compensation.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 */

  BWD_ADDR_DEPTH     = 9'd9,                  // DVD-FORK OVERRIDE (ref prefetch): 512-deep, see FWD block
  BWD_ADDR_THRESHOLD = MOTCOMP_ADDR_THRESHOLD,
  BWD_DTA_DEPTH      = 9'd9,                  // DVD-FORK OVERRIDE (ref prefetch): 512x64 ref-row buffer
  BWD_DTA_THRESHOLD  = DTA_THRESHOLD,

/*
 * dst_fifo. 35 bits wide.
 * Motion compensation. Queues the addresses where the reconstructed pixels need to be written
 * until prediction error, forward and backward motion compensation data are available.
 */

  DST_DEPTH          = 9'd9,                  // DVD-FORK OVERRIDE (ref prefetch): 512-deep recon-param run-ahead
                                              // (dct_block fifo = DST_DEPTH-3 = 128 deep, scales with this).
                                              // Must match the deepened fwd/bwd run-ahead so addrgen STATE_INIT
                                              // does not stall on dst before the deep data buffer can fill.
  DST_THRESHOLD      = MOTCOMP_ADDR_THRESHOLD,

/*
 * recon_writer. 86 bits wide.
 * Motion compensation. Writes reconstructed pixels to the frame store.
 */

  RECON_DEPTH        = DTA_DEPTH,
  RECON_THRESHOLD    = DTA_THRESHOLD,

/*
 * disp_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads pixels from the frame store for displaying.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 *
 * DVD-FORK OVERRIDE: deepened 8->11 (256->2048 entries) to form an N64-style
 * multi-line BRAM line-prefetch buffer (see header).  resample_addrgen run-ahead
 * fills it; the display drains from BRAM, immune to f2sdram latency/contention.
 * Thresholds left small relative to depth so it fills nearly full before
 * back-pressuring; DISP_DTA_THRESHOLD kept > 2**MEMTAG_DEPTH (=32) per upstream.
 */

  DISP_ADDR_DEPTH    = 9'd10,         // was ADDR_DEPTH (8 = 256); now 1024 deep run-ahead address queue
  DISP_ADDR_THRESHOLD= 9'd32,         // stop generating addrs with 32 free (runs ~992 ahead)
  DISP_DTA_DEPTH     = 9'd10,         // was DTA_DEPTH  (8 = 256); now 1024 x 64b = 8KB BRAM line buffer (~5-6 display lines)
  DISP_DTA_THRESHOLD = 9'd64,         // keep > 2**MEMTAG_DEPTH (32); fills to ~960 before stopping

/*
 * resample_fifo. 3 bits wide.
 * Chroma resampling. Fifo from resample_addr to resample_dta.
 *
 * DVD-FORK OVERRIDE: deepened 8->11 (256->2048) so resample_addrgen can keep up
 * to ~2044 display reads OUTSTANDING — matching the deepened disp line buffer —
 * instead of stalling at 256 ahead.  This is what makes the prefetch actually
 * run multiple lines ahead rather than just holding a deeper reactive buffer.
 */

  RESAMPLE_DEPTH     = 9'd10,         // was 8 (256); now 1024-deep run-ahead control queue
  RESAMPLE_THRESHOLD = 9'd4,

/*
 * pixel_fifo. 35 bits wide.
 * From the decoding process to the display process
 */

  PIXEL_DEPTH        = 9'd10,
  PIXEL_THRESHOLD    = 9'd32,

/*
 * osd_writer. 86 bits wide.
 * On-Screen Display. Writes on-screen display to the frame store.
 */

  OSD_DEPTH          = 9'd5,
  OSD_THRESHOLD      = 9'd8,

/*
 * threshold to make framestore_request stop writing before mem_request_fifo, mem_tag_fifo or mem_response_fifo overflow.
 */

  MEM_THRESHOLD      = 9'd16,

/*
 * mem_request_fifo. 88 bits wide.
 * Memory subsystem. Sends read, write and refresh commands to the memory controller.
 */

  MEMREQ_DEPTH      = 9'd6,
  MEMREQ_THRESHOLD  = MEM_THRESHOLD,

/*
 * mem_tag_fifo. 3 bits wide.
 * Memory subsystem. Queues tags of read commands sent to the memory controller.
 */

  MEMTAG_DEPTH      = 9'd5,
  MEMTAG_THRESHOLD  = MEM_THRESHOLD,

/*
 * mem_response_fifo. 64 bits wide.
 * Memory subsystem. Receives data read from the memory controller.
 */

  MEMRESP_DEPTH     = 9'd7,
  MEMRESP_THRESHOLD = 9'd64;

/* not truncated */
