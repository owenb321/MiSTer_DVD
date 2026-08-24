// =============================================================================
// dvd/vidfeed_cdc.sv — elementary-stream byte CDC: ps_demux (clk_sys 27 MHz) ->
// mpeg2video decoder (clk_dec 54 MHz).
// =============================================================================
// Raising the decoder compute clock above the feed clock means the video ES byte
// stream must cross clock domains. A dual-clock fifo_dc carries the byte; the read
// side converts the FIFO's PULL interface (assert rd_en -> data + valid the NEXT
// cycle) into the HELD valid/consume handshake the decoder wants
// (stream_valid = "byte taken this cycle").
//
// CORRECTNESS (this is the whole point of the module): the read adapter keeps AT
// MOST ONE outstanding pop and NEVER overwrites an unconsumed head byte. A naive
// "pop whenever the head looks free" adapter drops a byte if rd_ready (~core_busy)
// deasserts while a pop is already in flight — the arriving byte clobbers the
// still-unconsumed head. That dropped a byte from the MPEG bitstream and garbled
// EVERY clip (incl. SD/susi). The 3-state pull below is trivially correct: it only
// issues a pop from IDLE, then waits for that exact byte, holds it until consumed,
// and only then returns to IDLE to pop again. The ES byte rate (DVD max ~1.3 MB/s)
// is far below the resulting ~rd_clk/3 ceiling (~18 MB/s @54 MHz), so the per-byte
// handshake latency is never a throughput limit.
// =============================================================================
module vidfeed_cdc (
    input        rst_n,        // low-active (sync inside fifo_dc)

    // write side — ps_demux / clk_sys (27 MHz)
    input        wr_clk,
    input  [7:0] wr_data,      // ps_vid_byte
    input        wr_valid,     // ps_vid_valid
    output       wr_ready,     // -> ps_demux vid_ready (= FIFO not full)

    // read side — decoder / clk_dec (54 MHz)
    input        rd_clk,
    output [7:0] rd_data,      // -> mpeg2video stream_data
    output       rd_valid,     // -> mpeg2video stream_valid (byte consumed this cycle)
    input        rd_ready      // <- ~core_busy
);
    wire        full, empty, fifo_valid;
    wire [7:0]  fifo_dout;

    assign wr_ready = ~full;

    // ---- read-side pull adapter (3 states; one byte at a time) ----
    localparam [1:0] S_IDLE = 2'd0,   // head empty: pop one byte if FIFO non-empty
                     S_WAIT = 2'd1,   // pop issued: wait for its data (fifo_valid)
                     S_FULL = 2'd2;   // head holds a byte: present until consumed
    reg [1:0] st;
    reg [7:0] head;

    wire take  = (st == S_FULL) & rd_ready;       // decoder consumes the head byte
    wire rd_en = (st == S_IDLE) & ~empty;         // exactly one pop, only from IDLE

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            head <= 8'd0;
        end else begin
            case (st)
            S_IDLE: if (~empty)      st <= S_WAIT;            // rd_en high this cycle
            S_WAIT: if (fifo_valid) begin head <= fifo_dout; st <= S_FULL; end
            S_FULL: if (take)        st <= S_IDLE;
            default:                 st <= S_IDLE;
            endcase
        end
    end

    assign rd_data  = head;
    assign rd_valid = take;

    // 32-deep is ample for a CDC + the per-byte handshake (upstream ps_stream_fifo
    // and the decoder's vbuf provide the real buffering); keeping it small relieves
    // routing congestion in the dense HPS-bridge region.
    fifo_dc #(.dta_width(9'd8), .addr_width(9'd5)) u_fifo (
        .rst       (rst_n),            // low-active
        .wr_clk    (wr_clk),
        .din       (wr_data),
        .wr_en     (wr_valid & ~full),
        .full      (full),
        .wr_ack    (), .overflow(), .prog_full(),
        .rd_clk    (rd_clk),
        .dout      (fifo_dout),
        .rd_en     (rd_en),
        .empty     (empty),
        .valid     (fifo_valid),
        .underflow (), .prog_empty()
    );
endmodule
