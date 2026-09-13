// ============================================================================
// bench/dvd/ab_repeat_tb.sv -- A-B repeat
// ============================================================================
// [B5] is the load-bearing arm: marking or comparing inside the stale-DSI
// window must do NOTHING. nav_dsi's rst_n is pipe_rst_n, so every seek clears
// dsi_nv_pck_lbn to 0 while the tables keep the last VOBU -- and A-B repeat
// seeks by construction, so it lives in that window. Marking there stores a
// bogus point; comparing there fires a jump the instant the loop-back lands,
// which is an infinite seek storm.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module ab_repeat_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        ab_edge = 0, in_title = 1, dsi_commit = 0, nav_flush = 0, cancel = 0;
    reg [31:0] cur_rbn = 32'd1000;

    wire        jump_fire, jump_dir, evt;
    wire [31:0] jump_base, jump_off;
    wire [1:0]  state_o;

    ab_repeat dut (
        .clk(clk), .rst_n(rst_n), .ab_edge(ab_edge), .in_title(in_title),
        .cur_rbn(cur_rbn), .dsi_commit(dsi_commit), .nav_flush(nav_flush),
        .cancel(cancel), .jump_fire(jump_fire), .jump_base(jump_base),
        .jump_off(jump_off), .jump_dir(jump_dir), .state_o(state_o), .evt(evt)
    );

    integer errors = 0, fires = 0;
    reg [31:0] last_base, last_off;
    always @(posedge clk) if (jump_fire) begin
        fires = fires + 1; last_base = jump_base; last_off = jump_off;
    end

    task p_ab;     begin @(negedge clk); ab_edge=1;    @(negedge clk); ab_edge=0;    @(posedge clk); end endtask
    task p_dsi;    begin @(negedge clk); dsi_commit=1; @(negedge clk); dsi_commit=0; @(posedge clk); end endtask
    task p_flush;  begin @(negedge clk); nav_flush=1;  @(negedge clk); nav_flush=0;  @(posedge clk); end endtask
    task p_cancel; begin @(negedge clk); cancel=1;     @(negedge clk); cancel=0;     @(posedge clk); end endtask
    task at(input [31:0] r); begin @(negedge clk); cur_rbn = r; @(posedge clk); @(posedge clk); end endtask

    task chki(input [70*8-1:0] lbl, input integer got, input integer want);
        begin
            if (got !== want) begin errors=errors+1;
                $display("  FAIL %0s: got %0d want %0d", lbl, got, want);
            end else $display("  ok   %0s", lbl);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        p_dsi;                                   // tables are fresh

        // Deterministic setup helper: clear whatever state we are in, then
        // mark A and B and leave the playhead INSIDE the loop with the lockout
        // clear. Without the "move back inside" step, marking B at the current
        // playhead position satisfies (cur >= B) on the spot and the loop fires
        // during setup -- which is correct behaviour, but it makes every later
        // count ambiguous.
        // (task, not inline, because the first draft of this bench open-coded it
        // and each section silently inherited the previous one's state.)

        // ---- [B1] the three-press cycle ---------------------------------
        $display("== B1: press cycles off -> A -> armed -> off");
        p_cancel; p_dsi;
        at(32'd1000); p_ab; chki("B1a A set",   state_o, 1);
        at(32'd2000); p_ab; chki("B1b armed",   state_o, 2);
                      p_ab; chki("B1c cleared", state_o, 0);

        // ---- [B2] the loop actually loops -------------------------------
        $display("== B2: reaching B jumps back to A");
        p_cancel; p_dsi;
        at(32'd1000); p_ab;
        at(32'd2000); p_ab;
        at(32'd1500);                            // back inside the loop
        fires = 0;
        at(32'd2000);                            // playhead arrives at B
        chki("B2a one jump", fires, 1);
        chki("B2b base = playhead", last_base, 2000);
        chki("B2c offset = B-A",    last_off, 1000);
        // ⚠ 0 = BACKWARD. This is scrub_ctrl's contract (dvd/scrub_ctrl.sv:174
        // "jump_dir  // 1 = forward"), NOT a convention ab_repeat gets to pick.
        // The first version of this arm asserted 1 because the RTL drove 1 --
        // bench and RTL sharing one wrong belief, which is why it took hardware
        // to find (the loop jumped forward and clamped to the title end).
        chki("B2d backwards (0)",   jump_dir, 0);

        // ---- [B3] ONE jump per pass, not one per cycle -------------------
        // The playhead keeps reading near B for the frames before the seek
        // lands; without the lockout that is a seek storm.
        $display("== B3: the lockout stops a seek storm");
        fires = 0;
        repeat (20) at(32'd2100);                // still past B, seek not landed
        chki("B3a no repeat while past B", fires, 0);
        at(32'd1000);                            // loop-back landed
        at(32'd2000);                            // and comes round again
        chki("B3b next pass jumps again", fires, 1);

        // ---- [B4] B before A re-marks A instead of arming an empty loop --
        $display("== B4: a second press BEFORE A re-marks A");
        p_cancel; p_dsi;
        at(32'd5000); p_ab;   chki("B4a A at 5000", state_o, 1);
        at(32'd4000); p_ab;   chki("B4b still 'A set', not armed", state_o, 1);
        chki("B4c A re-marked", dut.pt_a, 4000);

        // ---- [B5] THE ONE THAT MATTERS: the stale-DSI window -------------
        $display("== B5: nothing happens while the DSI tables are stale");
        p_cancel;
        p_flush;                                 // a seek: scalars cleared, stale
        at(32'd0);                               // dsi_nv_pck_lbn reads 0
        p_ab;
        chki("B5a marking A is refused while stale", state_o, 0);
        p_dsi; at(32'd1000); p_ab;               // fresh again
        at(32'd2000); p_ab;
        at(32'd1500);
        chki("B5b armed once fresh", state_o, 2);
        fires = 0;
        p_flush; at(32'd0);                      // stale, playhead reads 0
        repeat (10) @(posedge clk);
        chki("B5c no jump fired against a stale 0", fires, 0);

        // ---- [B6] leaving the title drops the loop ----------------------
        $display("== B6: cancel / leaving a title clears it");
        p_cancel; p_dsi;
        at(32'd1000); p_ab; at(32'd2000); p_ab; at(32'd1500);
        chki("B6a armed", state_o, 2);
        p_cancel;
        chki("B6b cancel cleared it", state_o, 0);
        p_dsi; at(32'd1000); p_ab; at(32'd2000); p_ab; at(32'd1500);
        @(negedge clk); in_title = 0; repeat (3) @(posedge clk);
        chki("B6c leaving the title cleared it", state_o, 0);
        @(negedge clk); in_title = 1;

        // ---- [B7] the stale window after OUR OWN loop-back seek ----------
        // This is the arm that actually needs the freshness guard on the
        // COMPARE, and the first mutation round showed why B5c is not enough:
        // a stale 0 is BELOW B, so it can never trigger the compare directly.
        // The damage is to the LOCKOUT. The loop-back seek we just issued
        // flushes nav_dsi, cur_rbn drops to 0, and an unguarded lockout clears
        // on the spot (0 < B) -- so when the parse front comes back still
        // reading past B, before the seek has really landed, the module fires
        // a SECOND jump. That is the seek storm, one level down.
        $display("== B7: our own seek's flush must not re-arm the loop");
        p_cancel; p_dsi;
        at(32'd1000); p_ab; at(32'd2000); p_ab; at(32'd1500);
        fires = 0;
        at(32'd2000);
        chki("B7a the loop fired once", fires, 1);
        p_flush;                                 // our own seek flushes nav_dsi
        at(32'd0);                               // scalars cleared -> stale 0
        at(32'd2050);                            // parse front, still past B, STALE
        repeat (10) @(posedge clk);
        chki("B7b no second jump from stale data", fires, 1);
        // and once a real DSI packet lands inside the loop, it re-arms properly
        p_dsi; at(32'd1200);
        at(32'd2000);
        chki("B7c re-arms after a REAL update", fires, 2);

        if (errors == 0) $display("AB_REPEAT_TB: ALL TESTS PASSED");
        else             $display("AB_REPEAT_TB: FAILED (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
