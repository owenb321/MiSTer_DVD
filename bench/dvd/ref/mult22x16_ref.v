// bench/dvd/ref/mult22x16_ref.v -- THE A/B ORACLE for the IDCT multiplier. This is
// rtl/mpeg2/idct.v's mult22x16 as upstream wrote it (the Virtex-II 18x18 + shift-add split),
// with ONLY the module renamed. bench/dvd/run_idct_mult.sh scores the fork's one-DSP
// mult22x16 against it, alone and inside the whole idct (docs/logic_reclaim.md §11).
// Do NOT fix or change it.
module mult22x16_ref(clk, clk_en, rst, product, multiplicand, multiplier); 
   input         clk;
   input         clk_en;
   input         rst;
   input signed [21:0]  multiplier;
   input signed [15:0]  multiplicand;
   output reg signed [37:0] product;

/* 
 * the following code implements
 *   always @(posedge clk)
 *     product <= multiplier * multiplicand;
 * using only a single 18x18 multiplier, a few shifts and adders.
 *
 * See "Expanding Virtex-II" by Ken Chapman, Xilinx UK, 06/30/2001 for
 * a discussion about expanding multipliers.
 *
 */
   wire /* unsigned */  [3:0] multiplier_lsb;
   wire signed         [17:0] multiplier_msb;

   reg signed [19:0] partial_product_1;
   reg signed [33:0] partial_product_2;

   assign multiplier_lsb = multiplier[3:0]; 
   assign multiplier_msb = multiplier[21:4];

   always @(posedge clk)
     if (~rst) partial_product_2 <= 34'b0;
     else if (clk_en) partial_product_2 <= multiplier_msb * multiplicand;
     else partial_product_2 <= partial_product_2;

   always @(posedge clk)
     if (~rst) partial_product_1 <= 20'b0;
     else if (clk_en) 
       partial_product_1 <= (multiplier_lsb[0] ? {{4{multiplicand[15]}}, multiplicand      } : 20'b0) + 
                            (multiplier_lsb[1] ? {{3{multiplicand[15]}}, multiplicand, 1'b0} : 20'b0) +
                            (multiplier_lsb[2] ? {{2{multiplicand[15]}}, multiplicand, 2'b0} : 20'b0) +
                            (multiplier_lsb[3] ? {{1{multiplicand[15]}}, multiplicand, 3'b0} : 20'b0);
     else partial_product_1 <= partial_product_1;

   always @(posedge clk)
     if (~rst) product <= 38'b0;
     else if (clk_en) product <=  {partial_product_2, 4'b0} + { {18{partial_product_1[19]}}, partial_product_1};
     else product <= product;

endmodule

