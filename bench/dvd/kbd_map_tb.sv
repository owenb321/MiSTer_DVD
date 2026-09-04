// ============================================================================
// bench/dvd/kbd_map_tb.sv -- unit tests for dvd/kbd_map.sv
// ============================================================================
//   iverilog -g2012 -o /tmp/kbd_sim dvd/kbd_map.sv bench/dvd/kbd_map_tb.sv \
//     && vvp /tmp/kbd_sim
//
// The contracts worth defending here are not "the case statement is typed
// correctly" -- they are the three properties the rest of the design leans on:
//
//   * EVERY bit is a one-cycle pulse, including [14:13]. emu.sv feeds those two
//     to dpad_seek, where a held request would coalesce forever, and the other
//     fifteen go to edge detectors that must see exactly one edge per press.
//   * The extended bit DISCRIMINATES. Six of our scancodes are bit-identical to
//     numpad digits and differ only by the E0 prefix; emu.sv's "NUMPAD MENU
//     INPUT" block owns the non-extended forms, so any leak here would make one
//     keypress both pick a menu button and fire a transport action.
//   * NO digit produces output at all -- the same rule from the other side.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module kbd_map_tb;

    reg clk = 1'b0;
    always #18.5 clk = ~clk;            // ~27 MHz

    reg         rst_n = 1'b0;
    reg  [10:0] ps2 = 11'd0;
    wire [16:0] joy;

    kbd_map dut (.clk(clk), .rst_n(rst_n), .ps2_key(ps2), .joy(joy));

    integer errors = 0;

    // Observed pulse activity since the last clear: which bits fired, and the
    // WIDEST run of consecutive cycles any bit stayed high (the pulse contract).
    reg [16:0] seen  = 17'd0;
    integer    width = 0;
    integer    run   = 0;
    always @(posedge clk) begin
        seen <= seen | joy;
        if (joy != 17'd0) begin
            run = run + 1;
            if (run > width) width = run;
        end else run = 0;
    end

    task clr; begin seen = 17'd0; width = 0; run = 0; end endtask
    task tick(input integer n); begin repeat (n) @(negedge clk); end endtask

    // One key event: flip the toggle, hold the word (as hps_io does -- it stays
    // put for thousands of cycles until the next event).
    task key(input ext, input [7:0] code, input pressed, input integer hold);
        begin
            @(negedge clk);
            ps2 = {~ps2[10], pressed, ext, code};
            tick(hold);
        end
    endtask

    task expect_bit(input [80*8-1:0] lbl, input integer b);
        begin
            if (seen !== (17'd1 << b)) begin
                $display("FAIL %0s: joy=%b want only bit %0d", lbl, seen, b);
                errors = errors + 1;
            end else if (width != 1) begin
                $display("FAIL %0s: pulse was %0d cycles wide, want 1", lbl, width);
                errors = errors + 1;
            end else
                $display("PASS %0s -> bit %0d", lbl, b);
        end
    endtask

    task expect_none(input [80*8-1:0] lbl);
        begin
            if (seen !== 17'd0) begin
                $display("FAIL %0s: joy=%b, want all-zero", lbl, seen);
                errors = errors + 1;
            end else
                $display("PASS %0s -> nothing", lbl);
        end
    endtask

    // press-and-release, checking the PRESS produced bit b and the RELEASE
    // produced nothing at all.
    task tap_bit(input [80*8-1:0] lbl, input ext, input [7:0] code, input integer b);
        begin
            clr(); key(ext, code, 1'b1, 12); expect_bit(lbl, b);
            clr(); key(ext, code, 1'b0, 12); expect_none({lbl, " (break)"});
        end
    endtask

    task tap_none(input [80*8-1:0] lbl, input ext, input [7:0] code);
        begin
            clr(); key(ext, code, 1'b1, 12);
            clr2_check(lbl);
            clr(); key(ext, code, 1'b0, 12); expect_none({lbl, " (break)"});
        end
    endtask
    task clr2_check(input [80*8-1:0] lbl); begin expect_none(lbl); end endtask

    integer i;
    reg [7:0] digits [0:19];

    initial begin
        tick(4); rst_n = 1'b1; tick(4);

        // ---- T1/T2/T3: every mapped key, one-hot, one cycle, break silent ----
        $display("== T1-T3: per-key one-hot + pulse width + silent break");
        tap_bit("Up",        1'b1, 8'h75, 3);
        tap_bit("Down",      1'b1, 8'h72, 2);
        tap_bit("Left",      1'b1, 8'h6B, 1);
        tap_bit("Right",     1'b1, 8'h74, 0);
        tap_bit("Space",     1'b0, 8'h29, 4);
        tap_bit("PageUp",    1'b1, 8'h7D, 5);
        tap_bit("P",         1'b0, 8'h4D, 5);
        tap_bit("PageDown",  1'b1, 8'h7A, 6);
        tap_bit("N",         1'b0, 8'h31, 6);
        tap_bit("Enter",     1'b0, 8'h5A, 7);
        tap_bit("F1",        1'b0, 8'h05, 8);
        tap_bit("M",         1'b0, 8'h3A, 8);
        tap_bit("X",         1'b0, 8'h22, 8);
        tap_bit("G",         1'b0, 8'h34, 9);
        tap_bit("F3",        1'b0, 8'h04, 10);
        tap_bit("A",         1'b0, 8'h1C, 10);
        tap_bit("F4",        1'b0, 8'h0C, 11);
        tap_bit("S",         1'b0, 8'h1B, 11);
        tap_bit("D",         1'b0, 8'h23, 12);
        tap_bit("F2",        1'b0, 8'h06, 15);
        tap_bit("T",         1'b0, 8'h2C, 15);
        tap_bit("Esc",       1'b0, 8'h76, 16);
        tap_bit("B",         1'b0, 8'h32, 16);

        // ---- T4: Fast Fwd / Rewind pulse like everything else ---------------
        // These are the two bits emu.sv routes to dpad_seek. A LEVEL here would
        // hold the coalesce window open forever, so the pulse is the contract.
        $display("== T4: FF/REW are pulses, not levels");
        tap_bit("Tab (FF)",       1'b0, 8'h0D, 13);
        tap_bit("F (FF)",         1'b0, 8'h2B, 13);
        tap_bit("Backspace (REW)",1'b0, 8'h66, 14);
        tap_bit("R (REW)",        1'b0, 8'h2D, 14);

        // Hold one for a long time with no further events: still ONE pulse.
        clr(); key(1'b0, 8'h0D, 1'b1, 5000);
        if (seen !== (17'd1 << 13) || width != 1) begin
            $display("FAIL T4-hold: seen=%b width=%0d (want one 1-cycle pulse on 13)",
                     seen, width);
            errors = errors + 1;
        end else $display("PASS T4-hold: 5000-cycle hold = exactly one pulse");
        clr(); key(1'b0, 8'h0D, 1'b0, 12); expect_none("T4-hold release");

        // ---- T5: extended discrimination (the numpad collision) -------------
        // Non-extended 75/72/6B/74/7D/7A are numpad 8/2/4/6/9/3 and belong to
        // emu.sv's digit path. They must produce NOTHING here.
        $display("== T5: non-extended arrow/page codes are numpad digits");
        tap_none("numpad8 (75)", 1'b0, 8'h75);
        tap_none("numpad2 (72)", 1'b0, 8'h72);
        tap_none("numpad4 (6B)", 1'b0, 8'h6B);
        tap_none("numpad6 (74)", 1'b0, 8'h74);
        tap_none("numpad9 (7D)", 1'b0, 8'h7D);
        tap_none("numpad3 (7A)", 1'b0, 8'h7A);

        // ---- T6: no digit, either bank, produces anything --------------------
        $display("== T6: all 20 digit scancodes are inert");
        digits[0]=8'h45; digits[1]=8'h16; digits[2]=8'h1E; digits[3]=8'h26;
        digits[4]=8'h25; digits[5]=8'h2E; digits[6]=8'h36; digits[7]=8'h3D;
        digits[8]=8'h3E; digits[9]=8'h46;                    // top row 0..9
        digits[10]=8'h70; digits[11]=8'h69; digits[12]=8'h72; digits[13]=8'h7A;
        digits[14]=8'h6B; digits[15]=8'h73; digits[16]=8'h74; digits[17]=8'h6C;
        digits[18]=8'h75; digits[19]=8'h7D;                  // numpad 0..9
        for (i = 0; i < 20; i = i + 1) begin
            clr(); key(1'b0, digits[i], 1'b1, 8);
            if (seen !== 17'd0) begin
                $display("FAIL T6: digit scancode %02h produced joy=%b", digits[i], seen);
                errors = errors + 1;
            end
            clr(); key(1'b0, digits[i], 1'b0, 8);
        end
        $display("PASS T6: no digit scancode reaches the transport map");

        // ---- T7: Enter and KP-Enter both mean Select ------------------------
        $display("== T7: Enter / KP-Enter");
        tap_bit("KP-Enter", 1'b1, 8'h5A, 7);

        // ---- T8: no toggle flip = no event ----------------------------------
        // hps_io holds the word between events; only bit 10 changing is an event.
        $display("== T8: repeated word without a toggle flip is inert");
        @(negedge clk); ps2 = {~ps2[10], 1'b1, 1'b0, 8'h29};   // Space press
        tick(8);
        clr(); tick(200);                                       // same word held
        expect_none("Space held, no new event");

        // ---- T9: reset clears -----------------------------------------------
        $display("== T9: reset");
        @(negedge clk); ps2 = {~ps2[10], 1'b1, 1'b0, 8'h5A};
        @(negedge clk); rst_n = 1'b0;
        clr(); tick(20);
        if (joy !== 17'd0 || seen !== 17'd0) begin
            $display("FAIL T9: joy=%b seen=%b under reset", joy, seen);
            errors = errors + 1;
        end else $display("PASS T9: held in reset");
        @(negedge clk); rst_n = 1'b1; tick(4);

        // ---- T10: keys Main eats must never be bound ------------------------
        // F12 opens the MiSTer OSD, KEY_PAUSE (E1) has no break code, E2 is a
        // prefix. Executable form of the "never bind" rule in the module header.
        $display("== T10: never-bind keys");
        tap_none("F12 (07)",       1'b0, 8'h07);
        tap_none("KEY_PAUSE (E1)", 1'b0, 8'hE1);
        tap_none("prefix (E2)",    1'b0, 8'hE2);
        tap_none("CapsLock (58)",  1'b0, 8'h58);

        if (errors == 0) $display("KBD_MAP_TB: ALL TESTS PASSED");
        else begin $display("KBD_MAP_TB: %0d FAILURE(S)", errors); $fatal(1); end
        $finish;
    end

    initial begin #20_000_000; $display("KBD_MAP_TB: TIMEOUT"); $fatal(1); end

endmodule

`default_nettype wire
