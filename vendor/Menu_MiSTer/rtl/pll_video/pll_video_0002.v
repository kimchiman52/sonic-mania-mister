// Sonic Mania pll_video instance — 4:3 NTSC-exact mode.
//
// Phase 10b retarget: CLK_VIDEO = 25.600000 MHz. Pixel clock at DAC =
// CLK_VIDEO / 4 = 6.400000 MHz. Slowed from Phase 9c's 6.75 MHz to widen the
// active region as a fraction of each line on the CRT — 320 active pixels
// span 78.6% of the line at 6.4 MHz (was 74.6% at 6.75 MHz). Paired with
// native_video_timing.sv 4:3 H_TOTAL=407 keeps H-freq at 15,725 Hz (within
// NTSC tolerance of 15,734 Hz). V_TOTAL stays at 262 → refresh = 60.05 Hz.
// Image is wider on a typical 4:3 CRT, more closely matching Genesis 5.37
// MHz convention without going all the way (which would degrade
// YC-subcarrier math).
//
// Expected fit: M=64, N=5, C=25 (VCO 640 MHz, /25 = 25.600 MHz exact).
// Verify in fitter log post-compile.
//
// The `operation_mode("direct")` string below is inherited verbatim from the
// 3S-ARM shipping config. It is a cosmetic no-op when altera_pll is driven by
// an explicit `output_clock_frequency0` string -- Quartus's fitter picks the
// best M/N/C rational fraction regardless of the "direct" label. Do NOT
// hand-change this field; let Quartus regenerate it via the MegaWizard if a
// cleaner IP is desired.
//
// Integer-N discipline: `fractional_vco_multiplier("false")` prevents
// delta-sigma jitter on the pixel clock (see reference-native-analog-video.md
// §4 "Why Not Fractional-N PLL"). Keep false.
//
// Phase history: 3S-ARM was 31.153846 MHz; Sonic Mania Phase 4 was
// 24.603175 MHz (M=62/N=3/C=42, 50*62/3/42); Phase 9 is 27.000000 MHz exact.
`timescale 1ns/10ps
module  pll_video_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		// Phase 10b: 25.600 MHz (M=64/N=5/C=25, VCO 640 MHz). Verify M/N/C in fitter log.
		.output_clock_frequency0("25.600000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
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
		.rst	(rst),
		.outclk	({outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
