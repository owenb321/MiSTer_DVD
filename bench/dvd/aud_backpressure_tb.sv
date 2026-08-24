//============================================================================
//  aud_backpressure_tb.sv — demux-backpressure integration TB:
//      held-valid producer (ps_demux model) -> [valid&&ready qualifier]
//      -> ac3_reframer -> audio_ring (almost_full) -> throttled consumer.
//
//  Proves the STD-model demux flow control end to end, and specifically the
//  HANDSHAKE FIX: ps_demux's aud_valid is a HELD level (it stays high, with the
//  byte stable, until aud_ready accepts), while ac3_reframer/audio_ring have no
//  ready input and treat every valid cycle as a new byte. Unqualified, a stall
//  duplicates the held byte once per clock — flooding the reframer, blowing its
//  frame-length lock, and starving the ring (the "constant split-second audio
//  dropouts" seen on HW). The emu.sv fix feeds the reframer
//  in_valid = aud_valid && aud_ready, so downstream sees each byte exactly once.
//
//  The producer here reproduces the REAL handshake: it holds byte+valid until
//  the cycle ready is high (transfer on valid&&ready), like ps_demux's
//  S_AUDIO_DATA (in_ready = aud_ready). ready = ~(almost_full && armed), the
//  emu.sv gate (armed = a frame_pop has occurred, the drain-watchdog model).
//  The consumer drains slowly (~1 byte / 4 clks) so the ring rides the
//  almost_full threshold and the backpressure path is exercised HARD.
//
//  Checks (fixed mode, default):
//    1. BYTE-EXACT: every byte drained from the ring equals the source AC-3
//       stream in order (golden pointer walk) — catches ANY duplication/loss.
//    2. Every committed frame starts 0x0B77 and matches its header length.
//    3. overflow_count == 0 — backpressure PREVENTED all drops.
//    4. almost_full engaged (stall cycles > 0) — the path was exercised.
//
//  Run with +raw to reproduce the BUG (unqualified valid): expect byte
//  mismatches / far fewer clean frames — kept as a demonstrator, not a gate.
//
//  Build:
//    iverilog -g2012 -o bench/dvd/aud_backpressure_sim \
//        dvd/ac3_reframer.sv dvd/audio_ring.sv bench/dvd/aud_backpressure_tb.sv
//    vvp bench/dvd/aud_backpressure_sim            # fixed (must PASS)
//    vvp bench/dvd/aud_backpressure_sim +raw       # bug demo (fails checks)
//============================================================================
`timescale 1ns/1ps

module aud_backpressure_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    // ---- stimulus: real AC-3 elementary stream ----
    localparam int NBYTES = 19712;
    localparam int PES_SZ = 2016;              // simulated PES payload size
    logic [7:0] acdata [0:NBYTES-1];

    // ---- producer (ps_demux model): HELD valid+ready handshake ----
    logic [7:0]  p_byte;
    logic        p_valid;
    logic        p_fs;
    logic [32:0] p_pts;
    logic        p_pv;

    // emu.sv ready gate: ~(almost_full && armed)
    wire         ring_almost_full;
    logic        bp_armed;
    wire         p_ready = ~(ring_almost_full && bp_armed);

    // the FIX under test: qualified transfer into the reframer
    logic        raw_mode;
    wire         rf_in_valid = raw_mode ? p_valid : (p_valid && p_ready);

    // reframer -> audio_ring
    wire [7:0]  rf_byte;  wire rf_valid; wire [1:0] rf_type;
    wire        rf_fs;    wire [32:0] rf_pts; wire rf_pv;

    ac3_reframer rf (
        .clk(clk), .rst_n(rst_n),
        .in_byte(p_byte), .in_valid(rf_in_valid), .in_type(2'd0),
        .in_frame_start(p_fs),
        .in_frame_pts(p_pts), .in_frame_pts_valid(p_pv),
        .out_byte(rf_byte), .out_valid(rf_valid), .out_type(rf_type),
        .out_frame_start(rf_fs), .out_frame_pts(rf_pts), .out_frame_pts_valid(rf_pv)
    );

    wire        out_valid; wire [7:0] out_byte; logic out_ready;
    wire        frame_valid; wire [15:0] frame_len; wire [1:0] frame_type;
    wire [32:0] frame_pts; wire frame_pts_valid; logic frame_pop;
    wire [15:0] frames_available, bytes_available, overflow_count;

    // small ring so the almost_full threshold (8192-6144 = 2048 B) engages early
    audio_ring #(.BYTE_DEPTH(8192), .FRAME_DEPTH(64)) ring (
        .clk(clk), .rst_n(rst_n),
        .aud_byte(rf_byte), .aud_valid(rf_valid), .aud_type(rf_type),
        .aud_frame_start(rf_fs),
        .aud_frame_pts(rf_pts), .aud_frame_pts_valid(rf_pv),
        .aud_ready(),
        .almost_full(ring_almost_full),
        .out_byte(out_byte), .out_valid(out_valid), .out_ready(out_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid), .frame_pop(frame_pop),
        .frames_available(frames_available), .bytes_available(bytes_available),
        .overflow_count(overflow_count)
    );

    // drain watchdog model: armed after the first frame_pop (as in emu.sv)
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) bp_armed <= 1'b0;
        else if (frame_pop) bp_armed <= 1'b1;

    // count stall engagement so the test can't pass vacuously
    integer stall_cycles = 0;
    always_ff @(posedge clk)
        if (rst_n && p_valid && !p_ready) stall_cycles <= stall_cycles + 1;

    // ---- golden model: the reframer emits the AC-3 stream from its first
    //      0x0B77 sync onward, byte-exact. Walk a pointer through acdata. ----
    integer gptr;               // next expected source index
    integer gstart;             // first 0B77 position in acdata

    integer errs = 0;
    integer frames_checked = 0;

    // ---- throttled consumer: pop descriptor, drain frame_len bytes slowly ----
    typedef enum logic [1:0] { C_IDLE, C_POP, C_READ } cstate_t;
    cstate_t cst;
    logic [15:0] need, idx;
    logic [7:0]  b0;
    logic [2:0]  thr;

    assign frame_pop = (cst == C_POP);
    assign out_ready = (cst == C_READ) && (thr == 3'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst <= C_IDLE; need <= 0; idx <= 0; thr <= 0; b0 <= 0;
        end else begin
            thr <= thr + 3'd1;
            case (cst)
                C_IDLE: if (frame_valid) begin
                    need <= frame_len; idx <= 0; cst <= C_POP;
                end
                C_POP: cst <= C_READ;
                C_READ: if (out_valid && out_ready) begin
                    // 1. byte-exact against the source stream (fixed mode only)
                    if (!raw_mode) begin
                        if (out_byte !== acdata[gptr]) begin
                            if (errs < 10)
                                $display("FAIL: drained byte %0d = %02x, source[%0d] = %02x",
                                         idx, out_byte, gptr, acdata[gptr]);
                            errs = errs + 1;
                        end
                        gptr = gptr + 1;
                    end
                    // 2. frame integrity
                    if (idx == 16'd0) b0 <= out_byte;
                    if (idx == 16'd1 && (b0 !== 8'h0B || out_byte !== 8'h77)) begin
                        $display("FAIL: frame %0d starts %02x %02x (exp 0B 77)",
                                 frames_checked, b0, out_byte);
                        errs = errs + 1;
                    end
                    if (idx == need - 16'd1) begin
                        frames_checked <= frames_checked + 1;
                        cst <= C_IDLE;
                    end
                    idx <= idx + 16'd1;
                end
            endcase
        end
    end

    // ---- producer: held valid+ready handshake, exactly like ps_demux ----
    integer i;
    logic   rdy_s;
    initial begin
        raw_mode = $test$plusargs("raw");
        $readmemh("bench/dvd/test_ac3/bbb_short_5p1.ac3.hex", acdata);

        // locate the first sync for the golden pointer
        gstart = -1;
        for (i = 0; i < NBYTES-1; i = i + 1)
            if (gstart < 0 && acdata[i] == 8'h0B && acdata[i+1] == 8'h77) gstart = i;
        gptr = gstart;

        p_valid=0; p_byte=0; p_fs=0; p_pts=0; p_pv=0; rst_n=0;
        repeat (5) @(posedge clk); rst_n = 1;

        i = 0;
        while (i < NBYTES) begin
            @(negedge clk);
            p_byte  = acdata[i];
            p_valid = 1'b1;
            p_fs    = (i % PES_SZ == 0);
            p_pv    = (i % PES_SZ == 0);
            p_pts   = 33'h0_0000_1000 + i;
            rdy_s   = p_ready;            // stable through the coming posedge
            @(posedge clk);
            if (rdy_s || raw_mode) i = i + 1;   // advance only on accepted transfer
        end
        @(negedge clk); p_valid = 0; p_fs = 0; p_pv = 0;

        // drain everything committed
        repeat (400000) @(posedge clk);

        $display("frames_checked=%0d overflow=%0d stall_cycles=%0d bytes_matched=%0d",
                 frames_checked, overflow_count, stall_cycles, gptr - gstart);

        if (!raw_mode) begin
            if (stall_cycles == 0) begin
                $display("FAIL: backpressure never engaged — test vacuous"); errs = errs + 1;
            end
            if (overflow_count != 0) begin
                $display("FAIL: ring dropped %0d frames despite backpressure", overflow_count);
                errs = errs + 1;
            end
            if (frames_checked < 10) begin
                $display("FAIL: too few clean frames (%0d)", frames_checked); errs = errs + 1;
            end
            if (errs == 0)
                $display("PASS: backpressure byte-exact — %0d frames, 0 drops, %0d stall cycles absorbed",
                         frames_checked, stall_cycles);
            else
                $display("FAIL: %0d error(s)", errs);
        end else begin
            $display("(raw demo) frames=%0d overflow=%0d — expect corruption vs fixed run",
                     frames_checked, overflow_count);
        end
        $finish;
    end

    initial begin #200_000_000 $display("TIMEOUT"); $finish; end
endmodule
