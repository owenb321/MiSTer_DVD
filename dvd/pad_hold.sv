// ============================================================================
// dvd/pad_hold.sv -- the gamepad's Fast Fwd / Rewind: a TAP or a HOLD (docs/trick_play.md)
// ============================================================================
// Maintainer, 2026-11-24: "quick tap should nudge 10s like the other modes". In a DVD
// film the pad's B10/B11 drove trick play straight from the level, so a tap entered and
// left trick play at once and showed nothing. Now, like the keyboard and remote
// (dvd/kbd_hold.sv):
//
//   * A press of exactly one of the two starts a run.
//   * Released before T_HOLD: one `tap_*` pulse at the release (emu.sv sends it to
//     dpad_seek's 10 s jump while trick play claims the buttons).
//   * Still down at T_HOLD: `held_*` rises and stays up until the release (trick_ctrl's
//     held level). No tap follows a hold.
//   * The other button joining the run (both down) is not a gesture: no tap, and a
//     hold already up drops, so trick_ctrl sees a release and exits.
//
// Unlike kbd_hold there is no bridge: the pad is a level from hps_io and never repeats.
// One shared counter (the two directions are exclusive): 24 bits holds 400 ms at 27 MHz.
// ============================================================================
`default_nettype none
module pad_hold #(
    parameter integer T_HOLD = 10_800_000     // 400 ms at 27 MHz
) (
    input  wire clk,
    input  wire rst_n,
    input  wire ff,           // level: B10 Fast Fwd
    input  wire rew,          // level: B11 Rewind
    output reg  tap_ff,       // pulse: Fast Fwd released before T_HOLD
    output reg  tap_rew,      // pulse: Rewind released before T_HOLD
    output reg  held_ff,      // level: Fast Fwd down for T_HOLD (until released)
    output reg  held_rew      // level: Rewind down for T_HOLD (until released)
);
    reg [23:0] t;
    reg        run, dir, both;          // dir: 0 = Fast Fwd, 1 = Rewind
    wire       cur = dir ? rew : ff;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t <= 24'd0; run <= 1'b0; dir <= 1'b0; both <= 1'b0;
            tap_ff <= 1'b0; tap_rew <= 1'b0; held_ff <= 1'b0; held_rew <= 1'b0;
        end else begin
            tap_ff  <= 1'b0;
            tap_rew <= 1'b0;
            if (!run) begin
                if (ff ^ rew) begin
                    run <= 1'b1; dir <= rew; both <= 1'b0; t <= 24'd0;
                end
            end else if (!cur) begin
                // the run's button released: a tap if it was short and alone
                run      <= 1'b0;
                held_ff  <= 1'b0;
                held_rew <= 1'b0;
                if (!both && !held_ff && !held_rew) begin
                    tap_ff  <= !dir;
                    tap_rew <=  dir;
                end
            end else begin
                if (ff && rew) begin
                    both     <= 1'b1;
                    held_ff  <= 1'b0;
                    held_rew <= 1'b0;
                end else if (!both && t >= T_HOLD - 1) begin
                    held_ff  <= !dir;
                    held_rew <=  dir;
                end
                if (t != 24'hFFFFFF) t <= t + 24'd1;
            end
        end
    end
endmodule
`default_nettype wire
