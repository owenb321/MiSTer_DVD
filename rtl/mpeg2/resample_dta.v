/* 
 * resample_dta.v
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
 * resample_dta - chroma resampling: read pixel data from memory fifo.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module resample_dta (
  clk, clk_en, rst, 
  fifo_read, fifo_valid,
  disp_rd_dta_empty, disp_rd_dta_en, disp_rd_dta_valid, disp_rd_dta,
  resample_rd_en, resample_rd_dta, resample_rd_valid,
  fifo_osd, fifo_y, fifo_u_upper, fifo_u_lower, fifo_v_upper, fifo_v_lower, fifo_position
  );

  input            clk;                      // clock
  input            clk_en;                   // clock enable
  input            rst;                      // synchronous active low reset

  input            fifo_read;                // resample_bilinear asserts 'fifo_read' when resample_bilineear clocks in fifo_* data
  output reg       fifo_valid;               // resample_dta asserts 'fifo_valid' when fifo_* valid

  /* chroma resampling: reading reconstructed frame data */
  input            disp_rd_dta_empty;
  output           disp_rd_dta_en;
  input            disp_rd_dta_valid;
  input      [63:0]disp_rd_dta;

  output           resample_rd_en;
  input       [2:0]resample_rd_dta;
  input            resample_rd_valid;

  /* registers to read disp_rd_dta fifo in. 
     16 pixels - a macroblock - wide. 
     Two rows of chrominance information are stored, as we will have to interpolate between these two rows. */

  output reg [127:0]fifo_osd;          /* osd data */
  output reg [127:0]fifo_y;            /* lumi */
  output reg  [63:0]fifo_u_upper;      /* chromi, upper row */
  output reg  [63:0]fifo_u_lower;      /* chromi, lower row */
  output reg  [63:0]fifo_v_upper;      /* chromi, upper row */
  output reg  [63:0]fifo_v_lower;      /* chromi, lower row */
  output reg   [2:0]fifo_position;     /* position of pixels, as in  resample_codes */

  /* first-word fall-through fifo readers */

  wire             disp_fwft_valid; 
  wire      [127:0]disp_fwft_dout; 
  reg              disp_fwft_rd_en;

  wire             resample_fwft_valid; 
  wire        [2:0]resample_fwft_dout; 
  reg              resample_fwft_rd_en;

  parameter [3:0]
    STATE_INIT        = 4'h0,
    STATE_RD_OSD      = 4'h1,
    STATE_RD_Y        = 4'h2,
    STATE_RD_U        = 4'h3,
    STATE_RD_V        = 4'h4,
    STATE_RD_POS      = 4'h5,
    STATE_READY       = 4'h6,
    STATE_WAIT        = 4'h7;
  
  reg          [3:0]state;
  reg          [3:0]next;

  /* next state logic */
  always @*
    case (state)
      STATE_INIT:         next = STATE_RD_OSD;

      STATE_RD_OSD:       if (disp_fwft_valid) next = STATE_RD_Y;
                          else next = STATE_RD_OSD;

      STATE_RD_Y:         if (disp_fwft_valid) next = STATE_RD_U;
                          else next = STATE_RD_Y;

      STATE_RD_U:         if (disp_fwft_valid) next = STATE_RD_V;
                          else next = STATE_RD_U;

      STATE_RD_V:         if (disp_fwft_valid) next = STATE_RD_POS;
                          else next = STATE_RD_V;

      STATE_RD_POS:       if (resample_fwft_valid) next = STATE_READY;
                          else next = STATE_RD_POS;

                          /* raise fifo_valid; wait for fifo_read to go high */
      STATE_READY:        if (fifo_read) next = STATE_WAIT;
                          else next = STATE_READY;

                          /* wait for fifo_read to drop, then lower fifo_valid */
      STATE_WAIT:         if (~fifo_read) next = STATE_RD_OSD;
                          else next = STATE_WAIT;

      default             next = STATE_INIT;
    endcase

  /* state */
  always @(posedge clk)
    if(~rst) state <= STATE_INIT;
    else if (clk_en) state <= next;
    else state <= state;

  /* inform resample_bilinear data is valid */
  always @(posedge clk)
    if(~rst) fifo_valid <= 1'b0;
    else if (clk_en && (state == STATE_READY)) fifo_valid <= 1'b1;
    else if (clk_en && (state == STATE_WAIT)) fifo_valid <= fifo_read; // drop fifo_valid when fifo_read is lowered
    else if (clk_en) fifo_valid <= 1'b0;
    else fifo_valid <= fifo_valid;

  /* disp fifo read enable */
  always @(posedge clk)
    if(~rst) disp_fwft_rd_en <= 1'b0;
    else if (clk_en) disp_fwft_rd_en <= (next == STATE_RD_OSD) || (next == STATE_RD_Y) || (next == STATE_RD_U) ||(next == STATE_RD_V);
    else disp_fwft_rd_en <= disp_fwft_rd_en;

  /* resample fifo read enable */
  always @(posedge clk)
    if(~rst) resample_fwft_rd_en <= 1'b0;
    else if (clk_en) resample_fwft_rd_en <= (next == STATE_RD_POS);
    else resample_fwft_rd_en <= resample_fwft_rd_en;

  /* read data from disp fifo */

  always @(posedge clk)
    if (~rst) fifo_osd <= 128'b0;
    else if (clk_en && (state == STATE_RD_OSD) && disp_fwft_valid) fifo_osd <= disp_fwft_dout;
    else fifo_osd <= fifo_osd;

  always @(posedge clk)
    if (~rst) fifo_y <= 128'b0;
    else if (clk_en && (state == STATE_RD_Y) && disp_fwft_valid) fifo_y <= disp_fwft_dout;
    else fifo_y <= fifo_y;

  always @(posedge clk)
    if (~rst) {fifo_u_upper, fifo_u_lower} <= 64'b0;
    else if (clk_en && (state == STATE_RD_U) && disp_fwft_valid) {fifo_u_upper, fifo_u_lower} <= disp_fwft_dout;
    else {fifo_u_upper, fifo_u_lower} <= {fifo_u_upper, fifo_u_lower};

  always @(posedge clk)
    if (~rst) {fifo_v_upper, fifo_v_lower} <= 64'b0;
    else if (clk_en && (state == STATE_RD_V) && disp_fwft_valid) {fifo_v_upper, fifo_v_lower} <= disp_fwft_dout;
    else {fifo_v_upper, fifo_v_lower} <= {fifo_v_upper, fifo_v_lower};

  /* read data from resample fifo */

  always @(posedge clk)
    if (~rst) fifo_position <= 2'b0;
    else if (clk_en && (state == STATE_RD_POS) && resample_fwft_valid) fifo_position <= resample_fwft_dout;
    else fifo_position <= fifo_position;

  /* fifo readers */

  fwft2_reader 
    #(.dta_width(9'd64))
  disp_fwft_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(disp_rd_dta_en), 
    .fifo_valid(disp_rd_dta_valid), 
    .fifo_dout(disp_rd_dta), 
    .valid(disp_fwft_valid), 
    .dout(disp_fwft_dout), 
    .rd_en(disp_fwft_rd_en)
    );

  fwft_reader 
    #(.dta_width(9'd3))
  resample_fwft_reader (
    .rst(rst), 
    .clk(clk), 
    .clk_en(clk_en), 
    .fifo_rd_en(resample_rd_en), 
    .fifo_valid(resample_rd_valid), 
    .fifo_dout(resample_rd_dta), 
    .valid(resample_fwft_valid), 
    .dout(resample_fwft_dout), 
    .rd_en(resample_fwft_rd_en)
    );

`ifdef DEBUG
  always @(posedge clk)
    if (clk_en) 
        case (state)
        STATE_INIT:                   #0 $display("%m\tSTATE_INIT");
        STATE_RD_OSD:                 #0 $display("%m\tSTATE_RD_OSD");
        STATE_RD_Y:                   #0 $display("%m\tSTATE_RD_Y");
        STATE_RD_U:                   #0 $display("%m\tSTATE_RD_U");
        STATE_RD_V:                   #0 $display("%m\tSTATE_RD_V");
        STATE_RD_POS:                 #0 $display("%m\tSTATE_RD_POS");
        STATE_READY:                  #0 $display("%m\tSTATE_READY");
        STATE_WAIT:                   #0 $display("%m\tSTATE_WAIT");
        default                       #0 $display("%m\t*** Error: unknown state %d", state);
      endcase

  always @(posedge clk)
    $strobe("%m\tstate: %d fifo_read: %d fifo_valid: %d fifo_osd: %32h fifo_y: %32h fifo_u_upper: %16h fifo_u_lower: %16h fifo_v_upper: %16h fifo_v_lower: %16h fifo_position: %d disp_rd_dta_en: %d disp_rd_dta_valid: %d disp_rd_dta: %16h resample_rd_en: %d resample_rd_valid: %d resample_rd_dta: %d", state, fifo_read, fifo_valid, fifo_osd, fifo_y, fifo_u_upper, fifo_u_lower, fifo_v_upper, fifo_v_lower, fifo_position, disp_rd_dta_en, disp_rd_dta_valid, disp_rd_dta, resample_rd_en, resample_rd_valid, resample_rd_dta);

`endif
endmodule
/* not truncated */
