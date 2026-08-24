//============================================================================
//  imdct_512.sv — AC-3 512-pt inverse MDCT (M8 datapath; M11 area reduction).
//
//  Consumes the per-channel transform coefficients (coeff_mem, Q1.23, 256/ch,
//  HF tail already zero-filled by mantissa_dequant) and produces 256 windowed,
//  overlap-added time-domain PCM samples per channel into pcm_mem, maintaining
//  a per-channel 256-sample overlap/delay line across blocks.  Started by a
//  pulse (the sequencer drives it on mantissa_dequant's `done`); it does NOT
//  touch the bit_reader (all inputs are already in BRAM).
//
//  ALGORITHM — a literal transcription of liba52 0.8.0 a52_imdct_512()
//  (imdct.c): pre-twiddle (pre1[]) -> 128-pt complex split-radix IFFT -> post-
//  twiddle (post1[]) + KBD window -> overlap/add.  liba52's IFFT is a recursion
//  (ifft2/4/8/.. + ifft_pass butterflies); we instead execute a **flat
//  butterfly schedule** that bench/ac3/gen_imdct_tables.c traced out of that
//  exact recursion and proved (in double) against the real a52_imdct_512.  The
//  schedule + twiddle/window ROMs live in ac3_imdct_tables.svh (GENERATED).
//
//  FIXED POINT (architecture.md §5): complex samples are Q8.23 in 32-bit words
//  (range ±256 — peak |IFFT output| ≈ 17 for unit input, ample headroom);
//  twiddles + window are signed Q1.17 in 18-bit ROMs (DSP 18x18).  Each
//  multiply is `(sample * tw) >>> 17` (arithmetic, truncating).  This is a
//  fixed-point stage, so it is NOT bit-exact to liba52's float — the standalone
//  TB bounds the error vs a52_imdct_512 (see run_imdct.sh).
//
//  ----------------------------------------------------------------------------
//  M11 AREA REDUCTION (this revision) — make the design fit the Cyclone V.
//  ----------------------------------------------------------------------------
//  M8's working buffers buf_re/buf_im[0:127] were read at FOUR arbitrary indices
//  and written at FOUR arbitrary indices in the SAME cycle (the radix-4 step).
//  That cannot map to ≤2-port M10K block RAM, so Quartus realized them as 256
//  flip-flops × 32 bits behind 4× 128:1 read crossbars + write decoders =
//  ~82.8k ALUTs (≈80% of the whole core) and the Fitter failed.  Here the
//  complex working buffer is a single **true-dual-port M10K** (`bufmem`, 128 ×
//  64-bit packing {re,im}) with TWO ports, and every butterfly is **multi-
//  cycled**: read its ≤4 operands two-per-cycle into registers (synchronous RAM
//  read, 1-cycle latency), compute, then write its ≤4 results two-per-cycle.
//  The latency budget is enormous (~106k clk/block at 20 MHz vs ~157 butterflies
//  × ~6 cycles ≈ 1k + pre/post), so the serialization is effectively free.  The
//  arithmetic per butterfly is byte-for-byte the M8 math — only WHEN each
//  read/write happens changed — so the bounded error (1648 LSB) is unchanged.
//
//  M15 AREA REDUCTION: M14 tripled delay_mem/pcm_mem to 6 channel slots; with
//  their multiple combinational read ports they realized as ~98k flip-flops
//  together and the 5.1 design blew past the Cyclone V.  Both are now M10K with
//  registered reads (M13-style).  delay_mem is PACKED 64-bit ({dly2i,dly2i1},
//  read/written as one word per POST element); pcm_mem is a 1W/1R 32-bit RAM whose
//  POST writes are serialized over ph5..ph8 and whose S_DMX downmix reads the 5
//  fbw channels one-per-cycle.  The delay line is never reset by a loop (that
//  forces FFs) — `first_blk` instead zeroes the block-0 overlap read.  Arithmetic
//  is unchanged (bounded error still 1648 LSB).
//
//  DATAPATH: one shared bank of 4 signed multipliers (≈8 Cyclone V DSPs),
//  time-shared across pre/IFFT/post by the FSM.
//
//  MEMORIES / handshake:
//    - coeff_rd_addr/data : combinational read port into the coefficient store
//      (mantissa_dequant.coeff_mem in the integrated design; a TB array in the
//      standalone test).  Addr {ch, idx[7:0]}, data signed Q1.23.
//    - bufmem (M11) : true-dual-port M10K, 128 × {re,im} Q8.23; the IFFT working
//      buffer.  Synchronous read (1-cycle latency), per-port write.
//    - delay_mem (M15) : packed-64b M10K, {ch[2:0],i[5:0]} → {dly2i,dly2i1} Q8.23;
//      the overlap/add state, persists across blocks.  `first_blk` zeroes the
//      block-0 read (== liba52's fresh a52_state delay line) so no reset loop.
//    - pcm_mem (M15) : 1W/1R M10K, {ch[2:0],idx[7:0]} Q8.23, registered read.
//      pcm_rd_addr/data feeds pcm_out (M9, +1-cycle latency now); an AC3_COSIM
//      async tap serves the cosim/standalone TB without blocking M10K inference.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module imdct_512 (
    input  logic        clk,
    input  logic        rst,

    // begin IMDCT for this block (pulse, e.g. mantissa_dequant.done)
    input  logic        start,

    // number of full-bandwidth channels to transform (2 or 5).  LFE is dropped
    // from the stereo downmix, so it is never IMDCT'd.
    input  logic [2:0]  nfchans,

    // M16 short blocks: per-fbw-channel block-switch flag.  blksw[ch]==1 → that
    // channel uses the 256-pt short IMDCT (two interleaved transforms) instead of
    // the 512-pt long one.  Only affects the transform, not coeff/exp/bap.  LFE
    // and the coupling channel are never short.
    input  logic [4:0]  blksw,

    // DRC (M17): per-block dynamic-range gain word (A/52 §7.7).  Applied as a
    // uniform scalar on every transform coefficient at the PRE coeff read (the
    // IMDCT is linear, so this == liba52 folding state->dynrng into coeff_get).
    input  logic [7:0]  dynrng,

    // M14 Stage F downmix: when nfchans==5 (acmod==7, 5.1) the 5 fbw channels
    // L C R Ls Rs (slots 0..4) are folded to stereo Lo/Ro IN PLACE after the
    // IMDCT (written back to pcm slots 0/1) so pcm_out drains a plain 2-channel
    // result.  cmixlev/surmixlev select the centre/surround mix levels (A/52
    // §5.4.2.4/5).  nfchans==2 → no downmix (Lo=L, Ro=R already).
    input  logic [1:0]  cmixlev,
    input  logic [1:0]  surmixlev,

    // transform-coefficient read port (Q1.23, {ch[2:0], idx[7:0]})
    output logic [10:0] coeff_rd_addr,
    input  logic signed [23:0] coeff_rd_data,

    // PCM output read port (Q8.23, {ch[2:0], idx[7:0]}) for pcm_out + TB
    input  logic [10:0] pcm_rd_addr,
    output logic signed [31:0] pcm_rd_data,

    output logic        done            // 1-cycle pulse: both channels done
);

    // ---- IMDCT ROM tables + traced IFFT128 schedule (GENERATED) ----
    `include "ac3_imdct_tables.svh"

    // ---- complex IFFT working buffer: true-dual-port M10K (M11) -------------
    // One 64-bit word per complex sample, {re[63:32], im[31:0]}.  Two ports,
    // each independently read or write; synchronous read (q valid next cycle).
    (* ramstyle = "M10K, no_rw_check" *)
    logic [63:0] bufmem [0:127];
    logic [6:0]  bpa_addr, bpb_addr;
    logic        bpa_we,   bpb_we;
    logic [63:0] bpa_din,  bpb_din;
    logic [63:0] bpa_q,    bpb_q;
    always_ff @(posedge clk) begin
        if (bpa_we) bufmem[bpa_addr] <= bpa_din;
        bpa_q <= bufmem[bpa_addr];
    end
    always_ff @(posedge clk) begin
        if (bpb_we) bufmem[bpb_addr] <= bpb_din;
        bpb_q <= bufmem[bpb_addr];
    end

    // ---- overlap/output storage (M15: M10K block RAM) -----------------------
    // M14 tripled these to 6 channel slots (5 fbw used) — as inferred storage
    // with multiple combinational read ports they realized as flip-flops
    // (~98k FF for the two together) and the 5.1 design blew past the Cyclone V.
    // M15 converts both to M10K, M13-style: registered reads, writes funnelled
    // through explicit ports.
    //
    //   delay_mem : PACKED 64-bit per word ({sample[2i], sample[2i+1]}) addressed
    //     by {ch[2:0], i[5:0]} (i = POST element 0..63) — the overlap/add read
    //     (dly0=2i, dly1=2i+1) and write (ai=2i, bi=2i+1) always touch that pair
    //     together, so one word read (issue ph0, capture ph1) + one word write
    //     (ph5) per element.  1R/1W.  NOT reset by a loop (that forces FFs);
    //     instead `first_blk` forces the block-0 overlap read to 0 (the delay
    //     line is never *read* before block 1 has written it), reproducing
    //     liba52's fresh (zeroed) a52_state delay line without a clear pass.
    (* ramstyle = "M10K, no_rw_check" *)
    logic [63:0] delay_mem [0:511];        // {ch[2:0], i[5:0]} → {dly2i, dly2i1}
    logic        dm_we;
    logic [8:0]  dm_waddr, dm_raddr;
    logic [63:0] dm_wdata, dm_rq;
    always_ff @(posedge clk) begin
        if (dm_we) delay_mem[dm_waddr] <= dm_wdata;
        dm_rq <= delay_mem[dm_raddr];
    end

    //   pcm_mem : 32-bit per sample ({ch[2:0], idx[7:0]}) kept UNPACKED so the
    //     cosim/TB taps and pcm_out address samples directly.  1W/1R: every POST
    //     and downmix write funnels through pm_w*; one registered read port (pm_rq)
    //     serves the internal downmix and (in hardware) pcm_out's drain.  The
    //     cosim/sim async tap (combinational) is compiled in only under AC3_COSIM
    //     so it cannot block M10K inference in the real build.
    (* ramstyle = "M10K, no_rw_check" *)
    logic signed [31:0] pcm_mem [0:1535];  // {ch[2:0], idx[7:0]}
    logic        pm_we;
    logic [10:0] pm_waddr, pm_raddr;
    logic signed [31:0] pm_wdata, pm_rq;
    always_ff @(posedge clk) begin
        if (pm_we) pcm_mem[pm_waddr] <= pm_wdata;
        pm_rq <= pcm_mem[pm_raddr];
    end
`ifdef AC3_COSIM
    assign pcm_rd_data = pcm_mem[pcm_rd_addr];   // sim-only async verification tap
`else
    assign pcm_rd_data = pm_rq;                   // registered hardware read
`endif

    // ---- shared multiplier bank (4 × signed 34b·18b -> Q8.23) ----
    logic signed [33:0] ma0, ma1, ma2, ma3;
    logic signed [17:0] mb0, mb1, mb2, mb3;
    // (sample Q8.23 · twiddle Q1.17) >>> 17  -> Q8.23, truncating.  The error is
    // dominated by the Q1.17 twiddle quantization random-walked across the FFT,
    // not by per-multiply truncation bias — adding half-LSB round-to-nearest
    // here changed the measured max error by <2 LSB (1648 -> 1666), so per
    // architecture.md §5 truncation suffices and we keep the simpler datapath.
    wire  signed [51:0] mf0 = ma0 * mb0, mf1 = ma1 * mb1,
                        mf2 = ma2 * mb2, mf3 = ma3 * mb3;
    wire  signed [33:0] p0 = 34'(mf0 >>> 17), p1 = 34'(mf1 >>> 17),
                        p2 = 34'(mf2 >>> 17), p3 = 34'(mf3 >>> 17);

    // ---- FSM ----
    typedef enum logic [2:0] { S_IDLE, S_PRE, S_IFFT, S_POST, S_POST256, S_DMX } state_t;
    state_t st;

    logic [2:0]  ch;            // current channel (0..nfchans-1)
    wire  [2:0]  nfm1 = nfchans - 3'd1;

    // M16: does the current channel use the short (256-pt) transform?  blksw is
    // per fbw channel (0..4); coupling/LFE channels are never short.
    wire         blk_short = (ch < 3'd5) ? blksw[ch[2:0]] : 1'b0;

    // ---- M14 Stage F: 5.1 -> stereo downmix (final in-place pass) -------------
    // Lo = L + clev*C + slev*Ls ; Ro = R + clev*C + slev*Rs  (A52_STEREO).  clev/
    // slev are Q1.17 (×131072), the SAME LEVEL constants liba52 uses (a52_frame
    // clev[]/slev[]): LEVEL_3DB=0.7071→92682, LEVEL_45DB=0.5946→77933,
    // LEVEL_6DB=0.5→65536.  product (Q8.23·Q1.17)>>>17 → Q8.23; the 8 integer
    // bits of Q8.23 absorb the |Lo|<~2.4 headroom (no saturation possible).
    wire        dmx_en = (nfchans > 3'd2);     // 5.1 (acmod==7) only; stereo: off
    logic signed [17:0] clev, slev;
    always_comb begin
        case (cmixlev)                         // A/52 Table: 0.707 / 0.595 / 0.5
            2'd0: clev = 18'sd92682;
            2'd1: clev = 18'sd77933;
            2'd2: clev = 18'sd65536;
            default: clev = 18'sd77933;
        endcase
        case (surmixlev)                       // 0.707 / 0.5 / 0 (reserved→0)
            2'd0: slev = 18'sd92682;
            2'd1: slev = 18'sd65536;
            default: slev = 18'sd0;
        endcase
    end
    logic [8:0]  dmx_idx;                       // downmix walk 0..255
    // M15: the 5 fbw channels are read one-per-cycle through the single pcm read
    // port (S_DMX sub-phases) and captured here before the in-place fold.
    // M19e: the three dedicated downmix multipliers (6 DSPs) are folded into
    // the shared 4-mult bank — S_DMX never overlaps PRE/IFFT/POST, so the bank
    // is idle here.  The mux drives ma0=C·clev / ma1=Ls·slev / ma2=Rs·slev at
    // ph6/ph7; the bank's `(a*b)>>>17` truncation keeps the identical low 32
    // bits the dedicated 50-bit products produced (low bits are unaffected by
    // the wider intermediate).
    logic signed [31:0] dmx_l, dmx_c, dmx_r, dmx_ls, dmx_rs;
    wire signed [31:0] dmx_cwq = 32'(p0);                  // (C*clev)>>>17 -> Q8.23
    wire signed [31:0] dmx_lo  = dmx_l + dmx_cwq + 32'(p1);// + (Ls*slev)>>>17
    wire signed [31:0] dmx_ro  = dmx_r + dmx_cwq + 32'(p2);// + (Rs*slev)>>>17
    logic [8:0]  i;             // loop index (PRE 0..127, POST 0..63, POST256 0..31)
    logic [4:0]  ph;            // micro-step within an element / butterfly (POST256→18)
    logic [7:0]  s;             // schedule index 0..IMDCT_NSCHED-1
    logic        first_blk;     // 1 until the first block's done — zeroes overlap

    logic signed [31:0] dk, d255k;          // PRE captured coeffs
    logic [63:0] c0, c1, c2, c3;            // IFFT butterfly operands (regs)
    logic signed [33:0] tt5, tt6;           // BFULL latched partials
    logic signed [31:0] ar, ai, br, bi;     // POST latched a/b products
    logic signed [31:0] bir, bii, b1r, b1i; // POST captured buf[i], buf[127-i]
    logic signed [31:0] dly0_r, dly1_r;     // POST captured overlap (delay) pair
    logic signed [31:0] pa0, pa1, pb0, pb1; // POST latched output samples (serialized writes)

    // ---- M16 short-block (256-pt) POST working registers ----
    // buf1[i]/buf1[63-i]/buf2[i]/buf2[63-i] (buf1 at bufmem[0..63], buf2 at [64..127])
    logic signed [31:0] q1ir, q1ii, q1mr, q1mi, q2ir, q2ii, q2mr, q2mi;
    // captured overlap pairs: word A {delay[2i],delay[2i+1]}, word B {delay[126-2i],delay[127-2i]}
    logic signed [31:0] s_dly2i, s_dly2i1, s_dly126, s_dly127;
    // post2 complex products a/b (from buf1) and c/d (from buf2)
    logic signed [31:0] s_ar, s_ai, s_br, s_bi, s_cr, s_ci, s_dr, s_di;
    // windowed/overlap-added output samples for this element (8 per i)
    logic signed [31:0] o2i, o255, o128, o127, o2i1, o254, o129, o126;

    // ---- table sync-ROM reads (M19c area pass) ------------------------------
    // The GENERATED tables (~37 kbit) were combinational LUT ROMs; they are now
    // read REGISTERED so Quartus places them in M10K.  The packed images
    // (imdct_sched_pk / imdct_pre_pk / imdct_post_pk, emitted by the generator)
    // carry identical values; addresses are prefetched so every consumer sees
    // exactly the value it used to read combinationally:
    //   - schedule: addressed with s_next (s+1 during the ph5 advance) so
    //     sched_q holds entry s from ph0 of every butterfly; outside S_IFFT the
    //     address parks on the channel's entry 0, priming the S_IFFT entry.
    //   - pre/post twiddles + fftorder: addressed by i (stable per element);
    //     q registers on the element's first cycle, consumed from its second
    //     (S_PRE gained one phase so fo_q lands before the dk address issue).
    //   - window: 2 reads/cycle -> two read ports, addresses issued one ph
    //     early by the wa/wb mux (below the idx helpers).
    // M16: the short block runs the two-ifft64 schedule (packed at offset
    // IMDCT_NSCHED); the butterfly OP semantics are identical.
    wire [7:0] s_last = blk_short ? 8'(IMDCT_NSCHED256-1) : 8'(IMDCT_NSCHED-1);
    logic [70:0] sched_q;
    wire  [7:0]  s_next     = (s == s_last) ? s : (s + 8'd1);
    wire  [8:0]  sched_base = blk_short ? 9'(IMDCT_NSCHED) : 9'd0;
    wire  [8:0]  sched_addr = (st == S_IFFT)
                            ? (sched_base + {1'b0, (ph == 5'd5) ? s_next : s})
                            : sched_base;
    always_ff @(posedge clk) sched_q <= imdct_sched_pk[sched_addr];

    wire [2:0] op   = sched_q[70:68];
    wire [7:0] sa   = sched_q[67:60];
    wire [7:0] sb   = sched_q[59:52];
    wire [7:0] sc   = sched_q[51:44];
    wire [7:0] sd   = sched_q[43:36];
    wire signed [17:0] swr = $signed(sched_q[35:18]);
    wire signed [17:0] swi = $signed(sched_q[17:0]);

    // registered butterfly operands, split into re/im (a0,a1,a2,a3 in liba52)
    wire signed [31:0] c0r = c0[63:32], c0i = c0[31:0];   // a0
    wire signed [31:0] c1r = c1[63:32], c1i = c1[31:0];   // a1
    wire signed [31:0] c2r = c2[63:32], c2i = c2[31:0];   // a2
    wire signed [31:0] c3r = c3[63:32], c3i = c3[31:0];   // a3

    // PRE / POST twiddle sync-ROM reads (indexed by loop counter i, stable per
    // element).  M16: short blocks use pre2/post2, packed at +128 / +64.
    logic [35:0] pre_q, post_q;
    wire [7:0] pre_taddr  = blk_short ? {2'b10, i[5:0]} : {1'b0, i[6:0]};
    wire [6:0] post_taddr = blk_short ? {2'b10, i[4:0]} : {1'b0, i[5:0]};
    always_ff @(posedge clk) pre_q  <= imdct_pre_pk[pre_taddr];
    always_ff @(posedge clk) post_q <= imdct_post_pk[post_taddr];
    wire signed [17:0] pre_re = $signed(pre_q[35:18]);
    wire signed [17:0] pre_im = $signed(pre_q[17:0]);
    wire signed [17:0] po_re  = $signed(post_q[35:18]);  // post1 (long) / post2 (short)
    wire signed [17:0] po_im  = $signed(post_q[17:0]);

    // M16 short-block PRE coefficient addresses (== a52_imdct_256 de-interleave):
    //   buf1 (i<64):  dk=coeff[k],   d255k=coeff[254-k]   (even bins)
    //   buf2 (i>=64): dk=coeff[k+1], d255k=coeff[255-k]   (odd bins),  k=fftorder[i%64]
    // fo_q = fftorder[i] (long) / fftorder[i mod 64] (short), a sync read valid
    // from the element's second S_PRE cycle (first consumed at ph1).
    logic [7:0] fo_q;
    wire [6:0] fo_addr = blk_short ? {1'b0, i[5:0]} : i[6:0];
    always_ff @(posedge clk) fo_q <= imdct_fftorder[fo_addr];
    wire        s_buf2 = i[6];
    wire [7:0]  pre_addr0 = blk_short ? (s_buf2 ? (fo_q + 8'd1) : fo_q)
                                      : fo_q;
    wire [7:0]  pre_addr1 = blk_short ? (s_buf2 ? (8'd255 - fo_q) : (8'd254 - fo_q))
                                      : (8'd255 - fo_q);
    // window: two sync read ports; wa/wb addresses issued one ph early (mux
    // below the idx helpers)
    logic signed [17:0] wa_q, wb_q;
    logic [7:0] wa_addr, wb_addr;
    always_ff @(posedge clk) wa_q <= imdct_window[wa_addr];
    always_ff @(posedge clk) wb_q <= imdct_window[wb_addr];

    // ---- M17 DRC: scale a Q1.23 coeff by the dynrng gain into Q8.23 ----------
    //   A/52 §7.7.1: dynrng[7:5] is a 3-bit TWO'S-COMPLEMENT exponent (-4..+3),
    //   NOT a magnitude; dynrng[4:0] is the 5-bit mantissa.
    //     gain = (0x20 | mant)/32 * 2^signed3(exp)
    //   On the integer Q1.23 rep this is an exact integer mul + power-of-2 right
    //   shift:  scaled = (coeff * (0x20|mant)) >> (5 - signed3(exp)).
    //   (0x20|mant) ∈ [32,63];  (5 - signed3(exp)) ∈ [2,9];  |scaled| < 16.0
    //   → fits Q8.23 (max boost exp=3,mant=31 → 63/32·2^3 = 15.75 = +24 dB; max
    //   cut exp=4,mant=0 → 32/32·2^-4 = 0.0625 = -24 dB).  Unity is dynrng==0x00.
    //   *** FIX: was `9 - exp`, which is monotonic in the byte and INVERTS the
    //   exponent fold — cut codes (exp>=4) decoded as boosts → +16x clip on
    //   DRC-active DVD audio (Matrix front-channel dropout). ***
    wire signed [6:0]  drc_mant  = $signed({1'b0, 1'b1, dynrng[4:0]});  // +32..+63
    wire signed [3:0]  drc_exp   = $signed({dynrng[7], dynrng[7:5]});   // -4..+3
    wire signed [4:0]  drc_shr_s = 5'sd5 - 5'(drc_exp);                 // +2..+9
    wire        [3:0]  drc_shr   = drc_shr_s[3:0];                      // always 2..9
    wire signed [30:0] drc_prod  = coeff_rd_data * drc_mant;            // Q1.23·int
    wire signed [31:0] coeff_drc = 32'(drc_prod >>> drc_shr);           // Q8.23

    // POST window/data index helpers (i = 0..63)
    wire [7:0] idx0 = i[6:0] << 1;          // 2i      (0..126)
    wire [7:0] idx1 = (i[6:0] << 1) + 8'd1; // 2i+1    (1..127)
    wire [7:0] idxR = 8'd255 - (i[6:0] << 1);// 255-2i (255..129)
    wire [7:0] idxS = 8'd254 - (i[6:0] << 1);// 254-2i (254..128)
    // window read-address issue (M19c): each pair is requested one ph AHEAD of
    // the mult-mux phase that consumes it, so wa_q/wb_q carry exactly the
    // window values the old combinational reads (w0a/w0b, w1a/w1b, sw_lo/sw_hi)
    // delivered in that phase.
    always_comb begin
        wa_addr = idx0; wb_addr = idxR;
        unique case (st)
            S_POST: case (ph)
                5'd3: begin wa_addr = idx0; wb_addr = idxR; end   // ph4: w[2i], w[255-2i]
                5'd4: begin wa_addr = idx1; wb_addr = idxS; end   // ph5: w[2i+1], w[254-2i]
                default: ;
            endcase
            S_POST256: case (ph)
                5'd6: begin wa_addr = idx0;          wb_addr = idxR;          end // ph7
                5'd7: begin wa_addr = 8'd127 - idx0; wb_addr = 8'd128 + idx0; end // ph8
                5'd8: begin wa_addr = idx1;          wb_addr = idxS;          end // ph9
                5'd9: begin wa_addr = 8'd126 - idx0; wb_addr = 8'd129 + idx0; end // ph10
                default: ;
            endcase
            default: ;
        endcase
    end
    // M15: overlap pair captured from the packed delay M10K (ph1 of S_POST).
    wire signed [31:0] dly0 = dly0_r;       // delay[2i]
    wire signed [31:0] dly1 = dly1_r;       // delay[2i+1]

    // ---- multiplier-operand mux (combinational) ----
    always_comb begin
        ma0 = '0; ma1 = '0; ma2 = '0; ma3 = '0;
        mb0 = '0; mb1 = '0; mb2 = '0; mb3 = '0;
        unique case (st)
            S_PRE: if (ph == 3'd5) begin
                // buf.re = d255k*pre_im + dk*pre_re ; buf.im = d255k*pre_re - dk*pre_im
                ma0 = 34'(d255k); mb0 = pre_im;
                ma1 = 34'(dk);    mb1 = pre_re;
                ma2 = 34'(d255k); mb2 = pre_re;
                ma3 = 34'(dk);    mb3 = pre_im;
            end
            S_IFFT: begin
                if (op == OP_BHALF) begin
                    ma0 = 34'(c2r) + 34'(c2i); mb0 = swr;   // (a2.r+a2.i)*w
                    ma1 = 34'(c2i) - 34'(c2r); mb1 = swr;
                    ma2 = 34'(c3r) - 34'(c3i); mb2 = swr;
                    ma3 = 34'(c3i) + 34'(c3r); mb3 = swr;
                end else if (op == OP_BFULL) begin
                    if (ph == 3'd3) begin       // c2 products -> tt5/tt6
                        ma0 = 34'(c2r); mb0 = swr;  // a2.r*wr
                        ma1 = 34'(c2i); mb1 = swi;  // a2.i*wi
                        ma2 = 34'(c2i); mb2 = swr;  // a2.i*wr
                        ma3 = 34'(c2r); mb3 = swi;  // a2.r*wi
                    end else begin              // c3 products (write cycles)
                        ma0 = 34'(c3r); mb0 = swr;  // a3.r*wr
                        ma1 = 34'(c3i); mb1 = swi;  // a3.i*wi
                        ma2 = 34'(c3i); mb2 = swr;  // a3.i*wr
                        ma3 = 34'(c3r); mb3 = swi;  // a3.r*wi
                    end
                end
            end
            S_POST: case (ph)
                3'd2: begin                       // a_r,a_i from buf[i]
                    ma0 = 34'(bir); mb0 = po_re;
                    ma1 = 34'(bii); mb1 = po_im;
                    ma2 = 34'(bir); mb2 = po_im;
                    ma3 = 34'(bii); mb3 = po_re;
                end
                3'd3: begin                       // b_r,b_i from buf[127-i]
                    ma0 = 34'(b1r); mb0 = po_im;
                    ma1 = 34'(b1i); mb1 = po_re;
                    ma2 = 34'(b1r); mb2 = po_re;
                    ma3 = 34'(b1i); mb3 = po_im;
                end
                3'd4: begin                       // a-pair window (wa=w[2i], wb=w[255-2i])
                    ma0 = 34'(dly0); mb0 = wb_q;  // delay*window[255-2i]
                    ma1 = 34'(ar);   mb1 = wa_q;  // a_r*window[2i]
                    ma2 = 34'(dly0); mb2 = wa_q;
                    ma3 = 34'(ar);   mb3 = wb_q;
                end
                3'd5: begin                       // b-pair window (wa=w[2i+1], wb=w[254-2i])
                    ma0 = 34'(dly1); mb0 = wb_q;  // delay*window[254-2i]
                    ma1 = 34'(br);   mb1 = wa_q;  // b_r*window[2i+1]
                    ma2 = 34'(dly1); mb2 = wa_q;
                    ma3 = 34'(br);   mb3 = wb_q;
                end
                default: ;
            endcase
            // ---- M16 short-block POST (a52_imdct_256) ----
            // post2 products (a/b from buf1, c/d from buf2), each _r = p0+p1,
            // _i = p2-p3; then four windowed output pairs.  See the FF block.
            S_POST256: case (ph)
                5'd3: begin                       // a_r,a_i from buf1[i]
                    ma0 = 34'(q1ir); mb0 = po_re;
                    ma1 = 34'(q1ii); mb1 = po_im;
                    ma2 = 34'(q1ir); mb2 = po_im;
                    ma3 = 34'(q1ii); mb3 = po_re;
                end
                5'd4: begin                       // b_r,b_i from buf1[63-i]
                    ma0 = 34'(q1mr); mb0 = po_im;
                    ma1 = 34'(q1mi); mb1 = po_re;
                    ma2 = 34'(q1mr); mb2 = po_re;
                    ma3 = 34'(q1mi); mb3 = po_im;
                end
                5'd5: begin                       // c_r,c_i from buf2[i]
                    ma0 = 34'(q2ir); mb0 = po_re;
                    ma1 = 34'(q2ii); mb1 = po_im;
                    ma2 = 34'(q2ir); mb2 = po_im;
                    ma3 = 34'(q2ii); mb3 = po_re;
                end
                5'd6: begin                       // d_r,d_i from buf2[63-i]
                    ma0 = 34'(q2mr); mb0 = po_im;
                    ma1 = 34'(q2mi); mb1 = po_re;
                    ma2 = 34'(q2mr); mb2 = po_re;
                    ma3 = 34'(q2mi); mb3 = po_im;
                end
                5'd7: begin                       // window a-pair (wa=w[2i], wb=w[255-2i])
                    ma0 = 34'(s_dly2i); mb0 = wb_q; // delay[2i]*window[255-2i]
                    ma1 = 34'(s_ar);    mb1 = wa_q; // a_r*window[2i]
                    ma2 = 34'(s_dly2i); mb2 = wa_q;
                    ma3 = 34'(s_ar);    mb3 = wb_q;
                end
                5'd8: begin                       // a_i-pair (wa=w[127-2i], wb=w[128+2i])
                    ma0 = 34'(s_dly127); mb0 = wa_q;
                    ma1 = 34'(s_ai);     mb1 = wb_q;
                    ma2 = 34'(s_dly127); mb2 = wb_q;
                    ma3 = 34'(s_ai);     mb3 = wa_q;
                end
                5'd9: begin                       // b_i-pair (wa=w[2i+1], wb=w[254-2i])
                    ma0 = 34'(s_dly2i1); mb0 = wb_q; // delay[2i+1]*window[254-2i]
                    ma1 = 34'(s_bi);     mb1 = wa_q; // b_i*window[2i+1]
                    ma2 = 34'(s_dly2i1); mb2 = wa_q;
                    ma3 = 34'(s_bi);     mb3 = wb_q;
                end
                5'd10: begin                      // b_r-pair (wa=w[126-2i], wb=w[129+2i])
                    ma0 = 34'(s_dly126); mb0 = wa_q;
                    ma1 = 34'(s_br);     mb1 = wb_q;
                    ma2 = 34'(s_dly126); mb2 = wb_q;
                    ma3 = 34'(s_br);     mb3 = wa_q;
                end
                default: ;
            endcase
            // M19e: 5.1->stereo fold on the shared bank (Lo written ph6, Ro ph7;
            // hold the operands through both cycles)
            S_DMX: if (ph == 4'd6 || ph == 4'd7) begin
                ma0 = 34'(dmx_c);  mb0 = clev;
                ma1 = 34'(dmx_ls); mb1 = slev;
                ma2 = 34'(dmx_rs); mb2 = slev;
            end
            default: ;
        endcase
    end

    // ---- butterfly result words (combinational, from registered operands) ----
    // Identical arithmetic to M8; produced combinationally so the two write
    // micro-cycles (ph4 -> a,b ; ph5 -> c,d) just drive the RAM ports.
    logic [63:0] res_a, res_b, res_c, res_d;
    always_comb begin
        logic signed [33:0] t1,t2,t3,t4,t5,t6,t7,t8;
        t1='0;t2='0;t3='0;t4='0;t5='0;t6='0;t7='0;t8='0;
        res_a = '0; res_b = '0; res_c = '0; res_d = '0;
        unique case (op)
            OP_IFFT2: begin
                res_a = {32'(34'(c0r) + 34'(c1r)), 32'(34'(c0i) + 34'(c1i))};
                res_b = {32'(34'(c0r) - 34'(c1r)), 32'(34'(c0i) - 34'(c1i))};
            end
            OP_IFFT4: begin
                t1 = 34'(c0r)+34'(c1r); t2 = 34'(c3r)+34'(c2r);
                t3 = 34'(c0i)+34'(c1i); t4 = 34'(c2i)+34'(c3i);
                t5 = 34'(c0r)-34'(c1r); t6 = 34'(c0i)-34'(c1i);
                t7 = 34'(c2i)-34'(c3i); t8 = 34'(c3r)-34'(c2r);
                res_a = {32'(t1+t2), 32'(t3+t4)};
                res_c = {32'(t1-t2), 32'(t3-t4)};
                res_b = {32'(t5+t7), 32'(t6+t8)};
                res_d = {32'(t5-t7), 32'(t6-t8)};
            end
            OP_BZERO: begin
                t1 = 34'(c2r)+34'(c3r); t2 = 34'(c2i)+34'(c3i);
                t3 = 34'(c2i)-34'(c3i); t4 = 34'(c3r)-34'(c2r);
                res_c = {32'(34'(c0r)-t1), 32'(34'(c0i)-t2)};
                res_d = {32'(34'(c1r)-t3), 32'(34'(c1i)-t4)};
                res_a = {32'(34'(c0r)+t1), 32'(34'(c0i)+t2)};
                res_b = {32'(34'(c1r)+t3), 32'(34'(c1i)+t4)};
            end
            OP_BHALF: begin
                t5 = p0; t6 = p1; t7 = p2; t8 = p3;
                t1 = t5+t7; t2 = t6+t8; t3 = t6-t8; t4 = t7-t5;
                res_c = {32'(34'(c0r)-t1), 32'(34'(c0i)-t2)};
                res_d = {32'(34'(c1r)-t3), 32'(34'(c1i)-t4)};
                res_a = {32'(34'(c0r)+t1), 32'(34'(c0i)+t2)};
                res_b = {32'(34'(c1r)+t3), 32'(34'(c1i)+t4)};
            end
            default: begin   // OP_BFULL: t5/t6 latched (tt5/tt6), t7/t8 from c3
                t5 = tt5; t6 = tt6;
                t7 = p0 - p1;     // a3.r*wr - a3.i*wi
                t8 = p2 + p3;     // a3.i*wr + a3.r*wi
                t1 = t5+t7; t2 = t6+t8; t3 = t6-t8; t4 = t7-t5;
                res_c = {32'(34'(c0r)-t1), 32'(34'(c0i)-t2)};
                res_d = {32'(34'(c1r)-t3), 32'(34'(c1i)-t4)};
                res_a = {32'(34'(c0r)+t1), 32'(34'(c0i)+t2)};
                res_b = {32'(34'(c1r)+t3), 32'(34'(c1i)+t4)};
            end
        endcase
    end

    // ---- buffer RAM port drive (combinational) ----
    always_comb begin
        bpa_addr = 7'd0; bpa_we = 1'b0; bpa_din = 64'd0;
        bpb_addr = 7'd0; bpb_we = 1'b0; bpb_din = 64'd0;
        unique case (st)
            S_PRE: if (ph == 3'd5) begin       // write computed buf[i]
                bpa_we = 1'b1; bpa_addr = i[6:0];
                bpa_din = {32'(p0 + p1), 32'(p2 - p3)};
            end
            S_IFFT: case (ph)
                3'd0: begin                     // issue reads of sa, sb
                    bpa_addr = sa[6:0]; bpb_addr = sb[6:0];
                end
                3'd1: begin                     // issue reads of sc, sd
                    bpa_addr = sc[6:0]; bpb_addr = sd[6:0];
                end
                3'd4: begin                     // write a, b
                    bpa_we = 1'b1; bpa_addr = sa[6:0]; bpa_din = res_a;
                    bpb_we = 1'b1; bpb_addr = sb[6:0]; bpb_din = res_b;
                end
                3'd5: if (op != OP_IFFT2) begin // write c, d
                    bpa_we = 1'b1; bpa_addr = sc[6:0]; bpa_din = res_c;
                    bpb_we = 1'b1; bpb_addr = sd[6:0]; bpb_din = res_d;
                end
                default: ;
            endcase
            S_POST: if (ph == 3'd0) begin       // read buf[i], buf[127-i]
                bpa_addr = i[6:0]; bpb_addr = 7'd127 - i[6:0];
            end
            S_POST256: case (ph)
                5'd0: begin                      // read buf1[i], buf1[63-i]
                    bpa_addr = {1'b0, i[5:0]}; bpb_addr = 7'd63 - {1'b0, i[5:0]};
                end
                5'd1: begin                      // read buf2[i], buf2[63-i]
                    bpa_addr = 7'd64 + {1'b0, i[5:0]}; bpb_addr = 7'd127 - {1'b0, i[5:0]};
                end
                default: ;
            endcase
            default: ;
        endcase
    end

    // ---- pcm / delay RAM port drive (combinational) — M15 ---------------------
    // POST serializes its four output-sample writes over ph5..ph8 through the one
    // pcm write port, and writes the packed overlap word at ph5.  S_DMX walks the
    // pcm read port across the 5 fbw channels (ph0..ph4 → captured ph1..ph5) then
    // folds Lo/Ro back over slots 0/1 (ph6/ph7).  The read port otherwise carries
    // pcm_out's external drain address.
    always_comb begin
        pm_we = 1'b0; pm_waddr = 11'd0; pm_wdata = 32'sd0;
        pm_raddr = pcm_rd_addr;                 // default: external drain (hw)
        dm_we = 1'b0; dm_waddr = 9'd0; dm_wdata = 64'd0;
        dm_raddr = {ch, i[5:0]};                // POST overlap pair for this element
        unique case (st)
            S_POST: case (ph)
                4'd5: begin
                    pm_we = 1'b1; pm_waddr = {ch, idx0}; pm_wdata = pa0; // data[2i]
                    dm_we = 1'b1; dm_waddr = {ch, i[5:0]}; dm_wdata = {ai, bi};
                end
                4'd6: begin pm_we = 1'b1; pm_waddr = {ch, idx1}; pm_wdata = pb0; end // data[2i+1]
                4'd7: begin pm_we = 1'b1; pm_waddr = {ch, idxR}; pm_wdata = pa1; end // data[255-2i]
                4'd8: begin pm_we = 1'b1; pm_waddr = {ch, idxS}; pm_wdata = pb1; end // data[254-2i]
                default: ;
            endcase
            // M16 short POST: two packed delay words read (ph0/ph1), eight pcm
            // samples written (ph11..18), two packed delay words written (ph11/12).
            S_POST256: case (ph)
                5'd0: dm_raddr = {ch, i[5:0]};                 // word A: delay[2i],[2i+1]
                5'd1: dm_raddr = {ch, 6'd63 - i[5:0]};         // word B: delay[126-2i],[127-2i]
                5'd11: begin
                    pm_we = 1'b1; pm_waddr = {ch, idx0};       pm_wdata = o2i;   // data[2i]
                    dm_we = 1'b1; dm_waddr = {ch, i[5:0]};     dm_wdata = {s_ci, s_dr};
                end
                5'd12: begin
                    pm_we = 1'b1; pm_waddr = {ch, idxR};       pm_wdata = o255;  // data[255-2i]
                    dm_we = 1'b1; dm_waddr = {ch, 6'd63 - i[5:0]}; dm_wdata = {s_di, s_cr};
                end
                5'd13: begin pm_we = 1'b1; pm_waddr = {ch, 8'd128 + idx0}; pm_wdata = o128; end // data[128+2i]
                5'd14: begin pm_we = 1'b1; pm_waddr = {ch, 8'd127 - idx0}; pm_wdata = o127; end // data[127-2i]
                5'd15: begin pm_we = 1'b1; pm_waddr = {ch, idx1};         pm_wdata = o2i1; end // data[2i+1]
                5'd16: begin pm_we = 1'b1; pm_waddr = {ch, idxS};         pm_wdata = o254; end // data[254-2i]
                5'd17: begin pm_we = 1'b1; pm_waddr = {ch, 8'd129 + idx0}; pm_wdata = o129; end // data[129+2i]
                5'd18: begin pm_we = 1'b1; pm_waddr = {ch, 8'd126 - idx0}; pm_wdata = o126; end // data[126-2i]
                default: ;
            endcase
            S_DMX: case (ph)
                4'd0: pm_raddr = {3'd0, dmx_idx[7:0]};   // L
                4'd1: pm_raddr = {3'd1, dmx_idx[7:0]};   // C
                4'd2: pm_raddr = {3'd2, dmx_idx[7:0]};   // R
                4'd3: pm_raddr = {3'd3, dmx_idx[7:0]};   // Ls
                4'd4: pm_raddr = {3'd4, dmx_idx[7:0]};   // Rs
                4'd6: begin pm_we = 1'b1; pm_waddr = {3'd0, dmx_idx[7:0]}; pm_wdata = dmx_lo; end
                4'd7: begin pm_we = 1'b1; pm_waddr = {3'd1, dmx_idx[7:0]}; pm_wdata = dmx_ro; end
                default: ;
            endcase
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            st   <= S_IDLE;
            done <= 1'b0;
            ch   <= 3'd0;
            i    <= 9'd0;
            ph   <= 4'd0;
            s    <= 8'd0;
            coeff_rd_addr <= 11'd0;
            first_blk <= 1'b1;          // block 0 overlaps with a zeroed delay line
        end else begin
            done <= 1'b0;   // default: 1-cycle pulse

            case (st)
                S_IDLE: if (start) begin
                    ch <= 3'd0;
                    i  <= 9'd0;
                    ph <= 3'd0;
                    coeff_rd_addr <= {3'd0, 8'd0};  // fftorder[0] = 0
                    st <= S_PRE;
                end

                // ---- pre-twiddle: buf[i] = f(coeff[k], coeff[255-k]) ----
                // M13: coeff_rd_data is a registered M10K read (1-cycle latency);
                // M19c: fftorder is too, so ph0 lets fo_q land before the dk
                // address issue (one added phase per element).
                S_PRE: case (ph)
                    3'd0: ph <= 3'd1;                    // fo_q <= fftorder[i] lands
                    3'd1: begin
                        coeff_rd_addr <= {ch, pre_addr0};   // issue dk address (long: k)
                        ph <= 3'd2;
                    end
                    3'd2: begin
                        coeff_rd_addr <= {ch, pre_addr1};   // issue d255k address (long: 255-k)
                        ph <= 3'd3;                      // coeff lands next cycle
                    end
                    3'd3: begin
                        dk <= coeff_drc;                // coeff[k]·dynrng (valid)
                        ph <= 3'd4;
                    end
                    3'd4: begin
                        d255k <= coeff_drc;             // coeff[255-k]·dynrng (valid)
                        ph <= 3'd5;
                    end
                    default: begin                       // ph5: buf[i] written by port-mux
                        ph <= 3'd0;
                        if (i == 9'd127) begin
                            i <= 9'd0; s <= 8'd0; st <= S_IFFT;
                        end else begin
                            i <= i + 9'd1;
                        end
                    end
                endcase

                // ---- 128-pt IFFT: multi-cycle each traced butterfly ----
                //   ph0: issue reads sa,sb     ph1: issue reads sc,sd + grab c0,c1
                //   ph2: grab c2,c3            ph3: compute (BFULL: latch tt5/tt6)
                //   ph4: write a,b             ph5: write c,d + advance schedule
                S_IFFT: case (ph)
                    3'd0: ph <= 3'd1;
                    3'd1: begin c0 <= bpa_q; c1 <= bpb_q; ph <= 3'd2; end
                    3'd2: begin c2 <= bpa_q; c3 <= bpb_q; ph <= 3'd3; end
                    3'd3: begin
                        if (op == OP_BFULL) begin
                            tt5 <= p0 + p1;   // a2.r*wr + a2.i*wi
                            tt6 <= p2 - p3;   // a2.i*wr - a2.r*wi
                        end
                        ph <= 3'd4;
                    end
                    3'd4: ph <= 3'd5;
                    default: begin                       // ph5
                        ph <= 3'd0;
                        if (s == s_last) begin
                            i <= 9'd0; st <= state_t'(blk_short ? S_POST256 : S_POST);
                        end else begin
                            s <= s + 8'd1;
                        end
                    end
                endcase

                // ---- post-twiddle + window + overlap/add (M15: M10K mems) ----
                //   ph0: issue buf[i],buf[127-i] + packed delay[i] reads
                //   ph1: capture buf + overlap pair (zeroed on block 0)
                //   ph2: a products  ph3: b products
                //   ph4: latch a-pair samples   ph5: latch b-pair + write data[2i]
                //        + packed delay word     ph6/7/8: write the other 3 samples
                S_POST: case (ph)
                    4'd0: ph <= 4'd1;
                    4'd1: begin
                        bir <= $signed(bpa_q[63:32]); bii <= $signed(bpa_q[31:0]);
                        b1r <= $signed(bpb_q[63:32]); b1i <= $signed(bpb_q[31:0]);
                        // packed overlap pair; block 0 reads a (logically) zeroed
                        // delay line — never reads the M10K before block 1 wrote it.
                        dly0_r <= first_blk ? 32'sd0 : $signed(dm_rq[63:32]); // delay[2i]
                        dly1_r <= first_blk ? 32'sd0 : $signed(dm_rq[31:0]);  // delay[2i+1]
                        ph  <= 4'd2;
                    end
                    4'd2: begin
                        ar <= 32'(p0 + p1);   // post_re*buf.re + post_im*buf.im
                        ai <= 32'(p2 - p3);   // post_im*buf.re - post_re*buf.im
                        ph <= 4'd3;
                    end
                    4'd3: begin
                        br <= 32'(p0 + p1);   // post_im*b1.re + post_re*b1.im
                        bi <= 32'(p2 - p3);   // post_re*b1.re - post_im*b1.im
                        ph <= 4'd4;
                    end
                    4'd4: begin               // a-pair window products: data[2i], data[255-2i]
                        pa0 <= 32'(p0 - p1);  // delay*w2 - a_r*w1
                        pa1 <= 32'(p2 + p3);  // delay*w1 + a_r*w2
                        ph  <= 4'd5;
                    end
                    4'd5: begin               // b-pair window products: data[2i+1], data[254-2i]
                        pb0 <= 32'(p0 + p1);  // delay*w2 + b_r*w1
                        pb1 <= 32'(p2 - p3);  // delay*w1 - b_r*w2
                        ph  <= 4'd6;          // pcm[2i]=pa0 + delay word written by port-mux
                    end
                    4'd6: ph <= 4'd7;         // pcm[2i+1]=pb0 (port-mux)
                    4'd7: ph <= 4'd8;         // pcm[255-2i]=pa1 (port-mux)
                    default: begin            // ph8: pcm[254-2i]=pb1 (port-mux), advance
                        ph <= 4'd0;
                        if (i == 9'd63) begin
                            if (ch != nfm1) begin
                                ch <= ch + 3'd1; i <= 9'd0; st <= S_PRE;
                            end else if (dmx_en) begin
                                dmx_idx <= 9'd0; st <= S_DMX;   // fold 5.1 -> stereo
                            end else begin
                                done <= 1'b1; first_blk <= 1'b0; st <= S_IDLE;
                            end
                        end else begin
                            i <= i + 9'd1;
                        end
                    end
                endcase

                // ---- M16 short-block post-twiddle + window + overlap/add ----
                // Per element i (0..31): read buf1[i],buf1[63-i],buf2[i],buf2[63-i]
                // + the two packed overlap words; form post2 products a/b/c/d; build
                // 8 windowed output samples + 4 new overlap values; write them out.
                //   ph0/1: issue/capture buf + delay reads
                //   ph3..6: a,b,c,d products      ph7..10: windowed output pairs
                //   ph11..18: 8 pcm writes (+ 2 packed delay writes at ph11/12)
                S_POST256: case (ph)
                    5'd0: ph <= 5'd1;
                    5'd1: begin                       // capture buf1[i],buf1[63-i] + delay word A
                        q1ir <= $signed(bpa_q[63:32]); q1ii <= $signed(bpa_q[31:0]);
                        q1mr <= $signed(bpb_q[63:32]); q1mi <= $signed(bpb_q[31:0]);
                        s_dly2i  <= first_blk ? 32'sd0 : $signed(dm_rq[63:32]); // delay[2i]
                        s_dly2i1 <= first_blk ? 32'sd0 : $signed(dm_rq[31:0]);  // delay[2i+1]
                        ph <= 5'd2;
                    end
                    5'd2: begin                       // capture buf2[i],buf2[63-i] + delay word B
                        q2ir <= $signed(bpa_q[63:32]); q2ii <= $signed(bpa_q[31:0]);
                        q2mr <= $signed(bpb_q[63:32]); q2mi <= $signed(bpb_q[31:0]);
                        s_dly126 <= first_blk ? 32'sd0 : $signed(dm_rq[63:32]); // delay[126-2i]
                        s_dly127 <= first_blk ? 32'sd0 : $signed(dm_rq[31:0]);  // delay[127-2i]
                        ph <= 5'd3;
                    end
                    5'd3: begin s_ar <= 32'(p0 + p1); s_ai <= 32'(p2 - p3); ph <= 5'd4; end // a
                    5'd4: begin s_br <= 32'(p0 + p1); s_bi <= 32'(p2 - p3); ph <= 5'd5; end // b
                    5'd5: begin s_cr <= 32'(p0 + p1); s_ci <= 32'(p2 - p3); ph <= 5'd6; end // c
                    5'd6: begin s_dr <= 32'(p0 + p1); s_di <= 32'(p2 - p3); ph <= 5'd7; end // d
                    5'd7: begin                       // data[2i], data[255-2i]
                        o2i  <= 32'(p0 - p1);  // delay[2i]*w(255-2i) - a_r*w(2i)
                        o255 <= 32'(p2 + p3);  // delay[2i]*w(2i) + a_r*w(255-2i)
                        ph <= 5'd8;
                    end
                    5'd8: begin                       // data[128+2i], data[127-2i]
                        o128 <= 32'(p0 + p1);  // delay[127-2i]*w(127-2i) + a_i*w(128+2i)
                        o127 <= 32'(p2 - p3);  // delay[127-2i]*w(128+2i) - a_i*w(127-2i)
                        ph <= 5'd9;
                    end
                    5'd9: begin                       // data[2i+1], data[254-2i]
                        o2i1 <= 32'(p0 - p1);  // delay[2i+1]*w(254-2i) - b_i*w(2i+1)
                        o254 <= 32'(p2 + p3);  // delay[2i+1]*w(2i+1) + b_i*w(254-2i)
                        ph <= 5'd10;
                    end
                    5'd10: begin                      // data[129+2i], data[126-2i]
                        o129 <= 32'(p0 + p1);  // delay[126-2i]*w(126-2i) + b_r*w(129+2i)
                        o126 <= 32'(p2 - p3);  // delay[126-2i]*w(129+2i) - b_r*w(126-2i)
                        ph <= 5'd11;
                    end
                    5'd11: ph <= 5'd12;   // pcm[2i]=o2i + delay word A (port-mux)
                    5'd12: ph <= 5'd13;   // pcm[255-2i]=o255 + delay word B (port-mux)
                    5'd13: ph <= 5'd14;   // pcm[128+2i]=o128
                    5'd14: ph <= 5'd15;   // pcm[127-2i]=o127
                    5'd15: ph <= 5'd16;   // pcm[2i+1]=o2i1
                    5'd16: ph <= 5'd17;   // pcm[254-2i]=o254
                    5'd17: ph <= 5'd18;   // pcm[129+2i]=o129
                    default: begin        // ph18: pcm[126-2i]=o126 (port-mux), advance
                        ph <= 5'd0;
                        if (i == 9'd31) begin
                            if (ch != nfm1) begin
                                ch <= ch + 3'd1; i <= 9'd0; st <= S_PRE;
                            end else if (dmx_en) begin
                                dmx_idx <= 9'd0; st <= S_DMX;   // fold 5.1 -> stereo
                            end else begin
                                done <= 1'b1; first_blk <= 1'b0; st <= S_IDLE;
                            end
                        end else begin
                            i <= i + 9'd1;
                        end
                    end
                endcase

                // ---- 5.1 -> stereo downmix, in place over pcm slots 0/1 ----
                // M15: the 5 fbw channels are read one-per-cycle through the single
                // pcm read port (addr issued in the port-mux ph0..ph4, data landing
                // ph1..ph5), then Lo/Ro fold over slots 0/1 (ph6/ph7).  Each dmx_idx
                // reads slots 0..4 before overwriting only 0/1, so it is hazard-free.
                S_DMX: case (ph)
                    4'd0: ph <= 4'd1;
                    4'd1: begin dmx_l  <= pm_rq; ph <= 4'd2; end
                    4'd2: begin dmx_c  <= pm_rq; ph <= 4'd3; end
                    4'd3: begin dmx_r  <= pm_rq; ph <= 4'd4; end
                    4'd4: begin dmx_ls <= pm_rq; ph <= 4'd5; end
                    4'd5: begin dmx_rs <= pm_rq; ph <= 4'd6; end
                    4'd6: ph <= 4'd7;          // pcm[0]=Lo (port-mux)
                    default: begin             // ph7: pcm[1]=Ro (port-mux), advance
                        ph <= 4'd0;
                        if (dmx_idx == 9'd255) begin
                            done <= 1'b1; first_blk <= 1'b0; st <= S_IDLE;
                        end else begin
                            dmx_idx <= dmx_idx + 9'd1;
                        end
                    end
                endcase

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
