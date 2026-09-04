// ============================================================================
// dvd/secs_bcd.sv -- one seconds->BCD converter, shared by every clock in the
// transport layer
// ============================================================================
// dvd/lin_rate.sv and dvd/seek_time.sv both produce times, and both used to
// carry their own copy of this conversion. Measured, that copy is 166 ALUTs and
// 56 registers -- paying for it twice bought nothing, because only one clock is
// ever displayed at a time and none of them changes faster than once a second.
//
// ★ NO HANDSHAKE, BY DESIGN. A request/grant arbiter between two producers is
// more logic and more states than the thing it arbitrates. Instead this walks
// its four inputs round-robin and re-converts each unconditionally: a job is
// ~30 cycles, so all four refresh in ~4.4 us at 27 MHz. The fastest consumer
// (transport_hud's formatter) reloads every ~1.2 ms, and the fastest producer
// (a scrub cursor) moves every ~60 ms, so the result is always fresher than
// anything that reads it and there is nothing to synchronise.
//
// ★ THE VALID FLAGS STAY WITH THE PRODUCERS. This module converts whatever it
// is given, including nonsense from a source that has not armed yet; emu shows
// a clock only when that source's own ok flag is set. Keeping validity out of
// here is what lets the conversion be unconditional and stateless between jobs.
//
// Digits come out by repeated subtraction rather than a divide: it yields the
// BCD nibbles directly, so there is no separate binary-to-BCD pass, and the
// loop is bounded at 9 + 5 + 9 + 5 iterations by the 9:59:59 clamp.
// ============================================================================
`default_nettype none

module secs_bcd #(
    parameter [16:0] SEC_CAP = 17'd35_999      // 9:59:59, the widest readout
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [16:0] secs0,
    input  wire [16:0] secs1,
    input  wire [16:0] secs2,
    input  wire [16:0] secs3,
    output reg  [31:0] bcd0,                   // packed {hh, mm, ss, 8'h00}
    output reg  [31:0] bcd1,
    output reg  [31:0] bcd2,
    output reg  [31:0] bcd3
);
    reg  [1:0]  job;
    reg  [2:0]  st;
    reg  [16:0] t;
    reg  [3:0]  d_h, d_mt, d_mo, d_st;

    wire [16:0] sel  = (job == 2'd0) ? secs0 :
                       (job == 2'd1) ? secs1 :
                       (job == 2'd2) ? secs2 : secs3;
    wire [16:0] cap  = (sel > SEC_CAP) ? SEC_CAP : sel;
    wire [31:0] pack = {4'd0, d_h, d_mt, d_mo, d_st, t[3:0], 8'h00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            job <= 2'd0; st <= 3'd0; t <= 17'd0;
            d_h <= 4'd0; d_mt <= 4'd0; d_mo <= 4'd0; d_st <= 4'd0;
            bcd0 <= 32'd0; bcd1 <= 32'd0; bcd2 <= 32'd0; bcd3 <= 32'd0;
        end else begin
            case (st)
                3'd0: begin                              // load + clamp
                    t    <= cap;
                    d_h  <= 4'd0; d_mt <= 4'd0; d_mo <= 4'd0; d_st <= 4'd0;
                    st   <= 3'd1;
                end
                3'd1: if (t >= 17'd3600) begin t <= t - 17'd3600; d_h  <= d_h  + 4'd1; end
                      else st <= 3'd2;
                3'd2: if (t >= 17'd600)  begin t <= t - 17'd600;  d_mt <= d_mt + 4'd1; end
                      else st <= 3'd3;
                3'd3: if (t >= 17'd60)   begin t <= t - 17'd60;   d_mo <= d_mo + 4'd1; end
                      else st <= 3'd4;
                3'd4: if (t >= 17'd10)   begin t <= t - 17'd10;   d_st <= d_st + 4'd1; end
                      else st <= 3'd5;
                default: begin                           // publish + advance
                    case (job)
                        2'd0: bcd0 <= pack;
                        2'd1: bcd1 <= pack;
                        2'd2: bcd2 <= pack;
                        default: bcd3 <= pack;
                    endcase
                    job <= job + 2'd1;
                    st  <= 3'd0;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
