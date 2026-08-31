//============================================================================
//  bsi_parse.sv — AC-3 Bit Stream Information (BSI) parser.
//
//  Runs immediately after `sync_crc` has read syncinfo (sync word, crc1,
//  fscod, frmsizcod).  Drives `bit_reader` (req/grant) to walk the bsi()
//  syntax of A/52 §5.3, latches the fields this decoder needs, and enforces the
//  scope guards (acmod in {2, 7}).  On success it pulses `bsi_valid`; on an
//  out-of-scope field it sets sticky `err_unsupported` and halts in B_ERR.
//
//  A/52 bsi() syntax.  Both in-scope acmods (2 = 2/0 L/R, 7 = 3/2 = 5.1 with
//  lfeon) are decoded in full; other acmod values fail loud before their
//  conditionals matter.  The cmixlev/surmixlev/dsurmod block is variable-width
//  (lfeon is always its last bit):
//
//    bsid          5
//    bsmod         3
//    acmod         3      -- must be 2 or 7; else err_unsupported
//      (acmod&1 && acmod!=1) cmixlev 2   -- present for acmod==7 (centre mix lvl)
//      (acmod&4)            surmixlev 2  -- present for acmod==7 (surround mix lvl)
//      (acmod==2)           dsurmod  2   -- present for acmod==2 only
//    lfeon         1      -- 0 or 1 (LFE present); both in scope
//    dialnorm      5
//    compre        1 ; if compre  compr   8
//    langcode      1 ; if langcode langcod 8
//    audprodie     1 ; if audprodie { mixlevel 5; roomtyp 2 }
//    (acmod==0 dual-mono block)          -- N/A for acmod==2
//    copyrightb    1
//    origbs        1
//    timecod1e     1 ; if timecod1e timecod1 14
//    timecod2e     1 ; if timecod2e timecod2 14
//    addbsie       1 ; if addbsie { addbsil 6; addbsi (addbsil+1)*8 }
//
//  Only bsid/bsmod/acmod/dsurmod/lfeon/dialnorm are latched; everything else is
//  parsed (to advance the bit position correctly) and discarded.  The body
//  skip/resync that follows BSI lives in `ac3_parse`, computed from the frame
//  length, so BSI never needs to land on a particular bit — but it must not
//  over-read past the frame, hence every conditional is honoured exactly.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module bsi_parse (
    input  logic        clk,
    input  logic        rst,

    // begin parsing (pulse, e.g. on sync_crc's frame_hdr_valid)
    input  logic        start,

    // bit_reader request/grant interface
    output logic        req,
    output logic [5:0]  nbits,
    input  logic        ack,
    input  logic [31:0] data_in,      // right-justified field from bit_reader

    // results (registered, held until the next frame)
    output logic        bsi_valid,    // 1-cycle pulse: BSI parsed OK
    output logic [4:0]  bsid,
    output logic [2:0]  bsmod,
    output logic [2:0]  acmod,
    output logic [1:0]  dsurmod,
    output logic [1:0]  cmixlev,      // centre mix level  (acmod==7); else 0
    output logic [1:0]  surmixlev,    // surround mix level (acmod==7); else 0
    output logic        lfeon,
    output logic [4:0]  dialnorm,
    output logic        err_unsupported
);

    // ---- A/52 bsi() field-presence rules (DVD-FORK 2026-08-31) --------------
    // cmixlev present iff (acmod & 1) && acmod != 1   -> acmod 3, 5, 7
    // surmixlev present iff (acmod & 4)               -> acmod 4, 5, 6, 7
    function automatic logic acmod_has_cmix(input logic [2:0] a);
        acmod_has_cmix = a[0] && (a != 3'd1);
    endfunction
    function automatic logic acmod_has_smix(input logic [2:0] a);
        acmod_has_smix = a[2];
    endfunction
    function automatic logic [5:0] mixlfe_bits(input logic [2:0] a);
        mixlfe_bits = (acmod_has_cmix(a) && acmod_has_smix(a)) ? 6'd5 :
                      (acmod_has_cmix(a) || acmod_has_smix(a) || a == 3'd2) ? 6'd3 : 6'd1;
    endfunction

    typedef enum logic [4:0] {
        B_IDLE,
        B_BSID,     // bsid(5)+bsmod(3)
        B_ACMOD,    // acmod(3)
        B_MIXLFE,   // [cmixlev(2)][surmixlev(2)]/[dsurmod(2)] + lfeon(1)
        B_DIAL,     // dialnorm(5)+compre(1)
        B_COMPR,    // compr(8)
        B_LANGE,    // langcode(1)
        B_LANGV,    // langcod(8)
        B_APRODE,   // audprodie(1)
        B_APRODV,   // mixlevel(5)+roomtyp(2)
        B_MISC,     // copyrightb(1)+origbs(1)+timecod1e(1)
        B_TC1,      // timecod1(14)
        B_TC2E,     // timecod2e(1)
        B_TC2,      // timecod2(14)
        B_ADDE,     // addbsie(1)
        B_ADDL,     // addbsil(6)
        B_ADDV,     // skip (addbsil+1)*8 bits, chunked
        B_DONE,
        B_ERR
    } state_t;

    state_t      st;
    logic        awaiting;          // a get_bits request is in flight
    logic [9:0]  addbits;           // remaining addbsi bits to discard

    // addbsi discard chunk (<= MAXW so a single bit_reader read covers it).
    localparam logic [5:0] CHUNK = 6'd24;

    always_ff @(posedge clk) begin
        if (rst) begin
            st              <= B_IDLE;
            awaiting        <= 1'b0;
            req             <= 1'b0;
            nbits           <= 6'd0;
            addbits         <= 10'd0;
            bsi_valid       <= 1'b0;
            bsid            <= 5'd0;
            bsmod           <= 3'd0;
            acmod           <= 3'd0;
            dsurmod         <= 2'd0;
            cmixlev         <= 2'd0;
            surmixlev       <= 2'd0;
            lfeon           <= 1'b0;
            dialnorm        <= 5'd0;
            err_unsupported <= 1'b0;
        end else begin
            req       <= 1'b0;     // default: req is a 1-cycle pulse
            bsi_valid <= 1'b0;     // default: 1-cycle pulse

            if ((st == B_IDLE || st == B_DONE) && start) begin
                // (Re)arm for a new frame's BSI.
                st       <= B_BSID;
                awaiting <= 1'b0;
            end else if (!awaiting) begin
                // Issue the read for the current field.
                case (st)
                    B_BSID:  begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    B_ACMOD: begin req <= 1'b1; nbits <= 6'd3;  awaiting <= 1'b1; end
                    // A/52 bsi(): cmixlev if (acmod&1 && acmod!=1); surmixlev if
                    // (acmod&4); dsurmod if (acmod==2); then lfeon, ALWAYS last.
                    //   acmod 1 (1/0)        : lfeon only                       = 1
                    //   acmod 2 (2/0)        : dsurmod(2)+lfeon(1)              = 3
                    //   acmod 3 (3/0)        : cmixlev(2)+lfeon(1)              = 3
                    //   acmod 4 (2/1), 6(2/2): surmixlev(2)+lfeon(1)            = 3
                    //   acmod 5 (3/1), 7(3/2): cmixlev(2)+surmixlev(2)+lfeon(1) = 5
                    B_MIXLFE:begin req <= 1'b1;
                             nbits <= mixlfe_bits(acmod);
                             awaiting <= 1'b1; end
                    B_DIAL:  begin req <= 1'b1; nbits <= 6'd6;  awaiting <= 1'b1; end
                    B_COMPR: begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    B_LANGE: begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    B_LANGV: begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    B_APRODE:begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    B_APRODV:begin req <= 1'b1; nbits <= 6'd7;  awaiting <= 1'b1; end
                    B_MISC:  begin req <= 1'b1; nbits <= 6'd3;  awaiting <= 1'b1; end
                    B_TC1:   begin req <= 1'b1; nbits <= 6'd14; awaiting <= 1'b1; end
                    B_TC2E:  begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    B_TC2:   begin req <= 1'b1; nbits <= 6'd14; awaiting <= 1'b1; end
                    B_ADDE:  begin req <= 1'b1; nbits <= 6'd1;  awaiting <= 1'b1; end
                    B_ADDL:  begin req <= 1'b1; nbits <= 6'd6;  awaiting <= 1'b1; end
                    B_ADDV: begin
                        if (addbits == 10'd0) begin
                            st        <= B_DONE;
                            bsi_valid <= 1'b1;
                        end else begin
                            req      <= 1'b1;
                            nbits    <= (addbits >= {4'd0, CHUNK}) ? CHUNK : addbits[5:0];
                            awaiting <= 1'b1;
                        end
                    end
                    default: ; // B_DONE/B_ERR/B_IDLE: idle, no requests
                endcase
            end else if (ack) begin
                awaiting <= 1'b0;
                case (st)
                    B_BSID: begin
                        bsid  <= data_in[7:3];
                        bsmod <= data_in[2:0];
                        st    <= B_ACMOD;
                    end
                    B_ACMOD: begin
                        acmod <= data_in[2:0];
                        // DVD-FORK 2026-08-31: acmod 1..7 are ALL decoded now.
                        // Anything rejected here sets sticky err_unsupported ->
                        // ac3_err -> an ac3_front self-heal reset EVERY frame =
                        // total SILENCE, not a glitch. That is how mono (acmod 1)
                        // and the 2/2 quad case (acmod 6) reached users as "no
                        // audio". Only acmod 0 (1+1 dual mono) is still out: it
                        // carries a SECOND dialnorm/compr/langcod/audprodi block
                        // in bsi that this FSM does not walk, so accepting it
                        // would desync bsi and produce garbage instead of silence
                        // — a strictly worse failure. It is also absent from the
                        // measured library (see docs/ac3_decoder.md).
                        if (data_in[2:0] == 3'd0) begin
                            err_unsupported <= 1'b1;
                            st              <= B_ERR;
                        end else begin
                            st <= B_MIXLFE;
                        end
                    end
                    B_MIXLFE: begin
                        // lfeon is the LSB regardless of width (both in scope).
                        lfeon <= data_in[0];
                        // Field order is fixed (cmixlev, surmixlev, dsurmod,
                        // lfeon); only PRESENCE varies, so each present field
                        // sits just above lfeon in the order they appear.
                        cmixlev   <= 2'd0;
                        surmixlev <= 2'd0;
                        dsurmod   <= 2'd0;
                        if (acmod_has_cmix(acmod) && acmod_has_smix(acmod)) begin
                            // 5 bits: cmixlev[4:3] surmixlev[2:1] lfeon[0]
                            cmixlev   <= data_in[4:3];
                            surmixlev <= data_in[2:1];
                        end else if (acmod_has_cmix(acmod)) begin
                            cmixlev   <= data_in[2:1];   // 3 bits (acmod 3)
                        end else if (acmod_has_smix(acmod)) begin
                            surmixlev <= data_in[2:1];   // 3 bits (acmod 4, 6)
                        end else if (acmod == AC3_ACMOD_LR) begin
                            dsurmod   <= data_in[2:1];   // 3 bits (acmod 2)
                        end
                        // acmod 1: 1 bit, lfeon only - all three stay 0.
                        st <= B_DIAL;
                    end
                    B_DIAL: begin
                        dialnorm <= data_in[5:1];
                        st       <= state_t'(data_in[0] ? B_COMPR : B_LANGE);  // compre
                    end
                    B_COMPR: st <= B_LANGE;                                      // compr disc.
                    B_LANGE: st <= state_t'(data_in[0] ? B_LANGV  : B_APRODE);  // langcode
                    B_LANGV: st <= B_APRODE;                                     // langcod disc.
                    B_APRODE:st <= state_t'(data_in[0] ? B_APRODV : B_MISC);    // audprodie
                    B_APRODV:st <= B_MISC;                                       // mixlevel/room
                    B_MISC:  st <= state_t'(data_in[0] ? B_TC1    : B_TC2E);    // timecod1e
                    B_TC1:   st <= B_TC2E;                                       // timecod1 disc.
                    B_TC2E:  st <= state_t'(data_in[0] ? B_TC2    : B_ADDE);    // timecod2e
                    B_TC2:   st <= B_ADDE;                           // timecod2 discarded
                    B_ADDE: begin
                        if (data_in[0]) st <= B_ADDL;                // addbsie set
                        else begin
                            st        <= B_DONE;
                            bsi_valid <= 1'b1;
                        end
                    end
                    B_ADDL: begin
                        // addbsi length = (addbsil+1) bytes -> bits.
                        addbits <= ({4'd0, data_in[5:0]} + 10'd1) << 3;
                        st      <= B_ADDV;
                    end
                    B_ADDV: begin
                        addbits <= addbits - {4'd0, nbits};  // issue-side ends at 0
                    end
                    default: ;
                endcase
            end
        end
    end

`ifdef AC3_ASSERT
    // BSI must never over-read past a frame: a real over-read would desync the
    // sequencer's body-skip accounting.  We can't see the frame end here, but a
    // stuck/looping FSM is caught by the chain TB timeout.
`endif

endmodule
