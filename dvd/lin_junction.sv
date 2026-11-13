// lin_junction.sv -- the linear-stream junction controller (issue #188).
//
// DVD-FORK (2026-11-12). A program end code (0xB9) on a LINEAR stream ends one MPEG
// stream, and whatever follows is a NEW stream with its own time base: a Philips
// CD-i Digital Video disc plays a ~10 s still-picture intro, then its movie with the
// audio PTS restarting at 0; a .cue serves several VCD tracks as one span. Played
// straight through, the new stream's first picture re-anchored the clock (the late
// leg) while the old stream's last ~1 s of audio was still queued; the new audio was
// then late on the new clock and held, the ~1 s ring backpressured the shared demux
// and starved the video, and the ~2.5 s arm_timer finally released audio against the
// wrong clock. MEASURED on the rig (HFRO disc 1, v0.10.0): video 2.5 s late and audio
// 3.8 s late for the whole movie, cleared only by a seek.
//
// ★ The fix is what DVD already does at a natural cell transition (docs/dvd_nav.md "A
// natural transition waits for the AUDIO too") and what a standalone player does
// between play items: let the old stream FINISH, then start the next one cold.
//   1. ps_demux parks on the 0xB9 (jn_wait) holding the next stream's first bytes.
//   2. This waits until the ring and decoder are drained (aud_drain) AND the VBUF is
//      empty, continuously for SETTLE so the pictures in flight are shown too.
//   3. It pulses `junction` -> flush_ctl: aud_flush + seek_flush, NOT load_flush
//      (flush_ctl row [12]). Nothing is buffered to lose, and the demux, its FIFO and
//      the reader keep the bytes they hold. emu also re-arms the STD video hold on it,
//      as a load does.
//   4. It waits out the 64-cycle flush and its 2-FF into clk_dec (FLUSH_W), then
//      pulses `go`, and the demux resumes on the next stream.
// ⚠ The reframers ARE reset (aud_flush -> rf_flush_q): the old stream's last frame
//   start can sit in their pipeline stamped with the OLD time base, and the new
//   stream's first bytes would push it into the fresh ring as its first frame (the
//   stale-PTS trap, docs/dvd_nav.md §2h).
// ⚠ WD bounds the wait: a decoder that never drains costs ~5 s, never a hang.
//   `timeouts` counts those, so a bench or telemetry can tell one from a clean drain.
// ⚠ rst_n is emu's pipe_rst_n: a seek or load during the wait resets the demux, which
//   ends the park, and resets this.

`default_nettype none

module lin_junction #(
    parameter int SETTLE_W = 23,   // 2^23 / 27 MHz ~ 0.31 s drained, continuously
    parameter int WD_W     = 27,   // 2^27 / 27 MHz ~ 5 s: flush anyway
    parameter int FLUSH_W  = 8     // 255 cycles > the 64-cycle flush + its CDC
) (
    input  wire       clk,         // clk_sys
    input  wire       rst_n,       // emu pipe_rst_n
    input  wire       jn_wait,     // ps_demux: parked after a 0xB9
    input  wire       aud_drained, // dvd/aud_drain.sv: ring empty, decoder not holding
    input  wire       vbuf_empty,  // emu: the VBUF's low-water mark
    output logic      junction,    // one clk: fire the junction flush (flush_ctl)
    output logic      go,          // one clk: release the demux
    output wire  [7:0] timeouts    // junctions flushed by WD, not by a drain (saturating)
);

    typedef enum logic [1:0] { IDLE, DRAIN, FLUSH } st_t;
    st_t st;
    logic [SETTLE_W-1:0] settle;
    logic [WD_W-1:0]     wd;
    logic [FLUSH_W-1:0]  ftmr;
    // survives the pipe resets (it is evidence across seeks); power-up 0
    logic [7:0]          to_cnt = 8'd0;
    assign timeouts = to_cnt;

    always_ff @(posedge clk) begin
        junction <= 1'b0;
        go       <= 1'b0;
        if (!rst_n) begin
            st <= IDLE;
        end else case (st)
            // !go: the demux leaves its park on the edge that SAMPLES the release,
            // so jn_wait still reads 1 here for that one cycle -- without the term
            // this would re-arm and flush the new stream ~SETTLE in.
            IDLE: if (jn_wait && !go) begin
                settle <= '0;
                wd     <= '0;
                st     <= DRAIN;
            end
            DRAIN: begin
                wd     <= wd + 1'b1;
                settle <= (aud_drained && vbuf_empty) ? settle + 1'b1 : '0;
                if ((&settle) || (&wd)) begin
                    junction <= 1'b1;
                    ftmr     <= '0;
                    st       <= FLUSH;
                    if (!(&settle) && !(&to_cnt)) to_cnt <= to_cnt + 8'd1;
                end
            end
            FLUSH: begin
                ftmr <= ftmr + 1'b1;
                if (&ftmr) begin
                    go <= 1'b1;
                    st <= IDLE;
                end
            end
            default: st <= IDLE;
        endcase
    end

endmodule

`default_nettype wire
