//============================================================================
//  audblk_parse_tb.sv — self-checking unit TB for audblk_parse (M4).
//
//  Chain: FIFO -> bit_reader -> audblk_parse.  A block's side info is built
//  bit-by-bit by an independent encoder (putbits), so the field widths in the
//  test come from a separate source than the DUT's FSM — a width disagreement
//  shows up as either a wrong staged value or a wrong final bit count.
//
//  Positive scenario (acmod==2, no coupling/rematrix, long block):
//    blksw=00  dith(ch0=1,ch1=0)  dynrnge=1 dynrng=0x5A  cplstre=1 cplinu=0
//    rematstr=0  chexpstr(ch0=D45, ch1=D25)  chbwcod(ch0=0, ch1=2)
//    exps ch0: first=9, grps 1..6, gainrng=1
//    exps ch1: first=3, grps 10..22, gainrng=2
//    baie=1 bai{sdcy=1 fdcy=2 sgain=3 dbpb=0 floor=5}
//    snroffste=1 csnroffst=33  ch0{fsnr=9 fgain=4}  ch1{fsnr=5 fgain=2}
//    deltbaie=0  skiple=0
//  Derived: endmant0=73 -> nchgrps0=6 (D45);  endmant1=79 -> nchgrps1=13 (D25).
//  Total side-info bits = 212 (cross-checked against the encoder's counter).
//
//  Negative scenarios (each its own chain): short block / cplinu / rematstr all
//  must raise err_unsupported.
//============================================================================

`timescale 1ns/1ps

module audblk_parse_tb;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------------
    // Positive-scenario stream, built bit-by-bit (MSB-first) by putbits.
    // ----------------------------------------------------------------------
    localparam int MAXBITS = 4096;
    logic        bitbuf [0:MAXBITS-1];
    integer      nbit;
    logic [7:0]  s_pos [0:511];
    logic [7:0]  s_n1  [0:511];   // M16: short-block copy of s_pos (built below)
    integer      pos_bytes, pos_bits;

    task automatic putbits(input integer val, input integer n);
        integer i;
        for (i = n-1; i >= 0; i = i - 1) begin
            bitbuf[nbit] = val[i];
            nbit = nbit + 1;
        end
    endtask

    integer bi, by;
    initial begin
        nbit = 0;
        putbits(2'b00, 2);            // blksw  ch0=0 ch1=0
        putbits(2'b10, 2);            // dithflag ch0=1 ch1=0
        putbits(1, 1);                // dynrnge=1
        putbits(8'h5A, 8);            // dynrng (discarded)
        putbits(1, 1);                // cplstre=1
        putbits(0, 1);                // cplinu=0
        putbits(0, 1);                // rematstr=0
        putbits(4'b1110, 4);          // chexpstr ch0=D45(3) ch1=D25(2)
        putbits(6'd0, 6);             // chbwcod0=0  -> endmant0=73, nchgrps0=6
        putbits(6'd2, 6);             // chbwcod1=2  -> endmant1=79, nchgrps1=13
        // ch0 exponents (D45, 6 groups)
        putbits(4'd9, 4);
        putbits(7'd1, 7); putbits(7'd2, 7); putbits(7'd3, 7);
        putbits(7'd4, 7); putbits(7'd5, 7); putbits(7'd6, 7);
        putbits(2'd1, 2);             // gainrng ch0 (discarded)
        // ch1 exponents (D25, 13 groups)
        putbits(4'd3, 4);
        putbits(7'd10,7); putbits(7'd11,7); putbits(7'd12,7); putbits(7'd13,7);
        putbits(7'd14,7); putbits(7'd15,7); putbits(7'd16,7); putbits(7'd17,7);
        putbits(7'd18,7); putbits(7'd19,7); putbits(7'd20,7); putbits(7'd21,7);
        putbits(7'd22,7);
        putbits(2'd2, 2);             // gainrng ch1 (discarded)
        // bit-allocation params
        putbits(1, 1);                // baie=1
        putbits(2'd1, 2);             // sdcycod=1
        putbits(2'd2, 2);             // fdcycod=2
        putbits(2'd3, 2);             // sgaincod=3
        putbits(2'd0, 2);             // dbpbcod=0
        putbits(3'd5, 3);             // floorcod=5
        putbits(1, 1);                // snroffste=1
        putbits(6'd33, 6);            // csnroffst=33
        putbits(4'd9, 4); putbits(3'd4, 3);   // ch0 fsnroffst=9 fgaincod=4
        putbits(4'd5, 4); putbits(3'd2, 3);   // ch1 fsnroffst=5 fgaincod=2
        putbits(0, 1);                // deltbaie=0
        putbits(0, 1);                // skiple=0
        pos_bits  = nbit;
        pos_bytes = (nbit + 7) / 8;
        // pack bits MSB-first into bytes (zero-pad the tail)
        for (by = 0; by < 512; by = by + 1) s_pos[by] = 8'h00;
        for (bi = 0; bi < nbit; bi = bi + 1)
            if (bitbuf[bi]) s_pos[bi/8][7 - (bi%8)] = 1'b1;
        // s_n1 = the same block but with blksw=11 (short block, both channels):
        // the top 2 bits of byte 0 are the nfchans=2 blksw field (ch0,ch1).
        for (by = 0; by < 512; by = by + 1) s_n1[by] = s_pos[by];
        s_n1[0] = s_pos[0] | 8'hC0;
    end

    // ----------------------------------------------------------------------
    // Positive chain + per-chain feed.
    // ----------------------------------------------------------------------
    logic        p_full, p_wr;  logic [7:0] p_data;
    integer      p_fed = 0;
    logic        p_start;
    logic        p_bsv, p_err;
    logic [31:0] p_blk_bits;
    logic [4:0]  p_blksw, p_dith;
    logic [7:0]  p_dynrng;
    logic [9:0]  p_chexpstr;
    logic [44:0] p_endmant;
    logic [34:0] p_nchgrps;
    logic [5:0]  p_csnr;
    logic [1:0]  p_sdcy, p_fdcy, p_sgain, p_dbpb;
    logic [2:0]  p_floor;
    logic [19:0] p_fsnroffst;
    logic [14:0] p_fgaincod;

    assign p_wr   = (!rst) && (p_fed < pos_bytes) && !p_full;
    assign p_data = (p_fed < pos_bytes) ? s_pos[p_fed] : 8'h00;
    always_ff @(posedge clk) if (rst) p_fed <= 0; else if (p_wr) p_fed <= p_fed + 1;

    blk_harness u_pos (
        .clk(clk), .rst(rst), .wr_en(p_wr), .wr_data(p_data), .full(p_full),
        .start(p_start),
        .block_side_valid(p_bsv), .blk_bits(p_blk_bits),
        .blksw(p_blksw), .dithflag(p_dith), .dynrng(p_dynrng),
        .chexpstr(p_chexpstr),
        .endmant(p_endmant),
        .nchgrps(p_nchgrps),
        .sdcycod(p_sdcy), .fdcycod(p_fdcy), .sgaincod(p_sgain),
        .dbpbcod(p_dbpb), .floorcod(p_floor),
        .csnroffst(p_csnr),
        .fsnroffst(p_fsnroffst), .fgaincod(p_fgaincod),
        .err_unsupported(p_err)
    );

    // ----------------------------------------------------------------------
    // M16: the former "short block" negative chain (n1) is now a POSITIVE chain —
    // short blocks are SUPPORTED.  n1 feeds a COPY of the positive block with
    // blksw=11 (top 2 bits of byte 0 set); short-block parsing is byte-identical
    // to long apart from those bits, so it decodes the same 212-bit block, raises
    // NO error, and de-interleaves blksw[1:0]==11.  n2/n3 (cplinu / rematstr) are
    // in scope since M12 Stage A (verified in run_front_cosim); they feed zeros
    // and are no longer asserted as errors.
    //   cplinu: blksw00 dith00 dynrnge0 cplstre1 cplinu1 ..... 0000011_0 = 0x06
    //   remat:  blksw00 dith00 dynrnge0 cplstre0 rematstr1 ... = 0x03
    // ----------------------------------------------------------------------
    logic        n1_full,n2_full,n3_full, n1_wr,n2_wr,n3_wr;
    logic [7:0]  n1_data,n2_data,n3_data;
    integer      n1_fed=0,n2_fed=0,n3_fed=0;
    logic        n_start;
    logic        n1_err,n2_err,n3_err, n1_bsv,n2_bsv,n3_bsv;
    logic [4:0]  n1_blksw;
    logic [7:0]  s_n2 [0:7]; logic [7:0] s_n3 [0:7];
    initial begin
        for (by=0; by<8; by=by+1) begin s_n2[by]=8'h00; s_n3[by]=8'h00; end
        s_n2[0]=8'h06; s_n3[0]=8'h03;
        // s_n1 (short-block copy of s_pos) is built in the s_pos initial block.
    end

    assign n1_wr=(!rst)&&(n1_fed<pos_bytes)&&!n1_full; assign n1_data=s_n1[n1_fed];
    assign n2_wr=(!rst)&&(n2_fed<8)&&!n2_full; assign n2_data=s_n2[n2_fed];
    assign n3_wr=(!rst)&&(n3_fed<8)&&!n3_full; assign n3_data=s_n3[n3_fed];
    always_ff @(posedge clk) if (rst) begin n1_fed<=0;n2_fed<=0;n3_fed<=0; end
        else begin
            if (n1_wr) n1_fed<=n1_fed+1;
            if (n2_wr) n2_fed<=n2_fed+1;
            if (n3_wr) n3_fed<=n3_fed+1;
        end

    blk_harness u_n1 (.clk(clk),.rst(rst),.wr_en(n1_wr),.wr_data(n1_data),.full(n1_full),
        .start(n_start), .block_side_valid(n1_bsv), .blk_bits(),
        .blksw(n1_blksw),.dithflag(),.chexpstr(),.endmant(),.nchgrps(),
        .sdcycod(),.fdcycod(),.sgaincod(),.dbpbcod(),.floorcod(),
        .csnroffst(),.fsnroffst(),.fgaincod(),
        .err_unsupported(n1_err));
    blk_harness u_n2 (.clk(clk),.rst(rst),.wr_en(n2_wr),.wr_data(n2_data),.full(n2_full),
        .start(n_start), .block_side_valid(n2_bsv), .blk_bits(),
        .blksw(),.dithflag(),.chexpstr(),.endmant(),.nchgrps(),
        .sdcycod(),.fdcycod(),.sgaincod(),.dbpbcod(),.floorcod(),
        .csnroffst(),.fsnroffst(),.fgaincod(),
        .err_unsupported(n2_err));
    blk_harness u_n3 (.clk(clk),.rst(rst),.wr_en(n3_wr),.wr_data(n3_data),.full(n3_full),
        .start(n_start), .block_side_valid(n3_bsv), .blk_bits(),
        .blksw(),.dithflag(),.chexpstr(),.endmant(),.nchgrps(),
        .sdcycod(),.fdcycod(),.sgaincod(),.dbpbcod(),.floorcod(),
        .csnroffst(),.fsnroffst(),.fgaincod(),
        .err_unsupported(n3_err));

    // ----------------------------------------------------------------------
    // Checker.
    // ----------------------------------------------------------------------
    integer errors = 0;
    task automatic chk(input cond, input [255:0] msg);
        if (!cond) begin errors = errors + 1; $display("  FAIL  %0s", msg); end
    endtask

    integer g;
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("audblk_parse_tb.vcd"); $dumpvars(0, audblk_parse_tb);
        end
        p_start = 0; n_start = 0;
        repeat (6) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        // kick every chain once (all reset together)
        @(negedge clk); p_start = 1; n_start = 1;
        @(negedge clk); p_start = 0; n_start = 0;

        // wait for positive block to finish (or timeout watchdog below)
        wait (p_bsv);
        @(posedge clk);

        $display("  positive: blk_bits=%0d (expected %0d)", p_blk_bits, pos_bits);
        chk(p_blk_bits === pos_bits[31:0], "blk_bits != encoder bit count");
        chk(pos_bits   === 212,            "encoder produced != 212 bits (test math)");
        chk(p_err          === 1'b0,       "positive err_unsupported set");
        chk(p_blksw[1:0]   === 2'b00,      "blksw != 0");
        chk(p_dith[1:0]    === 2'b01,      "dithflag != {ch1=0,ch0=1}");
        chk(p_dynrng       === 8'h5A,      "dynrng != 0x5A (M17 capture)");
        chk(p_chexpstr[1:0]=== 2'd3,       "chexpstr0 != D45");
        chk(p_chexpstr[3:2]=== 2'd2,       "chexpstr1 != D25");
        chk(p_endmant[8:0] === 9'd73,      "endmant0 != 73");
        chk(p_endmant[17:9]=== 9'd79,      "endmant1 != 79");
        chk(p_nchgrps[6:0] === 7'd6,       "nchgrps0 != 6");
        chk(p_nchgrps[13:7]=== 7'd13,      "nchgrps1 != 13");
        chk(p_sdcy         === 2'd1,       "sdcycod != 1");
        chk(p_fdcy         === 2'd2,       "fdcycod != 2");
        chk(p_sgain        === 2'd3,       "sgaincod != 3");
        chk(p_dbpb         === 2'd0,       "dbpbcod != 0");
        chk(p_floor        === 3'd5,       "floorcod != 5");
        chk(p_csnr         === 6'd33,      "csnroffst != 33");
        chk(p_fsnroffst[3:0]=== 4'd9,      "fsnroffst0 != 9");
        chk(p_fgaincod[2:0]=== 3'd4,       "fgaincod0 != 4");
        chk(p_fsnroffst[7:4]=== 4'd5,      "fsnroffst1 != 5");
        chk(p_fgaincod[5:3]=== 3'd2,       "fgaincod1 != 2");

        // packed exponents (hierarchical peek into the staging RAM)
        chk(u_pos.u_audblk.exp_mem[0]   === 8'd9, "exp ch0[0] != 9");
        for (g = 1; g <= 6; g = g + 1)
            chk(u_pos.u_audblk.exp_mem[g] === g[7:0], "exp ch0 grp mismatch");
        chk(u_pos.u_audblk.exp_mem[128] === 8'd3, "exp ch1[0] != 3");
        for (g = 1; g <= 13; g = g + 1)
            chk(u_pos.u_audblk.exp_mem[128+g] === (g+9), "exp ch1 grp mismatch");

        // M16: short block (n1) is now POSITIVE — it must decode the same block
        // with no error and blksw de-interleaved to 11.  (M12 Stage A made cplinu
        // + active-rematstr in scope too; n2/n3 feed zeros and are not asserted.)
        wait (n1_bsv);
        @(posedge clk);
        chk(n1_err   === 1'b0,  "short-block wrongly raised err_unsupported");
        chk(n1_blksw[1:0] === 2'b11, "short-block blksw not de-interleaved to 11");
        chk(p_blk_bits === u_n1.u_audblk.blk_bits, "short-block bit count != long block (should match)");

        $display("audblk_parse_tb: %0d errors", errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        if (errors != 0) $fatal(1, "audblk_parse_tb FAILED");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL (timeout)");
        $fatal(1, "audblk_parse_tb timeout");
    end

endmodule

// FIFO -> bit_reader -> audblk_parse, with the audblk side-info ports surfaced.
// M14: per-channel buses are now packed (chexpstr 2b/ch, endmant 9b/ch, etc.)
// and the old chbwcod outputs were dropped; acmod/lfeon select the scope.
module blk_harness (
    input  logic clk, rst,
    input  logic wr_en, input logic [7:0] wr_data, output logic full,
    input  logic start,
    output logic block_side_valid, output logic [31:0] blk_bits,
    output logic [4:0]  blksw, dithflag,
    output logic [7:0]  dynrng,
    output logic [9:0]  chexpstr,
    output logic [44:0] endmant,
    output logic [34:0] nchgrps,
    output logic [1:0]  sdcycod, fdcycod, sgaincod, dbpbcod,
    output logic [2:0]  floorcod,
    output logic [5:0]  csnroffst,
    output logic [19:0] fsnroffst,
    output logic [14:0] fgaincod,
    output logic err_unsupported
);
    logic [7:0] fdout; logic fempty, frd;
    logic br_req; logic [5:0] br_nbits; logic br_ack; logic [31:0] br_data, br_bitpos;

    bit_fifo #(.DW(8), .DEPTH(64)) u_fifo (
        .clk(clk), .rst(rst), .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_data(fdout), .empty(fempty), .rd_en(frd));

    bit_reader #(.MAXW(32)) u_reader (
        .clk(clk), .rst(rst), .fifo_dout(fdout), .fifo_empty(fempty), .fifo_rd(frd),
        .req(br_req), .nbits(br_nbits), .ack(br_ack), .data(br_data), .bitpos(br_bitpos));

    // acmod==2 / lfeon==0 (the unit-test scenario is the original 2/0 block).
    audblk_parse u_audblk (
        .clk(clk), .rst(rst), .start(start), .first_blk(1'b1),
        .acmod(3'd2), .lfeon(1'b0),
        .req(br_req), .nbits(br_nbits), .ack(br_ack),
        .data_in(br_data), .bitpos(br_bitpos),
        .block_side_valid(block_side_valid), .blk_bits(blk_bits),
        .blksw(blksw), .dithflag(dithflag), .dynrng(dynrng),
        .chexpstr(chexpstr),
        .endmant(endmant),
        .nchgrps(nchgrps),
        // coupling outputs (unused in this 2/0 scenario)
        .chincpl(), .cplstrtmant(), .cplendmant(), .ncplbnd(),
        .cplstrtbnd(), .cplbndstrc(), .phsflginu(), .rematflg(),
        .cplco_rd_addr(8'd0), .cplco_rd_data(),
        .cplco_rd2_addr(8'd0), .cplco_rd2_data(),
        .cplexpstr(), .cplfleak(), .cplsleak(), .cplba_bai(),
        .cpl_exp_rd_addr(7'd0), .cpl_exp_rd_data(),
        // LFE outputs (unused)
        .lfeexpstr(), .lfeba_bai(),
        .lfe_exp_rd_addr(2'd0), .lfe_exp_rd_data(),
        .sdcycod(sdcycod), .fdcycod(fdcycod), .sgaincod(sgaincod),
        .dbpbcod(dbpbcod), .floorcod(floorcod),
        .csnroffst(csnroffst),
        .fsnroffst(fsnroffst), .fgaincod(fgaincod),
        .deltbae(), .deltba_rd_addr(9'd0), .deltba_rd_data(),
        .exp_rd_addr(10'd0), .exp_rd_data(),
        .err_unsupported(err_unsupported));
endmodule
