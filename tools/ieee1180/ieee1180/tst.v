`timescale 1ns/1ps
module tst;

  reg signed [11:0]i;
  reg clk;
  reg rst;
  wire signed [8:0]dta_out;
  wire              dta_out_valid;
  reg signed [11:0]dta_in;
  reg signed [11:0]dta_in_array[0:63];
  integer file, count, j;

  initial clk = 0;
  initial rst = 0;
  initial i = 0;
  initial j = 0;
  initial 
    begin
      $readmemh("idct-in", dta_in_array, 0, 63);
    end

initial 
  forever clk = #10 ~clk;
  
always @(posedge clk)
 rst <= 1;

always @(posedge clk)
 if (~rst)
   i <= 0;
 else 
  i <= i+1;

wire dta_in_valid = (i != 0);

always @(posedge clk)
  if ( i <= 63)
     dta_in <= dta_in_array[i];
  else 
     dta_in <= 0;


  idct          
                  idct(.clk(clk), .clk_en(1'b1), .rst(rst), 
                  .iquant_level(dta_in), .iquant_valid(dta_in_valid), 
                  .idct_data(dta_out), .idct_valid(dta_out_valid));
							 
always @(posedge clk)
  begin
    if (dta_out_valid) 
      begin
        j <= j + 1;
        #0 $display(dta_out);
      end
  end

always @(posedge clk)
  if (j == 64) 
    begin
      $finish();
    end

//`define DEBUG_VCD 1
`ifdef DEBUG_VCD
  initial 
    begin // generate vcd dump, for instance for use with covered (covered.sourceforge.net) or dinotrace
      $dumpfile("testbench.vcd");
      $dumpvars;
    end
`endif
		        

endmodule 
