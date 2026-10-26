//============================================================================
// vm_snap.sv -- the DVD VM's state snapshot, buffered for the HPS (EXT_BUS 0x7D).
//
// WHAT IT IS FOR. Save states, step 2 (docs/nav_engine.md "State snapshot"): read the
// whole navigation state out of the running core -- the VM's data RAM (GPRMs, counter
// modes, RSM, the fallback chain), every SPRM as a command would read it, the wrapper's
// own state, and the playback position -- consistently, without changing anything the
// VM does. On its own it lets nav_diff compare the full state at a park and lets a bug
// report carry it; step 3 (restore) will read the same words back.
//
// HOW. The HPS asks (control word bit 0 of a 0x7D transaction); when that transaction
// ENDS, this module raises snap_req. dvd_vm's microcode (vm.uasm E_SNAP) takes it the
// next time the VM is at rest -- nothing pending, so no word can change while the
// stream runs -- and writes USNAP_WORDS words here, one per snap_we, then snap_done.
// The position is latched on snap_done, so it is the position of the same instant.
// The HPS polls until `seq` moves and `busy` is clear, then reads the words.
//
// ★ WHY THE REQUEST WAITS FOR THE TRANSACTION'S END. The stream takes ~300 clk_sys
// cycles; a request raised mid-transaction would overwrite the buffer while the same
// transaction reads it. Requesting and reading are therefore always separate
// transactions, and a reader that sees busy = 0 and a new seq has a whole snapshot.
//
// READOUT (the dvd_telem / nav_trace protocol: io_enable frames, io_strobe clocks one
// word, the first strobe carries the command, the word answered at strobe k is word k;
// io_din at strobe 1 is the host's control word)
//   word 0  MAGIC 0x5E02 -- bit 15 clear: a core without this module never drives the
//           bus for 0x7D and hps_io answers 0, so 0 = ABSENT
//   word 1  seq      completed snapshots (wrapping), latched at the command
//   word 2  {busy, 7'd0, len[7:0]}  busy = requested, not yet complete; len = words in
//           the last completed snapshot (0 = none yet)
//   word 3  fmt      the layout id the words follow (tools/nav_isa.py snap_fmt())
//   word 4  {14'd0, pos_fresh, has_video}  pos_fresh = a NAV pack has been parsed since
//           the last flush (else the position below is stale); has_video = that VOBU's
//           1stref_ea != 0, i.e. it carries a picture (docs/save_states.md §5g: a
//           restore must not land in a VOBU without one)
//   word 5,6    nv_pck_lbn[31:16], [15:0]   the playhead: the VOBU on screen
//   word 7,8    prev_video[31:16], [15:0]   VOBU_SRI prev_video: the last VOBU with video
//   word 9,10   c_eltm[31:16], [15:0]       cell elapsed time (BCD)
//   word 11     vob_idn
//   word 12     {8'd0, c_idn}
//   words 13 .. 13+len-1   the snapshot, tools/nav_isa.py snap_layout() order
//   any further word: 0
//   control word (io_din at strobe 1): bit 0 = take a new snapshot when this
//   transaction ends
//
// ★ M10K READ-AHEAD, as nav_trace: the buffer's read port runs free on raddr, set one
// strobe ahead, so strobes must be >= 2 clk_sys cycles apart (the HPS's are us apart).
//
// LIMITS
//   * A mount (dvd_vm `start`) aborts a running stream: snap_done never comes, busy
//     stays set. The host times out and asks again; a new request restarts the buffer.
//   * A request while the VM never comes to rest (a jump waiting on its verdict) waits
//     for the VM's own give-up timer (~0.62 s).
//============================================================================

module vm_snap #(
    parameter [15:0] CMD   = 16'h007D,   // free: Main 0x00-0x44, 0x61-63, 0xF0-F9; 0x7A/0x7B dvd_telem, 0x7C nav_trace
    parameter [15:0] MAGIC = 16'h5E02
) (
    input         clk,                   // clk_sys
    input         rst_n,                 // core reset only

    // --- EXT_BUS side (from hps_io) -------------------------------------
    input         io_enable,
    input         io_strobe,
    input  [15:0] io_din,
    output        drive,
    output [15:0] dout,

    // --- dvd_vm ------------------------------------------------------------
    output reg    snap_req,              // pulse: take a snapshot at the next rest
    input         snap_we,
    input  [15:0] snap_d,
    input         snap_done,
    input  [15:0] snap_fmt,

    // --- the position (nav_dsi, clk_sys; on pipe_rst_n) ------------------------
    input         pos_clr,               // load_flush: nav_dsi's fields go stale
    input         pos_commit,            // dsi_commit: a NAV pack was parsed
    input  [31:0] nv_pck_lbn,
    input  [31:0] first_ref_ea,          // dsi_1stref_ea: 0 = no picture in this VOBU
    input  [31:0] prev_video,
    input  [31:0] c_eltm,
    input  [15:0] vob_idn,
    input   [7:0] c_idn
);

    localparam [3:0] HDR = 4'd13;

    // ---- the buffer ---------------------------------------------------------
    (* ramstyle = "M10K, no_rw_check" *) reg [15:0] buf_m [0:127];
    reg  [6:0]  wa, raddr;
    reg  [15:0] q;
    always @(posedge clk) begin
        if (snap_we) buf_m[wa] <= snap_d;
        q <= buf_m[raddr];
    end

    // ---- the snapshot's bookkeeping and its position ----------------------------
    reg         busy, req_l, fresh;
    reg  [15:0] seq;
    reg  [7:0]  len;
    reg         p_fresh, p_video;
    reg  [31:0] p_lbn, p_prev, p_eltm;
    reg  [15:0] p_vob;
    reg  [7:0]  p_cid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_req <= 1'b0; busy <= 1'b0; wa <= 7'd0; seq <= 16'd0; len <= 8'd0;
            fresh <= 1'b0; p_fresh <= 1'b0; p_video <= 1'b0;
            p_lbn <= 32'd0; p_prev <= 32'd0; p_eltm <= 32'd0; p_vob <= 16'd0; p_cid <= 8'd0;
        end else begin
            snap_req <= 1'b0;
            if (pos_clr)         fresh <= 1'b0;
            else if (pos_commit) fresh <= 1'b1;
            // the request fires when the transaction that carried it ends
            if (!io_enable && req_l) begin
                snap_req <= 1'b1; busy <= 1'b1; wa <= 7'd0;
            end else if (snap_we && wa != 7'd127) wa <= wa + 7'd1;
            if (snap_done) begin
                busy <= 1'b0; seq <= seq + 16'd1;
                len  <= {1'b0, wa};          // snap_done trails the last word by a cycle
                p_fresh <= fresh; p_video <= |first_ref_ea;
                p_lbn <= nv_pck_lbn; p_prev <= prev_video; p_eltm <= c_eltm;
                p_vob <= vob_idn; p_cid <= c_idn;
            end
        end
    end

    // ---- readout ---------------------------------------------------------------
    reg  [3:0]  wcnt;                    // header word index, saturates at HDR
    reg         active;
    reg  [15:0] dout_r;
    reg  [7:0]  left;                    // payload words still to send
    reg  [15:0] seq_s;
    reg  [7:0]  len_s;
    reg         busy_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt <= 4'd0; active <= 1'b0; dout_r <= 16'd0; left <= 8'd0; raddr <= 7'd0;
            seq_s <= 16'd0; len_s <= 8'd0; busy_s <= 1'b0; req_l <= 1'b0;
        end else if (!io_enable) begin
            wcnt <= 4'd0; active <= 1'b0; dout_r <= 16'd0; left <= 8'd0; req_l <= 1'b0;
        end else if (io_strobe) begin
            if (wcnt != HDR) wcnt <= wcnt + 4'd1;
            if (wcnt == 4'd0) begin
                active <= (io_din == CMD);
                if (io_din == CMD) begin
                    seq_s  <= seq;
                    len_s  <= len;
                    busy_s <= busy;
                    left   <= busy ? 8'd0 : len;   // never stream a buffer being written
                    dout_r <= MAGIC;
                end
            end else if (active) begin
                case (wcnt)
                    4'd1: begin dout_r <= seq_s; req_l <= io_din[0]; end
                    4'd2: dout_r <= {busy_s, 7'd0, len_s};
                    4'd3: dout_r <= snap_fmt;
                    4'd4: dout_r <= {14'd0, p_fresh, p_video};
                    4'd5: dout_r <= p_lbn[31:16];
                    4'd6: dout_r <= p_lbn[15:0];
                    4'd7: dout_r <= p_prev[31:16];
                    4'd8: dout_r <= p_prev[15:0];
                    4'd9: dout_r <= p_eltm[31:16];
                    4'd10: dout_r <= p_eltm[15:0];
                    4'd11: dout_r <= p_vob;
                    4'd12: begin dout_r <= {8'd0, p_cid}; raddr <= 7'd0; end   // read-ahead
                    default:
                        if (left != 8'd0) begin
                            dout_r <= q;
                            left   <= left - 8'd1;
                            raddr  <= raddr + 7'd1;
                        end else dout_r <= 16'd0;
                endcase
            end
        end
    end

    assign drive = active;
    assign dout  = dout_r;

endmodule
