// iso_reader_subpctl_tb.sv - verify dvd_iso_reader parses the PGC stream
// control tables and streams them out on the shared pgc_ctl_we/waddr/wdata bus
// at PGC load:
//   waddr  0..15 = subp_control[16] @ PGC+0x1C (TITLE domain only) - the data
//                  behind the subpicture display-mode substream mapping (Matrix
//                  "Follow the White Rabbit": logical 1 -> substream 0x22/0x23).
//   waddr 16..23 = audio_control[8] @ PGC+0x0C (EVERY domain) - the libdvdnav
//                  vm_get_audio_stream logical->physical audio map (GET_SMART
//                  VTS2 maps everything to substream 0x83; identity assumed =
//                  the "language menu -> movie plays silent" bug).
// Checks, per the audio-mapping feature:
//   [1] title PGC: audio_control words arrive at 16..23 (values byte-exact),
//       CONTIGUOUS with the subp words (audio first - the walk rolls straight
//       into P_SUBP with no re-seek), subp_control byte-exact as before.
//   [2] pgc_ctl_valid rises only AFTER the last audio word, with pgc_dom_tt=1.
//   [3] title PGC with audio_control[0]=0x8300 resolves like GET_SMART (the
//       shadow check mirrors tools/nav_extract.py --audio-map).

`timescale 1ns/1ps

module iso_reader_subpctl_tb;

    localparam IMG_BYTES = 40*2048;

    reg         clk = 0, rst_n = 0, start = 0;
    reg  [63:0] file_size = 0;

    wire [31:0] sd_lba;   wire sd_rd;
    reg         sd_ack = 0;
    reg  [13:0] sd_buff_addr = 0;
    reg  [7:0]  sd_buff_dout = 0;
    reg         sd_buff_wr = 0;
    wire [7:0]  stream_data;  wire stream_valid;

    wire        pgc_ctl_we;
    wire [4:0]  pgc_ctl_waddr;
    wire [31:0] pgc_ctl_wdata;
    wire        pgc_ctl_valid;
    wire        pgc_dom_tt;

    reg  [7:0]  img [0:IMG_BYTES-1];

    // capture stream-control writes into shadows the test can check
    reg [31:0] cap_mem  [0:15];      // subp_control words
    reg        cap_seen [0:15];
    reg [15:0] cap_aud  [0:7];       // audio_control words
    reg        cap_aseen[0:7];
    reg        valid_at_aud_write;   // pgc_ctl_valid sampled DURING an audio write
    reg        aud_before_subp_ok;   // all 8 audio words landed before subp word 0
    reg        dom_tt_at_valid;
    integer    aud_writes;
    integer k;
    always @(posedge clk) begin
        if (pgc_ctl_we) begin
            if (pgc_ctl_waddr[4]) begin
                cap_aud  [pgc_ctl_waddr[2:0]] <= pgc_ctl_wdata[15:0];
                cap_aseen[pgc_ctl_waddr[2:0]] <= 1'b1;
                aud_writes <= aud_writes + 1;
                if (pgc_ctl_valid) begin
                    valid_at_aud_write <= 1'b1;   // must stay 0
                    $display("  [probe] t=%0t audio write addr=%0d while valid=1 (writes so far %0d)",
                             $time, pgc_ctl_waddr[2:0], aud_writes);
                end
            end else begin
                cap_mem [pgc_ctl_waddr[3:0]] <= pgc_ctl_wdata;
                cap_seen[pgc_ctl_waddr[3:0]] <= 1'b1;
                if (aud_writes != 8) aud_before_subp_ok <= 1'b0; // audio must precede
            end
        end
        if (pgc_ctl_valid) dom_tt_at_valid <= pgc_dom_tt;
    end

    dvd_iso_reader dut (
        .clk(clk), .rst_n(rst_n), .start(start), .file_size(file_size),
        .title_sel(4'd0), .vbuf_empty(1'b0), .menu_snap(1'b0),
        .jump_ttn(7'd0), .jump_pgn(8'd0),
        .vm_mode(1'b0), .vm_adv(1'b0), .vm_replay(1'b0),
        .vm_cell_cmd(), .vm_pgc_end(), .nav_ready_o(), .auto_vts(), .cell_count_o(),
        .pm_we(), .pm_waddr(), .pm_wdata(), .cmd_nr_pgm(),
        .seek_pulse(1'b0), .seek_natural(1'b0), .seek_cell(8'd0), .seek_ack(),
        .seek_rbn_pulse(1'b0), .seek_rbn(32'd0),
        .chap_pulse(1'b0), .chap_dir(1'b0), .chap_mag(5'd1), .chap_at_start(1'b0),
        .angle_pulse(1'b0), .cur_angle(), .angle_count(),
        .keep_vbuf(), .cur_cell(), .cell_ready(),
        .pgc_ctl_we(pgc_ctl_we), .pgc_ctl_waddr(pgc_ctl_waddr), .pgc_ctl_wdata(pgc_ctl_wdata),
        .pgc_ctl_valid(pgc_ctl_valid), .pgc_dom_tt(pgc_dom_tt),
        .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
        .stream_data(stream_data), .stream_valid(stream_valid), .busy(1'b0),
        .debug_active(), .debug_sd_rd(), .debug_sd_ack(), .debug_cache_has_data(),
        .debug_file_size(), .debug_total_sectors(), .debug_next_lba(),
        .debug_state(), .debug_iso_mode(), .debug_iso_error()
    );

    always #5 clk = ~clk;

    // mock HPS: one 512-byte block per sd_rd
    integer m = 0, bc = 0, lat = 0;
    reg [31:0] rlba = 0;
    always @(posedge clk) begin
        sd_buff_wr <= 1'b0;
        case (m)
        0: begin sd_ack <= 1'b0; if (sd_rd) begin rlba <= sd_lba; lat <= 3; m <= 1; end end
        1: begin if (lat != 0) lat <= lat - 1; else begin sd_ack <= 1'b1; bc <= 0; m <= 2; end end
        2: begin sd_ack <= 1'b1; sd_buff_wr <= 1'b1; sd_buff_addr <= bc[13:0];
                 sd_buff_dout <= img[rlba*2048 + bc]; bc <= bc + 1; if (bc == 2047) m <= 3; end
        3: begin sd_ack <= 1'b0; sd_buff_wr <= 1'b0; m <= 0; end
        endcase
    end

    integer i, cur;
    task put_rec(input integer off, input [31:0] ext, input [31:0] dlen,
                 input [7:0] flags, input [127:0] nm, input integer nlen, output integer next_off);
        integer j; integer rl; begin
            rl = 33 + nlen; if (rl[0]) rl = rl + 1;
            img[off+0]=rl[7:0]; img[off+1]=0;
            img[off+2]=ext[7:0]; img[off+3]=ext[15:8]; img[off+4]=ext[23:16]; img[off+5]=ext[31:24];
            for (j=6;j<10;j=j+1) img[off+j]=0;
            img[off+10]=dlen[7:0]; img[off+11]=dlen[15:8]; img[off+12]=dlen[23:16]; img[off+13]=dlen[31:24];
            for (j=14;j<25;j=j+1) img[off+j]=0;
            img[off+25]=flags; for (j=26;j<32;j=j+1) img[off+j]=0;
            img[off+32]=nlen[7:0];
            for (j=0;j<nlen;j=j+1) img[off+33+j]=nm[8*(nlen-1-j) +: 8];
            if ((33+nlen)&1) img[off+33+nlen]=0;
            next_off = off + rl; end
    endtask

    task build; begin
        for (i=0;i<IMG_BYTES;i=i+1) img[i]=8'h00;
        // PVD @16
        img[32768]=8'd1; img[32769]="C"; img[32770]="D"; img[32771]="0"; img[32772]="0"; img[32773]="1"; img[32774]=8'd1;
        put_rec(32768+156, 17, 2048, 8'h02, 128'd0, 1, cur);
        cur=34816; // root @17
        put_rec(cur,17,2048,8'h02,128'h00,1,cur);
        put_rec(cur,17,2048,8'h02,128'h01,1,cur);
        put_rec(cur,18,2048,8'h02,"VIDEO_TS",8,cur);
        cur=36864; // VIDEO_TS @18
        put_rec(cur,17,2048,8'h02,128'h00,1,cur);
        put_rec(cur,17,2048,8'h02,128'h01,1,cur);
        put_rec(cur,19,4096,8'h00,"VIDEO_TS.IFO;1",14,cur);
        put_rec(cur,21,6144,8'h00,"VTS_01_0.IFO;1",14,cur);
        put_rec(cur,24,4*2048,8'h00,"VTS_01_1.VOB;1",14,cur);
        // VMGI TT_SRPT (title 1 -> VTS 1), VTSI_MAT -> VTS_PGCIT @ sector offset 1
        img[19*2048+196]=0; img[19*2048+197]=0; img[19*2048+198]=0; img[19*2048+199]=1;   // vmgm tt_srpt ptr=1
        img[20*2048+0]=0; img[20*2048+1]=1;  img[20*2048+8]=0; img[20*2048+9]=1; img[20*2048+10]=0; img[20*2048+11]=1;
        img[20*2048+12]=0; img[20*2048+13]=0; img[20*2048+14]=1; img[20*2048+15]=1;
        img[21*2048+204]=0; img[21*2048+205]=0; img[21*2048+206]=0; img[21*2048+207]=1;   // VTSI_MAT vts_pgcit=1
        // VTS_PGCIT @ sector 22: nr_srp=1, SRP[0].pgc_start_byte=16
        img[22*2048+0]=0; img[22*2048+1]=1;
        img[22*2048+12]=0; img[22*2048+13]=0; img[22*2048+14]=0; img[22*2048+15]=16;
        // PGC @ (22*2048 + 16): nr_programs@2=1, nr_cells@3=1, cell_pb_off@232=256
        img[22*2048+16+2]=1; img[22*2048+16+3]=1;
        img[22*2048+16+232]=1; img[22*2048+16+233]=0;   // cell_pb_off = 256
        // audio_control @ PGC+0x0C: the GET_SMART VTS2 shape - logical 0/1/2 all
        // available -> PHYSICAL 3 (0x8300); logical 5 -> physical 1 (0x8100)
        img[22*2048+16+16'h0C+0]=8'h83; img[22*2048+16+16'h0C+1]=8'h00;   // [0]=0x8300
        img[22*2048+16+16'h0C+2]=8'h83; img[22*2048+16+16'h0C+3]=8'h00;   // [1]=0x8300
        img[22*2048+16+16'h0C+4]=8'h83; img[22*2048+16+16'h0C+5]=8'h00;   // [2]=0x8300
        img[22*2048+16+16'h0C+10]=8'h81; img[22*2048+16+16'h0C+11]=8'h00; // [5]=0x8100
        // subp_control[1] @ PGC+0x1C+4 = 0x80020300 (BE)
        img[22*2048+16+16'h20+0]=8'h80; img[22*2048+16+16'h20+1]=8'h02;
        img[22*2048+16+16'h20+2]=8'h03; img[22*2048+16+16'h20+3]=8'h00;
        // subp_control[3] @ +0x1C+12 = 0x81000000 (present, all zero map)
        img[22*2048+16+16'h28+0]=8'h81;
        // one cell @ pgc+256: first_sector@8=0, last_sector@20=1
        img[22*2048+16+256+8]=0; img[22*2048+16+256+9]=0; img[22*2048+16+256+10]=0; img[22*2048+16+256+11]=0;
        img[22*2048+16+256+20]=0; img[22*2048+16+256+21]=0; img[22*2048+16+256+22]=0; img[22*2048+16+256+23]=1;
    end endtask

    integer errors = 0;
    initial begin
        for (k=0;k<16;k=k+1) begin cap_mem[k]=0; cap_seen[k]=0; end
        for (k=0;k<8;k=k+1)  begin cap_aud[k]=0; cap_aseen[k]=0; end
        valid_at_aud_write=0; aud_before_subp_ok=1; dom_tt_at_valid=0; aud_writes=0;
        rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);
        build; file_size=IMG_BYTES;
        @(posedge clk); start=1; @(posedge clk); start=0;
        // let the PGC parse run
        repeat (200000) @(posedge clk);
        $display("subp_control capture: [1]=0x%08x (seen=%0d)  [3]=0x%08x (seen=%0d)",
                 cap_mem[1], cap_seen[1], cap_mem[3], cap_seen[3]);
        if (!cap_seen[1] || cap_mem[1] !== 32'h80020300) begin
            errors=errors+1; $display("  FAIL: subp_control[1] expected 0x80020300"); end
        if (!cap_seen[3] || cap_mem[3] !== 32'h81000000) begin
            errors=errors+1; $display("  FAIL: subp_control[3] expected 0x81000000"); end
        // verify the mapping the RTL enables: logical 1, 16:9 wide -> substream 0x22
        if ((32'h80020300 >> 16 & 32'h1f) + 32'h20 !== 32'h22) begin
            errors=errors+1; $display("  FAIL: wide map != 0x22"); end
        // ---- audio_control (this feature) ----
        $display("audio_control capture: [0]=0x%04x [1]=0x%04x [2]=0x%04x [5]=0x%04x (writes=%0d)",
                 cap_aud[0], cap_aud[1], cap_aud[2], cap_aud[5], aud_writes);
        for (k=0;k<8;k=k+1)
            if (!cap_aseen[k]) begin
                errors=errors+1; $display("  FAIL: audio_control[%0d] never written", k); end
        if (cap_aud[0] !== 16'h8300 || cap_aud[1] !== 16'h8300 || cap_aud[2] !== 16'h8300) begin
            errors=errors+1; $display("  FAIL: audio_control[0..2] expected 0x8300"); end
        if (cap_aud[5] !== 16'h8100) begin
            errors=errors+1; $display("  FAIL: audio_control[5] expected 0x8100"); end
        if (cap_aud[3] !== 16'h0000 || cap_aud[4] !== 16'h0000
            || cap_aud[6] !== 16'h0000 || cap_aud[7] !== 16'h0000) begin
            errors=errors+1; $display("  FAIL: absent audio_control words not zero"); end
        if (!aud_before_subp_ok) begin
            errors=errors+1; $display("  FAIL: a subp word arrived before all 8 audio words"); end
        if (valid_at_aud_write) begin
            errors=errors+1; $display("  FAIL: pgc_ctl_valid high during the audio walk"); end
        if (!pgc_ctl_valid) begin
            errors=errors+1; $display("  FAIL: pgc_ctl_valid low after the parse"); end
        if (!dom_tt_at_valid) begin
            errors=errors+1; $display("  FAIL: pgc_dom_tt not 1 for a title PGC"); end
        if (errors==0) $display("ISO_READER_SUBPCTL_TB: ALL TESTS PASSED");
        else           $display("ISO_READER_SUBPCTL_TB: %0d FAILURE(S)", errors);
        $finish;
    end
    initial begin #80000000; $display("TIMEOUT"); $finish; end
endmodule
