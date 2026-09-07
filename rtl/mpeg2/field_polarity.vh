/*
 * field_polarity.vh — DVD-FORK (2026-09-06): WHICH raster field is SMPTE field 1.
 *
 * ★ ONE definition, three consumers, because they cannot be allowed to disagree:
 *
 *   rtl/mpeg2/syncgen.v  vs_ref_dot / eff_vertical_length — field 1 gets the
 *                        LINE-ALIGNED vertical sync and the SHORT field total; the
 *                        other gets the mid-line vsync and the extra line. (The longer
 *                        field must carry the mid-line vsync, or the vsync spacing
 *                        becomes 263.5/261.5 instead of 262.5 every field.)
 *   dvd/csync_smpte.sv   which field's equalizing/serration block starts on a line
 *                        boundary rather than half a line in.
 *   dvd/cc_vbi.sv        which field carries the line-21 EIA-608 field-1 services
 *                        (C1/C2/T1/T2).
 *
 * If these three ever disagree the analog output tells a television one thing about
 * field order while the caption inserter and the raster believe another — a class of
 * bug that is invisible in any single-module bench. bench/dvd/csync_field_tb.sv gates
 * the syncgen/csync_smpte half of it directly (the emitted block's line-aligned field
 * must be the same v_pos parity as the raster's own line-aligned vsync).
 *
 * ⚠ CHANGED 2026-09-06, from 0 to 1, on a hardware measurement — see below.
 *
 * WHY 1 (SMPTE field 1 = the v_pos-ODD field)
 * -------------------------------------------
 * Until the composite sync carried equalizing pulses (docs/single_raster_analog.md
 * §3.10) NO display could read our field order correctly, so this constant had never
 * actually been tested. The stock framework csync left the two fields' vertical events
 * 0.857 line apart instead of 0.500 (MEASURED, csync_field_tb), and a width-based
 * separator MISSED one field's 18 us broad pulse and locked onto the next one a line
 * later — which made a television read the OPPOSITE field as field 1. With that
 * misreading in place, a content mapping that is off by one field looked correct.
 *
 * Fixing the sync removed the misreading and exposed the error: on the reference CRT
 * the picture then needed the content flipped, while HDMI — which never reads composite
 * sync — stayed correct unflipped. Two outputs disagreeing by exactly one field pins the
 * fault to the thing that differs between them, which is this constant. (The same shape
 * as the VGA_F1 inversion found in PR #44, and found the same way.)
 *
 * Our system calls the v_pos-EVEN field the top field: rtl/mpeg2/mixer.v places TOP
 * content there and dvd/emu.sv's VGA_F1 tells ascal the same. So sync field 1 is the
 * OTHER one — which is also what bench/dvd/cc_field_map_tb.sv's header said all along
 * ("TOP content displays inside SYNC field 2; NTSC is bottom-field-first") before it was
 * "corrected" against three other sites that had all been calibrated on the broken sync.
 * ⚠ Agreement between several modules is not evidence when they share a reference that
 * was never checked against a display.
 *
 * ⛔ Do NOT "fix" a field-order report by flipping mixer.v's parity comparison or
 * VGA_F1: those move HDMI and analog TOGETHER, so they cannot resolve a disagreement
 * BETWEEN them. (P1O[48] Field Order existed to diagnose exactly that and was removed
 * once it had; see docs/single_raster_analog.md §3.11.)
 *
 * ⚠⚠ OPEN RISK: THIS IS ONE CONSTANT FOR BOTH STANDARDS, DERIVED FROM AN NTSC
 * MEASUREMENT. Nothing here or in its three consumers has a `pal` term, so a 625-line
 * raster gets the 525-line answer. That is an assumption, not a result:
 *   - The BLOCK SHAPE is standards-correct on both (BT.470's 5/5/5 half-lines and its
 *     pulse widths, gated by csync_field_tb's PAL arms) -- that part is not in question.
 *   - WHICH raster field is field 1 is a separate question, and 525-line and 625-line
 *     systems are not obliged to answer it the same way; their frame line numbering
 *     differs, and NTSC and PAL differ in authored field dominance besides.
 *   - [G8] only gates that the raster and the emitted block AGREE about which field is
 *     first. Both being wrong together on PAL would pass it.
 * PAL on an analog CRT has never been hardware-confirmed at all (no PAL CRT available --
 * the raster numbers have been sim-derived since PR fj#146), so this is untested rather
 * than known-good. If a PAL CRT report says the fields are swapped, the fix is to make
 * this constant per-standard (`pal ? ... : ...` in all three consumers) rather than to
 * flip it globally -- flipping it globally would break the NTSC case this was measured on.
 */
`ifndef FIELD_POLARITY_VH
`define FIELD_POLARITY_VH

// v_pos[0] of the field that is SMPTE 170M / BT.470 field 1.
// 1'b1 = the v_pos-ODD field.  (1'b0 was the pre-2026-09-06 behaviour.)
`define FIELD1_VPOS 1'b1

`endif
