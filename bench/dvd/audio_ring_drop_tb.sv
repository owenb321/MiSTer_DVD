// audio_ring_drop_tb.sv — focused test for the §5d menu-transition splice drop
// (drop_pulse). A committed frame must survive; the in-progress frame at drop_pulse
// and the next few frames must be dropped; then normal committing resumes.
`timescale 1ns/1ps

module audio_ring_drop_tb;
    localparam BD = 256, FD = 16;

    reg          clk = 0, rst_n = 0;
    reg  [7:0]   aud_byte = 0;
    reg          aud_valid = 0;
    reg  [1:0]   aud_type = 0;
    reg          aud_frame_start = 0;
    reg          drop_pulse = 0;
    reg  [32:0]  aud_frame_pts = 0;
    reg          aud_frame_pts_valid = 0;
    wire         aud_ready;
    reg          out_ready = 0, frame_pop = 0;
    wire [7:0]   out_byte;
    wire         out_valid, frame_valid, frame_pts_valid, almost_full;
    wire [1:0]   frame_type;
    wire [15:0]  frame_len, frames_available, bytes_available, overflow_count;
    wire [32:0]  frame_pts;

    audio_ring #(.BYTE_DEPTH(BD), .FRAME_DEPTH(FD)) dut (
        .clk(clk), .rst_n(rst_n), .aud_byte(aud_byte), .aud_valid(aud_valid),
        .aud_type(aud_type), .aud_frame_start(aud_frame_start), .drop_pulse(drop_pulse),
        .aud_frame_pts(aud_frame_pts), .aud_frame_pts_valid(aud_frame_pts_valid),
        .aud_ready(aud_ready), .out_byte(out_byte), .out_valid(out_valid), .out_ready(out_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid), .frame_pop(frame_pop),
        .frames_available(frames_available), .bytes_available(bytes_available),
        .overflow_count(overflow_count), .almost_full(almost_full));

    always #5 clk = ~clk;

    // push one whole frame of `len` bytes all valued `v`
    task push_frame(input integer len, input [7:0] v, input pulse_at_start);
        integer i;
        begin
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk);
                aud_byte  = v + i[7:0];
                aud_valid = 1'b1;
                aud_frame_start = (i == 0);
                drop_pulse = (i == 0) && pulse_at_start;
            end
            @(negedge clk); aud_valid = 0; aud_frame_start = 0; drop_pulse = 0;
        end
    endtask

    integer errors = 0;
    task chk(input cond, input [255:0] msg);
        begin if (!cond) begin errors=errors+1; $display("  ERR %0s", msg); end end
    endtask

    initial begin
        rst_n = 0; repeat (4) @(negedge clk); rst_n = 1;

        // 1) two whole frames commit normally (frame N commits when N+1 starts)
        push_frame(10, 8'hA0, 0);
        push_frame(10, 8'hB0, 0);
        push_frame(10, 8'hC0, 0);       // forces the first two to commit
        repeat (5) @(negedge clk);
        $display("after 3 frames: frames_available=%0d overflow=%0d", frames_available, overflow_count);
        chk(frames_available == 2, "T1 two whole frames committed");

        // 2) drop_pulse at the start of a frame -> that frame + the next 4 are dropped;
        //    then a normal frame commits. overflow_count rises for each dropped frame.
        begin : t2
            integer ov0; integer fa0;
            ov0 = overflow_count; fa0 = frames_available;
            push_frame(10, 8'hD0, 1);   // drop_pulse here -> dropped
            push_frame(10, 8'hE0, 0);   // dropped (drop_cnt)
            push_frame(10, 8'hE1, 0);   // dropped
            push_frame(10, 8'hE2, 0);   // dropped
            push_frame(10, 8'hE3, 0);   // dropped (4th)  -- drop_cnt now 0
            push_frame(10, 8'hF0, 0);   // COMMITS the 0xE3? no: 0xE3 was dropped; this starts clean
            push_frame(10, 8'hF1, 0);   // forces 0xF0 to finalize -> commit
            repeat (5) @(negedge clk);
            $display("after drop window: d_frames=%0d d_overflow=%0d",
                     frames_available - fa0, overflow_count - ov0);
            chk((overflow_count - ov0) >= 4, "T2 at least the drop-window frames were dropped");
            chk(frame_valid, "T2 a clean frame eventually commits after the drop window");
        end

        if (errors == 0) $display("AUDIO_RING_DROP_TB: ALL TESTS PASSED");
        else             $display("AUDIO_RING_DROP_TB: FAILED with %0d errors", errors);
        $finish;
    end

    initial begin #200000; $display("AUDIO_RING_DROP_TB: TIMEOUT"); $finish; end
endmodule
