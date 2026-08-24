//============================================================================
//  sync_crc.sv — AC-3 frame synchronization + header (syncinfo) parse.
//
//  Drives `bit_reader` (req/grant) to:
//    1. find the 0x0B77 sync word (MSB-first rolling byte search),
//    2. read CRC1 (16 bits),
//    3. read fscod (2 bits) + frmsizcod (6 bits),
//    4. derive the frame length in 16-bit words from the A/52 frame-size table
//       (48 kHz column only — this PoC supports fscod==0),
//    5. pulse `frame_hdr_valid` and stop (S_DONE), handing the bit_reader to
//       the BSI parser.  The `ac3_parse` sequencer later skips the frame body
//       and re-arms this module via `start` to resync on the next frame.
//
//  Scope guards: fscod != 0 (non-48 kHz) or frmsizcod > 37 (invalid) sets a
//  sticky `err_unsupported` and halts — never decodes out of scope.
//
//  As of M3 the body-skip/resync lives in `ac3_parse` (so BSI can run between
//  the header and the skip).  This module owns the bit_reader only while it is
//  searching/parsing a header; in S_DONE it issues no requests and `start`
//  re-arms a fresh sync search.
//
//  CRC1 is captured but NOT verified in this PoC (optional per roadmap).
//  TODO(crc): compute the AC-3 CRC16 over the first 5/8 of the frame and drive
//  a crc_ok flag (non-gating).
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module sync_crc (
    input  logic        clk,
    input  logic        rst,

    // re-arm: pulse to begin a fresh sync search for the next frame (only
    // meaningful in S_DONE; ignored while a header is being parsed).
    input  logic        start,

    // bit_reader request/grant interface
    output logic        req,
    output logic [5:0]  nbits,
    input  logic        ack,
    input  logic [31:0] data_in,      // right-justified field from bit_reader
    input  logic [31:0] bitpos,

    // results (registered, held until next frame)
    output logic        synced,           // high once a header has been parsed
    output logic        frame_hdr_valid,  // 1-cycle pulse per parsed header
    output logic [15:0] frame_words,      // frame length, 16-bit words
    output logic [15:0] frame_bytes,      // = frame_words << 1
    output logic [1:0]  fscod,
    output logic [5:0]  frmsizcod,
    output logic [15:0] crc1,
    output logic        err_unsupported,
    output logic [31:0] sync_bitpos       // bitpos just past the sync word
);

    // A/52 frame-size table, 48 kHz column: frmsizcod -> 16-bit words/syncframe.
    // (For 48 kHz, words = 2 * nominal_bitrate_kbps; the even/odd frmsizcod pair
    //  shares a value because no padding word is needed at 48 kHz.)
    function automatic logic [15:0] fsz48 (input logic [5:0] c);
        case (c)
            6'd0,  6'd1:  fsz48 = 16'd64;
            6'd2,  6'd3:  fsz48 = 16'd80;
            6'd4,  6'd5:  fsz48 = 16'd96;
            6'd6,  6'd7:  fsz48 = 16'd112;
            6'd8,  6'd9:  fsz48 = 16'd128;
            6'd10, 6'd11: fsz48 = 16'd160;
            6'd12, 6'd13: fsz48 = 16'd192;
            6'd14, 6'd15: fsz48 = 16'd224;
            6'd16, 6'd17: fsz48 = 16'd256;
            6'd18, 6'd19: fsz48 = 16'd320;
            6'd20, 6'd21: fsz48 = 16'd384;
            6'd22, 6'd23: fsz48 = 16'd448;
            6'd24, 6'd25: fsz48 = 16'd512;
            6'd26, 6'd27: fsz48 = 16'd640;
            6'd28, 6'd29: fsz48 = 16'd768;
            6'd30, 6'd31: fsz48 = 16'd896;
            6'd32, 6'd33: fsz48 = 16'd1024;
            6'd34, 6'd35: fsz48 = 16'd1152;
            6'd36, 6'd37: fsz48 = 16'd1280;
            default:      fsz48 = 16'd0;     // invalid frmsizcod
        endcase
    endfunction

    typedef enum logic [2:0] {
        S_SYNC, S_CRC1, S_HDR, S_DONE, S_ERR
    } state_t;

    state_t      st;
    logic        awaiting;      // a get_bits request is in flight
    logic [7:0]  last_byte;     // previous byte, for the rolling sync search

    wire [15:0] words_next = fsz48(data_in[5:0]);

    always_ff @(posedge clk) begin
        if (rst) begin
            st              <= S_SYNC;
            awaiting        <= 1'b0;
            req             <= 1'b0;
            nbits           <= 6'd0;
            last_byte       <= 8'd0;
            synced          <= 1'b0;
            frame_hdr_valid <= 1'b0;
            frame_words     <= 16'd0;
            frame_bytes     <= 16'd0;
            fscod           <= 2'd0;
            frmsizcod       <= 6'd0;
            crc1            <= 16'd0;
            err_unsupported <= 1'b0;
            sync_bitpos     <= 32'd0;
        end else begin
            req             <= 1'b0;       // default: req is a 1-cycle pulse
            frame_hdr_valid <= 1'b0;       // default: 1-cycle pulse

            // S_DONE: idle, owning no bit_reader request.  A `start` pulse from
            // the sequencer re-arms a fresh sync search for the next frame.
            if ((st == S_DONE) && start) begin
                st        <= S_SYNC;
                awaiting  <= 1'b0;
                last_byte <= 8'd0;
            end else if (!awaiting) begin
                // Issue the request appropriate to the current state.
                case (st)
                    S_SYNC: begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    S_CRC1: begin req <= 1'b1; nbits <= 6'd16; awaiting <= 1'b1; end
                    S_HDR:  begin req <= 1'b1; nbits <= 6'd8;  awaiting <= 1'b1; end
                    default: ; // S_DONE / S_ERR: issue nothing
                endcase
            end else if (ack) begin
                awaiting <= 1'b0;
                case (st)
                    S_SYNC: begin
                        last_byte <= data_in[7:0];
                        if ({last_byte, data_in[7:0]} == AC3_SYNCWORD) begin
                            sync_bitpos <= bitpos;     // just past 2nd sync byte
                            st          <= S_CRC1;
                        end
                    end
                    S_CRC1: begin
                        crc1 <= data_in[15:0];
                        st   <= S_HDR;
                    end
                    S_HDR: begin
                        fscod     <= data_in[7:6];
                        frmsizcod <= data_in[5:0];
                        if ((data_in[7:6] != AC3_FSCOD_48K) || (words_next == 16'd0)) begin
                            err_unsupported <= 1'b1;
                            st              <= S_ERR;
                        end else begin
                            frame_words     <= words_next;
                            frame_bytes     <= {words_next[14:0], 1'b0}; // *2
                            synced          <= 1'b1;
                            frame_hdr_valid <= 1'b1;
                            // Header done: hand the bit_reader to bsi_parse.
                            st              <= S_DONE;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
