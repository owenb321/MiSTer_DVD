//============================================================================
//  ac3_front.sv — decoder front-end: byte FIFO -> bit_reader -> ac3_parse.
//
//  Single DUT used by both the iverilog unit TB and the Verilator/liba52
//  co-sim.  Push AC-3 elementary-stream bytes in via the write port; the
//  front-end synchronizes (sync_crc), parses BSI (bsi_parse), skips the rest
//  of each frame body, and reports the header + BSI fields per frame.  The
//  parse sequencing and bit_reader arbitration live in `ac3_parse`.
//============================================================================

`timescale 1ns/1ps
`include "ac3_defs.svh"

module ac3_front #(
    parameter int FIFO_DEPTH = 4096
) (
    input  logic        clk,
    input  logic        rst,

    // byte input (AC-3 elementary stream)
    input  logic        wr_en,
    input  logic [7:0]  wr_data,
    output logic        full,

    // frame header (syncinfo) results
    output logic        synced,
    output logic        frame_hdr_valid,
    output logic [15:0] frame_words,
    output logic [15:0] frame_bytes,
    output logic [1:0]  fscod,
    output logic [5:0]  frmsizcod,
    output logic [15:0] crc1,
    output logic [31:0] sync_bitpos,

    // BSI results
    output logic        bsi_valid,
    output logic [4:0]  bsid,
    output logic [2:0]  bsmod,
    output logic [2:0]  acmod,
    output logic [1:0]  dsurmod,
    output logic [1:0]  cmixlev,
    output logic [1:0]  surmixlev,
    output logic        lfeon,
    output logic [4:0]  dialnorm,

    // audio-block side-info (block 0 of each frame)
    output logic        block_side_valid,
    output logic [31:0] blk_bits,

    // coupling geometry (M12 Stage A) — surfaced for the co-sim golden check.
    output logic [4:0]  chincpl,
    output logic [8:0]  cplstrtmant,
    output logic [8:0]  cplendmant,
    output logic [4:0]  ncplbnd,
    output logic [5:0]  cplstrtbnd,
    output logic        phsflginu,
    output logic [3:0]  rematflg,
    input  logic [7:0]  cplco_rd_addr,    // {ch[2:0], bnd[4:0]}
    output logic signed [23:0] cplco_rd_data,

    // decoded absolute exponents (block 0): pulse + combinational read port
    output logic        exp_done,
    input  logic [10:0] dexp_rd_addr,     // {ch[2:0], idx[7:0]}
    output logic [4:0]  dexp_rd_data,

    // derived bit-allocation pointers (block 0): pulse + combinational read port
    output logic        ba_done,
    input  logic [10:0] bap_rd_addr,      // {ch[2:0], idx[7:0]}
    output logic signed [7:0] bap_rd_data,

    // dequantized transform coeffs (block 0): pulse + combinational read port
    output logic        mant_done,
    input  logic [10:0] coeff_rd_addr,    // {ch[2:0], idx[7:0]}
    output logic signed [23:0] coeff_rd_data,

    // time-domain PCM (per block): pulse + combinational read port (Q8.23)
    output logic        imdct_done,
    input  logic [10:0] pcm_rd_addr,      // {ch[2:0], idx[7:0]}
    output logic signed [31:0] pcm_rd_data,

    // output-stage metering handshake (see ac3_parse): the sequencer waits for
    // `pcm_done` after each block's IMDCT before starting the next.  Drive from
    // pcm_out.done in hardware; tie to 1 where pcm_mem is read combinationally
    // on imdct_done (cosim / iverilog TBs) so no metering stall is needed.
    input  logic        pcm_done,

    output logic        err_unsupported
);

    // FIFO <-> bit_reader
    logic [7:0] fifo_dout;
    logic       fifo_empty;
    logic       fifo_rd;

    // bit_reader <-> ac3_parse
    logic        br_req;
    logic [5:0]  br_nbits;
    logic        br_ack;
    logic [31:0] br_data;
    logic [31:0] br_bitpos;

    bit_fifo #(.DW(8), .DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_data(fifo_dout), .empty(fifo_empty), .rd_en(fifo_rd)
    );

    bit_reader #(.MAXW(32)) u_reader (
        .clk(clk), .rst(rst),
        .fifo_dout(fifo_dout), .fifo_empty(fifo_empty), .fifo_rd(fifo_rd),
        .req(br_req), .nbits(br_nbits), .ack(br_ack),
        .data(br_data), .bitpos(br_bitpos)
    );

    ac3_parse u_parse (
        .clk(clk), .rst(rst),
        .req(br_req), .nbits(br_nbits), .ack(br_ack),
        .data_in(br_data), .bitpos(br_bitpos),
        .synced(synced), .frame_hdr_valid(frame_hdr_valid),
        .frame_words(frame_words), .frame_bytes(frame_bytes),
        .fscod(fscod), .frmsizcod(frmsizcod), .crc1(crc1),
        .sync_bitpos(sync_bitpos),
        .bsi_valid(bsi_valid),
        .bsid(bsid), .bsmod(bsmod), .acmod(acmod), .dsurmod(dsurmod),
        .cmixlev(cmixlev), .surmixlev(surmixlev),
        .lfeon(lfeon), .dialnorm(dialnorm),
        .block_side_valid(block_side_valid), .blk_bits(blk_bits),
        .chincpl(chincpl), .cplstrtmant(cplstrtmant), .cplendmant(cplendmant),
        .ncplbnd(ncplbnd), .cplstrtbnd(cplstrtbnd), .phsflginu(phsflginu),
        .rematflg(rematflg),
        .cplco_rd_addr(cplco_rd_addr), .cplco_rd_data(cplco_rd_data),
        .exp_done(exp_done),
        .dexp_rd_addr(dexp_rd_addr), .dexp_rd_data(dexp_rd_data),
        .ba_done(ba_done),
        .bap_rd_addr(bap_rd_addr), .bap_rd_data(bap_rd_data),
        .mant_done(mant_done),
        .coeff_rd_addr(coeff_rd_addr), .coeff_rd_data(coeff_rd_data),
        .imdct_done(imdct_done),
        .pcm_rd_addr(pcm_rd_addr), .pcm_rd_data(pcm_rd_data),
        .pcm_done(pcm_done),
        .err_unsupported(err_unsupported)
    );

endmodule
