//============================================================================
//  mantissa_dequant.sv — AC-3 mantissa read + dequantization (M7, third
//  datapath stage).
//
//  Consumes the per-coefficient bit-allocation pointers bap[] (from
//  bit_allocation) and absolute exponents exp[] (from exponent_decode), reads
//  the quantized mantissas out of the bitstream (this is the FIRST datapath
//  stage that drives the bit_reader), dequantizes them, and writes fixed-point
//  transform coefficients into coeff_mem for the IMDCT (M8).  Started by a pulse
//  (the sequencer drives it on bit_allocation's `done`); the bit_reader is now
//  granted to this stage (P_MANT) — exps/bap are already in BRAM so it only
//  pulls mantissa bits.
//
//  ALGORITHM — a literal transcription of liba52 0.8.0 coeff_get() (A/52
//  §7.3.1).  liba52's bap[] is remapped (see ac3_tables.svh): the grouped
//  quantizers carry a negative tag, everything else is positive:
//      bap  0      : zero  (or dither noise if dithflag[ch])
//      bap -1      : 3-level  grouped, 5-bit code, group of 3   (q1lev)
//      bap -2      : 5-level  grouped, 7-bit code, group of 3   (q2lev)
//      bap -3      : 11-level grouped, 7-bit code, group of 2   (q4lev)
//      bap  3      : 7-level  direct, 3-bit code                (q3lev)
//      bap  4      : 15-level direct, 4-bit code                (q5lev)
//      bap  5..16  : direct, `bap` bits, signed: m16 = sext(bits)<<(16-bap)
//  For the grouped quantizers liba52 reads ONE code and caches the remaining
//  sub-mantissas in the quantizer struct; later same-class coefficients consume
//  the cache with no further read.  The cache persists across BOTH fbw channels
//  within a block (the quantizer is reset once, before the channel loop) — so
//  this FSM resets the q-pointers at `start` and carries them from ch0 into ch1.
//
//  DEQUANT / FIXED POINT (architecture.md §5): every quantizer yields a signed
//  16-bit mantissa value `m16`; the transform coefficient is
//      coeff = ($signed(m16) <<< 8) >>> exp      (Q1.23, 24-bit, truncating)
//  (8 = 23 − 15).  Grouped/direct-table levels come from the round-to-nearest
//  integer ROMs in ac3_mant_tables.svh; this is the first fixed-point stage, so
//  it is NOT bit-exact to liba52's float — the standalone TB bounds the error
//  (≤ 2 LSB @ Q1.23, see run_mantissa.sh).
//
//  DITHER: bap==0 with dithflag[ch] set → liba52 fills the coefficient with
//  `dither_gen() * LEVEL_3DB * factor[exp]`.  We replicate the LFSR
//  (dither_lut ROM, seed 1, advanced once per dithered bap==0 coefficient in
//  coefficient order across channels) and use m16 = (nstate·23170)>>>15
//  (23170/32768 ≈ LEVEL_3DB).  dithflag==0 → coeff = 0.
//
//  Coefficients endmant..255 are zero-filled per channel (liba52 zeroes the HF
//  tail) so the IMDCT (M8) gets a clean 256-length array.
//
//  MEMORIES / handshake:
//    - mant_exp_rd_*  : 3rd combinational read port on exponent_decode.dexp_mem.
//    - mant_bap_rd_*  : 2nd combinational read port on bit_allocation.bap_mem.
//      Both addressed by the live {ch, idx} registers, so the data for the
//      coefficient being processed is always present.
//    - coeff_mem      : single write port (one coeff/cycle on the no-read fast
//      path, several cycles per bitstream read), combinational read port
//      (coeff_rd_addr/data) for the IMDCT (M8) and the TB.  512 entries
//      addressed {ch, idx[7:0]}, signed Q1.23.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module mantissa_dequant (
    input  logic        clk,
    input  logic        rst,

    // begin mantissa dequant for this block (pulse, e.g. bit_allocation.done)
    input  logic        start,

    // channel config + per-fbw-channel geometry (packed: ch occupies [ch*W +: W])
    input  logic [2:0]  nfchans,     // 2 or 5
    input  logic        lfeon,
    input  logic [44:0] endmant,     // 9 bits/ch
    input  logic [4:0]  dithflag,    // 1 bit/ch

    // coupling geometry + rematrixing (M12 Stage C/D) from audblk_parse
    input  logic [4:0]  chincpl,
    input  logic [8:0]  cplstrtmant,
    input  logic [8:0]  cplendmant,
    input  logic [17:0] cplbndstrc,
    input  logic [3:0]  rematflg,
    // coupling-coordinate read port -> audblk_parse.cplco_mem (combinational).
    // addr {ch[2:0], bnd[4:0]}, signed Q5.18.
    output logic [7:0]  cplco_rd_addr,
    input  logic signed [23:0] cplco_rd_data,

    // bit_reader request/grant (granted to this stage during P_MANT)
    output logic        req,
    output logic [5:0]  nbits,
    input  logic        ack,
    input  logic [31:0] data_in,

    // exponent read port -> exponent_decode.dexp_mem (combinational).  addr
    // {ch[2:0], idx[7:0]}: 0..4 fbw, 5 cpl, 6 lfe.
    output logic [10:0] mant_exp_rd_addr,
    input  logic [4:0]  mant_exp_rd_data,

    // bap read port -> bit_allocation.bap_mem (combinational).  addr {ch[2:0],idx}.
    output logic [10:0] mant_bap_rd_addr,
    input  logic signed [7:0] mant_bap_rd_data,

    // coeff read port (combinational): addr {ch[2:0], idx[7:0]}, signed Q1.23
    input  logic [10:0] coeff_rd_addr,
    output logic signed [23:0] coeff_rd_data,

    // 2nd combinational coeff read port (consumed by imdct_512)
    input  logic [10:0] coeff_rd2_addr,
    output logic signed [23:0] coeff_rd2_data,

    output logic        done            // 1-cycle pulse: all channels done
);

    localparam logic [2:0] LFE = AC3_CH_LFE[2:0];   // 6
    wire [2:0] nfm1 = nfchans - 3'd1;

    // ---- mantissa quantizer ROM tables (q1lev/.../q5lev, dither_lut) ----
    `include "ac3_mant_tables.svh"

    // ---- transform coefficients (Q1.23) — M13: M10K simple-dual-port ----------
    // M13 area pass: coeff_mem used to be read combinationally (coeff_rd2 for the
    // IMDCT + the cosim coeff_rd tap) and was read at TWO addresses in one cycle
    // by the rematrix RMW, so Quartus realized all 512×24 bits as registers.  Now
    // it is a single-write / single-read M10K: the FSM block only WRITES it, and a
    // separate synchronous read port (cm_rq) serves BOTH the IMDCT read (coeff_rd2,
    // now 1-cycle latency — imdct_512 S_PRE shifted by one) and the serialized
    // rematrix reads (M_REMRD..M_REMW1).  The cosim/TB coeff_rd tap stays an async
    // read but is compiled out of synthesis (AC3_COSIM defined only by the sim
    // scripts) so it does not block M10K inference.
    // 7 channel slots (0..4 fbw, 5 cpl unused here, 6 LFE).  LFE is dequantized
    // into slot 6 but never read by the IMDCT (dropped from the downmix); writing
    // it keeps the channel loop uniform.
    (* ramstyle = "M10K, no_rw_check" *)
    logic signed [23:0] coeff_mem [0:1791];

    // single write port (cm_we/cm_waddr/cm_wdata) + single read port (cm_raddr ->
    // cm_rq) in ONE clocked block: the canonical simple-dual-port pattern Quartus
    // maps to M10K.  Every FSM write funnels through cm_* (registered, so the
    // write commits one cycle after it is decided — harmless here: nothing reads a
    // coefficient in the same cycle it is written, and the IMDCT only reads after
    // `done`).  cm_raddr is muxed (rematrix reads vs IMDCT) below.
    logic               cm_we;             // write enable (pulse)
    logic [10:0]        cm_waddr;          // write address
    logic signed [23:0] cm_wdata;          // write data
    logic [10:0]        cm_raddr;          // shared read-port address
    logic signed [23:0] cm_rq;             // registered read data (1-cycle latency)
    always_ff @(posedge clk) begin
        if (cm_we) coeff_mem[cm_waddr] <= cm_wdata;
        cm_rq <= coeff_mem[cm_raddr];
    end
    assign coeff_rd2_data = cm_rq;         // IMDCT consumes the registered read

`ifdef AC3_COSIM
    // simulation-only async verification tap (unit TBs read final coeffs).  Tied
    // to 0 in hardware (ac3fpga.sv) and removed from synthesis so it cannot force
    // coeff_mem out of block RAM.
    assign coeff_rd_data  = coeff_mem[coeff_rd_addr];
`else
    assign coeff_rd_data  = 24'sd0;
`endif

    // ---- live indices feeding the combinational exp/bap read ports ----
    logic [2:0]  ch;                  // current channel slot (0..nfm1 fbw, 6 lfe)
    logic [8:0]  idx;                 // coeff index 0..256 (256 => channel done)
    // M12: during the coupling pass the exp/bap come from ch 5 (CPL) at cpl_idx.
    logic        in_cpl;             // coupling pass active
    logic [8:0]  cpl_idx;            // coupling coeff index (cplstrtmant..cplendmant)
    wire [2:0]  rd_ch  = in_cpl ? AC3_CH_CPL[2:0] : ch;
    wire [8:0]  rd_idx = in_cpl ? cpl_idx : idx;
    assign mant_exp_rd_addr = {rd_ch, rd_idx[7:0]};
    assign mant_bap_rd_addr = {rd_ch, rd_idx[7:0]};

    wire        is_lfe      = (ch == LFE);
    wire [8:0]  endmant_cur = is_lfe ? 9'd7 : endmant[ch*9 +: 9];
    wire        cpl_cur     = is_lfe ? 1'b0 : chincpl[ch];     // LFE never coupled
    // the zero tail starts after the coupling region for a coupled channel.
    wire [8:0]  zero_start  = cpl_cur ? cplendmant : endmant_cur;
    wire        dith_cur    = is_lfe ? 1'b0 : dithflag[ch];    // LFE: no dither
    wire signed [7:0] bap   = mant_bap_rd_data;
    wire [4:0]  exp         = mant_exp_rd_data;

    // ---- grouped-quantizer caches (liba52 quantizer_t), persist across ch ----
    logic signed [16:0] q1_cache [0:1];
    logic signed [16:0] q2_cache [0:1];
    logic signed [16:0] q4_cache;
    logic signed [1:0]  q1_ptr, q2_ptr, q4_ptr;   // -1 == empty

    // ---- dither LFSR ----
    logic [15:0] lfsr;
    wire  [15:0] dith_next = dither_lut[lfsr[15:8]] ^ {lfsr[7:0], 8'h00};
    // nstate is a signed int16 (liba52 dither_gen); the dither coefficient is
    // ns * LEVEL_3DB * scale_factor[e], LEVEL_3DB≈23170/32768.  dith_prod holds
    // the full-precision ns*23170 product (needs a 32-bit context).
    wire signed [31:0] dith_prod = $signed(dith_next) * 32'sd23170;

    // ---- coefficient scaler: coeff = (m16 << 8) >> exp, Q1.23 (truncating) ----
    function automatic signed [23:0] scale_coeff
        (input signed [16:0] m16v, input [4:0] e);
        logic signed [31:0] s;
        begin
            s = ($signed({{15{m16v[16]}}, m16v}) <<< 8) >>> e;
            scale_coeff = s[23:0];
        end
    endfunction

    // ---- full-precision dither coefficient (Q1.23) -----------------------------
    // The old path computed a 17-bit m16 = (ns*23170)>>15 (truncating) and then
    // scale_coeff'd it (<<8 >>e, truncating again) — two nested floors that lost
    // up to ~256 Q1.23 LSB/coeff at low exp.  Stereo barely dithers so it hid the
    // error, but 5.1 splits the bits across 5 fbw channels → many bap==0 dither
    // bins, and the per-coeff bias accumulated through the IMDCT to tens of LSB
    // (ch4 ≈ 46 LSB).  liba52 keeps ns*LEVEL_3DB*scale_factor[e] in float, so we
    // match it by forming the WHOLE product ns*23170/2^(7+e) and rounding ONCE:
    //   coeff = round( ns*23170 / 2^(7+e) )            (Q1.23)
    // (m16<<8>>e == (ns*23170)/2^(7+e) algebraically, but without the early
    //  17-bit clamp/floor).  Max |coeff| at e=0 ≈ 32768*181 ≈ 5.9e6 < 2^23, so no
    // saturation is possible (liba52 dither can't clip either).
    function automatic signed [23:0] dither_coeff(input [4:0] e);
        logic [5:0]         sh;
        logic signed [40:0] s;
        begin
            sh = 6'd7 + {1'b0, e};                       // shift = 7 + exp
            s  = ($signed({{9{dith_prod[31]}}, dith_prod})
                  + (41'sd1 <<< (sh - 6'd1))) >>> sh;     // round-to-nearest
            dither_coeff = s[23:0];
        end
    endfunction

    // ---- M12 recombine: coeff(Q1.23) * cplco(Q5.18) >>> 18 -> Q1.23 (saturating)
    // (liba52 folds the per-channel downmix coeff into cplco; the cosim normalizes
    //  by that scalar, so the dut uses the raw coordinate — see arch §5).
    function automatic signed [23:0] recombine
        (input signed [23:0] cc, input signed [23:0] co);
        logic signed [47:0] p;
        begin
            p = ($signed(cc) * $signed(co)) >>> 18;
            if      (p >  48'sd8388607)  recombine =  24'sd8388607;
            else if (p < -48'sd8388608)  recombine = -24'sd8388608;
            else                         recombine =  p[23:0];
        end
    endfunction

    // ---- M12 rematrix sum/diff, saturated to Q1.23 ----
    function automatic signed [23:0] sat24 (input signed [25:0] v);
        begin
            if      (v >  26'sd8388607)  sat24 =  24'sd8388607;
            else if (v < -26'sd8388608)  sat24 = -24'sd8388608;
            else                         sat24 =  v[23:0];
        end
    endfunction

    // ---- group ungroup helpers (arithmetic sub-index, see ac3_mant_tables) ----
    // code is right-justified in data_in on ack.
    wire [6:0]  code = data_in[6:0];
    wire [3:0]  code4 = data_in[3:0];
    wire [2:0]  code3 = data_in[2:0];
    // bap1: 3-level, group of 3 (code 0..26).
    wire [1:0]  i1a = code[4:0] / 5'd9;
    wire [1:0]  i1b = (code[4:0] / 5'd3) % 2'd3;   // (code/3)%3
    wire [1:0]  i1c = code[4:0] % 2'd3;
    // bap2: 5-level, group of 3 (code 0..124).
    wire [2:0]  i2a = code / 7'd25;
    wire [2:0]  i2b = (code / 7'd5) % 3'd5;
    wire [2:0]  i2c = code % 3'd5;
    // bap4: 11-level, group of 2 (code 0..120).
    wire [3:0]  i4a = code / 7'd11;
    wire [3:0]  i4b = code % 7'd11;
    // direct (signed) mantissa for bap 5..16: sext(bits)<<(16-bap).
    wire [5:0]  bw  = bap[5:0];                     // bit width == bap value
    wire signed [16:0] m16_direct =
        17'($signed(data_in << (6'd32 - bw)) >>> 6'd16);

    // ---- FSM ----
    typedef enum logic [4:0] {
        M_IDLE, M_FETCH, M_EXAM, M_WAIT,
        M_CPLBAND, M_CPLCOF, M_CPLFETCH, M_CPLEXAM, M_CPLWAIT,
        M_CPLWR,
        M_REMSET, M_REMRD, M_REMRDR, M_REMCAP, M_REMW0, M_REMW1
    } state_t;
    state_t st;

    // captured at request issue so M_WAIT knows how to decode the result.
    logic [4:0] pend_exp;
    logic [2:0] pend_ch;
    logic [7:0] pend_idx;

    // ---- M12 coupling-pass registers ----
    logic        done_cpl;           // coupling mantissas already read this block
    logic [8:0]  cpl_iend;           // end (excl) of the current coupling band
    logic [4:0]  cpl_bnd;            // current coupling band index
    logic [17:0] cbs;                // remaining cplbndstrc bits (band-merge replay)
    // M14: coupling recombine scatters into ALL coupled fbw channels (0..nfm1),
    // not just ch0/ch1.  cplco_arr holds the current band's cplco[ch][bnd] (Q5.18)
    // for every fbw channel; wc walks the scatter; cf fetches the array.
    logic signed [23:0] cplco_arr [0:4];
    logic [2:0]  wc;                 // coupling write-channel walker (0..nfm1)
    logic [2:0]  cf;                 // coupling cplco fetch counter (0..nfm1)
    logic signed [23:0] cc_r;        // dequantized coupling coeff (Q1.23, pre-cplco)
    logic [4:0]  cpl_exp_r;          // exp at the coupling coeff (for dither scale)
    logic        cpl_zero;           // current coupling coeff is bap==0 (dither/zero)

    // ---- M12 rematrixing registers ----
    logic [8:0]  rem_j;              // coeff index being rematrixed
    logic [3:0]  rem_i;              // rematrix band index (0..3)
    logic [3:0]  rem_flg;            // remaining rematflg bits
    logic [8:0]  rem_bandend;        // end (excl) of current active rematrix band
    logic signed [23:0] rem_l, rem_r;
    // rematrixing is stereo-only: ch0/ch1 fbw endmants (packed slots 0 and 1).
    wire  [8:0]  endmant0 = endmant[0*9 +: 9];
    wire  [8:0]  endmant1 = endmant[1*9 +: 9];
    wire  [8:0]  rem_end = (endmant0 < endmant1) ? endmant0 : endmant1;
    function automatic [8:0] rematrix_band (input [3:0] bi);
        case (bi)
            4'd0:    rematrix_band = 9'd25;
            4'd1:    rematrix_band = 9'd37;
            4'd2:    rematrix_band = 9'd61;
            default: rematrix_band = 9'd253;
        endcase
    endfunction

    // ---- M13: coeff_mem shared read-port address mux ------------------------
    // During the rematrix RMW the read port is driven by rematrix (L then R);
    // otherwise it follows the IMDCT's coeff_rd2 address.  M_REMRD presents the L
    // address ({0,rem_j}); M_REMRDR presents the R address ({1,rem_j}); the data
    // for each lands one cycle later in cm_rq (RAM read latency).
    always_comb begin
        unique case (st)
            M_REMRD:  cm_raddr = {3'd0, rem_j[7:0]};   // present L (slot 0)
            M_REMRDR: cm_raddr = {3'd1, rem_j[7:0]};   // present R (slot 1)
            default:  cm_raddr = coeff_rd2_addr;       // IMDCT
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            st       <= M_IDLE;
            ch       <= 3'd0;
            idx      <= 9'd0;
            req      <= 1'b0;
            nbits    <= 6'd0;
            done     <= 1'b0;
            q1_ptr   <= -2'sd1;
            q2_ptr   <= -2'sd1;
            q4_ptr   <= -2'sd1;
            lfsr     <= 16'd1;
            in_cpl   <= 1'b0;
            done_cpl <= 1'b0;
            wc       <= 3'd0;
            cf       <= 3'd0;
            cplco_rd_addr <= 8'd0;
            cm_we    <= 1'b0;
        end else begin
            done  <= 1'b0;   // default: 1-cycle pulse
            req   <= 1'b0;   // default: 1-cycle pulse
            cm_we <= 1'b0;   // default: no coeff write this cycle

            case (st)
                M_IDLE: if (start) begin
                    // reset quantizer caches once for the whole block; dither
                    // LFSR is NOT reset per block (liba52 seeds it once at init
                    // and lets it run).
                    ch       <= 3'd0;
                    idx      <= 9'd0;
                    q1_ptr   <= -2'sd1;
                    q2_ptr   <= -2'sd1;
                    q4_ptr   <= -2'sd1;
                    in_cpl   <= 1'b0;
                    done_cpl <= 1'b0;
                    st       <= M_FETCH;
                end

                // M13: bap now comes from a synchronous M10K read (bit_allocation
                // .bap_mem), so wait one cycle after the {ch,idx} address settles
                // before M_EXAM examines bap.  exp stays combinational.
                M_FETCH: st <= M_EXAM;

                // Examine the current coefficient's bap.  No-read cases (zero,
                // dither, cached grouped value, HF zero-fill) finish in this
                // cycle; bitstream reads issue a req and go to M_WAIT.  Default
                // next state is M_FETCH (re-fetch bap for the next idx); read and
                // control-flow cases override it below.
                M_EXAM: begin
                    st <= M_FETCH;
                    if (idx == 9'd256) begin
                        // channel finished (incl. HF zero-fill up to 255).
                        if (is_lfe) begin
                            // LFE was the last pass.
                            if (rematflg != 4'd0 && rem_end > 9'd13) begin
                                rem_j <= 9'd13; rem_i <= 4'd0; rem_flg <= rematflg;
                                st    <= M_REMSET;
                            end else begin done <= 1'b1; st <= M_IDLE; end
                        end else if (ch != nfm1) begin
                            ch  <= ch + 3'd1;
                            idx <= 9'd0;        // caches/lfsr persist into next ch
                        end else if (lfeon) begin
                            ch  <= LFE;         // LFE bit-consume pass (slot 6)
                            idx <= 9'd0;
                        end else if (rematflg != 4'd0 && rem_end > 9'd13) begin
                            // M12 Stage D: rematrix the low bands (acmod==2), finish.
                            rem_j   <= 9'd13;
                            rem_i   <= 4'd0;
                            rem_flg <= rematflg;
                            st      <= M_REMSET;
                        end else begin
                            done <= 1'b1;
                            st   <= M_IDLE;
                        end
                    end else if (cpl_cur && idx == cplstrtmant) begin
                        // M12 Stage C: end of this coupled channel's fbw region.
                        if (!done_cpl) begin
                            // FIRST coupled channel (whatever its index — not
                            // necessarily ch0; e.g. real DVD blocks where ch0 is
                            // uncoupled) reads the SHARED coupling mantissas once,
                            // mirroring liba52 coeff_get_coupling's done_cpl flag.
                            // `ch` is preserved through the coupling pass so the
                            // resume below continues THIS channel's zero tail.
                            cpl_idx  <= cplstrtmant;
                            cpl_iend <= cplstrtmant + 9'd12;
                            cpl_bnd  <= 5'd0;
                            cbs      <= cplbndstrc;
                            in_cpl   <= 1'b1;
                            wc       <= 3'd0;
                            st       <= M_CPLBAND;
                        end else begin
                            // coupling region already filled -> jump to zero tail
                            idx <= cplendmant;
                        end
                    end else if (idx >= zero_start) begin
                        // HF tail: zero
                        cm_we <= 1'b1; cm_waddr <= {ch, idx[7:0]}; cm_wdata <= 24'sd0;
                        idx <= idx + 9'd1;
                    end else begin
                        // active coefficient
                        case (bap)
                            8'sd0: begin
                                cm_we <= 1'b1; cm_waddr <= {ch, idx[7:0]};
                                if (dith_cur) begin
                                    cm_wdata <= dither_coeff(exp);
                                    lfsr <= dith_next;
                                end else
                                    cm_wdata <= 24'sd0;
                                idx <= idx + 9'd1;
                            end

                            -8'sd1: begin   // bap1, 3-level
                                if (q1_ptr >= 0) begin
                                    cm_we <= 1'b1; cm_waddr <= {ch, idx[7:0]};
                                    cm_wdata <= scale_coeff(q1_cache[q1_ptr[0]], exp);
                                    q1_ptr <= q1_ptr - 2'sd1;
                                    idx <= idx + 9'd1;
                                end else begin
                                    req <= 1'b1; nbits <= 6'd5;
                                    pend_exp <= exp; pend_ch <= ch; pend_idx <= idx[7:0];
                                    st <= M_WAIT;
                                end
                            end

                            -8'sd2: begin   // bap2, 5-level
                                if (q2_ptr >= 0) begin
                                    cm_we <= 1'b1; cm_waddr <= {ch, idx[7:0]};
                                    cm_wdata <= scale_coeff(q2_cache[q2_ptr[0]], exp);
                                    q2_ptr <= q2_ptr - 2'sd1;
                                    idx <= idx + 9'd1;
                                end else begin
                                    req <= 1'b1; nbits <= 6'd7;
                                    pend_exp <= exp; pend_ch <= ch; pend_idx <= idx[7:0];
                                    st <= M_WAIT;
                                end
                            end

                            -8'sd3: begin   // bap4, 11-level
                                if (q4_ptr == 0) begin
                                    cm_we <= 1'b1; cm_waddr <= {ch, idx[7:0]};
                                    cm_wdata <= scale_coeff(q4_cache, exp);
                                    q4_ptr <= -2'sd1;
                                    idx <= idx + 9'd1;
                                end else begin
                                    req <= 1'b1; nbits <= 6'd7;
                                    pend_exp <= exp; pend_ch <= ch; pend_idx <= idx[7:0];
                                    st <= M_WAIT;
                                end
                            end

                            8'sd3, 8'sd4: begin   // bap3 (3-bit), bap5 (4-bit)
                                req <= 1'b1;
                                nbits <= (bap == 8'sd3) ? 6'd3 : 6'd4;
                                pend_exp <= exp; pend_ch <= ch; pend_idx <= idx[7:0];
                                st <= M_WAIT;
                            end

                            default: begin   // bap 5..16, direct signed read
                                req <= 1'b1; nbits <= bap[5:0];
                                pend_exp <= exp; pend_ch <= ch; pend_idx <= idx[7:0];
                                st <= M_WAIT;
                            end
                        endcase
                    end
                end

                // Bitstream read complete: decode the code into m16, write the
                // coefficient, fill grouped caches, advance.
                M_WAIT: if (ack) begin
                    cm_we <= 1'b1; cm_waddr <= {pend_ch, pend_idx};
                    case (bap)
                        -8'sd1: begin   // bap1 group of 3
                            cm_wdata <= scale_coeff(q1lev[i1a], pend_exp);
                            q1_cache[1] <= q1lev[i1b];
                            q1_cache[0] <= q1lev[i1c];
                            q1_ptr <= 2'sd1;
                        end
                        -8'sd2: begin   // bap2 group of 3
                            cm_wdata <= scale_coeff(q2lev[i2a], pend_exp);
                            q2_cache[1] <= q2lev[i2b];
                            q2_cache[0] <= q2lev[i2c];
                            q2_ptr <= 2'sd1;
                        end
                        -8'sd3: begin   // bap4 group of 2
                            cm_wdata <= scale_coeff(q4lev[i4a], pend_exp);
                            q4_cache <= q4lev[i4b];
                            q4_ptr <= 2'sd0;
                        end
                        8'sd3:  cm_wdata <= scale_coeff(q3lev[code3], pend_exp);
                        8'sd4:  cm_wdata <= scale_coeff(q5lev[code4], pend_exp);
                        default:cm_wdata <= scale_coeff(m16_direct, pend_exp);
                    endcase
                    idx <= idx + 9'd1;
                    st  <= M_FETCH;
                end

                // ============ M12 Stage C: coupling-channel mantissas ============
                // Read the shared coupling mantissas ONCE (exp/bap from ch 2) and
                // scatter cpl_coeff*cplco[ch][bnd] into each coupled channel.  The
                // grouped-quantizer cache (q1/q2/q4) is SHARED with the fbw reads
                // (not reset here) so the bit position stays exact.

                // Extend this band's end by 12 per merged sub-band (cplbndstrc),
                // then fetch the band's two coupling coordinates.
                M_CPLBAND: begin
                    if (cbs[0]) begin
                        cpl_iend <= cpl_iend + 9'd12;
                        cbs      <= cbs >> 1;
                    end else begin
                        cbs           <= cbs >> 1;
                        cplco_rd_addr <= {3'd0, cpl_bnd[4:0]};    // cplco[0][bnd]
                        cf            <= 3'd0;
                        st            <= M_CPLCOF;
                    end
                end
                // Fetch this band's cplco[ch][bnd] for every fbw channel into
                // cplco_arr (one synchronous read per cycle; addr set last cycle).
                M_CPLCOF: begin
                    cplco_arr[cf] <= cplco_rd_data;
                    if (cf == nfm1) begin
                        st <= M_CPLFETCH;
                    end else begin
                        cplco_rd_addr <= {cf + 3'd1, cpl_bnd[4:0]};
                        cf            <= cf + 3'd1;
                    end
                end

                // M13: one cycle for bap[2,cpl_idx] (synchronous M10K read) to
                // settle before M_CPLEXAM examines it (mirrors M_FETCH).
                M_CPLFETCH: st <= M_CPLEXAM;

                // Examine one coupling coefficient (bap from ch 2).  No-read cases
                // set cc_r and go straight to the write; reads go to M_CPLWAIT.
                M_CPLEXAM: begin
                    cpl_exp_r <= exp;       // for the bap==0 dither scale
                    cpl_zero  <= 1'b0;      // default: real coefficient
                    case (bap)
                        // bap==0 coupling: liba52 fills each coupled channel with
                        // LEVEL_3DB*scale_factor[exp]*cplco[ch]*dither_gen() (if
                        // dithflag[ch]) or 0.  Handled per-channel in M_CPLWR0/1.
                        8'sd0: begin cpl_zero <= 1'b1; st <= M_CPLWR; end

                        -8'sd1: begin   // bap1, 3-level grouped
                            if (q1_ptr >= 0) begin
                                cc_r   <= scale_coeff(q1_cache[q1_ptr[0]], exp);
                                q1_ptr <= q1_ptr - 2'sd1;
                                st     <= M_CPLWR;
                            end else begin
                                req <= 1'b1; nbits <= 6'd5; pend_exp <= exp; st <= M_CPLWAIT;
                            end
                        end
                        -8'sd2: begin   // bap2, 5-level grouped
                            if (q2_ptr >= 0) begin
                                cc_r   <= scale_coeff(q2_cache[q2_ptr[0]], exp);
                                q2_ptr <= q2_ptr - 2'sd1;
                                st     <= M_CPLWR;
                            end else begin
                                req <= 1'b1; nbits <= 6'd7; pend_exp <= exp; st <= M_CPLWAIT;
                            end
                        end
                        -8'sd3: begin   // bap4, 11-level grouped
                            if (q4_ptr == 0) begin
                                cc_r   <= scale_coeff(q4_cache, exp);
                                q4_ptr <= -2'sd1;
                                st     <= M_CPLWR;
                            end else begin
                                req <= 1'b1; nbits <= 6'd7; pend_exp <= exp; st <= M_CPLWAIT;
                            end
                        end
                        8'sd3, 8'sd4: begin
                            req <= 1'b1; nbits <= (bap == 8'sd3) ? 6'd3 : 6'd4;
                            pend_exp <= exp; st <= M_CPLWAIT;
                        end
                        default: begin
                            req <= 1'b1; nbits <= bap[5:0]; pend_exp <= exp; st <= M_CPLWAIT;
                        end
                    endcase
                end

                M_CPLWAIT: if (ack) begin
                    case (bap)
                        -8'sd1: begin
                            cc_r <= scale_coeff(q1lev[i1a], pend_exp);
                            q1_cache[1] <= q1lev[i1b]; q1_cache[0] <= q1lev[i1c];
                            q1_ptr <= 2'sd1;
                        end
                        -8'sd2: begin
                            cc_r <= scale_coeff(q2lev[i2a], pend_exp);
                            q2_cache[1] <= q2lev[i2b]; q2_cache[0] <= q2lev[i2c];
                            q2_ptr <= 2'sd1;
                        end
                        -8'sd3: begin
                            cc_r <= scale_coeff(q4lev[i4a], pend_exp);
                            q4_cache <= q4lev[i4b]; q4_ptr <= 2'sd0;
                        end
                        8'sd3:  cc_r <= scale_coeff(q3lev[code3], pend_exp);
                        8'sd4:  cc_r <= scale_coeff(q5lev[code4], pend_exp);
                        default:cc_r <= scale_coeff(m16_direct, pend_exp);
                    endcase
                    st <= M_CPLWR;
                end

                // Scatter the coupling coeff into EVERY coupled fbw channel, one
                // per cycle (serialized to keep coeff_mem single-write-port).  For
                // bap==0 each coupled+dithered channel advances the shared LFSR
                // once (liba52 calls dither_gen() per coupled dithered channel, in
                // channel order).  After the last channel (wc==nfm1) advance the
                // coupling index / band / finish, mirroring liba52's loops.
                M_CPLWR: begin
                    if (chincpl[wc]) begin
                        cm_we <= 1'b1; cm_waddr <= {wc, cpl_idx[7:0]};
                        if (cpl_zero) begin
                            if (dithflag[wc]) begin
                                cm_wdata <= recombine(dither_coeff(cpl_exp_r), cplco_arr[wc]);
                                lfsr <= dith_next;
                            end else
                                cm_wdata <= 24'sd0;
                        end else
                            cm_wdata <= recombine(cc_r, cplco_arr[wc]);
                    end
                    if (wc == nfm1) begin
                        wc <= 3'd0;
                        if (cpl_idx + 9'd1 >= cplendmant) begin       // coupling done
                            done_cpl <= 1'b1;
                            in_cpl   <= 1'b0;
                            // KEEP ch = the triggering (first-coupled) channel; it
                            // resumes its own zero tail [cplendmant,256).  (Was
                            // hardcoded ch<=0, which broke when ch0 is uncoupled.)
                            idx      <= cplendmant;                   // its zero tail
                            st       <= M_FETCH;
                        end else if (cpl_idx + 9'd1 >= cpl_iend) begin // next band
                            cpl_idx  <= cpl_idx + 9'd1;
                            cpl_iend <= cpl_idx + 9'd1 + 9'd12;
                            cpl_bnd  <= cpl_bnd + 5'd1;
                            st       <= M_CPLBAND;
                        end else begin
                            cpl_idx <= cpl_idx + 9'd1;
                            st      <= M_CPLFETCH;
                        end
                    end else begin
                        wc <= wc + 3'd1;
                    end
                end

                // ============ M12 Stage D: rematrixing (acmod==2) ============
                // sum/difference the low bands (j in [13,end)) per active rematflg
                // band; end = min(endmant0,endmant1).  rematrix_band={25,37,61,253}.
                M_REMSET: begin
                    if (rem_j >= rem_end) begin
                        done <= 1'b1; st <= M_IDLE;
                    end else if (!rem_flg[0]) begin               // inactive band: skip
                        rem_flg <= rem_flg >> 1;
                        rem_j   <= rematrix_band(rem_i);
                        rem_i   <= rem_i + 4'd1;
                    end else begin                                // active band
                        rem_flg     <= rem_flg >> 1;
                        rem_bandend <= (rematrix_band(rem_i) < rem_end)
                                       ? rematrix_band(rem_i) : rem_end;
                        rem_i       <= rem_i + 4'd1;
                        st          <= M_REMRD;
                    end
                end
                // M13: coeff_mem is now a 1R1W M10K, so the band's L/R coeffs are
                // read serially through the shared read port (1-cycle latency each)
                // instead of two combinational reads in one cycle.
                //   M_REMRD : present L addr ({0,rem_j})   (mux above)
                //   M_REMRDR: cm_rq = L -> rem_l ; present R addr
                //   M_REMCAP: cm_rq = R -> rem_r
                //   M_REMW0 : write {0,rem_j} = sat(L+R)
                //   M_REMW1 : write {1,rem_j} = sat(L-R), advance
                M_REMRD: begin
                    if (rem_j >= rem_bandend) st <= M_REMSET;     // band done
                    else                      st <= M_REMRDR;     // L addr presented
                end
                M_REMRDR: begin
                    rem_l <= cm_rq;                               // L coeff (valid)
                    st    <= M_REMCAP;                            // R addr presented
                end
                M_REMCAP: begin
                    rem_r <= cm_rq;                               // R coeff (valid)
                    st    <= M_REMW0;
                end
                M_REMW0: begin
                    cm_we <= 1'b1; cm_waddr <= {1'b0, rem_j[7:0]};
                    cm_wdata <=
                        sat24($signed({{2{rem_l[23]}}, rem_l}) + $signed({{2{rem_r[23]}}, rem_r}));
                    st <= M_REMW1;
                end
                M_REMW1: begin
                    cm_we <= 1'b1; cm_waddr <= {1'b1, rem_j[7:0]};
                    cm_wdata <=
                        sat24($signed({{2{rem_l[23]}}, rem_l}) - $signed({{2{rem_r[23]}}, rem_r}));
                    rem_j <= rem_j + 9'd1;
                    st    <= M_REMRD;
                end

                default: st <= M_IDLE;
            endcase
        end
    end

endmodule
