/* 
 * motcomp_dcttype.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * motcomp_dcttype - Motion compensation dct type
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

`undef CHECK
`ifdef __IVERILOG__
`define CHECK 1
`endif

/*
  This module converts blocks between different dct types.
  dct_type is a flag indicating whether the macroblock is frame DCT coded or field DCT coded. If this is set to '1', the macroblock is field DCT coded. (par. 6.3.17.1 Macroblock modes)
  See par. 6.1.4, Figure 6-13 and 6-14.
 */

module motcomp_dcttype (
  clk, clk_en, rst, 
  dct_block_empty, dct_block_cmd, dct_block_en, dct_block_valid,
  idct_rd_dta_empty, idct_rd_dta, idct_rd_dta_en, idct_rd_dta_valid,
  frame_idct_rd_dta_empty, frame_idct_rd_dta, frame_idct_rd_dta_en, frame_idct_rd_dta_valid,
  frame_idct_wr_overflow
  );

`include "motcomp_dctcodes.v"

  input              clk;                          // clock
  input              clk_en;                       // clock enable
  input              rst;                          // synchronous active low reset

  /* input dct field->frame conversion commands */
  input              dct_block_empty;              // asserted if no dct_block_type/dct_block_count available.
  input         [2:0]dct_block_cmd;                // code which indicates number of blocks to transpose and how to transpose them.
  output reg         dct_block_en;                 // assert to read dct_block_type and dct_block_count.
  input              dct_block_valid;              // asserted if dct_block_type/dct_block_count valid

  /* input field/frame idct coefficients fifo */
  input              idct_rd_dta_empty;
  input        [71:0]idct_rd_dta;
  output reg         idct_rd_dta_en;
  input              idct_rd_dta_valid;

  /* output frame idct coefficients fifo */
  output              frame_idct_rd_dta_empty;
  output        [71:0]frame_idct_rd_dta;
  input               frame_idct_rd_dta_en;
  output              frame_idct_rd_dta_valid;

  wire                frame_idct_wr_dta_full;
  wire                frame_idct_wr_dta_almost_full;
  wire          [71:0]frame_idct_wr_dta;
  reg                 frame_idct_wr_dta_en;
  reg                 frame_idct_wr_dta_en_0;
  output              frame_idct_wr_overflow;

  /* ram address register */
  reg           [4:0]wr_addr;
  reg           [4:0]coeff;
  reg           [4:0]dct_count;
  reg           [2:0]dct_cmd;

  parameter [2:0]
    STATE_INIT       = 3'd0, 
    STATE_DCT_RD_EN  = 3'd1,
    STATE_DCT_READ   = 3'd2,
    STATE_WAIT_IDCT  = 3'd3,
    STATE_IDCT_RD_EN = 3'd4,
    STATE_READ_IDCT  = 3'd5,
    STATE_WRITE_IDCT = 3'd6,
    STATE_WAIT_WRITE = 3'd7;

  reg           [2:0]state;
  reg           [2:0]next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         if (dct_block_empty || frame_idct_wr_dta_almost_full) next = STATE_INIT; // wait for dct_type fifo (=command input) not empty and frame_idct (=output) not full
                          else next = STATE_DCT_RD_EN;

      STATE_DCT_RD_EN:    next = STATE_DCT_READ; // assert dct_block_en

      STATE_DCT_READ:     next = STATE_WAIT_IDCT; // read dct_block_cmd

      STATE_WAIT_IDCT:    if (idct_rd_dta_empty) next = STATE_WAIT_IDCT; // wait for idct fifo not empty
                          else next = STATE_IDCT_RD_EN;

      STATE_IDCT_RD_EN:   next = STATE_READ_IDCT; // assert idct_rd_dta_en

      STATE_READ_IDCT:    if (wr_addr == dct_count) next = STATE_WRITE_IDCT; // read idct_rd_dta; if last idct coefficient write re-arranged coefficients to frame idct fifo,
                          else next = STATE_WAIT_IDCT;                       // else read next idct coefficient

      STATE_WRITE_IDCT:   if (coeff == dct_count) next = STATE_WAIT_WRITE;   // write idct coefficients to frame idct fifo
                          else next = STATE_WRITE_IDCT;

      STATE_WAIT_WRITE:   if (frame_idct_wr_dta_en) next = STATE_WAIT_WRITE;
                          else next = STATE_INIT;

      default             next = STATE_INIT;

    endcase

  /* state */
  always @(posedge clk)
    if (~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= state;

  /* registers */
  /* read from dct_type fifo */
  always @(posedge clk)
    if (~rst) dct_block_en <= 1'b0;
    else if (clk_en) dct_block_en <= next == STATE_DCT_RD_EN;
    else  dct_block_en <= 1'b0;

  always @(posedge clk)
    if (~rst) dct_cmd <= 1'b0;
    else if (clk_en && dct_block_valid) dct_cmd <= dct_block_cmd;
    else  dct_cmd <= dct_cmd;

  always @(posedge clk)
    if (~rst) dct_count <= 5'b0;
    else if (clk_en && dct_block_valid) 
      case (dct_block_cmd)
        DCT_C1_PASS,
        DCT_C1_FRAME_TO_TOP_FIELD:    dct_count <= 5'd7;   // 1 block, 8 rows
        DCT_L4_PASS,
        DCT_L4_TOP_FIELD_TO_FRAME,
        DCT_L4_FRAME_TO_TOP_FIELD:    dct_count <= 5'd31;  // 4 blocks, 32 rows
        default                       dct_count <= 5'd0;   // Should never occur
      endcase
    else  dct_count <= dct_count;

  /* read from idct_dta fifo */
  always @(posedge clk)
    if (~rst) idct_rd_dta_en <= 1'b0;
    else if (clk_en) idct_rd_dta_en <= next == STATE_IDCT_RD_EN;
    else  idct_rd_dta_en <= 1'b0;

  always @(posedge clk)
    if (~rst) wr_addr <= 5'b0;
    else if (clk_en && (state == STATE_INIT)) wr_addr <= 5'b0;
    else if (clk_en && (state == STATE_READ_IDCT)) wr_addr <= wr_addr + 5'b1;
    else  wr_addr <= wr_addr;
  
  always @(posedge clk)
    if (~rst) coeff <= 5'b0;
    else if (clk_en && (state == STATE_INIT)) coeff <= 5'b0;
    else if (clk_en && (state == STATE_WRITE_IDCT)) coeff <= coeff + 5'b1;
    else  coeff <= coeff;
  
  /* write to idct_dta_ram */
  wire idct_ram_wr_en = idct_rd_dta_valid;
  wire [71:0]idct_ram_wr_dta = idct_rd_dta;

  /* write to frame_idct fifo */
  always @(posedge clk)
    if (~rst) frame_idct_wr_dta_en_0 <= 1'b0;
    else if (clk_en) frame_idct_wr_dta_en_0 <= (state == STATE_WRITE_IDCT);
    else  frame_idct_wr_dta_en_0 <= 1'b0;

  always @(posedge clk)
    if (~rst) frame_idct_wr_dta_en <= 1'b0;
    else if (clk_en) frame_idct_wr_dta_en <= frame_idct_wr_dta_en_0;
    else  frame_idct_wr_dta_en <= 1'b0;

  /* address transposition for reading */
  reg           [4:0]rd_addr;
  reg                idct_ram_rd_en;

  always @(posedge clk)
    if (~rst) idct_ram_rd_en <= 1'b0;
    else if (clk_en) idct_ram_rd_en <= (state == STATE_WRITE_IDCT);
    else  idct_ram_rd_en <= 1'b0;

  /* convert address from field to frame coding, or the other way round */
  always @(posedge clk)
    case (dct_cmd)
      /* chrominance pass-through */
      DCT_C1_PASS:
        rd_addr <= coeff;
      /* rearrange chrominance from frame to field. output top 4 rows are top field, bottom 4 rows are bottom field */
      DCT_C1_FRAME_TO_TOP_FIELD:
        case (coeff)
          5'd0:   rd_addr <= 5'd0;
          5'd1:   rd_addr <= 5'd2;
          5'd2:   rd_addr <= 5'd4;
          5'd3:   rd_addr <= 5'd6;
          5'd4:   rd_addr <= 5'd1;
          5'd5:   rd_addr <= 5'd3;
          5'd6:   rd_addr <= 5'd5;
          5'd7:   rd_addr <= 5'd7;
          default rd_addr <= 5'd0;
        endcase
      /* luminance pass-through */
      DCT_L4_PASS:
        rd_addr <= coeff;
      /* rearrange luminance from field to frame. input top 8 rows are top field, bottom 8 rows are bottom field */
      DCT_L4_TOP_FIELD_TO_FRAME:
        case (coeff)
          5'd0:   rd_addr <= 5'd0;
          5'd1:   rd_addr <= 5'd16;
          5'd2:   rd_addr <= 5'd1;
          5'd3:   rd_addr <= 5'd17;
          5'd4:   rd_addr <= 5'd2;
          5'd5:   rd_addr <= 5'd18;
          5'd6:   rd_addr <= 5'd3;
          5'd7:   rd_addr <= 5'd19;
          5'd8:   rd_addr <= 5'd8;
          5'd9:   rd_addr <= 5'd24;
          5'd10:  rd_addr <= 5'd9;
          5'd11:  rd_addr <= 5'd25;
          5'd12:  rd_addr <= 5'd10;
          5'd13:  rd_addr <= 5'd26;
          5'd14:  rd_addr <= 5'd11;
          5'd15:  rd_addr <= 5'd27;
          5'd16:  rd_addr <= 5'd4;
          5'd17:  rd_addr <= 5'd20;
          5'd18:  rd_addr <= 5'd5;
          5'd19:  rd_addr <= 5'd21;
          5'd20:  rd_addr <= 5'd6;
          5'd21:  rd_addr <= 5'd22;
          5'd22:  rd_addr <= 5'd7;
          5'd23:  rd_addr <= 5'd23;
          5'd24:  rd_addr <= 5'd12;
          5'd25:  rd_addr <= 5'd28;
          5'd26:  rd_addr <= 5'd13;
          5'd27:  rd_addr <= 5'd29;
          5'd28:  rd_addr <= 5'd14;
          5'd29:  rd_addr <= 5'd30;
          5'd30:  rd_addr <= 5'd15;
          5'd31:  rd_addr <= 5'd31;
          default rd_addr <= 5'd0;
        endcase
      /* rearrange luminance from frame to field. output top 8 rows are top field, bottom 8 rows are bottom field */
      DCT_L4_FRAME_TO_TOP_FIELD:
        case (coeff)
          5'd0:   rd_addr <= 5'd0;
          5'd1:   rd_addr <= 5'd2;
          5'd2:   rd_addr <= 5'd4;
          5'd3:   rd_addr <= 5'd6;
          5'd4:   rd_addr <= 5'd16;
          5'd5:   rd_addr <= 5'd18;
          5'd6:   rd_addr <= 5'd20;
          5'd7:   rd_addr <= 5'd22;
          5'd8:   rd_addr <= 5'd8;
          5'd9:   rd_addr <= 5'd10;
          5'd10:  rd_addr <= 5'd12;
          5'd11:  rd_addr <= 5'd14;
          5'd12:  rd_addr <= 5'd24;
          5'd13:  rd_addr <= 5'd26;
          5'd14:  rd_addr <= 5'd28;
          5'd15:  rd_addr <= 5'd30;
          5'd16:  rd_addr <= 5'd1;
          5'd17:  rd_addr <= 5'd3;
          5'd18:  rd_addr <= 5'd5;
          5'd19:  rd_addr <= 5'd7;
          5'd20:  rd_addr <= 5'd17;
          5'd21:  rd_addr <= 5'd19;
          5'd22:  rd_addr <= 5'd21;
          5'd23:  rd_addr <= 5'd23;
          5'd24:  rd_addr <= 5'd9;
          5'd25:  rd_addr <= 5'd11;
          5'd26:  rd_addr <= 5'd13;
          5'd27:  rd_addr <= 5'd15;
          5'd28:  rd_addr <= 5'd25;
          5'd29:  rd_addr <= 5'd27;
          5'd30:  rd_addr <= 5'd29;
          5'd31:  rd_addr <= 5'd31;
          default rd_addr <= 5'd0;
        endcase
      default
        rd_addr <= 5'd0;
    endcase

  /* storage for re-ordering idct coefficients */

  dpram_sc
    #(.addr_width(5),                                         // number of bits in address bus
    .dta_width(72))                                           // number of bits in data bus
    idct_dta_ram (
    .rst(rst),                                                // reset, active low
    .clk(clk),                                                // clock, rising edge trigger
    .wr_en(idct_ram_wr_en),                                   // write enable, active high
    .wr_addr(wr_addr),                                        // write address
    .din(idct_ram_wr_dta),                                    // data input
    .rd_en(idct_ram_rd_en),                                   // read enable, active high
    .rd_addr(rd_addr),                                        // read address
    .dout(frame_idct_wr_dta)                                  // data output
    );

  /* output fifo for idct coefficients */

  fifo_sc
    #(.addr_width(9'd6), // stores twice 4 blocks
    .dta_width(9'd72),
    .prog_thresh(9'd32))  // almost_full low indicates enough room for writing 4 blocks
    frame_idct_fifo (
    .rst(rst),
    .clk(clk),
    .din(frame_idct_wr_dta),
    .wr_en(frame_idct_wr_dta_en && clk_en),
    .full(frame_idct_wr_dta_full),
    .wr_ack(),
    .overflow(frame_idct_wr_overflow),
    .prog_full(frame_idct_wr_dta_almost_full),
    .dout(frame_idct_rd_dta),
    .rd_en(frame_idct_rd_dta_en),
    .empty(frame_idct_rd_dta_empty),
    .valid(frame_idct_rd_dta_valid),
    .underflow(),
    .prog_empty()
    );

`ifdef CHECK
  always @(posedge clk)
    if (frame_idct_wr_overflow)
      begin
        #0 $display("%m\t*** error: frame_idct_fifo overflow. **");
        $stop;
      end
`endif

`ifdef DEBUG
  /* debugging */

  always @(posedge clk)
    if (clk_en)
      case (state)
        STATE_INIT:                               #0 $display("%m         STATE_INIT");
        STATE_DCT_RD_EN:                          #0 $display("%m         STATE_DCT_RD_EN");
        STATE_DCT_READ:                           #0 $display("%m         STATE_DCT_READ");
        STATE_WAIT_IDCT:                          #0 $display("%m         STATE_WAIT_IDCT");
        STATE_IDCT_RD_EN:                         #0 $display("%m         STATE_IDCT_RD_EN");
        STATE_READ_IDCT:                          #0 $display("%m         STATE_READ_IDCT");
        STATE_WRITE_IDCT:                         #0 $display("%m         STATE_WRITE_IDCT");
        STATE_WAIT_WRITE:                         #0 $display("%m         STATE_WAIT_WRITE");
        default                                   #0 $display("%m         *** Error: unknown state %d", state);
      endcase

  always @(posedge clk)
    if (clk_en)
      begin
        $strobe("%m\tdct_block_empty: %d dct_block_cmd: %d dct_block_en: %d dct_block_valid: %d", dct_block_empty, dct_block_cmd, dct_block_en, dct_block_valid);
        $strobe("%m\tidct_rd_dta_empty: %d idct_rd_dta: %h idct_rd_dta_en: %d idct_rd_dta_valid: %d wr_addr: %d", idct_rd_dta_empty, idct_rd_dta, idct_rd_dta_en, idct_rd_dta_valid, wr_addr);
        $strobe("%m\tframe_idct_wr_dta_almost_full: %d frame_idct_wr_dta: %h frame_idct_wr_dta_en: %d rd_addr: %d", frame_idct_wr_dta_almost_full, frame_idct_wr_dta, frame_idct_wr_dta_en, rd_addr);
        $strobe("%m\tframe_idct_rd_dta_empty: %d frame_idct_rd_dta: %h frame_idct_rd_dta_en: %d frame_idct_rd_dta_valid: %d", frame_idct_rd_dta_empty, frame_idct_rd_dta, frame_idct_rd_dta_en, frame_idct_rd_dta_valid);
      end

`endif

endmodule
/* not truncated */
