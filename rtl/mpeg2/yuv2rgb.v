/* 
 * yuv2rgb.v
 * 
 * Copyright (c) 2006 - 2007 Koen De Vleeschauwer. 
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
 * yuv2rgb - conversion from y, u, v, to r, g, b.
 */

`include "timescale.v"

`undef DEBUG
//`define DEBUG 1

module yuv2rgb (clk, clk_en, rst,
                matrix_coefficients, y, u, v, h_sync_in, v_sync_in, pixel_en_in,
                r, g, b, y_out, u_out, v_out, h_sync_out, v_sync_out, c_sync_out, pixel_en_out
                );
  input  clk;
  input  clk_en;
  input  rst;

  input [7:0] matrix_coefficients; /* extracted from mpeg2 bitstream. Determines yuv -> rgb conversion factors. ISO/IEC 13818-2, par. 6.3.6 */

  input [7:0]y;
  input [7:0]u;
  input [7:0]v;

  output reg [7:0]r;
  output reg [7:0]g;
  output reg [7:0]b;
  output reg [7:0]y_out;
  output reg [7:0]u_out;
  output reg [7:0]v_out;

  /*
   * pixel_en_out, h_sync_out, v_sync_out are pixel_en_in, h_sync_in and v_sync_in, delayed so as to balance the delay from yuv -> rgb.
   * Typical use is to connect r, g, b to the 24-bit data-in of the dvi transmitter,
   * pixel_en_out, h_sync_out and video_out to de (data enable), h_sync and v_sync of the dvi transmitter.
   */

  input pixel_en_in;
  input h_sync_in;
  input v_sync_in;
  output reg pixel_en_out;
  output reg h_sync_out;
  output reg v_sync_out;
  output reg c_sync_out;

  reg signed [26:0]cy_y;
  reg signed [26:0]crv_v;
  reg signed [26:0]cbu_u;
  reg signed [26:0]cgu_u;
  reg signed [26:0]cgv_v;

  reg signed [17:0]crv;
  reg signed [17:0]cbu;
  reg signed [17:0]cgu;
  reg signed [17:0]cgv;

  reg signed [8:0]y_offset;
  reg signed [8:0]u_offset;
  reg signed [8:0]v_offset;

  reg signed [29:0]r_0;
  reg signed [29:0]g1_0;
  reg signed [29:0]g2_0;
  reg signed [29:0]b_0;

  reg signed [29:0]r_1;
  reg signed [29:0]g_1;
  reg signed [29:0]b_1;

  reg pixel_en_0;
  reg h_sync_0;
  reg v_sync_0;
  reg [7:0]y_0;
  reg [7:0]u_0;
  reg [7:0]v_0;

  reg pixel_en_1;
  reg h_sync_1;
  reg v_sync_1;
  reg [7:0]y_1;
  reg [7:0]u_1;
  reg [7:0]v_1;

  reg pixel_en_2;
  reg h_sync_2;
  reg v_sync_2;
  reg [7:0]y_2;
  reg [7:0]u_2;
  reg [7:0]v_2;

  /*
   * Simplify matrix_coefficients: values 8..255 are reserved and should not occur.
   * If value of matrix_coefficients outside 0..7 range, replace with 0.
   */

  reg         [2:0]mat_coeff;
  always @(posedge clk)
    if (~rst) mat_coeff <= 0;
    else if (clk_en && (matrix_coefficients[7:3] == 5'b0)) mat_coeff <= matrix_coefficients[2:0];
    else mat_coeff <= 0;

  /*
   *
   * Table 6-9 inverted.
   *
   * y        = cr * r + cg * g + cb * b
   * cr + cg + cb = 1
   *
   * cy       = (255/219) * 32768
   * crv      = (255/224) * 32768 * (1-cr) / 0.5
   * cbu      = (255/224) * 32768 * (1-cb) / 0.5
   * cgu      = (255/224) * 32768 * (cb/cg) * (1 - cb) / 0.5
   * cgv      = (255/224) * 32768 * (cr/cg) * (1 - cr) / 0.5
   * r        = ( cy * (y - 16)                   + crv * (v - 128) + 16384) >> 15;
   * g        = ( cy * (y - 16) - cgu * (u - 128) + crv * (v - 128) + 16384) >> 15;
   * b        = ( cy * (y - 16) - cbu * (u - 128)                   + 16384) >> 15;
   */

  parameter signed [17:0]
    cy = 18'sd38155;

  always @(posedge clk)
    if (clk_en)
      case (mat_coeff)
        3'd0, /* default value, no sequence_display_extension */
        3'd1: /* ITU-R Rec. 709 (1990) */
              begin
                crv <= 18'sd58752;
                cbu <= 18'sd69227;
                cgu <= 18'sd6977;
                cgv <= 18'sd17452;
              end
        3'd2, /* unspecified */
        3'd3, /* reserved */
        3'd5, /* ITU-R Rec. 624-4 System B, G */
        3'd6: /* SMPTE 170M */
              begin
                crv <= 18'sd52299;
                cbu <= 18'sd66101;
                cgu <= 18'sd12838;
                cgv <= 18'sd26640;
              end
        3'd4: /* FCC */
              begin
                crv <= 18'sd52224;
                cbu <= 18'sd66399;
                cgu <= 18'sd12380;
                cgv <= 18'sd26555;
              end
        3'd7: /* SMPTE 240M (1987) */
              begin
                crv <= 18'sd58790;
                cbu <= 18'sd68115;
                cgu <= 18'sd8454;
                cgv <= 18'sd17780;
              end
     endcase

  /* conversion */
  always @(posedge clk)
    if (~rst)
      begin
        y_offset <= 0;
        u_offset <= 0;
        v_offset <= 0;

        cy_y  <= 0;
        crv_v <= 0;
        cgv_v <= 0;
        cgu_u <= 0;
        cbu_u <= 0;

        r_0   <= 0;
        g1_0  <= 0;
        g2_0  <= 0;
        b_0   <= 0;

        r_1   <= 0;
        g_1   <= 0;
        b_1   <= 0;
      end
    else if (clk_en)
      begin
        y_offset <= {1'b0, y} - 9'sd16;
        u_offset <= {1'b0, u} - 9'sd128;
        v_offset <= {1'b0, v} - 9'sd128;

        cy_y  <= cy  * y_offset;
        cgu_u <= cgu * u_offset;
        cbu_u <= cbu * u_offset;
        crv_v <= crv * v_offset;
        cgv_v <= cgv * v_offset;

        r_0   <=   {{3{cy_y[26]}}, cy_y}  + {{3{crv_v[26]}}, crv_v};
        g1_0  <=   {{3{cy_y[26]}}, cy_y}  - {{3{cgu_u[26]}}, cgu_u};
        g2_0  <=                          - {{3{cgv_v[26]}}, cgv_v} + 30'sd16384;
        b_0   <=   {{3{cy_y[26]}}, cy_y}  + {{3{cbu_u[26]}}, cbu_u};

        r_1   <= (r_0 + 30'sd16384) >>> 15;
        g_1   <= (g1_0 + g2_0) >>> 15;
        b_1   <= (b_0 + 30'sd16384) >>> 15;
      end
    else
      begin
        y_offset <= y_offset;
        u_offset <= u_offset;
        v_offset <= v_offset;

        cy_y  <= cy_y;
        cgu_u <= cgu_u;
        cbu_u <= cbu_u;
        crv_v <= crv_v;
        cgv_v <= cgv_v;

        r_0   <= r_0;
        g1_0  <= g1_0;
        g2_0  <= g2_0;
        b_0   <= b_0;

        r_1   <= r_1;
        g_1   <= r_1;
        b_1   <= r_1;
      end

  /* clipping */
  always @(posedge clk)
    if (~rst) r <= 8'd0;
    else if (clk_en && r_1[29]) r <= 8'd0; /* negative, clip to 0 */
    else if (clk_en && (r_1[29:8] != 22'b0)) r <= 8'd255; /* 256 or more, clip to 255 */
    else if (clk_en) r <= r_1[7:0]; /* between 0 and 255, copy */
    else r <= r;

  always @(posedge clk)
    if (~rst) g <= 8'd0;
    else if (clk_en && g_1[29]) g <= 8'd0;
    else if (clk_en && (g_1[29:8] != 22'b0)) g <= 8'd255;
    else if (clk_en) g <= g_1[7:0];
    else g <= g;

  always @(posedge clk)
    if (~rst) b <= 8'd0;
    else if (clk_en && b_1[29]) b <= 8'd0;
    else if (clk_en && (b_1[29:8] != 22'b0)) b <= 8'd255;
    else if (clk_en) b <= b_1[7:0];
    else b <= b;

 /* delay pixel_en, h_sync and v_sync so they are balanced with r, g, b */

  always @(posedge clk)
    if (~rst)
      begin
        pixel_en_0 <= 1'b0;
        pixel_en_1 <= 1'b0;
        pixel_en_2 <= 1'b0;
        pixel_en_out <= 1'b0;
     end
   else if (clk_en)
     begin
        pixel_en_0 <= pixel_en_in;
        pixel_en_1 <= pixel_en_0;
        pixel_en_2 <= pixel_en_1;
        pixel_en_out <= pixel_en_2;
     end
   else
     begin
        pixel_en_0 <= pixel_en_0;
        pixel_en_1 <= pixel_en_1;
        pixel_en_2 <= pixel_en_2;
        pixel_en_out <= pixel_en_out;
     end

  always @(posedge clk)
    if (~rst)
      begin
        h_sync_0 <= 1'b0;
        h_sync_1 <= 1'b0;
        h_sync_2 <= 1'b0;
        h_sync_out <= 1'b0;
     end
   else if (clk_en)
     begin
        h_sync_0 <= h_sync_in;
        h_sync_1 <= h_sync_0;
        h_sync_2 <= h_sync_1;
        h_sync_out <= h_sync_2;
     end
   else
     begin
        h_sync_0 <= h_sync_0;
        h_sync_1 <= h_sync_1;
        h_sync_2 <= h_sync_2;
        h_sync_out <= h_sync_out;
     end

  always @(posedge clk)
    if (~rst)
      begin
        v_sync_0 <= 1'b0;
        v_sync_1 <= 1'b0;
        v_sync_2 <= 1'b0;
        v_sync_out <= 1'b0;
     end
   else if (clk_en)
     begin
        v_sync_0 <= v_sync_in;
        v_sync_1 <= v_sync_0;
        v_sync_2 <= v_sync_1;
        v_sync_out <= v_sync_2;
     end
   else
     begin
        v_sync_0 <= v_sync_0;
        v_sync_1 <= v_sync_1;
        v_sync_2 <= v_sync_2;
        v_sync_out <= v_sync_out;
     end
  /*
   * composite sync
   */

  always @(posedge clk)
    if (~rst) c_sync_out <= 1'b0;
    else if (clk_en) c_sync_out <= ~(h_sync_2 ^ v_sync_2);
    else c_sync_out <= c_sync_out;

  /*
   * yuv
   */

  always @(posedge clk)
    if (~rst)
      begin
        y_0 <= 8'd0;
        y_1 <= 8'd0;
        y_2 <= 8'd0;
        y_out <= 8'd0;
     end
   else if (clk_en)
     begin
        y_0 <= y;
        y_1 <= y_0;
        y_2 <= y_1;
        y_out <= y_2;
     end
   else
     begin
        y_0 <= y_0;
        y_1 <= y_1;
        y_2 <= y_2;
        y_out <= y_out;
     end

  always @(posedge clk)
    if (~rst)
      begin
        u_0 <= 8'd0;
        u_1 <= 8'd0;
        u_2 <= 8'd0;
        u_out <= 8'd0;
     end
   else if (clk_en)
     begin
        u_0 <= u;
        u_1 <= u_0;
        u_2 <= u_1;
        u_out <= u_2;
     end
   else
     begin
        u_0 <= u_0;
        u_1 <= u_1;
        u_2 <= u_2;
        u_out <= u_out;
     end

  always @(posedge clk)
    if (~rst)
      begin
        v_0 <= 8'd0;
        v_1 <= 8'd0;
        v_2 <= 8'd0;
        v_out <= 8'd0;
     end
   else if (clk_en)
     begin
        v_0 <= v;
        v_1 <= v_0;
        v_2 <= v_1;
        v_out <= v_2;
     end
   else
     begin
        v_0 <= v_0;
        v_1 <= v_1;
        v_2 <= v_2;
        v_out <= v_out;
     end

`ifdef DEBUG
  always @(posedge clk)
    begin
      $strobe("%m\tyuv: %0d %0d %0d pixel_en_in: %0d rgb: %0d %0d %0d pixel_en_out: %0d", y, u, v, pixel_en_in, r, g, b, pixel_en_out);
      $strobe("%m\tmatrix_coefficients: %4d y: %4d u: %4d v: %d y_offset: %d u_offset: %d v_offset: %d cy_y: %d crv_v: %d cgv_v: %d cgu_u: %d cbu_u: %d r_0: %d g1_0: %d g2_0: %d b_0: %d r_1: %d g_1: %d b_1: %d r: %4d g: %4d b: %4d ", 
                   matrix_coefficients,     y,     u,     v,    y_offset,    u_offset,    v_offset,    cy_y,    crv_v,    cgv_v,    cgu_u,    cbu_u,    r_0,    g1_0,    g2_0,    b_0,    r_1,    g_1,    b_1,    r,     g,     b);
    end
`endif
endmodule
/* not truncated */
