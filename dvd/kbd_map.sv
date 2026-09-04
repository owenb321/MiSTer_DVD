// ============================================================================
// dvd/kbd_map.sv -- keyboard / TV-remote transport control
// ============================================================================
// Decodes the framework's ps2_key stream into a VIRTUAL JOYSTICK VECTOR with
// exactly the bit layout of hps_io's joystick_0[16:0] (D-pad = [3:0], the J1
// CONF_STR buttons B1..B13 = [4]..[16]), which dvd/emu.sv ORs into joy_eff.
// Every transport action therefore gains a key for free -- edge detection,
// chapter coalescing, the menu button walk, the HUD and vm_entropy_stir all
// consume joy_eff and need no change.
//
// ★ WHY THIS EXISTS AT ALL, when MiSTer already maps keys to buttons
// (issue #35). Main's "Define buttons" REFUSES to bind Enter or Esc:
// input.cpp:3276 guards the capture block with
//     !((mapping_type < 2 || !mapping_button) && (cancel || enter))
// and a keyboard session is mapping_type == 0 (input.cpp:3353), so those two
// keys are excluded for EVERY button. Worse, they are not merely dropped --
// Enter is the OSD's own confirm key, so it reaches menu.cpp:4419 and ENDS AND
// SAVES the mapping session, which is exactly why a user reports that it
// "registered" and then does nothing. Reproduced on a stock MiSTer: a mapped
// Enter does not activate a highlighted DVD-menu button while the gamepad's
// own Select does, in the same menu. Reading the scancode here bypasses Main's
// mapper entirely -- and since those two keys can never be mapped, our bindings
// for them can never be shadowed by a user's own.
//
// ★ AND FOR HDMI-CEC THIS IS THE ONLY PATH THAT EXISTS. Main injects CEC button
// presses as KEYBOARD events (hdmi_cec.cpp:290-319) and never runs them through
// the joystick mapping, so before this module a TV remote could drive nothing
// here except menu digits. The key choices below are led by that fixed CEC
// table, because it is the constrained resource; keyboard aliases follow
// DVD-remote / VLC convention afterwards.
// ⚠ CEC's own Root Menu / Exit is UNREACHABLE and that is not fixable here:
// it maps to `menu_present() ? KEY_BACK : KEY_MENU` and menu_present() means
// "the OSD is on screen right now" (menu.cpp:8137), so during playback it is
// KEY_MENU -- which Main eats as the OSD toggle -- while KEY_BACK has NONE in
// the PS/2 table. Hence Menu/Title/Audio/Subtitle ride the CEC COLOUR keys.
//
// ★ EVERY OUTPUT BIT IS A ONE-CYCLE PULSE ON THE PRESS. Break events are
// ignored and no level is held anywhere in this module, so a lost release is a
// non-event and a stuck key is structurally impossible. (An all-levels design
// has a subtler failure too: a stuck bit swallows the NEXT press, because there
// is no rising edge left to detect, and the key just looks dead.) The cost is
// no key-repeat from holding a direction in a menu -- but the gamepad behaves
// identically today, and Main drops keyboard auto-repeat anyway
// (user_io.cpp:4059, `if (press > 1 && !use_ps2ctl) return;`), so a held key
// was never going to repeat.
//
// ★ [14:13] FAST FWD / REWIND ARE PULSES TOO, AND emu.sv MASKS THEM OUT OF
// joy_eff -- they drive dvd/dpad_seek.sv (+/-10 s per press, coalescing) rather
// than dvd/scrub_ctrl.sv's hold-to-scrub. They are the design's ONLY level
// consumers (scrub_ctrl.sv:84) and a keyboard-like device cannot drive a level
// safely, for two measured reasons:
//   1. TAP-REPEATING IR REMOTES TURN A HOLD INTO A BURST OF SEEKS. Retro
//      Remake's own SuperDock receiver firmware (DockIR, src/main.c) sends
//      key-down -> 80 ms -> key-up PER NEC REPEAT FRAME, ~110 ms apart: a long
//      press is ~9 discrete taps a second, not a hold. scrub_ctrl's accumulate
//      tick is 60 ms (TICK = 1_620_000 @ 27 MHz), so an 80 ms tap leaves
//      pending_off != 0 and each release issues a REAL seek -- ~9 flush and
//      re-locks per second, which is precisely the regime HW rounds 1-2
//      recorded as fatal (see the headers of scrub_ctrl.sv and dpad_seek.sv).
//      Under coalescing that identical burst builds ONE large jump instead.
//   2. A STUCK LEVEL HANGS THE PICTURE. held_right stuck with in_title leaves
//      `want` high forever -> hold_freeze -> frozen video with the bar up and
//      no seek issued (the seek happens on RELEASE), and the reflex recovery --
//      tap it again -- delivers a break with pending_off already ramped to the
//      title span, i.e. one seek straight to the END OF THE TITLE.
// The gamepad's hold-to-scrub is untouched by any of this; scrub_ctrl.sv is not
// modified. See docs/dvd_nav.md "Keyboard / CEC input".
//
// ⚠ DIGITS 0-9 ARE DELIBERATELY NOT DECODED HERE. All twenty scancodes (top row
// and numpad) belong to emu.sv's "NUMPAD MENU INPUT" block, where a digit
// selects AND activates menu button N -- the DVD-remote idiom, HW-confirmed by
// the T2 "82997" easter egg (PR fj#134). Binding them to a transport action as
// well would make one keypress do two things.
//
// ⚠ EXTENDED-BIT COLLISIONS ARE THE WHOLE REASON ps2_key[8] IS PART OF THE
// DECODE KEY. In PS/2 set 2 the arrow and page keys are bit-identical to numpad
// digits and differ ONLY by the E0 prefix:
//     E0 75 Up   / 75 numpad-8      E0 72 Down / 72 numpad-2
//     E0 6B Left / 6B numpad-4      E0 74 Rght / 74 numpad-6
//     E0 7D PgUp / 7D numpad-9      E0 7A PgDn / 7A numpad-3
// The digit block already requires !ps2_key[8]; this one requires ps2_key[8]
// for exactly those six. Enter is the one key accepted with EITHER polarity
// (5A and E0 5A = Enter and KP-Enter, both "OK").
//
// ⚠ NEVER BIND, all verified against Main: F12 (07) and KEY_MENU are eaten as
// the OSD toggle; KEY_PAUSE (E1) has no break code at all; NumLock/ScrollLock
// are Main's EMU_SWITCH_1/2 keyboard-emulation toggles; Alt/Meta are passed
// through specially so they cannot stick.
// ============================================================================

`default_nettype none

module kbd_map (
    input  wire        clk,        // clk_sys (27 MHz)
    input  wire        rst_n,

    // hps_io "ps2 alternative interface": {toggle, pressed, extended, code}.
    // Bit 10 flips on every new key event; bit 9 is make/break; bit 8 is E0.
    input  wire [10:0] ps2_key,

    // One-cycle pulse per PRESS, in joystick_0[16:0] bit order.
    output reg  [16:0] joy
);

    // ---- scancode -> bit index (combinational) -----------------------------
    // hit is a one-hot vector, not an index, because emu.sv wants the vector
    // and several keys share a destination (M / X / F1 all mean Menu).
    reg [16:0] hit;
    always @(*) begin
        hit = 17'd0;
        if (ps2_key[8]) begin
            // ---- E0-extended --------------------------------------------
            case (ps2_key[7:0])
            8'h75: hit[3]  = 1'b1;   // Up          -> D-pad Up      (CEC)
            8'h72: hit[2]  = 1'b1;   // Down        -> D-pad Down    (CEC)
            8'h6B: hit[1]  = 1'b1;   // Left        -> D-pad Left    (CEC)
            8'h74: hit[0]  = 1'b1;   // Right       -> D-pad Right   (CEC)
            8'h7D: hit[5]  = 1'b1;   // Page Up     -> B2  Prev Chapter (CEC)
            8'h7A: hit[6]  = 1'b1;   // Page Down   -> B3  Next Chapter (CEC)
            8'h5A: hit[7]  = 1'b1;   // KP-Enter    -> B4  Select
            default: ;
            endcase
        end else begin
            // ---- plain set-2 --------------------------------------------
            case (ps2_key[7:0])
            8'h5A: hit[7]  = 1'b1;   // Enter       -> B4  Select    (CEC OK)
            8'h29: hit[4]  = 1'b1;   // Space       -> B1  Pause     (CEC Play/Pause)
            8'h4D: hit[5]  = 1'b1;   // P           -> B2  Prev Chapter
            8'h31: hit[6]  = 1'b1;   // N           -> B3  Next Chapter
            8'h05: hit[8]  = 1'b1;   // F1          -> B5  Menu      (CEC Blue)
            8'h3A: hit[8]  = 1'b1;   // M           -> B5  Menu
            8'h22: hit[8]  = 1'b1;   // X           -> B5  Menu      (SuperDock "Cancel":
                                     //   its only spare key, and the dock's ONLY route to
                                     //   the disc menu -- its Menu button is F12 = the OSD)
            8'h34: hit[9]  = 1'b1;   // G           -> B6  Angle
            8'h04: hit[10] = 1'b1;   // F3          -> B7  Audio     (CEC Green)
            8'h1C: hit[10] = 1'b1;   // A           -> B7  Audio
            8'h0C: hit[11] = 1'b1;   // F4          -> B8  Subtitle  (CEC Yellow)
            8'h1B: hit[11] = 1'b1;   // S           -> B8  Subtitle
            8'h23: hit[12] = 1'b1;   // D           -> B9  Display
            8'h0D: hit[13] = 1'b1;   // Tab         -> B10 Fast Fwd  (CEC FF)
            8'h2B: hit[13] = 1'b1;   // F           -> B10 Fast Fwd
            8'h66: hit[14] = 1'b1;   // Backspace   -> B11 Rewind    (CEC Rewind)
            8'h2D: hit[14] = 1'b1;   // R           -> B11 Rewind
            8'h06: hit[15] = 1'b1;   // F2          -> B12 Title     (CEC Red)
            8'h2C: hit[15] = 1'b1;   // T           -> B12 Title
            8'h76: hit[16] = 1'b1;   // Esc         -> B13 Return    (CEC Stop, dock "Exit").
                                     //   Bound deliberately: CEC's real back button is
                                     //   unreachable (see header), so without Esc a CEC
                                     //   user has no way up a menu level. GoUp is a
                                     //   harmless no-op where the disc authors no parent.
            8'h32: hit[16] = 1'b1;   // B           -> B13 Return
            default: ;
            endcase
        end
    end

    // ---- event edge -> one-cycle pulse -------------------------------------
    // Registered, NOT combinational off ps2_key: that word stays put for
    // thousands of cycles between events, so a combinational "pulse" would be a
    // level and every downstream edge detector would see one edge but the
    // wrong width -- and bits [14:13] would land in dpad_seek as a held request.
    reg ps2_tgl_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            joy       <= 17'd0;
            ps2_tgl_q <= 1'b0;
        end else begin
            joy       <= 17'd0;                 // default: one-cycle pulse
            ps2_tgl_q <= ps2_key[10];
            // new key event (toggle flipped) + PRESSED (break events ignored)
            if ((ps2_key[10] ^ ps2_tgl_q) && ps2_key[9]) joy <= hit;
        end
    end

endmodule

`default_nettype wire
