// dvd/dts/dts_vec.sv -- the DTS core decoder's vector engine
//
// The hardwired loops, started by the sequencer's `vop` (dts_seq.sv) with their
// arguments in r8..r15 (a0..a7 here). Every op is defined by tools/dts_isa.py
// (Machine.vop), i.e. by tools/dts_fixed.py's arithmetic; bench/dvd/run_dts.sh scores
// the engine buffers after every op by checksum and every PCM pair bit-exact.
// docs/dts_decoder.md sec 10.
//
//   op 0 XCLR    zero the subsubframe's subband buffer X (1,280 words)
//   op 1 XQ      a0 ch, a1 band, a2 abits, a3 selector, a4 scale index, a5 adjustment
//                index, a6 lossless: dequantise the 8 codes dts_seq streams in
//   op 2 XVQ     a0 ch, a1 band, a2 VQ index, a3 ssf, a4 scale index
//   op 3 ADPCM   a0 ch, a1 band, a2 pvq index, a3 predicted?
//   op 4 JOINT   a0 ch, a1 band, a2 source ch, a3 joint scale index
//   op 5 BFLY    a0 ch p, a1 ch q: X[p], X[q] = X[p] + X[q], X[p] - X[q], every band
//   op 6 MIXSYN  a0 j, a1 AMODE, a2..a6 nmix (unused: see V_MX), a7 perfect: for each side, mix
//                column j into 32 subband samples, the half IMDCT into that side's
//                ring, the window; then the 32 PCM pairs out
//   op 7 HCLR    a0 ch, a1 from band: clear the ADPCM history from that band up
//   op 8 CNT     a0 counter (dts_top counts it)
//
// AC-3's ops (docs/ac3_engine.md A2c; tools/ac3_isa.py Machine.run_op, i.e.
// tools/ac3_model.py's arithmetic). The coefficients live in X at {slot, bin} (slots 0-4
// the full-bandwidth channels, 6 LFE), 24-bit Q1.23 sign-extended; AQC's coupling
// coordinates at 0x700 + ch, where the sequencer's item address puts them.
//   op 21 AQ     a0 slot, a2 lo, a3 hi: hi - lo bin items from the mantissa unit, each
//                (m16 << 8) >>> exp, a dither (the LFSR stepped, x 23170, rounded >> 7 +
//                exp; 0 past exp 23), or 0
//   op 22 AQC    a1 lo, a2 hi: the band's channel set and coordinates, then hi - lo bins,
//                each scaled once (or dithered per coupled, dithered channel, in channel
//                order) and recombined into every coupled channel: sat24((c x co) >> 18)
//   op 23 CZERO  a0 slot, a1 lo, a2 hi: X[slot][lo .. min(hi, 256)) = 0
//   op 24 REMAT  a0 flags, a1 end: 2/0 rematrix of bins [13, end), saturating; the
//                active bands' bins, L and R read before either is written
//   op 25 IMDCT  a0 blksw, a1 dynrng, a2 acmod, a4 cmixlev, a5 surmixlev: the block's
//                transform, here (docs/imdct_engine.md). imdct_req waits for imdct_go
//                (the caller's pcm_out has drained the last block); then the term program
//                (dvd/dts/imdct_tprog.mem, tools/imdct_isa.py) runs DRC, PRE, the IFFT
//                schedule and POST for every channel, folding 5.1 into PCM slots 0/1 in
//                the ring; imdct_fin pulses when they hold the block. pcm_ra -> pcm_q
//                reads them (one cycle) whenever the transform is not running.
//
// MP2's ops (docs/mp2_engine.md M2; tools/mp2_isa.py Machine, which proves each against
// tools/mp2_ref.py's own functions on every op). The samples live in X at {k, ch, sb}
// (27 bits: |S| < 2^25), V in the ring at {ch, i} (2 x 1,024, 31 bits: |V| <= 2^30);
// neither ever saturates (proved there), so neither op clips.
//   op 26 MDQ    a0 X address, a1 x16, a2 d16, a3 class, a4 scalefactor index:
//                S = floor(floor((x16 C + d16 C) / 2^7) SCF / 2^20), C and SCF from icoef
//   op 27 MSYN   a0 k, a1 mono: per channel (channel 0 only
//                if mono) the offset -= 64; the matrix, 2,048 MACs, V = floor(sum / 2^14)
//                into the ring; the window in two passes of 512 (V is 31 bits): the low
//                halves into b2 as floor(sum / 2^16), then the high halves on top of it,
//                floor(sum / 2), clip24, the PCM stage; then 32 pairs out (mono: L twice)
//   op 28 RCLR   zero the ring and b2 (DTS's and MP2's RESET: the two share them)
//   op 29 MFS    no vector work (as CNT): dts_top latches a0, the stream's rate
// A refusal mid-AQ / AQC (abort, the sequencer's err_valid) ends the op WITHOUT done,
// after the item in flight and the one still pending: the emulator stepped the dither
// LFSR for every item the sequencer emitted. The LFSR (power-up 1) lives here; its
// table is in the IMDCT program ROM at 768 (AC-3 never runs that program).
//
// ONE DATAPATH, two stages: a previously built decoder of this kind closed timing only
// once its multiply and its round / clip chain had a cycle each. Issue (the per-state
// wiring below): the operands, the accumulator's preset, the rounding, the addend and
// the write addresses of one element; the product is registered (in the DSP block)
// with all of them. Stage Y, a cycle later: sum = (clear ? preset : acc) + product;
// round half up (or floor) by a variable shift; optionally clip23 before the addend
// (ADPCM's two clips); negate (the IMDCT's x - round(c y)); add; shift left (the
// IMDCT's pre-shift undone); clip23; write. PCM takes one more registered stage
// (round to s16, saturate) into a 32-pair buffer per side.
//
// THE HALF IMDCT is a ROM program of 597 multiply-accumulate terms
// (tools/dts_vecrom.py, which proves it equal to FFmpeg's imdct_half_32), executed
// one term a cycle through a three-deep pipeline: fetch the term, read its scratch
// word and coefficient, issue. Each of its seven stages writes the scratch region the
// next one reads, so the first term of a stage is held two cycles at the boundary
// until the previous stage's last write has landed.
//
// Codebooks (D4) are off-chip: a request for one 64-bit row (cb_sel 0: an ADPCM
// vector, 4 x int16 at [16i +: 16]; 1: a VQ vector's slice for subsubframe ssf,
// 8 x int8 at [8k +: 8], cb_addr = {index, ssf}), answered by cb_valid any number of
// cycles later. P1b fetches on demand: docs/dts_decoder.md "P1b" records the cost.
//
// Quartus 17 (CLAUDE.md): no `function`s and no N'(expr) size casts; sign extension
// by replication; every RAM a power-of-two depth or a ROM.

`default_nettype none

module dts_vec (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          start,
    input  wire    [5:0] op,
    input  wire  [127:0] args,
    output logic         done,

    input  wire   [23:0] xq_code,
    input  wire          xq_valid,
    output logic         xq_ready,

    output logic         cb_req,
    output logic         cb_sel,
    output logic  [11:0] cb_addr,
    input  wire          cb_valid,
    input  wire   [63:0] cb_data,

    output logic  [15:0] pcm_l,
    output logic  [15:0] pcm_r,
    output logic         pcm_valid,
    input  wire          pcm_ready,

    // AC-3
    input  wire   [10:0] xq_addr,
    input  wire          abort,
    output logic         imdct_req,          // op 25 waits for imdct_go
    input  wire          imdct_go,           // pcm_out has drained the last block
    output logic         imdct_fin,          // pulse: PCM slots 0/1 hold this block
    input  wire    [8:0] pcm_ra,             // {slot, idx}
    output logic  [31:0] pcm_q,
    // X's read port while op 25 waits for imdct_go (benches score the coefficients
    // there; the core ties it off): {slot, bin}, one cycle
    input  wire   [10:0] coef_ra,
    output logic  [24:0] coef_q
);

`include "dvd/dts/dts_ucode.svh"
`include "dvd/dts/dts_vec.svh"
`include "dvd/dts/imdct_isa.svh"
// imdct_512's own tables (docs/imdct_engine.md: the same ROM images, so the same values).
// A bench that compiles imdct_512 too includes the file twice in one compilation unit:
// undef its guard on both sides of this include, so each module gets its own copy.
`undef AC3_IMDCT_TABLES_SVH
`include "dvd/ac3/ac3_imdct_tables.svh"
`undef AC3_IMDCT_TABLES_SVH

    localparam [5:0] OP_XCLR = 6'd0, OP_XQ = 6'd1, OP_XVQ = 6'd2, OP_ADPCM = 6'd3,
                     OP_JOINT = 6'd4, OP_BFLY = 6'd5, OP_MIXSYN = 6'd6, OP_HCLR = 6'd7;
    localparam [9:0] IP_DITH = 10'd768;      // the dither LFSR's table in the iprog ROM

    // ------------------------------------------------------------------ ROMs
    logic [23:0] vk    [0:VK_WORDS-1];
    logic [23:0] win   [0:1023];
    logic [19:0] iprog [0:1023];             // the IMDCT program; AC-3's dither table at 768
    logic [26:0] icoef [0:255];              // the IMDCT's; MP2's C at 128, SCF at 160
    logic [15:0] mn    [0:2047];             // MP2 N (Q1.14) {i, k}
    logic [17:0] mw    [0:511];              // MP2 D (Q2.16)
    initial begin
        $readmemh("dvd/dts/dts_vconst.mem", vk);
        $readmemh("dvd/dts/dts_win.mem", win);
        $readmemh("dvd/dts/dts_iprog.mem", iprog);
        $readmemh("dvd/dts/dts_icoef.mem", icoef);
        $readmemh("dvd/dts/dts_mp2n.mem", mn);
        $readmemh("dvd/dts/dts_mp2d.mem", mw);
    end

    // ------------------------------------------------------------------ RAMs
    (* ramstyle = "M10K" *) logic [26:0] xb   [0:2047];   // X {ch, band, j}: 25 bits (a butterflied
                                                          // band); MP2's samples 27
    (* ramstyle = "M10K" *) logic [23:0] hb   [0:1023];   // ADPCM history {ch, band, k}, k 0 the oldest
    (* ramstyle = "M10K" *) logic [34:0] ring [0:2047];   // IMDCT rings {0, side, i}, 24 bits;
                                                          // MP2's V {ch, i}, 31 bits; AC-3's
                                                          // IMDCT: 32-bit words, 33-bit pre-sums
                                                          // (35 wide: still 7 M10K at 2K x 5)
    // the four small buffers share one M10K (each alone took a block): their phases
    // never overlap -- the IMDCT scratch (mix, IMDCT), the window's carried sums
    // (window) and the PCM pairs (written by the window's outputs, read by the emit):
    //   0..63    sc  {region, i}   the IMDCT scratch, 24 bits
    //   64..127  b2  {side, i}     the window's carried partial sums, 29 bits
    //   128..191 pcm {side, i}     the 32 PCM pairs, 16 bits (L then R)
    (* ramstyle = "M10K" *) logic [28:0] sm [0:255];
    initial begin                    // as the emulator: every buffer starts at zero
        for (int n = 0; n < 2048; n++) begin xb[n] = 27'd0; ring[n] = 35'd0; end
        for (int n = 0; n < 1024; n++) hb[n] = 24'd0;
        for (int n = 0; n < 256; n++) sm[n] = 29'd0;
    end

    logic [10:0] xb_ra;  logic [26:0] xb_q;
    logic  [9:0] hb_ra;  logic [23:0] hb_q;
    logic [10:0] rg_ra;  logic [34:0] rg_q;
    logic  [5:0] b2_ra, sc_ra;
    logic  [7:0] sm_ra;  logic [28:0] sm_q;
    logic  [4:0] pb_ra;
    logic        pb_r;                                    // the emit reads R (else L)
    wire  [28:0] b2_q = sm_q;
    wire  [23:0] sc_q = sm_q[23:0];
    logic [15:0] pl_hold;                                 // the emit's L, while R is read
    logic  [8:0] vk_ra;  logic [23:0] vk_q;
    logic  [9:0] wn_ra;  logic [23:0] wn_q;
    logic  [9:0] ip_ra;  logic [19:0] ip_q;
    logic  [7:0] ic_ra;  logic [26:0] ic_q;
    logic [10:0] mn_ra;  logic [15:0] mn_q;
    logic  [8:0] mw_ra;  logic [17:0] mw_q;

    // stage-Y write controls (the issue-side controls, registered)
    logic        x_xb_we, x_hb_we, x_rg_we, x_b2_we, x_sc_we, x_p_we, x_mag_en, x_w35;
    logic [10:0] x_xb_wa;
    logic  [9:0] x_hb_wa;
    logic [10:0] x_rg_wa;
    logic  [5:0] x_b2_wa, x_sc_wa, x_p_wa;
    logic signed [55:0] res;
    // the PCM stage: res registered, then rounded to s16 and saturated
    logic        p_we;
    logic  [5:0] p_wa;                                    // {side, idx}
    logic signed [23:0] p_val;
    wire  signed [24:0] p_rnd = ($signed({p_val[23], p_val}) + 25'sd128) >>> 8;
    wire  signed [15:0] p_s16 = (p_rnd > 25'sd32767) ? 16'sh7FFF :
                                (p_rnd < -25'sd32768) ? 16'sh8000 : p_rnd[15:0];

    assign pcm_q = rg_q[31:0];
    assign coef_q = xb_q[24:0];
    // the ring's write: a 32-bit word sign-extended, or (the IMDCT's pre-sums) 35 bits
    wire  [34:0] rg_wd = x_w35 ? res[34:0] : {{3{res[31]}}, res[31:0]};
    always_ff @(posedge clk) begin
        xb_q <= xb[xb_ra];    if (x_xb_we) xb[x_xb_wa] <= res[26:0];
        hb_q <= hb[hb_ra];    if (x_hb_we) hb[x_hb_wa] <= res[23:0];
        rg_q <= ring[rg_ra];  if (x_rg_we) ring[x_rg_wa] <= rg_wd;
        sm_q <= sm[sm_ra];
        if (x_sc_we)      sm[{2'b00, x_sc_wa}] <= res[28:0];
        else if (x_b2_we) sm[{2'b01, x_b2_wa}] <= res[28:0];
        else if (p_we)    sm[{2'b10, p_wa}]    <= {13'd0, p_s16};
        vk_q <= vk[vk_ra];
        wn_q <= win[wn_ra];
        ip_q <= iprog[ip_ra];
        ic_q <= icoef[ic_ra];
        mn_q <= mn[mn_ra];
        mw_q <= mw[mw_ra];
    end

    // ------------------------------------------------------------------ state
    typedef enum logic [5:0] {
        V_IDLE, V_LOOP, V_DRAIN, V_DONE,
        V_XQ0, V_XQ1, V_XQ2, V_XQ2W, V_XQ3, V_XQ4, V_XQ4W, V_XQ5, V_XQ6, V_XQ6W, V_XQ7,
        V_VQ0, V_VQ1, V_JO0, V_JO1,
        V_AD0, V_AD1, V_AD2, V_AD3,
        V_BF,
        V_MX, V_IPS, V_IP, V_WIN, V_WINW, V_EMIT, V_EMITL, V_EMITW,
        // MP2
        V_MQ0, V_MQ1, V_MQ2, V_MQ3, V_MQ4, V_MS0, V_MM, V_MWIN, V_MWW,
        // AC-3
        V_AW, V_AD, V_CSC, V_CCH, V_CD1, V_CD2, V_CMUL, V_CZ, V_RM, V_IM, V_IMX
    } vstate_t;
    vstate_t st;
    logic  [5:0] vop;
    logic [15:0] a0, a1, a2, a3, a4, a5, a6, a7;
    logic [11:0] k, k_d, lcnt;
    logic        dv;
    logic [23:0] sreg;                       // a scale (XQ, XVQ), a joint scale
    logic [46:0] ss;                         // XQ: step x scale
    logic [23:0] ss2;                        // ... >> shift (<= 2^23)
    logic  [4:0] shreg, qsh;
    logic [63:0] cb_row;
    logic        cb_got;
    logic [23:0] h0, h1, h2, h3;             // ADPCM history, h0 the oldest
    logic  [2:0] aj, as;                     // ADPCM sample, issue step (0..4)
    logic [24:0] bf_a, bf_c;                 // BFLY: X[p], X[q] of the element
    logic        side;
    logic  [9:0] off0, off1;                 // the rings' offsets (FFmpeg's synth offset,
                                             // [8:0]); MP2's voff, all ten bits
    logic [28:0] mag;                        // the mixed column's sum of |v|
    logic        pshift;                     // the IMDCT pre-shift is 2 (else 0)
    logic  [2:0] nch;
    logic  [4:0] mb_b, mb_bd;                // mix: band read, band issued
    logic  [2:0] mb_c, mb_cd;                // mix: channel read, channel issued
    logic        mx_go;
    logic  [9:0] ip_d;                       // IMDCT: the term in ip_q (the read stage)
    logic        ip_dv;
    logic [19:0] ip_i;                       // the term being issued
    logic        ip_iv, ip_bub;
    logic  [7:0] outn;                       // outputs issued: {stage, index}
    logic        fresh;                      // the next MAC term starts a sum
    logic signed [55:0] ahold;               // the output's addend
    logic  [8:0] w, w_d;                     // window element {q, i, tap}
    logic        w_go;

    wire  [8:0] off  = side ? off1[8:0] : off0[8:0];
    wire  [9:0] moff = side ? off1 : off0;

    // AC-3: the item at the port, the bin being scattered, the LFSR
    localparam [5:0] OP_AQ = 6'd21, OP_AQC = 6'd22, OP_CZERO = 6'd23, OP_REMAT = 6'd24,
                     OP_IMDCT = 6'd25;
    wire        i_set  = xq_addr == 11'h7F0;                  // AQC's channel set
    wire        i_co   = (xq_addr[10:8] == 3'd7) && !i_set;    // a coordinate
    wire [16:0] i_m16  = xq_code[16:0];
    wire  [4:0] i_e    = xq_code[21:17];
    wire        i_b0   = xq_code[22];
    wire        i_dith = xq_code[23];
    logic [15:0] lfsr;
    wire  [15:0] lfsr_n = ip_q[15:0] ^ {lfsr[7:0], 8'd0};     // the table read last cycle
    logic  [4:0] c_dm, c_chin, c_e;
    logic  [2:0] c_nf, c_slot, c_ch;
    logic  [7:0] c_bin;
    logic        c_b0, ab;
    logic [23:0] creg;                                        // a bin's scaled or dithered value
    logic  [7:0] rb;                                          // REMAT's bin
    logic  [1:0] rph;
    wire  [1:0] r_band = (rb < 8'd25) ? 2'd0 : (rb < 8'd37) ? 2'd1 : (rb < 8'd61) ? 2'd2 : 2'd3;
    wire        r_act  = a0[r_band];
    wire signed [26:0] lf27  = {{11{lfsr_n[15]}}, lfsr_n};
    wire signed [26:0] creg27 = {{3{creg[23]}}, creg};
    wire signed [55:0] i_scl = {{31{i_m16[16]}}, i_m16, 8'd0};

    // sign extensions (named, no casts)
    wire signed [26:0] xq27   = {{3{xq_code[23]}}, xq_code};
    wire signed [26:0] xb27   = {{2{xb_q[24]}}, xb_q[24:0]};
    wire signed [26:0] sc27   = {{3{sc_q[23]}}, sc_q};
    wire signed [26:0] rg27   = {{3{rg_q[23]}}, rg_q[23:0]};
    wire signed [26:0] wn27   = {{3{wn_q[23]}}, wn_q};
    wire signed [26:0] vk27   = {3'd0, vk_q};
    wire signed [26:0] sreg27 = {3'd0, sreg};
    wire signed [26:0] ss27   = {3'd0, ss2};
    wire signed [26:0] hs0 = {{3{h0[23]}}, h0}, hs1 = {{3{h1[23]}}, h1};
    wire signed [26:0] hs2 = {{3{h2[23]}}, h2}, hs3 = {{3{h3[23]}}, h3};
    wire signed [26:0] cs0 = {{11{cb_row[15]}}, cb_row[15:0]};
    wire signed [26:0] cs1 = {{11{cb_row[31]}}, cb_row[31:16]};
    wire signed [26:0] cs2 = {{11{cb_row[47]}}, cb_row[47:32]};
    wire signed [26:0] cs3 = {{11{cb_row[63]}}, cb_row[63:48]};
    logic [7:0] vq_b;
    always_comb vq_b = cb_row[{k_d[2:0], 3'd0} +: 8];
    wire signed [26:0] vq27 = {{19{vq_b[7]}}, vq_b};

    // XQ: Huffman-coded bands take the adjusted scale (the sequencer's own rule)
    wire  [3:0] q_abm1  = a2[3:0] - 4'd1;
    wire  [3:0] q_gsize = XQ_GSIZE[4 * q_abm1 +: 4];
    wire        q_huff  = (a2[4:0] <= 5'd10) && ({1'b0, a3[2:0]} < q_gsize);
    wire  [8:0] q_sidx  = a4[8] ? (VK_SCALE7 + {2'd0, a4[6:0]}) : (VK_SCALE6 + {3'd0, a4[5:0]});
    // XQ: shift = ss > 2^23 ? the bit length of ss >> 23 : 0
    logic [4:0] ss_len;
    always_comb begin
        ss_len = 5'd0;
        for (int b = 0; b < 24; b++) if (ss[23 + b]) ss_len = b + 1;
    end
    wire ss_gt = (ss[46:23] > 24'd1) || (ss[46:23] == 24'd1 && ss[22:0] != 23'd0);

    // the IMDCT term being issued, and its output's place
    wire        ti_last = ip_i[14];
    wire        ti_add  = ip_i[15];
    wire  [1:0] ti_rsh  = ip_i[17:16];
    wire        ti_neg  = ip_i[18];
    wire        ti_shl  = ip_i[19];
    wire  [2:0] o_stage = outn[7:5];
    wire  [4:0] o_idx   = outn[4:0];
    wire        ip_final = ip_iv && ti_last && (o_idx == 5'd31) && (o_stage != 3'd6);

    // the window: element {q, i, tap}; ring index (q*16 +- i) + 64 tap + offset
    wire  [1:0] w_q  = w[8:7];
    wire  [3:0] w_i  = w[6:3];
    wire  [2:0] w_t  = w[2:0];
    wire  [4:0] w_k  = {w_q[1], w_q[0] ? ~w_i : w_i};
    wire  [8:0] w_rg = off + {w_t, 6'd0} + {4'd0, w_k};
    wire  [1:0] wd_q = w_d[8:7];
    wire  [3:0] wd_i = w_d[6:3];
    wire  [2:0] wd_t = w_d[2:0];

    // the mix: gain index AMODE*10 + ch*2 + side
    wire  [8:0] mx_g = VK_GAIN + {2'd0, a1[3:0], 3'd0} + {4'd0, a1[3:0], 1'b0} +
                       {5'd0, mb_c, 1'b0} + {8'd0, side};

    // MP2: MSYN's matrix element k = {i, kk}; its window element {pass, j, tap}, as read
    // (k) and as issued (k_d). D[j + 64 (t / 2) + 32 (t % 2)] is D[{t, j}]; the ring
    // index voff + j + 128 (t / 2) + 96 (t % 2) is voff + {t[3:1], t[0], t[0], j}
    localparam [5:0] OP_MDQ = 6'd26, OP_MSYN = 6'd27, OP_RCLR = 6'd28;
    wire  [4:0] mw_j  = k[8:4];
    wire  [3:0] mw_t  = k[3:0];
    wire        mwd_p = k_d[9];
    wire  [4:0] mwd_j = k_d[8:4];
    wire  [3:0] mwd_t = k_d[3:0];
    wire  [9:0] mw_rg = moff + {mw_t[3:1], mw_t[0], mw_t[0], mw_j};
    wire  [9:0] mm_rg = moff + {4'd0, k_d[10:5]};
    wire        m_mono = (vop == OP_MSYN) && a1[0];
    wire signed [26:0] mn27  = {{11{mn_q[15]}}, mn_q};
    wire signed [26:0] mw27  = {{9{mw_q[17]}}, mw_q};
    wire signed [26:0] vlo27 = {11'd0, rg_q[15:0]};
    wire signed [26:0] vhi27 = {{11{rg_q[31]}}, rg_q[31:16]};
    wire signed [26:0] s27   = xb_q;

    // ------------------------------------------------------------------ AC-3's IMDCT
    // docs/imdct_engine.md; tools/imdct_isa.py is this, term for term and cycle for cycle.
    // Three stages ahead of the shared datapath:
    //   F  the walker: element (phase, channel, index) and term t; presents the term ROM
    //      address; prefetches the next element's fftorder / schedule entry
    //   R  the term word: resolves its sample, constant and destination symbols against
    //      the element's context and presents the ring / X / constant reads; STALLS while
    //      its ring word has a write in flight (the term in I or in stage Y)
    //   I  the term issues on the multiplier (the per-state wiring, V_IMX)
    (* ramstyle = "M10K" *) logic [19:0] tprog [0:IM_TP_WORDS-1];
    initial $readmemh("dvd/dts/imdct_tprog.mem", tprog);
    logic [19:0] tp_q;
    logic  [9:0] tp_ra;
    logic signed [17:0] wn_im_q;
    logic  [7:0] wn_im_ra;
    logic [35:0] pre_q, post_q;
    logic  [7:0] pre_ra;
    logic  [6:0] post_ra;
    logic  [7:0] fo_q;
    logic  [6:0] fo_ra;
    logic [70:0] sched_q;
    logic  [8:0] sched_ra;
    // F
    logic        f_v, f_short;
    logic  [2:0] f_ch;
    logic  [1:0] f_ph;                       // 0 DRC, 1 PRE, 2 IFFT, 3 POST
    logic  [7:0] f_cnt;                      // the element: j (DRC), i, the butterfly
    logic  [6:0] f_t;                        // its term
    logic  [4:0] f_kind;
    logic  [7:0] f_a0, f_a1;
    logic  [6:0] f_s0, f_s1, f_s2, f_s3;
    logic signed [17:0] f_wr, f_wi;
    // R
    logic        r_v, r_short;
    logic  [2:0] r_ch;
    logic  [1:0] r_ph;
    logic  [7:0] r_cnt, r_a0, r_a1;
    logic  [6:0] r_s0, r_s1, r_s2, r_s3;
    logic signed [17:0] r_wr, r_wi;
    // I
    logic        i_v, i_prod, i_drc, i_krom, i_kim, i_dstv, i_w35;
    logic  [1:0] i_mode, i_srck, i_kromsel;
    logic signed [26:0] i_kv;
    logic [10:0] i_dst;
    // per block
    logic  [4:0] im_vld;                     // a channel's delay line is valid (since reset)
    logic [10:0] im_ra;                      // R: the ring read
    logic        im_hz;                      // R: stall
    // the block's parameters (the op's arguments)
    wire  [2:0] im_acmod = a2[2:0];
    wire  [2:0] im_nf = (im_acmod == 3'd1) ? 3'd1 : (im_acmod == 3'd3 || im_acmod == 3'd4) ? 3'd3 :
                        (im_acmod == 3'd5 || im_acmod == 3'd6) ? 3'd4 : (im_acmod == 3'd7) ? 3'd5 : 3'd2;
    wire  [5:0] im_mant = {1'b1, a1[4:0]};                   // 32 + dynrng[4:0]
    wire  [3:0] im_drc_sh = 4'd5 - {a1[7], a1[7:5]};         // 5 - e, e signed in [7:5]
    wire        im_has_c = (im_acmod == 3'd3) || (im_acmod == 3'd5) || (im_acmod == 3'd7);
    wire        im_has_s = im_acmod[2];
    wire        im_mono_s = (im_acmod == 3'd4) || (im_acmod == 3'd5);
    logic [17:0] im_clev, im_slev;
    always_comb begin
        case (a4[1:0])
            2'd0: im_clev = 18'd92682;
            2'd2: im_clev = 18'd65536;
            default: im_clev = 18'd77933;
        endcase
        if (!im_has_c || im_nf <= 3'd2) im_clev = 18'd0;
        case (a5[1:0])
            2'd0: im_slev = im_mono_s ? 18'd65536 : 18'd92682;
            2'd1: im_slev = im_mono_s ? 18'd46341 : 18'd65536;
            default: im_slev = 18'd0;
        endcase
        if (!im_has_s) im_slev = 18'd0;
    end
    // the fold class of channel f_ch (tools/imdct_isa.py CLASSES: D0 D1 A1 C S LS RS NONE)
    logic [2:0] im_cls;
    always_comb begin
        if (im_nf <= 3'd2) im_cls = (f_ch == 3'd0) ? 3'd0 : 3'd1;
        else if (f_ch == 3'd0) im_cls = 3'd0;                                    // L
        else if (im_has_c && f_ch == 3'd1) im_cls = 3'd3;                        // C
        else if (f_ch == (im_has_c ? 3'd2 : 3'd1)) im_cls = im_has_c ? 3'd2 : 3'd1;   // R
        else if (im_slev == 18'd0) im_cls = 3'd7;                                // a silent surround
        else if (im_mono_s) im_cls = 3'd4;
        else im_cls = (f_ch == (im_has_c ? 3'd3 : 3'd2)) ? 3'd5 : 3'd6;          // LS, RS
    end
    // F: the term ROM address, the element's length
    wire  [9:0] f_kb  = IM_KB[f_kind * 10 +: 10];
    wire  [6:0] f_kl  = IM_KL[f_kind * 7 +: 7];
    wire        f_lastt = (f_t == f_kl - 7'd1);
    wire  [7:0] f_last  = (f_ph == 2'd0) ? 8'd255 : (f_ph == 2'd1) ? 8'd127 :
                          (f_ph == 2'd2) ? (f_short ? 8'd133 : 8'd156) : (f_short ? 8'd31 : 8'd63);
    wire  [7:0] f_nxt = f_cnt + 8'd1;
    always_comb begin
        tp_ra    = f_kb + {3'd0, f_t};
        fo_ra    = (f_ph == 2'd1) ? (f_short ? {1'b0, f_nxt[5:0]} : f_nxt[6:0]) : 7'd0;
        sched_ra = (f_short ? 9'd157 : 9'd0) + ((f_ph == 2'd2) ? {1'b0, f_nxt} : 9'd0);
        if (st == V_IM) sched_ra = a0[0] ? 9'd157 : 9'd0;    // channel 0's entry 0 (ISKIP)
    end
    // the short-block PRE pair from fftorder (imdct_512: buf2 = i >= 64)
    wire  [7:0] fo_nx = f_nxt;                      // the PRE element the prefetch is for
    // R: resolve the term's sample, destination and constant symbols
    wire  [1:0] r_mode = tp_q[1:0];
    wire  [5:0] r_src  = tp_q[7:2];
    wire  [3:0] r_cst  = tp_q[11:8];
    wire  [5:0] r_dst  = tp_q[17:12];
    logic [10:0] ra_q [0:1];                // [0] the sample's, [1] the destination's
    logic  [1:0] r_srck;                    // 0 ring, 1 X, 2 zero (an invalid delay word)
    // the resolver's temporaries, one set per symbol (module scope: Quartus 17)
    logic  [5:0] sy_q [0:1], d_q [0:1];
    logic  [6:0] ix_q [0:1], j7_q [0:1];
    logic  [7:0] kk_q [0:1];
    always_comb begin
        for (int q = 0; q < 2; q++) begin
            sy_q[q] = q ? r_dst : r_src;
            d_q[q] = 6'd0; ix_q[q] = 7'd0; j7_q[q] = 7'd0; kk_q[q] = 8'd0;
            ra_q[q] = 11'd0;
            if (sy_q[q] >= IM_S_C && sy_q[q] < IM_S_T) begin                 // c0r .. c3i
                d_q[q] = sy_q[q] - IM_S_C;
                case (d_q[q][2:1])
                    2'd0: ix_q[q] = r_s0;  2'd1: ix_q[q] = r_s1;  2'd2: ix_q[q] = r_s2;  default: ix_q[q] = r_s3;
                endcase
                ra_q[q] = {3'b000, ix_q[q], d_q[q][0]};
            end else if (sy_q[q] >= IM_S_T && sy_q[q] < IM_S_DA0) begin      // t0 .. t15
                d_q[q] = sy_q[q] - IM_S_T;
                ra_q[q] = IM_R_TMP + {7'd0, d_q[q][3:0]};
            end else if (sy_q[q] == IM_S_DA0) ra_q[q] = IM_R_D + {3'd0, r_a0};
            else if (sy_q[q] == IM_S_DA1) ra_q[q] = IM_R_D + {3'd0, r_a1};
            else if (sy_q[q] == IM_S_BIR || sy_q[q] == IM_S_BII) ra_q[q] = {3'b000, r_cnt[6:0], sy_q[q] == IM_S_BII};
            else if (sy_q[q] == IM_S_DJ) ra_q[q] = IM_R_D + {3'd0, r_cnt};
            else if (sy_q[q] >= IM_S_B && sy_q[q] < IM_S_DL) begin           // bA .. bD, r / i
                d_q[q] = sy_q[q] - IM_S_B;
                case (d_q[q][2:1])
                    2'd0: ix_q[q] = r_cnt[6:0];
                    2'd1: ix_q[q] = 7'd63 - r_cnt[6:0];
                    2'd2: ix_q[q] = 7'd64 + r_cnt[6:0];
                    default: ix_q[q] = 7'd127 - r_cnt[6:0];
                endcase
                ra_q[q] = {3'b000, ix_q[q], d_q[q][0]};
            end else if (sy_q[q] >= IM_S_DL && sy_q[q] < IM_S_P) begin       // dl0 .. dl3
                d_q[q] = sy_q[q] - IM_S_DL;
                case (d_q[q][1:0])
                    2'd0: j7_q[q] = {r_cnt[5:0], 1'b0};
                    2'd1: j7_q[q] = {r_cnt[5:0], 1'b1};
                    2'd2: j7_q[q] = 7'd126 - {r_cnt[5:0], 1'b0};
                    default: j7_q[q] = 7'd127 - {r_cnt[5:0], 1'b0};
                endcase
                ra_q[q] = {4'd6 + {1'b0, r_ch}, j7_q[q]};
            end else if (sy_q[q] >= IM_S_P) begin                       // p{slot}_{n}
                d_q[q] = sy_q[q] - IM_S_P;
                if (r_short) case (d_q[q][2:0])
                    3'd0: kk_q[q] = {r_cnt[6:0], 1'b0};
                    3'd1: kk_q[q] = 8'd255 - {r_cnt[6:0], 1'b0};
                    3'd2: kk_q[q] = 8'd128 + {r_cnt[6:0], 1'b0};
                    3'd3: kk_q[q] = 8'd127 - {r_cnt[6:0], 1'b0};
                    3'd4: kk_q[q] = {r_cnt[6:0], 1'b1};
                    3'd5: kk_q[q] = 8'd254 - {r_cnt[6:0], 1'b0};
                    3'd6: kk_q[q] = 8'd129 + {r_cnt[6:0], 1'b0};
                    default: kk_q[q] = 8'd126 - {r_cnt[6:0], 1'b0};
                endcase else case (d_q[q][1:0])
                    2'd0: kk_q[q] = {r_cnt[6:0], 1'b0};
                    2'd1: kk_q[q] = 8'd255 - {r_cnt[6:0], 1'b0};
                    2'd2: kk_q[q] = {r_cnt[6:0], 1'b1};
                    default: kk_q[q] = 8'd254 - {r_cnt[6:0], 1'b0};
                endcase
                ra_q[q] = {2'b11, d_q[q][3], kk_q[q]};
            end
        end
        im_ra = ra_q[0];
        r_srck = (r_src == IM_S_XJ) ? 2'd1 :
                 (r_src >= IM_S_DL && r_src < IM_S_P && !im_vld[r_ch]) ? 2'd2 : 2'd0;
        // the constant: a window tap, a PRE / POST twiddle (the ROMs, read now), or a value
        case (r_cst)
            IM_C_WA0: wn_im_ra = {r_cnt[6:0], 1'b0};
            IM_C_WB0: wn_im_ra = 8'd255 - {r_cnt[6:0], 1'b0};
            IM_C_WA1: wn_im_ra = r_short ? 8'd127 - {r_cnt[6:0], 1'b0} : {r_cnt[6:0], 1'b1};
            IM_C_WB1: wn_im_ra = r_short ? 8'd128 + {r_cnt[6:0], 1'b0} : 8'd254 - {r_cnt[6:0], 1'b0};
            IM_C_WA2: wn_im_ra = {r_cnt[6:0], 1'b1};
            IM_C_WB2: wn_im_ra = 8'd254 - {r_cnt[6:0], 1'b0};
            IM_C_WA3: wn_im_ra = 8'd126 - {r_cnt[6:0], 1'b0};
            default:  wn_im_ra = 8'd129 + {r_cnt[6:0], 1'b0};
        endcase
        pre_ra  = r_short ? {2'b10, r_cnt[5:0]} : {1'b0, r_cnt[6:0]};
        post_ra = r_short ? {2'b10, r_cnt[4:0]} : {1'b0, r_cnt[5:0]};
        // stall: the ring word has a write in flight (the term in I, the one in stage Y)
        im_hz = r_v && (r_srck != 2'd1) &&
                ((i_v && i_dstv && i_dst == im_ra) || (x_rg_we && x_rg_wa == im_ra));
    end
    always_ff @(posedge clk) begin
        if (!im_hz) tp_q <= tprog[tp_ra];   // held while R stalls: R still needs its word
        wn_im_q <= imdct_window[wn_im_ra];
        pre_q   <= imdct_pre_pk[pre_ra];
        post_q  <= imdct_post_pk[post_ra];
        fo_q    <= imdct_fftorder[fo_ra];
        sched_q <= imdct_sched_pk[sched_ra];
    end
    // F, R, I
    always_ff @(posedge clk) begin
        if (st == V_IM && imdct_go) begin               // the block starts: channel 0, DRC
            f_v <= 1'b1; f_ch <= 3'd0; f_short <= a0[0]; f_ph <= 2'd0; f_cnt <= 8'd0;
            f_t <= 7'd0; f_kind <= IM_K_DRC;
            r_v <= 1'b0; i_v <= 1'b0;
            // ISKIP (a7[0], benches only): start at the IFFT, on a work buffer and delay
            // line the bench has written -- the only way to reach 33-bit pre-sums, which
            // no coefficient block does through PRE (docs/imdct_engine.md I2). The
            // schedule entry is channel 0's first, read while op 25 waited (>= 1 cycle).
            if (a7[0]) begin
                f_ph <= 2'd2;
                f_kind <= IM_K_OP + {2'd0, sched_q[70:68]};
                f_s0 <= sched_q[66:60]; f_s1 <= sched_q[58:52];
                f_s2 <= sched_q[50:44]; f_s3 <= sched_q[42:36];
                f_wr <= $signed(sched_q[35:18]); f_wi <= $signed(sched_q[17:0]);
            end
        end else if (st == V_IMX && !im_hz) begin
            // R <- F
            r_v <= f_v; r_ch <= f_ch; r_short <= f_short; r_ph <= f_ph; r_cnt <= f_cnt;
            r_a0 <= f_a0; r_a1 <= f_a1; r_s0 <= f_s0; r_s1 <= f_s1; r_s2 <= f_s2; r_s3 <= f_s3;
            r_wr <= f_wr; r_wi <= f_wi;
            // I <- R
            i_v <= r_v;
            i_mode <= r_mode; i_srck <= r_srck;
            i_dst <= ra_q[1]; i_dstv <= (r_dst != 6'd0); i_w35 <= tp_q[18];
            i_drc  <= (r_cst == IM_C_MANT);
            i_prod <= (r_cst != IM_C_NONE) && (r_cst != IM_C_MANT);
            i_krom <= (r_cst >= IM_C_PR) && (r_cst <= IM_C_WB3);
            i_kromsel <= (r_cst >= IM_C_WA0) ? 2'd0 : (r_ph == 2'd1) ? 2'd1 : 2'd2;
            i_kim <= (r_cst == IM_C_PI);
            case (r_cst)
                IM_C_WR:   i_kv <= {{9{r_wr[17]}}, r_wr};
                IM_C_WI:   i_kv <= {{9{r_wi[17]}}, r_wi};
                IM_C_MANT: i_kv <= {21'd0, im_mant};
                IM_C_CLEV: i_kv <= {9'd0, im_clev};
                IM_C_SLEV: i_kv <= {9'd0, im_slev};
                default:   i_kv <= 27'sd1;                  // an add: the sample itself
            endcase
            // F: the next term, or the next element
            if (f_v) begin
                if (!f_lastt) f_t <= f_t + 7'd1;
                else begin
                    f_t <= 7'd0;
                    f_cnt <= (f_cnt == f_last) ? 8'd0 : f_nxt;
                    case (f_ph)
                        2'd0: if (f_cnt == f_last) begin            // DRC -> PRE, element 0
                            f_ph <= 2'd1; f_kind <= IM_K_PRE;
                            f_a0 <= fo_q;
                            f_a1 <= f_short ? 8'd254 - fo_q : 8'd255 - fo_q;
                        end
                        2'd1: if (f_cnt == f_last) begin            // PRE -> IFFT, butterfly 0
                            f_ph <= 2'd2;
                            f_kind <= IM_K_OP + {2'd0, sched_q[70:68]};
                            f_s0 <= sched_q[66:60]; f_s1 <= sched_q[58:52];
                            f_s2 <= sched_q[50:44]; f_s3 <= sched_q[42:36];
                            f_wr <= $signed(sched_q[35:18]); f_wi <= $signed(sched_q[17:0]);
                        end else begin                              // PRE element i + 1
                            f_a0 <= (f_short && fo_nx[6]) ? fo_q + 8'd1 : fo_q;
                            f_a1 <= !f_short ? 8'd255 - fo_q : fo_nx[6] ? 8'd255 - fo_q : 8'd254 - fo_q;
                        end
                        2'd2: if (f_cnt == f_last) begin            // IFFT -> POST
                            f_ph <= 2'd3;
                            f_kind <= (f_short ? IM_K_POSTS : IM_K_POSTL) + {2'd0, im_cls};
                        end else begin                              // the next butterfly
                            f_kind <= IM_K_OP + {2'd0, sched_q[70:68]};
                            f_s0 <= sched_q[66:60]; f_s1 <= sched_q[58:52];
                            f_s2 <= sched_q[50:44]; f_s3 <= sched_q[42:36];
                            f_wr <= $signed(sched_q[35:18]); f_wi <= $signed(sched_q[17:0]);
                        end
                        default: if (f_cnt == f_last) begin         // POST done: the next channel
                            if (f_ch + 3'd1 == im_nf) f_v <= 1'b0;
                            else begin
                                f_ch <= f_ch + 3'd1; f_short <= a0[f_ch + 3'd1];
                                f_ph <= 2'd0; f_kind <= IM_K_DRC;
                            end
                        end
                    endcase
                end
            end
        end else if (st == V_IMX) i_v <= 1'b0;          // a stall: a bubble issues
        if (!rst_n) begin
            f_v <= 1'b0; r_v <= 1'b0; i_v <= 1'b0; im_vld <= 5'd0;
        end else if (imdct_fin) im_vld <= im_vld | ((im_nf == 3'd1) ? 5'b00001 : (im_nf == 3'd2) ? 5'b00011 :
                                                    (im_nf == 3'd3) ? 5'b00111 : (im_nf == 3'd4) ? 5'b01111 : 5'b11111);
    end

    // ------------------------------------------------------------------ the datapath
    logic signed [32:0] ma;                  // 33: the IMDCT's samples (a 32-bit word, or a
                                             // pre-sum of two); every other op's are 27
    logic signed [26:0] mb;
    logic               acc_clr, acc_en, direct, trunc, preclip, neg, sat24, mag_en;
    logic               psh, psub, w35;      // the IMDCT: floor the product by 17 before it
                                             // meets the accumulator; subtract it; store 35
    logic         [1:0] shl;
    logic signed [55:0] init, addend, dsrc;
    logic         [5:0] rsh;
    logic               xb_we, hb_we, rg_we, b2_we, sc_we, p_wi;
    logic        [10:0] xb_wa;
    logic         [9:0] hb_wa;
    logic        [10:0] rg_wa;
    logic         [5:0] b2_wa, sc_wa, p_wai;
    logic signed [55:0] x_prod;              // |33 x 27| < 2^55 for every op that uses it
    logic               x_acc_clr, x_acc_en, x_direct, x_trunc, x_preclip, x_neg, x_sat24;
    logic               x_psh, x_psub;
    logic         [1:0] x_shl;
    logic signed [55:0] x_init, x_addend, x_dsrc, acc;
    logic         [5:0] x_rsh;
    logic signed [55:0] sum, rsrc, rnd, pcl, pn, post, shv, pv;
    always_comb begin
        // the IMDCT floors EACH product (imdct_512's `(s * tw) >>> 17`) before it is added,
        // and subtracts the floored product (floor(-x) != -floor(x))
        pv   = x_psh ? (x_prod >>> 17) : x_prod;
        sum  = (x_acc_clr ? x_init : acc) + (x_psub ? -pv : pv);
        rsrc = x_direct ? x_dsrc : sum;
        rnd  = (x_rsh == 6'd0) ? rsrc
             : ((rsrc + (x_trunc ? 56'sd0 : (56'sd1 <<< (x_rsh - 6'd1)))) >>> x_rsh);
        pcl  = rnd;
        if (x_preclip) begin
            if (rnd > 56'sd8388607) pcl = 56'sd8388607;
            else if (rnd < -56'sd8388608) pcl = -56'sd8388608;
        end
        pn   = x_neg ? -pcl : pcl;
        post = pn + x_addend;
        shv  = post <<< x_shl;
        res  = shv;
        if (x_sat24) begin
            if (shv > 56'sd8388607) res = 56'sd8388607;
            else if (shv < -56'sd8388608) res = -56'sd8388608;
        end
    end
    wire [23:0] res_abs = res[23] ? (24'd0 - res[23:0]) : res[23:0];

    // synthesis translate_off
    always @(posedge clk)
        if ((x_sc_we || x_b2_we) && p_we)
            $fatal(1, "dts_vec: the small-buffer M10K took two writes in one cycle");
    // synthesis translate_on

    always_ff @(posedge clk) begin
        x_prod <= ma * mb;
        x_psh <= psh; x_psub <= psub; x_w35 <= w35;
        x_acc_clr <= acc_clr; x_acc_en <= acc_en; x_direct <= direct; x_trunc <= trunc;
        x_preclip <= preclip; x_neg <= neg; x_sat24 <= sat24; x_shl <= shl;
        x_init <= init; x_addend <= addend; x_dsrc <= dsrc; x_rsh <= rsh;
        x_xb_we <= xb_we; x_hb_we <= hb_we; x_rg_we <= rg_we; x_b2_we <= b2_we;
        x_sc_we <= sc_we; x_p_we <= p_wi; x_mag_en <= mag_en;
        x_xb_wa <= xb_wa; x_hb_wa <= hb_wa; x_rg_wa <= rg_wa; x_b2_wa <= b2_wa;
        x_sc_wa <= sc_wa; x_p_wa <= p_wai;
        p_we <= x_p_we; p_wa <= x_p_wa; p_val <= res[23:0];
        if (x_acc_en) acc <= sum;
        if (!rst_n) begin
            x_acc_en <= 1'b0; x_xb_we <= 1'b0; x_hb_we <= 1'b0; x_rg_we <= 1'b0;
            x_b2_we <= 1'b0; x_sc_we <= 1'b0; x_p_we <= 1'b0; x_mag_en <= 1'b0; p_we <= 1'b0;
        end
    end

    // ------------------------------------------------------------------ per-state wiring
    always_comb begin
        ma = 33'sd0; mb = 27'sd0; acc_clr = 1'b1; acc_en = 1'b0; direct = 1'b0;
        psh = 1'b0; psub = 1'b0; w35 = 1'b0;
        trunc = 1'b0; preclip = 1'b0; neg = 1'b0; sat24 = 1'b0; shl = 2'd0; mag_en = 1'b0;
        init = 56'sd0; addend = 56'sd0; dsrc = 56'sd0; rsh = 6'd0;
        xb_we = 1'b0; hb_we = 1'b0; rg_we = 1'b0; b2_we = 1'b0; sc_we = 1'b0; p_wi = 1'b0;
        xb_wa = {a0[2:0], a1[4:0], k_d[2:0]};
        hb_wa = {a0[2:0], a1[4:0], k_d[1:0]};
        rg_wa = {1'b0, side, off + {4'd0, o_idx}};
        b2_wa = {side, wd_q[0], wd_i};
        sc_wa = {!o_stage[0], o_idx};
        p_wai = {side, wd_q[0], wd_i};
        xb_ra = {a0[2:0], a1[4:0], k[2:0]};
        hb_ra = {a0[2:0], a1[4:0], k[1:0]};
        // the ring's read: pcm_out's AC-3 PCM slots unless an op is using the ring (DTS's
        // window, MP2's window, AC-3's IMDCT override it; only those ops read the ring)
        rg_ra = {2'b11, pcm_ra};
        b2_ra = {side, w_q[0], w_i};
        sc_ra = ip_q[5:0];
        pb_ra = k[4:0];
        // the shared small-buffer RAM's one read: the scratch (IMDCT), the carried
        // sums (window) or a PCM word (emit)
        pb_r = ((st == V_EMITL) || (st == V_EMITW)) && !m_mono;   // MP2 mono: L twice
        sm_ra = (st == V_WIN) ? {2'b01, b2_ra} :
                (st == V_MWIN) ? {2'b01, side, mw_j} :
                (st == V_EMIT || st == V_EMITL || st == V_EMITW) ? {2'b10, pb_r, pb_ra} :
                {2'b00, sc_ra};
        vk_ra = q_sidx;
        wn_ra = {a7[0], w_t, w_q, w_i};
        ip_ra = (st == V_IPS) ? 10'd0 : (ip_bub || ip_final) ? ip_d : ip_d + 10'd1;
        ic_ra = {1'b0, ip_q[12:6]};
        mn_ra = k[10:0];
        mw_ra = {mw_t, mw_j};
        xq_ready = (st == V_XQ7) || (st == V_AW);
        imdct_req = (st == V_IM);
        case (st)
            // ---- the plain loops: XCLR, HCLR (zero writes), XVQ, JOINT (8 samples)
            V_LOOP: begin
                if (vop == OP_JOINT) xb_ra = {a2[2:0], a1[4:0], k[2:0]};   // the source
                if (dv) case (vop)
                    OP_XCLR: begin direct = 1'b1; xb_we = 1'b1; xb_wa = k_d[10:0]; end
                    OP_HCLR: begin direct = 1'b1; hb_we = 1'b1; hb_wa = {a0[2:0], k_d[6:0]}; end
                    OP_RCLR: begin                      // the ring, and b2 in its first 64
                        direct = 1'b1; rg_we = 1'b1; rg_wa = k_d[10:0];
                        b2_we = (k_d < 12'd64); b2_wa = k_d[5:0];
                    end
                    OP_XVQ: begin                       // clip23((v x scale + 8) >> 4)
                        ma = vq27; mb = sreg27; rsh = 6'd4; sat24 = 1'b1; xb_we = 1'b1;
                    end
                    OP_JOINT: begin                     // clip23(norm(x x scale, 17)), and history
                        ma = xb27; mb = sreg27; rsh = 6'd17; sat24 = 1'b1; xb_we = 1'b1;
                        hb_we = k_d[2];
                    end
                    default: ;
                endcase
            end
            // ---- XQ
            V_JO0: vk_ra = VK_JOINT + {1'b0, a3[7:0]};               // the joint scale
            V_XQ1: vk_ra = VK_ADJ + {7'd0, a5[1:0]};
            V_XQ2: begin                        // the Huffman scale: (adj x scale) >> 22, floor
                ma = sreg27; mb = vk27; rsh = 6'd22; trunc = 1'b1; sat24 = 1'b1;
            end
            V_XQ3: vk_ra = VK_STEP + {3'd0, a6[0], a2[4:0]};
            V_XQ4: begin ma = sreg27; mb = vk27; end                 // step x scale
            V_XQ6: begin direct = 1'b1; dsrc = {9'd0, ss}; rsh = {1'b0, shreg}; trunc = 1'b1; end
            V_XQ7: if (xq_valid) begin          // clip23(norm(q x ss, 22 - shift))
                ma = xq27; mb = ss27; rsh = {1'b0, qsh}; sat24 = 1'b1;
                xb_we = 1'b1; xb_wa = {a0[2:0], a1[4:0], k[2:0]};
            end
            // ---- ADPCM
            V_AD1: xb_ra = {a0[2:0], a1[4:0], 1'b1, k[1:0]};       // unpredicted: x[4..7]
            V_AD2: begin
                xb_ra = {a0[2:0], a1[4:0], aj};
                acc_clr = (as == 3'd0); acc_en = (as <= 3'd3);
                case (as)
                    3'd0: begin ma = hs0; mb = cs3; end
                    3'd1: begin ma = hs1; mb = cs2; end
                    3'd2: begin ma = hs2; mb = cs1; end
                    3'd3: begin                 // clip23(x + clip23(norm(pred, 13)))
                        ma = hs3; mb = cs0; rsh = 6'd13; preclip = 1'b1; sat24 = 1'b1;
                        addend = {{31{xb_q[24]}}, xb_q[24:0]};
                        xb_we = 1'b1; xb_wa = {a0[2:0], a1[4:0], aj};
                    end
                    default: ;
                endcase
            end
            V_AD3: begin                        // the history out
                direct = 1'b1; hb_we = 1'b1; hb_wa = {a0[2:0], a1[4:0], k[1:0]};
                case (k[1:0])
                    2'd0: dsrc = {{32{h0[23]}}, h0};
                    2'd1: dsrc = {{32{h1[23]}}, h1};
                    2'd2: dsrc = {{32{h2[23]}}, h2};
                    default: dsrc = {{32{h3[23]}}, h3};
                endcase
            end
            // ---- BFLY: an element in 4 cycles (read p, read q, write p + q, write p - q)
            V_BF: begin
                xb_ra = k[0] ? {a1[2:0], k[9:2]} : {a0[2:0], k[9:2]};
                direct = 1'b1;
                if (k[1:0] == 2'd2) begin
                    dsrc = {{31{bf_a[24]}}, bf_a} + {{31{xb_q[24]}}, xb_q[24:0]};
                    xb_we = 1'b1; xb_wa = {a0[2:0], k[9:2]};
                end else if (k[1:0] == 2'd3) begin
                    dsrc = {{31{bf_a[24]}}, bf_a} - {{31{bf_c[24]}}, bf_c};   // BFLY: X[p] - X[q]
                    xb_we = 1'b1; xb_wa = {a1[2:0], k[9:2]};
                end
            end
            // ---- MIXSYN: the mix of column j, clip23(norm(sum x g, 15)), and sum |v|.
            //      Every band of every channel: the model's nmix bound (a2..a6) is not
            //      applied, because X above a channel's mixed count is zero by
            //      construction -- XCLR clears X every subsubframe, every op writes only
            //      below the channel's active count, and BFLY's sums stay below the
            //      pair's larger count, which is what nmix is. The bound saved the
            //      model's cycles only; without it the pair-bound bug (D3, mix_own_bound)
            //      cannot occur here.
            V_MX: begin
                xb_ra = {mb_c, mb_b, a0[2:0]};
                vk_ra = mx_g;
                if (dv) begin
                    ma = xb27; mb = vk27;
                    acc_clr = (mb_cd == 3'd0); acc_en = 1'b1;
                    if (mb_cd == nch - 3'd1) begin
                        rsh = 6'd15; sat24 = 1'b1; sc_we = 1'b1; sc_wa = {1'b0, mb_bd};
                        mag_en = 1'b1;
                    end
                end
            end
            // ---- MIXSYN: the IMDCT program
            V_IP: if (ip_iv) begin
                if (!ti_add) begin
                    ma = sc27; mb = ic_q; acc_clr = fresh; acc_en = 1'b1;
                end
                if (ti_last) begin
                    case (ti_rsh)
                        2'd0: rsh = 6'd0;
                        2'd1: rsh = pshift ? 6'd2 : 6'd0;
                        2'd2: rsh = 6'd22;
                        default: rsh = 6'd23;
                    endcase
                    neg = ti_neg; shl = (ti_shl && pshift) ? 2'd2 : 2'd0; sat24 = 1'b1;
                    addend = ahold;
                    if (o_stage == 3'd6) rg_we = 1'b1; else sc_we = 1'b1;
                end
            end
            // ---- MIXSYN: the window, 8 taps an output, q-major
            V_WIN: begin
                rg_ra = {1'b0, side, w_rg};
                if (dv) begin
                ma = wn27; mb = rg27;
                acc_clr = (wd_t == 3'd0); acc_en = 1'b1;
                init = wd_q[1] ? 56'sd0 : ($signed({{27{b2_q[28]}}, b2_q}) <<< 21);
                if (wd_t == 3'd7) begin
                    rsh = 6'd21;
                    if (wd_q[1]) b2_we = 1'b1;                       // c, d: the carried sums
                    else begin sat24 = 1'b1; p_wi = 1'b1; end        // a, b: PCM
                end
            end
            end
            // ---- AC-3: an item (the dither table is read for the LFSR as it stands)
            V_AW: begin
                ip_ra = IP_DITH + {2'd0, lfsr[15:8]};
                if (xq_valid) begin
                    xb_wa = xq_addr;
                    if (i_co) begin                 // a coordinate, as sent
                        direct = 1'b1; dsrc = {{32{xq_code[23]}}, xq_code}; xb_we = 1'b1;
                    end else if (!i_set && !(vop == OP_AQ && i_b0 && i_dith)) begin
                        // a bin's (m16 << 8) >>> exp, or 0; AQ writes it, AQC holds it
                        direct = 1'b1; dsrc = i_b0 ? 56'sd0 : i_scl;
                        rsh = i_b0 ? 6'd0 : {1'b0, i_e}; trunc = 1'b1;
                        xb_we = (vop == OP_AQ);
                    end
                end
            end
            V_AD, V_CD1: begin                      // the dither: round(ns x 23170 / 2^(7+e))
                ma = lf27; mb = 27'sd23170; rsh = 6'd7 + {1'b0, c_e};
                if (c_e > 5'd23) begin direct = 1'b1; dsrc = 56'sd0; rsh = 6'd0; end
                xb_we = (st == V_AD); xb_wa = {c_slot, c_bin};
            end
            V_CCH: begin
                ip_ra = IP_DITH + {2'd0, lfsr[15:8]};
                xb_ra = {8'hE0, c_ch};                         // its coordinate
                if (c_ch != c_nf && c_chin[c_ch] && c_b0 && !c_dm[c_ch]) begin
                    direct = 1'b1; xb_we = 1'b1; xb_wa = {c_ch, c_bin};    // undithered: 0
                end
            end
            V_CD2: xb_ra = {8'hE0, c_ch};
            V_CMUL: begin                           // sat24((c x co) >> 18), floor
                ma = creg27; mb = xb27; rsh = 6'd18; trunc = 1'b1; sat24 = 1'b1;
                xb_we = 1'b1; xb_wa = {c_ch, c_bin};
            end
            V_CZ: begin direct = 1'b1; xb_we = 1'b1; xb_wa = {a0[2:0], k[7:0]}; end
            // ---- REMAT: an active bin in 4 cycles (read L, read R, write L + R, L - R)
            V_RM: begin
                xb_ra = {2'd0, rph[0], rb};
                direct = 1'b1; sat24 = 1'b1;
                if (rb < a1[7:0] && r_act) begin
                    if (rph == 2'd2) begin
                        dsrc = {{31{bf_a[24]}}, bf_a} + {{31{xb_q[24]}}, xb_q[24:0]};
                        xb_we = 1'b1; xb_wa = {3'd0, rb};
                    end else if (rph == 2'd3) begin
                        dsrc = {{31{bf_a[24]}}, bf_a} - {{31{bf_c[24]}}, bf_c};
                        xb_we = 1'b1; xb_wa = {3'd1, rb};
                    end
                end
            end
            V_IM: xb_ra = coef_ra;
            V_IMX: begin
                // R stage: the next term's reads (its ring word / coefficient, its constant)
                rg_ra = im_ra;
                xb_ra = {r_ch, r_cnt};
                // I stage: the term issues
                if (i_v) begin
                    case (i_srck)
                        2'd0: ma = $signed(rg_q[32:0]);
                        2'd1: ma = {{8{xb_q[24]}}, xb_q[24:0]};
                        default: ma = 33'sd0;                    // a delay word not yet valid
                    endcase
                    mb = i_kv;
                    if (i_krom) case (i_kromsel)
                        2'd0: mb = {{9{wn_im_q[17]}}, wn_im_q};
                        2'd1: mb = i_kim ? {{9{pre_q[17]}}, pre_q[17:0]} : {{9{pre_q[35]}}, pre_q[35:18]};
                        default: mb = i_kim ? {{9{post_q[17]}}, post_q[17:0]} : {{9{post_q[35]}}, post_q[35:18]};
                    endcase
                    acc_clr = !i_mode[1]; acc_en = 1'b1;
                    psub = i_mode[0];
                    psh = i_prod;
                    rsh = i_drc ? {2'd0, im_drc_sh} : 6'd0; trunc = 1'b1;
                    rg_we = i_dstv; rg_wa = i_dst; w35 = i_w35;
                end
            end
            // ---- MP2: MDQ -- C read, x16 C and d16 C into one sum, floored by 7; then x SCF
            V_MQ0: ic_ra = MP2_IC_C + {3'd0, a3[4:0]};
            V_MQ1: begin
                ic_ra = MP2_IC_C + {3'd0, a3[4:0]};
                ma = {{17{a1[15]}}, a1}; mb = {10'd0, ic_q[16:0]}; acc_en = 1'b1;
            end
            V_MQ2: begin
                ic_ra = MP2_IC_SCF + {2'd0, a4[5:0]};
                ma = {11'd0, a2}; mb = {10'd0, ic_q[16:0]};
                acc_clr = 1'b0; acc_en = 1'b1; rsh = 6'd7; trunc = 1'b1;
            end
            V_MQ3: ic_ra = MP2_IC_SCF + {2'd0, a4[5:0]};          // the floor lands (ss)
            V_MQ4: begin                        // floor(q x SCF / 2^20): never clips (|S| < 2^25)
                ic_ra = MP2_IC_SCF + {2'd0, a4[5:0]};
                ma = {{6{ss[26]}}, ss[26:0]}; mb = {5'd0, ic_q[21:0]}; rsh = 6'd20; trunc = 1'b1;
                xb_we = 1'b1; xb_wa = a0[10:0];
            end
            // ---- MP2: MSYN's matrix, V[i] = floor(sum_k N[i][k] S[k] / 2^14) (|V| <= 2^30)
            V_MM: begin
                xb_ra = {3'd0, a0[1:0], side, k[4:0]};
                if (dv) begin
                    ma = mn27; mb = s27; acc_clr = (k_d[4:0] == 5'd0); acc_en = 1'b1;
                    if (k_d[4:0] == 5'd31) begin
                        rsh = 6'd14; trunc = 1'b1; rg_we = 1'b1; rg_wa = {side, mm_rg};
                    end
                end
            end
            // ---- MP2: MSYN's window, the low halves into b2, then the high halves on top
            V_MWIN: begin
                rg_ra = {side, mw_rg};
                if (dv) begin
                    ma = mw27; mb = mwd_p ? vhi27 : vlo27;
                    acc_clr = (mwd_t == 4'd0); acc_en = 1'b1;
                    init = mwd_p ? {{27{b2_q[28]}}, b2_q} : 56'sd0;
                    if (mwd_t == 4'd15) begin
                        trunc = 1'b1;
                        if (!mwd_p) begin rsh = 6'd16; b2_we = 1'b1; b2_wa = {side, mwd_j}; end
                        else begin
                            rsh = 6'd1; sat24 = 1'b1; p_wi = 1'b1; p_wai = {side, mwd_j};
                        end
                    end
                end
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------ sequencing
    always_ff @(posedge clk) begin
        done <= 1'b0;
        cb_req <= 1'b0;
        imdct_fin <= 1'b0;
        if (cb_valid) begin cb_row <= cb_data; cb_got <= 1'b1; end
        if (pcm_valid && pcm_ready) pcm_valid <= 1'b0;
        if (x_mag_en) mag <= mag + {5'd0, res_abs};
        if ((st == V_AW || st == V_AD || st == V_CSC || st == V_CCH || st == V_CD1 ||
             st == V_CD2 || st == V_CMUL) && abort) ab <= 1'b1;
        if (!rst_n) begin
            st <= V_IDLE; pcm_valid <= 1'b0; cb_got <= 1'b0;
            off0 <= 10'd0; off1 <= 10'd0;
            lfsr <= 16'd1;
        end else case (st)
            V_IDLE: if (start) begin
                vop <= op;
                a0 <= args[15:0];   a1 <= args[31:16];  a2 <= args[47:32];
                a3 <= args[63:48];  a4 <= args[79:64];  a5 <= args[95:80];
                a6 <= args[111:96]; a7 <= args[127:112];
                k <= 12'd0; dv <= 1'b0;
                case (op)
                    OP_XCLR: begin lcnt <= 12'd1280; st <= V_LOOP; end
                    OP_HCLR: begin        // {band, k} from 4 x the band to 127
                        k <= args[31] ? 12'd0 : (args[31:16] >= 16'd32) ? 12'd128
                                                : {3'd0, args[22:16], 2'd0};
                        lcnt <= 12'd128; st <= V_LOOP;
                    end
                    OP_XQ: st <= V_XQ0;
                    OP_XVQ: begin
                        cb_req <= 1'b1; cb_sel <= 1'b1; cb_got <= 1'b0;
                        cb_addr <= {args[41:32], args[49:48]};
                        st <= V_VQ0;
                    end
                    OP_ADPCM: begin
                        aj <= 3'd0; as <= 3'd0;
                        if (args[48]) begin
                            cb_req <= 1'b1; cb_sel <= 1'b0; cb_got <= 1'b0;
                            cb_addr <= args[43:32];
                            st <= V_AD0;
                        end else st <= V_AD1;
                    end
                    OP_JOINT: st <= V_JO0;
                    OP_BFLY: st <= V_BF;
                    OP_MIXSYN: begin
                        side <= 1'b0; mb_b <= 5'd0; mb_c <= 3'd0; mx_go <= 1'b1; mag <= 29'd0;
                        nch <= VK_NCH[3 * args[19:16] +: 3];
                        st <= V_MX;
                    end
                    OP_AQ: begin
                        ab <= 1'b0;
                        lcnt <= args[63:48] - args[47:32];
                        if ($signed(args[47:32]) < $signed(args[63:48])) st <= V_AW;
                        else st <= V_DONE;
                    end
                    OP_AQC: begin ab <= 1'b0; lcnt <= args[47:32] - args[31:16]; st <= V_AW; end
                    OP_CZERO: begin
                        k <= args[27:16];
                        lcnt <= (args[47:32] > 16'd256) ? 12'd256 : args[43:32];
                        if (args[31:16] < ((args[47:32] > 16'd256) ? 16'd256 : args[47:32])) st <= V_CZ;
                        else st <= V_DONE;
                    end
                    OP_REMAT: begin
                        rb <= 8'd13; rph <= 2'd0;
                        if (args[31:16] > 16'd13) st <= V_RM; else st <= V_DONE;
                    end
                    OP_IMDCT: st <= V_IM;
                    OP_MDQ: st <= V_MQ0;
                    OP_MSYN: begin side <= 1'b0; st <= V_MS0; end
                    OP_RCLR: begin lcnt <= 12'd2048; st <= V_LOOP; end
                    default: st <= V_DONE;          // CNT
                endcase
            end
            // ---- AC-3: AQ / AQC items
            V_AW: if (xq_valid) begin
                if (i_set) begin c_dm <= xq_code[4:0]; c_chin <= xq_code[9:5]; c_nf <= xq_code[12:10]; end
                else if (!i_co) begin
                    c_slot <= xq_addr[10:8]; c_bin <= xq_addr[7:0]; c_e <= i_e; c_b0 <= i_b0;
                    c_ch <= 3'd0;
                    if (vop == OP_AQ) begin
                        if (i_b0 && i_dith) st <= V_AD;
                        else begin
                            k <= k + 12'd1;
                            if (k + 12'd1 == lcnt && !ab) st <= V_DRAIN;
                        end
                    end else if (i_b0) st <= V_CCH;
                    else st <= V_CSC;
                end
            end else if (ab) st <= V_IDLE;          // refused: nothing pending, no done
            V_AD: begin
                lfsr <= lfsr_n;
                k <= k + 12'd1;
                if (k + 12'd1 == lcnt && !ab) st <= V_DRAIN; else st <= V_AW;
            end
            V_CSC: begin creg <= res[23:0]; st <= V_CCH; end
            V_CCH: if (c_ch == c_nf) begin
                k <= k + 12'd1;
                if (k + 12'd1 == lcnt && !ab) st <= V_DRAIN; else st <= V_AW;
            end else if (!c_chin[c_ch] || (c_b0 && !c_dm[c_ch])) c_ch <= c_ch + 3'd1;
            else if (c_b0) st <= V_CD1;
            else st <= V_CMUL;
            V_CD1: begin lfsr <= lfsr_n; st <= V_CD2; end
            V_CD2: begin creg <= res[23:0]; st <= V_CMUL; end
            V_CMUL: begin c_ch <= c_ch + 3'd1; st <= V_CCH; end
            V_CZ: begin
                k <= k + 12'd1;
                if (k + 12'd1 == lcnt) st <= V_DRAIN;
            end
            V_RM: begin
                if (rb >= a1[7:0]) st <= V_DRAIN;
                else if (!r_act) rb <= rb + 8'd1;
                else begin
                    if (rph == 2'd1) bf_a <= xb_q[24:0];      // L, read in phase 0
                    if (rph == 2'd2) bf_c <= xb_q[24:0];      // R, read in phase 1
                    rph <= rph + 2'd1;
                    if (rph == 2'd3) rb <= rb + 8'd1;
                end
            end
            V_IM: if (imdct_go) st <= V_IMX;
            V_IMX: if (!f_v && !r_v && !i_v && !x_rg_we) begin   // the last write has landed
                imdct_fin <= 1'b1;
                st <= V_DONE;
            end
            // ---- a plain loop: k issues reads, k_d the data's use
            V_LOOP: begin
                dv <= (k < lcnt);
                k_d <= k;
                if (k < lcnt) k <= k + 12'd1;
                else if (!dv) st <= V_DONE;
            end
            V_DRAIN: st <= V_DONE;                  // the last stage-Y write lands
            V_DONE: if (!pcm_valid) begin done <= 1'b1; st <= V_IDLE; end
            // ---- XQ
            V_XQ0: st <= V_XQ1;                     // the scale is read
            V_XQ1: begin sreg <= vk_q; if (q_huff) st <= V_XQ2; else st <= V_XQ3; end
            V_XQ2: st <= V_XQ2W;
            V_XQ2W: begin sreg <= res[23:0]; st <= V_XQ3; end
            V_XQ3: st <= V_XQ4;                     // the step is read
            V_XQ4: st <= V_XQ4W;
            V_XQ4W: begin ss <= res[46:0]; st <= V_XQ5; end
            V_XQ5: begin shreg <= ss_gt ? ss_len : 5'd0; st <= V_XQ6; end
            V_XQ6: begin qsh <= (shreg >= 5'd22) ? 5'd0 : 5'd22 - shreg; st <= V_XQ6W; end
            V_XQ6W: begin ss2 <= res[23:0]; st <= V_XQ7; end
            V_XQ7: if (xq_valid) begin
                k <= k + 12'd1;
                if (k[2:0] == 3'd7) st <= V_DRAIN;
            end
            // ---- XVQ, JOINT: the scale, then the plain loop
            V_VQ0: st <= V_VQ1;
            V_VQ1: if (cb_got) begin sreg <= vk_q; lcnt <= 12'd8; st <= V_LOOP; end
            V_JO0: st <= V_JO1;
            V_JO1: begin sreg <= vk_q; lcnt <= 12'd8; st <= V_LOOP; end
            // ---- ADPCM: predicted -- the history in, 8 samples, the history out
            V_AD0: begin
                dv <= (k < 12'd4);
                k_d <= k;
                if (k < 12'd4) k <= k + 12'd1;
                if (dv) case (k_d[1:0])
                    2'd0: h0 <= hb_q;  2'd1: h1 <= hb_q;  2'd2: h2 <= hb_q;  default: h3 <= hb_q;
                endcase
                if (k == 12'd4 && !dv && cb_got) st <= V_AD2;
            end
            // ---- ADPCM: unpredicted -- the history is x[4..7]
            V_AD1: begin
                dv <= (k < 12'd4);
                k_d <= k;
                if (k < 12'd4) k <= k + 12'd1;
                if (dv) case (k_d[1:0])
                    2'd0: h0 <= xb_q[23:0];  2'd1: h1 <= xb_q[23:0];
                    2'd2: h2 <= xb_q[23:0];  default: h3 <= xb_q[23:0];
                endcase
                if (k == 12'd4 && !dv) begin k <= 12'd0; st <= V_AD3; end
            end
            V_AD2: begin                            // 4 terms, then the result lands (as 4)
                if (as == 3'd4) begin
                    as <= 3'd0;
                    h0 <= h1; h1 <= h2; h2 <= h3; h3 <= res[23:0];
                    aj <= aj + 3'd1;
                    if (aj == 3'd7) begin k <= 12'd0; st <= V_AD3; end
                end else as <= as + 3'd1;
            end
            V_AD3: begin
                k <= k + 12'd1;
                if (k[1:0] == 2'd3) st <= V_DRAIN;
            end
            // ---- BFLY
            V_BF: begin
                if (k[1:0] == 2'd1) bf_a <= xb_q[24:0];   // X[p], read in phase 0
                if (k[1:0] == 2'd2) bf_c <= xb_q[24:0];   // X[q], read in phase 1
                k <= k + 12'd1;
                if (k == 12'd1023) st <= V_DRAIN;
            end
            // ---- MIXSYN: mix one side's column
            V_MX: begin
                dv <= mx_go;
                mb_bd <= mb_b; mb_cd <= mb_c;
                if (mx_go) begin
                    if (mb_c == nch - 3'd1) begin
                        mb_c <= 3'd0;
                        if (mb_b == 5'd31) mx_go <= 1'b0;
                        mb_b <= mb_b + 5'd1;
                    end else mb_c <= mb_c + 3'd1;
                end else if (!dv) st <= V_IPS;      // the last write and |v| land now
            end
            V_IPS: begin                            // term 0 is read; the pipeline starts
                pshift <= (mag > 29'h400000);
                ip_d <= 10'd0; ip_dv <= 1'b1; ip_iv <= 1'b0; ip_bub <= 1'b0;
                outn <= 8'd0; fresh <= 1'b1; ahold <= 56'sd0;
                st <= V_IP;
            end
            V_IP: begin
                if (ip_iv) begin
                    if (ti_add) ahold <= {{32{sc_q[23]}}, sc_q};
                    else fresh <= 1'b0;
                    if (ti_last) begin outn <= outn + 8'd1; ahold <= 56'sd0; fresh <= 1'b1; end
                end
                if (ip_bub || ip_final) begin        // a stage boundary: hold the read stage
                    ip_iv <= 1'b0;
                    ip_bub <= ip_final;
                end else begin
                    ip_i <= ip_q; ip_iv <= ip_dv;
                    ip_d <= ip_d + 10'd1;
                    ip_dv <= (ip_d + 10'd1 < IPROG_WORDS);
                end
                if (outn == 8'd224) begin           // the last ring write lands now
                    w <= 9'd0; w_go <= 1'b1; dv <= 1'b0;
                    st <= V_WIN;
                end
            end
            V_WIN: begin
                dv <= w_go;
                w_d <= w;
                if (w_go) begin
                    w <= w + 9'd1;
                    if (w == 9'd511) w_go <= 1'b0;
                end else if (!dv) begin k <= 12'd0; st <= V_WINW; end
            end
            V_WINW: begin                           // the last PCM word lands
                k <= k + 12'd1;
                if (k == 12'd1) begin
                    if (!side) begin
                        off0 <= off0 - 10'd32;
                        side <= 1'b1; mb_b <= 5'd0; mb_c <= 3'd0; mx_go <= 1'b1; mag <= 29'd0;
                        dv <= 1'b0;
                        st <= V_MX;
                    end else begin
                        off1 <= off1 - 10'd32;
                        k <= 12'd0;
                        st <= V_EMIT;
                    end
                end
            end
            V_EMIT: st <= V_EMITL;                  // pair k's L is read
            V_EMITL: begin pl_hold <= sm_q[15:0]; st <= V_EMITW; end   // ... then its R
            V_EMITW: if (!pcm_valid || pcm_ready) begin
                pcm_l <= pl_hold; pcm_r <= sm_q[15:0]; pcm_valid <= 1'b1;
                k <= k + 12'd1;
                if (k == 12'd31) st <= V_DONE; else st <= V_EMIT;
            end
            // ---- MP2: MDQ
            V_MQ0: st <= V_MQ1;                     // C is read
            V_MQ1: st <= V_MQ2;
            V_MQ2: st <= V_MQ3;
            V_MQ3: begin ss <= res[46:0]; st <= V_MQ4; end
            V_MQ4: st <= V_DRAIN;
            // ---- MP2: MSYN, a channel: the offset, the matrix, the window
            V_MS0: begin
                if (side) off1 <= off1 - 10'd64; else off0 <= off0 - 10'd64;
                k <= 12'd0; dv <= 1'b0;
                st <= V_MM;
            end
            V_MM: begin
                dv <= (k < 12'd2048);
                k_d <= k;
                if (k < 12'd2048) k <= k + 12'd1;
                else if (!dv) begin k <= 12'd0; st <= V_MWIN; end   // the last V lands now
            end
            V_MWIN: begin
                dv <= (k < 12'd1024);
                k_d <= k;
                if (k < 12'd1024) k <= k + 12'd1;
                else if (!dv) begin k <= 12'd0; st <= V_MWW; end
            end
            V_MWW: begin                            // the last PCM word lands
                k <= k + 12'd1;
                if (k == 12'd1) begin
                    k <= 12'd0;
                    if (!side && !a1[0]) begin side <= 1'b1; st <= V_MS0; end
                    else st <= V_EMIT;
                end
            end
            default: st <= V_IDLE;
        endcase
    end

endmodule
