//============================================================================
//  ac3_reframer_ring_tb.sv — integration TB: ac3_reframer -> audio_ring.
//
//  Proves the static-pops fix end to end: with the reframer in front, audio_ring's
//  frames are AC-3 frames, so EVERY committed frame the decoder receives begins
//  with the 0x0B77 sync word — even when the ring OVERFLOWS and drops frames.
//
//  Method: feed a real AC-3 elementary stream (bbb_short_5p1.ac3) through the
//  reframer with simulated ps_demux PES framing (frame_start every PES_SZ bytes),
//  into a deliberately small audio_ring drained by a THROTTLED consumer so the
//  producer outruns it and the ring overflows.  Drain every committed frame and
//  assert its first two bytes are 0x0B 0x77.  Also require overflow_count > 0 so we
//  know the drop path was actually exercised.
//============================================================================
`timescale 1ns/1ps

module ac3_reframer_ring_tb;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n;

    // ---- stimulus ----
    localparam int NBYTES = 19712;
    localparam int PES_SZ = 2016;          // simulated ps_demux PES payload size
    logic [7:0] acdata [0:NBYTES-1];

    // ps_demux-side (reframer input)
    logic [7:0]  in_byte;
    logic        in_valid;
    logic [1:0]  in_type;
    logic        in_frame_start;
    logic [32:0] in_frame_pts;
    logic        in_frame_pts_valid;

    // reframer -> audio_ring
    wire [7:0]  rf_byte;  wire rf_valid; wire [1:0] rf_type;
    wire        rf_fs;    wire [32:0] rf_pts; wire rf_pv;

    ac3_reframer rf (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_type(in_type),
        .in_frame_start(in_frame_start),
        .in_frame_pts(in_frame_pts), .in_frame_pts_valid(in_frame_pts_valid),
        .out_byte(rf_byte), .out_valid(rf_valid), .out_type(rf_type),
        .out_frame_start(rf_fs), .out_frame_pts(rf_pts), .out_frame_pts_valid(rf_pv)
    );

    // audio_ring (small, to force overflow)
    wire        out_valid; wire [7:0] out_byte; logic out_ready;
    wire        frame_valid; wire [15:0] frame_len; wire [1:0] frame_type;
    wire [32:0] frame_pts; wire frame_pts_valid; logic frame_pop;
    wire [15:0] frames_available, bytes_available, overflow_count;

    audio_ring #(.BYTE_DEPTH(8192), .FRAME_DEPTH(64)) ring (
        .clk(clk), .rst_n(rst_n),
        .aud_byte(rf_byte), .aud_valid(rf_valid), .aud_type(rf_type),
        .aud_frame_start(rf_fs),
        .aud_frame_pts(rf_pts), .aud_frame_pts_valid(rf_pv),
        .aud_ready(),
        .out_byte(out_byte), .out_valid(out_valid), .out_ready(out_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid), .frame_pop(frame_pop),
        .frames_available(frames_available), .bytes_available(bytes_available),
        .overflow_count(overflow_count)
    );

    integer errs = 0;
    integer frames_checked = 0;
    integer producer_done = 0;

    // AC-3 48 kHz frame size (bytes) from frmsizcod — mirrors the reframer table,
    // used to independently validate the locked frame_len on real data.
    function automatic [15:0] fbytes48 (input [5:0] frmsizcod);
        case (frmsizcod[5:1])
            5'd0:fbytes48=128;  5'd1:fbytes48=160;  5'd2:fbytes48=192;  5'd3:fbytes48=224;
            5'd4:fbytes48=256;  5'd5:fbytes48=320;  5'd6:fbytes48=384;  5'd7:fbytes48=448;
            5'd8:fbytes48=512;  5'd9:fbytes48=640;  5'd10:fbytes48=768; 5'd11:fbytes48=896;
            5'd12:fbytes48=1024;5'd13:fbytes48=1280;5'd14:fbytes48=1536;5'd15:fbytes48=1792;
            5'd16:fbytes48=2048;5'd17:fbytes48=2304;5'd18:fbytes48=2560;default:fbytes48=0;
        endcase
    endfunction

    // ---- THROTTLED consumer FSM: pop a descriptor, read frame_len bytes (slowly),
    //      check the first two bytes are 0x0B 0x77. ----
    typedef enum logic [1:0] { C_IDLE, C_POP, C_READ } cstate_t;
    cstate_t cst;
    logic [15:0] need, idx;
    logic [7:0]  b0, b1, b4;
    logic [2:0]  thr;   // throttle counter (drain slower than producer fills)

    assign frame_pop = (cst == C_POP);
    // read at most ~1 byte every 4 cycles so the 1-byte/cycle producer overflows us
    assign out_ready = (cst == C_READ) && (thr == 3'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst <= C_IDLE; need <= 0; idx <= 0; thr <= 0;
            b0 <= 0; b1 <= 0; b4 <= 0;
        end else begin
            thr <= thr + 3'd1;
            case (cst)
                C_IDLE: if (frame_valid) begin
                    need <= frame_len; idx <= 0; cst <= C_POP;
                end
                C_POP: cst <= C_READ;          // frame_pop pulses this cycle
                C_READ: if (out_valid && out_ready) begin
                    if (idx == 16'd0) b0 <= out_byte;
                    if (idx == 16'd1) begin
                        b1 <= out_byte;
                        if (b0 !== 8'h0B || out_byte !== 8'h77) begin
                            $display("FAIL: committed frame %0d starts %02x %02x (exp 0B 77)",
                                     frames_checked, b0, out_byte);
                            errs <= errs + 1;
                        end
                    end
                    if (idx == 16'd4) b4 <= out_byte;
                    if (idx == need - 16'd1) begin
                        // validate the locked length against the real AC-3 header
                        if ((b4[7:6] == 2'b00) && (fbytes48(b4[5:0]) != 0)
                            && (need !== fbytes48(b4[5:0]))) begin
                            $display("FAIL: frame %0d len=%0d but header frmsizcod implies %0d",
                                     frames_checked, need, fbytes48(b4[5:0]));
                            errs <= errs + 1;
                        end
                        frames_checked <= frames_checked + 1;
                        cst <= C_IDLE;
                    end
                    idx <= idx + 16'd1;
                end
            endcase
        end
    end

    // ---- producer ----
    integer i;
    initial begin
        $readmemh("bench/dvd/test_ac3/bbb_short_5p1.ac3.hex", acdata);
        in_valid=0; in_byte=0; in_type=0; in_frame_start=0;
        in_frame_pts=0; in_frame_pts_valid=0; rst_n=0;
        repeat (5) @(posedge clk); rst_n=1;

        for (i = 0; i < NBYTES; i = i + 1) begin
            @(posedge clk); #1;
            in_byte            = acdata[i];
            in_type            = 2'd0;                 // AC-3
            in_valid           = 1'b1;
            in_frame_start     = (i % PES_SZ == 0);    // simulated PES boundary
            in_frame_pts_valid = (i % PES_SZ == 0);
            in_frame_pts       = 33'h0_0000_1000 + i;  // arbitrary, distinct
        end
        @(posedge clk); #1; in_valid=0; in_frame_start=0; in_frame_pts_valid=0;
        producer_done = 1;

        // let the throttled consumer drain whatever is committed
        repeat (200000) @(posedge clk);

        $display("frames_checked=%0d overflow_count=%0d", frames_checked, overflow_count);
        if (frames_checked < 2) begin
            $display("FAIL: too few frames committed/checked (%0d)", frames_checked); errs=errs+1;
        end
        if (overflow_count == 0) begin
            $display("FAIL: ring never overflowed — test did not exercise the drop path"); errs=errs+1;
        end
        if (errs == 0)
            $display("PASS: ac3_reframer+audio_ring — every committed frame starts 0B77 across %0d overflow drops",
                     overflow_count);
        else
            $display("FAIL: %0d error(s)", errs);
        $finish;
    end
endmodule
