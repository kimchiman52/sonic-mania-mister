//============================================================================
//
//  Native Video Timing Generator (Sonic Mania) — Phase 9 dual-aspect.
//
//  Two modes selected by `aspect_169` input port:
//
//  4:3 mode (aspect_169 = 0):
//    320x240 active area @ 60.07 Hz (429x262 total).
//    CLK_VIDEO: 27.000 MHz (dedicated video PLL), CE_PIXEL: divide-by-4
//    Pixel clock: 27.000 / 4 = 6.7500 MHz
//    H: 320 active + 14 FP + 32 sync + 63 BP = 429 total
//    V: 240 active +  6 FP +  3 sync + 13 BP = 262 total
//    Frame rate: 6,750,000 / (429 * 262) = 60.07 Hz
//    H_freq:     6,750,000 / 429         = 15,734 Hz (NTSC-exact)
//
//  16:9 mode (aspect_169 = 1):
//    424x240 active area @ 60.06 Hz (545x266 total).
//    CLK_VIDEO: 34.828 MHz (= 1010/29, dedicated video PLL #2)
//    Pixel clock: 34.828 / 4 = 8.7069 MHz
//    H: 424 active + 21 FP + 32 sync + 68 BP = 545 total
//    V: 240 active +  9 FP +  3 sync + 14 BP = 266 total
//    Frame rate: 8,706,961 / (545 * 266) = 60.06 Hz
//    H_freq:     8,706,961 / 545         = 15,976 Hz
//
//  16:9 fallback (M=89/N=5/C=25 if M=101 PLL fit fails):
//    CLK_VIDEO: 35.600 MHz, pixel: 8.900 MHz.
//    H_TOTAL=555, V_TOTAL=267 (H_FP=23, H_SYNC=32, H_BP=76, V_FP=10, V_SYNC=3, V_BP=14)
//    -> 60.06 Hz / 16,036 Hz. The mode-keyed wires below would need updating;
//    document this if the fallback is taken.
//
//  Forked from 3S-ARM native_video_timing.sv (384x224 @ 59.5995 Hz).
//
//  Copyright (C) 2026 Sonic Mania MiSTer Port
//  Licensed under GNU General Public License v2+
//
//============================================================================

module native_video_timing (
    input  wire        clk,        // CLK_VIDEO (27 MHz @ 4:3 / 34.828 MHz @ 16:9); pixel rate is clk/CE
    input  wire        ce_pix,     // pixel clock enable (1-in-4 at CE_DIV=4)
    input  wire        reset,      // synchronous reset

    // Phase 9: aspect-ratio mode select.
    // 0 = 4:3 (320x240, 27 MHz / 6.75 MHz pixel)
    // 1 = 16:9 (424x240, 34.828 MHz / 8.707 MHz pixel)
    input  wire        aspect_169,

    // OSD position offsets (two's complement)
    // Positive = shift image right/down (adds to BP, subtracts from FP)
    input  wire signed [3:0] h_offset,  // -8 to +7 pixels
    input  wire signed [3:0] v_offset,  // -8 to +7 lines

    output reg         hsync,      // active high (MiSTer convention)
    output reg         vsync,      // active high (MiSTer convention)
    output reg         hblank,
    output reg         vblank,
    output reg         de,         // data enable = ~(hblank | vblank)
    output reg  [9:0]  hcount,     // 0..1023 (max H_TOTAL = 545 for 16:9)
    output reg  [8:0]  vcount,     // 0..511 (max V_TOTAL = 266 for 16:9)
    output reg         new_frame,  // single-cycle pulse at vblank start
    output reg         new_line    // single-cycle pulse at hblank start
);

// Phase 9: aspect-keyed timing constants (now wires, were localparams).
//
// Image centering notes:
// The CRT positions the image based on sync-to-active timing.
// Larger H_BP shifts image RIGHT, larger V_BP shifts image DOWN.
// Positive h_offset/v_offset = shift image right/down (adds to BP,
// subtracts from FP).  H_TOTAL and V_TOTAL are always preserved.
//
// 4:3 modeline rationale (NTSC-exact at 6.75 MHz pixel):
//   H 320 active + 14 FP + 32 sync + 63 BP = 429 total
//   V 240 active +  6 FP +  3 sync + 13 BP = 262 total
//   refresh = 6,750,000 / (429*262) = 60.07 Hz
//   H_freq  = 6,750,000 / 429       = 15,734 Hz (NTSC-exact)
//
// 16:9 modeline rationale (8.7069 MHz pixel):
//   H 424 active + 21 FP + 32 sync + 68 BP = 545 total
//   V 240 active +  9 FP +  3 sync + 14 BP = 266 total
//   refresh = 8,706,961 / (545*266) = 60.06 Hz
//   H_freq  = 8,706,961 / 545       = 15,976 Hz
//
// Verilog `wire` and `localparam` are interchangeable in expression contexts,
// so the downstream always blocks (hcount == H_TOTAL - 1 etc.) need no edit.
wire [9:0] H_ACTIVE = aspect_169 ? 10'd424 : 10'd320;
wire [9:0] H_FP     = aspect_169 ? 10'd21  : 10'd14;
wire [5:0] H_SYNC   = aspect_169 ? 6'd32   : 6'd32;
wire [9:0] H_BP     = aspect_169 ? 10'd68  : 10'd63;
wire [9:0] H_TOTAL  = aspect_169 ? 10'd545 : 10'd429;

wire [8:0] V_ACTIVE = aspect_169 ? 9'd240  : 9'd240;
wire [8:0] V_FP     = aspect_169 ? 9'd9    : 9'd6;
wire [4:0] V_SYNC   = aspect_169 ? 5'd3    : 5'd3;
wire [8:0] V_BP     = aspect_169 ? 9'd14   : 9'd13;
wire [8:0] V_TOTAL  = aspect_169 ? 9'd266  : 9'd262;

// Derived boundaries — adjusted by OSD offsets.
// Positive offset shifts image right/down: adds to BP, subtracts from FP.
// Sync pulse width and totals are invariant.
wire signed [5:0] h_off_ext = {{2{h_offset[3]}}, h_offset};  // sign-extend to 6 bits
wire signed [4:0] v_off_ext = {v_offset[3], v_offset};  // sign-extend to 5 bits

// FP shrinks and BP grows by offset (or vice versa); sync width is fixed.
// Only FP adjustment is needed to compute sync start; BP is implicit from total.
wire [9:0] h_sync_start = H_ACTIVE + (H_FP - h_off_ext);
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
wire [8:0] v_sync_start = V_ACTIVE + (V_FP - v_off_ext);
wire [8:0] v_sync_end   = v_sync_start + V_SYNC;

always @(posedge clk) begin
    if (reset) begin
        hcount    <= 10'd0;
        vcount    <= 9'd0;
        hsync     <= 1'b0;  // inactive (active high)
        vsync     <= 1'b0;  // inactive (active high)
        hblank    <= 1'b0;
        vblank    <= 1'b0;
        de        <= 1'b1;  // first pixel is visible
        new_frame <= 1'b0;
        new_line  <= 1'b0;
    end
    else if (ce_pix) begin
        // Default: clear single-cycle pulses
        new_frame <= 1'b0;
        new_line  <= 1'b0;

        // Horizontal counter
        if (hcount == H_TOTAL - 1) begin
            hcount <= 10'd0;

            // Vertical counter (advances at end of each line)
            if (vcount == V_TOTAL - 1)
                vcount <= 9'd0;
            else
                vcount <= vcount + 9'd1;
        end
        else begin
            hcount <= hcount + 10'd1;
        end

        // --- Horizontal blanking ---
        // hblank asserts when hcount reaches H_ACTIVE (entering front porch)
        // hblank deasserts when hcount wraps to 0 (entering active)
        if (hcount == H_ACTIVE - 1)
            hblank <= 1'b1;
        else if (hcount == H_TOTAL - 1)
            hblank <= 1'b0;

        // --- Horizontal sync (active high) ---
        if (hcount == h_sync_start - 1)
            hsync <= 1'b1;  // assert
        else if (hcount == h_sync_end - 1)
            hsync <= 1'b0;  // deassert

        // --- Vertical blanking ---
        // Transitions at the start of a new line (when hcount wraps)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == V_ACTIVE - 1)
                vblank <= 1'b1;
            else if (vcount == V_TOTAL - 1)
                vblank <= 1'b0;
        end

        // --- Vertical sync (active high) ---
        if (hcount == H_TOTAL - 1) begin
            if (vcount == v_sync_start - 1)
                vsync <= 1'b1;  // assert
            else if (vcount == v_sync_end - 1)
                vsync <= 1'b0;  // deassert
        end

        // --- New line pulse ---
        // Fires when entering horizontal blanking
        if (hcount == H_ACTIVE - 1)
            new_line <= 1'b1;

        // --- New frame pulse ---
        // Fires at start of vblank
        if (hcount == H_TOTAL - 1 && vcount == V_ACTIVE - 1)
            new_frame <= 1'b1;

        // --- Data enable ---
        // Registered output: active when next pixel will be in visible region.
        // We compute based on what hblank/vblank will be next cycle.
        // Simplest: derive from the blanking signals we just computed.
        // Since hblank and vblank are updated in this same cycle, de follows
        // them with one cycle latency. To keep all signals aligned, compute
        // de from the same conditions:
        begin
            reg next_hblank, next_vblank;

            // Will hblank be set next cycle?
            if (hcount == H_ACTIVE - 1)
                next_hblank = 1'b1;
            else if (hcount == H_TOTAL - 1)
                next_hblank = 1'b0;
            else
                next_hblank = hblank;

            // Will vblank be set next cycle?
            if (hcount == H_TOTAL - 1) begin
                if (vcount == V_ACTIVE - 1)
                    next_vblank = 1'b1;
                else if (vcount == V_TOTAL - 1)
                    next_vblank = 1'b0;
                else
                    next_vblank = vblank;
            end
            else
                next_vblank = vblank;

            de <= ~next_hblank & ~next_vblank;
        end
    end
end

endmodule
