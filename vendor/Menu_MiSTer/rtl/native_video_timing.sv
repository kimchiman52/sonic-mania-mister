//============================================================================
//
//  Native Video Timing Generator (Sonic Mania)
//
//  320x240 active area @ ~59.587 Hz (391x264 total)
//  CLK_VIDEO: 24.6032 MHz (dedicated video PLL), CE_PIXEL: divide-by-4
//
//  PLL: 50 MHz * 62/3 = 1033.33 MHz VCO, /42 = 24.6032 MHz CLK_VIDEO
//  Pixel clock: 24.6032 / 4 (CE_PIXEL) = 6.1508 MHz
//
//  H: 320 active + 14 FP + 32 sync + 25 BP = 391 total
//  V: 240 active +  6 FP +  3 sync + 15 BP = 264 total
//
//  Frame rate: 6,150,794 / (391 * 264) = 59.587 Hz
//  H_freq: 6,150,794 / 391 = 15,731 Hz (NTSC target 15,734 Hz; ~200 ppm low,
//          within CRT tolerance)
//
//  Refresh-rate vs. Sonic Mania RSDKv5 engine:
//    FPGA:    59.587 Hz
//    Engine:  59.587 Hz (TARGET_FPS -- userland pacer matches FPGA)
//    Delta:   0 Hz (engine adapts via Linux-userland TARGET_FPS constant)
//
//  Forked from 3S-ARM native_video_timing.sv (384x224 @ 59.5995 Hz).
//
//  Copyright (C) 2026 Sonic Mania MiSTer Port
//  Licensed under GNU General Public License v2+
//
//============================================================================

module native_video_timing (
    input  wire        clk,        // CLK_VIDEO (~24.60 MHz); pixel rate is clk/CE
    input  wire        ce_pix,     // pixel clock enable (1-in-4 at CE_DIV=4)
    input  wire        reset,      // synchronous reset

    // OSD position offsets (two's complement)
    // Positive = shift image right/down (adds to BP, subtracts from FP)
    input  wire signed [3:0] h_offset,  // -8 to +7 pixels
    input  wire signed [3:0] v_offset,  // -8 to +7 lines

    output reg         hsync,      // active high (MiSTer convention)
    output reg         vsync,      // active high (MiSTer convention)
    output reg         hblank,
    output reg         vblank,
    output reg         de,         // data enable = ~(hblank | vblank)
    output reg  [9:0]  hcount,     // 0..511
    output reg  [8:0]  vcount,     // 0..263
    output reg         new_frame,  // single-cycle pulse at vblank start
    output reg         new_line    // single-cycle pulse at hblank start
);

// Timing constants
//
// Image centering notes:
// The CRT positions the image based on sync-to-active timing.
// Larger H_BP shifts image RIGHT, larger V_BP shifts image DOWN.
// Positive h_offset/v_offset = shift image right/down (adds to BP,
// subtracts from FP).  H_TOTAL and V_TOTAL are always preserved.
//
// Sonic Mania modeline rationale (see docs/phase-4-plan.md §2-3):
//   H blanking budget: 71 pixels (H_FP=14, H_SYNC=32, H_BP=25) targeting the
//   NTSC-exact H-freq of 15,734 Hz. H_SYNC held at a full 5.2 us; H_FP slightly
//   tighter than 3sx to keep H_BP >= 4us (standard NTSC back porch).
//   V blanking budget: 24 lines (V_FP=6, V_SYNC=3, V_BP=15). V_SYNC held at 3
//   lines (NTSC canonical). BP > FP by convention (sync sits below active).
//
// H_TOTAL=391, V_TOTAL=264: with dedicated video PLL (CLK_VIDEO=24.6032 MHz, CE_DIV=4):
// pixel_clock = 6.1508 MHz, H_freq = 15,731 Hz (~200 ppm below NTSC),
// refresh = 59.587 Hz (engine TARGET_FPS matches this exactly).
localparam H_ACTIVE = 320;
localparam H_FP     = 14;
localparam H_SYNC   = 32;
localparam H_BP     = 25;
localparam H_TOTAL  = 391;   // 320+14+32+25

localparam V_ACTIVE = 240;
localparam V_FP     = 6;
localparam V_SYNC   = 3;
localparam V_BP     = 15;
localparam V_TOTAL  = 264;   // 240+6+3+15

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
