//============================================================================
//  bit_allocation.sv — AC-3 bit allocation (M6, second datapath stage).
//
//  Consumes the absolute exponents from exponent_decode (dexp_mem) plus the
//  bit-allocation parameters staged by audblk_parse, and produces the per-band
//  bit-allocation pointers bap[] that mantissa_dequant (M7) uses to size each
//  mantissa.  Started by a pulse (the sequencer drives it on exp_done); the
//  bit_reader is idle while it runs, so it consumes no bitstream.
//
//  ALGORITHM — a *literal* transcription of liba52 0.8.0 a52_bit_allocate()
//  (A/52 §7.2), so the derived bap[] is bit-exact to liba52's
//  fbw_expbap[ch].bap[] (the co-sim golden).  liba52 is integer here, so unlike
//  the float DSP stages this stage CAN be bit-exact.  Per channel, with the
//  in-scope call shape bndstart=0,start=0,end=endmant,fastleak=slowleak=0:
//
//    consts: fdecay,fgain,sdecay,sgain,dbknee,floor,snroffset  (BAI sub-codes)
//    phase 1 : bins 0..2 (and up to 6 while exp rising) — lowcomp=384 seed
//    phase 2 : bins ..6   — leaky integrator kicks in
//    phase 3 : bins 7..19 — lowcomp=320 seed
//    phase 4 : lowcomp tail (<=2 bins)
//    phase 5 : banded loop (bndtab) with log-add PSD integration (latab)
//    each bin/band:  mask -> bap[k] = (baptab+156)[mask + 4*exp[k]]
//
//  The two COMPUTE_MASK / UPDATE_LEAK macros and the (baptab+156)[] lookup live
//  in the functions below; tables are in ac3_tables.svh (ROMs).
//
//  PoC SIMPLIFICATIONS (documented, all true for the in-scope 48 kHz stereo
//  path):
//    - halfrate==0 (48 kHz), so every ">> halfrate" is a no-op and hth is the
//      fscod==0 row only (ac3_tables hthtab0).
//    - no coupling / no lfe channel: only the two fbw channels, each called
//      with bndstart=start=0, fastleak=slowleak=0.
//    - delta bit allocation: DELTA_BIT_NEW is honoured (deltba read from
//      audblk_parse), DELTA_BIT_NONE -> zeros (matches liba52).  DELTA_BIT_REUSE
//      across blocks is out of scope for the block-0-only M6 integration.
//    - zero_snr_offsets: if csnroffst==0 and both fsnroffst==0, liba52 forces
//      bap[]=0 — handled by the C_ZERO fast path.
//
//  MEMORIES / handshake:
//    - ba_exp_rd_* : reads exponent_decode.dexp_mem (1-cycle latent); copied
//      once into the local expc RAMs at channel start.  M19: expc is a pair of
//      identically-written 1W1R sync RAMs (not a register file), so the masking
//      math fetches exp[i]/exp[i+1]/exp[j] via a ph0-fetch/ph1-execute
//      micro-cycle in each compute state (values unchanged, reads 1 cyc later).
//    - deltba_rd_*: reads audblk_parse.deltba_mem, copied into the local dbc
//      RAM likewise (gated by deltbae==NEW).
//    - bap_mem    : single write port (one bap/cycle), combinational read port
//      (bap_rd_addr/data) for mantissa_dequant (M7) and the co-sim.  512 entries
//      addressed {ch, idx[7:0]} (endmant <= 253).  Stored signed (liba52 uses
//      negative bap to flag the grouped quantizers).
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module bit_allocation (
    input  logic        clk,
    input  logic        rst,

    // begin bit allocation for this block (pulse, e.g. exponent_decode.done)
    input  logic        start,

    // channel config + per-fbw-channel geometry (packed: ch occupies [ch*W +: W])
    input  logic [2:0]  nfchans,     // 2 or 5
    input  logic        lfeon,
    input  logic [44:0] endmant,     // 9 bits/ch

    // bit-allocation parameters (BAI + SNR offsets) from audblk_parse
    input  logic [1:0]  sdcycod,
    input  logic [1:0]  fdcycod,
    input  logic [1:0]  sgaincod,
    input  logic [1:0]  dbpbcod,
    input  logic [2:0]  floorcod,
    input  logic [5:0]  csnroffst,
    input  logic [19:0] fsnroffst,   // 4 bits/ch
    input  logic [14:0] fgaincod,    // 3 bits/ch
    input  logic [9:0]  deltbae,     // 2 bits/ch (0=reuse 1=new 2=none 3=resv)

    // LFE bit-alloc params (M14): lfeba.bai = {fsnroffst[6:3], fgaincod[2:0]}
    input  logic [6:0]  lfeba_bai,

    // coupling-channel bit-alloc params (M12 Stage B)
    input  logic [4:0]  chincpl,
    input  logic [8:0]  cplstrtmant,
    input  logic [8:0]  cplendmant,
    input  logic [5:0]  cplstrtbnd,
    input  logic [3:0]  cplfleak,     // fast-leak init (seeds fastleak = <<8)
    input  logic [3:0]  cplsleak,     // slow-leak init (seeds slowleak = <<8)
    input  logic [6:0]  cplba_bai,    // {fsnroffst[6:3], fgaincod[2:0]}

    // exponent read port -> exponent_decode.dexp_mem (combinational).  addr
    // {ch[2:0], idx[7:0]}: 0..4 fbw, 5 coupling, 6 LFE.
    output logic [10:0] ba_exp_rd_addr,
    input  logic [4:0]  ba_exp_rd_data,

    // delta-ba read port -> audblk_parse.deltba_mem (combinational)
    output logic [8:0]  deltba_rd_addr,   // {ch[2:0], band[5:0]}
    input  logic signed [3:0] deltba_rd_data,

    // bap read port (combinational): addr {ch[2:0], idx[7:0]}, signed bap
    input  logic [10:0] bap_rd_addr,
    output logic signed [7:0] bap_rd_data,

    // second bap read port (combinational) for mantissa_dequant.
    input  logic [10:0] mant_bap_rd_addr,
    output logic signed [7:0] mant_bap_rd_data,

    output logic        done          // 1-cycle pulse: all channels allocated
);

    localparam logic [2:0] CPL = AC3_CH_CPL[2:0];   // 5
    localparam logic [2:0] LFE = AC3_CH_LFE[2:0];   // 6
    wire [2:0] nfm1 = nfchans - 3'd1;

    // ---- bit-allocation ROM tables (baptab/latab/hthtab0/bndtab/...) ----
    `include "ac3_tables.svh"

    // ---- derived bit allocation pointers ----
    // Address {ch[1:0], idx[7:0]}: ch 0/1 = fbw, ch 2 = coupling channel (M12);
    // 1024 entries.  mant_bap_rd_addr stays 9-bit (mantissa is coupling-unaware
    // until Stage C; it only reaches ch 0/1).
    // M13 area pass: bap_mem (1024×8) used to have two combinational read ports
    // (the cosim bap_rd tap + mantissa's mant_bap_rd) so Quartus realized it as
    // registers.  Convert to a 1W1R M10K: a single explicit write port funnels
    // every C_* write, and one synchronous read port (bm_rq) serves mantissa
    // (now 1-cycle latency — mantissa inserts M_FETCH/M_CPLFETCH).  The cosim/TB
    // async bap_rd tap is compiled out of synthesis (AC3_COSIM) so it cannot
    // block M10K inference.
    (* ramstyle = "M10K, no_rw_check" *)
    logic signed [7:0] bap_mem [0:2047];

    logic              bm_we;
    logic [10:0]       bm_waddr;
    logic signed [7:0] bm_wdata;
    logic [10:0]       bm_raddr;
    logic signed [7:0] bm_rq;
    always_ff @(posedge clk) begin
        if (bm_we) bap_mem[bm_waddr] <= bm_wdata;
        bm_rq <= bap_mem[bm_raddr];
    end

    // ---- bap-write pipeline (timing) -------------------------------------
    // The single-cycle phases C_P1..C_P4 used to compute compute_mask AND
    // bap_lookup in one cycle — two SERIAL ROM reads (hthtab0 then baptab) plus
    // 32-bit arithmetic, which failed setup at the 27 MHz clk_sys by ~1.3 ns and
    // glitched the audio ("static blips").  We decouple bap_lookup into a shared
    // 1-deep stage: states stage the mask+exponent (or a literal, for C_ZERO)
    // into pend_*, and this stage performs the bap_lookup and drives the bap_mem
    // write port one cycle later.  Phase 5 already did this split (C_P5MASK ->
    // C_P5WRITE) and never violated.  bap_mem writes now lag one extra cycle, so
    // the terminal `done` is delayed through C_FLUSH until the last write commits.
    logic               pend_we;
    logic [10:0]        pend_waddr;
    logic               pend_lookup;     // 1: bap_lookup(pend_mask,pend_e); 0: pend_lit
    logic signed [31:0] pend_mask;
    logic        [4:0]  pend_e;
    logic signed [7:0]  pend_lit;
    logic        [1:0]  flush_cnt;
    // M19b: the baptab read is now a sync M10K ROM, so the write pipeline gains
    // a stage: pend_* -> (baptab_q registers alongside p2_*) -> bm_* commit.
    logic               p2_we;
    logic [10:0]        p2_waddr;
    logic               p2_lookup;
    logic signed [7:0]  p2_lit;
    assign bm_raddr         = mant_bap_rd_addr;   // sole reader in hardware
    assign mant_bap_rd_data = bm_rq;

`ifdef AC3_COSIM
    assign bap_rd_data = bap_mem[bap_rd_addr];    // sim-only async verification tap
`else
    assign bap_rd_data = 8'sd0;
`endif

    // ---- local per-channel working copies (M19 area pass) ----
    // expc/dbc used to be plain register arrays (256×5 + 64×4 FFs) with
    // multi-tap combinational reads (expc[i] + expc[i+1] in the same cycle,
    // plus expc[j] / expc[jw]) — Quartus realized them as a ~1.5k-FF register
    // file with 256-way write decoders and read crossbars (the bulk of this
    // module's ~3k ALMs).  Converted to synchronous-read RAMs using the proven
    // bap_mem/M13 same-block 1W1R template.  expc is duplicated into two
    // identically-written copies so the two same-cycle read taps map onto two
    // 1W1R memories (exactly the replication synthesis performs for 1W2R).
    // Reads are now 1-cycle latent: each compute state runs a ph0-fetch /
    // ph1-execute micro-cycle (see `ph`).  Computed values are IDENTICAL to
    // the register-array version — only the cycle a value is read moves.
    // No reset loops on these arrays (RAM-inference rule).
    (* ramstyle = "M10K, no_rw_check" *)
    logic [4:0] expc_a [0:255];        // absolute exponents, this channel
    (* ramstyle = "M10K, no_rw_check" *)
    logic [4:0] expc_b [0:255];        // write-mirror of expc_a (2nd read tap)
    (* ramstyle = "MLAB, no_rw_check" *)
    logic signed [3:0] dbc_mem [0:63]; // delta-ba per band, this channel

    logic [4:0]        ex_qa, ex_qb;   // sync reads: expc[raddr_a/b]
    logic signed [3:0] db_q;           // sync read: dbc[i]

    // ---- per-channel constants (latched at channel start) ----
    logic signed [31:0] fdecay, fgain, sdecay, sgain, dbknee, floor_s, snroffset;
    logic        [8:0]  end_r;

    // ---- FSM ----
    typedef enum logic [3:0] {
        C_IDLE, C_CHINIT, C_COPY,
        C_P1, C_P2, C_P3, C_P4,
        C_P5SETUP, C_P5ACC, C_P5MASK, C_P5WRITE,
        C_ZERO, C_CCHINIT, C_CCOPY, C_FLUSH
    } state_t;
    state_t st;

    logic [2:0]  cur_ch;               // fbw channel index (0..nfm1)
    logic        cpl;                  // coupling-channel pass in progress
    logic        lfe;                  // LFE-channel pass in progress
    logic [11:0] kcnt;                 // copy / zero counter
    // exp/deltba prefetch pipeline (ba_exp_rd is now a 1-cycle-latent M10K read —
    // see exponent_decode dexp_mem note).  copy_primed gates the first write until
    // the registered read has caught up.  (M19d: deltba_rd is now itself a
    // registered read in audblk_parse — landing exactly where the old local
    // deltba_q realignment register did, so that register is deleted.)
    logic        copy_primed;
    logic [7:0]  i;                    // band/bin index (<=49; 8b for clean idx)
    logic [8:0]  jcap;                 // end-1 (phase 1/2 lowcomp guard)
    logic signed [15:0] lowcomp;
    logic signed [31:0] psd_r, fastleak_r, slowleak_r, mask_r;
    logic [8:0]  j, jw, sb, eb;        // phase-5 read / write / band bounds
    logic [1:0]  ph;                   // M19 micro-phase: 0=fetch RAM operands,
                                       // 1=execute the original state body
                                       // (2 = C_P5ACC log-add apply, M19b)
    logic signed [31:0] vnext_r, vdelta_r;  // M19b: C_P5ACC ph1->ph2 operands

    // destination channel slot for bap writes (fbw / coupling / LFE).
    wire [2:0] cur_slot = lfe ? LFE : cpl ? CPL : cur_ch;

    // ---- combinational parameter selects + constant expressions ----
    // LFE uses lfeba.bai; fbw use their packed per-channel sub-codes.
    wire [8:0] sel_endmant  = lfe ? 9'd7 : endmant[cur_ch*9 +: 9];
    wire [2:0] sel_fgaincod = lfe ? lfeba_bai[2:0] : fgaincod[cur_ch*3 +: 3];
    wire [3:0] sel_fsnroffst= lfe ? lfeba_bai[6:3] : fsnroffst[cur_ch*4 +: 4];
    wire [1:0] sel_deltbae  = lfe ? 2'd2 : deltbae[cur_ch*2 +: 2];  // lfe: no delta-BA

    wire signed [31:0] w_fdecay = 32'sd63 + 32'sd20 * $signed({30'd0, fdcycod});
    wire signed [31:0] w_sdecay = 32'sd15 + 32'sd2  * $signed({30'd0, sdcycod});
    wire signed [31:0] w_sgain  = $signed({20'd0, slowgain_t[sgaincod]});
    wire signed [31:0] w_dbknee = $signed({19'd0, dbpbtab_t[dbpbcod]});
    wire signed [31:0] w_fgain  = 32'sd128 + 32'sd128 * $signed({29'd0, sel_fgaincod});
    wire signed [31:0] w_floorf = $signed({19'd0, floortab_t[floorcod]});
    wire signed [31:0] w_snr    = 32'sd960 - 32'sd64 * $signed({26'd0, csnroffst})
                                          - 32'sd4  * $signed({28'd0, sel_fsnroffst})
                                          + w_floorf;
    wire signed [31:0] w_floors = w_floorf >>> 5;

    // coupling-channel constants (M12 Stage B): fgain/snroffset use cplba.bai's
    // sub-codes; fdecay/sdecay/sgain/dbknee/floor are channel-independent.
    wire [2:0] cpl_fgaincod  = cplba_bai[2:0];
    wire [3:0] cpl_fsnroffst = cplba_bai[6:3];
    wire signed [31:0] w_fgain_cpl = 32'sd128 + 32'sd128 * $signed({29'd0, cpl_fgaincod});
    wire signed [31:0] w_snr_cpl   = 32'sd960 - 32'sd64 * $signed({26'd0, csnroffst})
                                              - 32'sd4  * $signed({28'd0, cpl_fsnroffst})
                                              + w_floorf;

    wire [8:0] copy_n  = (end_r < 9'd50) ? 9'd50 : end_r;
    // liba52 zero_snr_offsets(): csnroffst==0 AND every active channel's
    // fsnroffst==0 (fbw 0..nfm1 + coupling-if-inuse + LFE-if-on).
    wire fbw_snr_nz =
        ((nfchans > 3'd0) && (fsnroffst[ 0 +: 4] != 4'd0)) ||
        ((nfchans > 3'd1) && (fsnroffst[ 4 +: 4] != 4'd0)) ||
        ((nfchans > 3'd2) && (fsnroffst[ 8 +: 4] != 4'd0)) ||
        ((nfchans > 3'd3) && (fsnroffst[12 +: 4] != 4'd0)) ||
        ((nfchans > 3'd4) && (fsnroffst[16 +: 4] != 4'd0));
    wire       zero_snr = (csnroffst == 6'd0) && !fbw_snr_nz &&
                          ((chincpl == 5'd0) || (cpl_fsnroffst == 4'd0)) &&
                          (!lfeon || (lfeba_bai[6:3] == 4'd0));
    wire [10:0] zero_top = 11'd2047;     // zero the whole bap_mem (all 7 slots)

    // ---- read-address drivers (combinational; copy-rate). ----
    wire [2:0] rd_ch = lfe ? LFE : cpl ? CPL : cur_ch;
    assign ba_exp_rd_addr = {rd_ch, kcnt[7:0]};
    assign deltba_rd_addr  = {cur_ch, kcnt[5:0]};

    // ---- expc/dbc RAM ports (M19) ----
    // Writes fire only in the copy states — the combinational decode of the
    // exact condition the old in-FSM array writes used (copy_primed gates the
    // first cycle; the terminal copy cycle still commits its write).  Reads
    // are muxed by state: port a serves expc[i], port b serves the second tap
    // (expc[i+1] in phases 1-4, expc[j] in P5SETUP/P5ACC, expc[jw] in P5WRITE).
    wire        ex_we    = ((st == C_COPY) || (st == C_CCOPY)) && copy_primed;
    wire [7:0]  ex_waddr = kcnt[7:0] - 8'd1;
    wire        db_we    = (st == C_COPY) && copy_primed && ((kcnt - 12'd1) < 12'd50);
    wire [5:0]  db_waddr = kcnt[5:0] - 6'd1;
    wire signed [3:0] db_wdata = (sel_deltbae == 2'd1) ? deltba_rd_data : 4'sd0;

    wire [7:0]  ex_raddr_a = i;                                       // expc[i]
    wire [7:0]  ex_raddr_b = ((st == C_P5SETUP) || (st == C_P5ACC)) ? j[7:0]  :
                             (st == C_P5WRITE)                      ? jw[7:0] :
                                                                      (i + 8'd1);
    always_ff @(posedge clk) begin
        if (ex_we) expc_a[ex_waddr] <= ba_exp_rd_data;
        ex_qa <= expc_a[ex_raddr_a];
    end
    always_ff @(posedge clk) begin
        if (ex_we) expc_b[ex_waddr] <= ba_exp_rd_data;
        ex_qb <= expc_b[ex_raddr_b];
    end
    always_ff @(posedge clk) begin
        if (db_we) dbc_mem[db_waddr] <= db_wdata;
        db_q <= dbc_mem[i[5:0]];
    end

    // ---- sync ROM read ports (M19b) ----
    // baptab: address formed combinationally from the pend_* stage (valid the
    // cycle after a state stages a lookup); baptab_q registers alongside p2_*.
    // This is the old bap_lookup() clamp, relocated ahead of the ROM.
    wire signed [31:0] bl_idx  = 32'sd156 + pend_mask
                               + (32'sd4 * $signed({27'd0, pend_e}));
    wire        [8:0]  bl_addr = (bl_idx < 0)         ? 9'd0
                               : (bl_idx > 32'sd304)  ? 9'd304
                               :                        bl_idx[8:0];
    logic signed [7:0] baptab_q;
    always_ff @(posedge clk) baptab_q <= baptab[bl_addr];

    // latab: the C_P5ACC log-add operand.  Address is the old vid clamp,
    // computed from ex_qb (expc[j], valid at C_P5ACC ph1) and the accumulated
    // psd_r; la_q registers at the ph1 edge and is applied at ph2.
    wire signed [31:0] la_vnext  = 32'sd128 * $signed({27'd0, ex_qb});
    wire signed [31:0] la_vdelta = la_vnext - psd_r;
    wire signed [31:0] la_vid    = ((la_vdelta >>> 9) == -32'sd1)
                                 ? ((-la_vdelta) >>> 1) : (la_vdelta >>> 1);
    wire        [7:0]  la_addr   = (la_vid > 32'sd255) ? 8'd255 : la_vid[7:0];
    logic signed [7:0] la_q;
    always_ff @(posedge clk) la_q <= latab[la_addr];

    // hthtab0: every compute_mask call site uses band == i, so one registered
    // read indexed by i is always current by the time a ph1 body consumes it
    // (i settles at least one full cycle — the ph0 fetch — beforehand).
    logic [15:0] hth_q;
    always_ff @(posedge clk) hth_q <= hthtab0[i[5:0]];

    // COMPUTE_MASK (liba52 macro): psd/pre-mask -> final mask (uses the latched
    // per-channel constants).  M19b: the hearing-threshold value is passed in
    // (hth_q sync-ROM read, band == i at every call site) instead of read from
    // the ROM inside the function.
    function automatic signed [31:0] compute_mask
        (input signed [31:0] psd_in, input signed [31:0] mask_in,
         input signed [31:0] hthv, input signed [3:0] db);
        logic signed [31:0] m;
        begin
            m    = mask_in;
            if (psd_in > dbknee) m = m - ((psd_in - dbknee) >>> 2);
            if (m > hthv)        m = hthv;
            m = m - (snroffset + 32'sd128 * $signed({{28{db[3]}}, db}));
            if (m > 0) m = 32'sd0; else m = (-m) >>> 5;
            m = m - floor_s;
            compute_mask = m;
        end
    endfunction

    // (M19b: the old bap_lookup() function — (baptab+156)[mask+4*exp] with the
    //  clamp — is now the bl_addr wire + sync baptab_q read + p2_* stage above.)

    // UPDATE_LEAK (liba52 macro), split per leak.
    function automatic signed [31:0] upd_fast
        (input signed [31:0] fl, input signed [31:0] psd_in);
        logic signed [31:0] x;
        begin
            x = fl + fdecay;
            if (x > psd_in + fgain) x = psd_in + fgain;
            upd_fast = x;
        end
    endfunction
    function automatic signed [31:0] upd_slow
        (input signed [31:0] sl, input signed [31:0] psd_in);
        logic signed [31:0] x;
        begin
            x = sl + sdecay;
            if (x > psd_in + sgain) x = psd_in + sgain;
            upd_slow = x;
        end
    endfunction

    // scratch (combinational temporaries inside the FF; written before read)
    logic signed [31:0] vpsd, vmaskpre, vmask, vfl, vsl;
    logic signed [15:0] vnlc;
    logic        [8:0]  veb;

    always_ff @(posedge clk) begin
        if (rst) begin
            st     <= C_IDLE;
            cur_ch <= 3'd0;
            cpl    <= 1'b0;
            lfe    <= 1'b0;
            kcnt   <= 12'd0;
            done   <= 1'b0;
            bm_we  <= 1'b0;
            pend_we <= 1'b0;
            p2_we  <= 1'b0;
            flush_cnt <= 2'd0;
            copy_primed <= 1'b0;
            ph     <= 1'b0;
        end else begin
            done  <= 1'b0;     // default: 1-cycle pulse

            // bap-write pipeline (drives the bap_mem write port; see decl).
            // M19b: two stages — the cycle after a state stages pend_*, the
            // baptab sync ROM registers baptab_q (bl_addr wire) while pend_*
            // shifts into p2_*; the cycle after that, bm_* commits the write.
            pend_we  <= 1'b0;  // default: 1-cycle pulse
            p2_we     <= pend_we;
            p2_waddr  <= pend_waddr;
            p2_lookup <= pend_lookup;
            p2_lit    <= pend_lit;
            bm_we    <= p2_we;
            bm_waddr <= p2_waddr;
            bm_wdata <= p2_lookup ? baptab_q : p2_lit;

            case (st)
                C_IDLE: if (start) begin
                    cur_ch <= 3'd0;
                    cpl    <= 1'b0;
                    lfe    <= 1'b0;
                    if (zero_snr) begin kcnt <= 12'd0; st <= C_ZERO; end
                    else                 st <= C_CHINIT;
                end

                // liba52 zero_snr_offsets(): force the whole bap[] to 0 (all slots).
                C_ZERO: begin
                    pend_we <= 1'b1; pend_waddr <= kcnt[10:0];
                    pend_lookup <= 1'b0; pend_lit <= 8'sd0;
                    if (kcnt[10:0] == zero_top) begin st <= C_FLUSH; flush_cnt <= 2'd0; end
                    else kcnt <= kcnt + 12'd1;
                end

                // Latch this channel's constants; begin copying its exps/deltba.
                C_CHINIT: begin
                    end_r      <= sel_endmant;
                    fdecay     <= w_fdecay;
                    sdecay     <= w_sdecay;
                    sgain      <= w_sgain;
                    dbknee     <= w_dbknee;
                    fgain      <= w_fgain;
                    snroffset  <= w_snr;     // w_snr/w_fgain use sel_* (lfe-aware)
                    floor_s    <= w_floors;
                    kcnt       <= 12'd0;
                    copy_primed <= 1'b0;
                    st         <= C_COPY;
                end

                // ba_exp_rd / deltba reads are 1-cycle latent (M10K): the data
                // for the address driven at kcnt arrives next cycle, so the RAM
                // write ports (ex_we/db_we — combinational, see the M19 port
                // block) commit expc[kcnt-1]/dbc[kcnt-1] once copy_primed.  The
                // terminal cycle (kcnt==copy_n) still commits the last write
                // (expc[copy_n-1]) at the same edge C_P1 is entered.
                C_COPY: begin
                    copy_primed <= 1'b1;
                    if (kcnt >= {3'd0, copy_n}) begin
                        i       <= 8'd0;
                        lowcomp <= 16'sd0;
                        jcap    <= end_r - 9'd1;
                        st      <= C_P1;
                    end else begin
                        kcnt <= kcnt + 12'd1;
                    end
                end

                // ---- phase 1: do { bin i } while (i<3 || (i<7 && exp rising)) ----
                // (M19: ph0 fetches ex_qa=expc[i], ex_qb=expc[i+1], db_q=dbc[i];
                //  ph1 is the original body with those substitutions.)
                C_P1: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    vnlc = lowcomp;
                    if ({1'b0, i} < jcap) begin
                        if (ex_qb == ex_qa - 5'd2)                 vnlc = 16'sd384;
                        else if (lowcomp != 0 && ex_qb > ex_qa)
                                                                   vnlc = lowcomp - 16'sd64;
                    end
                    vpsd     = 32'sd128 * $signed({27'd0, ex_qa});
                    vmaskpre = vpsd + fgain + $signed(vnlc);
                    vmask    = compute_mask(vpsd, vmaskpre, $signed({16'd0, hth_q}), db_q);
                    pend_we <= 1'b1; pend_waddr <= {cur_slot, i};
                    pend_lookup <= 1'b1; pend_mask <= vmask; pend_e <= ex_qa;

                    lowcomp <= vnlc;
                    psd_r   <= vpsd;
                    i       <= i + 8'd1;
                    if (!(((i + 8'd1) < 8'd3) ||
                          (((i + 8'd1) < 8'd7) && (ex_qb > ex_qa)))) begin
                        fastleak_r <= vpsd + fgain;
                        slowleak_r <= vpsd + sgain;
                        st         <= C_P2;
                    end
                end

                // ---- phase 2: while (i<7) ----
                C_P2: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    if (i >= 8'd7) begin
                        // LFE (end==7): liba52 returns right after phase 2 (no
                        // phase 3/4/5).  LFE is always the last pass -> done.
                        if (lfe) begin st <= C_FLUSH; flush_cnt <= 2'd0; end
                        else st <= C_P3;
                    end else begin
                        vnlc = lowcomp;
                        if ({1'b0, i} < jcap) begin
                            if (ex_qb == ex_qa - 5'd2)             vnlc = 16'sd384;
                            else if (lowcomp != 0 && ex_qb > ex_qa)
                                                                   vnlc = lowcomp - 16'sd64;
                        end
                        vpsd     = 32'sd128 * $signed({27'd0, ex_qa});
                        vfl      = upd_fast(fastleak_r, vpsd);
                        vsl      = upd_slow(slowleak_r, vpsd);
                        vmaskpre = ((vfl + $signed(vnlc)) < vsl) ?
                                   (vfl + $signed(vnlc)) : vsl;
                        vmask    = compute_mask(vpsd, vmaskpre, $signed({16'd0, hth_q}), db_q);
                        pend_we <= 1'b1; pend_waddr <= {cur_slot, i};
                        pend_lookup <= 1'b1; pend_mask <= vmask; pend_e <= ex_qa;

                        fastleak_r <= vfl; slowleak_r <= vsl;
                        lowcomp <= vnlc; psd_r <= vpsd;
                        i <= i + 8'd1;
                    end
                end

                // ---- phase 3: do { bin i } while (i<20), lowcomp seed 320 ----
                C_P3: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    if (i >= 8'd20) st <= C_P4;
                    else begin
                        vnlc = lowcomp;
                        if (ex_qb == ex_qa - 5'd2)                 vnlc = 16'sd320;
                        else if (lowcomp != 0 && ex_qb > ex_qa)
                                                                   vnlc = lowcomp - 16'sd64;
                        vpsd     = 32'sd128 * $signed({27'd0, ex_qa});
                        vfl      = upd_fast(fastleak_r, vpsd);
                        vsl      = upd_slow(slowleak_r, vpsd);
                        vmaskpre = ((vfl + $signed(vnlc)) < vsl) ?
                                   (vfl + $signed(vnlc)) : vsl;
                        vmask    = compute_mask(vpsd, vmaskpre, $signed({16'd0, hth_q}), db_q);
                        pend_we <= 1'b1; pend_waddr <= {cur_slot, i};
                        pend_lookup <= 1'b1; pend_mask <= vmask; pend_e <= ex_qa;

                        fastleak_r <= vfl; slowleak_r <= vsl;
                        lowcomp <= vnlc; psd_r <= vpsd;
                        i <= i + 8'd1;
                    end
                end

                // ---- phase 4: while (lowcomp>128) { lowcomp-=128; bin i } ----
                C_P4: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    if (lowcomp <= 16'sd128) begin
                        j  <= {1'b0, i};
                        st <= C_P5SETUP;
                    end else begin
                        vnlc     = lowcomp - 16'sd128;
                        vpsd     = 32'sd128 * $signed({27'd0, ex_qa});
                        vfl      = upd_fast(fastleak_r, vpsd);
                        vsl      = upd_slow(slowleak_r, vpsd);
                        vmaskpre = ((vfl + $signed(vnlc)) < vsl) ?
                                   (vfl + $signed(vnlc)) : vsl;
                        vmask    = compute_mask(vpsd, vmaskpre, $signed({16'd0, hth_q}), db_q);
                        pend_we <= 1'b1; pend_waddr <= {cur_slot, i};
                        pend_lookup <= 1'b1; pend_mask <= vmask; pend_e <= ex_qa;

                        fastleak_r <= vfl; slowleak_r <= vsl;
                        lowcomp <= vnlc;
                        i <= i + 8'd1;
                    end
                end

                // ---- phase 5: banded loop with log-add PSD integration ----
                // (M19: ex_qb carries expc[j] here / expc[jw] in C_P5WRITE.)
                C_P5SETUP: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    veb = (bndtab[(i - 8'd20)] < end_r) ? bndtab[(i - 8'd20)] : end_r;
                    sb    <= j;
                    eb    <= veb;
                    psd_r <= 32'sd128 * $signed({27'd0, ex_qb});
                    j     <= j + 9'd1;
                    if ((j + 9'd1) < veb) st <= C_P5ACC;
                    else                  st <= C_P5MASK;
                end

                // M19b: three micro-phases — ph0 fetches expc[j] (ex_qb); ph1
                // registers the log-add operands while la_q (latab sync ROM,
                // addressed by the la_addr clamp wire) registers at the same
                // edge; ph2 applies the original switch(delta>>9) update with
                // la_q standing in for latab[vid].  Values identical.
                C_P5ACC: begin
                    if (ph == 2'd0) ph <= 2'd1;
                    else if (ph == 2'd1) begin
                        if (j >= eb) begin st <= C_P5MASK; ph <= 2'd0; end
                        else begin
                            vnext_r  <= la_vnext;
                            vdelta_r <= la_vdelta;
                            ph       <= 2'd2;
                        end
                    end else begin
                        ph <= 2'd0;
                        // switch (delta >> 9): -6..-2 -> next; -1/0 -> log-add;
                        // positive (>=1) -> psd unchanged.  (latab idx in [0,255].)
                        if ((vdelta_r >>> 9) == -32'sd1)
                            psd_r <= vnext_r + la_q;
                        else if ((vdelta_r >>> 9) == 32'sd0)
                            psd_r <= psd_r + la_q;
                        else if ((vdelta_r >>> 9) <= -32'sd2)
                            psd_r <= vnext_r;
                        j <= j + 9'd1;
                    end
                end

                C_P5MASK: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    vfl      = upd_fast(fastleak_r, psd_r);
                    vsl      = upd_slow(slowleak_r, psd_r);
                    vmaskpre = (vfl < vsl) ? vfl : vsl;
                    // coupling channel has no delta-BA in scope (cpl deltbae NEW
                    // fails loud upstream), so its deltba term is 0.
                    mask_r   <= compute_mask(psd_r, vmaskpre,
                                             $signed({16'd0, hth_q}),
                                             cpl ? 4'sd0 : db_q);
                    fastleak_r <= vfl; slowleak_r <= vsl;
                    i  <= i + 8'd1;
                    jw <= sb;
                    st <= C_P5WRITE;
                end

                C_P5WRITE: if (!ph) ph <= 1'b1; else begin
                    ph <= 1'b0;
                    pend_we    <= 1'b1;
                    pend_waddr <= {cur_slot, jw[7:0]};
                    pend_lookup <= 1'b1; pend_mask <= mask_r; pend_e <= ex_qb;
                    if ((jw + 9'd1) >= eb) begin
                        if (eb >= end_r) begin           // channel done
                            if (cpl) begin               // coupling pass done
                                if (lfeon) begin cpl <= 1'b0; lfe <= 1'b1; st <= C_CHINIT; end
                                else begin st <= C_FLUSH; flush_cnt <= 2'd0; end
                            end else if (cur_ch != nfm1) begin
                                cur_ch <= cur_ch + 3'd1; st <= C_CHINIT;   // next fbw
                            end else if (chincpl != 5'd0) begin
                                cpl <= 1'b1; st <= C_CCHINIT;   // coupling pass
                            end else if (lfeon) begin
                                lfe <= 1'b1; st <= C_CHINIT;    // LFE pass
                            end else begin
                                st <= C_FLUSH; flush_cnt <= 2'd0;
                            end
                        end else st <= C_P5SETUP;        // next band (j == eb)
                    end else jw <= jw + 9'd1;
                end

                // bap-write pipeline flush: after the last write is staged into
                // pend_*, wait for it to pass through both pipeline stages
                // (pend->p2 +1 cyc, p2->bm_we +1 cyc — M19b added the baptab
                // sync-ROM stage) and the registered bap_mem write to commit
                // (+1 cyc) before pulsing `done`, so the consumer never reads
                // a stale final bap.  flush_cnt==3 => last write committed.
                C_FLUSH: begin
                    if (flush_cnt == 2'd3) begin done <= 1'b1; st <= C_IDLE; end
                    else flush_cnt <= flush_cnt + 2'd1;
                end

                // ---- coupling-channel bit allocation (M12 Stage B) ----
                // liba52 calls a52_bit_allocate(cplba, cplstrtbnd, cplstrtmant,
                // cplendmant, cplfleak<<8, cplsleak<<8, cpl_expbap): start!=0, so
                // the phase 1-4 lowcomp region is skipped — straight to the banded
                // phase-5 loop with the leaks seeded.
                C_CCHINIT: begin
                    end_r     <= cplendmant;
                    fdecay    <= w_fdecay;
                    sdecay    <= w_sdecay;
                    sgain     <= w_sgain;
                    dbknee    <= w_dbknee;
                    fgain     <= w_fgain_cpl;
                    snroffset <= w_snr_cpl;
                    floor_s   <= w_floors;
                    kcnt      <= {3'd0, cplstrtmant};
                    copy_primed <= 1'b0;
                    st        <= C_CCOPY;
                end

                // Same 1-cycle-latent prefetch as C_COPY (coupling region has no
                // deltba copy): ex_we commits expc[kcnt-1] once copy_primed.
                C_CCOPY: begin
                    copy_primed <= 1'b1;
                    if (kcnt[9:0] >= {1'b0, cplendmant}) begin
                        i          <= {2'd0, cplstrtbnd};
                        j          <= cplstrtmant;
                        fastleak_r <= $signed({20'd0, cplfleak, 8'd0});  // <<8
                        slowleak_r <= $signed({20'd0, cplsleak, 8'd0});
                        st         <= C_P5SETUP;
                    end else begin
                        kcnt <= kcnt + 12'd1;
                    end
                end

                default: st <= C_IDLE;
            endcase
        end
    end

endmodule
