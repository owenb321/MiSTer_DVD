// hl_mask.sv -- do not let the PREVIOUS cell's highlight recolour the NEW cell's
// subpicture (2026-09-18, Harry Potter Interactive's Player Mode;
// docs/subpicture.md "The re-send guard is per cell").
//
// WHY.  A menu subpicture is shown as soon as it commits (spu_decode's menu_mode is
// windowless), and it commits at the PARSE front -- about a VBUF depth before the
// display reaches its cell. The HLI is promoted on the DISPLAY's schedule. So for
// that window the new cell's graphic is on the subpicture layer while the previous
// cell's HLI is still the one armed. On Player Mode the previous cell is the intro,
// whose HLI is ONE full-screen "skip" button with the same colours: its rect covers
// both wands, so both lit up until the new cell's two-button HLI arrived. A player
// that presents the subpicture at its PTS never shows that.
//
// WHAT.  mask = "a new cell's unit has committed and no HLI has armed since that
// cell began". While it is set the highlight is not drawn; the next HLI to arm is
// the new cell's, and clears it.
//
// ⚠ THE RACE IT MUST NOT LOSE: if the new cell's HLI arms BEFORE its unit commits
// (a small parse lead, e.g. straight after a flush), masking at the commit would
// hide the CORRECT highlight until some later HLI armed -- possibly never, on a
// still menu whose later HLIs are continuations. So the mask only sets when no HLI
// has armed since the cell change (`armed_since`).
`default_nettype none
module hl_mask (
    input  wire clk,
    input  wire rst_n,           // pipe reset: a flush forgets everything
    input  wire new_cell,        // the delivered stream entered a different cell
    input  wire newcell_commit,  // spu_decode committed that cell's first unit
    input  wire hli_arm,         // nav_pci promoted an HLI with buttons
    output reg  mask
);
    reg armed_since;             // an HLI armed since the last cell change
    always @(posedge clk) begin
        if (!rst_n) begin
            mask        <= 1'b0;
            armed_since <= 1'b0;
        end else begin
            if (new_cell) armed_since <= 1'b0;
            if (newcell_commit && !armed_since && !hli_arm) mask <= 1'b1;
            if (hli_arm) begin
                armed_since <= 1'b1;
                mask        <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
