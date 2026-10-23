//============================================================================
// nav_trace.sv -- timestamped navigation event FIFO, drained by the HPS.
//
// WHAT IT IS FOR. Interactive-disc timing bugs (issue #176, Mad Dog McCree) are
// questions about WHEN: when a menu's buttons went live relative to the picture,
// when a cell command ran, when the audio-low hold released, what g[0] was set
// to, when a key press reached the fabric. The 0x7A telemetry snapshot cannot
// answer them: it is a level sampled every 10..250 ms, and these are events a
// few frames apart. So the fabric logs each event, with the time it happened on
// the core's own clocks, into a 256-entry FIFO the HPS drains over the same
// hps_io EXT_BUS dvd_telem uses (command 0x7C). docs/hil_play_harness.md
// "Nav event FIFO (fabric)" is the reference; this header is the contract.
//
// ENTRY (80 bits, read as five 16-bit words, MSB first)
//   [79:75] code      event code, 1..16 (0 is never written: a zero code read
//                     back is a protocol error, not an event)
//   [74:49] payload   26 bits, per code (table below)
//   [48:16] stc       av_stc, the clk_sys mirror of the 90 kHz STC, at the cycle
//                     the entry was written
//   [15:0]  fts       free-running 90 kHz tick count, bits [20:5]: 1 LSB =
//                     32 ticks = 0.356 ms, wraps every 23.3 s
//
// ★ WHY TWO TIMESTAMPS. The STC is the clock the picture is scheduled by
// (displayed PTS = STC + disp_lag, telemetry word 11), so it is the one a
// "relative to the picture" question needs. But it is NOT free-running: it
// holds while paused or before video is live, it is zeroed by a flush, and it
// jumps on every re-anchor (dvd/disp_sched.sv). A key-latency measurement made
// across a pause, or two events either side of a flush, cannot be ordered or
// differenced on it. The free tick can, and it is what maps an entry onto the
// HPS's CLOCK_MONOTONIC: every drain's header carries both clocks' values at
// the command strobe. Fitting both in one entry is what made it 80 bits wide --
// at no M10K cost, since 256 x 80 is exactly two 256x40 blocks, the same two
// that 256 x 64 would occupy. The free tick is stored at 1/32 resolution in 16
// bits; the host unwraps it against the header's full 32-bit free_now, which is
// exact for any entry younger than 23.3 s at its drain (see LIMITS).
//
// EVENT CODES (code = priority index + 1; index 0 is drained first)
//    1 GPRM      {6'd0, idx[3:0], value[15:0]}  a VM write to GPRM 0..15
//                (dvd_vm's data-RAM write snoop -- every write, including the
//                1 Hz counter-mode increments and the mount clear)
//    2 STC_JUMP  delta[25:0] = new - previous STC, two's complement mod 2^26
//                (+/-372 s); the entry's stc field is the new value. Any change
//                that is not +0/+1: a re-anchor, a flush reset, a pause re-sync.
//    3 JOY       {kbd, rise[24:0]}: joy_eff press edges (joystick_0's bit order;
//                kbd = at least one of them came from kbd_map)
//    4 PS2       {16'd0, ps2_key[9:0]} = {pressed, extended, scancode}: every
//                ps2_key toggle, make AND break (digits never reach joy_eff)
//    5 BTN_ACT   {14'd0, btn_ns[5:0], btn_sel[5:0]}  nav_pci activated a button
//    6 CELL_CMD  {10'd0, cur_cell[7:0], cmdnr[7:0]}  the reader handed the VM a cell command
//    7 HLI_ARM   {btn_ns[5:0], h_sptm[19:0]}  an HLI with buttons promoted onto
//                the screen; h_sptm is its authored start PTS (low 20 bits:
//                compare with the entry's stc to see how late it went live)
//    8 ARMED     {19'd0, btns_armed, btn_ns[5:0]}  btns_armed changed (either edge)
//    9 CELL      {9'd0, menu, cur_vts[7:0], cur_cell[7:0]}  cur_cell or cur_vts changed
//   10 PGC       {1'b0, menu, cur_vts[7:0], cur_pgcn[15:0]}  PGC, VTS or domain changed
//   11 FLUSH     {20'd0, rise[5:0]}: [0] load_flush [1] aud_flush [2] aud_resync
//                [3] seek_flush [4] mount_flush [5] soft_flush (rising edges)
//   12 AUD_LOW   {9'd0, low, frames[15:0]}  emu's aud_ring_low hysteresis flag changed
//   13 STATE     {18'd0, chg[3:0], now[3:0]}: [0] pause [1] still [2] video_live
//                [3] menu_active
//   14..16 X0..X2  x_pl[k*26 +: 26]: spare inputs for signals that exist only
//                on another branch (issue #176's h_so / nxt_early / cc_aud_low).
//                Tied off on main.
//
// ★ SIMULTANEOUS EVENTS. One RAM write per cycle, up to 16 sources. Each source
// has a PENDING bit; the highest-priority pending source is written each cycle
// (so 16 at once take 16 cycles, < 1 us, well under one 11 us STC tick). A
// source that fires again while still pending (not being written this cycle) is
// a MERGE: its two events become one entry, and `merges` counts it. GPRM is top
// priority with a set-wins-over-clear pending bit, so a write every cycle (the
// mount clear) is logged without a single merge. Payloads are LATCHED for the
// sources whose data is transient (GPRM, STC_JUMP, JOY, FLUSH and STATE's
// change mask, X0..X2) and read LIVE at the write for the ones whose data is
// state that holds (cell, PGC, button counts, ps2_key, aud_frames): that is
// ~110 flops instead of 16 x 26.
// Ordering: entries are in write order. Events in one cycle are written in
// priority order; an event delayed behind higher-priority ones is at most 15
// cycles late, which neither timestamp can resolve.
//
// ★ NEVER SILENT. FIFO full: the event is DROPPED and `ovf` counts it -- holding
// it would only mis-time it. Both counters are 16-bit, wrapping, reset by the
// core reset only, and ride every drain's header; the host differences them.
//
// READOUT (command 0x7C, the dvd_telem protocol: io_enable frames, io_strobe
// clocks one word, the first strobe carries the command, the word answered at
// strobe k is word k)
//   word 0  MAGIC 0x5E01 -- bit 15 clear. A core without this module never
//           drives the bus for 0x7C and hps_io answers 0 (it zeroes io_dout on
//           every strobe of a command it does not know), so 0 = ABSENT.
//   word 1  N      entries in this reply, min(fill, MAXN = 64), latched at the command
//   word 2  fill   entries in the FIFO at the command (0..256): fill > N = more waiting
//   word 3  ovf    events dropped because the FIFO was full (wrapping)
//   word 4  merges events merged into a pending one (wrapping)
//   word 5  free_now[31:16]   word 6  free_now[15:0]   (90 kHz free tick at the command)
//   word 7  {15'd0, stc_now[32]}  word 8 stc_now[31:16]  word 9 stc_now[15:0]
//   words 10 .. 10+5N-1  N entries, five words each, oldest first
//   any further word: 0
// An entry is popped when its LAST word is strobed out, so a transaction cut
// short loses nothing: the partly read entry is read again next time.
//
// ★ M10K READ-AHEAD. The RAM's read port is free-running on the read pointer
// (q <= mem[rptr] every cycle), so the head entry is always waiting in q; a pop
// at word 4 has the next entry in q one cycle later. The words of one entry are
// muxed straight out of q, which cannot change under them: rptr holds, and the
// writer cannot reach an unread slot. Strobes must therefore be >= 2 clk_sys
// cycles apart -- the HPS's are microseconds apart (bench arm [proto] runs at 2).
//
// LIMITS
//   * fts aliases for an entry older than 23.3 s at its drain (the first drain
//     after the harness arms can carry such a backlog; dvd_ctl tags that drain).
//   * STC_JUMP deltas beyond +/-372 s alias mod 2^26; the new STC is exact.
//   * Live payloads show the value at the write, up to 15 cycles after the event.
//   * GPRMs only (data RAM 0x00..0x0F); SPRM writes are not logged.
//============================================================================

module nav_trace #(
    parameter [15:0] CMD   = 16'h007C,   // free: Main uses 0x00-0x44, 0x61-63, 0xF0-F9; 0x7A/0x7B are dvd_telem
    parameter [15:0] MAGIC = 16'h5E01,
    parameter [6:0]  MAXN  = 7'd64       // entries per drain: 10 + 5*64 = 330 SPI words
) (
    input         clk,                   // clk_sys
    input         rst_n,                 // core reset only: the log survives flushes

    // --- EXT_BUS side (from hps_io) -------------------------------------
    input         io_enable,
    input         io_strobe,
    input  [15:0] io_din,
    output        drive,
    output [15:0] dout,

    // --- clocks ----------------------------------------------------------
    input         tick,                  // 90 kHz, one clk pulse (emu's clk_sys/300)
    input  [32:0] stc,                   // av_stc

    // --- event sources (all clk_sys) -------------------------------------
    input         gprm_we,               // dvd_vm GPRM write snoop
    input   [3:0] gprm_a,
    input  [15:0] gprm_d,
    input  [24:0] joy_rise,              // joy_eff press edges
    input  [24:0] kbd_joy,               // kbd_map's pulses (source flag)
    input  [10:0] ps2_key,               // hps_io: [10] toggles per event
    input         btn_act,               // nav_pci btn_cmd_valid
    input   [5:0] btn_sel,
    input   [5:0] btn_ns,                // nav_pci dbg_btn_ns
    input         cell_cmd,              // vm_cell_cmd pulse
    input   [7:0] cell_cmdnr,
    input         hli_arm,               // nav_pci hli_arm pulse
    input  [31:0] h_sptm,                // nav_pci: the promoted HLI's start PTS
    input         btns_armed,
    input   [7:0] cur_cell,
    input   [7:0] cur_vts,
    input  [15:0] cur_pgcn,
    input         menu_active,
    input   [5:0] flush,                 // {soft, mount, seek, aud_resync, aud_flush, load} levels
    input         aud_low,               // emu's aud_ring_low
    input  [15:0] aud_frames,
    input         pause,
    input         still,
    input         video_live,
    input   [2:0] x_ev,                  // spare pulses (#176 hooks), tied 0 on main
    input  [77:0] x_pl                   // their payloads, 26 bits each
);

    localparam int NS = 16;
    localparam [3:0] S_GPRM = 4'd0,  S_STC  = 4'd1,  S_JOY  = 4'd2,  S_PS2   = 4'd3,
                     S_BTN  = 4'd4,  S_CCMD = 4'd5,  S_HLI  = 4'd6,  S_ARMED = 4'd7,
                     S_CELL = 4'd8,  S_PGC  = 4'd9,  S_FLSH = 4'd10, S_AUDL  = 4'd11,
                     S_STAT = 4'd12, S_X0   = 4'd13, S_X1   = 4'd14, S_X2    = 4'd15;

    // ---- free-running 90 kHz count ----------------------------------------
    reg [32:0] free;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)    free <= 33'd0;
        else if (tick) free <= free + 33'd1;

    // ---- edge detectors (prev registers start at 0, so the state at reset
    //      release is logged once -- deliberately: it is the log's baseline) ----
    reg  [32:0] stc_p;
    reg         ps2_t, armed_p, low_p;
    reg   [7:0] cell_p, vts_p;
    reg  [15:0] pgcn_p;
    reg         menu_p;
    reg   [5:0] flush_p;
    reg   [3:0] st_p;
    wire  [3:0] st_now  = {menu_active, video_live, still, pause};
    wire [32:0] stc_d   = stc - stc_p;
    wire        stc_jmp = (stc_d != 33'd0) && (stc_d != 33'd1);
    wire  [5:0] fl_rise = flush & ~flush_p;
    wire  [3:0] st_chg  = st_now ^ st_p;

    wire [NS-1:0] ev;
    assign ev[S_GPRM]  = gprm_we;
    assign ev[S_STC]   = stc_jmp;
    assign ev[S_JOY]   = |joy_rise;
    assign ev[S_PS2]   = ps2_key[10] ^ ps2_t;
    assign ev[S_BTN]   = btn_act;
    assign ev[S_CCMD]  = cell_cmd;
    assign ev[S_HLI]   = hli_arm;
    assign ev[S_ARMED] = btns_armed ^ armed_p;
    assign ev[S_CELL]  = (cur_cell != cell_p) || (cur_vts != vts_p);
    assign ev[S_PGC]   = (cur_pgcn != pgcn_p) || (cur_vts != vts_p) || (menu_active != menu_p);
    assign ev[S_FLSH]  = |fl_rise;
    assign ev[S_AUDL]  = aud_low ^ low_p;
    assign ev[S_STAT]  = |st_chg;
    assign ev[S_X0]    = x_ev[0];
    assign ev[S_X1]    = x_ev[1];
    assign ev[S_X2]    = x_ev[2];

    // ---- pending bits + latched payloads ------------------------------------
    reg  [NS-1:0] pend;
    reg  [19:0] l_gprm;
    reg  [25:0] l_stc, l_joy;
    reg   [5:0] l_fl;
    reg   [3:0] l_stchg;
    reg  [25:0] l_x0, l_x1, l_x2;

    // priority grant: lowest pending index
    reg   [3:0] g_idx;
    reg         g_any;
    integer k;
    always @* begin
        g_idx = 4'd0; g_any = 1'b0;
        for (k = NS - 1; k >= 0; k = k - 1)
            if (pend[k]) begin g_idx = k; g_any = 1'b1; end
    end
    wire [NS-1:0] g_oh = g_any ? (16'd1 << g_idx) : 16'd0;

    // payload of the granted source
    reg  [25:0] g_pl;
    always @* begin
        case (g_idx)
            S_GPRM:  g_pl = {6'd0, l_gprm};
            S_STC:   g_pl = l_stc;
            S_JOY:   g_pl = l_joy;
            S_PS2:   g_pl = {16'd0, ps2_key[9:0]};
            S_BTN:   g_pl = {14'd0, btn_ns, btn_sel};
            S_CCMD:  g_pl = {10'd0, cur_cell, cell_cmdnr};
            S_HLI:   g_pl = {btn_ns, h_sptm[19:0]};
            S_ARMED: g_pl = {19'd0, btns_armed, btn_ns};
            S_CELL:  g_pl = {9'd0, menu_active, cur_vts, cur_cell};
            S_PGC:   g_pl = {1'b0, menu_active, cur_vts, cur_pgcn};
            S_FLSH:  g_pl = {20'd0, l_fl};
            S_AUDL:  g_pl = {9'd0, aud_low, aud_frames};
            S_STAT:  g_pl = {18'd0, l_stchg, st_now};
            S_X0:    g_pl = l_x0;
            S_X1:    g_pl = l_x1;
            default: g_pl = l_x2;
        endcase
    end

    // ---- the FIFO ------------------------------------------------------------
    (* ramstyle = "M10K, no_rw_check" *) reg [79:0] mem [0:255];
    reg  [8:0]  wptr, rptr;               // MSB = wrap bit: fill = wptr - rptr
    reg  [79:0] q;
    wire [8:0]  fill = wptr - rptr;
    wire        full = fill[8];
    wire        we   = g_any && !full;
    wire [79:0] wd   = {{1'b0, g_idx} + 5'd1, g_pl, stc, free[20:5]};

    always @(posedge clk) begin
        if (we) mem[wptr[7:0]] <= wd;
        q <= mem[rptr[7:0]];
    end

    reg [15:0] ovf, merges;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stc_p <= 33'd0; ps2_t <= 1'b0; armed_p <= 1'b0; low_p <= 1'b0;
            cell_p <= 8'd0; vts_p <= 8'd0; pgcn_p <= 16'd0; menu_p <= 1'b0;
            flush_p <= 6'd0; st_p <= 4'd0;
            pend <= {NS{1'b0}};
            l_gprm <= 20'd0; l_stc <= 26'd0; l_joy <= 26'd0; l_fl <= 6'd0; l_stchg <= 4'd0;
            l_x0 <= 26'd0; l_x1 <= 26'd0; l_x2 <= 26'd0;
            wptr <= 9'd0; ovf <= 16'd0; merges <= 16'd0;
        end else begin
            stc_p <= stc; ps2_t <= ps2_key[10]; armed_p <= btns_armed; low_p <= aud_low;
            cell_p <= cur_cell; vts_p <= cur_vts; pgcn_p <= cur_pgcn; menu_p <= menu_active;
            flush_p <= flush; st_p <= st_now;

            // set wins over clear: a source granted this cycle that fires again
            // stays pending with its new payload
            pend <= (pend & ~g_oh) | ev;
            if (|(ev & pend & ~g_oh)) merges <= merges + 16'd1;

            // latched payloads: a fresh event replaces (GPRM, STC, JOY, X) or,
            // for the masks, accumulates into a still-pending one
            if (ev[S_GPRM]) l_gprm <= {gprm_a, gprm_d};
            if (ev[S_STC])  l_stc  <= stc_d[25:0];
            if (ev[S_JOY])  l_joy  <= {|(joy_rise & kbd_joy), joy_rise};
            if (ev[S_FLSH]) l_fl   <= (pend[S_FLSH] && !g_oh[S_FLSH]) ? (l_fl | fl_rise) : fl_rise;
            if (ev[S_STAT]) l_stchg <= (pend[S_STAT] && !g_oh[S_STAT]) ? (l_stchg | st_chg) : st_chg;
            if (ev[S_X0])   l_x0   <= x_pl[25:0];
            if (ev[S_X1])   l_x1   <= x_pl[51:26];
            if (ev[S_X2])   l_x2   <= x_pl[77:52];

            if (we) wptr <= wptr + 9'd1;
            else if (g_any) ovf <= ovf + 16'd1;   // full: dropped, and counted
        end
    end

    // ---- readout ---------------------------------------------------------------
    reg  [3:0]  wcnt;                     // header word index, saturates at 10
    reg  [2:0]  wi;                       // word within the current entry
    reg  [6:0]  left;                     // entries still to send
    reg         active;
    reg  [15:0] dout_r;
    reg  [6:0]  n_r;
    reg  [8:0]  fill_r;
    reg  [31:0] free_s;
    reg  [32:0] stc_s;

    wire [15:0] qw = (wi == 3'd0) ? q[79:64] :
                     (wi == 3'd1) ? q[63:48] :
                     (wi == 3'd2) ? q[47:32] :
                     (wi == 3'd3) ? q[31:16] : q[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt <= 4'd0; wi <= 3'd0; left <= 7'd0; active <= 1'b0; dout_r <= 16'd0;
            rptr <= 9'd0; n_r <= 7'd0; fill_r <= 9'd0; free_s <= 32'd0; stc_s <= 33'd0;
        end else if (!io_enable) begin
            wcnt <= 4'd0; wi <= 3'd0; left <= 7'd0; active <= 1'b0; dout_r <= 16'd0;
        end else if (io_strobe) begin
            if (wcnt != 4'd10) wcnt <= wcnt + 4'd1;
            if (wcnt == 4'd0) begin
                active <= (io_din == CMD);
                if (io_din == CMD) begin
                    n_r    <= (fill > {2'd0, MAXN}) ? MAXN : fill[6:0];
                    left   <= (fill > {2'd0, MAXN}) ? MAXN : fill[6:0];
                    fill_r <= fill;
                    free_s <= free[31:0];
                    stc_s  <= stc;
                    dout_r <= MAGIC;
                end
            end else if (active) begin
                case (wcnt)
                    4'd1: dout_r <= {9'd0, n_r};
                    4'd2: dout_r <= {7'd0, fill_r};
                    4'd3: dout_r <= ovf;
                    4'd4: dout_r <= merges;
                    4'd5: dout_r <= free_s[31:16];
                    4'd6: dout_r <= free_s[15:0];
                    4'd7: dout_r <= {15'd0, stc_s[32]};
                    4'd8: dout_r <= stc_s[31:16];
                    4'd9: dout_r <= stc_s[15:0];
                    default:
                        if (left != 7'd0) begin
                            dout_r <= qw;
                            if (wi == 3'd4) begin
                                wi   <= 3'd0;
                                left <= left - 7'd1;
                                rptr <= rptr + 9'd1;     // popped on its LAST word
                            end else wi <= wi + 3'd1;
                        end else dout_r <= 16'd0;
                endcase
            end
        end
    end

    assign drive = active;
    assign dout  = dout_r;

endmodule
