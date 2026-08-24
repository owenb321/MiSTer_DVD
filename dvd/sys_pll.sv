// PLL for MiSTer MPEG2/DVD core  (dvd/ copy — rtl/ original left untouched)
// Input:  50 MHz (FPGA_CLK2_50 via sys_top)
// Output: 27 MHz (MPEG2 system clock)
//         108 MHz (clk_mem — f2sdram burst bridge + decoder mem_clk)
//         25.175 MHz (VGA 640x480 pixel clock)
//
// *** clk_mem = 90 MHz (f2sdram burst-bridge ceiling on this board) ***
// History: clk_mem was 108 (core native), dropped to 90 for the SDRAM add-on
// board's read-eye margin. The memory path is now HPS f2sdram via the burst bridge
// (dvd/mem_shim_burst.sv). We TRIED restoring 108 (DDR3 has no read-eye problem) to
// buy ~20% bandwidth, but the O4 burst BIST returned 0000/0000/0000/E000 on hardware
// (2026-06-22): wedged in the WRITE phase with ZERO writes accepted — f2sdram's
// waitrequest never drops at 108. f2sdram on this board tops out below 108 (single
// reads only returned at 27, bursts at 90). So 90 is the proven ceiling; bandwidth
// gains must come from the bridge structure (larger LINEW / fewer cycles-per-word),
// not the clock — see docs/history.md. Video unaffected (outclk_0 = 27).
//
// Uses Altera/Intel altera_pll for Cyclone V
// Parameterization matches Quartus IP-generated pattern from pll_0002.v

`timescale 1ns/10ps
module sys_pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0, // 27 MHz
	output wire outclk_1, // 90 MHz — clk_mem (burst bridge + decoder mem_clk)
	output wire outclk_2, // ~25.175 MHz
	output wire outclk_3, // 81 MHz (VCO 810 / 10) — decoder COMPUTE clock (mpeg2video.clk).
	                      // The decode domain closes ~81 MHz with little margin, so a bad
	                      // placement over-clocks it -> intermittent green chroma fringe.
	                      // Protections (docs/history.md §7-10): targeted retimes
	                      // (framestore_request PR #58, disp_vscale PR #92), the per-build
	                      // Fmax gate (tools/fmax_check.sh, wired into build_release.sh),
	                      // and the sys_top.sdc clock-groups fix (2026-08-01) so the fitter
	                      // times only real paths. (Physical synthesis, the original
	                      // 2026-07-01 fix, is OFF since 2026-07-01 for routability.)
	                      // Do NOT lower this clock (54=stutter; 73-77=won't route).
	output wire locked
);

`ifdef QUARTUS

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("27.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("90.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("25.116279 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("81.000000 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);

`else
	// Simulation / non-Quartus: pass-through
	assign outclk_0 = refclk;
	assign outclk_1 = refclk;
	assign outclk_2 = refclk;
	assign outclk_3 = refclk;
	assign locked   = 1'b1;
`endif

endmodule
