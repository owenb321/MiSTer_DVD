//============================================================================
//  exponent_decode.sv — AC-3 exponent ungrouping (first datapath stage).
//
//  Reads the packed (grouped) exponents that `audblk_parse` staged and produces
//  the per-channel array of *absolute 5-bit exponents* (0..24) that
//  bit_allocation and mantissa_dequant consume.  Started by a pulse once a
//  block's side info is parsed; the bit_reader is idle while this runs.
//
//  ALGORITHM (A/52 §7.1.3, == liba52 parse.c): each channel sends one 4-bit
//  absolute exponent (exp[0], DC) then `nchgrps` 7-bit group codes; each code
//  0..124 ungroups into three mapped diffs (M-2), accumulated and replicated
//  group_size (1/2/4 for D15/D25/D45) times into dexp_mem[{ch,idx}].
//
//  CHANNELS (M14): up to 5 fbw (acmod==7 = L C R Ls Rs), the coupling channel,
//  and LFE — decoded as separate passes into dexp_mem channel slots:
//      0..4 = fbw,  5 = coupling (AC3_CH_CPL),  6 = LFE (AC3_CH_LFE).
//  Passes run fbw 0..nfchans-1, then coupling (if cplexpstr!=reuse), then LFE
//  (if lfeon && lfeexpstr).  Coupling differs: seed = cplabsexp<<1, no DC store,
//  first decoded value lands at exp[cplstrtmant].  LFE is a plain D15 channel
//  (nlfegrps=2, 7 mantissas) seeded with its own 4-bit absolute exp.
//
//  REUSE (chexpstr==0 / lfeexpstr==0): the channel keeps its previous exps —
//  this stage leaves that slot untouched.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module exponent_decode (
    input  logic        clk,
    input  logic        rst,

    // begin decoding this block's exponents (pulse, e.g. block_side_valid)
    input  logic        start,

    // channel config + per-fbw-channel geometry (packed: ch occupies [ch*W +: W])
    input  logic [2:0]  nfchans,     // 2 or 5
    input  logic        lfeon,
    input  logic [9:0]  chexpstr,    // 2 bits/ch: 0=reuse,1=D15,2=D25,3=D45
    input  logic [34:0] nchgrps,     // 7 bits/ch

    // coupling-channel exponent geometry
    input  logic [1:0]  cplexpstr,   // 0=reuse (none), 1=D15, 2=D25, 3=D45
    input  logic [8:0]  cplstrtmant,
    input  logic [8:0]  cplendmant,

    // LFE exponent strategy (1 bit: 0=reuse, 1=D15)
    input  logic        lfeexpstr,

    // packed-exp read ports -> audblk_parse (combinational reads)
    output logic [9:0]  exp_rd_addr,     // {ch[2:0], idx[6:0]}
    input  logic [7:0]  exp_rd_data,
    output logic [6:0]  cpl_exp_rd_addr,
    input  logic [7:0]  cpl_exp_rd_data,
    output logic [1:0]  lfe_exp_rd_addr,
    input  logic [7:0]  lfe_exp_rd_data,

    // decoded-exp read ports (combinational): addr {ch[2:0], idx[7:0]}; 5-bit exp.
    input  logic [10:0] dexp_rd_addr,
    output logic [4:0]  dexp_rd_data,
    input  logic [10:0] ba_exp_rd_addr,
    output logic [4:0]  ba_exp_rd_data,
    input  logic [10:0] mant_exp_rd_addr,
    output logic [4:0]  mant_exp_rd_data,

    output logic        done         // 1-cycle pulse: all passes decoded
);

    localparam logic [2:0] CPL = AC3_CH_CPL[2:0];   // 5
    localparam logic [2:0] LFE = AC3_CH_LFE[2:0];   // 6

    // Decoded absolute exponents.  Address = {ch[2:0], idx[7:0]}: ch 0..4 = fbw,
    // 5 = coupling, 6 = LFE.  2048 entries (7 channels x 256).
    //
    // RESOURCE NOTE (minimize pass): this used to have THREE *asynchronous* read
    // ports (dexp/ba/mant), which forced Quartus to realize all 2048x5 bits as
    // flip-flops + three 2048:1 mux trees — ~8.8k ALMs, 40% of the whole decoder.
    // That's fine for the standalone build but blows the budget when the decoder
    // shares the device with the MPEG2 core.  We now back dexp_mem with a true-
    // dual-port M10K (registered reads), trading ~8.5k ALMs for ~1-2 M10K (which
    // the combined design has in abundance).  The datapath is strictly sequential
    // (P_EXP -> P_BITALLOC -> P_MANT), so the write port (P_EXP) and the ba read
    // (P_BITALLOC) never collide and share port A; the mant read (P_MANT) owns
    // port B.  ba/mant reads are now 1-cycle latent: mantissa_dequant already
    // tolerates this (its exp aligns with the registered bap_mem read); bit_alloc
    // gained a +1 prefetch pipeline (C_COPY/C_CCOPY).  Same M10K-conversion rules
    // as M15: NO reset on the array, funnel every write through ONE port.
    logic [4:0] dexp_mem [0:2047];

    // Write funnel (port A write) — combinationally decoded from the FSM below.
    logic        wr_we;
    logic [10:0] wr_addr;
    logic [4:0]  wr_data;

    // Port A: write (P_EXP) or ba_exp read (P_BITALLOC); Port B: mant_exp read.
    wire [10:0] addr_a = wr_we ? wr_addr : ba_exp_rd_addr;
    always_ff @(posedge clk) begin
        if (wr_we) dexp_mem[wr_addr] <= wr_data;
        ba_exp_rd_data   <= dexp_mem[addr_a];
        mant_exp_rd_data <= dexp_mem[mant_exp_rd_addr];
    end

`ifdef AC3_COSIM
    // Verification-only async tap (cosim / unit TBs check decoded exps directly).
    // Compiled out of synthesis so the array stays M10K-inferable.
    assign dexp_rd_data = dexp_mem[dexp_rd_addr];
`else
    assign dexp_rd_data = 5'd0;
`endif

    typedef enum logic [2:0] {
        E_IDLE,
        E_ABS_REQ, E_ABS_RD,
        E_GRP_REQ, E_GRP_RD,
        E_EMIT,
        E_CABS_REQ, E_CABS_RD
    } state_t;

    state_t      st;
    logic        rdw;           // M19d: audblk staging reads are 1-cycle latent
                                // (registered M10K) — each *_RD state runs a
                                // wait cycle (rdw=0) then captures (rdw=1)
    logic [2:0]  ci;            // fbw channel index (0..nfchans-1)
    logic        cpl;           // coupling-channel pass in progress
    logic        lfe;           // LFE-channel pass in progress
    logic [6:0]  gi;            // group index within channel (1..nchgrps)
    logic [7:0]  j;             // decoded-coefficient write index
    logic [4:0]  prevexp;       // running absolute exponent
    logic [6:0]  code;          // current 7-bit group code
    logic [1:0]  di;            // which of the three diffs (0..2)
    logic [2:0]  ri;            // replication counter within a diff

    wire [2:0] nfm1 = nfchans - 3'd1;

    // ---- per-channel geometry helpers ----
    wire [1:0] cur_chexpstr = chexpstr[ci*2 +: 2];
    wire [6:0] cur_nchgrps  = nchgrps[ci*7 +: 7];
    // coupling-channel geometry: ncplgrps = (cplendmant-cplstrtmant)/grpsz.
    wire [4:0] cpl_grpsz    = 5'd3 << (cplexpstr - 2'd1);
    wire [8:0] cpl_nmant    = cplendmant - cplstrtmant;
    wire [8:0] ncplgrps_full = cpl_nmant / {4'd0, cpl_grpsz};
    wire [6:0] ncplgrps     = ncplgrps_full[6:0];
    // effective strategy / group count for the current pass.
    wire [1:0] eff_str      = cpl ? cplexpstr : lfe ? 2'd1 : cur_chexpstr;
    wire [6:0] eff_nchgrps  = cpl ? ncplgrps  : lfe ? 7'd2 : cur_nchgrps;
    // group_size (coeffs per decoded diff): D15->1, D25->2, D45->4.
    wire [2:0] gs = (eff_str == 2'd3) ? 3'd4 : {1'b0, eff_str};
    // destination channel slot for writes.
    wire [2:0] wr_ch = cpl ? CPL : lfe ? LFE : ci;
    // packed group-code source for the current pass.
    wire [6:0] pk_code = cpl ? cpl_exp_rd_data[6:0] :
                         lfe ? lfe_exp_rd_data[6:0] : exp_rd_data[6:0];
    // whether a coupling / LFE pass is needed this block.
    wire need_cpl = (cplexpstr != 2'd0);
    wire need_lfe = (lfeon && lfeexpstr);

    // ---- ungroup the current code into its three mapped values (0..4) ----
    wire [6:0] gm0 = code / 7'd25;
    wire [6:0] grem = code - gm0 * 7'd25;
    wire [6:0] gm1 = grem / 7'd5;
    wire [6:0] gm2 = grem - gm1 * 7'd5;
    wire [2:0] mcur = (di == 2'd0) ? gm0[2:0] :
                      (di == 2'd1) ? gm1[2:0] : gm2[2:0];

    // prevexp + (mcur - 2), clamped to [0,24].
    wire signed [7:0] sumv  = $signed({3'b0, prevexp}) + $signed({5'b0, mcur}) - 8'sd2;
    wire        [4:0] addexp = (sumv < 0)       ? 5'd0  :
                               (sumv > 8'sd24)  ? 5'd24 : sumv[4:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            st          <= E_IDLE;
            rdw         <= 1'b0;
            ci          <= 3'd0;
            cpl         <= 1'b0;
            lfe         <= 1'b0;
            gi          <= 7'd0;
            j           <= 8'd0;
            prevexp     <= 5'd0;
            code        <= 7'd0;
            di          <= 2'd0;
            ri          <= 3'd0;
            exp_rd_addr <= 10'd0;
            cpl_exp_rd_addr <= 7'd0;
            lfe_exp_rd_addr <= 2'd0;
            done        <= 1'b0;
        end else begin
            done <= 1'b0;   // default: 1-cycle pulse

            case (st)
                E_IDLE: if (start) begin
                    ci  <= 3'd0;
                    cpl <= 1'b0;
                    lfe <= 1'b0;
                    st  <= E_ABS_REQ;
                end

                // Channel start: reuse keeps the previous exps; otherwise fetch
                // the 4-bit DC exponent from packed idx 0 (fbw or LFE).
                E_ABS_REQ: begin
                    if (!lfe && cur_chexpstr == 2'd0) begin     // fbw reuse channel
                        if (ci != nfm1) ci <= ci + 3'd1;        // -> next fbw channel
                        else if (need_cpl) st <= E_CABS_REQ;
                        else if (need_lfe) begin lfe <= 1'b1; st <= E_ABS_REQ; end
                        else begin done <= 1'b1; st <= E_IDLE; end
                    end else begin
                        if (lfe) lfe_exp_rd_addr <= 2'd0;
                        else     exp_rd_addr     <= {ci, 7'd0};
                        st <= E_ABS_RD;
                    end
                end

                E_ABS_RD: if (!rdw) rdw <= 1'b1; else begin
                    // fbw/LFE: DC exp at idx 0 (4-bit), decode starts at idx 1.
                    // (memory write handled by the wr_* funnel below)
                    rdw                  <= 1'b0;
                    prevexp              <= lfe ? lfe_exp_rd_data[4:0] : exp_rd_data[4:0];
                    gi                   <= 7'd1;
                    j                    <= 8'd1;
                    st                   <= E_GRP_REQ;
                end

                E_GRP_REQ: begin
                    if (gi > eff_nchgrps) begin                // channel done
                        if (cpl) begin
                            // coupling pass finished: LFE next or done.
                            if (need_lfe) begin cpl <= 1'b0; lfe <= 1'b1; st <= E_ABS_REQ; end
                            else begin done <= 1'b1; st <= E_IDLE; end
                        end else if (lfe) begin done <= 1'b1; st <= E_IDLE; end
                        else if (ci != nfm1) begin ci <= ci + 3'd1; st <= E_ABS_REQ; end
                        else if (need_cpl) st <= E_CABS_REQ;
                        else if (need_lfe) begin lfe <= 1'b1; st <= E_ABS_REQ; end
                        else begin done <= 1'b1; st <= E_IDLE; end
                    end else begin
                        if (cpl)      cpl_exp_rd_addr <= gi;
                        else if (lfe) lfe_exp_rd_addr <= gi[1:0];
                        else          exp_rd_addr     <= {ci, gi};
                        st <= E_GRP_RD;
                    end
                end

                E_GRP_RD: if (!rdw) rdw <= 1'b1; else begin
                    rdw  <= 1'b0;
                    code <= pk_code;
                    di   <= 2'd0;
                    ri   <= 3'd0;
                    st   <= E_EMIT;
                end

                // Emit one decoded exponent per cycle: apply the diff on the
                // first replica (ri==0), then repeat the value group_size times.
                E_EMIT: begin
                    // (memory write handled by the wr_* funnel below)
                    if (ri == 3'd0) prevexp <= addexp;
                    j <= j + 8'd1;

                    if (ri == gs - 3'd1) begin
                        ri <= 3'd0;
                        if (di == 2'd2) begin                  // group done
                            gi <= gi + 7'd1;
                            st <= E_GRP_REQ;
                        end else di <= di + 2'd1;
                    end else ri <= ri + 3'd1;
                end

                // ---- coupling-channel pass ----
                // liba52 seeds the coupling exps with cplabsexp = get(4) << 1 and
                // writes the FIRST decoded value at exp[cplstrtmant] (no separate
                // DC-exp store, unlike the fbw/LFE channels).
                E_CABS_REQ: begin
                    cpl_exp_rd_addr <= 7'd0;     // packed idx 0 = cplabsexp (4-bit)
                    st              <= E_CABS_RD;
                end
                E_CABS_RD: if (!rdw) rdw <= 1'b1; else begin
                    rdw     <= 1'b0;
                    prevexp <= {cpl_exp_rd_data[3:0], 1'b0};   // cplabsexp << 1
                    j       <= cplstrtmant[7:0];
                    gi      <= 7'd1;
                    cpl     <= 1'b1;
                    st      <= E_GRP_REQ;
                end

                default: st <= E_IDLE;
            endcase
        end
    end

    // ---- write funnel (single port A write) -------------------------------
    // All dexp_mem writes go through one address/data/enable so the array maps
    // to a single M10K write port.  Mirrors the two former in-FSM writes:
    //   E_ABS_RD : DC exponent at idx 0 (fbw/LFE; coupling has no DC store)
    //   E_EMIT   : one decoded exponent per cycle at idx j
    always_comb begin
        wr_we   = 1'b0;
        wr_addr = {wr_ch, 8'd0};
        wr_data = lfe ? lfe_exp_rd_data[4:0] : exp_rd_data[4:0];
        case (st)
            E_ABS_RD: begin
                wr_we   = rdw;   // M19d: write only on the capture cycle
                wr_addr = {wr_ch, 8'd0};
                wr_data = lfe ? lfe_exp_rd_data[4:0] : exp_rd_data[4:0];
            end
            E_EMIT: begin
                wr_we   = 1'b1;
                wr_addr = {wr_ch, j};
                wr_data = (ri == 3'd0) ? addexp : prevexp;
            end
            default: ;
        endcase
    end

endmodule
