
module sys_pll (
	input  refclk,
	input  rst,
	output outclk_0, // 27 MHz (System)
	output outclk_1, // 100+ MHz (Memory)
	output outclk_2, // Video Clock (e.g. 25.175 MHz)
	output locked
);

	// This is a placeholder for the actual Altera PLL IP.
	// In a real MiSTer build, you would generate an ALTPLL 
	// or use the Qsys/Platform Designer to create this component.
	// For simulation/linting, we can assign simple clocks.
	
	// Default simulation behavior:
	assign outclk_0 = refclk; // Should be ~27M
	assign outclk_1 = refclk; // Should be ~100M+
	assign outclk_2 = refclk; // Should be ~25M
	assign locked = 1'b1;

endmodule
