// =============================================================================
// dvd/cc_line21.sv — EIA-608 line-21 closed-caption inserter for the analog raster
// =============================================================================
// Takes the caption byte pairs the VLD sniffs out of MPEG-2 user_data
// (rtl/mpeg2/vld.v, `cc_pair_valid`) and re-injects them onto **line 21** of the
// native 15 kHz interlaced raster as the standard EIA-608 waveform, exactly as a
// real DVD player does — the television's own caption decoder does the rendering.
//
// WHY THIS AND NOT AN ON-SCREEN CHARACTER GENERATOR: decoding 608 in fabric needs
// a 32x15 character plane, a double-buffered char RAM and a font ROM grown past 64
// glyphs to carry lowercase — several hundred ALMs and 2-3 M10K on a fit already at
// 98% ALMs / 91% RAM (a branch has failed to route here before at 91%). This is a
// phase accumulator and a shift register. It is also what the hardware being
// emulated actually did. Trade-off: analog output only, and it depends on the
// viewer's TV having a decoder (every US set 13" and larger since 1993).
// See docs/closed_captions.md §4.
//
// -----------------------------------------------------------------------------
// PACING — the reason this is cheap
// -----------------------------------------------------------------------------
// Measured on real discs (docs/closed_captions.md §1): the caption block sits on
// the GOP header and `cc_count` counts DISPLAY frames, not coded pictures (15
// against 12 following pictures = 3:2 pulldown already expanded by the encoder).
// So one byte pair belongs to one displayed FIELD, and the correct clock to drain
// them on is the raster's own field rate. No PTS, no STC compare, no NCO trim:
// consume exactly one pair per field at line 21 and captions track the picture
// for free — including through governor drops and repeats, because the caption
// clock and the raster are then literally the same clock.
//
// Pairs carry their own field bit (marker bit 0: 1 = field 1 = CC1/CC2), so they
// are de-interleaved into two slots and each field serves its own. A disc that
// only ever emits field 1 (every disc measured) simply leaves the field-2 slot
// empty, and field 2 transmits nothing. An empty slot blanks line 21 rather than
// inventing a null pair — we transmit exactly the fields the disc provides.
//
// -----------------------------------------------------------------------------
// WAVEFORM (EIA-608-B)
// -----------------------------------------------------------------------------
//   7 cycles clock run-in | 3 start bits (0,0,1) | 16 data bits = 26 bit periods
//   bit rate  = 32 * fH = 503.4965 kHz
//   levels    : logic 1 = 50 IRE, logic 0 = blanking (0 IRE)
//   run-in    : sinusoid 25 - 25*cos(2*pi*phi) IRE, i.e. 0 IRE at the bit
//               boundaries, peaking 50 IRE at bit CENTRES — which is what aligns
//               the recovered clock with the data eyes (the standard defines the
//               data bit centres as the positive peaks of the run-in).
//   start     : run-in begins 10.5 us +/- 0.25 us after the leading edge of hsync.
//
// The dot clock makes this exact rather than approximate: 13.5 MHz = 858 * fH and
// the bit rate is 32 * fH, so one bit is 858/32 = 26.8125 dots EXACTLY. A 16-bit
// NCO stepping 2444 per dot realises that to +0.0002% (2^16*32/858 = 2443.995),
// which is nothing against a decoder PLL, and its top 4 bits index the run-in
// sine LUT for free.
//
// Placement: hsync leads at dot 735 of 858, so 10.5 us (141.75 dots) later is dot
// 18.75 of the NEXT line's active region -> CC_START = 19. The waveform is
// 26 * 26.8125 = 697.1 dots, ending at dot ~716 — inside the 720-dot active
// window with 4 dots to spare. (That is not luck: line 21 is specified to fit an
// active line.) The +/-1 dot of pipeline alignment is 74 ns against a +/-250 ns
// tolerance.
//
// Levels are driven equally on R, G and B = luma-only, zero colour difference, so
// the data appears on Y for a YPbPr/composite chain and carries no chroma.
//
// ⚠ HW-GATE ITEMS (derived, not yet measured on a set — docs/closed_captions.md §6):
//   * CC_START (19) and the line number itself are derived from the modeline.
//   * Run-in is a 16-entry sine. Data-bit TRANSITIONS are shaped through the
//     same half-cosine over ~500 ns (round 4: the first cut used hard square
//     edges — 74 ns steps against the spec's ~240 ns transition — and the HW
//     symptom was scattered dropped characters, i.e. parity failures at a
//     marginal slicer; 608 decoders DROP bad-parity bytes rather than print
//     garbage, so an over-sharp edge reads as missing letters, not noise).
// =============================================================================

`include "timescale.v"
`default_nettype none   // see the note in dvd/re_interlace.sv (round-3 lesson)

module cc_line21 (
    input             clk,             // clk_sys 27 MHz
    input             rst_n,
    input             ce2,             // 13.5 MHz clock enable (the dot clock)

    // ---- producer side: the VLD, in the clk_dec domain ----------------------
    input             dec_clk,
    input             dec_pair_valid,  // one pulse per caption byte pair
    input      [15:0] dec_pair,        // {cc_byte_1, cc_byte_2}
    input             dec_pair_field,  // 1 = field 1 (CC1/CC2)

    // ---- control (clk_sys) --------------------------------------------------
    input             enable,          // NTSC analog raster up and captions wanted
    input             flush,           // seek / new title: drop the backlog

    // ---- raster (clk_sys, ce2 dots) ----------------------------------------
    input      [11:0] hpos,            // dot within the line, 0..857
    input             cc_line,         // this line is line 21 for the current field
    input             field1,          // 1 = NTSC field 1 (the CC1/CC2 field)

    // ---- output ------------------------------------------------------------
    output     [7:0]  level,           // luma level for this dot
    output            level_en,        // drive `level` instead of normal video
    output            active           // diagnostics: a pair is being transmitted
);

// ---------------------------------------------------------------------------
// Timing constants
// ---------------------------------------------------------------------------
// ARM dot, not the emitted dot. Transmission begins 3 dots later: one for the
// arm-to-tx edge, one for cc_line21's own ce2 phase, one for re_interlace's
// output register. 10.5 us after the hsync leading edge is dot 18.75, so arming
// at 16 puts the first run-in dot on ~19 and keeps the +/-0.25 us (+/-3.4 dot)
// window centred instead of spending it on pipeline delay.
localparam [11:0] CC_START  = 12'd16;
localparam [15:0] NCO_INC   = 16'd2444;    // 2^16 * 32/858
localparam [4:0]  N_RUNIN   = 5'd7;
localparam [4:0]  N_BITS    = 5'd26;       // 7 run-in + 3 start + 16 data
localparam [4:0]  TRANS     = 5'd8;        // shaping window: 8/32 of a bit ≈ 6.7 dots ≈ 500 ns
localparam [7:0]  LVL_HI    = 8'd128;      // 50 IRE at 255 = 100 IRE

// ---------------------------------------------------------------------------
// Cross the pairs from clk_dec into clk_sys.
//
// Depth 128 against a worst case of 62 pairs per GOP block: the block arrives as
// one burst when the VLD parses the GOP header and then drains at 2 pairs per
// frame, so steady-state occupancy is about one GOP's worth. On overflow fifo_dc
// simply refuses the write — a lost caption line, self-healing on the next block,
// which is the right failure mode for a decorative side channel.
// ---------------------------------------------------------------------------
wire [16:0] fifo_dout;
wire        fifo_empty, fifo_valid;
reg         fifo_rd;

fifo_dc #(.dta_width(9'd17), .addr_width(9'd7))
cc_fifo (
    .rst        (rst_n),
    .wr_clk     (dec_clk),
    .din        ({dec_pair_field, dec_pair}),
    .wr_en      (dec_pair_valid),
    .full       (),
    .wr_ack     (),
    .overflow   (),
    .prog_full  (),
    .rd_clk     (clk),
    .dout       (fifo_dout),
    .rd_en      (fifo_rd),
    .empty      (fifo_empty),
    .valid      (fifo_valid),
    .underflow  (),
    .prog_empty ()
);

// ---------------------------------------------------------------------------
// De-interleave into one slot per field, and drain on flush.
//
// The pop is issued whenever a slot is empty and is NOT gated on ce2 — this runs
// at 27 MHz while the consumer takes 2 pairs per frame, so the slots are always
// refilled long before their line-21 slot comes round.
//
// A popped pair whose slot is still full is HELD in a 1-entry skid (hold_*) and
// placed when that slot frees; no further pop is issued while a pair is held, so
// order within each field is preserved and nothing is ever dropped. (The first
// cut DROPPED such pairs. Measured on real discs the loss was null-padding only
// — Matrix alternates perfectly, MiB bunches parity 7 times in 13 min, all nulls
// — but a mechanism that eats a caption pair on an authoring quirk has no
// business existing when a hold register deletes it. The held pair can always be
// placed eventually: its slot is consumed once per frame while enabled, and when
// disabled the FIFO simply backs up and refuses writes, same as before.)
// ---------------------------------------------------------------------------
reg [15:0] slot   [0:1];
reg [1:0]  slot_v;
reg        draining;
reg        rd_busy;                        // a pop is in flight (1-cycle latency)
reg        hold_v;                         // skid: a popped pair awaiting its slot
reg        hold_fld;
reg [15:0] hold_pair;

wire       head_fld = fifo_dout[16];
wire       want_pop = ~fifo_empty & ~rd_busy & ~hold_v &
                      (draining | ~slot_v[1] | ~slot_v[0]);

// Consume pulses, generated by the transmitter below.
reg  take;                                 // pop slot[field1] this cycle

always @(posedge clk) begin
    if (!rst_n) begin
        slot[0]  <= 16'd0;
        slot[1]  <= 16'd0;
        slot_v   <= 2'd0;
        draining <= 1'b0;
        rd_busy  <= 1'b0;
        hold_v   <= 1'b0;
        hold_fld <= 1'b0;
        hold_pair<= 16'd0;
        fifo_rd  <= 1'b0;
    end else begin
        fifo_rd <= 1'b0;

        if (flush) begin
            slot_v   <= 2'd0;
            hold_v   <= 1'b0;
            draining <= 1'b1;
        end else begin
            if (draining && fifo_empty && !rd_busy) draining <= 1'b0;

            if (want_pop) begin
                fifo_rd <= 1'b1;
                rd_busy <= 1'b1;
            end
            if (fifo_valid) begin
                rd_busy <= 1'b0;
                if (!draining) begin
                    if (!slot_v[head_fld]) begin
                        slot[head_fld]   <= fifo_dout[15:0];
                        slot_v[head_fld] <= 1'b1;
                    end else begin
                        hold_v    <= 1'b1;        // skid, place when the slot frees
                        hold_fld  <= head_fld;
                        hold_pair <= fifo_dout[15:0];
                    end
                end
            end
            // place a held pair the moment its slot is (or becomes) free —
            // checked after take below so a same-cycle consume frees the way
            if (hold_v && (!slot_v[hold_fld] || (take && field1 == hold_fld))) begin
                slot[hold_fld]   <= hold_pair;
                slot_v[hold_fld] <= 1'b1;
                hold_v           <= 1'b0;
            end
            else if (take) slot_v[field1] <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// Transmitter — advances on ce2 so it stays dot-aligned with sg_hpos, and its
// outputs are combinational from those registers so they land in re_interlace's
// output register on the same edge as the pixel they replace.
// ---------------------------------------------------------------------------
reg [15:0] phase;
reg [4:0]  bitidx;
reg [18:0] ser;                            // {byte2, byte1, start bits 0,0,1}
reg        tx;

// Explicit carry-out rather than a wrap-around comparison: the bit boundary is
// the NCO overflow, and saying so in 17 bits leaves nothing to infer.
wire [16:0] phase_nxt = {1'b0, phase} + {1'b0, NCO_INC};
wire [4:0]  substep   = phase[15:11];      // 32 substeps per bit period (shaping clock)

wire arm = enable & cc_line & slot_v[field1] & (hpos == CC_START) & ~tx;

always @(posedge clk) begin
    if (!rst_n) begin
        phase  <= 16'd0;
        bitidx <= 5'd0;
        ser    <= 19'd0;
        tx     <= 1'b0;
        take   <= 1'b0;
    end else begin
        take <= 1'b0;
        if (!enable || flush) begin
            tx <= 1'b0;
        end else if (ce2) begin
            if (arm) begin
                // Transmission order is LSB first per byte, byte 1 then byte 2,
                // behind the three start bits.
                ser    <= {slot[field1][7:0], slot[field1][15:8], 3'b100};
                phase  <= 16'd0;
                bitidx <= 5'd0;
                tx     <= 1'b1;
                take   <= 1'b1;
            end else if (tx) begin
                phase <= phase_nxt[15:0];
                // bit N_BITS is a virtual forced-zero TAIL bit: the generic edge
                // shaping below ramps the last data bit down instead of cutting a
                // logic-1 off with a cliff; tx ends once its ramp completes.
                if (bitidx == N_BITS && substep >= TRANS) tx <= 1'b0;
                else if (phase_nxt[16])                   // NCO wrap = bit boundary
                    bitidx <= bitidx + 5'd1;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Level: run-in sine for the first 7 bit periods; data bits with SHAPED edges.
// One shared half-cosine LUT — round(64 - 64*cos(2*pi*k/16)) — serves both: the
// run-in walks all 16 entries per bit (0 at the edges, 128 at the centres, which
// is what aligns the recovered clock with the data eyes), and each data-bit
// TRANSITION walks entries 0..8 (a monotone 0->128 half-cosine) across the first
// TRANS substeps of the bit, ~310 ns — near the spec's transition time, and a
// world away from the 74 ns square step of the first cut (see the header note).
// Consecutive equal bits hold their plateau; only real transitions are shaped.
// ---------------------------------------------------------------------------
function [7:0] coslut(input [3:0] k);
    case (k)
    4'd0:  coslut = 8'd0;    4'd1:  coslut = 8'd5;    4'd2:  coslut = 8'd19;   4'd3:  coslut = 8'd40;
    4'd4:  coslut = 8'd64;   4'd5:  coslut = 8'd88;   4'd6:  coslut = 8'd109;  4'd7:  coslut = 8'd123;
    4'd8:  coslut = 8'd128;  4'd9:  coslut = 8'd123;  4'd10: coslut = 8'd109;  4'd11: coslut = 8'd88;
    4'd12: coslut = 8'd64;   4'd13: coslut = 8'd40;   4'd14: coslut = 8'd19;   4'd15: coslut = 8'd5;
    endcase
endfunction

// Index clamped so the part-select is always in range; the muxes below are what
// actually select run-in vs data vs tail, but an out-of-range select would read
// X and propagate through a mux in simulation.
wire [4:0] ser_idx  = (bitidx >= N_RUNIN) ? (bitidx - N_RUNIN) : 5'd0;
wire       data_bit = (bitidx >= N_BITS) ? 1'b0 : ser[ser_idx];      // tail bit = 0
wire       prev_bit = (bitidx == N_RUNIN) ? 1'b0 :                   // run-in ends at 0
                      (ser_idx != 5'd0)   ? ser[ser_idx - 5'd1] : 1'b0;

// rising edge walks LUT 0..8 (0->128) one entry per substep; falling walks 8..0.
// One entry per substep keeps the per-dot level delta <= ~48 (substeps advance
// ~1.19/dot); the first cut stepped two entries per substep and produced 90-level
// hops — sharper than the shaping it was meant to provide.
wire       in_trans = (substep < TRANS) && (data_bit != prev_bit);
wire [3:0] ramp_idx = data_bit ? {1'b0, substep[2:0]}
                               : (4'd8 - {1'b0, substep[2:0]});
wire [7:0] data_lvl = in_trans ? coslut(ramp_idx)
                               : (data_bit ? LVL_HI : 8'd0);

assign     level    = (bitidx < N_RUNIN) ? coslut(phase[15:12]) : data_lvl;
assign     level_en = tx;
assign     active   = tx;

endmodule

`default_nettype wire
