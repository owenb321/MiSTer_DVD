//============================================================================
//  ac3_parse.sv — frame sequencer: syncinfo -> BSI -> 6 audio blocks -> skip.
//
//  Owns the single `bit_reader` request/grant port and time-shares it across
//  the parse + datapath stages, exactly one driving the reader at a time:
//
//    P_SYNC : sync_crc  searches for 0x0B77 and parses syncinfo (header).
//    P_BSI  : bsi_parse walks bsi() and enforces acmod==2 / lfeon==0.
//    P_AUDBLK : audblk_parse walks one audio block's side info.
//    P_MANT : mantissa_dequant pulls that block's mantissa bits (P_EXP/
//             P_BITALLOC between side info and here leave the reader idle, so
//             the stream is positioned exactly at the first mantissa).
//    P_SKIP : an internal skip FSM discards the remainder of the frame body so
//             the next 0x0B77 lands byte-aligned, then re-arms sync_crc.
//
//  Block loop (M10): each AC-3 frame carries 6 audio blocks.  After BSI the
//  sequencer runs the per-block datapath
//      P_AUDBLK -> P_EXP -> P_BITALLOC -> P_MANT -> P_IMDCT -> P_DRAIN
//  six times (blk 0..5), re-arming audblk_parse via `audblk_start` each time.
//  The bit_reader advances continuously through the blocks; the IMDCT delay
//  line carries the overlap across them; exponent/mantissa reuse + the dither
//  LFSR persist across blocks (each stage is already block-loop-ready).  Only
//  after block 5 does P_CALC/P_SKIP discard the rest of the frame (auxbits +
//  CRC2) and resync.
//
//  Metering (M10): P_DRAIN waits for `pcm_done` before starting the next
//  block's IMDCT — the next IMDCT overwrites the shared pcm_mem, so it must not
//  begin until the output stage (pcm_out) has read this block out.  pcm_out
//  stalls its drain on a full CDC FIFO, so this wait paces the whole parser to
//  the ~48 kHz output rate (no more free-running / dropped blocks).  Tie
//  `pcm_done`=1 where there is no output stage (cosim/iverilog TBs read pcm_mem
//  combinationally on imdct_done, before any overwrite).
//
//  The body skip is computed from the *frame length* (sync_bitpos + frame
//  bytes), NOT from where the last block stopped.  That keeps frame boundaries
//  correct even though the blocks consume a variable, bit-granular number of
//  bits — and the skip target stays byte-aligned (sync was found on a byte
//  boundary and the frame length is a whole number of bytes).
//
//  Handshake note: bit_reader's `ack`/`data`/`bitpos` are broadcast to all
//  requesters; each only acts while it has an outstanding request, and the
//  sequencer guarantees only the granted requester ever drives `req`.  Hand-offs
//  happen on idle pulses (frame_hdr_valid / bsi_valid / block_side_valid / skip
//  done), so no request is ever in flight across a grant change.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module ac3_parse (
    input  logic        clk,
    input  logic        rst,

    // bit_reader request/grant (this module is the sole driver of req/nbits)
    output logic        req,
    output logic [5:0]  nbits,
    input  logic        ack,
    input  logic [31:0] data_in,
    input  logic [31:0] bitpos,

    // syncinfo (header) results — from sync_crc
    output logic        synced,
    output logic        frame_hdr_valid,
    output logic [15:0] frame_words,
    output logic [15:0] frame_bytes,
    output logic [1:0]  fscod,
    output logic [5:0]  frmsizcod,
    output logic [15:0] crc1,
    output logic [31:0] sync_bitpos,

    // BSI results — from bsi_parse
    output logic        bsi_valid,
    output logic [4:0]  bsid,
    output logic [2:0]  bsmod,
    output logic [2:0]  acmod,
    output logic [1:0]  dsurmod,
    output logic [1:0]  cmixlev,      // centre mix level   (acmod==7 downmix)
    output logic [1:0]  surmixlev,    // surround mix level  (acmod==7 downmix)
    output logic        lfeon,
    output logic [4:0]  dialnorm,

    // audio-block side-info — from audblk_parse (block 0 of each frame)
    output logic        block_side_valid,
    output logic [31:0] blk_bits,

    // coupling geometry (M12 Stage A) — staged by audblk_parse, surfaced for the
    // co-sim golden check (vs liba52 st->cplstrtmant/cplendmant/ncplbnd/cplco).
    output logic [4:0]  chincpl,
    output logic [8:0]  cplstrtmant,
    output logic [8:0]  cplendmant,
    output logic [4:0]  ncplbnd,
    output logic [5:0]  cplstrtbnd,
    output logic        phsflginu,
    output logic [3:0]  rematflg,
    input  logic [7:0]  cplco_rd_addr,    // {ch[2:0], bnd[4:0]}
    output logic signed [23:0] cplco_rd_data,

    // decoded absolute exponents.  addr {ch[2:0], idx[7:0]}: 0..4 fbw, 5 cpl, 6 lfe.
    output logic        exp_done,         // 1-cycle pulse: exponents decoded
    input  logic [10:0] dexp_rd_addr,
    output logic [4:0]  dexp_rd_data,

    // derived bit-allocation pointers.  addr {ch[2:0], idx[7:0]}.
    output logic        ba_done,          // 1-cycle pulse: bap[] computed
    input  logic [10:0] bap_rd_addr,
    output logic signed [7:0] bap_rd_data,

    // dequantized transform coefficients — from mantissa_dequant.  fbw slots 0..4.
    output logic        mant_done,        // 1-cycle pulse: coeffs dequantized
    input  logic [10:0] coeff_rd_addr,    // {ch[2:0], idx[7:0]}
    output logic signed [23:0] coeff_rd_data,

    // time-domain PCM samples — from imdct_512 (per block).  fbw slots 0..4.
    output logic        imdct_done,       // 1-cycle pulse: IMDCT complete (per block)
    input  logic [10:0] pcm_rd_addr,      // {ch[2:0], idx[7:0]}
    output logic signed [31:0] pcm_rd_data,

    // output-stage metering handshake.  After a block's IMDCT the sequencer
    // waits in P_DRAIN for `pcm_done` before starting the next block — the next
    // IMDCT overwrites the shared pcm_mem, so it must not begin until the output
    // stage has finished reading this block out.  pcm_out stalls its drain on a
    // full CDC FIFO, so this wait paces the whole parser to the ~48 kHz output
    // rate (the real-time frame-metering fix).  Tie `pcm_done`=1 where there is
    // no output stage (the cosim/iverilog TBs read pcm_mem combinationally on
    // `imdct_done`, before any overwrite, so they need no metering).
    input  logic        pcm_done,

    // sticky: any out-of-scope field in syncinfo, BSI, or the audio block
    output logic        err_unsupported
);

    // ---- bit_reader request wires from each requester ----
    logic        req_s,  req_b,  req_a,  req_m, req_k;
    logic [5:0]  nbits_s, nbits_b, nbits_a, nbits_m, nbits_k;

    // ---- sub-module status ----
    logic        err_s, err_b, err_a;

    // nfchans from acmod (== liba52 nfchans_tbl[acmod]).
    wire  [2:0]  nfchans = (acmod == AC3_ACMOD_3_2) ? 3'd5 : 3'd2;

    // ---- audblk_parse staged geometry (packed: ch occupies [ch*W +: W]) ----
    logic [9:0]  chexpstr;     // 2 bits/ch
    logic [34:0] nchgrps;      // 7 bits/ch
    logic [44:0] endmant;      // 9 bits/ch
    logic [4:0]  dithflag;     // 1 bit/ch (consumed by mantissa_dequant)
    logic [4:0]  blksw;        // M16: 1 bit/ch (short block → 256-pt IMDCT)
    logic [7:0]  dynrng;       // M17: per-block DRC gain word (consumed by imdct_512)

    // ---- audblk_parse staged bit-alloc params (consumed by bit_allocation) ----
    logic [1:0]  sdcycod, fdcycod, sgaincod, dbpbcod;
    logic [2:0]  floorcod;
    logic [5:0]  csnroffst;
    logic [19:0] fsnroffst;    // 4 bits/ch
    logic [14:0] fgaincod;     // 3 bits/ch
    logic [9:0]  deltbae;      // 2 bits/ch

    // ---- audblk_parse <-> exponent_decode packed-exp read ports ----
    logic [9:0]  exp_rd_addr;
    logic [7:0]  exp_rd_data;
    logic [6:0]  cpl_exp_rd_addr;
    logic [7:0]  cpl_exp_rd_data;
    logic [1:0]  lfe_exp_rd_addr;
    logic [7:0]  lfe_exp_rd_data;
    // ---- audblk_parse coupling/LFE staging consumed downstream ----
    // (chincpl/cplstrtmant/cplendmant/cplstrtbnd/rematflg are module outputs)
    logic [1:0]  cplexpstr;
    logic [3:0]  cplfleak, cplsleak;
    logic [6:0]  cplba_bai;
    logic [17:0] cplbndstrc;
    logic [7:0]  cplco_rd2_addr;
    logic signed [23:0] cplco_rd2_data;
    logic        lfeexpstr;
    logic [6:0]  lfeba_bai;
    // ---- exponent_decode <-> bit_allocation decoded-exp read port ----
    logic [10:0] ba_exp_rd_addr;
    logic [4:0]  ba_exp_rd_data;
    // ---- audblk_parse <-> bit_allocation delta-ba read port ----
    logic [8:0]  deltba_rd_addr;
    logic signed [3:0] deltba_rd_data;
    // ---- exponent_decode/bit_allocation <-> mantissa_dequant read ports ----
    logic [10:0] mant_exp_rd_addr;
    logic [4:0]  mant_exp_rd_data;
    logic [10:0] mant_bap_rd_addr;
    logic signed [7:0] mant_bap_rd_data;
    // ---- mantissa_dequant <-> imdct_512 coeff read port (2nd coeff_mem port) ----
    logic [10:0] imdct_coeff_rd_addr;
    logic signed [23:0] imdct_coeff_rd_data;

    // ---- sequencer ----
    typedef enum logic [3:0] {
        P_SYNC, P_BSI, P_AUDBLK, P_EXP, P_BITALLOC, P_MANT, P_IMDCT, P_DRAIN,
        P_CALC, P_SKIP, P_HALT
    } pstate_t;
    pstate_t     pstate;

    logic        sync_start;        // re-arm sync_crc for the next frame
    logic [2:0]  blk;               // current audio block (0..5) within the frame
    logic        audblk_start;      // 1-cycle pulse: arm audblk_parse for a block
    logic [31:0] skip_rem;          // body bits still to discard
    logic        skip_await;        // a discard read is in flight
    logic [5:0]  skip_nb;           // size of the in-flight discard read

    // sync_crc: header parser, re-armed each frame by `sync_start`.
    sync_crc u_sync (
        .clk(clk), .rst(rst),
        .start(sync_start),
        .req(req_s), .nbits(nbits_s), .ack(ack),
        .data_in(data_in), .bitpos(bitpos),
        .synced(synced), .frame_hdr_valid(frame_hdr_valid),
        .frame_words(frame_words), .frame_bytes(frame_bytes),
        .fscod(fscod), .frmsizcod(frmsizcod), .crc1(crc1),
        .err_unsupported(err_s), .sync_bitpos(sync_bitpos)
    );

    // bsi_parse: started by the header-valid pulse.
    bsi_parse u_bsi (
        .clk(clk), .rst(rst),
        .start(frame_hdr_valid),
        .req(req_b), .nbits(nbits_b), .ack(ack), .data_in(data_in),
        .bsi_valid(bsi_valid),
        .bsid(bsid), .bsmod(bsmod), .acmod(acmod), .dsurmod(dsurmod),
        .cmixlev(cmixlev), .surmixlev(surmixlev),
        .lfeon(lfeon), .dialnorm(dialnorm),
        .err_unsupported(err_b)
    );

    // audblk_parse: armed once per audio block by `audblk_start` (block 0 on
    // bsi_valid, blocks 1..5 after the previous block drains).  The bit_reader is
    // positioned at the next block's first side-info bit after each P_MANT, so
    // re-arming here simply continues walking the frame.
    audblk_parse u_audblk (
        .clk(clk), .rst(rst),
        .start(audblk_start),
        .first_blk(blk == 3'd0),
        .acmod(acmod), .lfeon(lfeon),
        .req(req_a), .nbits(nbits_a), .ack(ack),
        .data_in(data_in), .bitpos(bitpos),
        .block_side_valid(block_side_valid), .blk_bits(blk_bits),
        // exponent geometry feeds exponent_decode; bit-alloc params feed M6.
        .blksw(blksw), .dithflag(dithflag), .dynrng(dynrng),
        .chexpstr(chexpstr), .endmant(endmant), .nchgrps(nchgrps),
        // coupling geometry + coordinate read port (M12 Stage A)
        .chincpl(chincpl), .cplstrtmant(cplstrtmant), .cplendmant(cplendmant),
        .ncplbnd(ncplbnd), .cplstrtbnd(cplstrtbnd), .cplbndstrc(cplbndstrc),
        .phsflginu(phsflginu), .rematflg(rematflg),
        .cplco_rd_addr(cplco_rd_addr), .cplco_rd_data(cplco_rd_data),
        .cplco_rd2_addr(cplco_rd2_addr), .cplco_rd2_data(cplco_rd2_data),
        // coupling-channel staging for exponent_decode + bit_allocation (Stage B)
        .cplexpstr(cplexpstr), .cplfleak(cplfleak), .cplsleak(cplsleak),
        .cplba_bai(cplba_bai),
        .cpl_exp_rd_addr(cpl_exp_rd_addr), .cpl_exp_rd_data(cpl_exp_rd_data),
        // LFE staging (M14)
        .lfeexpstr(lfeexpstr), .lfeba_bai(lfeba_bai),
        .lfe_exp_rd_addr(lfe_exp_rd_addr), .lfe_exp_rd_data(lfe_exp_rd_data),
        .sdcycod(sdcycod), .fdcycod(fdcycod), .sgaincod(sgaincod),
        .dbpbcod(dbpbcod), .floorcod(floorcod),
        .csnroffst(csnroffst),
        .fsnroffst(fsnroffst), .fgaincod(fgaincod),
        .deltbae(deltbae),
        .deltba_rd_addr(deltba_rd_addr), .deltba_rd_data(deltba_rd_data),
        .exp_rd_addr(exp_rd_addr), .exp_rd_data(exp_rd_data),
        .err_unsupported(err_a)
    );

    // exponent_decode: ungroups audblk_parse's packed exps into absolute
    // exponents.  Started by block_side_valid; the bit_reader is idle (P_EXP).
    exponent_decode u_exp (
        .clk(clk), .rst(rst),
        .start(block_side_valid),
        .nfchans(nfchans), .lfeon(lfeon),
        .chexpstr(chexpstr), .nchgrps(nchgrps),
        .cplexpstr(cplexpstr), .cplstrtmant(cplstrtmant), .cplendmant(cplendmant),
        .lfeexpstr(lfeexpstr),
        .exp_rd_addr(exp_rd_addr), .exp_rd_data(exp_rd_data),
        .cpl_exp_rd_addr(cpl_exp_rd_addr), .cpl_exp_rd_data(cpl_exp_rd_data),
        .lfe_exp_rd_addr(lfe_exp_rd_addr), .lfe_exp_rd_data(lfe_exp_rd_data),
        .dexp_rd_addr(dexp_rd_addr), .dexp_rd_data(dexp_rd_data),
        .ba_exp_rd_addr(ba_exp_rd_addr), .ba_exp_rd_data(ba_exp_rd_data),
        .mant_exp_rd_addr(mant_exp_rd_addr), .mant_exp_rd_data(mant_exp_rd_data),
        .done(exp_done)
    );

    // bit_allocation: exps + bit-alloc params -> bap[].  Started by exp_done;
    // the bit_reader is idle (P_BITALLOC).
    bit_allocation u_balloc (
        .clk(clk), .rst(rst),
        .start(exp_done),
        .nfchans(nfchans), .lfeon(lfeon),
        .endmant(endmant),
        .sdcycod(sdcycod), .fdcycod(fdcycod), .sgaincod(sgaincod),
        .dbpbcod(dbpbcod), .floorcod(floorcod),
        .csnroffst(csnroffst),
        .fsnroffst(fsnroffst), .fgaincod(fgaincod),
        .deltbae(deltbae),
        .lfeba_bai(lfeba_bai),
        .chincpl(chincpl), .cplstrtmant(cplstrtmant), .cplendmant(cplendmant),
        .cplstrtbnd(cplstrtbnd), .cplfleak(cplfleak), .cplsleak(cplsleak),
        .cplba_bai(cplba_bai),
        .ba_exp_rd_addr(ba_exp_rd_addr), .ba_exp_rd_data(ba_exp_rd_data),
        .deltba_rd_addr(deltba_rd_addr), .deltba_rd_data(deltba_rd_data),
        .bap_rd_addr(bap_rd_addr), .bap_rd_data(bap_rd_data),
        .mant_bap_rd_addr(mant_bap_rd_addr), .mant_bap_rd_data(mant_bap_rd_data),
        .done(ba_done)
    );

    // mantissa_dequant: bap[] + exp[] + mantissa bits -> transform coeffs.
    // Started by ba_done; granted the bit_reader during P_MANT (it pulls the
    // block's mantissa bits — the first datapath stage to touch the stream).
    mantissa_dequant u_mant (
        .clk(clk), .rst(rst),
        .start(ba_done),
        .nfchans(nfchans), .lfeon(lfeon),
        .endmant(endmant),
        .dithflag(dithflag),
        // coupling recombine + rematrixing (M12 Stage C/D)
        .chincpl(chincpl), .cplstrtmant(cplstrtmant), .cplendmant(cplendmant),
        .cplbndstrc(cplbndstrc), .rematflg(rematflg),
        .cplco_rd_addr(cplco_rd2_addr), .cplco_rd_data(cplco_rd2_data),
        .req(req_m), .nbits(nbits_m), .ack(ack), .data_in(data_in),
        .mant_exp_rd_addr(mant_exp_rd_addr), .mant_exp_rd_data(mant_exp_rd_data),
        .mant_bap_rd_addr(mant_bap_rd_addr), .mant_bap_rd_data(mant_bap_rd_data),
        .coeff_rd_addr(coeff_rd_addr), .coeff_rd_data(coeff_rd_data),
        .coeff_rd2_addr(imdct_coeff_rd_addr), .coeff_rd2_data(imdct_coeff_rd_data),
        .done(mant_done)
    );

    // imdct_512: transform coeffs -> windowed/overlap-added PCM.  Started by
    // mant_done (P_IMDCT); reads mantissa_dequant.coeff_mem over its 2nd port.
    // Touches no bitstream — the reader stays idle during P_IMDCT.
    imdct_512 u_imdct (
        .clk(clk), .rst(rst),
        .start(mant_done),
        .nfchans(nfchans),
        .blksw(blksw),
        .dynrng(dynrng),
        .cmixlev(cmixlev), .surmixlev(surmixlev),
        .coeff_rd_addr(imdct_coeff_rd_addr), .coeff_rd_data(imdct_coeff_rd_data),
        .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data),
        .done(imdct_done)
    );

    assign err_unsupported = err_s | err_b | err_a;

    // ---- bit_reader grant mux: exactly one requester drives req/nbits ----
    always_comb begin
        unique case (pstate)
            P_SYNC:   begin req = req_s; nbits = nbits_s; end
            P_BSI:    begin req = req_b; nbits = nbits_b; end
            P_AUDBLK: begin req = req_a; nbits = nbits_a; end
            P_MANT:   begin req = req_m; nbits = nbits_m; end
            P_SKIP:   begin req = req_k; nbits = nbits_k; end
            // P_EXP/P_BITALLOC/P_IMDCT/P_DRAIN/P_CALC/P_HALT: bit_reader idle
            default:  begin req = 1'b0; nbits = 6'd0; end
        endcase
    end

    // ---- skip FSM body-discard read (registered) ----
    wire [31:0] skip_target = (sync_bitpos - 32'd16) + ({16'd0, frame_bytes} << 3);

    always_ff @(posedge clk) begin
        if (rst) begin
            pstate       <= P_SYNC;
            sync_start   <= 1'b0;
            blk          <= 3'd0;
            audblk_start <= 1'b0;
            skip_rem     <= 32'd0;
            skip_await   <= 1'b0;
            skip_nb      <= 6'd0;
            req_k        <= 1'b0;
            nbits_k      <= 6'd0;
        end else begin
            sync_start   <= 1'b0;     // 1-cycle pulse
            audblk_start <= 1'b0;     // 1-cycle pulse
            req_k        <= 1'b0;     // 1-cycle pulse

            // An out-of-scope field anywhere -> halt loud (never decode wrong).
            if (err_s | err_b | err_a) begin
                pstate <= P_HALT;
            end else begin
                case (pstate)
                    P_SYNC: if (frame_hdr_valid)   pstate <= P_BSI;

                    // Start the frame at block 0 and arm audblk_parse.
                    P_BSI:  if (bsi_valid) begin
                        blk          <= 3'd0;
                        audblk_start <= 1'b1;
                        pstate       <= P_AUDBLK;
                    end

                    // Per-block datapath: side info -> exps -> bap -> mantissas
                    // -> IMDCT.  Repeated for each of the frame's 6 blocks; the
                    // bit_reader advances continuously through the block side
                    // info + mantissas, and the IMDCT delay line carries the
                    // overlap across blocks.
                    P_AUDBLK: if (block_side_valid) pstate <= P_EXP;

                    P_EXP:      if (exp_done)       pstate <= P_BITALLOC;

                    P_BITALLOC: if (ba_done)        pstate <= P_MANT;

                    // Read + dequantize this block's mantissas (consumes the
                    // mantissa bits from the stream); coeff_mem feeds the IMDCT.
                    P_MANT:     if (mant_done)      pstate <= P_IMDCT;

                    // Transform this block's coeffs to PCM (no bitstream touched).
                    P_IMDCT:    if (imdct_done)     pstate <= P_DRAIN;

                    // Metering: wait for the output stage to finish reading this
                    // block's pcm_mem (pcm_done) before the next block's IMDCT
                    // overwrites it.  Then loop to the next block, or — after
                    // block 5 — skip the rest of the frame body and resync.
                    P_DRAIN: if (pcm_done) begin
                        if (blk == 3'd5) begin
                            pstate <= P_CALC;
                        end else begin
                            blk          <= blk + 3'd1;
                            audblk_start <= 1'b1;
                            pstate       <= P_AUDBLK;
                        end
                    end

                    P_CALC: begin
                        // bitpos has settled past block 5's last mantissa read;
                        // skip the frame tail (auxbits + CRC2) to the next frame.
                        skip_rem   <= skip_target - bitpos;
                        skip_await <= 1'b0;
                        pstate     <= P_SKIP;
                    end

                    P_SKIP: begin
                        if (!skip_await) begin
                            if (skip_rem == 32'd0) begin
                                sync_start <= 1'b1;   // re-arm sync for next frame
                                pstate     <= P_SYNC;
                            end else begin
                                req_k      <= 1'b1;
                                nbits_k    <= (skip_rem >= 32'd24) ? 6'd24 : skip_rem[5:0];
                                skip_nb    <= (skip_rem >= 32'd24) ? 6'd24 : skip_rem[5:0];
                                skip_await <= 1'b1;
                            end
                        end else if (ack) begin
                            skip_rem   <= skip_rem - {26'd0, skip_nb};
                            skip_await <= 1'b0;
                        end
                    end

                    default: ; // P_HALT: stop
                endcase
            end
        end
    end

endmodule
