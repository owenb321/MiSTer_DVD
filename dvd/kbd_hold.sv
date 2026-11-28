// ============================================================================
// dvd/kbd_hold.sv -- a keyboard / remote key: a TAP or a HOLD (docs/trick_play.md)
// ============================================================================
// Keyboard, CEC and IR-remote Fast Fwd / Rewind reach the core as press and release
// PULSES (dvd/kbd_map.sv). A tap must stay the 10 s jump (dvd/dpad_seek.sv); a hold
// must drive trick play like the gamepad's held B10/B11 (maintainer, 2026-11-24).
//
//   * A press starts a run. Gaps shorter than BRIDGE between a release and the next
//     press are part of the same run: a tap-repeating IR receiver sends key-down ->
//     80 ms -> key-up ~110 ms apart for a held button (dvd/kbd_map.sv header), so its
//     hold is a run of taps that this bridges into one.
//   * A run that lasts T_HOLD (still down, or bridged) is a HOLD: `held` rises and
//     stays up until the run ends.
//   * A run that ends (BRIDGE after its last release) before T_HOLD was a TAP: one
//     `tap` pulse then. A tap therefore fires BRIDGE after the release, not on the
//     press; dpad_seek's own 0.4 s coalescing window hides that.
//   * A lost release must not hold for ever: a key "down" for MAX_DOWN (60 s) with no event
//     ends the run (a press that never releases is a fault, not a gesture).
//
// Main drops keyboard auto-repeat (user_io.cpp, press > 1), so a held keyboard key is
// one press and, later, one release; CEC sends its release (with its own deadline).
// ============================================================================
`default_nettype none
module kbd_hold #(
    parameter integer BRIDGE   = 5_400_000,     // 200 ms at 27 MHz
    parameter integer T_HOLD   = 10_800_000,    // 400 ms
    parameter integer MAX_DOWN = 1_620_000_000  // 60 s with no event
) (
    input  wire clk,
    input  wire rst_n,
    input  wire press,       // pulse: key down
    input  wire release_,    // pulse: key up
    output reg  tap,         // pulse: a run shorter than T_HOLD ended
    output reg  held         // level: the run has lasted T_HOLD
);
    localparam [1:0] S_IDLE = 2'd0, S_DOWN = 2'd1, S_GAP = 2'd2;
    reg [1:0]  st;
    reg [31:0] run_t;        // since the run's first press
    reg [31:0] ev_t;         // since the last event (press: down time; release: gap)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; run_t <= 32'd0; ev_t <= 32'd0; tap <= 1'b0; held <= 1'b0;
        end else begin
            tap <= 1'b0;
            if (st != S_IDLE && run_t != 32'hFFFFFFFF) run_t <= run_t + 32'd1;
            if (st != S_IDLE && ev_t  != 32'hFFFFFFFF) ev_t  <= ev_t  + 32'd1;
            if (st != S_IDLE && run_t >= T_HOLD) held <= 1'b1;
            case (st)
                S_IDLE: if (press) begin st <= S_DOWN; run_t <= 32'd0; ev_t <= 32'd0; end
                S_DOWN: begin
                    if (release_)               begin st <= S_GAP; ev_t <= 32'd0; end
                    else if (press)             ev_t <= 32'd0;
                    else if (ev_t >= MAX_DOWN)  begin st <= S_IDLE; held <= 1'b0; end
                end
                S_GAP: begin
                    if (press)                  begin st <= S_DOWN; ev_t <= 32'd0; end
                    else if (ev_t >= BRIDGE) begin
                        st   <= S_IDLE;
                        tap  <= !held && (run_t < T_HOLD);
                        held <= 1'b0;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
