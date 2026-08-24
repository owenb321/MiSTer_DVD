//============================================================================
//  bit_reader.sv — MSB-first variable-width bit reader over a byte FIFO.
//
//  Part of the MiSTer AC-3 decoder PoC (full-fabric).  This is the front of the
//  control plane: every parser stage pulls fields of arbitrary width (1..MAXW)
//  out of the AC-3 elementary stream through this module.
//
//  Bit order: AC-3 is read MSB-first.  The very first bit of the stream is
//  bit 7 of byte 0, then bit 6, ... bit 0, then bit 7 of byte 1, etc.
//
//  Source FIFO contract: FIRST-WORD-FALL-THROUGH (show-ahead).  `fifo_dout`
//  always presents the current head byte; asserting `fifo_rd` for one cycle
//  pops it so the next byte appears on the following clock.  Quartus SCFIFO with
//  lpm_showahead="ON" provides this; the testbench models it directly.
//
//  Request/grant handshake (single outstanding request):
//    - Pulse `req` for one cycle with `nbits` (1..MAXW), only when idle.
//    - `ack` pulses for one cycle when `data` (right-justified) is valid.
//    - Latency: 2 cycles req->ack when >= nbits bits are already buffered;
//      +1 cycle for each byte that must be fetched.  Stalls (req latched, ack
//      low) while the FIFO is empty.
//
//  `bitpos` is the running total of bits consumed since reset — used by the
//  parsers for frame-size accounting, CRC coverage, and byte alignment
//  (a field is byte-aligned when bitpos[2:0]==0).
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module bit_reader #(
    parameter int MAXW = AC3_MAXW   // max bits per request (<= 32)
) (
    input  logic              clk,
    input  logic              rst,        // synchronous, active-high

    // Byte source — FWFT / show-ahead FIFO
    input  logic [7:0]        fifo_dout,
    input  logic              fifo_empty,
    output logic              fifo_rd,     // 1-cycle pop strobe

    // Consumer request/grant
    input  logic              req,         // pulse to request (only when idle)
    input  logic [5:0]        nbits,       // 1..MAXW
    output logic              ack,         // 1-cycle: data valid this cycle
    output logic [MAXW-1:0]   data,        // right-justified, zero-extended
    output logic [31:0]       bitpos       // total bits consumed since reset
);

    // Bit accumulator, LEFT-justified: acc[ACC_W-1] is the next bit out.
    // Must hold up to (MAXW-1) leftover bits plus a freshly appended byte, so
    // 64 bits is comfortable for MAXW<=32 (worst case need<=32, cnt can reach
    // need+7 = 39 < 64).
    localparam int ACC_W = 64;

    logic [ACC_W-1:0] acc;     // valid bits are the top `cnt`, MSB-first
    logic [6:0]       cnt;     // number of valid bits in acc (0..ACC_W)
    logic [6:0]       need;    // bits requested; 0 == idle

    // Combinational control:
    //  - emit when we have enough bits buffered for the pending request
    //  - otherwise fetch a byte if one is available
    wire have_enough = (need != 7'd0) && (cnt >= need);
    wire want_byte   = (need != 7'd0) && (cnt <  need) && !fifo_empty;

    assign fifo_rd = want_byte;

    // Place a new byte immediately after the existing `cnt` valid bits.
    // Existing bits occupy acc[ACC_W-1 -: cnt]; the byte goes at
    // acc[ACC_W-1-cnt -: 8], i.e. shifted left by (ACC_W-8-cnt).
    wire [ACC_W-1:0] byte_placed = {{(ACC_W-8){1'b0}}, fifo_dout} << (ACC_W - 8 - cnt);

    always_ff @(posedge clk) begin
        if (rst) begin
            acc    <= '0;
            cnt    <= '0;
            need   <= '0;
            ack    <= 1'b0;
            data   <= '0;
            bitpos <= '0;
        end else begin
            ack <= 1'b0;                    // default; pulsed on emit

            if (need == 7'd0) begin
                // Idle: latch a new request.  (1..MAXW; 0 is treated as idle.)
                if (req && (nbits != 6'd0))
                    need <= {1'b0, nbits};
            end else if (have_enough) begin
                // Emit top `need` bits, right-justified, then pop them.
                data   <= MAXW'(acc >> (ACC_W - need));
                acc    <= acc << need;      // shifts zeros into the low bits
                cnt    <= cnt - need;
                bitpos <= bitpos + {25'd0, need};
                need   <= 7'd0;
                ack    <= 1'b1;
            end else if (want_byte) begin
                // Append one byte (FIFO pops this cycle via fifo_rd).
                acc <= acc | byte_placed;
                cnt <= cnt + 7'd8;
            end
            // else: stall (FIFO empty) — hold state, ack stays low.
        end
    end

`ifdef AC3_ASSERT
    // No new request while a request is in flight.
    always_ff @(posedge clk)
        if (!rst && (need != 0) && req)
            $error("bit_reader: req asserted while busy (need=%0d)", need);
    always_ff @(posedge clk)
        if (!rst && req && (nbits > MAXW[5:0]))
            $error("bit_reader: nbits=%0d exceeds MAXW=%0d", nbits, MAXW);
`endif

endmodule
