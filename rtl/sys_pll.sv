// PLL for MiSTer MPEG2 core
// Input:  50 MHz (FPGA_CLK2_50 via sys_top)
// Output: 27 MHz (MPEG2 system clock)
//         108 MHz (SDRAM controller clock)
//         25.175 MHz (VGA 640x480 pixel clock)
//
// Uses Altera/Intel altera_pll for Cyclone V
// Parameterization matches Quartus IP-generated pattern from pll_0002.v

`timescale 1ns/10ps
module sys_pll (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0, // 27 MHz
	output wire outclk_1, // 108 MHz
	output wire outclk_2, // ~25.175 MHz
	output wire locked
);

`ifdef QUARTUS

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("27.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("108.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("25.116279 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
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
		.outclk   ({outclk_2, outclk_1, outclk_0}),
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
	assign locked   = 1'b1;
`endif

endmodule
