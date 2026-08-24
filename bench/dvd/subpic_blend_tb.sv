// =============================================================================
// bench/dvd/subpic_blend_tb.sv — reusable alpha compositor
// =============================================================================
// Phase-1 update: subpic_blend no longer holds a fixed white/black palette. The
// caller now supplies the resolved overlay colour (ov_r/g/b) — for DVD it is the
// SET_COLOR index looked up in pgc_palette. This TB drives an explicit overlay
// colour and checks the per-channel alpha blend against a software reference:
//   * ov_on=0        -> passthrough
//   * ov_idx=0       -> transparent (passthrough)  [idx0 is the subpicture key]
//   * ov_alpha=0     -> transparent (passthrough)
//   * ov_alpha=15    -> fully opaque (out = ov colour exactly)
//   * partial alpha  -> per-channel linear interp
// =============================================================================
`timescale 1ns/1ps
module subpic_blend_tb;
    logic [7:0] in_r, in_g, in_b;
    logic       ov_on;
    logic [1:0] ov_idx;
    logic [7:0] ov_r, ov_g, ov_b;
    logic [3:0] ov_alpha;
    logic       ov_force;
    wire [7:0]  out_r, out_g, out_b;

    subpic_blend dut (
        .in_r(in_r), .in_g(in_g), .in_b(in_b),
        .ov_on(ov_on), .ov_idx(ov_idx),
        .ov_r(ov_r), .ov_g(ov_g), .ov_b(ov_b),
        .ov_alpha(ov_alpha),
        .ov_force(ov_force),
        .out_r(out_r), .out_g(out_g), .out_b(out_b)
    );

    // software reference (per-channel)
    function automatic [7:0] ref_mix(input [7:0] vin, input [7:0] c, input [3:0] a);
        int w; int acc;
        begin
            w   = (a == 4'hF) ? 16 : a;
            acc = int'(c) * w + int'(vin) * (16 - w);
            ref_mix = (acc >> 4) & 8'hFF;
        end
    endfunction
    // ov_force high (menu highlight): blend on alpha alone, idx0 is NOT keyed out.
    function automatic [7:0] ref_out(input [7:0] vin, input [7:0] c,
                                     input on, input [1:0] idx, input [3:0] a, input frc);
        begin
            if (!on || a == 4'd0 || (!frc && idx == 2'd0)) ref_out = vin;
            else ref_out = ref_mix(vin, c, a);
        end
    endfunction

    int errors = 0;
    task automatic chk(input [7:0] r, g, b, input [7:0] cr, cg, cb,
                       input on, input [1:0] idx, input [3:0] a, input frc);
        logic [7:0] er, eg, eb;
        begin
            in_r=r; in_g=g; in_b=b; ov_r=cr; ov_g=cg; ov_b=cb;
            ov_on=on; ov_idx=idx; ov_alpha=a; ov_force=frc;
            #1;
            er = ref_out(r,cr,on,idx,a,frc); eg = ref_out(g,cg,on,idx,a,frc); eb = ref_out(b,cb,on,idx,a,frc);
            if (out_r!==er || out_g!==eg || out_b!==eb) begin
                $display("  FAIL in=%02h,%02h,%02h col=%02h,%02h,%02h on=%0d idx=%0d a=%0d frc=%0d -> got %02h,%02h,%02h exp %02h,%02h,%02h",
                         r,g,b,cr,cg,cb,on,idx,a,frc, out_r,out_g,out_b, er,eg,eb);
                errors++;
            end
        end
    endtask

    initial begin
        $display("=== subpic_blend test ===");
        // passthrough cases (overlay colour present but suppressed), ov_force=0
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b0, 2'd1, 4'hF, 1'b0);   // ov_on=0
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b1, 2'd0, 4'hF, 1'b0);   // idx0 transparent
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b1, 2'd1, 4'h0, 1'b0);   // alpha0 transparent
        // HIGHLIGHT FILL: idx0 with ov_force lights up (background-class button fill)
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b1, 2'd0, 4'hF, 1'b1);   // idx0 forced -> ov colour
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b1, 2'd0, 4'h8, 1'b1);   // idx0 forced partial
        chk(8'h40,8'h80,8'hC0, 8'hFF,8'h10,8'h20, 1'b1, 2'd0, 4'h0, 1'b1);   // idx0 forced but alpha0 -> passthrough
        // opaque -> out = overlay colour exactly (per channel)
        in_r=8'h33;in_g=8'h44;in_b=8'h55; ov_r=8'hAA;ov_g=8'hBB;ov_b=8'hCC;
        ov_on=1;ov_idx=1;ov_alpha=4'hF;ov_force=0; #1;
        if (out_r!==8'hAA || out_g!==8'hBB || out_b!==8'hCC) begin
            $display("  FAIL opaque colour got %02h,%02h,%02h",out_r,out_g,out_b); errors++; end
        // sweep partial alphas / indices / video levels / colours / force vs reference
        for (int frc=0;frc<2;frc++)
          for (int a=0;a<16;a++)
            for (int idx=0;idx<4;idx++)
              for (int v=0;v<256;v+=17)
                chk(v[7:0], (v+40)&8'hFF, (v+120)&8'hFF,
                    (255-v)&8'hFF, (v*2)&8'hFF, (v+90)&8'hFF,
                    1'b1, idx[1:0], a[3:0], frc[0]);

        if (errors == 0) $display("RESULT: PASS (blend matches reference)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
