//============================================================================
//  vbuf_pos.sv — the exact byte position the NEXT stream byte will occupy in
//  the VBUF, in the coordinate the vld reports its parse position in.
//
//  Part of the PTS -> picture association (docs/av_sync.md "THE STC IS A
//  CLOCK"). The MPEG rule is positional: a PES PTS belongs to the first picture
//  start code at or after that PES payload's first byte. The demux marks that
//  byte, this module says where it lands, and the vld (getbits_fifo.bitpos)
//  says where each picture start code was parsed -- both counted from the same
//  VBUF flush, so the compare needs no tolerance.
//
//      stream_pos = 8 * (vbuf_wr_cnt + vbw_pending) + phase_idx     [bytes]
//
//  vbuf_wr_cnt   words the VBW state has WRITTEN since vb_flush (framestore_request)
//  vbw_pending   words pushed into vbuf_write_fifo by the packer and not yet
//                written. Reset by the same synchronised flush reset the fifo
//                uses (vbuf_rst, active-low); a push during that reset is not
//                counted because the fifo drops it. A pop that lands after
//                vb_flush but inside the reset window is the ONE in-flight
//                word: vbuf_wr_cnt counts it as word 0 and the read side (new
//                epoch) sees it as word 0 -- consistent -- so the decrement
//                saturates at 0 instead of going negative.
//  phase_idx     bytes already packed into the packer's partial word, from
//                vbuf_write's one-hot `loop`: 0x00/0x80 -> 0, 0x01 -> 1, ...
//                0x40 -> 7 (see rtl/mpeg2/vbuf.v).
//
//  No `function`, no N'(expr) cast: Quartus 17 miscompiles both silently.
//============================================================================

`default_nettype none

module vbuf_pos (
    input  wire        clk,
    input  wire        vbuf_rst,       // active-LOW synchronised VBUF flush reset (mpeg2video)
    input  wire        vbw_wr_en,      // packer pushed a word into vbuf_write_fifo
    input  wire        vbuf_wr_pulse,  // framestore wrote a word into the VBUF
    input  wire [25:0] vbuf_wr_cnt,    // words written since vb_flush (framestore_request)
    input  wire  [7:0] phase,          // vbuf_write.loop
    output wire [28:0] stream_pos      // byte position of the next incoming byte (modular)
);

    reg [8:0] vbw_pending;
    always @(posedge clk)
        if (~vbuf_rst) vbw_pending <= 9'd0;
        else
            case ({vbw_wr_en, vbuf_wr_pulse && (vbw_pending != 9'd0)})
                2'b10:   vbw_pending <= vbw_pending + 9'd1;
                2'b01:   vbw_pending <= vbw_pending - 9'd1;
                default: vbw_pending <= vbw_pending;
            endcase

    wire [2:0] phase_idx = phase[0] ? 3'd1 : phase[1] ? 3'd2 : phase[2] ? 3'd3 :
                           phase[3] ? 3'd4 : phase[4] ? 3'd5 : phase[5] ? 3'd6 :
                           phase[6] ? 3'd7 : 3'd0;
    // vbuf_write raises vid_out_wr_en the cycle AFTER a word's eighth byte, so a
    // byte arriving in exactly that cycle -- the first byte of the next word --
    // sees a push that vbw_pending has not counted yet. Count it here, or every
    // stamp on a word boundary lands one word early (measured: -8 B, pts_chain_tb).
    wire [25:0] stream_word = vbuf_wr_cnt + {17'd0, vbw_pending} + {25'd0, vbw_wr_en};
    assign stream_pos = {stream_word, phase_idx};

endmodule

`default_nettype wire
