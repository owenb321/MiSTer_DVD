/* 
 * zigzag_table.v
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
 * zigzag_table - different zig-zag scanning orders.
 */
     
  function [5:0]scan_forward;
    input      alternate_scan;
    input [5:0]u_v;
    begin
      if (alternate_scan) 
        /*
         * zig-zag scanning order 1. par. 7.3 
         */
        casex(u_v)
          6'd00: scan_forward = 6'd0;
          6'd01: scan_forward = 6'd4;
          6'd02: scan_forward = 6'd6;
          6'd03: scan_forward = 6'd20;
          6'd04: scan_forward = 6'd22;
          6'd05: scan_forward = 6'd36;
          6'd06: scan_forward = 6'd38;
          6'd07: scan_forward = 6'd52;
          6'd08: scan_forward = 6'd1;
          6'd09: scan_forward = 6'd5;
          6'd10: scan_forward = 6'd7;
          6'd11: scan_forward = 6'd21;
          6'd12: scan_forward = 6'd23;
          6'd13: scan_forward = 6'd37;
          6'd14: scan_forward = 6'd39;
          6'd15: scan_forward = 6'd53;
          6'd16: scan_forward = 6'd2;
          6'd17: scan_forward = 6'd8;
          6'd18: scan_forward = 6'd19;
          6'd19: scan_forward = 6'd24;
          6'd20: scan_forward = 6'd34;
          6'd21: scan_forward = 6'd40;
          6'd22: scan_forward = 6'd50;
          6'd23: scan_forward = 6'd54;
          6'd24: scan_forward = 6'd3;
          6'd25: scan_forward = 6'd9;
          6'd26: scan_forward = 6'd18;
          6'd27: scan_forward = 6'd25;
          6'd28: scan_forward = 6'd35;
          6'd29: scan_forward = 6'd41;
          6'd30: scan_forward = 6'd51;
          6'd31: scan_forward = 6'd55;
          6'd32: scan_forward = 6'd10;
          6'd33: scan_forward = 6'd17;
          6'd34: scan_forward = 6'd26;
          6'd35: scan_forward = 6'd30;
          6'd36: scan_forward = 6'd42;
          6'd37: scan_forward = 6'd46;
          6'd38: scan_forward = 6'd56;
          6'd39: scan_forward = 6'd60;
          6'd40: scan_forward = 6'd11;
          6'd41: scan_forward = 6'd16;
          6'd42: scan_forward = 6'd27;
          6'd43: scan_forward = 6'd31;
          6'd44: scan_forward = 6'd43;
          6'd45: scan_forward = 6'd47;
          6'd46: scan_forward = 6'd57;
          6'd47: scan_forward = 6'd61;
          6'd48: scan_forward = 6'd12;
          6'd49: scan_forward = 6'd15;
          6'd50: scan_forward = 6'd28;
          6'd51: scan_forward = 6'd32;
          6'd52: scan_forward = 6'd44;
          6'd53: scan_forward = 6'd48;
          6'd54: scan_forward = 6'd58;
          6'd55: scan_forward = 6'd62;
          6'd56: scan_forward = 6'd13;
          6'd57: scan_forward = 6'd14;
          6'd58: scan_forward = 6'd29;
          6'd59: scan_forward = 6'd33;
          6'd60: scan_forward = 6'd45;
          6'd61: scan_forward = 6'd49;
          6'd62: scan_forward = 6'd59;
          6'd63: scan_forward = 6'd63;
        endcase
      else
        /*
         * zig-zag scanning order 0. par. 7.3 
         */
        casex(u_v)
          6'd0: scan_forward = 6'd0;
          6'd1: scan_forward = 6'd1;
          6'd2: scan_forward = 6'd5;
          6'd3: scan_forward = 6'd6;
          6'd4: scan_forward = 6'd14;
          6'd5: scan_forward = 6'd15;
          6'd6: scan_forward = 6'd27;
          6'd7: scan_forward = 6'd28;
          6'd8: scan_forward = 6'd2;
          6'd9: scan_forward = 6'd4;
          6'd10: scan_forward = 6'd7;
          6'd11: scan_forward = 6'd13;
          6'd12: scan_forward = 6'd16;
          6'd13: scan_forward = 6'd26;
          6'd14: scan_forward = 6'd29;
          6'd15: scan_forward = 6'd42;
          6'd16: scan_forward = 6'd3;
          6'd17: scan_forward = 6'd8;
          6'd18: scan_forward = 6'd12;
          6'd19: scan_forward = 6'd17;
          6'd20: scan_forward = 6'd25;
          6'd21: scan_forward = 6'd30;
          6'd22: scan_forward = 6'd41;
          6'd23: scan_forward = 6'd43;
          6'd24: scan_forward = 6'd9;
          6'd25: scan_forward = 6'd11;
          6'd26: scan_forward = 6'd18;
          6'd27: scan_forward = 6'd24;
          6'd28: scan_forward = 6'd31;
          6'd29: scan_forward = 6'd40;
          6'd30: scan_forward = 6'd44;
          6'd31: scan_forward = 6'd53;
          6'd32: scan_forward = 6'd10;
          6'd33: scan_forward = 6'd19;
          6'd34: scan_forward = 6'd23;
          6'd35: scan_forward = 6'd32;
          6'd36: scan_forward = 6'd39;
          6'd37: scan_forward = 6'd45;
          6'd38: scan_forward = 6'd52;
          6'd39: scan_forward = 6'd54;
          6'd40: scan_forward = 6'd20;
          6'd41: scan_forward = 6'd22;
          6'd42: scan_forward = 6'd33;
          6'd43: scan_forward = 6'd38;
          6'd44: scan_forward = 6'd46;
          6'd45: scan_forward = 6'd51;
          6'd46: scan_forward = 6'd55;
          6'd47: scan_forward = 6'd60;
          6'd48: scan_forward = 6'd21;
          6'd49: scan_forward = 6'd34;
          6'd50: scan_forward = 6'd37;
          6'd51: scan_forward = 6'd47;
          6'd52: scan_forward = 6'd50;
          6'd53: scan_forward = 6'd56;
          6'd54: scan_forward = 6'd59;
          6'd55: scan_forward = 6'd61;
          6'd56: scan_forward = 6'd35;
          6'd57: scan_forward = 6'd36;
          6'd58: scan_forward = 6'd48;
          6'd59: scan_forward = 6'd49;
          6'd60: scan_forward = 6'd57;
          6'd61: scan_forward = 6'd58;
          6'd62: scan_forward = 6'd62;
          6'd63: scan_forward = 6'd63;
        endcase
    end
  endfunction
    
       
  function [5:0]scan_reverse;
    input      alternate_scan;
    input [5:0]u_v;
    begin
      if (alternate_scan)
        /*
         * inverse zig-zag scanning order 1. par. 7.3 
         */
        casex(u_v)
          6'd00: scan_reverse = 6'd0;
          6'd04: scan_reverse = 6'd1;
          6'd06: scan_reverse = 6'd2;
          6'd20: scan_reverse = 6'd3;
          6'd22: scan_reverse = 6'd4;
          6'd36: scan_reverse = 6'd5;
          6'd38: scan_reverse = 6'd6;
          6'd52: scan_reverse = 6'd7;
          6'd01: scan_reverse = 6'd8;
          6'd05: scan_reverse = 6'd9;
          6'd07: scan_reverse = 6'd10;
          6'd21: scan_reverse = 6'd11;
          6'd23: scan_reverse = 6'd12;
          6'd37: scan_reverse = 6'd13;
          6'd39: scan_reverse = 6'd14;
          6'd53: scan_reverse = 6'd15;
          6'd02: scan_reverse = 6'd16;
          6'd08: scan_reverse = 6'd17;
          6'd19: scan_reverse = 6'd18;
          6'd24: scan_reverse = 6'd19;
          6'd34: scan_reverse = 6'd20;
          6'd40: scan_reverse = 6'd21;
          6'd50: scan_reverse = 6'd22;
          6'd54: scan_reverse = 6'd23;
          6'd03: scan_reverse = 6'd24;
          6'd09: scan_reverse = 6'd25;
          6'd18: scan_reverse = 6'd26;
          6'd25: scan_reverse = 6'd27;
          6'd35: scan_reverse = 6'd28;
          6'd41: scan_reverse = 6'd29;
          6'd51: scan_reverse = 6'd30;
          6'd55: scan_reverse = 6'd31;
          6'd10: scan_reverse = 6'd32;
          6'd17: scan_reverse = 6'd33;
          6'd26: scan_reverse = 6'd34;
          6'd30: scan_reverse = 6'd35;
          6'd42: scan_reverse = 6'd36;
          6'd46: scan_reverse = 6'd37;
          6'd56: scan_reverse = 6'd38;
          6'd60: scan_reverse = 6'd39;
          6'd11: scan_reverse = 6'd40;
          6'd16: scan_reverse = 6'd41;
          6'd27: scan_reverse = 6'd42;
          6'd31: scan_reverse = 6'd43;
          6'd43: scan_reverse = 6'd44;
          6'd47: scan_reverse = 6'd45;
          6'd57: scan_reverse = 6'd46;
          6'd61: scan_reverse = 6'd47;
          6'd12: scan_reverse = 6'd48;
          6'd15: scan_reverse = 6'd49;
          6'd28: scan_reverse = 6'd50;
          6'd32: scan_reverse = 6'd51;
          6'd44: scan_reverse = 6'd52;
          6'd48: scan_reverse = 6'd53;
          6'd58: scan_reverse = 6'd54;
          6'd62: scan_reverse = 6'd55;
          6'd13: scan_reverse = 6'd56;
          6'd14: scan_reverse = 6'd57;
          6'd29: scan_reverse = 6'd58;
          6'd33: scan_reverse = 6'd59;
          6'd45: scan_reverse = 6'd60;
          6'd49: scan_reverse = 6'd61;
          6'd59: scan_reverse = 6'd62;
          6'd63: scan_reverse = 6'd63;
        endcase
      else
        /*
         * inverse zig-zag scanning order 0. par. 7.3 
         */
        casex(u_v)
          6'd00: scan_reverse = 6'd0;
          6'd01: scan_reverse = 6'd1;
          6'd05: scan_reverse = 6'd2;
          6'd06: scan_reverse = 6'd3;
          6'd14: scan_reverse = 6'd4;
          6'd15: scan_reverse = 6'd5;
          6'd27: scan_reverse = 6'd6;
          6'd28: scan_reverse = 6'd7;
          6'd02: scan_reverse = 6'd8;
          6'd04: scan_reverse = 6'd9;
          6'd07: scan_reverse = 6'd10;
          6'd13: scan_reverse = 6'd11;
          6'd16: scan_reverse = 6'd12;
          6'd26: scan_reverse = 6'd13;
          6'd29: scan_reverse = 6'd14;
          6'd42: scan_reverse = 6'd15;
          6'd03: scan_reverse = 6'd16;
          6'd08: scan_reverse = 6'd17;
          6'd12: scan_reverse = 6'd18;
          6'd17: scan_reverse = 6'd19;
          6'd25: scan_reverse = 6'd20;
          6'd30: scan_reverse = 6'd21;
          6'd41: scan_reverse = 6'd22;
          6'd43: scan_reverse = 6'd23;
          6'd09: scan_reverse = 6'd24;
          6'd11: scan_reverse = 6'd25;
          6'd18: scan_reverse = 6'd26;
          6'd24: scan_reverse = 6'd27;
          6'd31: scan_reverse = 6'd28;
          6'd40: scan_reverse = 6'd29;
          6'd44: scan_reverse = 6'd30;
          6'd53: scan_reverse = 6'd31;
          6'd10: scan_reverse = 6'd32;
          6'd19: scan_reverse = 6'd33;
          6'd23: scan_reverse = 6'd34;
          6'd32: scan_reverse = 6'd35;
          6'd39: scan_reverse = 6'd36;
          6'd45: scan_reverse = 6'd37;
          6'd52: scan_reverse = 6'd38;
          6'd54: scan_reverse = 6'd39;
          6'd20: scan_reverse = 6'd40;
          6'd22: scan_reverse = 6'd41;
          6'd33: scan_reverse = 6'd42;
          6'd38: scan_reverse = 6'd43;
          6'd46: scan_reverse = 6'd44;
          6'd51: scan_reverse = 6'd45;
          6'd55: scan_reverse = 6'd46;
          6'd60: scan_reverse = 6'd47;
          6'd21: scan_reverse = 6'd48;
          6'd34: scan_reverse = 6'd49;
          6'd37: scan_reverse = 6'd50;
          6'd47: scan_reverse = 6'd51;
          6'd50: scan_reverse = 6'd52;
          6'd56: scan_reverse = 6'd53;
          6'd59: scan_reverse = 6'd54;
          6'd61: scan_reverse = 6'd55;
          6'd35: scan_reverse = 6'd56;
          6'd36: scan_reverse = 6'd57;
          6'd48: scan_reverse = 6'd58;
          6'd49: scan_reverse = 6'd59;
          6'd57: scan_reverse = 6'd60;
          6'd58: scan_reverse = 6'd61;
          6'd62: scan_reverse = 6'd62;
          6'd63: scan_reverse = 6'd63;
        endcase
    end
  endfunction
/* not truncated */    
