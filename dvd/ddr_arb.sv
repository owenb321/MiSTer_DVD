// ddr_arb.sv — two-master priority arbiter on the DDRAM (f2sdram ram1) port
// Part of MiSTer DVD Player Core
//
// Lets the audio DDR writer share the decoder's DDRAM command channel. The
// MPEG-2 decoder (dvd/mem_shim_burst.sv) is the PRIORITY master; the audio
// writer (dvd/audio_ddr_issue.sv) is a write-only secondary master that only
// gets the bus when the decoder is at a safe idle point. See docs/audio_ddr_path.md.
//
// ---------------------------------------------------------------------------
// CORRECTNESS RULES
//  * Single command channel: exactly one master drives addr/burst/rd/wr/din/be
//    at a time. The non-granted master is held off with waitrequest = 1.
//  * NEVER switch masters mid write-burst. A decoder write burst of N beats must
//    deliver all N writedata beats before any other command (even if the decoder
//    GAPS the burst by dropping `write` between beats). `dec_wburst` counts the
//    remaining beats and pins the grant to the decoder until the burst finishes.
//  * Audio is write-only and uses burstcount 1, so it occupies the bus for a
//    single accepted beat.
//  * Read RESPONSES (readdata/readdatavalid) are NOT gated by grant — they always
//    route to the decoder (the audio master never reads). A decoder read issued
//    earlier can return its data while audio holds the command channel.
//  * Decoder priority + no starvation: audio is only granted on a decoder-idle
//    cycle (no rd/wr asserted, not mid-burst). The decoder cannot reserve the bus
//    while idle, so any idle cycle lets audio take one turn; the decoder's next
//    command then waits at most until audio's single beat is accepted. Both
//    masters already tolerate waitrequest (it is the native DDR backpressure).
//
// Sim-verified by bench/dvd/ddr_arb_tb.sv (incl. a GAPPED decoder write burst
// with audio pending — proves no mid-burst interleave).

`default_nettype none

module ddr_arb (
    input  wire        clk,
    input  wire        rst_n,

    // ---- Master 0: decoder (priority) — full read/write Avalon-MM ----
    input  wire [28:0] dec_address,
    input  wire  [7:0] dec_burstcount,
    input  wire        dec_read,
    input  wire        dec_write,
    input  wire [63:0] dec_writedata,
    input  wire  [7:0] dec_byteenable,
    output wire        dec_waitrequest,
    output wire [63:0] dec_readdata,
    output wire        dec_readdatavalid,

    // ---- Master 1: audio writer (write-only, burstcount 1) ----
    input  wire [28:0] aud_address,
    input  wire  [7:0] aud_burstcount,
    input  wire        aud_write,
    input  wire [63:0] aud_writedata,
    input  wire  [7:0] aud_byteenable,
    output wire        aud_waitrequest,

    // ---- Slave side: the real DDRAM port ----
    output wire [28:0] ddr_address,
    output wire  [7:0] ddr_burstcount,
    output wire        ddr_read,
    output wire        ddr_write,
    output wire [63:0] ddr_writedata,
    output wire  [7:0] ddr_byteenable,
    input  wire        ddr_waitrequest,
    input  wire [63:0] ddr_readdata,
    input  wire        ddr_readdatavalid
);

    localparam GRANT_DEC = 1'b0;
    localparam GRANT_AUD = 1'b1;

    reg       grant;
    reg [7:0] dec_wburst;   // remaining beats of an in-progress decoder write burst

    wire dec_beat_acc = (grant == GRANT_DEC) && dec_write && !ddr_waitrequest;
    wire aud_beat_acc = (grant == GRANT_AUD) && aud_write && !ddr_waitrequest;

    // can hand the bus to audio only at a decoder-idle, non-mid-burst point
    wire dec_idle = (dec_wburst == 8'd0) && !dec_read && !dec_write;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant      <= GRANT_DEC;
            dec_wburst <= 8'd0;
        end else begin
            case (grant)
                GRANT_DEC: begin
                    if (dec_beat_acc) begin
                        if (dec_wburst == 8'd0)
                            dec_wburst <= dec_burstcount - 8'd1; // first beat consumed
                        else
                            dec_wburst <= dec_wburst - 8'd1;
                    end
                    // switch to audio only when the decoder is truly idle
                    if (dec_idle && aud_write)
                        grant <= GRANT_AUD;
                end

                GRANT_AUD: begin
                    // single accepted beat (burstcount 1) hands the bus back
                    if (aud_beat_acc || !aud_write)
                        grant <= GRANT_DEC;
                end
            endcase
        end
    end

    // ---- command-channel mux ----
    assign ddr_address    = (grant == GRANT_AUD) ? aud_address    : dec_address;
    assign ddr_burstcount = (grant == GRANT_AUD) ? aud_burstcount : dec_burstcount;
    assign ddr_writedata  = (grant == GRANT_AUD) ? aud_writedata  : dec_writedata;
    assign ddr_byteenable = (grant == GRANT_AUD) ? aud_byteenable : dec_byteenable;
    assign ddr_write      = (grant == GRANT_AUD) ? aud_write      : dec_write;
    assign ddr_read       = (grant == GRANT_AUD) ? 1'b0           : dec_read;

    // ---- backpressure: only the granted master sees the real waitrequest ----
    assign dec_waitrequest = (grant == GRANT_DEC) ? ddr_waitrequest : 1'b1;
    assign aud_waitrequest = (grant == GRANT_AUD) ? ddr_waitrequest : 1'b1;

    // ---- read responses always belong to the decoder ----
    assign dec_readdata      = ddr_readdata;
    assign dec_readdatavalid = ddr_readdatavalid;

endmodule

`default_nettype wire
