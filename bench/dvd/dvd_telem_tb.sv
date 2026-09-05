`timescale 1ns/1ps
//============================================================================
// dvd_telem_tb -- the EXT_BUS telemetry responder.
//
// Four properties, the middle two being the ones that fail silently:
//   [1] a matching command returns MAGIC then the counters, in order
//   [2] a NON-matching command never drives the bus (hijacking another
//       command would break unrelated Main <-> core traffic, and the symptom
//       would appear nowhere near here)
//   [3] the snapshot is ATOMIC: counters changing mid-transaction must not
//       appear in the readout. Without this the words are samples taken
//       milliseconds apart and the refresh/pickup ratio this exists to measure
//       becomes noise rather than a number.
//   [4] the CDC stability filter never commits a mid-increment value
//============================================================================
module dvd_telem_tb;
    reg clk = 0;
    always #5 clk = ~clk;                     // 100 MHz, arbitrary

    reg         io_enable = 0, io_strobe = 0;
    reg  [15:0] io_din = 0;
    wire        drive;
    wire [15:0] dout;

    reg [15:0] refreshes = 16'h1111, pickups = 16'h2222, lates = 16'h3333;
    reg [15:0] drops = 16'h4444, vid_err = 16'h5555, drop_costs = 16'h6666;
    reg [15:0] aud_frames = 16'h8888;
    reg  [7:0] vbuf_fill = 8'h77, flags = 8'h07;
    reg [15:0] aud_play = 16'h9999, aud_gate = 16'hA0A0;

    integer errors = 0;
    reg [15:0] got [0:11];

    dvd_telem dut (
        .clk(clk), .io_enable(io_enable), .io_strobe(io_strobe),
        .io_din(io_din), .drive(drive), .dout(dout),
        .refreshes(refreshes), .pickups(pickups), .lates(lates),
        .drops(drops), .vid_err(vid_err), .drop_costs(drop_costs),
        .vbuf_fill(vbuf_fill), .aud_frames(aud_frames), .flags(flags),
        .aud_play(aud_play), .aud_gate(aud_gate));

    task strobe(input [15:0] d);
        begin
            @(negedge clk); io_din = d; io_strobe = 1;
            @(negedge clk); io_strobe = 0;
            @(negedge clk);
        end
    endtask

    // Read a transaction. `disturb` changes the counters after the command
    // word, which is how [3] is tested.
    task run_xact(input [15:0] cmd, input disturb, output drove);
        integer i;
        begin
            drove = 0;
            @(negedge clk); io_enable = 1;
            strobe(cmd);
            got[0] = dout;
            if (drive) drove = 1;
            if (disturb) begin
                refreshes = 16'hAAAA; pickups = 16'hBBBB; lates = 16'hCCCC;
                drops = 16'hDDDD; vid_err = 16'hEEEE;
                repeat (8) @(negedge clk);     // let the syncs settle too
            end
            for (i = 1; i <= 10; i = i + 1) begin
                strobe(16'd0);
                got[i] = dout;
                if (drive) drove = 1;
            end
            @(negedge clk); io_enable = 0;
            @(negedge clk);
        end
    endtask

    task check(input [127:0] name, input [15:0] a, input [15:0] b);
        begin
            if (a !== b) begin
                $display("  FAIL %0s: got %04h want %04h", name, a, b);
                errors = errors + 1;
            end else
                $display("  ok   %0s = %04h", name, a);
        end
    endtask

    reg drove;
    initial begin
        repeat (20) @(negedge clk);

        $display("[1] matching command returns MAGIC then the counters");
        run_xact(16'h007A, 1'b0, drove);
        check("magic",     got[0], 16'hD7D1);
        check("refreshes", got[1], 16'h1111);
        check("pickups",   got[2], 16'h2222);
        check("lates",     got[3], 16'h3333);
        check("drops",     got[4], 16'h4444);
        check("vid_err",   got[5], 16'h5555);
        check("costs",     got[6], 16'h6666);
        check("vbuf|flags",got[7], 16'h7707);
        check("aud",       got[8], 16'h8888);
        check("aud_play",  got[9], 16'h9999);
        check("aud_gate",  got[10], 16'hA0A0);
        if (!drove) begin
            $display("  FAIL: never drove the bus for its own command");
            errors = errors + 1;
        end

        $display("[2] non-matching command must NOT drive the bus");
        run_xact(16'h0016, 1'b0, drove);       // 0x16 = hps_io's sd command
        if (drove) begin
            $display("  FAIL: hijacked command 0x16");
            errors = errors + 1;
        end else
            $display("  ok   stayed off the bus");

        $display("[3] snapshot is atomic across a disturbed transaction");
        refreshes = 16'h1111; pickups = 16'h2222; lates = 16'h3333;
        drops = 16'h4444; vid_err = 16'h5555;
        repeat (8) @(negedge clk);
        run_xact(16'h007A, 1'b1, drove);       // counters change mid-readout
        check("refreshes", got[1], 16'h1111);
        check("pickups",   got[2], 16'h2222);
        check("lates",     got[3], 16'h3333);
        check("drops",     got[4], 16'h4444);
        check("vid_err",   got[5], 16'h5555);

        $display("[4] the next transaction sees the NEW values");
        run_xact(16'h007A, 1'b0, drove);
        check("refreshes", got[1], 16'hAAAA);
        check("pickups",   got[2], 16'hBBBB);

        if (errors == 0) $display("dvd_telem_tb: ALL GREEN");
        else             $display("dvd_telem_tb: FAILURES");
        if (errors != 0) $fatal(1, "%0d failure(s)", errors);
        $finish;
    end
endmodule
