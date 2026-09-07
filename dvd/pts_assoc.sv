//============================================================================
//  pts_assoc.sv — attach each PES PTS to the picture it belongs to, by position.
//
//  THE RULE (ISO 13818-1 2.4.3.7): a PES packet's PTS belongs to the first
//  access unit -- picture -- whose start code lies at or after the first byte
//  of that PES packet's payload. DVDs carry a video PTS only about once per
//  VOBU (~11 pictures), flat .mpg files about once per picture; either way
//  the association is positional, and the two positions it compares are exact
//  by construction (docs/av_sync.md "THE STC IS A CLOCK"):
//
//    stamp  the byte position the marked payload byte will occupy in the VBUF
//           (dvd/vbuf_pos.sv, counted from the flush)
//    header the byte position of the picture start code the vld just parsed
//           (getbits_fifo.bitpos - 32, same origin -- pinned by pts_assoc_tb)
//
//  A shift-register FIFO of {pts, stamp} (head always in slot 0, so the
//  compare is a register read, never an async array read -- the LUT-RAM
//  pattern this project keeps paying for). At every picture header ONE
//  decision, in one cycle: if the head stamp lies at or before the start code,
//  pop it and it is this picture's tag; otherwise this picture has none.
//  Entries that are still at or before the LAST header while the vld is
//  parsing the picture body belong to no picture (a PES carrying a PTS but no
//  access-unit start -- illegal, but seen) and are popped and discarded, so
//  they can never be attached to a later picture. A stamp pushed after the
//  vld already passed it (the PTS value arriving late through its CDC while
//  the VBUF ran nearly empty) is discarded the same way: a lost tag, never a
//  wrong one.
//
//  The tag is REGISTERED and held until the next header. motcomp_picbuf reads
//  it at its STATE_UPDATE for the picture, which is >= 3 cycles after the
//  header (update_picture_buffers -> mvec fifo -> picbuf) and can be no later
//  than the next header (the vld is frozen at the header until picbuf has
//  rotated). A tag that lands on the SECOND field of a field pair arrives
//  after that rotation, so it is also announced by tag_commit for picbuf to
//  re-latch, flagged tag_second for the scheduler to subtract one field.
//
//  Modular compare over 24 bits of bytes (16 MB) with the MSB-of-difference
//  test; correct while the tracked distance is under 8 MB against a 2 MB VBUF.
//  A stamp RATE LIMIT keeps a per-picture-PTS .mpg (a stamp every ~30 KB, up
//  to a whole 2 MB VBUF in flight) from overflowing DEPTH=16: a stamp is
//  accepted only once MIN_GAP bytes have been written since the last accepted
//  one, so at most ~14 are ever in flight and the ones kept are still exact.
//  A full FIFO drops the NEWEST and counts it (dbg_ovf), never the oldest.
//
//  No `function`, no N'(expr) cast: Quartus 17 miscompiles both silently.
//============================================================================

`default_nettype none

module pts_assoc #(
    parameter int DEPTH     = 16,
    parameter int PW        = 24,        // compared position width, bytes (modular)
    parameter int MIN_GAP_W = 16         // 2^16 = 64 KB between accepted stamps
) (
    input  wire          clk,            // clk_dec
    input  wire          rst_n,          // sync_rst (decoder)
    input  wire          flush,          // VBUF flush LEVEL: drop everything in flight

    // write side: a PTS-bearing PES payload's first byte was written at stamp_pos
    input  wire          stamp_valid,
    input  wire [32:0]   stamp_pts,
    input  wire [PW-1:0] stamp_pos,

    // read side: the vld parsed a picture header (one-cycle pulse)
    input  wire          hdr_pulse,
    input  wire [PW-1:0] hdr_pos,        // byte position of the start code
    input  wire          hdr_second,     // the second field of a pair

    // the tag for the picture just parsed; held until the next header
    output logic         tag_valid,
    output logic [32:0]  tag_pts,
    output logic         tag_second,
    output logic         tag_commit,     // one-cycle: tag_* just changed

    output logic [7:0]   dbg_ovf
);

    localparam int CW = $clog2(DEPTH + 1);

    logic [32:0]   pts_q   [DEPTH];
    logic [PW-1:0] pos_q   [DEPTH];
    logic [CW-1:0] cnt;
    logic [PW-1:0] last_hdr;             // position of the last header parsed
    logic          hdr_seen;

    wire full  = (cnt == DEPTH);
    wire empty = (cnt == '0);

    // head stamp at or before a position: (pos - head) has its MSB clear
    wire [PW-1:0] d_hdr  = hdr_pos  - pos_q[0];
    wire [PW-1:0] d_last = last_hdr - pos_q[0];
    wire head_le_hdr  = !empty && !d_hdr[PW-1];
    wire head_le_last = !empty && hdr_seen && !d_last[PW-1];

    wire pop_tag  = hdr_pulse && head_le_hdr;            // this picture's tag
    wire pop_drop = !hdr_pulse && head_le_last;          // belongs to no picture
    wire do_pop   = pop_tag || pop_drop;

    // stamp rate limit (modular, forward-only distance)
    logic [PW-1:0] last_stamp;
    logic          gap_armed;
    localparam [PW-1:0] MIN_GAP = (1 << MIN_GAP_W);
    wire [PW-1:0] gap_d  = stamp_pos - last_stamp;
    wire gap_ok  = !gap_armed || (gap_d >= MIN_GAP);
    wire do_push = stamp_valid && !full && gap_ok;

    integer i;
    always_ff @(posedge clk) begin
        tag_commit <= 1'b0;
        if (!rst_n || flush) begin
            cnt        <= '0;
            gap_armed  <= 1'b0;
            hdr_seen   <= 1'b0;
            last_hdr   <= '0;
            last_stamp <= '0;
            tag_valid  <= 1'b0;
            tag_pts    <= '0;
            tag_second <= 1'b0;
            if (!rst_n) dbg_ovf <= '0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                pts_q[i] <= '0;
                pos_q[i] <= '0;
            end
        end else begin
            if (hdr_pulse) begin
                last_hdr   <= hdr_pos;
                hdr_seen   <= 1'b1;
                tag_valid  <= head_le_hdr;
                tag_pts    <= pts_q[0];
                tag_second <= hdr_second;
                tag_commit <= 1'b1;
            end
            if (do_push) begin
                last_stamp <= stamp_pos;
                gap_armed  <= 1'b1;
            end
            if (do_pop)
                for (i = 0; i < DEPTH - 1; i = i + 1) begin
                    pts_q[i] <= pts_q[i+1];
                    pos_q[i] <= pos_q[i+1];
                end
            if (do_push) begin
                for (i = 0; i < DEPTH; i = i + 1)
                    if (i == (do_pop ? cnt - 1 : cnt)) begin
                        pts_q[i] <= stamp_pts;
                        pos_q[i] <= stamp_pos;
                    end
            end else if (stamp_valid && full && gap_ok && ~&dbg_ovf)
                dbg_ovf <= dbg_ovf + 1'b1;
            case ({do_push, do_pop})
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: cnt <= cnt;
            endcase
        end
    end

endmodule

`default_nettype wire
