//============================================================================
//
//  Native Video Timing Generator (Sonic Mania) — Phase 9 scope cut (4:3 only).
//
//  4:3 mode:
//    320x240 active area @ 60.07 Hz (429x262 total).
//    CLK_VIDEO: 27.000 MHz (dedicated video PLL), CE_PIXEL: divide-by-4
//    Pixel clock: 27.000 / 4 = 6.7500 MHz
//    H: 320 active + 14 FP + 32 sync + 63 BP = 429 total
//    V: 240 active +  6 FP +  3 sync + 13 BP = 262 total
//    Frame rate: 6,750,000 / (429 * 262) = 60.07 Hz
//    H_freq:     6,750,000 / 429         = 15,734 Hz (NTSC-exact)
//
//  16:9 widescreen support is deferred to Phase 10 (requires altpll_reconfig
//  for runtime PLL coefficient reconfiguration).
//
//  Forked from 3S-ARM native_video_timing.sv (384x224 @ 59.5995 Hz).
//
//  Copyright (C) 2026 Sonic Mania MiSTer Port
//  Licensed under GNU General Public License v2+
//
//============================================================================

module native_video_timing (
    input  wire        clk,        // CLK_VIDEO (27 MHz); pixel rate is clk/CE
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
    output reg  [9:0]  hcount,     // 0..1023 (max H_TOTAL = 429 for 4:3)
    output reg  [8:0]  vcount,     // 0..511 (max V_TOTAL = 262 for 4:3)
    output reg         new_frame,  // single-cycle pulse at vblank start
    output reg         new_line    // single-cycle pulse at hblank start
);

// Phase 9 scope cut: 4:3-only timing constants (NTSC-exact at 6.75 MHz pixel).
//
// Image centering notes:
// The CRT positions the image based on sync-to-active timing.
// Larger H_BP shifts image RIGHT, larger V_BP shifts image DOWN.
// Positive h_offset/v_offset = shift image right/down (adds to BP,
// subtracts from FP).  H_TOTAL and V_TOTAL are always preserved.
//
// 4:3 modeline rationale:
//   H 320 active + 26 FP + 32 sync + 51 BP = 429 total
//   V 224 active + 10 FP +  3 sync + 25 BP = 262 total
//   refresh = 6,750,000 / (429*262) = 60.07 Hz
//   H_freq  = 6,750,000 / 429       = 15,734 Hz (NTSC-exact)
//
// Phase 10b retune: V_ACTIVE 240 → 224 to match standard NTSC 240p console
// convention (Genesis/SNES). Engine now compiles with -DSCREEN_YSIZE=224 so
// the rendered frame is 320×224. CRT shows the same vertical extent as
// other retro cores. V_FP+V_BP grew from 19 to 35 lines to keep V_TOTAL
// pinned at 262 (V-freq 60.05 Hz NTSC-locked).
//
// Porch envelope (for tuning):
//   H_FP+H_BP must equal 77 (H_TOTAL-H_ACTIVE-H_SYNC); larger H_BP shifts
//   image right. Practical range: H_FP 5–50, H_BP 27–72.
//   V_FP+V_BP must equal 35 (V_TOTAL-V_ACTIVE-V_SYNC); larger V_BP shifts
//   image down. Practical range: V_FP 3–25, V_BP 10–32.
localparam [9:0] H_ACTIVE = 10'd320;
localparam [9:0] H_FP     = 10'd26;
localparam [5:0] H_SYNC   = 6'd32;
localparam [9:0] H_BP     = 10'd51;
localparam [9:0] H_TOTAL  = 10'd429;

localparam [8:0] V_ACTIVE = 9'd224;
localparam [8:0] V_FP     = 9'd10;
localparam [4:0] V_SYNC   = 5'd3;
localparam [8:0] V_BP     = 9'd25;
localparam [8:0] V_TOTAL  = 9'd262;

// Derived boundaries — adjusted by OSD offsets.
// Positive offset shifts image right/down: subtracts from FP (sync earlier
// → larger effective BP → image right). Sync width and totals invariant.
//
// Verilog gotcha: `H_FP - h_offset` mixes unsigned H_FP and signed h_offset.
// Per IEEE 1364-2001, ANY unsigned operand makes the whole expression
// unsigned, so a negative h_offset gets silently zero-extended (treated as
// a large positive). Fix: sign-extend h_offset to the FULL result width
// (10/9 bits) so two's-complement wrapping in unsigned arithmetic gives
// the right answer. e.g. h=-1 → 10'b1111111111 → 1023 unsigned →
// (H_FP+H_ACTIVE)-1023 wraps to (H_FP+H_ACTIVE)+1 in 10-bit modulo.
wire [9:0] h_off_signext = {{6{h_offset[3]}}, h_offset};  // 10-bit two's-comp
wire [8:0] v_off_signext = {{5{v_offset[3]}}, v_offset};  // 9-bit two's-comp

wire [9:0] h_sync_start = H_ACTIVE + H_FP - h_off_signext;
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
wire [8:0] v_sync_start = V_ACTIVE + V_FP - v_off_signext;
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
