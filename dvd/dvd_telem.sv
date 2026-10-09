//============================================================================
// dvd_telem.sv -- core -> HPS telemetry over the hps_io EXT_BUS extension.
//
// Reads out the decoder's pacing counters so a host-side tool can measure them
// directly, instead of photographing the debug overlay. Built for the
// hardware-in-the-loop harness (docs/hil_harness.md); the immediate question is
// whether the display governor shows each content frame for exactly SHOW_N
// refreshes on average, which a measured drift of ~450 ppm says it may not.
//
// WHY EXT_BUS AND NOT status_in
// hps_io exposes status_in/status_set, which looks like the obvious channel and
// is not: stock Main polls UIO_GET_STATUS every frame and writes the result
// straight into cur_status (Main_MiSTer/user_io.cpp:2640), so a core driving it
// would overwrite the user's OSD settings. EXT_BUS is the sanctioned
// core-specific extension -- hps_io passes the bus through and lets the core
// drive HPS_BUS[15:0] whenever it asserts EXT_BUS[32] (sys/hps_io.sv:220).
//
// PROTOCOL (mirrors hps_io's own command handling)
//   io_enable frames a transaction; io_strobe clocks one 16-bit word.
//   The FIRST strobe carries the command in io_din. If it is CMD we take the
//   bus for the rest of the transaction and answer with:
//     word 0  MAGIC          -- so the host can tell a real reply from a stuck
//                               bus or another core; checked before use
//     word 1  refreshes      -- raster vsyncs
//     word 2  pickups        -- content frames picked up for display
//     word 3  lates          -- governor deadline misses
//     word 4  drops          -- pictures dropped
//     word 5  aud_disc       -- {skip[7:0], catch-up[3:0], re-arms[3:0]} (was vid_err,
//                               retired by PR #63; the port keeps its name)
//     word 6  {debt, drop_costs}
//     word 7  {vbuf_fill, flags}   -- flags[5] = the field blend is on the scan under way
//                                     flags[6]/[7] = the last TIME seek used the disc's time
//                                     map / fell back to its sector estimate (issue #127)
//     word 8  aud_frames     -- audio frames queued
//     word 9  aud_play       -- audio play ticks / 16 (what reaches the DAC)
//     word 10 aud_gate       -- drain-gate closures
//     word 11 disp_lag       -- SIGNED, PTS of the picture just DISPLAYED - STC, 1 LSB = 16 ticks
//     word 12 play_err       -- SIGNED, audio playback position vs its anchor, same scale
//     word 13 av_drift       -- SIGNED, dispatched audio PTS - STC, same scale
//     word 14 sched_flags    word 15 sched_dur (debug layout, see dvd_ctl.cpp; word 14
//                               bit 8 = bob active, bit 9 = disc prohibits every region,
//                               bits 10/11 = VMGI/VTSI read from its .BUP, bit 12 = an
//                               IFO header bad with no good .BUP -- docs/dvd_nav.md)
//     word 16 DUTY_MAGIC     -- says words 17..20 exist. ⚠ A core built before them
//                               answers strobes past 15 with word 15 AGAIN (wcnt
//                               saturated at 4'hF), not with zero, so the reader
//                               must check this marker before trusting 17..20.
//     words 17..20 dec_duty  -- free-running clk_dec cycle counts / 4096 of where
//                               the decoder's time goes: parked on the display,
//                               starved of bitstream, stalled by the decode pipe,
//                               recon waiting on reference pixels (dvd/dec_duty.sv,
//                               docs/decode_pacing.md). They move at most once per
//                               4096 clk_dec cycles, so the two-agree sampler holds.
//     word 21 PIC_MAGIC      -- says words 22..24 exist. A SECOND marker rather than a
//                               new value at word 16, so a Main that knows only DD01
//                               keeps reading 17..20; a core built before these words
//                               answers 0 past word 20 (wcnt is 5 bits), never the marker.
//     word 22 pic_max        -- longest single-picture decode in the last 0.83 s
//                               window, cycles/4096 (dec_duty; changes once a window)
//     word 23 pic_n          -- pictures decoded (wraps)
//     word 24 pic_over       -- ... that took longer than one frame period (wraps)
//     word 25 AUD_MAGIC      -- says words 26..30 exist (the audio engine; docs/dts_decoder.md)
//     word 26 dts_flags      -- [0] codebooks copied, [1] their checksum matched (tables_ok:
//                               DTS decodes), [2] the engine runs DTS, [12:8] last refusal
//     word 27 cb_sum[31:16]  word 28 cb_sum[15:0] -- the copy's checksum (D4 rule 2)
//     word 29 eng_frames     -- frames the engine decoded (AC-3 + DTS, wraps)
//     word 30 eng_refused    -- frames it refused (wraps)
//     word 31 field_par      -- {1, fb_heals[6:0], strict_waits[7:0]} (docs/field_parity.md
//                               "Strict first field"). Bit 15 is a FORMAT bit, not data: a
//                               core built before this word answers 0 here, which a Main
//                               must not read as "zero heals". fb_heals = the field-parity
//                               corrector's FEEDBACK insertions (the ~0.5 s heal), strict_waits
//                               = frame-top slots the mixer's strict first-field placement
//                               refused. Both wrap and survive soft resets (hard_rst only).
//                               ⚠ The LAST word: wcnt is 5 bits and saturates at 31, so a
//                               further word needs a wider counter, not a new index.
//   Word 11 is the measurement docs/av_sync.md "THE STC IS A CLOCK" is built
//   on: the picture on SCREEN against the clock the audio is scheduled by. It
//   is ~0 when the display is scheduled by PTS (Stage 1) and reads the whole
//   buffering lead (about -1 s in Film 24p) before that.
//   Word 9 over word 1 is the audio-vs-raster ratio, the companion to
//   refreshes/pickups: both are ratios of counters in ONE clock domain, so
//   neither needs an external reference or an assumption about which clock is
//   right.
//   All counters are free-running 16-bit and WRAP; the host unwraps. Word 1
//   over word 2 is the number this exists to answer: for 29.97 content on a
//   59.94 Hz raster it must be exactly 2.000.
//
// ⚠ THE SNAPSHOT IS ATOMIC, and it has to be. The counters live in three clock
// domains and advance while the transaction runs; reading them one word at a
// time would mix samples taken milliseconds apart and turn a ratio of exactly
// 2.000 into noise. They are latched together on the command strobe.
//
// ⚠ CDC IS A STABILITY FILTER, NOT A PLAIN 2-FF SYNC. These are multi-bit
// BINARY counters from clk_dec/clk_mem: catching one mid-increment can read
// 0x00FF as 0x01FF -- not a small error, a wild one, and a single bad sample
// corrupts a rate measurement. The sampler commits a value only when two
// consecutive samples agree, which is cheap and sufficient because nothing here
// advances faster than ~60 Hz against a 27 MHz clock.
//============================================================================

// (telem_sync, the per-source 3-register filter, was retired by the 2026-09-10
//  area pass in favour of the shared round-robin sampler inside dvd_telem.)


module dvd_telem #(
    parameter [15:0] CMD   = 16'h007A,   // free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9
    // A SECOND command, for state Main needs in order to act rather than to log.
    // It is answered on the same EXT_BUS and is deliberately NOT part of the 0x7A
    // snapshot: that one is diagnostic telemetry whose HPS reader is gated behind
    // the /media/fat/dvd_hil arm file, so a feature that depended on it would work
    // only on a rig set up for hardware-in-the-loop testing.
    parameter [15:0] CMD_AF = 16'h007B,
    parameter [15:0] MAGIC = 16'hD7D1,
    parameter [15:0] DUTY_MAGIC = 16'hDD01,  // word 16: dec_duty words 17..20 follow
    parameter [15:0] PIC_MAGIC  = 16'hDD02,  // word 21: dec_duty per-picture words 22..24 follow
    parameter [15:0] AUD_MAGIC  = 16'hDD03   // word 25: the audio engine's words 26..30 follow
) (
    input         clk,

    // --- EXT_BUS side (from hps_io) -------------------------------------
    input         io_enable,             // EXT_BUS[34]
    input         io_strobe,             // EXT_BUS[33]
    input  [15:0] io_din,                // EXT_BUS[31:16]
    output        drive,                 // -> EXT_BUS[32]
    output [15:0] dout,                  // -> EXT_BUS[15:0]

    // --- counters (asynchronous to clk; see the CDC note above) ---------
    input  [15:0] refreshes,
    input  [15:0] pickups,
    input  [15:0] lates,
    input  [15:0] drops,
    input  [15:0] vid_err,
    input  [15:0] drop_costs,            // {debt[4:0], drop_req, probe} as emu packs it
    input   [7:0] vbuf_fill,
    input  [15:0] aud_frames,
    input   [7:0] flags,
    input  [15:0] aud_play,
    input  [15:0] aud_gate,
    // A/V phase, SIGNED, the source value's bits [19:4] (1 LSB = 16 ticks of
    // the 90 kHz STC = 0.178 ms, full scale +/-5.8 s). Do NOT take [15:0]: that
    // wraps at +/-0.36 s and cannot represent the offsets these exist to show.
    input  [15:0] disp_lag,              // word 11: PTS of the picture just DISPLAYED - STC
    input  [15:0] play_err,              // word 12: audio playback position vs its anchor
    input  [15:0] av_drift,              // word 13: dispatched audio PTS - STC
    input  [15:0] sched_flags,           // word 14: {frame_rate_code, ps, pf, tff, rff} at the last pickup
    input  [15:0] sched_dur,              // word 15: the duration the scheduler applied, ticks
    input  [15:0] dec_disp,              // word 17: VLD parked on the display (cycles/4096)
    input  [15:0] dec_starve,            // word 18: no bitstream to parse
    input  [15:0] dec_back,              // word 19: parse stalled by the decode pipeline
    input  [15:0] dec_ref,               // word 20: recon waiting on reference pixels
    input  [15:0] dec_pic_max,           // word 22: longest picture decode, last window (cycles/4096)
    input  [15:0] dec_pic_n,             // word 23: pictures decoded
    input  [15:0] dec_pic_over,          // word 24: ... over one frame period
    input  [15:0] dts_flags,             // word 26
    input  [31:0] cb_sum,                // words 27, 28
    input  [15:0] eng_frames,            // word 29
    input  [15:0] eng_refused,           // word 30
    input  [15:0] field_par,             // word 31: {1, fb_heals[6:0], strict_waits[7:0]}

    // --- audio link format (CMD_AF) -------------------------------------
    // What the wire is actually carrying, which is NOT what the OSD bit says: in
    // Passthru an LPCM or MP2 track leaves as linear PCM, and the ADV7513 has to
    // be taken out of non-PCM mode for it. Main polls this to decide.
    // ⚠ Bit 15 is a FORMAT VERSION, not data. A core built before bs_session
    // existed answers with it clear, and Main must then fall back to the old
    // !pcm_session rule -- the two cannot be told apart otherwise, because an
    // old core and a new idle one both answer "pcm_session = 0".
    input         af_passthru,            // Audio Out = Passthru
    input         af_pcm_session,         // ...and the current content is LPCM/MP2
    input         af_bs_session,          // ...and the current content IS AC-3/DTS

    // --- core -> Main REQUESTS, on the same CMD_AF word ------------------
    // The DVD-remote Eject and Volume buttons (B19..B21) are things only the
    // HPS can do: Main owns the mount slot, the optical drive, and sys_top's
    // vol_att (which attenuates I2S, the analog DAC and S/PDIF together).
    // ⚠ NOT levels. Main polls this word at its own rate, so a level would be
    // re-read as a fresh request on every poll -- one press would eject over
    // and over. Eject is a TOGGLE (edge-detected by Main) and the two volume
    // requests are WRAPPING COUNTERS, so Main applies the DIFFERENCE since its
    // last poll: a burst of presses between two polls still yields the right
    // number of steps, and a missed poll is caught up rather than lost.
    // ⚠ Bit 12 is a FORMAT VERSION for exactly the reason bit 15 is: a core
    // built before these existed answers with the field clear, which is
    // indistinguishable from "no request" unless Main is told the field is
    // there at all.
    input         rq_eject_tgl,           // flips once per Eject press
    input  [3:0]  rq_volup_seq,           // +1 per Vol Up press (wraps)
    input  [3:0]  rq_voldn_seq            // +1 per Vol Down press (wraps)
);

    // ---- ONE round-robin two-consecutive-agree sampler (area pass 2026-09-10) --
    // This used to be 19 telem_sync instances, each holding s1/s2/q = three
    // copies of its word (864 flops for 288 bits of data). The filter needs
    // two consecutive samples of ONE source to agree; nothing here changes
    // faster than ~60 Hz, so one sampler can walk the sources in turn (19
    // then; NSRC now) -- sample source n at cycle A, sample it again at cycle
    // B, commit q[n] at C if the two registered samples agree -- and every q
    // is refreshed every 3*NSRC cycles (72 = 2.7 us at 27 MHz). Same filter, same
    // registered-sample commit (never the raw asynchronous input), 1/3 the
    // flops. The atomic snapshot below is untouched: q[] is latched together
    // on the command strobe exactly as the 19 outputs were.
    localparam int NSRC = 30;
    wire [15:0] src [0:NSRC-1];
    assign src[0]  = refreshes;
    assign src[1]  = pickups;
    assign src[2]  = lates;
    assign src[3]  = drops;
    assign src[4]  = vid_err;
    assign src[5]  = drop_costs;
    assign src[6]  = aud_frames;
    assign src[7]  = {8'd0, vbuf_fill};
    assign src[8]  = {8'd0, flags};
    assign src[9]  = aud_play;
    assign src[10] = aud_gate;
    assign src[11] = disp_lag;
    assign src[12] = play_err;
    assign src[13] = av_drift;
    assign src[14] = sched_flags;
    assign src[15] = sched_dur;
    // CMD_AF word layout:
    //   [15]    format v2  -- this word carries bit 2 (bs_session)
    //   [14:13] spare
    //   [12]    format v3  -- this word carries [11:3] (the remote requests)
    //   [11:8]  Vol Down request counter
    //   [7:4]   Vol Up   request counter
    //   [3]     Eject request toggle
    //   [2]     bitstream session   [1] PCM session   [0] Passthru
    // See the port comments for why the requests are a toggle and counters
    // rather than levels, and why bit 12 has to exist.
    assign src[16] = {1'b1, 2'd0, 1'b1,
                      rq_voldn_seq, rq_volup_seq, rq_eject_tgl,
                      af_bs_session, af_pcm_session, af_passthru};
    assign src[17] = dec_disp;
    assign src[18] = dec_starve;
    assign src[19] = dec_back;
    assign src[20] = dec_ref;
    assign src[21] = dec_pic_max;
    assign src[22] = dec_pic_n;
    assign src[23] = dec_pic_over;
    assign src[24] = dts_flags;
    assign src[25] = cb_sum[31:16];
    assign src[26] = cb_sum[15:0];
    assign src[27] = eng_frames;
    assign src[28] = eng_refused;
    assign src[29] = field_par;

    reg  [4:0]  cur;                        // source being sampled
    reg  [1:0]  sph;                        // 0: sample A, 1: sample B, 2: compare+commit
    reg  [15:0] s1, s2;
    reg  [15:0] q [0:NSRC-1];
    integer qi;
    // Power-up state (this module has no reset; telem_sync never needed one
    // because its samplers free-ran, but a walk needs a defined cursor).
    initial begin
        cur = 5'd0; sph = 2'd0;
        for (qi = 0; qi < NSRC; qi = qi + 1) q[qi] = 16'd0;
    end
    always @(posedge clk) begin
        case (sph)
            2'd0: begin s1 <= src[cur]; sph <= 2'd1; end
            2'd1: begin s2 <= src[cur]; sph <= 2'd2; end
            default: begin
                if (s1 == s2) q[cur] <= s2;   // commit only a value seen twice running
                cur <= (cur == NSRC - 1) ? 5'd0 : cur + 5'd1;
                sph <= 2'd0;
            end
        endcase
    end

    wire [15:0] s_refresh = q[0],  s_pickup = q[1],  s_late  = q[2],  s_drop  = q[3];
    wire [15:0] s_viderr  = q[4],  s_costs  = q[5],  s_aud   = q[6];
    wire  [7:0] s_vbuf    = q[7][7:0], s_flags = q[8][7:0];
    wire [15:0] s_play    = q[9],  s_gate   = q[10];
    wire [15:0] s_dlag    = q[11], s_perr   = q[12], s_drift = q[13];
    wire [15:0] s_sfl     = q[14], s_sdu    = q[15];
    wire [15:0] s_afmt    = q[16];
    wire [15:0] s_ddisp   = q[17], s_dstarve = q[18], s_dback = q[19], s_dref = q[20];
    wire [15:0] s_pmax    = q[21], s_pn      = q[22], s_pover = q[23];
    wire [15:0] s_dflags  = q[24], s_sumhi   = q[25], s_sumlo = q[26];
    wire [15:0] s_efr     = q[27], s_eref    = q[28];
    wire [15:0] s_fpar    = q[29];

    reg  [4:0] wcnt;
    reg        active;
    reg [15:0] dout_r;

    // the atomic snapshot
    reg [15:0] q1, q2, q3, q4, q5, q6, q7, q8, q9, q10, q11, q12, q13, q14, q15;
    reg [15:0] q17, q18, q19, q20, q22, q23, q24, q26, q27, q28, q29, q30, q31;
    reg [15:0] q_afmt;
    reg        af_sel;

    always @(posedge clk) begin
        if (!io_enable) begin
            wcnt   <= 5'd0;
            active <= 1'b0;
            af_sel <= 1'b0;
            dout_r <= 16'd0;
        end else if (io_strobe) begin
            if (wcnt == 5'd0) begin
                active <= (io_din == CMD) || (io_din == CMD_AF);
                af_sel <= (io_din == CMD_AF);
                q1 <= s_refresh;
                q2 <= s_pickup;
                q3 <= s_late;
                q4 <= s_drop;
                q5 <= s_viderr;
                q6 <= s_costs;
                q7 <= {s_vbuf, s_flags};
                q8 <= s_aud;
                q9 <= s_play;
                q10 <= s_gate;
                q11 <= s_dlag;
                q12 <= s_perr;
                q13 <= s_drift;
                q14 <= s_sfl;
                q15 <= s_sdu;
                q17 <= s_ddisp;
                q18 <= s_dstarve;
                q19 <= s_dback;
                q20 <= s_dref;
                q22 <= s_pmax;
                q23 <= s_pn;
                q24 <= s_pover;
                q26 <= s_dflags;
                q27 <= s_sumhi;
                q28 <= s_sumlo;
                q29 <= s_efr;
                q30 <= s_eref;
                q31 <= s_fpar;
                q_afmt <= s_afmt;
                dout_r <= MAGIC;
            end else begin
                if (af_sel) dout_r <= (wcnt == 5'd1) ? q_afmt : 16'd0;
                else
                case (wcnt)
                    5'd1:    dout_r <= q1;
                    5'd2:    dout_r <= q2;
                    5'd3:    dout_r <= q3;
                    5'd4:    dout_r <= q4;
                    5'd5:    dout_r <= q5;
                    5'd6:    dout_r <= q6;
                    5'd7:    dout_r <= q7;
                    5'd8:    dout_r <= q8;
                    5'd9:    dout_r <= q9;
                    5'd10:   dout_r <= q10;
                    5'd11:   dout_r <= q11;
                    5'd12:   dout_r <= q12;
                    5'd13:   dout_r <= q13;
                    5'd14:   dout_r <= q14;
                    5'd15:   dout_r <= q15;
                    5'd16:   dout_r <= DUTY_MAGIC;
                    5'd17:   dout_r <= q17;
                    5'd18:   dout_r <= q18;
                    5'd19:   dout_r <= q19;
                    5'd20:   dout_r <= q20;
                    5'd21:   dout_r <= PIC_MAGIC;
                    5'd22:   dout_r <= q22;
                    5'd23:   dout_r <= q23;
                    5'd24:   dout_r <= q24;
                    5'd25:   dout_r <= AUD_MAGIC;
                    5'd26:   dout_r <= q26;
                    5'd27:   dout_r <= q27;
                    5'd28:   dout_r <= q28;
                    5'd29:   dout_r <= q29;
                    5'd30:   dout_r <= q30;
                    5'd31:   dout_r <= q31;
                    default: dout_r <= 16'd0;
                endcase
            end
            if (wcnt != 5'h1F) wcnt <= wcnt + 5'd1;
        end
    end

    assign drive = active;
    assign dout  = dout_r;

endmodule
