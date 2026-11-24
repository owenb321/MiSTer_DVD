// trick_demux_tb.sv -- ps_demux with aud_drop (trick play, docs/trick_play.md).
//
// Streams a program-stream file through dvd/ps_demux.sv and reports what came out:
//   +IN=<ps file>  +VID=<video ES out>  +DROP=<0|1>  +AUDREADY=<0|1>  +SP=<0|1>
// Prints "aud <n> sp <n> vid <n> in <n>/<len> stall <0|1>" then DONE. A stall is the
// input making no progress for 200,000 cycles before it is exhausted (with aud_ready
// low and audio not dropped, the demux waits on the audio ring for ever: the reason
// aud_drop exists). Every input is tied (CLAUDE.md: an unconnected input floats Z).
`timescale 1ns/1ps

module trick_demux_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg  [7:0] in_byte = 0;
    reg        in_valid = 0;
    wire       in_ready;
    reg        drop = 0, aud_rdy = 1, sp_en = 0;

    wire [7:0] vid_byte, aud_byte, sp_byte;
    wire       vid_valid, aud_valid, sp_valid;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .aud_drop(drop), .aud_realign(1'b0),
        .sp_track(5'd0), .sp_enable(sp_en),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1), .vid_mark(),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(), .aud_frame_start(),
        .aud_ready(aud_rdy),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .aud_frame_pts(), .aud_frame_pts_valid(),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
        .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
        .aud_lpcm_quant(), .aud_lpcm_nch_m1(), .aud_lpcm_fs96(), .aud_lpcm_bad(),
        .pes_scrambled(), .pes_hdr_ok(),
        .aud_ss_seen(), .aud_ss_id(), .aud_pes_hit(),
        .saw_pack(),
        .jn_en(1'b0), .jn_go(1'b0), .jn_wait()
    );

    string  inp, vidp;
    integer fi, fo, ch, a;
    integer n_in = 0, n_aud = 0, n_sp = 0, n_vid = 0, idle = 0, stall = 0;
    reg     eof = 0, took = 0;

    always @(posedge clk) if (rst_n) begin
        if (aud_valid && aud_rdy) n_aud <= n_aud + 1;
        if (sp_valid) n_sp <= n_sp + 1;
        if (vid_valid) begin $fwrite(fo, "%c", vid_byte); n_vid <= n_vid + 1; end
    end

    initial begin
        if (!$value$plusargs("IN=%s", inp)) $fatal(1, "need +IN=");
        if (!$value$plusargs("VID=%s", vidp)) $fatal(1, "need +VID=");
        if ($value$plusargs("DROP=%d", a)) drop = a[0];
        if ($value$plusargs("AUDREADY=%d", a)) aud_rdy = a[0];
        if ($value$plusargs("SP=%d", a)) sp_en = a[0];
        fi = $fopen(inp, "rb");
        if (fi == 0) $fatal(1, "cannot open %s", inp);
        fo = $fopen(vidp, "wb");
        repeat (4) @(posedge clk);
        rst_n = 1;
        ch = $fgetc(fi);
        if (ch < 0) $fatal(1, "empty input");
        in_byte = ch[7:0];
        in_valid = 1;
        while (!eof && !stall) begin
            // the handshake is decided before the edge; change inputs just after it
            @(negedge clk);
            took = in_valid && in_ready;
            @(posedge clk);
            #1;
            if (took) begin
                n_in = n_in + 1;
                idle = 0;
                ch = $fgetc(fi);
                if (ch < 0) begin eof = 1; in_valid = 0; end
                else in_byte = ch[7:0];
            end else begin
                idle = idle + 1;
                if (idle > 200_000) stall = 1;
            end
        end
        repeat (200) @(posedge clk);
        $fclose(fo);
        $display("aud %0d sp %0d vid %0d in %0d stall %0d", n_aud, n_sp, n_vid, n_in, stall);
        $display("DONE");
        $finish;
    end
endmodule
