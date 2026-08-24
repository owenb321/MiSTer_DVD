/* 
 * vlc_tables.v
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
 * vlc_tables - Variable Length Code Tables. Tables B-1 to B-5 and B-9 to B-15 from ISO/IEC 13818-2.
 */

/*
  Function macroblock_address_increment_dec translates 
  macroblock address increment vlc code to {codelength, codeword} pairs 
  as in table B-1 from ISO/IEC 13818-2. 
  First 4 bits of output are` code length, next 5 bits of output are code value.
*/
   
function [10:0]macroblock_address_increment_dec;
  input [10:0]codeword;
  begin
    casex(codeword)
      11'b0000_0100_011: macroblock_address_increment_dec = {4'd11, 6'd22, 1'b0};
      11'b0000_0100_010: macroblock_address_increment_dec = {4'd11, 6'd23, 1'b0};
      11'b0000_0100_001: macroblock_address_increment_dec = {4'd11, 6'd24, 1'b0};
      11'b0000_0100_000: macroblock_address_increment_dec = {4'd11, 6'd25, 1'b0};
      11'b0000_0011_111: macroblock_address_increment_dec = {4'd11, 6'd26, 1'b0};
      11'b0000_0011_110: macroblock_address_increment_dec = {4'd11, 6'd27, 1'b0};
      11'b0000_0011_101: macroblock_address_increment_dec = {4'd11, 6'd28, 1'b0};
      11'b0000_0011_100: macroblock_address_increment_dec = {4'd11, 6'd29, 1'b0};
      11'b0000_0011_011: macroblock_address_increment_dec = {4'd11, 6'd30, 1'b0};
      11'b0000_0011_010: macroblock_address_increment_dec = {4'd11, 6'd31, 1'b0};
      11'b0000_0011_001: macroblock_address_increment_dec = {4'd11, 6'd32, 1'b0};
      11'b0000_0011_000: macroblock_address_increment_dec = {4'd11, 6'd33, 1'b0};
      11'b0000_0001_000: macroblock_address_increment_dec = {4'd11, 6'd33, 1'b1}; // macroblock_escape
      11'b0000_0101_11x: macroblock_address_increment_dec = {4'd10, 6'd16, 1'b0};
      11'b0000_0101_10x: macroblock_address_increment_dec = {4'd10, 6'd17, 1'b0};
      11'b0000_0101_01x: macroblock_address_increment_dec = {4'd10, 6'd18, 1'b0};
      11'b0000_0101_00x: macroblock_address_increment_dec = {4'd10, 6'd19, 1'b0};
      11'b0000_0100_11x: macroblock_address_increment_dec = {4'd10, 6'd20, 1'b0};
      11'b0000_0100_10x: macroblock_address_increment_dec = {4'd10, 6'd21, 1'b0};
      11'b0000_1011_xxx: macroblock_address_increment_dec = {4'd8,  6'd10, 1'b0};
      11'b0000_1010_xxx: macroblock_address_increment_dec = {4'd8,  6'd11, 1'b0};
      11'b0000_1001_xxx: macroblock_address_increment_dec = {4'd8,  6'd12, 1'b0};
      11'b0000_1000_xxx: macroblock_address_increment_dec = {4'd8,  6'd13, 1'b0};
      11'b0000_0111_xxx: macroblock_address_increment_dec = {4'd8,  6'd14, 1'b0};
      11'b0000_0110_xxx: macroblock_address_increment_dec = {4'd8,  6'd15, 1'b0};
      11'b0000_111x_xxx: macroblock_address_increment_dec = {4'd7,  6'd8,  1'b0};
      11'b0000_110x_xxx: macroblock_address_increment_dec = {4'd7,  6'd9,  1'b0};
      11'b0001_1xxx_xxx: macroblock_address_increment_dec = {4'd5,  6'd6,  1'b0};
      11'b0001_0xxx_xxx: macroblock_address_increment_dec = {4'd5,  6'd7,  1'b0};
      11'b0011_xxxx_xxx: macroblock_address_increment_dec = {4'd4,  6'd4,  1'b0};
      11'b0010_xxxx_xxx: macroblock_address_increment_dec = {4'd4,  6'd5,  1'b0};
      11'b011x_xxxx_xxx: macroblock_address_increment_dec = {4'd3,  6'd2,  1'b0};
      11'b010x_xxxx_xxx: macroblock_address_increment_dec = {4'd3,  6'd3,  1'b0};
      11'b1xxx_xxxx_xxx: macroblock_address_increment_dec = {4'd1,  6'd1,  1'b0};
      default            macroblock_address_increment_dec = {4'd0,  6'd0,  1'b0}; // Error
    endcase
  end
endfunction

/*
  Function macroblock_type_dec translates 
  macroblock type vlc code to {codelength, codeword} pairs 
  in tables B-2 to B-5 from ISO/IEC 13818-2, as selected by picture_coding_type. 
  I don't do scalability, hence scalable_mode and tables B-6 to B-8 are not used.
  First 4 bits of output are code length, next 6 bits of output are code value.
  Typical use:
  {next_shift[3:0], macroblock_quant, macroblock_motion_forward, macroblock_motion_backward, 
   macroblock_pattern, macroblock_intra, spatial_temporal_weight_code_flag} = 
   macroblock_type_dec(.picture_coding_type(picture_coding_type), .codeword(codeword));
*/
   
function [9:0]macroblock_type_dec;
  input [5:0]codeword;
  input [2:0]picture_coding_type;
  begin
    casex(picture_coding_type)
      3'b001: // intra-coded (I)
        casex(codeword)
          6'b01xx_xx: macroblock_type_dec = {4'd2,  6'b100010};
          6'b1xxx_xx: macroblock_type_dec = {4'd1,  6'b000010};
          default     macroblock_type_dec = {4'd0,  6'b111111}; // Error
        endcase
      3'b010: // predictive-coded (P)
        casex(codeword)
          6'b0000_01: macroblock_type_dec = {4'd6,  6'b100010};
          6'b0001_1x: macroblock_type_dec = {4'd5,  6'b000010};
          6'b0001_0x: macroblock_type_dec = {4'd5,  6'b110100};
          6'b0000_1x: macroblock_type_dec = {4'd5,  6'b100100};
          6'b001x_xx: macroblock_type_dec = {4'd3,  6'b010000};
          6'b01xx_xx: macroblock_type_dec = {4'd2,  6'b000100};
          6'b1xxx_xx: macroblock_type_dec = {4'd1,  6'b010100};
          default     macroblock_type_dec = {4'd0,  6'b111111}; // Error
        endcase
      3'b011: // bidirectionally-predictive-coded (B)
        casex(codeword)
          6'b0000_11: macroblock_type_dec = {4'd6,  6'b110100};
          6'b0000_10: macroblock_type_dec = {4'd6,  6'b101100};
          6'b0000_01: macroblock_type_dec = {4'd6,  6'b100010};
          6'b0001_1x: macroblock_type_dec = {4'd5,  6'b000010};
          6'b0001_0x: macroblock_type_dec = {4'd5,  6'b111100};
          6'b0010_xx: macroblock_type_dec = {4'd4,  6'b010000};
          6'b0011_xx: macroblock_type_dec = {4'd4,  6'b010100};
          6'b010x_xx: macroblock_type_dec = {4'd3,  6'b001000};
          6'b011x_xx: macroblock_type_dec = {4'd3,  6'b001100};
          6'b10xx_xx: macroblock_type_dec = {4'd2,  6'b011000};
          6'b11xx_xx: macroblock_type_dec = {4'd2,  6'b011100};
          default     macroblock_type_dec = {4'd0,  6'b111111}; // Error
        endcase
      default // error
                      macroblock_type_dec = {4'd0,  6'b111111}; // Error
    endcase 
  end
endfunction


/*
  Function coded_block_pattern_dec translates 
  coded block pattern vlc code to {codelength, codeword} pairs 
  as in table B-9 from ISO/IEC 13818-2. 
  First 4 bits of output are` code length, next 6 bits of output are code value.
*/
   
function [9:0]coded_block_pattern_dec;
  input [8:0]codeword;
  begin
    casex(codeword)
      9'b0000_0011_1: coded_block_pattern_dec = {4'd9,  6'd31};
      9'b0000_0011_0: coded_block_pattern_dec = {4'd9,  6'd47};
      9'b0000_0010_1: coded_block_pattern_dec = {4'd9,  6'd55};
      9'b0000_0010_0: coded_block_pattern_dec = {4'd9,  6'd59};
      9'b0000_0001_1: coded_block_pattern_dec = {4'd9,  6'd27};
      9'b0000_0001_0: coded_block_pattern_dec = {4'd9,  6'd39};
      9'b0000_0000_1: coded_block_pattern_dec = {4'd9,  6'd0};
      9'b0001_1111_x: coded_block_pattern_dec = {4'd8,  6'd7};
      9'b0001_1110_x: coded_block_pattern_dec = {4'd8,  6'd11};
      9'b0001_1101_x: coded_block_pattern_dec = {4'd8,  6'd19};
      9'b0001_1100_x: coded_block_pattern_dec = {4'd8,  6'd35};
      9'b0001_1011_x: coded_block_pattern_dec = {4'd8,  6'd13};
      9'b0001_1010_x: coded_block_pattern_dec = {4'd8,  6'd49};
      9'b0001_1001_x: coded_block_pattern_dec = {4'd8,  6'd21};
      9'b0001_1000_x: coded_block_pattern_dec = {4'd8,  6'd41};
      9'b0001_0111_x: coded_block_pattern_dec = {4'd8,  6'd14};
      9'b0001_0110_x: coded_block_pattern_dec = {4'd8,  6'd50};
      9'b0001_0101_x: coded_block_pattern_dec = {4'd8,  6'd22};
      9'b0001_0100_x: coded_block_pattern_dec = {4'd8,  6'd42};
      9'b0001_0011_x: coded_block_pattern_dec = {4'd8,  6'd15};
      9'b0001_0010_x: coded_block_pattern_dec = {4'd8,  6'd51};
      9'b0001_0001_x: coded_block_pattern_dec = {4'd8,  6'd23};
      9'b0001_0000_x: coded_block_pattern_dec = {4'd8,  6'd43};
      9'b0000_1111_x: coded_block_pattern_dec = {4'd8,  6'd25};
      9'b0000_1110_x: coded_block_pattern_dec = {4'd8,  6'd37};
      9'b0000_1101_x: coded_block_pattern_dec = {4'd8,  6'd26};
      9'b0000_1100_x: coded_block_pattern_dec = {4'd8,  6'd38};
      9'b0000_1011_x: coded_block_pattern_dec = {4'd8,  6'd29};
      9'b0000_1010_x: coded_block_pattern_dec = {4'd8,  6'd45};
      9'b0000_1001_x: coded_block_pattern_dec = {4'd8,  6'd53};
      9'b0000_1000_x: coded_block_pattern_dec = {4'd8,  6'd57};
      9'b0000_0111_x: coded_block_pattern_dec = {4'd8,  6'd30};
      9'b0000_0110_x: coded_block_pattern_dec = {4'd8,  6'd46};
      9'b0000_0101_x: coded_block_pattern_dec = {4'd8,  6'd54};
      9'b0000_0100_x: coded_block_pattern_dec = {4'd8,  6'd58};
      9'b0010_111x_x: coded_block_pattern_dec = {4'd7,  6'd5};
      9'b0010_110x_x: coded_block_pattern_dec = {4'd7,  6'd9};
      9'b0010_101x_x: coded_block_pattern_dec = {4'd7,  6'd17};
      9'b0010_100x_x: coded_block_pattern_dec = {4'd7,  6'd33};
      9'b0010_011x_x: coded_block_pattern_dec = {4'd7,  6'd6};
      9'b0010_010x_x: coded_block_pattern_dec = {4'd7,  6'd10};
      9'b0010_001x_x: coded_block_pattern_dec = {4'd7,  6'd18};
      9'b0010_000x_x: coded_block_pattern_dec = {4'd7,  6'd34};
      9'b0011_11xx_x: coded_block_pattern_dec = {4'd6,  6'd24};
      9'b0011_10xx_x: coded_block_pattern_dec = {4'd6,  6'd36};
      9'b0011_01xx_x: coded_block_pattern_dec = {4'd6,  6'd3};
      9'b0011_00xx_x: coded_block_pattern_dec = {4'd6,  6'd63};
      9'b1001_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd12};
      9'b1001_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd48};
      9'b1000_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd20};
      9'b1000_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd40};
      9'b0111_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd28};
      9'b0111_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd44};
      9'b0110_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd52};
      9'b0110_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd56};
      9'b0101_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd1};
      9'b0101_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd61};
      9'b0100_1xxx_x: coded_block_pattern_dec = {4'd5,  6'd2};
      9'b0100_0xxx_x: coded_block_pattern_dec = {4'd5,  6'd62};
      9'b1101_xxxx_x: coded_block_pattern_dec = {4'd4,  6'd4};
      9'b1100_xxxx_x: coded_block_pattern_dec = {4'd4,  6'd8};
      9'b1011_xxxx_x: coded_block_pattern_dec = {4'd4,  6'd16};
      9'b1010_xxxx_x: coded_block_pattern_dec = {4'd4,  6'd32};
      9'b111x_xxxx_x: coded_block_pattern_dec = {4'd3,  6'd60};
      default         coded_block_pattern_dec = {4'd0,  6'd0}; // Error
    endcase
  end
endfunction

/*
  Function motion_code_dec translates 
  motion code vlc to {codelength, codeword, sign} triplets 
  as in table B-10 from ISO/IEC 13818-2. 
  First 4 bits of output are` code length, 
  next 5 bits of output are code value, 
  last bit is sign (1 = negative, 0 = positive).
*/
   
function [9:0]motion_code_dec;
  input [10:0]codeword;
  begin
    casex(codeword)
      11'b0000_0011_001: motion_code_dec = {4'd11, 5'd16, 1'b1};
      11'b0000_0011_011: motion_code_dec = {4'd11, 5'd15, 1'b1};
      11'b0000_0011_101: motion_code_dec = {4'd11, 5'd14, 1'b1};
      11'b0000_0011_111: motion_code_dec = {4'd11, 5'd13, 1'b1};
      11'b0000_0100_001: motion_code_dec = {4'd11, 5'd12, 1'b1};
      11'b0000_0100_011: motion_code_dec = {4'd11, 5'd11, 1'b1};
      11'b0000_0100_010: motion_code_dec = {4'd11, 5'd11, 1'b0};
      11'b0000_0100_000: motion_code_dec = {4'd11, 5'd12, 1'b0};
      11'b0000_0011_110: motion_code_dec = {4'd11, 5'd13, 1'b0};
      11'b0000_0011_100: motion_code_dec = {4'd11, 5'd14, 1'b0};
      11'b0000_0011_010: motion_code_dec = {4'd11, 5'd15, 1'b0};
      11'b0000_0011_000: motion_code_dec = {4'd11, 5'd16, 1'b0};
      11'b0000_0100_11x: motion_code_dec = {4'd10, 5'd10, 1'b1};
      11'b0000_0101_01x: motion_code_dec = {4'd10, 5'd9,  1'b1};
      11'b0000_0101_11x: motion_code_dec = {4'd10, 5'd8,  1'b1};
      11'b0000_0101_10x: motion_code_dec = {4'd10, 5'd8,  1'b0};
      11'b0000_0101_00x: motion_code_dec = {4'd10, 5'd9,  1'b0};
      11'b0000_0100_10x: motion_code_dec = {4'd10, 5'd10, 1'b0};
      11'b0000_0111_xxx: motion_code_dec = {4'd8,  5'd7,  1'b1};
      11'b0000_1001_xxx: motion_code_dec = {4'd8,  5'd6,  1'b1};
      11'b0000_1011_xxx: motion_code_dec = {4'd8,  5'd5,  1'b1};
      11'b0000_1010_xxx: motion_code_dec = {4'd8,  5'd5,  1'b0};
      11'b0000_1000_xxx: motion_code_dec = {4'd8,  5'd6,  1'b0};
      11'b0000_0110_xxx: motion_code_dec = {4'd8,  5'd7,  1'b0};
      11'b0000_111x_xxx: motion_code_dec = {4'd7,  5'd4,  1'b1};
      11'b0000_110x_xxx: motion_code_dec = {4'd7,  5'd4,  1'b0};
      11'b0001_1xxx_xxx: motion_code_dec = {4'd5,  5'd3,  1'b1};
      11'b0001_0xxx_xxx: motion_code_dec = {4'd5,  5'd3,  1'b0};
      11'b0011_xxxx_xxx: motion_code_dec = {4'd4,  5'd2,  1'b1};
      11'b0010_xxxx_xxx: motion_code_dec = {4'd4,  5'd2,  1'b0};
      11'b011x_xxxx_xxx: motion_code_dec = {4'd3,  5'd1,  1'b1};
      11'b010x_xxxx_xxx: motion_code_dec = {4'd3,  5'd1,  1'b0};
      11'b1xxx_xxxx_xxx: motion_code_dec = {4'd1,  5'd0,  1'b0};
      default            motion_code_dec = {4'd0,  5'd0,  1'b0}; // Error
    endcase
  end
endfunction


/*
  Function dmvector_dec translates 
  dmvector vlc code to {codelength, codeword, sign} triplets 
  as in table B-11 from ISO/IEC 13818-2. 
  First 2 bits of output are` code length, next bit of output is code value.
  Last bit is sign (1 if negative, 0 if positive).
*/
   
function [3:0]dmvector_dec;
  input [1:0]codeword;
  begin
    casex(codeword)
      2'b11:  dmvector_dec = {2'd2,  1'd1, 1'b1};
      2'b10:  dmvector_dec = {2'd2,  1'd1, 1'b0};
      2'b0x:  dmvector_dec = {2'd1,  1'd0, 1'b0};
      default dmvector_dec = {2'd0,  1'd0, 1'b0}; // Error
    endcase
  end
endfunction

/*
  Function dct_dc_size_luminance_dec translates 
  dct_dc_size_luminance vlc code to {codelength, codeword} pairs 
  as in table B-12 from ISO/IEC 13818-2. 
  First 4 bits of output are code length, next 5 bits are code value.
*/
   
function [8:0]dct_dc_size_luminance_dec;
  input [8:0]codeword;
  begin
    `ifdef DEBUG_VLC
    $strobe("%m\tcodeword:                    %b", codeword);
    $strobe("%m\tdct_dc_size_luminance_dec:   %b", dct_dc_size_luminance_dec);
    `endif
    casex(codeword)
      9'b1111_1111_0: dct_dc_size_luminance_dec = {4'd9, 5'd10};
      9'b1111_1111_1: dct_dc_size_luminance_dec = {4'd9, 5'd11};
      9'b1111_1110_x: dct_dc_size_luminance_dec = {4'd8, 5'd9};
      9'b1111_110x_x: dct_dc_size_luminance_dec = {4'd7, 5'd8};
      9'b1111_10xx_x: dct_dc_size_luminance_dec = {4'd6, 5'd7};
      9'b1111_0xxx_x: dct_dc_size_luminance_dec = {4'd5, 5'd6};
      9'b1110_xxxx_x: dct_dc_size_luminance_dec = {4'd4, 5'd5};
      9'b100x_xxxx_x: dct_dc_size_luminance_dec = {4'd3, 5'd0};
      9'b101x_xxxx_x: dct_dc_size_luminance_dec = {4'd3, 5'd3};
      9'b110x_xxxx_x: dct_dc_size_luminance_dec = {4'd3, 5'd4};
      9'b00xx_xxxx_x: dct_dc_size_luminance_dec = {4'd2, 5'd1};
      9'b01xx_xxxx_x: dct_dc_size_luminance_dec = {4'd2, 5'd2};
      default         dct_dc_size_luminance_dec = {4'd0, 5'd0}; // Error
    endcase
  end
endfunction

/*
  Function dct_dc_size_chrominance_dec translates 
  dct_dc_size_chrominance vlc code to {codelength, codeword} pairs 
  as in table B-13 from ISO/IEC 13818-2. 
  First 4 bits of output are code length, next 5 bits are code value.
*/
   
function [8:0]dct_dc_size_chrominance_dec;
  input [9:0]codeword;
  begin
    `ifdef DEBUG_VLC
    $strobe("%m\tcodeword:                    %b", codeword);
    $strobe("%m\tdct_dc_size_chrominance_dec: %b", dct_dc_size_chrominance_dec);
    `endif
    casex(codeword)
      10'b1111_1111_10: dct_dc_size_chrominance_dec = {4'd10, 5'd10};
      10'b1111_1111_11: dct_dc_size_chrominance_dec = {4'd10, 5'd11};
      10'b1111_1111_0x: dct_dc_size_chrominance_dec = {4'd9, 5'd9};
      10'b1111_1110_xx: dct_dc_size_chrominance_dec = {4'd8, 5'd8};
      10'b1111_110x_xx: dct_dc_size_chrominance_dec = {4'd7, 5'd7};
      10'b1111_10xx_xx: dct_dc_size_chrominance_dec = {4'd6, 5'd6};
      10'b1111_0xxx_xx: dct_dc_size_chrominance_dec = {4'd5, 5'd5};
      10'b1110_xxxx_xx: dct_dc_size_chrominance_dec = {4'd4, 5'd4};
      10'b110x_xxxx_xx: dct_dc_size_chrominance_dec = {4'd3, 5'd3};
      10'b00xx_xxxx_xx: dct_dc_size_chrominance_dec = {4'd2, 5'd0};
      10'b01xx_xxxx_xx: dct_dc_size_chrominance_dec = {4'd2, 5'd1};
      10'b10xx_xxxx_xx: dct_dc_size_chrominance_dec = {4'd2, 5'd2};
      default           dct_dc_size_chrominance_dec = {4'd0, 5'd0};
    endcase
  end
endfunction

/*
  Function dct_coefficient_0_dec translates 
  dct coefficient table zero vlc code to {codelength, run , level} triplets 
  as in table B-14 from ISO/IEC 13818-2. 
  First 5 bits are code length, 
  next 5 bits are run value,
  next 6 bits are unsigned level value.
  Code length includes sign bit.
*/
   
function [15:0]dct_coefficient_0_dec;
  input [15:0]codeword;
  begin
    `ifdef DEBUG_VLC
    $strobe("%m\tcodeword:                    %b", codeword);
    $strobe("%m\tdct_coefficient_0_dec:       %b", dct_coefficient_0_dec);
    `endif
    casex(codeword)
      16'b0000000000010011: dct_coefficient_0_dec = {5'd17, 5'd01, 6'd15}; // codeword = 0000000000010011, run =  1, level =  15
      16'b0000000000010010: dct_coefficient_0_dec = {5'd17, 5'd01, 6'd16}; // codeword = 0000000000010010, run =  1, level =  16
      16'b0000000000010001: dct_coefficient_0_dec = {5'd17, 5'd01, 6'd17}; // codeword = 0000000000010001, run =  1, level =  17
      16'b0000000000010000: dct_coefficient_0_dec = {5'd17, 5'd01, 6'd18}; // codeword = 0000000000010000, run =  1, level =  18
      16'b0000000000010100: dct_coefficient_0_dec = {5'd17, 5'd06, 6'd03}; // codeword = 0000000000010100, run =  6, level =   3
      16'b0000000000011010: dct_coefficient_0_dec = {5'd17, 5'd11, 6'd02}; // codeword = 0000000000011010, run = 11, level =   2
      16'b0000000000011001: dct_coefficient_0_dec = {5'd17, 5'd12, 6'd02}; // codeword = 0000000000011001, run = 12, level =   2
      16'b0000000000011000: dct_coefficient_0_dec = {5'd17, 5'd13, 6'd02}; // codeword = 0000000000011000, run = 13, level =   2
      16'b0000000000010111: dct_coefficient_0_dec = {5'd17, 5'd14, 6'd02}; // codeword = 0000000000010111, run = 14, level =   2
      16'b0000000000010110: dct_coefficient_0_dec = {5'd17, 5'd15, 6'd02}; // codeword = 0000000000010110, run = 15, level =   2
      16'b0000000000010101: dct_coefficient_0_dec = {5'd17, 5'd16, 6'd02}; // codeword = 0000000000010101, run = 16, level =   2
      16'b0000000000011111: dct_coefficient_0_dec = {5'd17, 5'd27, 6'd01}; // codeword = 0000000000011111, run = 27, level =   1
      16'b0000000000011110: dct_coefficient_0_dec = {5'd17, 5'd28, 6'd01}; // codeword = 0000000000011110, run = 28, level =   1
      16'b0000000000011101: dct_coefficient_0_dec = {5'd17, 5'd29, 6'd01}; // codeword = 0000000000011101, run = 29, level =   1
      16'b0000000000011100: dct_coefficient_0_dec = {5'd17, 5'd30, 6'd01}; // codeword = 0000000000011100, run = 30, level =   1
      16'b0000000000011011: dct_coefficient_0_dec = {5'd17, 5'd31, 6'd01}; // codeword = 0000000000011011, run = 31, level =   1
      16'b000000000011000x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd32}; // codeword = 000000000011000 , run =  0, level =  32
      16'b000000000010111x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd33}; // codeword = 000000000010111 , run =  0, level =  33
      16'b000000000010110x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd34}; // codeword = 000000000010110 , run =  0, level =  34
      16'b000000000010101x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd35}; // codeword = 000000000010101 , run =  0, level =  35
      16'b000000000010100x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd36}; // codeword = 000000000010100 , run =  0, level =  36
      16'b000000000010011x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd37}; // codeword = 000000000010011 , run =  0, level =  37
      16'b000000000010010x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd38}; // codeword = 000000000010010 , run =  0, level =  38
      16'b000000000010001x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd39}; // codeword = 000000000010001 , run =  0, level =  39
      16'b000000000010000x: dct_coefficient_0_dec = {5'd16, 5'd00, 6'd40}; // codeword = 000000000010000 , run =  0, level =  40
      16'b000000000011111x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd08}; // codeword = 000000000011111 , run =  1, level =   8
      16'b000000000011110x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd09}; // codeword = 000000000011110 , run =  1, level =   9
      16'b000000000011101x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd10}; // codeword = 000000000011101 , run =  1, level =  10
      16'b000000000011100x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd11}; // codeword = 000000000011100 , run =  1, level =  11
      16'b000000000011011x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd12}; // codeword = 000000000011011 , run =  1, level =  12
      16'b000000000011010x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd13}; // codeword = 000000000011010 , run =  1, level =  13
      16'b000000000011001x: dct_coefficient_0_dec = {5'd16, 5'd01, 6'd14}; // codeword = 000000000011001 , run =  1, level =  14
      16'b00000000011111xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd16}; // codeword = 00000000011111  , run =  0, level =  16
      16'b00000000011110xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd17}; // codeword = 00000000011110  , run =  0, level =  17
      16'b00000000011101xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd18}; // codeword = 00000000011101  , run =  0, level =  18
      16'b00000000011100xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd19}; // codeword = 00000000011100  , run =  0, level =  19
      16'b00000000011011xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd20}; // codeword = 00000000011011  , run =  0, level =  20
      16'b00000000011010xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd21}; // codeword = 00000000011010  , run =  0, level =  21
      16'b00000000011001xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd22}; // codeword = 00000000011001  , run =  0, level =  22
      16'b00000000011000xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd23}; // codeword = 00000000011000  , run =  0, level =  23
      16'b00000000010111xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd24}; // codeword = 00000000010111  , run =  0, level =  24
      16'b00000000010110xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd25}; // codeword = 00000000010110  , run =  0, level =  25
      16'b00000000010101xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd26}; // codeword = 00000000010101  , run =  0, level =  26
      16'b00000000010100xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd27}; // codeword = 00000000010100  , run =  0, level =  27
      16'b00000000010011xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd28}; // codeword = 00000000010011  , run =  0, level =  28
      16'b00000000010010xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd29}; // codeword = 00000000010010  , run =  0, level =  29
      16'b00000000010001xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd30}; // codeword = 00000000010001  , run =  0, level =  30
      16'b00000000010000xx: dct_coefficient_0_dec = {5'd15, 5'd00, 6'd31}; // codeword = 00000000010000  , run =  0, level =  31
      16'b0000000011010xxx: dct_coefficient_0_dec = {5'd14, 5'd00, 6'd12}; // codeword = 0000000011010   , run =  0, level =  12
      16'b0000000011001xxx: dct_coefficient_0_dec = {5'd14, 5'd00, 6'd13}; // codeword = 0000000011001   , run =  0, level =  13
      16'b0000000011000xxx: dct_coefficient_0_dec = {5'd14, 5'd00, 6'd14}; // codeword = 0000000011000   , run =  0, level =  14
      16'b0000000010111xxx: dct_coefficient_0_dec = {5'd14, 5'd00, 6'd15}; // codeword = 0000000010111   , run =  0, level =  15
      16'b0000000010110xxx: dct_coefficient_0_dec = {5'd14, 5'd01, 6'd06}; // codeword = 0000000010110   , run =  1, level =   6
      16'b0000000010101xxx: dct_coefficient_0_dec = {5'd14, 5'd01, 6'd07}; // codeword = 0000000010101   , run =  1, level =   7
      16'b0000000010100xxx: dct_coefficient_0_dec = {5'd14, 5'd02, 6'd05}; // codeword = 0000000010100   , run =  2, level =   5
      16'b0000000010011xxx: dct_coefficient_0_dec = {5'd14, 5'd03, 6'd04}; // codeword = 0000000010011   , run =  3, level =   4
      16'b0000000010010xxx: dct_coefficient_0_dec = {5'd14, 5'd05, 6'd03}; // codeword = 0000000010010   , run =  5, level =   3
      16'b0000000010001xxx: dct_coefficient_0_dec = {5'd14, 5'd09, 6'd02}; // codeword = 0000000010001   , run =  9, level =   2
      16'b0000000010000xxx: dct_coefficient_0_dec = {5'd14, 5'd10, 6'd02}; // codeword = 0000000010000   , run = 10, level =   2
      16'b0000000011111xxx: dct_coefficient_0_dec = {5'd14, 5'd22, 6'd01}; // codeword = 0000000011111   , run = 22, level =   1
      16'b0000000011110xxx: dct_coefficient_0_dec = {5'd14, 5'd23, 6'd01}; // codeword = 0000000011110   , run = 23, level =   1
      16'b0000000011101xxx: dct_coefficient_0_dec = {5'd14, 5'd24, 6'd01}; // codeword = 0000000011101   , run = 24, level =   1
      16'b0000000011100xxx: dct_coefficient_0_dec = {5'd14, 5'd25, 6'd01}; // codeword = 0000000011100   , run = 25, level =   1
      16'b0000000011011xxx: dct_coefficient_0_dec = {5'd14, 5'd26, 6'd01}; // codeword = 0000000011011   , run = 26, level =   1
      16'b000000011101xxxx: dct_coefficient_0_dec = {5'd13, 5'd00, 6'd08}; // codeword = 000000011101    , run =  0, level =   8
      16'b000000011000xxxx: dct_coefficient_0_dec = {5'd13, 5'd00, 6'd09}; // codeword = 000000011000    , run =  0, level =   9
      16'b000000010011xxxx: dct_coefficient_0_dec = {5'd13, 5'd00, 6'd10}; // codeword = 000000010011    , run =  0, level =  10
      16'b000000010000xxxx: dct_coefficient_0_dec = {5'd13, 5'd00, 6'd11}; // codeword = 000000010000    , run =  0, level =  11
      16'b000000011011xxxx: dct_coefficient_0_dec = {5'd13, 5'd01, 6'd05}; // codeword = 000000011011    , run =  1, level =   5
      16'b000000010100xxxx: dct_coefficient_0_dec = {5'd13, 5'd02, 6'd04}; // codeword = 000000010100    , run =  2, level =   4
      16'b000000011100xxxx: dct_coefficient_0_dec = {5'd13, 5'd03, 6'd03}; // codeword = 000000011100    , run =  3, level =   3
      16'b000000010010xxxx: dct_coefficient_0_dec = {5'd13, 5'd04, 6'd03}; // codeword = 000000010010    , run =  4, level =   3
      16'b000000011110xxxx: dct_coefficient_0_dec = {5'd13, 5'd06, 6'd02}; // codeword = 000000011110    , run =  6, level =   2
      16'b000000010101xxxx: dct_coefficient_0_dec = {5'd13, 5'd07, 6'd02}; // codeword = 000000010101    , run =  7, level =   2
      16'b000000010001xxxx: dct_coefficient_0_dec = {5'd13, 5'd08, 6'd02}; // codeword = 000000010001    , run =  8, level =   2
      16'b000000011111xxxx: dct_coefficient_0_dec = {5'd13, 5'd17, 6'd01}; // codeword = 000000011111    , run = 17, level =   1
      16'b000000011010xxxx: dct_coefficient_0_dec = {5'd13, 5'd18, 6'd01}; // codeword = 000000011010    , run = 18, level =   1
      16'b000000011001xxxx: dct_coefficient_0_dec = {5'd13, 5'd19, 6'd01}; // codeword = 000000011001    , run = 19, level =   1
      16'b000000010111xxxx: dct_coefficient_0_dec = {5'd13, 5'd20, 6'd01}; // codeword = 000000010111    , run = 20, level =   1
      16'b000000010110xxxx: dct_coefficient_0_dec = {5'd13, 5'd21, 6'd01}; // codeword = 000000010110    , run = 21, level =   1
      16'b0000001010xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd00, 6'd07}; // codeword = 0000001010      , run =  0, level =   7
      16'b0000001100xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd01, 6'd04}; // codeword = 0000001100      , run =  1, level =   4
      16'b0000001011xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd02, 6'd03}; // codeword = 0000001011      , run =  2, level =   3
      16'b0000001111xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd04, 6'd02}; // codeword = 0000001111      , run =  4, level =   2
      16'b0000001001xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd05, 6'd02}; // codeword = 0000001001      , run =  5, level =   2
      16'b0000001110xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd14, 6'd01}; // codeword = 0000001110      , run = 14, level =   1
      16'b0000001101xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd15, 6'd01}; // codeword = 0000001101      , run = 15, level =   1
      16'b0000001000xxxxxx: dct_coefficient_0_dec = {5'd11, 5'd16, 6'd01}; // codeword = 0000001000      , run = 16, level =   1
      16'b00100110xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd00, 6'd05}; // codeword = 00100110        , run =  0, level =   5
      16'b00100001xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd00, 6'd06}; // codeword = 00100001        , run =  0, level =   6
      16'b00100101xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd01, 6'd03}; // codeword = 00100101        , run =  1, level =   3
      16'b00100100xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd03, 6'd02}; // codeword = 00100100        , run =  3, level =   2
      16'b00100111xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd10, 6'd01}; // codeword = 00100111        , run = 10, level =   1
      16'b00100011xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd11, 6'd01}; // codeword = 00100011        , run = 11, level =   1
      16'b00100010xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd12, 6'd01}; // codeword = 00100010        , run = 12, level =   1
      16'b00100000xxxxxxxx: dct_coefficient_0_dec = {5'd09, 5'd13, 6'd01}; // codeword = 00100000        , run = 13, level =   1
      16'b0000110xxxxxxxxx: dct_coefficient_0_dec = {5'd08, 5'd00, 6'd04}; // codeword = 0000110         , run =  0, level =   4
      16'b0000100xxxxxxxxx: dct_coefficient_0_dec = {5'd08, 5'd02, 6'd02}; // codeword = 0000100         , run =  2, level =   2
      16'b0000111xxxxxxxxx: dct_coefficient_0_dec = {5'd08, 5'd08, 6'd01}; // codeword = 0000111         , run =  8, level =   1
      16'b0000101xxxxxxxxx: dct_coefficient_0_dec = {5'd08, 5'd09, 6'd01}; // codeword = 0000101         , run =  9, level =   1
      16'b000110xxxxxxxxxx: dct_coefficient_0_dec = {5'd07, 5'd01, 6'd02}; // codeword = 000110          , run =  1, level =   2
      16'b000111xxxxxxxxxx: dct_coefficient_0_dec = {5'd07, 5'd05, 6'd01}; // codeword = 000111          , run =  5, level =   1
      16'b000101xxxxxxxxxx: dct_coefficient_0_dec = {5'd07, 5'd06, 6'd01}; // codeword = 000101          , run =  6, level =   1
      16'b000100xxxxxxxxxx: dct_coefficient_0_dec = {5'd07, 5'd07, 6'd01}; // codeword = 000100          , run =  7, level =   1
      16'b000001xxxxxxxxxx: dct_coefficient_0_dec = {5'd06, 5'd00, 6'd00}; // codeword = 000001          , escape (no sign bit)
      16'b00101xxxxxxxxxxx: dct_coefficient_0_dec = {5'd06, 5'd00, 6'd03}; // codeword = 00101           , run =  0, level =   3
      16'b00111xxxxxxxxxxx: dct_coefficient_0_dec = {5'd06, 5'd03, 6'd01}; // codeword = 00111           , run =  3, level =   1
      16'b00110xxxxxxxxxxx: dct_coefficient_0_dec = {5'd06, 5'd04, 6'd01}; // codeword = 00110           , run =  4, level =   1
      16'b0100xxxxxxxxxxxx: dct_coefficient_0_dec = {5'd05, 5'd00, 6'd02}; // codeword = 0100            , run =  0, level =   2
      16'b0101xxxxxxxxxxxx: dct_coefficient_0_dec = {5'd05, 5'd02, 6'd01}; // codeword = 0101            , run =  2, level =   1
      16'b011xxxxxxxxxxxxx: dct_coefficient_0_dec = {5'd04, 5'd01, 6'd01}; // codeword = 011             , run =  1, level =   1
      16'b10xxxxxxxxxxxxxx: dct_coefficient_0_dec = {5'd02, 5'd00, 6'd00}; // codeword = 10              , end of block (no sign bit)
      16'b11xxxxxxxxxxxxxx: dct_coefficient_0_dec = {5'd03, 5'd00, 6'd01}; // codeword = 11              , run =  0, level =   1
      default               dct_coefficient_0_dec = {5'd00, 5'd00, 6'd00}; // Error
    endcase
  end
endfunction

/*
  Function dct_coefficient_1_dec translates 
  dct coefficient table one vlc code to {codelength, run, level} triplets 
  as in table B-15 from ISO/IEC 13818-2. 
  First 5 bits are code length, 
  next 5 bits are run value,
  next 6 bits are unsigned level value.
  Code length includes sign bit.
*/
   
function [15:0]dct_coefficient_1_dec;
  input [15:0]codeword;
  begin
    `ifdef DEBUG_VLC
    $strobe("%m\tcodeword:                    %b", codeword);
    $strobe("%m\tdct_coefficient_1_dec:       %b", dct_coefficient_1_dec);
    `endif
    casex(codeword)
      16'b0000000000010011: dct_coefficient_1_dec = {5'd17, 5'd01, 6'd15}; // codeword = 0000000000010011, run =  1, level =  15
      16'b0000000000010010: dct_coefficient_1_dec = {5'd17, 5'd01, 6'd16}; // codeword = 0000000000010010, run =  1, level =  16
      16'b0000000000010001: dct_coefficient_1_dec = {5'd17, 5'd01, 6'd17}; // codeword = 0000000000010001, run =  1, level =  17
      16'b0000000000010000: dct_coefficient_1_dec = {5'd17, 5'd01, 6'd18}; // codeword = 0000000000010000, run =  1, level =  18
      16'b0000000000010100: dct_coefficient_1_dec = {5'd17, 5'd06, 6'd03}; // codeword = 0000000000010100, run =  6, level =   3
      16'b0000000000011010: dct_coefficient_1_dec = {5'd17, 5'd11, 6'd02}; // codeword = 0000000000011010, run = 11, level =   2
      16'b0000000000011001: dct_coefficient_1_dec = {5'd17, 5'd12, 6'd02}; // codeword = 0000000000011001, run = 12, level =   2
      16'b0000000000011000: dct_coefficient_1_dec = {5'd17, 5'd13, 6'd02}; // codeword = 0000000000011000, run = 13, level =   2
      16'b0000000000010111: dct_coefficient_1_dec = {5'd17, 5'd14, 6'd02}; // codeword = 0000000000010111, run = 14, level =   2
      16'b0000000000010110: dct_coefficient_1_dec = {5'd17, 5'd15, 6'd02}; // codeword = 0000000000010110, run = 15, level =   2
      16'b0000000000010101: dct_coefficient_1_dec = {5'd17, 5'd16, 6'd02}; // codeword = 0000000000010101, run = 16, level =   2
      16'b0000000000011111: dct_coefficient_1_dec = {5'd17, 5'd27, 6'd01}; // codeword = 0000000000011111, run = 27, level =   1
      16'b0000000000011110: dct_coefficient_1_dec = {5'd17, 5'd28, 6'd01}; // codeword = 0000000000011110, run = 28, level =   1
      16'b0000000000011101: dct_coefficient_1_dec = {5'd17, 5'd29, 6'd01}; // codeword = 0000000000011101, run = 29, level =   1
      16'b0000000000011100: dct_coefficient_1_dec = {5'd17, 5'd30, 6'd01}; // codeword = 0000000000011100, run = 30, level =   1
      16'b0000000000011011: dct_coefficient_1_dec = {5'd17, 5'd31, 6'd01}; // codeword = 0000000000011011, run = 31, level =   1
      16'b000000000011000x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd32}; // codeword = 000000000011000 , run =  0, level =  32
      16'b000000000010111x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd33}; // codeword = 000000000010111 , run =  0, level =  33
      16'b000000000010110x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd34}; // codeword = 000000000010110 , run =  0, level =  34
      16'b000000000010101x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd35}; // codeword = 000000000010101 , run =  0, level =  35
      16'b000000000010100x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd36}; // codeword = 000000000010100 , run =  0, level =  36
      16'b000000000010011x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd37}; // codeword = 000000000010011 , run =  0, level =  37
      16'b000000000010010x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd38}; // codeword = 000000000010010 , run =  0, level =  38
      16'b000000000010001x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd39}; // codeword = 000000000010001 , run =  0, level =  39
      16'b000000000010000x: dct_coefficient_1_dec = {5'd16, 5'd00, 6'd40}; // codeword = 000000000010000 , run =  0, level =  40
      16'b000000000011111x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd08}; // codeword = 000000000011111 , run =  1, level =   8
      16'b000000000011110x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd09}; // codeword = 000000000011110 , run =  1, level =   9
      16'b000000000011101x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd10}; // codeword = 000000000011101 , run =  1, level =  10
      16'b000000000011100x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd11}; // codeword = 000000000011100 , run =  1, level =  11
      16'b000000000011011x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd12}; // codeword = 000000000011011 , run =  1, level =  12
      16'b000000000011010x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd13}; // codeword = 000000000011010 , run =  1, level =  13
      16'b000000000011001x: dct_coefficient_1_dec = {5'd16, 5'd01, 6'd14}; // codeword = 000000000011001 , run =  1, level =  14
      16'b00000000011111xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd16}; // codeword = 00000000011111  , run =  0, level =  16
      16'b00000000011110xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd17}; // codeword = 00000000011110  , run =  0, level =  17
      16'b00000000011101xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd18}; // codeword = 00000000011101  , run =  0, level =  18
      16'b00000000011100xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd19}; // codeword = 00000000011100  , run =  0, level =  19
      16'b00000000011011xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd20}; // codeword = 00000000011011  , run =  0, level =  20
      16'b00000000011010xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd21}; // codeword = 00000000011010  , run =  0, level =  21
      16'b00000000011001xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd22}; // codeword = 00000000011001  , run =  0, level =  22
      16'b00000000011000xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd23}; // codeword = 00000000011000  , run =  0, level =  23
      16'b00000000010111xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd24}; // codeword = 00000000010111  , run =  0, level =  24
      16'b00000000010110xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd25}; // codeword = 00000000010110  , run =  0, level =  25
      16'b00000000010101xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd26}; // codeword = 00000000010101  , run =  0, level =  26
      16'b00000000010100xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd27}; // codeword = 00000000010100  , run =  0, level =  27
      16'b00000000010011xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd28}; // codeword = 00000000010011  , run =  0, level =  28
      16'b00000000010010xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd29}; // codeword = 00000000010010  , run =  0, level =  29
      16'b00000000010001xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd30}; // codeword = 00000000010001  , run =  0, level =  30
      16'b00000000010000xx: dct_coefficient_1_dec = {5'd15, 5'd00, 6'd31}; // codeword = 00000000010000  , run =  0, level =  31
      16'b0000000010110xxx: dct_coefficient_1_dec = {5'd14, 5'd01, 6'd06}; // codeword = 0000000010110   , run =  1, level =   6
      16'b0000000010101xxx: dct_coefficient_1_dec = {5'd14, 5'd01, 6'd07}; // codeword = 0000000010101   , run =  1, level =   7
      16'b0000000010100xxx: dct_coefficient_1_dec = {5'd14, 5'd02, 6'd05}; // codeword = 0000000010100   , run =  2, level =   5
      16'b0000000010011xxx: dct_coefficient_1_dec = {5'd14, 5'd03, 6'd04}; // codeword = 0000000010011   , run =  3, level =   4
      16'b0000000010010xxx: dct_coefficient_1_dec = {5'd14, 5'd05, 6'd03}; // codeword = 0000000010010   , run =  5, level =   3
      16'b0000000010001xxx: dct_coefficient_1_dec = {5'd14, 5'd09, 6'd02}; // codeword = 0000000010001   , run =  9, level =   2
      16'b0000000010000xxx: dct_coefficient_1_dec = {5'd14, 5'd10, 6'd02}; // codeword = 0000000010000   , run = 10, level =   2
      16'b0000000011111xxx: dct_coefficient_1_dec = {5'd14, 5'd22, 6'd01}; // codeword = 0000000011111   , run = 22, level =   1
      16'b0000000011110xxx: dct_coefficient_1_dec = {5'd14, 5'd23, 6'd01}; // codeword = 0000000011110   , run = 23, level =   1
      16'b0000000011101xxx: dct_coefficient_1_dec = {5'd14, 5'd24, 6'd01}; // codeword = 0000000011101   , run = 24, level =   1
      16'b0000000011100xxx: dct_coefficient_1_dec = {5'd14, 5'd25, 6'd01}; // codeword = 0000000011100   , run = 25, level =   1
      16'b0000000011011xxx: dct_coefficient_1_dec = {5'd14, 5'd26, 6'd01}; // codeword = 0000000011011   , run = 26, level =   1
      16'b000000011100xxxx: dct_coefficient_1_dec = {5'd13, 5'd03, 6'd03}; // codeword = 000000011100    , run =  3, level =   3
      16'b000000010010xxxx: dct_coefficient_1_dec = {5'd13, 5'd04, 6'd03}; // codeword = 000000010010    , run =  4, level =   3
      16'b000000011110xxxx: dct_coefficient_1_dec = {5'd13, 5'd06, 6'd02}; // codeword = 000000011110    , run =  6, level =   2
      16'b000000010101xxxx: dct_coefficient_1_dec = {5'd13, 5'd07, 6'd02}; // codeword = 000000010101    , run =  7, level =   2
      16'b000000010001xxxx: dct_coefficient_1_dec = {5'd13, 5'd08, 6'd02}; // codeword = 000000010001    , run =  8, level =   2
      16'b000000011111xxxx: dct_coefficient_1_dec = {5'd13, 5'd17, 6'd01}; // codeword = 000000011111    , run = 17, level =   1
      16'b000000011010xxxx: dct_coefficient_1_dec = {5'd13, 5'd18, 6'd01}; // codeword = 000000011010    , run = 18, level =   1
      16'b000000011001xxxx: dct_coefficient_1_dec = {5'd13, 5'd19, 6'd01}; // codeword = 000000011001    , run = 19, level =   1
      16'b000000010111xxxx: dct_coefficient_1_dec = {5'd13, 5'd20, 6'd01}; // codeword = 000000010111    , run = 20, level =   1
      16'b000000010110xxxx: dct_coefficient_1_dec = {5'd13, 5'd21, 6'd01}; // codeword = 000000010110    , run = 21, level =   1
      16'b0000001101xxxxxx: dct_coefficient_1_dec = {5'd11, 5'd16, 6'd01}; // codeword = 0000001101      , run = 16, level =   1
      16'b0000001100xxxxxx: dct_coefficient_1_dec = {5'd11, 5'd02, 6'd04}; // codeword = 0000001100      , run =  2, level =   4
      16'b000000100xxxxxxx: dct_coefficient_1_dec = {5'd10, 5'd05, 6'd02}; // codeword = 000000100       , run =  5, level =   2
      16'b000000101xxxxxxx: dct_coefficient_1_dec = {5'd10, 5'd14, 6'd01}; // codeword = 000000101       , run = 14, level =   1
      16'b000000111xxxxxxx: dct_coefficient_1_dec = {5'd10, 5'd15, 6'd01}; // codeword = 000000111       , run = 15, level =   1
      16'b00100110xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd03, 6'd02}; // codeword = 00100110        , run =  3, level =   2
      16'b00100001xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd11, 6'd01}; // codeword = 00100001        , run = 11, level =   1
      16'b00100101xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd12, 6'd01}; // codeword = 00100101        , run = 12, level =   1
      16'b00100100xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd13, 6'd01}; // codeword = 00100100        , run = 13, level =   1
      16'b00100111xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd01, 6'd04}; // codeword = 00100111        , run =  1, level =   4
      16'b11111100xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd02, 6'd03}; // codeword = 11111100        , run =  2, level =   3
      16'b11111101xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd04, 6'd02}; // codeword = 11111101        , run =  4, level =   2
      16'b00100011xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd10}; // codeword = 00100011        , run =  0, level =  10
      16'b00100010xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd11}; // codeword = 00100010        , run =  0, level =  11
      16'b00100000xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd01, 6'd05}; // codeword = 00100000        , run =  1, level =   5
      16'b11111010xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd12}; // codeword = 11111010        , run =  0, level =  12
      16'b11111011xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd13}; // codeword = 11111011        , run =  0, level =  13
      16'b11111110xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd14}; // codeword = 11111110        , run =  0, level =  14
      16'b11111111xxxxxxxx: dct_coefficient_1_dec = {5'd09, 5'd00, 6'd15}; // codeword = 11111111        , run =  0, level =  15
      16'b0000110xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd06, 6'd01}; // codeword = 0000110         , run =  6, level =   1
      16'b0000100xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd07, 6'd01}; // codeword = 0000100         , run =  7, level =   1
      16'b0000111xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd02, 6'd02}; // codeword = 0000111         , run =  2, level =   2
      16'b0000101xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd08, 6'd01}; // codeword = 0000101         , run =  8, level =   1
      16'b1111000xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd09, 6'd01}; // codeword = 1111000         , run =  9, level =   1
      16'b1111001xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd01, 6'd03}; // codeword = 1111001         , run =  1, level =   3
      16'b1111010xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd10, 6'd01}; // codeword = 1111010         , run = 10, level =   1
      16'b1111011xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd00, 6'd08}; // codeword = 1111011         , run =  0, level =   8
      16'b1111100xxxxxxxxx: dct_coefficient_1_dec = {5'd08, 5'd00, 6'd09}; // codeword = 1111100         , run =  0, level =   9
      16'b000110xxxxxxxxxx: dct_coefficient_1_dec = {5'd07, 5'd04, 6'd01}; // codeword = 000110          , run =  4, level =   1
      16'b000111xxxxxxxxxx: dct_coefficient_1_dec = {5'd07, 5'd05, 6'd01}; // codeword = 000111          , run =  5, level =   1
      16'b000001xxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd00, 6'd00}; // codeword = 000001          , escape (no sign bit)
      16'b000101xxxxxxxxxx: dct_coefficient_1_dec = {5'd07, 5'd00, 6'd06}; // codeword = 000101          , run =  0, level =   6
      16'b000100xxxxxxxxxx: dct_coefficient_1_dec = {5'd07, 5'd00, 6'd07}; // codeword = 000100          , run =  0, level =   7
      16'b00101xxxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd02, 6'd01}; // codeword = 00101           , run =  2, level =   1
      16'b00111xxxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd03, 6'd01}; // codeword = 00111           , run =  3, level =   1
      16'b00110xxxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd01, 6'd02}; // codeword = 00110           , run =  1, level =   2
      16'b11100xxxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd00, 6'd04}; // codeword = 11100           , run =  0, level =   4
      16'b11101xxxxxxxxxxx: dct_coefficient_1_dec = {5'd06, 5'd00, 6'd05}; // codeword = 11101           , run =  0, level =   5
      16'b0110xxxxxxxxxxxx: dct_coefficient_1_dec = {5'd04, 5'd00, 6'd00}; // codeword = 0110            , end of block (no sign bit)
      16'b0111xxxxxxxxxxxx: dct_coefficient_1_dec = {5'd05, 5'd00, 6'd03}; // codeword = 0111            , run =  0, level =   3
      16'b010xxxxxxxxxxxxx: dct_coefficient_1_dec = {5'd04, 5'd01, 6'd01}; // codeword = 010             , run =  1, level =   1
      16'b110xxxxxxxxxxxxx: dct_coefficient_1_dec = {5'd04, 5'd00, 6'd02}; // codeword = 110             , run =  0, level =   2
      16'b10xxxxxxxxxxxxxx: dct_coefficient_1_dec = {5'd03, 5'd00, 6'd01}; // codeword = 10              , run =  0, level =   1
      default               dct_coefficient_1_dec = {5'd00, 5'd00, 6'd00}; // Error 
    endcase
  end
endfunction
/* not truncated */
