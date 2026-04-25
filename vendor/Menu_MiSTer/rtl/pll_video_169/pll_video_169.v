// megafunction wizard: %Altera PLL v17.0%
// GENERATION: XML
// pll_video_169.v
//
// Phase 9: 16:9 widescreen video PLL wrapper.
// Mirrors pll_video.v but instantiates the 16:9 core (pll_video_169_0002).

`timescale 1 ps / 1 ps
module pll_video_169 (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  locked    //  locked.export
	);

	pll_video_169_0002 pll_video_169_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.locked   (locked)    //  locked.export
	);

endmodule
