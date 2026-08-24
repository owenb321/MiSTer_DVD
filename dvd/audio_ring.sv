// audio_ring.sv — Audio frame ring buffer (ps_demux → HPS)
// Part of MiSTer DVD Player Core
//
// Sits on the audio output of dvd/ps_demux.sv and holds complete audio frames
// (AC-3 / DTS / LPCM payload) so the HPS can later pull them out, decode
// (liba52 / libdca) or pass LPCM, and play via ALSA → HDMI.
//
// ---------------------------------------------------------------------------
// Why single-clock (clk_sys): the intended HPS read transport is the MiSTer
// `ioctl_upload` channel, which runs in the clk_sys (27 MHz) domain — the same
// domain as ps_demux. So no clock-domain crossing is needed and this is a plain
// single-clock FIFO, NOT the dual-clock FIFO the early docs assumed for an
// f2sdram path.
//
// ---------------------------------------------------------------------------
// FLOW CONTROL (revised 2026-07-02 — the old "never backpressure" invariant is
// RELAXED to a watchdog-guarded backpressure, the DVD STD model):
//   ps_demux carries BOTH video and audio on one byte stream. This module's own
//   aud_ready output stays tied HIGH (it always accepts and drops a whole frame
//   on overflow — rewinding its bytes — so boundaries stay intact). But it now
//   also exports `almost_full`, and emu.sv uses that to deassert ps_demux's
//   aud_ready, stalling the shared STREAM until the audio decoder drains. That
//   is how a real DVD player's demux works (System Target Decoder: the demux
//   waits when an elementary buffer is full). The VIDEO PICTURE is unaffected:
//   the video decoder reads from VBUF, a multi-MB DRAM bitstream backlog, so a
//   stream stall never starves the display. Rationale: an overflow drop is a
//   whole AC-3 frame = an audible 32 ms gap ("stutter"); backpressure loses
//   nothing. emu.sv guards it with a drain watchdog (audio muted / DTS-only /
//   wedged decoder → backpressure released, reverts to drop-on-full) so the
//   stream can never wedge.
//
// ---------------------------------------------------------------------------
// Structure — two coupled FIFOs in one clock domain:
//   1. Byte FIFO   : BRAM-style ring of audio payload bytes (BYTE_DEPTH).
//   2. Frame FIFO  : one descriptor { length[15:0], type[1:0] } per COMPLETED
//                    frame (FRAME_DEPTH). The HPS pops a descriptor, then reads
//                    `frame_len` bytes for that frame.
//
// Only COMMITTED (finalized) frame bytes are visible to the reader: `avail`
// counts committed readable bytes; `fill` counts all physical bytes (committed
// + the in-progress frame). In-progress bytes sit ahead of the readable region
// and are never popped until their frame commits, so a partially-written or
// dropped frame can never leak to the HPS.
//
// LENGTH-DEFERRED FINALIZE: a frame's length is only known when the NEXT
// aud_frame_start arrives, so frame N's descriptor is pushed at the start of
// frame N+1. Consequence: the trailing frame is not finalized until another
// frame starts. Fine for continuous playback; a future flush/timeout input can
// finalize a lone trailing frame.
//
// PER-FRAME PTS (A/V sync): each descriptor also carries the PES PTS captured at
// aud_frame_start ({pts_valid, pts[32:0]}), surfaced as frame_pts/frame_pts_valid
// on the read side. dvd/av_sync.sv uses it to genlock the audio NCO to the video
// STC. frame_pts_valid is low for a PES that carried no PTS (held value is stale).
//
// Tested by bench/dvd/audio_ring_tb.sv.

`default_nettype none

module audio_ring #(
    parameter int BYTE_DEPTH  = 8192,  // payload byte ring depth   (power of two)
    parameter int FRAME_DEPTH = 64     // completed-frame descriptors (power of two)
) (
    input  wire        clk,            // clk_sys (27 MHz)
    input  wire        rst_n,

    // Write side — from ps_demux audio output (held valid; we always accept).
    input  wire  [7:0] aud_byte,
    input  wire        aud_valid,
    input  wire  [1:0] aud_type,        // 0=AC3 1=DTS 2=LPCM 3=unknown
    input  wire        aud_frame_start,  // pulsed on first byte of a new frame
    // MENU-TRANSITION SPLICE DROP (docs/dvd_menu_refinements.md §5d): on a keep_vbuf
    // menu->menu transition the ring is NOT reset (audio-continuity), but ps_demux/reframer
    // re-sync on the new stream and produce a truncated old frame + a couple of re-sync
    // garbage frames that would decode as a "pop/blip". Pulse drop_pulse at that transition
    // to DROP the in-progress frame and the next few frames, so the buffered old audio plays
    // out and the new menu audio picks up on a clean AC-3 frame boundary.
    input  wire        drop_pulse,
    input  wire [32:0] aud_frame_pts,    // PES PTS for this frame (held, valid @ start)
    input  wire        aud_frame_pts_valid, // this frame's PES carried a PTS
    output wire        aud_ready,        // tied high — see HARD INVARIANT above

    // Read side, byte stream (FWFT) — for the HPS via ioctl_upload.
    output wire  [7:0] out_byte,
    output wire        out_valid,         // = committed bytes available
    input  wire        out_ready,         // pop on out_valid && out_ready

    // Read side, per-frame metadata. The consumer pops a descriptor, then reads
    // `frame_len` bytes of type `frame_type` from the byte stream.
    output wire        frame_valid,       // a completed frame is queued
    output wire [15:0] frame_len,         // its payload length in bytes
    output wire  [1:0] frame_type,        // its codec (aud_type)
    output wire [32:0] frame_pts,         // PES PTS captured at frame start
    output wire        frame_pts_valid,   // that PTS is meaningful (PES had one)
    input  wire        frame_pop,         // pop the front descriptor

    // Status (for status-word / debug-overlay wiring later).
    output wire [15:0] frames_available,  // queued completed frames
    output wire [15:0] bytes_available,   // queued committed bytes
    output wire [15:0] overflow_count,    // frames dropped on overflow (sticky)

    // Demux flow control (see FLOW CONTROL above): asserted while the ring is
    // close enough to full that another max-size PES payload / AC-3 frame might
    // not fit. emu.sv gates ps_demux's aud_ready with this (watchdog-guarded)
    // so the stream stalls instead of dropping an audible 32 ms audio frame.
    // Headroom covers a max AC-3 frame (~3.8 KB @640 kb/s) + a PES payload in
    // flight through the (unbuffered) ac3_reframer.
    output wire        almost_full
);

    localparam int BYTE_AW  = $clog2(BYTE_DEPTH);
    localparam int FRAME_AW = $clog2(FRAME_DEPTH);

    // ---- Byte FIFO ----
    logic [7:0]          mem [0:BYTE_DEPTH-1];
    logic [BYTE_AW-1:0]  wr_ptr;
    logic [BYTE_AW-1:0]  rd_ptr;
    logic [BYTE_AW:0]    fill;     // total physical bytes (committed + in-progress)
    logic [BYTE_AW:0]    avail;    // committed bytes readable by HPS

    // ---- In-progress frame state ----
    logic [BYTE_AW-1:0]  frame_start_wrptr;  // wr_ptr where current frame began
    // bytes pushed for current frame. WIDTH = BYTE_AW+1 so cur_len[BYTE_AW:0] (used in
    // the fill/avail arithmetic below) is in range for ANY BYTE_DEPTH - at 64 KB
    // (BYTE_AW=16) a 16-bit cur_len made cur_len[16:0] an out-of-range index (Quartus
    // error 10232). The descriptor still stores only cur_len[15:0] (a real audio frame is
    // < 2 KB, never near 64 KB), so frame_len stays 16-bit and DESC_W is unchanged.
    logic [BYTE_AW:0]    cur_len;
    logic [1:0]          cur_type;
    logic [32:0]         cur_pts;            // PES PTS captured at this frame's start
    logic                cur_pts_valid;      // that PTS is meaningful
    logic                cur_dropping;       // current frame overflowed → discard
    logic                frame_open;         // a frame has been started
    logic [2:0]          drop_cnt;           // menu-transition splice: frames left to drop

    // ---- Frame descriptor FIFO ({pts_valid, pts[32:0], length[15:0], type[1:0]}) ----
    // Phase-0 ALM reclaim (2026-07-06): dmem is now a SYNC-READ M10K, fronted by a
    // FWFT head register (`head_desc`/`head_v`). The old async taps `dmem[d_rd]` on
    // four 52-bit fields synthesised as wide 64:1 muxes (~1.9k combinational ALUTs =
    // the module's ALM cost). A registered read port maps dmem into 1 M10K and the
    // descriptor the consumer sees comes from `head_desc` instead. Behaviour is
    // interface-equivalent: `frame_valid` de-asserts for ≤2 clk_sys cycles after a
    // pop while the ring refills the head — absorbed by dvd_audio_decode, which reads
    // the descriptor only in S_IDLE (gated by frame_valid) and then routes hundreds
    // of bytes before needing the next one. See docs/roadmap.md ALM-reclaim note.
    localparam int DESC_W = 1 + 33 + 16 + 2;   // 52
    logic [DESC_W-1:0]   dmem [0:FRAME_DEPTH-1];
    logic [FRAME_AW-1:0] d_wr;      // ring write pointer (commit)
    logic [FRAME_AW-1:0] d_rd;      // ring read pointer  (head refill)
    logic [FRAME_AW:0]   q_cnt;     // committed descriptors resident in dmem (ring)

    // FWFT head register: the descriptor currently presented to the consumer.
    logic [DESC_W-1:0]   head_desc; // == dmem output register (M10K read reg)
    logic                head_v;    // head_desc holds a valid, un-popped descriptor

    // Total committed descriptors not yet popped = ring residents + the head slot.
    logic [FRAME_AW+1:0] total_frames;
    assign total_frames = q_cnt + (head_v ? 1'b1 : 1'b0);

    // ---- Outputs ----
    assign aud_ready        = 1'b1;                 // HARD INVARIANT
    assign out_valid        = (avail != 0);
    assign out_byte         = mem[rd_ptr];
    assign frame_valid      = head_v;
    assign frame_type       = head_desc[1:0];
    assign frame_len        = head_desc[17:2];
    assign frame_pts        = head_desc[50:18];
    assign frame_pts_valid  = head_desc[51];
    assign frames_available = {{(16-(FRAME_AW+2)){1'b0}}, total_frames};
    // bytes_available is a 16-bit STATUS output (overlay/HPS), but `avail` is
    // BYTE_AW+1 bits wide - narrower than 16 for a small ring, but EXACTLY 17 once
    // BYTE_DEPTH == 65536 (BYTE_AW==16). Zero-extend to a fixed 17 bits (valid for any
    // BYTE_DEPTH <= 64 KB), then saturate at 0xFFFF. The old zero-pad-to-16 concat
    // broke the build at 64 KB (negative replication count). Cosmetic only - flow
    // control uses the full-width `fill`/`avail` internally.
    wire [16:0] avail_ext = {{(17-(BYTE_AW+1)){1'b0}}, avail};
    assign bytes_available  = (avail_ext > 17'd65535) ? 16'hFFFF : avail_ext[15:0];

    // 16-bit view of cur_len for the descriptor frame_len field. Plain assignment
    // auto-resizes (zero-extend when the ring is small / cur_len < 16 bits, truncate at
    // 64 KB where cur_len is 17 bits) - width-agnostic, unlike a fixed [15:0] part-select.
    wire [15:0] cur_len16 = cur_len;

    logic [15:0] overflow_q;
    assign overflow_count   = overflow_q;

    // Backpressure threshold: byte headroom < 6 KB (max AC-3 frame + in-flight
    // PES margin) or descriptor headroom < 8. `fill` (physical, incl. the
    // in-progress frame) is the right measure — committed `avail` understates.
    localparam int BP_BYTE_HEADROOM  = 6144;
    localparam int BP_FRAME_HEADROOM = 8;
    assign almost_full = (fill         >= (BYTE_DEPTH  - BP_BYTE_HEADROOM)) ||
                         (total_frames >= (FRAME_DEPTH - BP_FRAME_HEADROOM));

    always_ff @(posedge clk or negedge rst_n) begin : ring_proc
        // combinational intermediates (blocking) — registers use non-blocking
        logic               do_pop;
        logic               start;
        logic               fin;
        logic               do_commit;
        logic               do_drop;
        logic               do_pop_head;   // consumer pops the head descriptor
        logic               head_free_nx;  // head will be empty (empty now, or popped)
        logic               do_issue;      // launch a ring read into the head slot
        logic [BYTE_AW:0]   fill_t;
        logic [BYTE_AW:0]   avail_t;
        logic [BYTE_AW-1:0] wr_addr;
        logic               has_space;

        if (!rst_n) begin
            wr_ptr            <= '0;
            rd_ptr            <= '0;
            fill              <= '0;
            avail             <= '0;
            frame_start_wrptr <= '0;
            cur_len           <= '0;
            cur_type          <= '0;
            cur_pts           <= '0;
            cur_pts_valid     <= 1'b0;
            cur_dropping      <= 1'b0;
            frame_open        <= 1'b0;
            drop_cnt          <= 3'd0;
            d_wr              <= '0;
            d_rd              <= '0;
            q_cnt             <= '0;
            head_v            <= 1'b0;
            head_desc         <= '0;
            overflow_q        <= '0;
        end else begin
            do_pop  = out_valid && out_ready;         // avail != 0 guaranteed
            start   = aud_valid && aud_frame_start;
            fin     = start && frame_open;            // finalize previous frame

            // --- stage 1: reader pop (committed bytes leave the buffer) ---
            fill_t  = fill  - (do_pop ? 1'b1 : 1'b0);
            avail_t = avail - (do_pop ? 1'b1 : 1'b0);

            // --- stage 2: finalize the previous frame on a start pulse ---
            // commit only if it has bytes, didn't overflow, and the ring has room;
            // otherwise drop it. (Room in the RAM ring; the head slot is extra.)
            do_commit = fin && !cur_dropping && (cur_len != 0) && (q_cnt != FRAME_DEPTH[FRAME_AW:0]);
            do_drop   = fin && !do_commit && (cur_dropping || (cur_len != 0));

            if (do_drop) begin
                wr_addr = frame_start_wrptr;          // rewind: discard frame bytes
                fill_t  = fill_t - cur_len[BYTE_AW:0];
                overflow_q <= overflow_q + 1'b1;
            end else begin
                wr_addr = wr_ptr;
            end

            if (do_commit) begin
                dmem[d_wr] <= {cur_pts_valid, cur_pts, cur_len16, cur_type};
                d_wr       <= d_wr + 1'b1;
                avail_t    = avail_t + cur_len[BYTE_AW:0];
            end

            // --- descriptor head register (FWFT over the sync-read ring) ---
            // Pop consumes the head; a ring read refills it. A read is issued only
            // when the head is (or is becoming) empty AND the ring holds a resident
            // committed descriptor. Because q_cnt is registered, the earliest a read
            // can launch is the cycle AFTER a commit — so dmem's write has landed and
            // the M10K read never races its own write (no read-during-write hazard).
            do_pop_head  = frame_pop && head_v;
            head_free_nx = (!head_v) || do_pop_head;
            do_issue     = head_free_nx && (q_cnt != 0);

            if (do_issue) begin
                head_desc <= dmem[d_rd];    // sync read → M10K output register
                head_v    <= 1'b1;
                d_rd      <= d_rd + 1'b1;
            end else if (do_pop_head) begin
                head_v    <= 1'b0;          // ring empty: head drains, no refill
            end

            // ring occupancy: +1 on commit, -1 when a resident is pulled into head
            case ({do_commit, do_issue})
                2'b10:   q_cnt <= q_cnt + 1'b1;
                2'b01:   q_cnt <= q_cnt - 1'b1;
                default: q_cnt <= q_cnt;
            endcase

            // --- stage 3: push the incoming byte ---
            // drop_cnt>0 forces "no room" so a new frame is dropped (reuses the overflow
            // path) - the menu-transition splice drop (drop_pulse below).
            has_space = (fill_t < BYTE_DEPTH[BYTE_AW:0]) && (drop_cnt == 3'd0);

            if (start) begin
                // first byte of a new frame
                frame_start_wrptr <= wr_addr;
                cur_type          <= aud_type;
                cur_pts           <= aud_frame_pts;        // stamp this frame's PES PTS
                cur_pts_valid     <= aud_frame_pts_valid;
                frame_open        <= 1'b1;
                if (has_space) begin
                    mem[wr_addr] <= aud_byte;
                    wr_ptr       <= wr_addr + 1'b1;
                    fill         <= fill_t + 1'b1;
                    cur_len      <= 1'b1;             // zero-extends to [BYTE_AW:0]
                    cur_dropping <= 1'b0;
                end else begin
                    wr_ptr       <= wr_addr;
                    fill         <= fill_t;
                    cur_len      <= '0;
                    cur_dropping <= 1'b1;             // no room from byte one
                end
            end else if (aud_valid && frame_open) begin
                // continuing byte of the current frame (wr_addr == wr_ptr here)
                if (!cur_dropping && has_space) begin
                    mem[wr_addr] <= aud_byte;
                    wr_ptr       <= wr_addr + 1'b1;
                    fill         <= fill_t + 1'b1;
                    cur_len      <= cur_len + 1'b1;
                end else begin
                    wr_ptr       <= wr_addr;
                    fill         <= fill_t;
                    cur_dropping <= 1'b1;             // ran out of room mid-frame
                end
            end else begin
                // no incoming byte this cycle
                wr_ptr <= wr_addr;
                fill   <= fill_t;
            end

            // --- menu-transition splice drop (drop_pulse) ---
            // Discard the truncated in-progress frame and arm the next few frames for
            // drop (ps_demux/reframer re-sync garbage). has_space above is forced 0 while
            // drop_cnt>0 so those frames drop via the overflow path; each frame_start
            // consumes one. Placed after the push chain so its cur_dropping wins.
            if (drop_pulse) begin
                drop_cnt <= 3'd4;
                if (frame_open) cur_dropping <= 1'b1;   // drop the truncated open frame
            end else if (start && drop_cnt != 3'd0) begin
                drop_cnt <= drop_cnt - 1'b1;
            end

            // --- reader byte pointer / counter (independent of push branch) ---
            avail <= avail_t;
            if (do_pop) rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule

`default_nettype wire
