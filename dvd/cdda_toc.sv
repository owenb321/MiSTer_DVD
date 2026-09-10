//============================================================================
//  dvd/cdda_toc.sv — the audio CD's track table, and where the playhead is in it.
//
//  A physical audio CD reaches the core as ONE GIANT WAV (see docs/cdda.md): the
//  Main concatenates the disc's audio sectors behind a synthetic 44-byte RIFF
//  header, so the reader plays it with no CD-specific mode at all. That is what
//  makes playback simple — and it is also why the core has no idea where one
//  track ends and the next begins. This module is the missing half: the Main
//  sends the track boundaries over the generic ioctl-download channel, and this
//  turns the linear playhead back into "track 7 of 12".
//
//  WIRE FORMAT (little-endian, ioctl index CDDA_TOC_INDEX):
//     0..3   magic "CDTC"
//     4      version (1)
//     5      ntracks (1..99)
//     6..7   reserved
//     8..11  total_blocks   — the whole image, so the last track has an end
//     12..   track_start[ntracks], 4 bytes each — 2048-byte block of each
//            track's first audio byte
//
//  ★ NEVER-GARBAGE, the idle_logo rule: the table commits only at download END
//  and only if the magic, the version and the LENGTH all check out. A
//  partially-written track table would send a track skip to a random position,
//  which is worse than having no tracks at all.
//
//  ⚠ AND THE ENTRY RAM IS PART OF THAT, which the first version of this module
//  got wrong. Gating only the header fields at commit is not enough: the entry
//  writes land as the bytes ARRIVE, so a malformed upload still overwrote the
//  starts and left a table that passed every header check while pointing at the
//  wrong blocks. The download START therefore invalidates: a failed upload loses
//  the tracks (HUD hides them, skip is disabled) rather than silently giving
//  wrong ones. Nothing is lost by that — a mount already invalidates, so the
//  "previous table" a double buffer would preserve is never one we would use.
//
//  ★ Block granularity is deliberate. One 2048-byte block is ~12 ms of CD audio,
//  far below anything a listener can notice on a track skip, and it lets every
//  comparison here happen in the reader's own linear-block units with no
//  conversion.
//
//  ⚠⚠ THE TABLE IS READ THROUGH ONE SYNCHRONOUS PORT, AND THAT IS NOT A STYLE
//  CHOICE. The first version read start_ram combinationally at five sites (the
//  scan bounds, prev/next, the notch replay). Quartus cannot map an async-read
//  array to an M10K, so it built all 100x32 bits out of FLOPS plus the address
//  muxes: 3733 ALUTs and 3463 registers, 0 block memory bits, and the design --
//  already at 98% ALM -- FAILED TO FIT (4558 LABs needed, 4191 on the device).
//  This is the same LUT-RAM explosion that once put dvd_iso_reader's parse_buf
//  at 226% ALM. One registered read port, walked one entry per cycle, is what
//  makes it an M10K.
//
//  The walk is free: the playhead moves ~86 blocks/second and there are at most
//  99 tracks, so a full pass settles thousands of times faster than the answer
//  can go stale. Reading entries k, k-1 and k-2 as the address advances gives
//  the current track's bounds AND its neighbours' starts from that single port.
//============================================================================

`timescale 1ns/1ps
`default_nettype none

module cdda_toc #(
    parameter [15:0] TOC_INDEX = 16'd250   // clear of PSX's 251
)(
    input  wire        clk,
    input  wire        rst_n,

    // generic ioctl download (hps_io)
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    input  wire [15:0] ioctl_index,

    // cleared whenever a new image is mounted: a table belongs to ONE disc.
    input  wire        mount,

    // the reader's linear playhead, in 2048-byte blocks
    input  wire [31:0] lin_blk,

    output reg         toc_valid,
    output reg  [7:0]  n_tracks,
    output reg  [7:0]  cur_track,      // 1-based; 0 while unresolved
    output wire [31:0] cur_start,      // first block of the current track
    output wire [31:0] cur_end,        // first block AFTER it
    output wire [31:0] prev_start,     // target for a "previous track" skip
    output wire [31:0] next_start,     // target for a "next track" skip

    // seek-bar notch feed: replayed once after each commit so seek_bar's
    // generic cellf_* write ports draw a tick at every track boundary.
    output reg         notch_we,
    output reg  [6:0]  notch_idx,
    output reg  [31:0] notch_blk
);

    localparam MAXT = 100;

    reg [31:0] start_ram [0:MAXT-1];
    reg [31:0] total_blk;

    // ---- download capture --------------------------------------------------
    reg        dl_prev, idx_q, mg_ok, ver_ok;
    reg [7:0]  ntr_raw;
    reg [31:0] tot_raw;
    reg [31:0] word;
    reg [26:0] last_addr;

    wire dl_here = ioctl_download & idx_q;
    // byte 12 onward is the track array; entry i occupies 12+4i .. 15+4i
    wire        in_body = (ioctl_addr >= 27'd12);
    wire [26:0] body_off = ioctl_addr - 27'd12;
    wire [6:0]  ent_i   = body_off[8:2];
    wire [1:0]  ent_b   = body_off[1:0];

    // The exact byte count this header implies. A download of any other length
    // is refused wholesale.
    wire [26:0] want_len = 27'd12 + ({19'd0, ntr_raw} << 2);

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dl_prev <= 1'b0; idx_q <= 1'b0; mg_ok <= 1'b0; ver_ok <= 1'b0;
            ntr_raw <= 8'd0; tot_raw <= 32'd0; word <= 32'd0; last_addr <= 27'd0;
            toc_valid <= 1'b0; n_tracks <= 8'd0; total_blk <= 32'd0;
        end else begin
            dl_prev <= ioctl_download;

            // A new disc invalidates the old disc's tracks immediately.
            if (mount) begin toc_valid <= 1'b0; n_tracks <= 8'd0; end

            if (ioctl_download & ~dl_prev) begin
                // hps_io latches ioctl_index BEFORE raising download
                idx_q     <= (ioctl_index == TOC_INDEX);
                mg_ok     <= 1'b0; ver_ok <= 1'b0;
                ntr_raw   <= 8'd0; tot_raw <= 32'd0;
                last_addr <= 27'd0;
                // ⚠ Invalidate up front: the entry RAM is about to be written
                // byte by byte, so from here until a clean commit the table is
                // NOT trustworthy. See the never-garbage note in the header.
                if (ioctl_index == TOC_INDEX) begin
                    toc_valid <= 1'b0;
                    n_tracks  <= 8'd0;
                end
            end

            if (ioctl_wr & dl_here) begin
                last_addr <= ioctl_addr;
                case (ioctl_addr)
                    27'd0: mg_ok  <= (ioctl_dout == "C");
                    27'd1: mg_ok  <= mg_ok & (ioctl_dout == "D");
                    27'd2: mg_ok  <= mg_ok & (ioctl_dout == "T");
                    27'd3: mg_ok  <= mg_ok & (ioctl_dout == "C");
                    27'd4: ver_ok <= (ioctl_dout == 8'd1);
                    27'd5: ntr_raw <= ioctl_dout;
                    27'd8:  tot_raw[7:0]   <= ioctl_dout;
                    27'd9:  tot_raw[15:8]  <= ioctl_dout;
                    27'd10: tot_raw[23:16] <= ioctl_dout;
                    27'd11: tot_raw[31:24] <= ioctl_dout;
                    default: ;
                endcase

                // Track entries: assemble little-endian, write on the last byte.
                if (in_body && ent_i < MAXT[6:0]) begin
                    case (ent_b)
                        2'd0: word[7:0]   <= ioctl_dout;
                        2'd1: word[15:8]  <= ioctl_dout;
                        2'd2: word[23:16] <= ioctl_dout;
                        2'd3: start_ram[ent_i] <= {ioctl_dout, word[23:0]};
                    endcase
                end
            end

            // ---- commit, only if EVERYTHING checks out ----------------------
            if (~ioctl_download & dl_prev & idx_q) begin
                if (mg_ok && ver_ok && ntr_raw != 8'd0 && ntr_raw < 8'd100 &&
                    (last_addr + 27'd1) == want_len && tot_raw != 32'd0)
                begin
                    n_tracks  <= ntr_raw;
                    total_blk <= tot_raw;
                    toc_valid <= 1'b1;
                end
                // else: keep whatever was there. A bad upload changes nothing.
            end
        end
    end

    // Current track's bounds and its neighbours' starts, all REGISTERED off the
    // single read port below.
    reg [31:0] s_lo, s_hi, s_prev, s_next;

    // ---- the walk: one sync read port serves bounds, neighbours and notches --
    // ra sweeps 0..n_tracks. `rd` is start_ram[ra_q] one cycle later, with rd_p
    // and rd_pp trailing it, so at ra_q == k we hold start[k], start[k-1] and
    // start[k-2] -- everything track k-1 needs, from ONE port.
    reg [6:0]  ra, ra_q;
    reg [31:0] rd, rd_p, rd_pp;
    reg        first_pass;        // emit notches on the pass after a commit

    always @(posedge clk) begin
        rd   <= start_ram[ra];
        ra_q <= ra;
        rd_p <= rd;
        rd_pp<= rd_p;
    end

    // Track index under evaluation this cycle, and its bounds. The LAST track's
    // upper bound is the image end -- there is no start[n] to read.
    wire [6:0]  ev_i    = ra_q - 7'd1;
    wire        ev_ok   = toc_valid && (ra_q >= 7'd1) && (ra_q <= n_tracks[6:0]);
    wire        ev_last = (ra_q == n_tracks[6:0]);
    wire [31:0] ev_lo   = rd_p;
    wire [31:0] ev_hi   = ev_last ? total_blk : rd;
    wire [31:0] ev_next = ev_last ? total_blk : rd;
    wire [31:0] ev_prev = (ev_i == 7'd0) ? rd_p : rd_pp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra <= 7'd0; first_pass <= 1'b0;
            cur_track <= 8'd0;
            s_lo <= 32'd0; s_hi <= 32'd0; s_prev <= 32'd0; s_next <= 32'd0;
            notch_we <= 1'b0; notch_idx <= 7'd0; notch_blk <= 32'd0;
        end else begin
            notch_we <= 1'b0;

            if (!toc_valid) begin
                ra <= 7'd0; cur_track <= 8'd0; first_pass <= 1'b1;
            end else begin
                ra <= (ra >= n_tracks[6:0]) ? 7'd0 : (ra + 7'd1);
                // ⚠ Clear on ra_q, NOT ra: the read port is a cycle behind, so
                // the pass is not finished until the LAST track has been
                // EVALUATED. Clearing on ra dropped the final track's notch --
                // the seek bar was one tick short on every disc.
                if (ra_q >= n_tracks[6:0]) first_pass <= 1'b0;

                if (ev_ok) begin
                    // seek-bar notch: one per track, on the first pass only
                    if (first_pass) begin
                        notch_we  <= 1'b1;
                        notch_idx <= ev_i;
                        notch_blk <= ev_lo;
                    end
                    if (lin_blk >= ev_lo && lin_blk < ev_hi) begin
                        cur_track <= {1'b0, ev_i} + 8'd1;
                        s_lo   <= ev_lo;
                        s_hi   <= ev_hi;
                        s_prev <= ev_prev;
                        s_next <= ev_next;
                    end
                end
            end
        end
    end

    assign cur_start  = s_lo;
    assign cur_end    = s_hi;
    assign next_start = s_next;
    assign prev_start = s_prev;

endmodule

`default_nettype wire
