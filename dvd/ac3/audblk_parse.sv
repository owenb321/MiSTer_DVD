//============================================================================
//  audblk_parse.sv — AC-3 audio-block side-information parser (the conditional-
//  syntax heart of the control plane).
//
//  Runs once per audio block, started by the sequencer.  Drives `bit_reader`
//  (req/grant) to walk the *side information* of one audio block — A/52
//  §5.4.2.2, in bitstream order, honouring every conditional field so the bit
//  position stays exact — and stages the results a later stage needs:
//
//    - packed (grouped) exponents      -> exp_mem  (read back by exponent_decode)
//    - bit-allocation parameters        -> regs (sdcycod..floorcod, snr offsets)
//    - per-channel exponent geometry    -> chexpstr/endmant/nchgrps packed buses
//    - coupling geometry + coordinates  -> chincpl/cplstrtmant/cplendmant/ncplbnd
//                                          /cplstrtbnd/cplco_mem
//    - LFE geometry/exps/bit-alloc      -> lfeexpstr/lfeba_bai/lfe_exp_mem
//
//  SCOPE (strict — fail loud, never decode wrong):
//    - acmod==2 (2 fbw) or acmod==7 (5 fbw = L C R Ls Rs); lfeon 0 or 1.
//      nfchans is derived from acmod (== liba52 nfchans_tbl).
//    - blksw[ch]==1  (short block)      -> M16: SUPPORTED (256-pt short IMDCT);
//      de-interleaved to a per-channel blksw[ch] flag for imdct_512.
//    - deltbae==3    (reserved)         -> err_unsupported.
//    - cpl deltbae==DELTA_BIT_NEW       -> err_unsupported (cpl delta-BA not wired).
//
//  M14 (5.1 / LFE) — this generalizes the former 2-channel parser:
//    * the 1-bit per-channel loop index `ci` is now 3-bit and loops 0..nfchans-1;
//      per-channel scalars are packed buses indexed `ch*W +: W`.
//    * acmod-dependent syntax: `phsflginu` and the whole `rematstr/rematflg`
//      block are STEREO-ONLY (acmod==2) — skipped for acmod==7 (A/52 §5.4.3.4,
//      §5.4.3.7; liba52 `phsflginu`=stereo only, rematrixing only for A52_STEREO).
//    * LFE: when lfeon, parse `lfeexpstr` (1 bit, after the fbw chexpstr loop),
//      the LFE grouped exps (nlfegrps=2, 7 mantissas, after the fbw exps), the
//      LFE snr-offset (`lfefsnroffst`/`lfegaincod` = lfeba.bai, after the fbw
//      snr loop).  LFE has NO coupling, NO rematrix, NO chbwcod, NO gainrng,
//      NO delta-BA.
//
//  M12 coupling (channel coupling + rematrixing) is unchanged in spirit, just
//  generalized to N channels: chincpl is an N-bit mask, the cplcoe loop iterates
//  the coupled channels, cplco_mem is addressed {ch[2:0], bnd[4:0]}.  Coupling
//  state PERSISTS across blocks (reuse semantics): chincpl on cplstre, geometry
//  on cplinu, cplco on cplcoe, rematflg on rematstr.
//
//  Geometry: endmant = chbwcod*3 + 73;  grpsz = 3<<(chexpstr-1) (D15/D25/D45 =
//  3/6/12);  nchgrps = (endmant + grpsz - 4) / grpsz   (A/52, == liba52 parse.c).
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module audblk_parse (
    input  logic        clk,
    input  logic        rst,

    // begin parsing one block's side info (pulse)
    input  logic        start,
    input  logic        first_blk,    // this is block 0 of the frame (dynrng reset)

    // channel configuration (from bsi_parse, latched for the frame)
    input  logic [2:0]  acmod,        // 1 (1/0), 2 (2/0) or 7 (3/2)
    input  logic        lfeon,        // LFE channel present

    // bit_reader request/grant interface (granted by ac3_parse while in P_AUDBLK)
    output logic        req,
    output logic [5:0]  nbits,
    input  logic        ack,
    input  logic [31:0] data_in,     // right-justified field from bit_reader
    input  logic [31:0] bitpos,      // running bit count (post-read on ack cycle)

    // result strobe + geometry/side-info (registered, held until next block)
    output logic        block_side_valid,   // 1-cycle pulse: side info parsed OK
    output logic [31:0] blk_bits,            // bits consumed by this block's side info

    // per-fbw-channel scalars, packed: channel `ch` occupies [ch*W +: W].
    output logic [4:0]  blksw,               // 1 bit/ch (0 => long block)
    output logic [4:0]  dithflag,            // 1 bit/ch

    // DRC (M17) — per-block dynamic-range gain word (A/52 §7.7).  Held until the
    // next block.  Persists across blocks when dynrnge==0 (reuse); reset to
    // 8'h80 (unity gain) at frame start (first_blk), matching liba52 a52_frame.
    output logic [7:0]  dynrng,
    output logic [9:0]  chexpstr,            // 2 bits/ch (0=reuse,1=D15,2=D25,3=D45)
    output logic [44:0] endmant,             // 9 bits/ch (= chbwcod*3+73, or cplstrtmant)
    output logic [34:0] nchgrps,             // 7 bits/ch (grouped fbw exps)

    // coupling geometry (M12) — persistent across blocks (reuse semantics)
    output logic [4:0]  chincpl,             // per-ch coupling-in-use bitmask
    output logic [8:0]  cplstrtmant,         // = cplbegf*12 + 37
    output logic [8:0]  cplendmant,          // = cplendf*12 + 73
    output logic [4:0]  ncplbnd,             // # coupling bands (after band merge)
    output logic [5:0]  cplstrtbnd,          // coupling start band (bit-alloc banding)
    output logic [17:0] cplbndstrc,          // coupling band-structure (merge mask)
    output logic        phsflginu,           // phase flags in use (stereo only)
    output logic [3:0]  rematflg,            // rematrixing band flags (stereo only)

    // coupling-coordinate read ports (combinational).  Address = {ch[2:0],
    // bnd[4:0]}; value is signed Q5.18 (see arch §5).
    input  logic [7:0]  cplco_rd_addr,       // {ch[2:0], bnd[4:0]}
    output logic signed [23:0] cplco_rd_data,
    input  logic [7:0]  cplco_rd2_addr,
    output logic signed [23:0] cplco_rd2_data,

    // coupling-channel exponent staging (Stage B): strategy + grouped exps.
    output logic [1:0]  cplexpstr,           // coupling exponent strategy
    output logic [3:0]  cplfleak,            // coupling fast-leak init (9-x)
    output logic [3:0]  cplsleak,            // coupling slow-leak init (9-x)
    output logic [6:0]  cplba_bai,           // coupling bit-alloc info
    input  logic [6:0]  cpl_exp_rd_addr,     // packed cpl exp index (0=cplabsexp)
    output logic [7:0]  cpl_exp_rd_data,

    // LFE staging (M14).  lfeexpstr (1b); LFE grouped exps in lfe_exp_mem
    // (idx 0=4b absolute, 1..2=7b grouped); lfeba.bai for bit_allocation.
    output logic        lfeexpstr,
    output logic [6:0]  lfeba_bai,
    input  logic [1:0]  lfe_exp_rd_addr,     // 0=abs, 1..2=grouped
    output logic [7:0]  lfe_exp_rd_data,

    // bit-allocation parameters (valid when baie/snroffste seen this block)
    output logic [1:0]  sdcycod,
    output logic [1:0]  fdcycod,
    output logic [1:0]  sgaincod,
    output logic [1:0]  dbpbcod,
    output logic [2:0]  floorcod,
    output logic [5:0]  csnroffst,
    output logic [19:0] fsnroffst,           // 4 bits/ch
    output logic [14:0] fgaincod,            // 3 bits/ch

    // delta bit-allocation: per-channel deltbae + staged per-band deltba values.
    output logic [9:0]  deltbae,             // 2 bits/ch (0=reuse 1=new 2=none 3=resv)
    input  logic [8:0]  deltba_rd_addr,      // {ch[2:0], band[5:0]}
    output logic signed [3:0] deltba_rd_data,

    // packed-exponent read port (combinational) — exponent_decode reads the
    // grouped fbw exponents staged below after `block_side_valid`.
    input  logic [9:0]  exp_rd_addr,         // {ch[2:0], idx[6:0]}
    output logic [7:0]  exp_rd_data,

    output logic        err_unsupported
);

    // nfchans from acmod (== liba52 nfchans_tbl[acmod]).
    // DVD-FORK 2026-08-31: acmod 1 (1/0 mono) => ONE fbw channel (see ac3_parse).
    wire [2:0] nfchans = (acmod == AC3_ACMOD_3_2)  ? 3'd5 :
                         (acmod == AC3_ACMOD_MONO) ? 3'd1 : 3'd2;
    wire [2:0] nfm1    = nfchans - 3'd1;

    // Packed-exponent staging (fbw channels).  Address = {ch[2:0], idx[6:0]}:
    // idx 0 = 4-bit absolute exponent, idx 1..nchgrps = 7-bit grouped codes.
    // M19d: reads are REGISTERED (1-cycle latent) so these staging arrays infer
    // as M10K instead of MLAB/LUT-RAM; the in-FSM writes below are the single
    // write port.  exponent_decode gained a wait state per read (rdw); the
    // deltba consumer (bit_allocation) deleted its realignment register instead.
    (* ramstyle = "M10K, no_rw_check" *)
    logic [7:0] exp_mem [0:1023];
    always_ff @(posedge clk) exp_rd_data <= exp_mem[exp_rd_addr];

    // Packed-exponent staging (coupling channel).  idx 0 = 4-bit cplabsexp,
    // idx 1..ncplgrps = 7-bit grouped codes.
    (* ramstyle = "M10K, no_rw_check" *)
    logic [7:0] cpl_exp_mem [0:127];
    always_ff @(posedge clk) cpl_exp_rd_data <= cpl_exp_mem[cpl_exp_rd_addr];

    // Packed-exponent staging (LFE).  idx 0 = 4-bit absolute, 1..2 = 7-bit
    // groups.  4 entries — stays a combinational read (its value is simply
    // stable across the consumer's wait+capture pair).
    logic [7:0] lfe_exp_mem [0:3];
    assign lfe_exp_rd_data = lfe_exp_mem[lfe_exp_rd_addr];

    // Delta-BA staging (fbw).  Address = {ch[2:0], band[5:0]}.  M19d: registered
    // read — this lands exactly where bit_allocation's old deltba_q register
    // did, so that consumer just uses deltba_rd_data directly.
    (* ramstyle = "M10K, no_rw_check" *)
    logic signed [3:0] deltba_mem [0:511];
    always_ff @(posedge clk) deltba_rd_data <= deltba_mem[deltba_rd_addr];

    // Coupling-coordinate staging.  Address = {ch[2:0], bnd[4:0]}; signed Q5.18.
    //
    // RESOURCE NOTE (M18 minimize pass): cplco_mem (256x24 = 6,144 bits) used to
    // have THREE access ports — the mantissa read (cplco_rd2), the cosim read tap
    // (cplco_rd), and an in-place phase-flag read-modify-write negate (A_PHSFLG).
    // Cyclone V M10K supports async (unregistered-output) reads but only TWO
    // ports, so three accesses forced the whole array into flip-flops (~6.1k FFs,
    // the bulk of audblk_parse's logic).  Two changes drop it to 2 ports so it
    // infers as M10K (unregistered output — no timing change for the mantissa
    // read): (1) the cosim tap is guarded behind AC3_COSIM; (2) the phsflg negate
    // is no longer an in-place RMW — instead a per-band toggle accumulator
    // `phsneg` (ch1 only) records the sign and the negate is applied at the read
    // outputs.  This is exactly equivalent to the old in-place toggle, including
    // reuse blocks: a fresh A_CPLCOMANT write of ch1 clears phsneg[bnd]; each
    // A_PHSFLG bit toggles it; the stored value stays the un-negated coordinate.
    logic signed [23:0] cplco_mem [0:255];
    logic [31:0] phsneg;   // per-band phase-flip sign for coupling ch1 (A/52 2/0)

    // mantissa read (port B): async M10K read, negate applied for ch1 if flipped.
    wire b_phsneg = (cplco_rd2_addr[7:5] == 3'd1) && phsneg[cplco_rd2_addr[4:0]];
    assign cplco_rd2_data = b_phsneg ? -cplco_mem[cplco_rd2_addr]
                                     :  cplco_mem[cplco_rd2_addr];
`ifdef AC3_COSIM
    // Verification-only tap (cosim checks cplco vs liba52's phase-flipped value).
    // Compiled out of synthesis so cplco_mem stays a 2-port (M10K) memory.
    wire a_phsneg = (cplco_rd_addr[7:5] == 3'd1) && phsneg[cplco_rd_addr[4:0]];
    assign cplco_rd_data = a_phsneg ? -cplco_mem[cplco_rd_addr]
                                    :  cplco_mem[cplco_rd_addr];
`else
    assign cplco_rd_data = 24'sd0;
`endif

    typedef enum logic [5:0] {
        A_IDLE,
        A_BLKSW, A_DITH, A_DYNE, A_DYNV,
        A_CPLSTRE, A_CPLINU, A_CHINCPL, A_PHSE, A_CPLBEGF, A_CPLENDF, A_CPLBSTR,
        A_CPLCOE_INIT, A_CPLCOE, A_MSTRCPL, A_CPLCOEXP, A_CPLCOMANT,
        A_PHSFLG_INIT, A_PHSFLG,
        A_REMATSTR, A_REMATF,
        A_CPLEXPSTR, A_CHEXP, A_LFEEXPSTR, A_CHBW,
        A_CPLEXPF, A_CPLEXPG,
        A_EXPF, A_EXPG, A_GAIN,
        A_LFEEXPF, A_LFEEXPG,
        A_BAIE, A_BAI, A_SNRE, A_CSNR, A_CPLBAI, A_FSNR, A_LFEFSNR,
        A_CPLLKE, A_CPLLK,
        A_DBAE, A_CPLDBAE, A_DBA, A_DPRE, A_DCLR, A_DNSEG, A_DSEG, A_DFILL,
        A_SKIPE, A_SKIPL, A_SKIPF,
        A_DONE, A_ERR
    } state_t;

    state_t      st;
    logic        awaiting;       // a get_bits request is in flight
    logic [2:0]  ci;             // channel index for per-channel loops (0..nfm1)
    logic [6:0]  gi;             // grouped-exponent index within a channel
    logic [6:0]  cgi;            // coupling-channel grouped-exponent index
    logic [1:0]  lgi;            // LFE grouped-exponent index
    logic [4:0]  cb;             // coupling band index (cplbndstrc/cplco/phsflg)
    logic [4:0]  csubnd;         // ncplsubnd loop bound (pre-merge band count)
    logic [3:0]  cplbegf_r;      // cplbegf latched between begf/endf reads
    logic [3:0]  mstrcplco_r;    // 3*master coupling coord (0/3/6/9)
    logic [3:0]  cplcoexp_r;     // current band's coupling-coord exponent
    logic [1:0]  cpl_deltbae;    // coupling delta-BA exists
    logic        cplcoe_any;     // any channel sent new cplco this block (for phsflg)
    logic [2:0]  dnseg;          // delta segments for the current channel
    logic [2:0]  dseg;           // delta segment counter
    logic [6:0]  dband;          // delta band write pointer / offset base (j)
    logic [3:0]  dfill;          // remaining bands to fill in the current segment
    logic signed [3:0] dval;     // mapped delta value being filled
    logic [31:0] start_bitpos;   // bitpos at block start (for blk_bits)
    logic [12:0] skip_rem;       // skipfld bits still to discard
    logic [5:0]  skip_nb;        // size of the in-flight skip read

    localparam logic [5:0] SKIP_CHUNK = 6'd24;

    // "after coupling coords" target: stereo reads rematstr next, 3/2 jumps to
    // the exponent-strategy block (no rematrixing for acmod==7).
    wire is_stereo = (acmod == AC3_ACMOD_LR);

    // ---- per-channel geometry helpers (indexed by ci) ----
    wire [1:0]  cur_chexpstr = chexpstr[ci*2 +: 2];
    wire [6:0]  cur_nchgrps  = nchgrps[ci*7 +: 7];
    wire [1:0]  cur_deltbae  = deltbae[ci*2 +: 2];
    wire        cur_coupled  = chincpl[ci];

    // fbw endmant/nchgrps from chbwcod (the chbwcod read is on data_in).
    wire [8:0]  endmant_w     = ({3'd0, data_in[5:0]} * 9'd3) + 9'd73;
    wire [4:0]  grpsz_w       = 5'd3 << (cur_chexpstr - 2'd1);
    wire [8:0]  ngnum_w       = endmant_w + {4'd0, grpsz_w} - 9'd4;
    wire [8:0]  nchgrps_full  = ngnum_w / {4'd0, grpsz_w};
    wire [6:0]  nchgrps_w     = nchgrps_full[6:0];

    // coupled fbw channel: endmant = cplstrtmant, nchgrps from that.
    wire [8:0]  ngnum_cpl     = cplstrtmant + {4'd0, grpsz_w} - 9'd4;
    wire [8:0]  nchgrps_cplf  = ngnum_cpl / {4'd0, grpsz_w};
    wire [6:0]  nchgrps_cpl   = nchgrps_cplf[6:0];

    // coupling-channel exponent geometry: ncplgrps = (cplendmant - cplstrtmant)
    //  / (3 << (cplexpstr - 1)).
    wire [4:0]  cpl_grpsz     = 5'd3 << (cplexpstr - 2'd1);
    wire [8:0]  cpl_nmant     = cplendmant - cplstrtmant;
    wire [8:0]  ncplgrps_full = cpl_nmant / {4'd0, cpl_grpsz};
    wire [6:0]  ncplgrps      = ncplgrps_full[6:0];

    // cplco compute (A/52 §5.4.3.5): cplcomant magnitude then * scale_factor.
    // scale_factor[i] = 2^-(15+i); store cplco as Q5.18 -> shift = 3 - exp_idx.
    wire [31:0] cplcomant_full = (cplcoexp_r == 4'd15)
                                   ? ({28'd0, data_in[3:0]} << 14)
                                   : (({28'd0, data_in[3:0]} | 32'h10) << 13);
    wire [5:0]  cpl_exp_idx    = {1'b0, cplcoexp_r} + {2'd0, mstrcplco_r};   // 0..24
    wire signed [6:0] cpl_shift = 7'sd3 - $signed({1'b0, cpl_exp_idx});
    wire [31:0] cplco_val      = cpl_shift[6]
                                   ? (cplcomant_full >> (-cpl_shift))
                                   : (cplcomant_full << cpl_shift[4:0]);

    // rematrixing band edges + this-block end (do-while termination).
    wire [8:0]  remat_end      = (chincpl != 5'b0) ? cplstrtmant : 9'd253;
    logic [8:0] remat_band;
    always_comb begin
        case (cb)
            5'd0:    remat_band = 9'd25;
            5'd1:    remat_band = 9'd37;
            5'd2:    remat_band = 9'd61;
            default: remat_band = 9'd253;
        endcase
    end

    // bndtab[cplbegf] -> cplstrtbnd (A/52 / liba52 parse.c).
    function automatic [5:0] bndtab (input [3:0] begf);
        case (begf)
            4'd0:  bndtab = 6'd31;  4'd1:  bndtab = 6'd35;
            4'd2:  bndtab = 6'd37;  4'd3:  bndtab = 6'd39;
            4'd4:  bndtab = 6'd41;  4'd5:  bndtab = 6'd42;
            4'd6:  bndtab = 6'd43;  4'd7:  bndtab = 6'd44;
            4'd8:  bndtab = 6'd45;  4'd9:  bndtab = 6'd45;
            4'd10: bndtab = 6'd46;  4'd11: bndtab = 6'd46;
            4'd12: bndtab = 6'd47;  4'd13: bndtab = 6'd47;
            default: bndtab = 6'd48;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            st               <= A_IDLE;
            awaiting         <= 1'b0;
            req              <= 1'b0;
            nbits            <= 6'd0;
            phsneg           <= 32'd0;
            ci               <= 3'd0;
            gi               <= 7'd0;
            cgi              <= 7'd0;
            lgi              <= 2'd0;
            cb               <= 5'd0;
            csubnd           <= 5'd0;
            cplbegf_r        <= 4'd0;
            mstrcplco_r      <= 4'd0;
            cplcoexp_r       <= 4'd0;
            cplexpstr        <= 2'd0;
            cplfleak         <= 4'd0;
            cplsleak         <= 4'd0;
            cplba_bai        <= 7'd0;
            cpl_deltbae      <= 2'd2;
            cplcoe_any       <= 1'b0;
            lfeexpstr        <= 1'b0;
            lfeba_bai        <= 7'd0;
            dnseg            <= 3'd0;
            dseg             <= 3'd0;
            dband            <= 7'd0;
            dfill            <= 4'd0;
            dval             <= 4'sd0;
            deltbae          <= 10'd0;
            start_bitpos     <= 32'd0;
            skip_rem         <= 13'd0;
            skip_nb          <= 6'd0;
            block_side_valid <= 1'b0;
            blk_bits         <= 32'd0;
            blksw            <= 5'd0;
            dithflag         <= 5'd0;
            dynrng           <= 8'h00;   // unity gain (no DRC) until first dynrng
                                         // (A/52: gain=(0x20|mant)/32·2^signed3(exp);
                                         //  unity is exp=0,mant=0 == 0x00, NOT 0x80)

            chexpstr         <= 10'd0;
            endmant          <= 45'd0;
            nchgrps          <= 35'd0;
            chincpl          <= 5'd0;
            cplstrtmant      <= 9'd0;
            cplendmant       <= 9'd0;
            ncplbnd          <= 5'd0;
            cplstrtbnd       <= 6'd0;
            cplbndstrc       <= 18'd0;
            phsflginu        <= 1'b0;
            rematflg         <= 4'd0;
            sdcycod          <= 2'd0;
            fdcycod          <= 2'd0;
            sgaincod         <= 2'd0;
            dbpbcod          <= 2'd0;
            floorcod         <= 3'd0;
            csnroffst        <= 6'd0;
            fsnroffst        <= 20'd0;
            fgaincod         <= 15'd0;
            err_unsupported  <= 1'b0;
        end else begin
            req              <= 1'b0;   // default: 1-cycle pulse
            block_side_valid <= 1'b0;   // default: 1-cycle pulse

            if ((st == A_IDLE || st == A_DONE) && start) begin
                // (Re)arm for a new block.  Coupling state PERSISTS (reuse
                // semantics) — only the per-block-default fields reset here.
                st           <= A_BLKSW;
                awaiting     <= 1'b0;
                ci           <= 3'd0;
                gi           <= 7'd0;
                // liba52 resets deltbae to DELTA_BIT_NONE per block default.
                deltbae      <= {5{2'd2}};
                cpl_deltbae  <= 2'd2;
                cplcoe_any   <= 1'b0;
                start_bitpos <= bitpos;
                // liba52 a52_frame resets state->dynrng to unity at frame start;
                // block 0's dynrnge (if set) then overwrites it.  Across blocks
                // dynrng persists (reuse when dynrnge==0).
                if (first_blk) dynrng <= 8'h00;   // unity == 0x00 (see reset above)
            end else if (!awaiting) begin
                // ---- issue phase: request the current field (or skip it) ----
                case (st)
                    // blksw + dithflag are read as nfchans bits in one go.
                    A_BLKSW:  begin req <= 1'b1; nbits <= {3'd0, nfchans}; awaiting <= 1'b1; end
                    A_DITH:   begin req <= 1'b1; nbits <= {3'd0, nfchans}; awaiting <= 1'b1; end
                    A_DYNE:   begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_DYNV:   begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    A_CPLSTRE:begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_CPLINU: begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_CHINCPL:begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_PHSE:   begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_CPLBEGF:begin req <= 1'b1; nbits <= 6'd4;  awaiting <= 1'b1; end
                    A_CPLENDF:begin req <= 1'b1; nbits <= 6'd4;  awaiting <= 1'b1; end
                    A_CPLBSTR:begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end

                    A_CPLCOE_INIT: begin
                        if (chincpl == 5'b0) st <= state_t'(is_stereo ? A_REMATSTR : A_CPLEXPSTR);
                        else begin ci <= 3'd0; cplcoe_any <= 1'b0; st <= A_CPLCOE; end
                    end

                    A_CPLCOE: begin
                        if (cur_coupled) begin
                            req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1;  // cplcoe
                        end else begin                          // ch not coupled
                            if (ci == nfm1) st <= A_PHSFLG_INIT;
                            else ci <= ci + 3'd1;
                        end
                    end

                    A_MSTRCPL:  begin req <= 1'b1; nbits <= 6'd2;  awaiting <= 1'b1; end
                    A_CPLCOEXP: begin req <= 1'b1; nbits <= 6'd4;  awaiting <= 1'b1; end
                    A_CPLCOMANT:begin req <= 1'b1; nbits <= 6'd4;  awaiting <= 1'b1; end

                    A_PHSFLG_INIT: begin
                        if (phsflginu && cplcoe_any) begin cb <= 5'd0; st <= A_PHSFLG; end
                        else st <= state_t'(is_stereo ? A_REMATSTR : A_CPLEXPSTR);
                    end
                    A_PHSFLG: begin req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1; end

                    A_REMATSTR: begin req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1; end
                    A_REMATF:   begin req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1; end

                    A_CPLEXPSTR: begin
                        if (chincpl != 5'b0) begin
                            req <= 1'b1; nbits <= 6'd2; awaiting <= 1'b1;
                        end else begin cplexpstr <= 2'd0; ci <= 3'd0; st <= A_CHEXP; end
                    end

                    A_CHEXP: begin req <= 1'b1; nbits <= 6'd2; awaiting <= 1'b1; end

                    A_LFEEXPSTR: begin req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1; end

                    A_CHBW: begin
                        if (cur_chexpstr == 2'd0) begin            // reuse: no chbwcod
                            if (ci == nfm1) begin ci <= 3'd0; st <= A_CPLEXPF; end
                            else ci <= ci + 3'd1;
                        end else if (cur_coupled) begin            // coupled: endmant=cplstrtmant
                            endmant[ci*9 +: 9] <= cplstrtmant;
                            nchgrps[ci*7 +: 7] <= nchgrps_cpl;
                            if (ci == nfm1) begin ci <= 3'd0; st <= A_CPLEXPF; end
                            else ci <= ci + 3'd1;
                        end else begin
                            req <= 1'b1; nbits <= 6'd6; awaiting <= 1'b1;
                        end
                    end

                    A_CPLEXPF: begin
                        if (cplexpstr == 2'd0) st <= A_EXPF;       // reuse: no cpl exps
                        else begin req <= 1'b1; nbits <= 6'd4; awaiting <= 1'b1; end
                    end
                    A_CPLEXPG: begin
                        if (cgi > ncplgrps) st <= A_EXPF;          // cpl groups done
                        else begin req <= 1'b1; nbits <= 6'd7; awaiting <= 1'b1; end
                    end

                    A_EXPF: begin
                        if (cur_chexpstr == 2'd0) begin            // reuse: no exps
                            if (ci == nfm1) st <= state_t'(lfeon ? A_LFEEXPF : A_BAIE);
                            else ci <= ci + 3'd1;
                        end else begin
                            req <= 1'b1; nbits <= 6'd4; awaiting <= 1'b1;
                        end
                    end

                    A_EXPG: begin
                        if (gi > cur_nchgrps) st <= A_GAIN;        // groups done
                        else begin req <= 1'b1; nbits <= 6'd7; awaiting <= 1'b1; end
                    end

                    A_GAIN:   begin req <= 1'b1; nbits <= 6'd2;  awaiting <= 1'b1; end

                    A_LFEEXPF: begin
                        if (lfeexpstr == 1'b0) st <= A_BAIE;       // reuse: no lfe exps
                        else begin req <= 1'b1; nbits <= 6'd4; awaiting <= 1'b1; end
                    end
                    A_LFEEXPG: begin
                        if (lgi > 2'd2) st <= A_BAIE;              // 2 lfe groups done
                        else begin req <= 1'b1; nbits <= 6'd7; awaiting <= 1'b1; end
                    end

                    A_BAIE:   begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_BAI:    begin req <= 1'b1; nbits <= 6'd11; awaiting <= 1'b1; end
                    A_SNRE:   begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_CSNR:   begin req <= 1'b1; nbits <= 6'd6;  awaiting <= 1'b1; end
                    A_CPLBAI: begin req <= 1'b1; nbits <= 6'd7;  awaiting <= 1'b1; end
                    A_FSNR:   begin req <= 1'b1; nbits <= 6'd7;  awaiting <= 1'b1; end
                    A_LFEFSNR:begin req <= 1'b1; nbits <= 6'd7;  awaiting <= 1'b1; end

                    A_CPLLKE: begin
                        if (chincpl != 5'b0) begin
                            req <= 1'b1; nbits <= 6'd1; awaiting <= 1'b1;  // cplleake
                        end else st <= A_DBAE;
                    end
                    A_CPLLK:  begin req <= 1'b1; nbits <= 6'd6;  awaiting <= 1'b1; end

                    A_DBAE:   begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_CPLDBAE:begin req <= 1'b1; nbits <= 6'd2;  awaiting <= 1'b1; end
                    A_DBA:    begin req <= 1'b1; nbits <= 6'd2;  awaiting <= 1'b1; end

                    A_DPRE: begin
                        if (cur_deltbae == 2'd1) begin             // DELTA_BIT_NEW
                            dband <= 7'd0; st <= A_DCLR;            // clear, then parse
                        end else begin
                            if (ci == nfm1) st <= A_SKIPE;
                            else ci <= ci + 3'd1;
                        end
                    end

                    A_DCLR: begin
                        deltba_mem[{ci, dband[5:0]}] <= 4'sd0;
                        if (dband == 7'd49) begin dband <= 7'd0; st <= A_DNSEG; end
                        else dband <= dband + 7'd1;
                    end

                    A_DNSEG: begin req <= 1'b1; nbits <= 6'd3; awaiting <= 1'b1; end

                    A_DSEG: begin
                        if (dseg > dnseg) begin                    // segments done
                            if (ci == nfm1) st <= A_SKIPE;
                            else begin ci <= ci + 3'd1; st <= A_DPRE; end
                        end else begin
                            req <= 1'b1; nbits <= 6'd12; awaiting <= 1'b1; // off5+len4+ba3
                        end
                    end

                    A_DFILL: begin
                        deltba_mem[{ci, dband[5:0]}] <= dval;
                        dband <= dband + 7'd1;
                        if (dfill == 4'd1) begin dseg <= dseg + 3'd1; st <= A_DSEG; end
                        else dfill <= dfill - 4'd1;
                    end

                    A_SKIPE:  begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    A_SKIPL:  begin req <= 1'b1; nbits <= 6'd9;  awaiting <= 1'b1; end

                    A_SKIPF: begin
                        if (skip_rem == 13'd0) begin
                            st               <= A_DONE;
                            block_side_valid <= 1'b1;
                            blk_bits         <= bitpos - start_bitpos;
                        end else begin
                            skip_nb  <= (skip_rem >= 13'd24) ? SKIP_CHUNK : skip_rem[5:0];
                            nbits    <= (skip_rem >= 13'd24) ? SKIP_CHUNK : skip_rem[5:0];
                            req      <= 1'b1;
                            awaiting <= 1'b1;
                        end
                    end

                    default: ; // A_IDLE/A_DONE/A_ERR: idle, no requests
                endcase
            end else if (ack) begin
                // ---- consume phase: latch the field, advance ----
                awaiting <= 1'b0;
                case (st)
                    A_BLKSW: begin
                        // M16: nfchans bits, ch0 in the MSB.  De-interleave to a
                        // per-channel flag (blksw[ch]) like dithflag, so the IMDCT
                        // can index blksw[ch] directly to pick the 256-pt short
                        // transform.  Short blocks are now SUPPORTED (no fail-loud).
                        blksw[0] <= data_in[nfchans-1];
                        blksw[1] <= (nfchans > 3'd1) ? data_in[nfchans-2] : 1'b0;
                        blksw[2] <= (nfchans > 3'd2) ? data_in[nfchans-3] : 1'b0;
                        blksw[3] <= (nfchans > 3'd3) ? data_in[nfchans-4] : 1'b0;
                        blksw[4] <= (nfchans > 3'd4) ? data_in[nfchans-5] : 1'b0;
                        st <= A_DITH;
`ifdef AC3_COSIM
                        if ((data_in & ((32'd1 << nfchans) - 32'd1)) != 32'd0)
                            $display("AUDBLK_SHORT blksw=%b", data_in[4:0]);
`endif
                    end
                    A_DITH:  begin
                        // dithflag[ch] = field[nfchans-1-ch]; reverse up to 5 bits.
                        dithflag[0] <= data_in[nfchans-1];
                        dithflag[1] <= (nfchans > 3'd1) ? data_in[nfchans-2] : 1'b0;
                        dithflag[2] <= (nfchans > 3'd2) ? data_in[nfchans-3] : 1'b0;
                        dithflag[3] <= (nfchans > 3'd3) ? data_in[nfchans-4] : 1'b0;
                        dithflag[4] <= (nfchans > 3'd4) ? data_in[nfchans-5] : 1'b0;
                        st <= A_DYNE;
                    end
                    A_DYNE:  st <= state_t'(data_in[0] ? A_DYNV : A_CPLSTRE);
                    A_DYNV:  begin
                        dynrng <= data_in[7:0];         // M17: apply DRC gain
                        st <= A_CPLSTRE;
                    end

                    // ---- coupling strategy ----
                    A_CPLSTRE: begin
                        if (data_in[0]) begin               // cplstre: new strategy
                            chincpl <= 5'd0; st <= A_CPLINU;
                        end else st <= A_CPLCOE_INIT;       // reuse prior chincpl/geom
                    end
                    A_CPLINU: st <= state_t'(data_in[0] ? A_CHINCPL : A_CPLCOE_INIT);
                    A_CHINCPL: begin
                        chincpl[ci] <= data_in[0];
                        if (ci == nfm1) begin
                            ci <= 3'd0;
                            st <= state_t'(is_stereo ? A_PHSE : A_CPLBEGF);  // phsflginu stereo only
                        end else ci <= ci + 3'd1;
                    end
                    A_PHSE: begin phsflginu <= data_in[0]; st <= A_CPLBEGF; end
                    A_CPLBEGF: begin cplbegf_r <= data_in[3:0]; st <= A_CPLENDF; end
                    A_CPLENDF: begin
                        // ncplsubnd = cplendf + 3 - cplbegf; <0 is illegal.
                        if (({1'b0, data_in[3:0]} + 5'd3) < {1'b0, cplbegf_r}) begin
                            err_unsupported <= 1'b1; st <= A_ERR;
`ifdef AC3_COSIM
                            $display("AUDBLK_OOS reason=CPL_GEOM cplbegf=%0d cplendf=%0d", cplbegf_r, data_in[3:0]);
`endif
                        end else begin
                            csubnd      <= ({1'b0, data_in[3:0]} + 5'd3) - {1'b0, cplbegf_r};
                            ncplbnd     <= ({1'b0, data_in[3:0]} + 5'd3) - {1'b0, cplbegf_r};
                            cplstrtmant <= ({3'd0, cplbegf_r} * 9'd12) + 9'd37;
                            cplendmant  <= ({3'd0, data_in[3:0]} * 9'd12) + 9'd73;
                            cplstrtbnd  <= bndtab(cplbegf_r);
                            cb          <= 5'd0;
                            cplbndstrc  <= 18'd0;
                            // ncplsubnd-1 band-structure bits to read (0 -> none).
                            if ((({1'b0, data_in[3:0]} + 5'd3) - {1'b0, cplbegf_r}) > 5'd1)
                                st <= A_CPLBSTR;
                            else st <= A_CPLCOE_INIT;
                        end
                    end
                    A_CPLBSTR: begin
                        // cplbndstrc[cb]: 1 -> merge this sub-band into prior band.
                        if (data_in[0]) begin
                            ncplbnd <= ncplbnd - 5'd1;
                            cplbndstrc[cb] <= 1'b1;
                        end
                        if (cb + 5'd1 >= csubnd - 5'd1) begin cb <= 5'd0; st <= A_CPLCOE_INIT; end
                        else cb <= cb + 5'd1;
                    end

                    // ---- coupling coordinates ----
                    A_CPLCOE: begin
                        if (data_in[0]) begin               // cplcoe: new coords
                            cplcoe_any <= 1'b1; st <= A_MSTRCPL;
                        end else begin                      // reuse this ch's coords
                            if (ci == nfm1) st <= A_PHSFLG_INIT;
                            else ci <= ci + 3'd1;
                        end
                    end
                    A_MSTRCPL: begin
                        mstrcplco_r <= {data_in[1:0], 1'b0} + {1'b0, data_in[1:0]}; // 3*x
                        cb <= 5'd0; st <= A_CPLCOEXP;
                    end
                    A_CPLCOEXP: begin cplcoexp_r <= data_in[3:0]; st <= A_CPLCOMANT; end
                    A_CPLCOMANT: begin
                        cplco_mem[{ci, cb}] <= $signed(cplco_val[23:0]);
                        // fresh ch1 coordinate => clear its accumulated phase sign
                        // (the stored value is the un-negated coordinate).
                        if (ci == 3'd1) phsneg[cb] <= 1'b0;
                        if (cb + 5'd1 >= ncplbnd) begin     // this channel done
                            cb <= 5'd0;
                            if (ci == nfm1) begin ci <= 3'd0; st <= A_PHSFLG_INIT; end
                            else begin ci <= ci + 3'd1; st <= A_CPLCOE; end
                        end else begin cb <= cb + 5'd1; st <= A_CPLCOEXP; end
                    end
                    A_PHSFLG: begin
                        // phsflg only present for acmod==2; it flips channel 1.
                        // Toggle the per-band sign accumulator instead of an
                        // in-place memory negate (kept cplco_mem at 2 ports / M10K).
                        // Equivalent to the old `cplco[1][bnd] <= -cplco[1][bnd]`.
                        if (data_in[0]) phsneg[cb] <= ~phsneg[cb];
                        if (cb + 5'd1 >= ncplbnd) st <= A_REMATSTR;
                        else cb <= cb + 5'd1;
                    end

                    // ---- rematrixing (stereo only) ----
                    A_REMATSTR: begin
                        if (data_in[0]) begin               // rematstr: re-parse flags
                            rematflg <= 4'd0; cb <= 5'd0; st <= A_REMATF;
                        end else st <= A_CPLEXPSTR;          // reuse prior rematflg
                    end
                    A_REMATF: begin
                        if (data_in[0]) rematflg[cb] <= 1'b1;
                        // do-while: continue while rematrix_band[cb] < end.
                        if (remat_band < remat_end) cb <= cb + 5'd1;
                        else st <= A_CPLEXPSTR;
                    end

                    // ---- exponent strategy ----
                    A_CPLEXPSTR: begin cplexpstr <= data_in[1:0]; ci <= 3'd0; st <= A_CHEXP; end
                    A_CHEXP: begin
                        chexpstr[ci*2 +: 2] <= data_in[1:0];
                        if (ci == nfm1) begin
                            ci <= 3'd0;
                            st <= state_t'(lfeon ? A_LFEEXPSTR : A_CHBW);
                        end else ci <= ci + 3'd1;
                    end
                    A_LFEEXPSTR: begin lfeexpstr <= data_in[0]; ci <= 3'd0; st <= A_CHBW; end
                    A_CHBW: begin
                        endmant[ci*9 +: 9] <= endmant_w;
                        nchgrps[ci*7 +: 7] <= nchgrps_w;
                        if (ci == nfm1) begin ci <= 3'd0; st <= A_CPLEXPF; end
                        else ci <= ci + 3'd1;
                    end

                    // ---- coupling-channel exponents ----
                    A_CPLEXPF: begin
                        cpl_exp_mem[0] <= {4'd0, data_in[3:0]};  // cplabsexp (raw 4b)
                        cgi <= 7'd1; st <= A_CPLEXPG;
                    end
                    A_CPLEXPG: begin
                        cpl_exp_mem[cgi[6:0]] <= {1'b0, data_in[6:0]};
                        cgi <= cgi + 7'd1;
                    end

                    // ---- fbw-channel exponents ----
                    A_EXPF: begin
                        exp_mem[{ci, 7'd0}] <= {4'd0, data_in[3:0]};  // absolute exp
                        gi <= 7'd1; st <= A_EXPG;
                    end
                    A_EXPG: begin
                        exp_mem[{ci, gi}] <= {1'b0, data_in[6:0]};    // grouped code
                        gi <= gi + 7'd1;
                    end
                    A_GAIN: begin                                     // gainrng discarded
                        if (ci == nfm1) begin
                            ci <= 3'd0; st <= state_t'(lfeon ? A_LFEEXPF : A_BAIE);
                        end else begin ci <= ci + 3'd1; st <= A_EXPF; end
                    end

                    // ---- LFE-channel exponents ----
                    A_LFEEXPF: begin
                        lfe_exp_mem[0] <= {4'd0, data_in[3:0]};  // lfe absolute exp
                        lgi <= 2'd1; st <= A_LFEEXPG;
                    end
                    A_LFEEXPG: begin
                        lfe_exp_mem[lgi] <= {1'b0, data_in[6:0]};
                        lgi <= lgi + 2'd1;
                    end

                    A_BAIE: st <= state_t'(data_in[0] ? A_BAI : A_SNRE);
                    A_BAI: begin
                        sdcycod  <= data_in[10:9];
                        fdcycod  <= data_in[8:7];
                        sgaincod <= data_in[6:5];
                        dbpbcod  <= data_in[4:3];
                        floorcod <= data_in[2:0];
                        st <= A_SNRE;
                    end
                    // cplleake follows the snroffste block UNCONDITIONALLY in
                    // liba52 (if chincpl), so route the snroffste==0 case through
                    // A_CPLLKE too (it falls through to A_DBAE when uncoupled).
                    A_SNRE: st <= state_t'(data_in[0] ? A_CSNR : A_CPLLKE);
                    A_CSNR: begin
                        csnroffst <= data_in[5:0]; ci <= 3'd0;
                        st <= state_t'((chincpl != 5'b0) ? A_CPLBAI : A_FSNR);
                    end
                    A_CPLBAI: begin cplba_bai <= data_in[6:0]; st <= A_FSNR; end
                    A_FSNR: begin
                        fsnroffst[ci*4 +: 4] <= data_in[6:3];
                        fgaincod [ci*3 +: 3] <= data_in[2:0];
                        if (ci == nfm1) st <= state_t'(lfeon ? A_LFEFSNR : A_CPLLKE);
                        else ci <= ci + 3'd1;
                    end
                    A_LFEFSNR: begin lfeba_bai <= data_in[6:0]; st <= A_CPLLKE; end
                    A_CPLLKE: st <= state_t'(data_in[0] ? A_CPLLK : A_DBAE);
                    A_CPLLK: begin
                        cplfleak <= 4'd9 - {1'b0, data_in[5:3]};
                        cplsleak <= 4'd9 - {1'b0, data_in[2:0]};
                        st <= A_DBAE;
                    end
                    A_DBAE: begin
                        if (data_in[0]) begin
                            ci <= 3'd0;
                            st <= state_t'((chincpl != 5'b0) ? A_CPLDBAE : A_DBA);
                        end else st <= A_SKIPE;
                    end
                    A_CPLDBAE: begin
                        cpl_deltbae <= data_in[1:0];
                        if (data_in[1:0] == 2'd3) begin       // reserved
                            err_unsupported <= 1'b1; st <= A_ERR;
`ifdef AC3_COSIM
                            $display("AUDBLK_OOS reason=CPL_DELTBAE_RESERVED");
`endif
                        end else if (data_in[1:0] == 2'd1) begin  // NEW: not yet wired
                            err_unsupported <= 1'b1; st <= A_ERR;
`ifdef AC3_COSIM
                            $display("AUDBLK_OOS reason=CPL_DELTBAE_NEW");
`endif
                        end else begin ci <= 3'd0; st <= A_DBA; end
                    end
                    A_DBA: begin
                        deltbae[ci*2 +: 2] <= data_in[1:0];
                        if (data_in[1:0] == 2'd3) begin       // reserved
                            err_unsupported <= 1'b1; st <= A_ERR;
`ifdef AC3_COSIM
                            $display("AUDBLK_OOS reason=FBW_DELTBAE_RESERVED ch=%0d", ci);
`endif
                        end else if (ci == nfm1) begin ci <= 3'd0; st <= A_DPRE; end
                        else ci <= ci + 3'd1;
                    end
                    A_DNSEG: begin
                        dnseg <= data_in[2:0]; dseg <= 3'd0; dband <= 7'd0;
                        st <= A_DSEG;
                    end
                    A_DSEG: begin
                        if (data_in[6:3] == 4'd0) begin           // deltlen==0: skip
                            dband <= dband + {2'd0, data_in[11:7]};
                            dseg  <= dseg + 3'd1;
                        end else if (({2'd0, dband} + {4'd0, data_in[11:7]} +
                                      {5'd0, data_in[6:3]}) >= 9'd50) begin
                            err_unsupported <= 1'b1; st <= A_ERR;
`ifdef AC3_COSIM
                            $display("AUDBLK_OOS reason=DELTA_BA_OVERFLOW");
`endif
                        end else begin
                            dband <= dband + {2'd0, data_in[11:7]};
                            dfill <= data_in[6:3];
                            dval  <= $signed({1'b0, data_in[2:0]}) -
                                     (data_in[2] ? 4'sd3 : 4'sd4);
                            st    <= A_DFILL;
                        end
                    end
                    A_SKIPE: begin
                        if (data_in[0]) st <= A_SKIPL;
                        else begin
                            st <= A_DONE; block_side_valid <= 1'b1;
                            blk_bits <= bitpos - start_bitpos;
                        end
                    end
                    A_SKIPL: begin skip_rem <= {data_in[8:0], 3'd0}; st <= A_SKIPF; end
                    A_SKIPF: skip_rem <= skip_rem - {7'd0, skip_nb};
                    default: ;
                endcase
            end
        end
    end

endmodule
