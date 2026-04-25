// Sonic Mania pll_video_169 instance — 16:9 widescreen mode.
//
// Phase 9 target: CLK_VIDEO = 1010/29 MHz = 34.827586 MHz exact rational.
// Pixel clock at DAC = CLK_VIDEO / 4 = 8.706897 MHz. Paired with
// native_video_timing.sv 16:9 H_TOTAL=545, V_TOTAL=266 yields refresh =
// 60.06 Hz, H-freq = 15,976 Hz.
//
// Expected fit: M=101, N=5, C=29 (VCO 1010 MHz, /29 = 34.827586 MHz).
// Verify in fitter log post-compile.
//
// FALLBACK (auto-trigger if M=101 fit fails per phase-9-plan.md §1
// "Failure mode + recovery"):
//   .output_clock_frequency0("35.600000 MHz")  -- M=89/N=5/C=25, VCO 890 MHz.
//   Then: H_TOTAL=555, V_TOTAL=267, H_FP=23, H_BP=76, V_FP=10, V_BP=14 in
//   native_video_timing.sv; video.cpp ternary literal becomes 1780.0/50.0.
//
// The `operation_mode("direct")` string below mirrors pll_video_0002.v. It is
// a cosmetic no-op when altera_pll is driven by an explicit
// `output_clock_frequency0` string. Quartus's fitter picks the best M/N/C
// rational fraction.
//
// Integer-N discipline: `fractional_vco_multiplier("false")` prevents
// delta-sigma jitter on the pixel clock. Keep false.
`timescale 1ns/10ps
module  pll_video_169_0002(

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
		// Phase 9: 34.827586 MHz (1010/29, M=101/N=5/C=29, VCO 1010 MHz).
		// If fitter rejects M=101, change to "35.600000 MHz" (M=89/N=5/C=25)
		// per fallback path documented above.
		.output_clock_frequency0("34.827586 MHz"),
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
