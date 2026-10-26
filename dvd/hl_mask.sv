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
// WHAT.  mask = "a new cell's unit has been accepted and no HLI has armed since that
// cell began". While it is set the highlight is not drawn; the next HLI to arm is
// the new cell's, and clears it.
//
// ⚠ THE RACE IT MUST NOT LOSE: if the new cell's HLI arms BEFORE its unit commits
// (a small parse lead, e.g. straight after a flush), masking at the load would
// hide the CORRECT highlight until some later HLI armed -- possibly never, on a
// still menu whose later HLIs are continuations. So the mask only sets when no HLI
// has armed since the cell change (`armed_since`).
//
// ⚠ AND AN ARM JUST BEFORE THE CELL CHANGE CAN BE THE NEW CELL'S (2026-10-13, issue
// #176, Mad Dog McCree's sheriff's office: reticle never drawn, shots still scored).
// A NAV pack carries the HLI (PCI) BEFORE the cell ids (DSI) that raise new_cell, so a
// highlight that promotes AT ITS COMMIT arms ~200 demux bytes before its own cell's
// new_cell -- which then cleared armed_since, and the cell's unit raised a mask that
// no later arm ever cleared (that window's HLI is "forever", its continuations never
// re-promote). nav_pci's scoring-window lead made that commit-time promotion common:
// after a title jump the clock reads 0 until its first anchor, so a window at the
// title's first picture is due the moment it is parsed. An arm within ARM_GRACE
// cycles of new_cell therefore counts as the new cell's. A previous cell's HLI
// promotes on the DISPLAY schedule, so it lands in that sliver only by coincidence,
// and the cost then is the old one-frame blip, not a highlight hidden for good.
`default_nettype none
module hl_mask #(
    // PCI->DSI of one NAV pack is ~224 bytes of the demux; at 27 MHz clk_sys that is
    // well under a thousand cycles. 16384 (~0.6 ms) covers it with margin and stays far
    // inside the spacing of any two display-scheduled promotions.
    parameter [14:0] ARM_GRACE = 15'd16383
) (
    input  wire clk,
    input  wire rst_n,           // pipe reset: a flush forgets everything
    input  wire new_cell,        // the delivered stream entered a different cell
    input  wire newcell_load,    // spu_decode ACCEPTED that cell's first unit (before any pixel)
    input  wire hli_arm,         // nav_pci promoted an HLI with buttons
    output reg  mask
);
    reg armed_since;             // an HLI armed since the last cell change
    reg [14:0] since_arm;        // cycles since the last hli_arm (saturating)
    always @(posedge clk) begin
        if (!rst_n) begin
            mask        <= 1'b0;
            armed_since <= 1'b0;
            since_arm   <= 15'h7FFF;
        end else begin
            if (since_arm != 15'h7FFF) since_arm <= since_arm + 15'd1;
            if (new_cell) armed_since <= (since_arm < ARM_GRACE);
            if (newcell_load && !armed_since && !hli_arm) mask <= 1'b1;
            if (hli_arm) begin
                armed_since <= 1'b1;
                since_arm   <= 15'd0;
                mask        <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
