// =============================================================================
// dvd/es_stuff.sv -- MPEG-2 zero_byte stuffing at a keep_vbuf menu hop
//                    (docs/quant_matrix.md 13q)
// =============================================================================
// THE DEFECT.  A keep_vbuf menu->menu hop hands the decoder the OUTGOING cell cut
// at an arbitrary byte (the reader's cache is discarded and ps_demux is reset by
// the hop's load_flush), immediately followed by the landing cell's 00 00 01 B3.
// The vld is wherever the cut left it -- usually mid-macroblock, mid-VLC.  At most
// cut offsets it errors out on the truncated slice and hunts the next start code
// BEFORE the landing's header arrives; at some it swallows `00 00 01 B3` as
// coefficient data, the landing's ONE sequence header is lost, and a menu still
// (SEQ GOP PIC:I SEQ_END, one header ever) is dequantised with the previous
// menu's matrix: the "deep fried" still.  MEASURED on NACHO_LIBRE_WS's real cells
// (bench/dvd/run_menu_junction.sh): offset 5000 -> 63/64 matrix entries wrong.
//
// THE FIX.  ISO 13818-2 6.2.1 requires a decoder to skip any number of zero
// bytes before a start code, and this vld does (STATE_NEXT_START_CODE walks a
// byte at a time; 24'h000000 != 24'h000001).  So put a run of 0x00 between the
// last byte of the outgoing cell and the first byte of the landing.  From ANY
// state the cut left the parser in, an all-zero string cannot be parsed as
// valid data for long:
//   * mid-VLC: every table returns length 0 on zeros -> STATE_ERROR (before the
//     macroblock is announced to motcomp, nothing in the rld fifo) or
//     STATE_DCT_ERROR (which pads the macroblock out to its full block count
//     with end-of-block markers) -> STATE_NEXT_START_CODE;
//   * mid fixed-length field (DC diff, escape, motion residual, quant scale):
//     the zeros are the value, the next state is a VLC state -> as above;
//   * at a macroblock boundary: the spec's 23-zero nextbits() test -> hunt;
//   * mid header: every "another field follows" flag reads 0 -> hunt.
//   * EXCEPT a cut inside a 64-entry quantiser-matrix download (vld.v
//     STATE_LD_*_QUANT0): that loop is counter-driven and eats up to 64 zero
//     bytes as matrix entries first.  Hence N >= 68; 128 is used.  MEASURED
//     (run_menu_junction.sh [J4]): a cut inside the download fries with 16
//     zeros and is clean with 128.
// The hunt then finds the landing's `00 00 01 B3` intact -- a zero run followed
// by 00 00 01 is a legal start-code prefix from ANY byte alignment -- the header
// is parsed, the matrix downloaded, and the still decodes correctly the FIRST
// time.  No fried picture, no drop, no re-stream, no duplicate audio, and no
// black frame: nothing is flushed or reset.  This is the SAME natural error path
// that already resyncs 4 landings in 5 cleanly, and it is structurally immune
// to the luma-in-chroma desync of docs/quant_matrix.md 9 (that came from
// FORCING the state from inside a block, leaving one block without its end
// marker; the natural path never does).
//
// WHY ZEROS, NOT 0xFF.  A run of 1s decodes as valid B.14 coefficients
// indefinitely (`11` = run 0 level 1); only zeros provoke the error.  Precedent
// in this very pipeline: ps_demux's S_VID_FLUSH emits 24 zero bytes after every
// still's B7, HW-proven since the Phase-5 menu work.
//
// WHEN.  `arm` is EVERY jump/seek ack (emu: es_stuff_arm = jump_ack | seek_ack)
// -- the keep_vbuf menu hop, whose junction has no VBUF flush at all, AND the
// flushing jump/seek, whose flush leaves the parser frozen mid-picture
// (docs/quant_matrix.md 11) with the landing arriving INTO that state.  Both eat
// the landing's header; MEASURED on Harry Potter Interactive's title-domain
// stills (13r): 7 of 12 swept flush positions lose it, 0 of 12 with the run.
// The run is issued in front of the FIRST byte ps_demux presents after that
// junction's pipe reset -- the landing's first byte by construction.  The spend waits
// for pipe_rst_n to have actually been LOW since the arm (rst_seen): in the
// cycle between the ack and load_flush taking pipe_rst_n low, ps_demux can
// still present a byte of the OUTGOING cell, and stuffing in front of THAT
// would put `<zeros> XX 00 00 01 B3` on the wire -- if XX happened to be 0x01
// the hunt would read `00 00 01 00` as a picture start code and eat the real
// header from the other side.  bench/dvd/es_stuff_tb.sv T3 is that case.
//
// The zeros ride the normal byte path (vidfeed_cdc -> vbuf_write -> vbuf_pos),
// so the parse-position coordinate the PTS association lives in stays exact,
// and the PTS mark stays on the landing's real byte (ps_demux holds it, with
// mark_pending, while in_ready is low).  Reset domain: reset_n, never
// pipe_rst_n -- the module must survive the very reset it keys on.
// =============================================================================
`default_nettype none
module es_stuff #(
    parameter integer N = 128         // zero bytes per junction (>= 68, see above)
) (
    input  wire       clk,            // clk_sys
    input  wire       rst_n,          // core reset (NOT pipe_rst_n)
    input  wire       arm,            // pulse: a keep_vbuf hop was acknowledged
    input  wire       pipe_rst_n,     // the load_flush reset that hop pulses on ps_demux

    // <- ps_demux vid_*
    input  wire [7:0] in_byte,
    input  wire       in_mark,        // PTS mark (rides with its byte)
    input  wire       in_valid,
    output wire       in_ready,

    // -> vidfeed_cdc wr_*
    output wire [8:0] out_data,       // {mark, byte}
    output wire       out_valid,
    input  wire       out_ready,

    output wire       stuffing        // level: a zero run is being emitted (probe)
);
    localparam integer CW = $clog2(N + 1);

    reg          armed;               // a hop was acked, its landing not yet stuffed
    reg          rst_seen;            // ...and its pipe reset has been observed
    reg [CW-1:0] cnt;                 // zeros still to emit

    wire run   = (cnt != {CW{1'b0}});
    // The landing's first byte: presented after the reset the hop pulsed.
    wire start = armed && rst_seen && pipe_rst_n && in_valid && ~run;
    wire stuff = run || start;        // start counts: the byte must NOT pass first

    assign stuffing  = stuff;
    assign out_data  = stuff ? 9'h000 : {in_mark, in_byte};
    assign out_valid = stuff | in_valid;
    assign in_ready  = out_ready & ~stuff;

    always @(posedge clk) begin
        if (!rst_n) begin
            armed    <= 1'b0;
            rst_seen <= 1'b0;
            cnt      <= {CW{1'b0}};
        end else begin
            if (armed && !pipe_rst_n) rst_seen <= 1'b1;
            if (start) begin
                // the first zero goes out THIS cycle if the sink takes it
                cnt      <= out_ready ? N[CW-1:0] - 1'b1 : N[CW-1:0];
                armed    <= 1'b0;
                rst_seen <= 1'b0;
            end else if (run && out_ready) begin
                cnt      <= cnt - 1'b1;
            end
            // last, so an ack landing in the same cycle as a spend re-arms for
            // the NEXT landing instead of being lost
            if (arm) begin
                armed    <= 1'b1;
                rst_seen <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
