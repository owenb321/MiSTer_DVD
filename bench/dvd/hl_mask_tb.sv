// hl_mask_tb.sv -- the previous cell's highlight must not recolour the new cell's
// subpicture, and the new cell's highlight must never be hidden (2026-09-18;
// dvd/hl_mask.sv, docs/subpicture.md "The re-send guard is per cell").
//
//   [K1] Player Mode: new cell -> its unit commits while the intro's HLI is still
//        armed -> MASKED; the new cell's HLI arms -> unmasked.
//   [K2] THE RACE: new cell -> its HLI arms FIRST -> then its unit commits ->
//        NEVER masked (masking here would hide the right highlight for good).
//   [K3] a pipe reset clears a pending mask.
//   [K4] a commit with no cell change (an ordinary unit) never masks.
`timescale 1ns/1ps
`default_nettype none
module hl_mask_tb;
    reg clk = 0, rst_n = 0, new_cell = 0, newcell_commit = 0, hli_arm = 0;
    wire mask;
    always #5 clk = ~clk;
    hl_mask dut (.clk(clk), .rst_n(rst_n), .new_cell(new_cell),
                 .newcell_commit(newcell_commit), .hli_arm(hli_arm), .mask(mask));
    integer errors = 0;
    task fail(input [639:0] m); begin $display("FAIL: %0s", m); errors = errors + 1; end endtask
    task p_nc;  begin @(negedge clk); new_cell = 1;       @(negedge clk); new_cell = 0;       repeat (3) @(negedge clk); end endtask
    task p_cm;  begin @(negedge clk); newcell_commit = 1; @(negedge clk); newcell_commit = 0; repeat (3) @(negedge clk); end endtask
    task p_arm; begin @(negedge clk); hli_arm = 1;        @(negedge clk); hli_arm = 0;        repeat (3) @(negedge clk); end endtask
    task rst;   begin rst_n = 0; repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk); end endtask
    initial begin
        rst;
        p_arm;                      // the intro's HLI is armed
        p_nc; p_cm;                 // cell 2's unit commits at the parse front
        if (!mask) fail("[K1] the intro's highlight was left to recolour cell 2's graphic");
        p_arm;                      // cell 2's HLI promotes
        if (mask) fail("[K1] cell 2's own highlight stayed masked");
        else $display("   [K1] masked from the new unit's commit to the new HLI  ok");

        rst;
        p_arm; p_nc; p_arm; p_cm;   // the new cell's HLI arms before its unit commits
        if (mask) fail("[K2] the new cell's own highlight was hidden (commit after its HLI)");
        else $display("   [K2] HLI first, then the unit: never masked  ok");

        rst;
        p_arm; p_nc; p_cm; rst;
        if (mask) fail("[K3] a pipe reset left the mask set");
        else $display("   [K3] a flush clears the mask  ok");

        rst;
        p_arm; p_cm;                // newcell_commit only pulses across a cell change,
        p_arm;                      // but a lone pulse after an arm with no new_cell
        if (mask) fail("[K4] mask left set after an HLI armed");
        else $display("   [K4] an HLI arm always clears it  ok");

        if (errors == 0) $display("RESULT: PASS");
        else begin $display("RESULT: FAIL (%0d)", errors); $fatal(1, "hl_mask_tb failed"); end
        $finish;
    end
endmodule
`default_nettype wire
