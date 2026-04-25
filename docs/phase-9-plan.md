# Phase 9 — Modeline Retune + OSD Rewrite + Dual Aspect Ratio (cross-layer)

**Document date:** 2026-04-24
**Status:** Plan only. Awaits autonomous `/implement` execution. User is asleep — agent must self-recover from failures.
**Branch:** `mister`
**Scope:** One large, batched cross-layer rebuild. Touches FPGA RTL, HPS wrapper, and the RSDKv5 engine in one phase. Replaces the current single-modeline 320x240 path with a dual-modeline (4:3 NTSC-exact + 16:9 widescreen) path selected at boot via OSD, rewrites the inherited 3sx CONF_STR to a Mania-specific menu, and wires three new env-var-controlled engine behaviours (mods on/off, FPS overlay mode, aspect-ratio runtime resolution).
**Companion docs (READ BEFORE IMPLEMENTING ANY STEP):**
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-research.md` — architecture (rendering data flow, RSDKv5 backend seam, native video writer protocol)
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md` — master phased plan + Decisions table (D1 used to lock 4:3 only; this phase intentionally extends to dual-mode)
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-4-plan.md` — current FPGA + wrapper structure (PLL math, VTG, pixel reader)
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-7-plan.md` — release-packaging shape (ZIP layout, ENV-var conventions, save path)
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — current operational state (Phase 4 RBF deployed, wrapper paths, deploy script)
- `/Users/sb/Developer/3sx-mister/docs/spec-fpga-native-video.md` — DDR3 memory map, PLL search method
- `/Users/sb/Developer/3sx-mister/docs/reference-native-analog-video.md` — integer-N PLL discipline, S-Video color rationale, vga_scaler=0 invariant

**Memory rules every step obeys (verbatim):**
- Quartus 17 lives in colima `quartus2` VM (NOT Docker). Path: `/home/sb.linux/intelFPGA_lite/17.0/`. (`reference-quartus-build-env.md`)
- Always launch Quartus builds with `nohup`. SSH would otherwise time out and kill the build. (`feedback-quartus-nohup.md`)
- Always pass `--fast` during dev iteration. Regular builds take 2+ hours in QEMU. Final release RBF only uses non-`--fast`. (`feedback-quartus-fast-build.md`)
- Never kill a running Quartus build without verifying it is dead/blocked first. (`feedback-quartus-process-mgmt.md`)
- MiSTer host: `root@192.168.1.188`, password `1`. RBF target: `/media/fat/_Other/Sonic Mania.rbf` (a SPACE not underscore). Wrapper: `/media/fat/MiSTer_SonicMania`. (`reference-mister-credentials.md`)
- NEVER use `rsync --delete` outside the whitelisted `/media/fat/games/sonic-mania/` subtree. (`feedback-no-rsync-delete.md`)
- Parallel commits on the same branch can orphan work. Serialize commits across logical groups. (`feedback-parallel-agent-git.md`)
- Don't suggest stopping; keep pushing. (`feedback-stop-suggesting-stops.md`, `feedback-never-suggest-calling-it.md`)
- DO NOT publish a release ZIP without explicit user OK. (`feedback-no-premature-release.md`)
- When user specifies a skill, actually invoke it (this plan was generated via /plan). (`feedback-enforce-skill-invocation.md`)

**Locked design decisions (DO NOT REVISIT):**
- 4:3 PLL: M=81 / N=5 / C=30 → VCO 810 MHz → CLK_VIDEO 27.000 MHz → pixel 6.750 MHz at CE_DIV=4 → H_TOTAL=429, V_TOTAL=262 → 60.07 Hz / 15,734 Hz (NTSC-exact). H_SYNC=32, V_SYNC=3.
- 16:9 PLL: M=101 / N=5 / C=29 → VCO 1010 MHz → CLK_VIDEO 34.827586 MHz → pixel 8.7069 MHz → H_TOTAL=545, V_TOTAL=266 → 60.06 Hz / 15,976 Hz. Fallback if Quartus rejects M=101: M=89/N=5/C=25 → 35.6 MHz / pix 8.9 MHz / H_TOTAL=555 / V_TOTAL=267 → 60.06 Hz / 15,995 Hz.
- TWO PLL instances always running. Glitch-free clock mux on `clk_video` (2-FF synchronizer + AND/OR, NOT raw `?:`). Mode bit gates the mux.
- VTG H_TOTAL/V_TOTAL/porches become muxed wires keyed off the mode bit.
- Wrapper writes the mode bit to an FPGA control register BEFORE binary launch (so mux is settled by the time clk_video is consumed).
- video.cpp `core_CLK_VIDEO` literal becomes a ternary on the same mode bit (4:3 = `27.0`, 16:9 = `1010.0/29.0` for bit-exact rational).
- Engine reads three env vars: `SONIC_MANIA_MODS` (0/1), `SONIC_MANIA_ASPECT` ("43"/"169"), `SONIC_MANIA_FPS_OVERLAY` ("0"/"1"/"2").
- `NativeVideoWriter` constants (NV_FRAME_WIDTH/HEIGHT/BYTES/BUF1_OFFSET) become RUNTIME values (not preprocessor constants) — they depend on aspect.
- CONF_STR is fully rewritten per the bit map in step 2 below. 3sx-specific options (Game Mode, Hold to Pause, Button Check, SA Activation/Ghost Res/Ghost Count, Overclock) are REMOVED.
- Existing fixes already in place — DO NOT REDO: chdir to SONIC_MANIA_HOME via SigHandler ctor; scanlines malloc in MiSTerRenderDevice::SetupRendering; wrapper input.cpp `grabbed=0` default; wrapper video.cpp `input_switch(0)` instead of (1) in fb-switch path (lines 3415/3422/3430); Phase 7 UserStorage uses `./` not `./saves/`.

**What NOT to do across the whole phase:**
- Do NOT publish a release. Plan ends at "deployed and verified working." User will OK the release separately.
- Do NOT redo any fix listed under "Existing fixes already in place."
- Do NOT add Overclock back to CONF_STR (user explicitly excluded it).
- Do NOT touch `RetroEngine.hpp` platform detection (decision D3 in mister-port-plan.md: MiSTer rides on `RETRO_LINUX` with our own `RETRO_RENDERDEVICE_MISTER` flag).
- Do NOT add fbdev (per `feedback-fbdev-not-used.md`).
- Do NOT use raw `?:` for the clk_video mux (will glitch). Glitch-free mux is mandatory.

---

## Critical autonomy notes for the implement agent

The user is asleep. Agent must:

1. Not ask user anything. If a decision point arises that the locked-decisions list doesn't cover, choose the safer option, document it, and proceed.
2. Auto-recover from failures:
   - If Quartus fitter rejects M=101 (16:9 PLL): retry with M=89/N=5/C=25 fallback (recompute H_TOTAL=555, V_TOTAL=267, pixel 8.9 MHz; update video.cpp ternary literal accordingly).
   - If Quartus fitter rejects the dual-PLL VCO budget: instantiate a second `pll_video` IP variant via the Quartus MegaWizard rather than hand-editing — `feedback-quartus-process-mgmt.md` applies.
   - If on-device crash on first boot: capture `gdb` backtrace via the existing SigHandler infrastructure and `/media/fat/games/sonic-mania/logs/log.txt`, root-cause, fix, redeploy.
   - If S-Video color regresses on CRT: confirm `core_CLK_VIDEO` literal in `vendor/Main_MiSTer/video.cpp` matches the actual PLL output for the active aspect; the YC subcarrier phase math depends on it (see `reference-native-analog-video.md` §4 and §10).
3. Self-verify via existing canary tests (each step lists its specific verification).
4. Commit progress per logical group. Each step's "Success criteria" lists what to commit. Every step ends with a commit so a Quartus failure does not orphan work. Never `git push --force`. Keep all commits on the `mister` branch.
5. Document remaining issues at end if any can't be resolved autonomously — append a `## Phase 9 wrap-up status` section at the bottom of this file with what landed, what didn't, and a precise repro for any deferred issue.

---

## Step plan overview (8 steps, dependency-ordered)

| # | Step | Layer | Quartus build? | Wall-clock |
|---|---|---|---|---|
| 1 | Add second video PLL + VTG mux + reader mux (RTL) | FPGA | Yes (1× --fast) | ~50-90 min |
| 2 | Rewrite CONF_STR + status-bit allocation (RTL) | FPGA | Yes (combine with step 1 if possible — 1 build covers both) | combined |
| 3 | Wrapper: read status bits, emit env vars, write FPGA mode register, fix video.cpp ternary | HPS C++ | No | ~30 min |
| 4 | Engine: read SONIC_MANIA_MODS env in RetroEngine.cpp; read SONIC_MANIA_ASPECT and SONIC_MANIA_FPS_OVERLAY in MiSTerRenderDevice::Init | C++ | No (engine rebuild only) | ~40 min |
| 5 | Make NativeVideoWriter dimensions runtime values | C | No (engine rebuild only) | ~30 min |
| 6 | Cross-layer integration test on hardware (4:3 boots, 16:9 boots, OSD options behave, S-Video color preserved both modes, input still works after OSD interaction) | All | No | ~60 min |
| 7 | Final release-quality Quartus rebuild (no `--fast`) | FPGA | Yes (1× full) | 2+ hours wall-clock |
| 8 | Wrap-up: commit any lingering changes, append wrap-up status to this doc, leave clean tree | git | No | ~10 min |

Steps 1+2 share a Quartus build (combine the RTL changes into one branch and one --fast compile). Steps 3, 4, 5 are independent of each other once 1+2 are committed; the implement agent can run them in any order, but the plan sequences them by dependency-criticality. Step 6 is gated by 1-5 and the on-device deploy. Step 7 is gated by step 6 passing. Step 8 only finalizes the work.

---

## Step 1 — RTL: add second video PLL, glitch-free clk_video mux, mode-keyed VTG/reader

### Title
Dual-PLL FPGA core with mode-keyed VTG and pixel reader

### Why it matters
The user wants 4:3 (NTSC-exact) and 16:9 (widescreen) to BOTH be selectable at boot. A single Cyclone V PLL cannot produce two unrelated VCOs without re-locking — re-locking on every aspect change would visibly glitch the display. So we instantiate two PLLs, both always running, and select which output drives `clk_video` via a glitch-free mux. The VTG and pixel reader then need their H_TOTAL / V_TOTAL / LINE_BURST / V_ACTIVE to follow the same mode bit so that the display timing matches the buffer geometry.

### Files to read first (in order)
1. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/menu.sv` — top-level. PLL instantiation at lines 322-336, status bits at lines 209-225, hps_io at 308-317.
2. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` — current 4:3-only PLL (output_clock_frequency0 = "24.603175 MHz").
3. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_timing.sv` — H/V constants at lines 69-79.
4. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv` — DDR3 buffer addresses at lines 75-80; LINE_BURST/LINE_STRIDE/V_ACTIVE.
5. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/native_video_top.sv` — top-level wiring of timing→reader.
6. `/Users/sb/Developer/3sx-mister/docs/reference-native-analog-video.md` §4 — PLL discipline (integer-N only, no fractional).
7. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/menu.qsf` — confirm IP file inclusion mechanism (will need to add a new IP file).
8. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/files.qip` — verify file list source.

### Files to create / modify

**Modified PLL (4:3 NTSC-exact):**
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v`
  - Update header comment block (lines 1-18) to document the new target: M=81/N=5/C=30 → CLK_VIDEO 27.000 MHz, CE_DIV=4 → pixel 6.750 MHz, paired with H_TOTAL=429/V_TOTAL=262.
  - Line 40: change `.output_clock_frequency0("24.603175 MHz"),` → `.output_clock_frequency0("27.000000 MHz"),`.
  - DO NOT touch `fractional_vco_multiplier("false")` (line 36), `operation_mode("direct")` (line 38), or any other field. Quartus picks M/N/C from the frequency string (verified by phase-4-plan.md §3.4).
  - Add a Verilog comment immediately above line 40 documenting the *expected* M/N/C: `// Expected fit: M=81, N=5, C=30 (VCO 810 MHz, /30 = 27.000 MHz exact). Verify in fitter log post-compile.`

**New PLL (16:9 widescreen) — copy & re-parameterize:**
- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169/pll_video_169.v`
  - Create a new directory `pll_video_169/` paralleling the existing `pll_video/`.
  - Copy `pll_video_0002.v` verbatim, rename the module to `pll_video_169_0002`.
  - Update header comment block: M=101/N=5/C=29 → CLK_VIDEO 34.827586 MHz → pixel 8.7069 MHz → H_TOTAL=545/V_TOTAL=266 → 60.06 Hz / 15,976 Hz.
  - Set `.output_clock_frequency0("34.827586 MHz"),` at the equivalent line.
  - **Fallback path (auto-trigger if M=101 fit fails):** if the Quartus compile log reports the PLL cannot be fit (look for "Could not fit clock", "PLL output frequency violation", or M-bound errors in the fitter report), the implement agent must edit the file once more to `.output_clock_frequency0("35.600000 MHz"),` (M=89/N=5/C=25 fallback) and recompile. Update the header comment to reflect the chosen config.

- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169/pll_video_169.v`
  - Top-level wrapper paralleling `vendor/Menu_MiSTer/rtl/pll_video/pll_video.v`. (Read that file first to see the wrapper shape — typically a thin module that instantiates the `*_0002` core.) Rename the wrapper module to `pll_video_169`.

- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/rtl/pll_video_169.qip`
  - New `.qip` file listing the two new `.v` files. Mirror the structure of `vendor/Menu_MiSTer/rtl/pll_video.qip`.

- `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/files.qip`
  - Add a line including the new `.qip`: `set_global_assignment -name QIP_FILE rtl/pll_video_169.qip`. Match the formatting of the existing `pll_video.qip` line.

**Top-level RTL changes (`menu.sv`):**

1. **Status-bit allocation for the mode bit.** Per step 2, the Aspect Ratio bit lives at `status[13]` (NOT status[12] — status[12:11] is the FPS Overlay 2-bit field). Define an early wire near the existing `vcrop_size` block (around line 207-210):
   ```verilog
   // Phase 9: Aspect ratio mode select. 0 = 4:3 (27 MHz), 1 = 16:9 (34.83 MHz).
   wire aspect_169 = status[13];
   ```
   **NOTE:** The current code uses `status[12]` for `ar_full` (line 206) which feeds `arx_in`/`ary_in` HDMI scaler aspect at lines 237-238. With the new CONF_STR (step 2), status[12] is repurposed as the upper FPS Overlay bit and the standalone "Aspect Ratio,4:3,Full" item is gone. We REPLACE `wire ar_full = status[12];` with `wire ar_full = aspect_169;` so the HDMI scaler tracks the native aspect mode (widescreen native ⇒ full-aspect scaler ⇒ ARX=0/ARY=0 ⇒ scaler fills display, which is correct behavior). The two wires can be unified or kept as aliases; either way, NO bare `status[12]` reads should remain in `menu.sv` after this step.

2. **Instantiate both PLLs (replace lines 330-336):**
   ```verilog
   wire clk_pix_43, clk_pix_169;
   wire pll43_locked, pll169_locked;

   pll_video pll_vid_43 (
       .refclk(CLK_50M),
       .rst(0),
       .outclk_0(clk_pix_43),
       .locked(pll43_locked)
   );

   pll_video_169 pll_vid_169 (
       .refclk(CLK_50M),
       .rst(0),
       .outclk_0(clk_pix_169),
       .locked(pll169_locked)
   );
   ```

3. **Glitch-free clock mux** — insert AFTER both PLLs, BEFORE `assign CLK_VIDEO = clk_pix;`:
   ```verilog
   // Glitch-free 2:1 clock mux on aspect_169.
   // Standard pattern: synchronize the select to BOTH clock domains, gate each
   // input clock with its own enable that is driven from the synchronized
   // select, then OR the gated outputs.
   //
   // For altera fabric this is what altclkctrl is for, but a portable AND/OR
   // pattern with explicit synchronizers is also acceptable per the Altera
   // app note "Glitch-Free Clock Multiplexers" (the 2-FF + AND-OR pattern).
   //
   // We use the explicit pattern here to keep visibility in source.

   reg [1:0] sel_sync_43, sel_sync_169;
   always @(posedge clk_pix_43) sel_sync_43  <= {sel_sync_43[0],  ~aspect_169};
   always @(posedge clk_pix_169) sel_sync_169 <= {sel_sync_169[0], aspect_169};

   wire en43  = sel_sync_43[1]  & ~sel_sync_169[1];
   wire en169 = sel_sync_169[1] & ~sel_sync_43[1];

   wire clk_pix_43_g  = clk_pix_43  & en43;
   wire clk_pix_169_g = clk_pix_169 & en169;

   wire clk_pix = clk_pix_43_g | clk_pix_169_g;
   assign CLK_VIDEO = clk_pix;
   ```
   The cross-coupled "this clock disabled while the other is enabled" pattern is the canonical glitch-free 2:1 clock mux. **Quartus may complain about gated clocks** in the timing report; that's expected. Use `set_clock_groups -exclusive {clk_pix_43} {clk_pix_169}` in the SDC if needed (see "Failure mode + recovery" below).

4. **Mode-keyed VTG parameters.** The current `native_video_timing.sv` uses `localparam` (compile-time constants). We change it to accept the mode as a port input and derive the H/V totals from it. Edit `vendor/Menu_MiSTer/rtl/native_video_timing.sv`:
   - Add input port: `input wire aspect_169` (place between the existing `reset` and `h_offset` ports; update the port list and the always_ff sensitivity).
   - Replace lines 69-79 (the `localparam` block) with a derived-wire block:
     ```verilog
     // Aspect-keyed timing constants.
     // 4:3:  H 320 (=320 active) + FP=14 + SYNC=32 + BP=63 = 429 total
     //       V 240 active +  6 FP +  3 sync + 13 BP = 262 total
     //       (NTSC-exact: 60.07 Hz, 15,734 Hz H-freq with 6.75 MHz pixel)
     // 16:9: H 424 active + FP=21 + SYNC=32 + BP=68 = 545 total
     //       V 240 active +  9 FP +  3 sync + 14 BP = 266 total
     //       (60.06 Hz, 15,976 Hz with 8.7069 MHz pixel)
     wire [9:0] H_ACTIVE = aspect_169 ? 10'd424 : 10'd320;
     wire [9:0] H_FP     = aspect_169 ? 10'd21  : 10'd14;
     wire [5:0] H_SYNC_W = aspect_169 ? 6'd32   : 6'd32;
     wire [9:0] H_BP     = aspect_169 ? 10'd68  : 10'd63;
     wire [9:0] H_TOTAL  = aspect_169 ? 10'd545 : 10'd429;

     wire [8:0] V_ACTIVE = aspect_169 ? 9'd240  : 9'd240;
     wire [8:0] V_FP     = aspect_169 ? 9'd9    : 9'd6;
     wire [4:0] V_SYNC_W = aspect_169 ? 5'd3    : 5'd3;
     wire [8:0] V_BP     = aspect_169 ? 9'd14   : 9'd13;
     wire [8:0] V_TOTAL  = aspect_169 ? 9'd266  : 9'd262;
     ```
   - The downstream usage of `H_ACTIVE`, `H_FP`, etc., already reads them as if-else expressions in always blocks (see lines 89-92, 112, 116, 128, 130, 134, 136, 142, 144, 150, 152, 158, 163). Those usages remain unchanged because Verilog `wire` and `localparam` are equivalent in expression context. Verify after edit by recompiling — fitter should produce no errors.
   - Rename the existing `H_SYNC` → `H_SYNC_W` and `V_SYNC` → `V_SYNC_W` (internal-only) to avoid name clash with output port names if any. Search the file before editing to confirm there's no port named H_SYNC / V_SYNC; if there isn't (current code only emits `hsync` and `vsync` as outputs), just keep the names as `H_SYNC` / `V_SYNC` to minimize diff.

   **Modeline arithmetic check (4:3):** 320+14+32+63 = 429 ✓; 240+6+3+13 = 262 ✓; pixel clock = 429*262*60.07 = 6,749,953 Hz ≈ 6.750 MHz ✓; H-freq = 6,750,000/429 = 15,734.27 Hz ✓ (NTSC-exact).
   **Modeline arithmetic check (16:9):** 424+21+32+68 = 545 ✓; 240+9+3+14 = 266 ✓; pixel clock = 545*266*60.06 = 8,706,961 Hz ≈ 8.7069 MHz ✓; H-freq = 8,706,961/545 = 15,976 Hz ✓.
   **Modeline arithmetic check (16:9 fallback M=89/N=5/C=25):** if pixel = 8.9 MHz, H_TOTAL=555, V_TOTAL=267 → 8,900,000/(555*267) = 60.06 Hz ✓; H-freq = 8,900,000/555 = 16,036 Hz (acceptable). Use H_FP=23, H_SYNC=32, H_BP=76 → 424+23+32+76=555. Use V_FP=10, V_SYNC=3, V_BP=14 → 240+10+3+14=267.

5. **Mode-keyed pixel reader parameters.** Edit `vendor/Menu_MiSTer/rtl/native_video_reader.sv`:
   - Add input port: `input wire aspect_169`.
   - Replace lines 75-80 (the `localparam` block) with derived wires:
     ```verilog
     // Aspect-keyed addresses & burst.
     // 4:3 frame: 320*240*2 = 153,600 bytes = 0x25800. BUF1 starts at 0x100 + 0x25800 = 0x25900. >>3 = 0x4B20.
     // 16:9 frame: 424*240*2 = 203,520 bytes = 0x31B00 (rounded to 8B = 0x31B00). BUF1 starts at 0x100 + 0x31B00 = 0x31C00. >>3 = 0x6380.
     localparam [28:0] CTRL_ADDR   = 29'h07400000;  // 0x3A000000 >> 3 (unchanged)
     localparam [28:0] BUF0_ADDR   = 29'h07400020;  // 0x3A000100 >> 3 (unchanged)
     wire        [28:0] BUF1_ADDR   = aspect_169 ? 29'h07406380 : 29'h07404B20;
     wire         [7:0] LINE_BURST  = aspect_169 ?     8'd106    :     8'd80;
     wire        [28:0] LINE_STRIDE = aspect_169 ?    29'd106    :    29'd80;
     wire         [8:0] V_ACTIVE    = 9'd240;        // unchanged
     ```
     Where 16:9 line burst = ceil(424*2/8) = ceil(106) = 106 beats = 848 B. The last 16 bytes are slop; the writer pads them. (DDR burst granularity is 8 B; 424*2=848 B = exactly 106 beats — no slop.)
   - Existing references to BUF1_ADDR/LINE_BURST/LINE_STRIDE in the file already use them as expressions; converting localparam→wire is transparent. Verify after edit.
   - The 16:9 BUF1 offset is BIGGER (203,520 vs 153,600), so the existing `NV_DDR_REGION_SIZE = 0x60000` (393,216 B) still holds: 2 * 203,520 + 256 (control) = 407,296 B which would *exceed* 0x60000 = 393,216 B. **Bug!** Fix: bump NV_DDR_REGION_SIZE to 0x80000 (512 KB) in the writer header (step 5) AND in any FPGA-side address-decode if there is one (search the RTL for 0x60000 / region_size literals — there aren't any in the RTL, only the writer side).

6. **Top-level wiring** (`native_video_top.sv`): pass the new `aspect_169` signal from `menu.sv` (where `wire aspect_169 = status[13];` is defined) down through `native_video_top` into `native_video_timing` and `native_video_reader`. Read `native_video_top.sv` first, find the timing/reader instantiation, add the port pass-through.

### Success criteria
- `quartus_sh --flow compile menu` (executed via `tools/mister-wrapper/build-core.sh --fast` on the colima `quartus2` VM, with `nohup` per `feedback-quartus-nohup.md`) completes with 0 errors. Warnings within the existing baseline (~78 warnings reference: phase-4 docs).
- Fitter report (open `output_files/menu.fit.summary`) confirms BOTH PLL output frequencies: 27.000 MHz and 34.828 MHz (or 35.6 MHz fallback).
- The output `Sonic Mania.rbf` (or `menu.rbf` then renamed) exists at the expected output path.
- Static-timing report has no NEW critical paths beyond baseline (check `menu.sta.rpt`).
- One commit on `mister`: `feat(rtl): dual-PLL aspect mux + mode-keyed VTG/reader for Phase 9`.

### Dependencies
None — this is the first step. Step 2 RTL edits (CONF_STR) can be folded into the same Quartus build to save wall-clock; the implement agent should combine them into one rebuild.

### What NOT to do
- DO NOT use raw `assign clk_pix = aspect_169 ? clk_pix_169 : clk_pix_43;` — that glitches.
- DO NOT use a single PLL with reconfig (Cyclone V supports it via the reconfig IP, but that adds re-lock latency and is more invasive than two PLLs).
- DO NOT change CTRL_ADDR or BUF0_ADDR — both are part of the wrapper-engine memory contract and unchanged.
- DO NOT change CE_PIXEL divide ratio (still ÷4 for both modes).
- DO NOT regenerate `pll_video_0002.v` via the Quartus MegaWizard unless the hand-edit fails. The frequency-string approach is documented as working in phase-4-plan.md §3.4.
- DO NOT add `set_clock_groups -exclusive` to the SDC unless Quartus emits a critical warning that requires it; the AND/OR pattern's `clk_pix` is a synthesized clock that the fitter may auto-classify correctly.

### Failure mode + recovery
- **Quartus fitter rejects the new PLL frequency for 16:9 (M=101 doesn't fit):**
  Edit `pll_video_169_0002.v` line `.output_clock_frequency0(...)` to `"35.600000 MHz"` (the M=89/N=5/C=25 fallback). Re-recompute the timing constants in `native_video_timing.sv` lines using H_TOTAL=555 / V_TOTAL=267 / H_FP=23 / H_BP=76 / V_FP=10 / V_BP=14. Update video.cpp ternary literal to `1780.0/50.0` (= 35.600000 MHz exact rational). Rebuild.
- **Quartus complains about gated clocks (clk_pix_43_g / clk_pix_169_g):**
  Add to `vendor/Menu_MiSTer/menu.sdc` (or the equivalent SDC, search for `*.sdc` in the project):
  ```
  set_clock_groups -exclusive -group {clk_pix_43} -group {clk_pix_169}
  ```
- **Both PLLs fit but `clk_pix` is reported unconstrained:**
  Add explicit `create_generated_clock -name clk_pix43 -source ...` for each PLL output in the SDC. The implement agent should follow the existing 3sx pattern in the original SDC if present (read it first).
- **Compile completes but fitter log shows the wrong M/N/C** (e.g., for 4:3 it picked something other than M=81/N=5/C=30):
  Acceptable as long as actual CLK_VIDEO is within ±100 ppm of 27.000000 MHz. If not, regenerate the IP via Quartus MegaWizard (Option B in phase-4-plan.md §3.4).

---

## Step 2 — RTL: rewrite CONF_STR + status-bit map

### Title
Sonic-Mania-specific OSD CONF_STR with locked status-bit allocation

### Why it matters
The current `vendor/Menu_MiSTer/menu.sv` CONF_STR (lines 278-305) is inherited from the Menu/3S-ARM project and exposes 3sx-specific options the user has explicitly removed: Game Mode, Hold to Pause, Button Check, SA Activation, SA Ghost Res, SA Ghost Count, Overclock. The user wants Mods, FPS Overlay, Aspect Ratio, the standard MiSTer scaler options, Reset to Default, Restart, and standard joystick maps.

The bit map below is the contract between (a) menu.sv CONF_STR encoding, (b) the wrapper's reading of the status word over the MiSTer hps_io interface, (c) the engine's env-var-controlled behaviour. Once written, this bit map is stable; do NOT renumber bits across phases.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/menu.sv` lines 209-225 (current status[] usage pattern), 278-305 (current CONF_STR), 308 (status width declaration).
2. `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/menu.sv` lines 278-305 — for reference, the 3sx version we are diverging from.
3. `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp` lines 1820-1830 (existing env-var emission pattern at startup).
4. MiSTer `hps_io` documentation for CONF_STR option syntax (knownish from existing menu.sv usage).

### Files to create / modify

**`vendor/Menu_MiSTer/menu.sv`:**

1. Replace lines 278-305 (the entire `CONF_STR` block) with:
   ```verilog
   `include "build_id.v"
   localparam CONF_STR = {
       "Sonic Mania;UART31250,MIDI;",                                                  // header
       "O[10],Mods,On,Off;",                                                           // status[10]
       "O[12:11],FPS Overlay,Off,Simple,Detailed;",                                    // status[12:11]
       "-;",
       "O[13],Aspect Ratio,4:3,Widescreen;",                                           // status[13]  <- THE MODE BIT
       "O[32],Vertical Crop,Disabled,216p(5x);",                                       // status[32]
       "O[36:33],Crop Offset,0,2,4,6,8,10,-12,-10,-8,-6,-4,-2;",                       // status[36:33]
       "O[38:37],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",        // status[38:37]
       "O[42:39],H Size,0,+1,+2,+3,+4,-4,-3,-2,-1;",                                   // status[42:39]
       "O[28:25],H Position,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",          // status[28:25]
       "O[46:43],V Position,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",          // status[46:43]
       "-;",
       "T[21],Reset to Default;",                                                      // status[21] (toggle)
       "T[22],Restart;",                                                               // status[22] (toggle)
       "-;",
       "J1,A,B,Select,Start;",                                                         // P1 button order
       "jn,B,A,Select,Start;",                                                         // SDL2 default name overrides
       "V,v",`BUILD_DATE
   };
   ```
   **Defaults** (default-on/off — encoded by ordering in CONF_STR): user spec says Mods default On, so `O[10],Mods,On,Off` orders "On" first → status[10]=0 means On, status[10]=1 means Off. The wrapper interprets accordingly (step 3). FPS Overlay defaults Off (status[12:11] = 00). Aspect defaults 4:3 (status[13] = 0). Vertical Crop defaults Disabled (status[32] = 0). Other settings (Crop Offset, Scale, H Size, H/V Position) default to 0/center.

2. **Bit allocation table (locked — DO NOT renumber):**

| Bit(s) | Meaning | Encoding |
|---|---|---|
| `status[9]` | NATIVE_VID | already used (line 341) — UNCHANGED |
| `status[10]` | Mods | 0 = On (default), 1 = Off |
| `status[12:11]` | FPS Overlay | 00=Off (default), 01=Simple, 10=Detailed |
| `status[13]` | Aspect Ratio | 0 = 4:3 (default), 1 = Widescreen — wired to `aspect_169` in step 1 |
| `status[21]` | Reset to Default (toggle) | edge-triggered |
| `status[22]` | Restart (toggle) | edge-triggered |
| `status[28:25]` | H Position | 4-bit signed offset, default 0 (already wired at line 704) |
| `status[32]` | Vertical Crop | 0=Disabled (default), 1=216p — already wired (line 209) |
| `status[36:33]` | Crop Offset | 4-bit selector — already wired (line 213) |
| `status[38:37]` | Scale | 2-bit selector — already wired (line 219) |
| `status[42:39]` | H Size | 4-bit selector — already wired (line 224) |
| `status[46:43]` | V Position | 4-bit signed offset (already wired at line 705) |

   Bits NOT listed above are reserved (zero) — DO NOT introduce additional bits in this phase.

3. **Re-confirm step 1's `aspect_169` wire is exactly `status[13]`** (the locked bit map below uses status[13] for Aspect; status[12:11] is the FPS Overlay 2-bit field). Step 1 also rewires `ar_full = aspect_169` to drop bare `status[12]` reads.

4. **Status width:** the existing `wire [46:0] status;` at line 308 stays — bits 0-46 are sufficient for our map (highest used is bit 46).

5. **Restart/Reset-to-default plumbing:** these are user-actuated toggles. The wrapper reads them on the next status update and acts. No RTL action needed beyond the CONF_STR declaration.

### Success criteria
- Quartus rebuild (combined with step 1 — same `--fast` compile) succeeds, 0 errors.
- New RBF on the MiSTer shows the new menu after boot: open OSD with the keyboard F12 / hotkey, navigate to "Sonic Mania" core, see the items in the order above. Items NOT in the list above (Game Mode, Hold to Pause, Button Check, SA *, Overclock) are GONE.
- Toggling Aspect Ratio in the OSD changes status[13] (verifiable via wrapper log if instrumented; visible verification in step 6 once the wrapper acts on the bit).
- One commit on `mister`: `feat(rtl): rewrite CONF_STR for Mania-specific OSD options`.
- Combined commit message for steps 1+2 acceptable: `feat(rtl): dual-PLL aspect mux + Mania CONF_STR rewrite`.

### Dependencies
Step 1 (the `aspect_169` wire references status[13] — both must land together).

### What NOT to do
- DO NOT add Overclock back. User explicitly excluded it.
- DO NOT keep "Game Mode", "Hold to Pause", "Button Check", "SA Activation", "SA Ghost Res", "SA Ghost Count" — all 3sx-specific.
- DO NOT renumber bits to "fix gaps" — gaps are fine and reserve future expansion.
- DO NOT re-use status[9] (NATIVE_VID — preserved from baseline) for anything else.
- DO NOT add new buttons to the J1 line. The user spec was exactly `J1,A,B,Select,Start`.

### Failure mode + recovery
- **OSD shows nothing or wrong items:** `hps_io` parses CONF_STR strictly. Verify quote escaping, no trailing semicolons inside strings, no `]` mismatches. The pattern `"O[N:M],Name,opt0,opt1,...;"` is exact.
- **Compile error "Object is not declared" referencing status[XX]:** check `wire [46:0] status;` width is large enough. If new code uses status[47+], widen the declaration.
- **Two CONF_STR options share a bit:** Quartus does not enforce uniqueness. Manual review is the only safety net. The bit table above is the source of truth — re-read it.

---

## Step 3 — Wrapper: read status bits, emit env vars, write FPGA mode register, fix video.cpp ternary

### Title
HPS wrapper status-bit ingest, env-var emission, and `core_CLK_VIDEO` ternary

### Why it matters
The HPS wrapper (`vendor/Main_MiSTer/sonicmania_wrapper.cpp`) is the bridge between the FPGA OSD (CONF_STR bits) and the engine binary. It reads the status word, derives env vars, writes them, executes the binary, and also feeds the YC encoder phase math (`core_CLK_VIDEO` constant in `video.cpp`). The aspect mode bit must flow:
1. From OSD → status[13] (FPGA side, step 2).
2. From wrapper read of status → env var `SONIC_MANIA_ASPECT="43"` or `"169"` (this step).
3. From wrapper → an FPGA control register write so the dual-PLL mux is settled BEFORE the binary launches and starts writing to DDR3 (this step).
4. From wrapper → `core_CLK_VIDEO` ternary so YC subcarrier phase is correct for the active modeline (this step).

Without step (3), the engine could start writing 16:9-sized frames into DDR3 while the FPGA reader is still in 4:3 mode, causing visible tearing and one frame of garbage at startup.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp` — full file (3046 lines per phase-7-plan.md). Particularly:
   - Lines 50-90 (constants: kRuntimeHome, env-var name conventions)
   - Lines 200-220 (existing wrapper-force handling)
   - Lines 1820-1830 (existing `setenv("SONIC_MANIA_HOME", ...)` pattern)
   - Lines 2720-2800 (env-var emission to child, including SONIC_MANIA_NATIVE_VIDEO and SONIC_MANIA_JOY_SHM)
   - Lines 2805-2925 (status-bit read, log emission, exec)
2. `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.cpp` lines 1985-2030 — current 3sx pattern for FPS overlay bit decoding (`CONF_STR: 0=Off, 1=FPS, 2=Debug` pattern). Use as template, adapting to Mania's bit map.
3. `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.cpp` lines 2810-2820 — "Seed CONF_STR status bits from persisted game config" pattern. Mania does NOT persist config bits (yet), so this code is removed; the wrapper reads status purely from the FPGA each frame.
4. `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/video.cpp` line 3072 area — `core_CLK_VIDEO` constant. (3sx version is at the same line in the 3sx tree; ours is the same after the Phase 4 fork.)
5. `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/video.cpp` lines 3415, 3422, 3430 — existing `input_switch(0)` fix (DO NOT touch, just verify it's still there).

### Files to create / modify

**`vendor/Main_MiSTer/sonicmania_wrapper.cpp`:**

1. **Remove 3sx-specific status-bit handlers.** Search for and DELETE the following blocks (or comment-out with a `// PHASE 9: removed - 3sx-specific` marker):
   - Any handler reading SA Activation / SA Ghost Res / SA Ghost Count (status bits 14/15/18:16 in 3sx).
   - Any handler reading Game Mode (status[13] in 3sx — WARNING: 3sx used status[13] for Game Mode; we re-use status[13] for Aspect Ratio. Search the file for `status[13]` and confirm any pre-existing reference is the one being intentionally repurposed.).
   - Any handler reading Hold to Pause (status[24] in 3sx).
   - Any handler reading Button Check trigger (status[23] in 3sx).
   - Any handler reading Overclock (status[20:19] in 3sx).
   Use git history (`git log --all --diff-filter=A -- vendor/Main_MiSTer/sonicmania_wrapper.cpp`) to confirm the originating 3sx commit and identify the lines if grep is ambiguous.

2. **Add new status-bit handlers** in the function that emits env vars to the child (around line 2720-2790, where SONIC_MANIA_NATIVE_VIDEO is set). The existing 3sx code at lines ~1989-2154 uses the API `user_io_status_get("[bit_range]")` — VERIFIED via grep: `user_io_status_get("[11:10]")`, `user_io_status_get("[14]")`, `user_io_status_get("[12]")`, etc. Use that exact API. Insert after the SONIC_MANIA_NATIVE_VIDEO block:
   ```cpp
   // ---- Phase 9: status-bit env-var emission ----
   //
   // Status bit map (must match vendor/Menu_MiSTer/menu.sv CONF_STR):
   //   status[10]    : Mods (0=On default, 1=Off)
   //   status[12:11] : FPS Overlay (00=Off, 01=Simple, 10=Detailed)
   //   status[13]    : Aspect Ratio (0=4:3 default, 1=Widescreen)
   //
   // env vars consumed by the engine binary:
   //   SONIC_MANIA_MODS         "0" disables ModAPI scan, "1" enables (default)
   //   SONIC_MANIA_FPS_OVERLAY  "0" off, "1" simple (showFPSOverlay=true,fpsOverlayMode=0),
   //                            "2" detailed (showFPSOverlay=true,fpsOverlayMode=1)
   //   SONIC_MANIA_ASPECT       "43" or "169"
   {
       const uint32_t mods_off    = user_io_status_get("[10]");
       const uint32_t fps_overlay = user_io_status_get("[12:11]");
       const uint32_t aspect_169  = user_io_status_get("[13]");

       setenv("SONIC_MANIA_MODS",        mods_off ? "0" : "1", 1);
       setenv("SONIC_MANIA_FPS_OVERLAY",
              fps_overlay == 0 ? "0" :
              fps_overlay == 1 ? "1" :
              fps_overlay == 2 ? "2" : "0", 1);
       setenv("SONIC_MANIA_ASPECT",      aspect_169 ? "169" : "43", 1);

       write_log_line(wrapper_log,
           "phase9: SONIC_MANIA_MODS=%s SONIC_MANIA_FPS_OVERLAY=%s SONIC_MANIA_ASPECT=%s (mods_off=%u fps=%u aspect_169=%u)",
           getenv("SONIC_MANIA_MODS"), getenv("SONIC_MANIA_FPS_OVERLAY"),
           getenv("SONIC_MANIA_ASPECT"), mods_off, fps_overlay, aspect_169);
   }
   ```

3. **Write the aspect mode bit to the FPGA control register BEFORE engine exec.** The MiSTer hps_io layer normally syncs status[] over the `HPS_BUS` automatically, so the FPGA-side `aspect_169 = status[13]` should already be set BY the time `setenv` runs. **Verification step:** add a 50 ms `usleep(50000)` AFTER `setenv("SONIC_MANIA_ASPECT", ...)` and BEFORE `execve` of the engine binary. Comment:
   ```cpp
   // Allow the FPGA's glitch-free clock mux to settle on the new aspect mode
   // before handing off the DDR3 region to the engine. The 2-FF synchronizer
   // chain in vendor/Menu_MiSTer/menu.sv is at most a few clock_pix cycles
   // (~250 ns at 6.75 MHz) plus an additional VTG line (~63 us) for the
   // reader to re-acquire scanline alignment; 50 ms is generous slack.
   usleep(50000);
   ```
   If a more direct "force a status word write" is exposed by the existing wrapper API, prefer that. Search for `user_io_set_status` or similar.

4. **`vendor/Main_MiSTer/video.cpp:3076`** — make `core_CLK_VIDEO` ternary on the FPGA aspect bit:

   Current code (verified verbatim from the file):
   ```cpp
   const double core_CLK_VIDEO = native_video_enabled
       ? (1550.0 / 63.0) // dedicated pll_video: 50 * 62/3 / 42 = 24.603175 MHz
       : (current_video_info.ctime * 100.f / current_video_info.ptime);
   ```

   Replace with:
   ```cpp
   // Phase 9: dual-modeline. CLK_VIDEO is selected by status[13] aspect bit,
   // matching menu.sv's pll_video / pll_video_169 mux.
   //   4:3:  M=81/N=5/C=30 -> 27.000 MHz exact.
   //   16:9: M=101/N=5/C=29 -> 1010/29 MHz (bit-exact rational).
   //   16:9 fallback: M=89/N=5/C=25 -> 35.6 MHz (1780/50). If step 1 used the fallback PLL,
   //   change `(1010.0/29.0)` below to `(1780.0/50.0)`.
   const bool aspect_169_native = (user_io_status_get("[13]") != 0);
   const double core_CLK_VIDEO = native_video_enabled
       ? (aspect_169_native ? (1010.0 / 29.0) : 27.0)
       : (current_video_info.ctime * 100.f / current_video_info.ptime);
   ```
   `user_io_status_get` is the existing API used elsewhere in the wrapper (verified at sonicmania_wrapper.cpp:1989-2154). The function is declared in `vendor/Main_MiSTer/user_io.h` — confirm it's already included transitively in video.cpp (search for `#include "user_io.h"`). If not, add it.

5. **DO NOT TOUCH lines 3415, 3422, 3430** in `video.cpp`. They contain the `input_switch(0)` fix from Phase 7 fixup. Leave them.

### Success criteria
- `tools/mister-wrapper/build-hps.sh` (or the equivalent — see `feedback-build-terminology.md`: "wrapper" = build-hps.sh) builds the wrapper without errors.
- Resulting `MiSTer_SonicMania` binary is armhf ELF, ~1 MB, loads on the device.
- After boot in 4:3 mode, wrapper log (`/media/fat/games/sonic-mania/logs/wrapper-*.log`) shows:
  ```
  phase9: SONIC_MANIA_MODS=1 SONIC_MANIA_FPS_OVERLAY=0 SONIC_MANIA_ASPECT=43 (status=...)
  ```
- After toggling Aspect to Widescreen in OSD and reloading core, log shows `SONIC_MANIA_ASPECT=169`.
- `core_CLK_VIDEO` log emission (find existing log line in video.cpp around line 3080-3090) reports `27.000000` for 4:3 boot and `34.827586` for 16:9 boot.
- One commit: `feat(wrapper): emit Phase 9 env vars + dual-modeline core_CLK_VIDEO`.

### Dependencies
Steps 1+2 must be deployed (or at least committed and the RBF available) before this step can be tested end-to-end. The wrapper compile itself can happen first.

### What NOT to do
- DO NOT redo the `chdir to SONIC_MANIA_HOME via SigHandler ctor` fix. It's already in.
- DO NOT redo the `input_switch(0)` fix. Already in (lines 3415/3422/3430).
- DO NOT remove the SONIC_MANIA_NATIVE_VIDEO env-var setting (line ~2735); it's still load-bearing.
- DO NOT remove the SONIC_MANIA_JOY_SHM env-var setting (line ~2789); it's reserved for Phase 8 and harmless.
- DO NOT add user-config persistence in this step. Status bits are FPGA-side only.

### Failure mode + recovery
- **Wrapper compiles but env vars don't reach engine:** verify the env emission happens BEFORE `execve` (not in a child fork that's discarded). Add a `setenv` at the very top of the function and grep for it in `/proc/<pid>/environ` on the device.
- **Status word read returns 0:** the FPGA hasn't loaded yet, or hps_io hasn't sync'd. Confirm the wrapper sequence: `core_load_rbf` → wait for RBF lock → `read_status` → `setenv` → `execve`. Add a `sleep(1)` after RBF load if necessary.
- **video.cpp ternary triggers grayscale on 16:9 S-Video:** the YC subcarrier math expects CLK_VIDEO to match the actual PLL output. If `core_CLK_VIDEO = 1010.0/29.0` is wrong (because the fallback M=89/N=5/C=25 was selected in step 1), edit the literal to `1780.0/50.0`.

---

## Step 4 — Engine: read SONIC_MANIA_MODS / SONIC_MANIA_ASPECT / SONIC_MANIA_FPS_OVERLAY env vars

### Title
RSDKv5 engine env-var ingestion (mods, aspect, FPS overlay)

### Why it matters
The engine binary needs to honor the wrapper-emitted env vars BEFORE rendering or mod-scanning begins. Each env var has a different consumer:
- `SONIC_MANIA_MODS` gates `RSDK::InitModAPI(true)` (engine-side) — the call at `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp:73`.
- `SONIC_MANIA_ASPECT` overrides `videoSettings.pixWidth` (320 for 4:3 / 424 for 16:9) at the very start of `MiSTerRenderDevice::Init` BEFORE `SetupRendering` allocates the framebuffer.
- `SONIC_MANIA_FPS_OVERLAY` seeds the static `RenderDevice::showFPSOverlay` and `RenderDevice::fpsOverlayMode` BEFORE the runtime overlay state is consulted.

These reads are pure additions; no existing env-var reads are removed or changed.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` lines 60-80 — `RunRetroEngine` startup, including the `InitModAPI(true)` call at line 73.
2. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` lines 60-100 — `Init()` body, including `videoSettings.pixWidth = 320;` at line 65.
3. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` lines 33-40 — definitions of `RenderDevice::showFPSOverlay` (line 34/36) and `RenderDevice::fpsOverlayMode` (line 38). `MiSTerPacer.cpp` is C-linkage helpers and does NOT have an Init method.
4. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/SigHandler.c` — env-var reading patterns, if any, that already exist for SONIC_MANIA_HOME.
5. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/ModAPI.cpp` line 87 — `InitModAPI` entry point and the `getVersion` flag.

### Files to create / modify

**1. `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` — gate ModAPI on `SONIC_MANIA_MODS`:**

Around line 73 (the `InitModAPI(true)` call), wrap with an env-var check:
```cpp
#if defined(RSDK_USE_MISTER)
{
    // Phase 9: SONIC_MANIA_MODS=0 from wrapper disables mod scan entirely.
    const char *mods_env = getenv("SONIC_MANIA_MODS");
    const bool mods_enabled = !mods_env || (mods_env[0] != '0');
    if (mods_enabled) {
        InitModAPI(true);
    } else {
        PrintLog(PRINT_NORMAL, "Phase 9: SONIC_MANIA_MODS=0 -> skipping InitModAPI");
    }
}
#else
        InitModAPI(true); // check for versions
#endif
```
The `RSDK_USE_MISTER` macro is emitted by `dependencies/RSDKv5/platforms/MiSTer.cmake:155` per phase-7-plan.md, so the `#if` block is correct.

Add `#include <stdlib.h>` near the top of the file (for `getenv`) if not already present (search for it; it almost certainly is via transitive include).

**2. `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` — read aspect env var and override pixWidth:**

Replace the existing line 65:
```cpp
    videoSettings.pixWidth = 320;
```

with:
```cpp
    // Phase 9: SONIC_MANIA_ASPECT="169" from wrapper -> 424 widescreen; default 320.
    {
        const char *aspect_env = getenv("SONIC_MANIA_ASPECT");
        if (aspect_env && strcmp(aspect_env, "169") == 0) {
            videoSettings.pixWidth = 424;
        } else {
            videoSettings.pixWidth = 320;
        }
    }
    PrintLog(PRINT_NORMAL, "Phase 9: SONIC_MANIA_ASPECT=%s -> pixWidth=%d",
             getenv("SONIC_MANIA_ASPECT") ? getenv("SONIC_MANIA_ASPECT") : "(unset)",
             videoSettings.pixWidth);
```
Add `#include <cstdlib>` and `#include <cstring>` to the top of the file if not already present.

The existing line 66 PrintLog (`MiSTerRenderDevice::Init: pixWidth=%d ...`) is now redundant with the new log line — leave both for now (logs are cheap and it confirms the override took effect).

**3. `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` — read FPS overlay env var and seed showFPSOverlay/fpsOverlayMode:**

VERIFIED: `RenderDevice::showFPSOverlay` and `RenderDevice::fpsOverlayMode` are static class members declared in `MiSTerRenderDevice.hpp:101-102`, defined at `MiSTerRenderDevice.cpp:34/36/38`. There is NO `MiSTerPacer::Init()` — `MiSTerPacer.cpp` is C-linkage helpers, not a class. The cleanest seeding point is INSIDE `MiSTerRenderDevice::Init()`, immediately AFTER the `videoSettings.pixWidth` env-var-read block (the change in part 2 above), BEFORE any frame logic runs.

Add this block immediately after the `PrintLog(... pixWidth ...)` log line in `Init()`:
```cpp
// Phase 9: SONIC_MANIA_FPS_OVERLAY env var seeds initial overlay state.
//   "0" -> off
//   "1" -> Simple   (showFPSOverlay=true, fpsOverlayMode=0)
//   "2" -> Detailed (showFPSOverlay=true, fpsOverlayMode=1)
{
    const char *fpso = getenv("SONIC_MANIA_FPS_OVERLAY");
    const int mode = fpso ? atoi(fpso) : 0;
    switch (mode) {
        case 1:
            RenderDevice::showFPSOverlay = true;
            RenderDevice::fpsOverlayMode = 0;
            break;
        case 2:
            RenderDevice::showFPSOverlay = true;
            RenderDevice::fpsOverlayMode = 1;
            break;
        case 0:
        default:
            RenderDevice::showFPSOverlay = false;
            RenderDevice::fpsOverlayMode = 0;
            break;
    }
    PrintLog(PRINT_NORMAL, "Phase 9: SONIC_MANIA_FPS_OVERLAY=%s -> showFPSOverlay=%d fpsOverlayMode=%d",
             fpso ? fpso : "(unset)",
             (int)RenderDevice::showFPSOverlay, (int)RenderDevice::fpsOverlayMode);
}
```

`MiSTerPacer.cpp` is NOT modified by this step. The pacer reads `RenderDevice::showFPSOverlay` and `fpsOverlayMode` directly (verified at lines 186, 231, 236 of MiSTerRenderDevice.cpp); seeding them in Init() is sufficient.

**4. NO CHANGES needed in `SigHandler.c`** — env vars are read where they are consumed, not centrally. The user spec mentions "add env-reading for the above so they're available before main()" — but env vars are inherited from `execve` and ARE available in `main()` and beyond without explicit setup. The "before main()" framing in the user spec is a misunderstanding; reading at `RunRetroEngine` (line 73) is plenty early. No SigHandler changes.

### Success criteria
- Engine compiles armhf, builds via `tools/mister/build-game.sh --flavor telemetry` (per `feedback-always-telemetry.md`).
- Engine compiles macOS via the existing CMake build (Mac-host fallbacks must keep working — the `RSDK_USE_MISTER` guard isolates the changes).
- Deployed binary log on device shows the three new log lines:
  ```
  Phase 9: SONIC_MANIA_MODS=1 -> InitModAPI called (or =0 -> skipping)
  Phase 9: SONIC_MANIA_ASPECT=43 -> pixWidth=320 (or =169 -> pixWidth=424)
  Phase 9: SONIC_MANIA_FPS_OVERLAY=0 -> showFPSOverlay=0 fpsOverlayMode=0 (etc.)
  ```
- Toggling Mods OFF in OSD and re-launching skips the mod scan (visible in log: ModAPI scan messages absent).
- Toggling Aspect to Widescreen and re-launching produces a 424×240 framebuffer (validates by `MiSTerRenderDevice::CopyFrameBuffer` log if instrumented).
- One commit: `feat(engine): read Phase 9 env vars (mods, aspect, fps overlay)`.

### Dependencies
- Step 3 (wrapper must be emitting the env vars) is required for end-to-end test, but the engine code change is independent and can be committed before step 3 deploys.
- Step 5 (NativeVideoWriter runtime dims) is required to actually USE the 424×240 width — without step 5, setting pixWidth=424 will mismatch the writer's hardcoded NV_FRAME_WIDTH=320 and trigger the assertion at MiSTerRenderDevice.cpp:215.

### What NOT to do
- DO NOT call `getenv` from a static initializer (undefined order vs `main`). Read it lazily at first use.
- DO NOT change the engine default-Linux behaviour (gate everything on `RSDK_USE_MISTER`).
- DO NOT use exceptions for missing env vars — gracefully default.
- DO NOT remove the existing `videoSettings.pixWidth = 320;` line — replace it.
- DO NOT touch SigHandler.c except to verify env vars are reachable via getenv (they always are on Linux).
- DO NOT modify `MiSTerPacer.cpp` — the FPS overlay statics live on `RenderDevice` (the class) and are seeded in MiSTerRenderDevice::Init. Pacer reads them.

### Failure mode + recovery
- **Build fails on macOS due to `RSDK_USE_MISTER` not being defined:** the macro is emitted only by `platforms/MiSTer.cmake`. The `#if defined(RSDK_USE_MISTER)` guard handles this — verify the macro names in `platforms/MiSTer.cmake:155` and update if drift.
- **Engine crashes on env-var-set value of `SONIC_MANIA_ASPECT="garbage"`:** strcmp against "169" returns nonzero, falls back to 320 — safe.
- **showFPSOverlay reset by some later code path:** add a one-shot guard (`static bool fpso_initialized = false; if (!fpso_initialized) { ...; fpso_initialized = true; }`) in case the function is re-entered.

---

## Step 5 — NativeVideoWriter: make dimensions runtime values

### Title
Convert NV_FRAME_WIDTH / NV_FRAME_HEIGHT / NV_FRAME_BYTES / NV_BUF1_OFFSET from preprocessor constants to runtime variables

### Why it matters
The current `NativeVideoWriter.h` hardcodes:
```c
#define NV_FRAME_WIDTH      320
#define NV_FRAME_HEIGHT     240
#define NV_FRAME_BYTES      (NV_FRAME_WIDTH * NV_FRAME_HEIGHT * 2)  /* 153,600 */
#define NV_BUF1_OFFSET      0x00025900u   /* NV_BUF0_OFFSET + NV_FRAME_BYTES */
```
For dual-modeline support, these must be settable at `NativeVideoWriter_Init` time based on the active aspect. Otherwise, switching to 16:9 (424×240) would either crash (NV_FRAME_BYTES too small for 424*240*2 = 203,520) or silently truncate to 320 width.

The DDR3 region size also bumps from 0x60000 (393,216 B — too small for two 16:9 frames + control) to 0x80000 (524,288 B — fits 2*203,520 + 256 = 407,296 B with comfortable slack).

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h` — full file (74 lines).
2. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c` — full file (146 lines).
3. `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` lines 70-95 (Init flow), 215-260 (CopyFrameBuffer/FlipScreen, the assertion guard).

### Files to create / modify

**`NativeVideoWriter.h`:**

Replace the four `#define`s for the dims with:
```c
/* Phase 9: dimensions are RUNTIME-configurable. Defaults match the 4:3 mode
 * for backward compatibility if NativeVideoWriter_InitWithDims is not called.
 *
 * Address invariants (FPGA-side fixed):
 *   NV_DDR_PHYS_BASE   = 0x3A000000  (unchanged)
 *   NV_DDR_REGION_SIZE = 0x00080000  (bumped from 0x60000 to fit 16:9 buffers)
 *   NV_CTRL_OFFSET     = 0x00000000  (unchanged)
 *   NV_FEEDBACK_OFFSET = 0x00000040  (unchanged)
 *   NV_BUF0_OFFSET     = 0x00000100  (unchanged - the FPGA reader hardcodes this)
 *
 * Runtime-set fields (derived from aspect):
 *   nv_frame_width_runtime, nv_frame_height_runtime, nv_frame_bytes_runtime,
 *   nv_buf1_offset_runtime
 */

#define NV_DDR_REGION_SIZE  0x00080000u   /* 512 KB; was 0x60000 */
#define NV_CTRL_OFFSET      0x00000000u
#define NV_FEEDBACK_OFFSET  0x00000040u
#define NV_BUF0_OFFSET      0x00000100u

extern int      nv_frame_width_runtime;
extern int      nv_frame_height_runtime;
extern uint32_t nv_frame_bytes_runtime;
extern uint32_t nv_buf1_offset_runtime;

/* Configures the runtime dimensions. Must be called BEFORE NativeVideoWriter_Init.
 * If never called, defaults to the 4:3 mode (320x240). */
void NativeVideoWriter_SetDims(int width, int height);
```

Existing fragility note in the header (lines 14-19) about NV_FRAME_BYTES macro expansion — REWRITE that comment to reflect the new runtime model.

**`NativeVideoWriter.c`:**

1. Add static defaults at file scope:
   ```c
   int      nv_frame_width_runtime  = 320;
   int      nv_frame_height_runtime = 240;
   uint32_t nv_frame_bytes_runtime  = 320u * 240u * 2u;     /* 153,600 */
   uint32_t nv_buf1_offset_runtime  = 0x00000100u + 320u * 240u * 2u;  /* 0x25900 */
   ```

2. Add the setter:
   ```c
   void NativeVideoWriter_SetDims(int width, int height) {
       nv_frame_width_runtime  = width;
       nv_frame_height_runtime = height;
       nv_frame_bytes_runtime  = (uint32_t)width * (uint32_t)height * 2u;
       nv_buf1_offset_runtime  = NV_BUF0_OFFSET + nv_frame_bytes_runtime;
       /* Sanity: BUF1 + frame_bytes must not exceed REGION_SIZE. */
       if (nv_buf1_offset_runtime + nv_frame_bytes_runtime > NV_DDR_REGION_SIZE) {
           /* Will trip in Init; log and continue. */
       }
   }
   ```

3. Replace every reference to the old macros:
   - `NV_FRAME_WIDTH`  → `nv_frame_width_runtime`  (lines 67, 74, 81 — see grep output above)
   - `NV_FRAME_HEIGHT` → `nv_frame_height_runtime` (line 67)
   - `NV_FRAME_BYTES`  → `nv_frame_bytes_runtime`  (lines 34, 35, 76)
   - `NV_BUF1_OFFSET`  → `nv_buf1_offset_runtime`  (line 27 in the header, line 71 here)

4. Update `NativeVideoWriter_Init` to use the runtime values (the `memset(BUF0_OFFSET)` and `memset(BUF1_OFFSET)` calls).

**`MiSTerRenderDevice.cpp`:**

1. In `Init()`, AFTER reading SONIC_MANIA_ASPECT and setting `videoSettings.pixWidth` (per step 4) and BEFORE the `NativeVideoWriter_Init()` call (around line 70-75), add:
   ```cpp
   NativeVideoWriter_SetDims(videoSettings.pixWidth, SCREEN_YSIZE);
   ```

2. Replace the assertion guard at line 215:
   ```cpp
   if (screens[0].size.x != NV_FRAME_WIDTH || screens[0].size.y != NV_FRAME_HEIGHT) {
   ```
   with:
   ```cpp
   if (screens[0].size.x != nv_frame_width_runtime || screens[0].size.y != nv_frame_height_runtime) {
   ```

3. At line 244-245, replace `NV_FRAME_WIDTH` and `NV_FRAME_HEIGHT` with the runtime variables.

4. Add `extern "C"` declarations OR `#include "NativeVideoWriter.h"` at the top — likely already included; verify and ensure the `extern int nv_frame_width_runtime;` is reachable from C++.

### Success criteria
- Engine compiles armhf and macOS without errors. macOS host build doesn't actually call NativeVideoWriter_Init (mmap fails per phase-2 log) — runtime defaults make it OK.
- Deployed binary in 4:3 mode logs `nv_frame_width_runtime=320 nv_frame_height_runtime=240 nv_frame_bytes_runtime=153600 nv_buf1_offset_runtime=0x25900`.
- Deployed binary in 16:9 mode logs `nv_frame_width_runtime=424 nv_frame_height_runtime=240 nv_frame_bytes_runtime=203520 nv_buf1_offset_runtime=0x31C00`.
- DDR3 dump in 16:9 mode shows BUF1 starts at `0x3A031C00` and contains valid RGB565 data.
- One commit: `refactor(engine): make NativeVideoWriter dims runtime-configurable`.

### Dependencies
Step 4 (the `videoSettings.pixWidth` is set there from the aspect env var; this step uses that value).

### What NOT to do
- DO NOT change `NV_DDR_PHYS_BASE` (0x3A000000) — fixed by the FPGA.
- DO NOT change `NV_BUF0_OFFSET` (0x100) — fixed by the FPGA reader at `BUF0_ADDR = 29'h07400020` in step 1.
- DO NOT change `NV_CTRL_OFFSET` or `NV_FEEDBACK_OFFSET` — fixed by the FPGA.
- DO NOT change the runtime variables AFTER `NativeVideoWriter_Init` has been called. The setter is only valid before init.
- DO NOT remove the macro definitions of NV_DDR_REGION_SIZE / NV_CTRL_OFFSET / NV_FEEDBACK_OFFSET / NV_BUF0_OFFSET — those are still preprocessor constants because the FPGA-side memory map is fixed.

### Failure mode + recovery
- **Mac build fails on extern int / linkage:** ensure the C linkage in NativeVideoWriter.h:
  ```c
  #ifdef __cplusplus
  extern "C" {
  #endif
  /* extern int nv_frame_width_runtime; etc. */
  #ifdef __cplusplus
  }
  #endif
  ```
- **`screens[0].size.x` mismatch at runtime even after dim set:** this means `SetScreenSize(0, ...)` (line 140) was called with stale pixWidth. Verify the env-var-read code in step 4 runs BEFORE `SetScreenSize`.
- **DDR3 corruption at 16:9:** verify `NV_DDR_REGION_SIZE = 0x80000` is reflected in the wrapper's mmap call (search the wrapper for `0x60000` or `NV_DDR_REGION_SIZE`). The wrapper should NOT also hardcode the region size differently.

---

## Step 6 — Cross-layer integration test on hardware

### Title
End-to-end smoke test for both aspect modes, OSD-driven options, S-Video color, and input

### Why it matters
RTL + wrapper + engine all changed in this phase. A regression in any one layer breaks the whole stack. This step ships the integrated build to the device and confirms the locked acceptance criteria from the user spec:

1. 4:3 mode boots and runs.
2. 16:9 mode boots and runs.
3. OSD options behave correctly (Mods toggle, FPS Overlay, Aspect Ratio, Vertical Crop, Crop Offset, Scale, H Size, H/V Position, Reset to Default, Restart).
4. S-Video color preserved in BOTH modes (CRT users get color, not grayscale).
5. Input still works after OSD interaction (regression test for the input_switch fix).

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — deployment procedure (always re-read per `feedback-read-runbooks-before-deploy.md`).
2. `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/deploy-step5.sh` — current deploy script.

### Files to create / modify
None for this step; it's a hardware test that produces results captured in commit messages and the wrap-up section.

### Procedure (execute in order)

**6.1 Deploy**
```bash
# From project root
tools/mister-wrapper/deploy-step5.sh
# Or whatever the canonical Phase 7 deploy is — check tools/ directory
```
Verify on device:
- `ssh root@192.168.1.188 'ls -la /media/fat/_Other/ | grep -i sonic'` shows `Sonic Mania.rbf` (with space).
- `ssh root@192.168.1.188 'ls -la /media/fat/MiSTer_SonicMania'` shows wrapper binary.
- `ssh root@192.168.1.188 'ls -la /media/fat/games/sonic-mania/bin/RSDKv5U'` shows engine binary.

**6.2 4:3 mode boot test**
- Boot core from MiSTer menu.
- Confirm OSD shows the new menu structure (open OSD, navigate the items).
- Confirm Aspect Ratio defaults to 4:3.
- Confirm engine launches into title screen at 320×240 (visible 4:3 framing on display).
- Capture the wrapper log: `ssh root@192.168.1.188 'tail -100 /media/fat/games/sonic-mania/logs/wrapper-*.log'`.
  - Confirm: `phase9: SONIC_MANIA_ASPECT=43`.
  - Confirm: `core_CLK_VIDEO=27.000000`.
- Capture the engine log: `ssh root@192.168.1.188 'tail -100 /media/fat/games/sonic-mania/saves/log.txt'`.
  - Confirm: `Phase 9: SONIC_MANIA_ASPECT=43 -> pixWidth=320`.
  - Confirm: `nv_frame_width_runtime=320 nv_frame_bytes_runtime=153600`.
- DDR3 probe: `ssh root@192.168.1.188 'busybox devmem 0x3A000000 32'` — control word should be non-zero and incrementing.

**6.3 16:9 mode boot test**
- Open OSD, toggle Aspect Ratio to Widescreen, save and reload core (Restart toggle).
- Confirm engine launches into title screen at 424×240 (wider visible image).
- Capture the wrapper log:
  - Confirm: `phase9: SONIC_MANIA_ASPECT=169`.
  - Confirm: `core_CLK_VIDEO=34.827586` (or `35.600000` if M=89/N=5/C=25 fallback was used in step 1).
- Capture the engine log:
  - Confirm: `Phase 9: SONIC_MANIA_ASPECT=169 -> pixWidth=424`.
  - Confirm: `nv_frame_width_runtime=424 nv_frame_bytes_runtime=203520 nv_buf1_offset_runtime=0x31C00`.
- DDR3 probe at 16:9 BUF1: `ssh root@192.168.1.188 'busybox devmem 0x3A031C00 32'` — should show valid RGB565 data once title screen renders.

**6.4 OSD option behavior tests**
- **Mods toggle:** Set OSD Mods=Off, restart core. Check engine log: `Phase 9: SONIC_MANIA_MODS=0 -> skipping InitModAPI`. Set back to On, restart, confirm `=1 -> InitModAPI called`.
- **FPS Overlay:** Set OSD FPS Overlay=Off→Simple→Detailed in turn, restart between each. Check engine log shows respective `showFPSOverlay`/`fpsOverlayMode`. Visually confirm overlay appears/disappears on title screen.
- **Vertical Crop / Crop Offset / Scale / H Size / H Position / V Position:** these are HDMI-scaler settings and were already wired in baseline. Confirm they still work (no regression from the Aspect change). Toggle each at least once; observe HDMI output adjusts.
- **Reset to Default toggle:** activate; confirm OSD options revert to defaults (Mods=On, FPS=Off, Aspect=4:3, Crop=Disabled, etc.).
- **Restart toggle:** activate; confirm core reloads (visible on the screen).

**6.5 S-Video color test (CRT only — skip if no CRT available)**
- With a CRT connected via S-Video and `vga_scaler=0` set (`/media/fat/MiSTer.ini` `[Sonic Mania]` section), boot in 4:3 mode and visually confirm the title screen has color (not grayscale). The YC subcarrier phase math depends on `core_CLK_VIDEO=27.0` matching the actual PLL output.
- Toggle to 16:9 mode and re-confirm color on CRT.
- If color is grayscale: the `core_CLK_VIDEO` literal in `vendor/Main_MiSTer/video.cpp` does not match the actual PLL output. Re-check step 3 — likely the M=89/N=5/C=25 fallback was used but the literal stayed at `1010.0/29.0`.

**6.6 Input regression test**
- In 4:3 mode, navigate the in-game menu with controller. Confirm A/B/Select/Start work.
- Open OSD with hotkey, navigate, close OSD.
- Verify in-game controller still works (this is the input_switch(0) fix from earlier — already in place; this step just confirms no regression).

### Success criteria
- ALL of 6.1-6.6 pass.
- Engine logs and wrapper logs show the expected env-var values.
- DDR3 control word increments between samples in both modes.
- One commit: `test(phase-9): on-device verification of 4:3 + 16:9 + OSD behavior` (commit message captures the verification log excerpts).

### Dependencies
Steps 1-5 all deployed.

### What NOT to do
- DO NOT use `rsync --delete` to clean the device. Per `feedback-no-rsync-delete.md`.
- DO NOT skip 6.5 (S-Video) just because it's "cosmetic" — color regression on CRT is a functional regression for our user base.
- DO NOT release a ZIP based on this verification. Per `feedback-no-premature-release.md`.

### Failure mode + recovery
- **Engine doesn't boot in 16:9 mode (immediate exit):** check `MiSTerRenderDevice.cpp:215` assertion (frame buffer dim mismatch). Likely indicates step 5 didn't get the runtime dim into NativeVideoWriter before MiSTerRenderDevice's CopyFrameBuffer-time check.
- **Wrong aspect on display:** verify `aspect_169 = status[13]` (NOT status[12]) in menu.sv — step 1 + step 2 must agree on the bit number.
- **Black screen in 16:9 mode but engine running:** the FPGA pixel reader's `BUF1_ADDR` mux is wrong — check step 1 RTL change to native_video_reader.sv.
- **One mode works, other shows torn/garbage frames:** the glitch-free clock mux didn't settle. Increase the wrapper's pre-exec `usleep` from 50 ms to 200 ms; if that fixes it, the underlying issue is the synchronizer chain length and a longer chain (3-FF instead of 2-FF) is warranted in step 1.
- **OSD shows correct items but toggling does nothing:** the wrapper isn't reading the right status bits. Verify the wrapper's status read against the bit map in step 2.
- **Crash with backtrace:** the existing SigHandler should dump a backtrace to log.txt. Read it. Common cause: pixWidth=424 but framebuffer was allocated for 320 (i.e., step 5 didn't apply correctly). Fix and redeploy.

---

## Step 7 — Final release-quality Quartus rebuild (no `--fast`)

### Title
Full Quartus compile for shippable RBF

### Why it matters
The dev iteration in step 1 used `--fast` per `feedback-quartus-fast-build.md`. The shippable RBF needs the full fitter pass for best fMAX margin and pin compatibility. This step is the Quartus build; it does NOT publish a release ZIP (per `feedback-no-premature-release.md`).

### Files to read first
1. `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-core.sh` — reference for Quartus invocation (verify `--fast` is the only difference, NOT a different project).
2. `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/build-core.sh` if present — local script.
3. Phase-4 plan §7 — final release build procedure.

### Files to create / modify
None — this is a build-only step.

### Procedure
1. SSH to colima `quartus2` VM: `ssh sb.linux@<vm>` or however the VM is reached locally.
2. cd to the project mirror in the VM (typically `/home/sb.linux/build/sonic-mania-mister-core/` or similar — search for `menu.qpf`).
3. Pull latest from the `mister` branch: `git pull` (or sync via rsync from the host project dir).
4. Launch full compile in background:
   ```bash
   cd /home/sb.linux/build/sonic-mania-mister-core/vendor/Menu_MiSTer
   nohup /home/sb.linux/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile menu \
       > /tmp/quartus-phase9-final.log 2>&1 &
   echo $! > /tmp/quartus-phase9-final.pid
   ```
5. Monitor without blocking:
   ```bash
   tail -f /tmp/quartus-phase9-final.log
   # Or: while kill -0 $(cat /tmp/quartus-phase9-final.pid) 2>/dev/null; do sleep 60; done
   ```
6. On success, copy the RBF back to the host:
   ```bash
   scp colima-vm:/home/sb.linux/build/.../output_files/menu.rbf \
       /Users/sb/Developer/sonic-mania-mister/build/mister-wrapper-core/Sonic_Mania.rbf
   # Then rename if/as needed for deploy-step5.sh
   ```
7. Verify the new RBF: file size in same ballpark as previous (~3-4 MB), fMAX report shows positive slack.

### Success criteria
- Full compile completes (2+ hours wall-clock) with 0 errors.
- `menu.fit.summary` confirms BOTH PLLs fit within timing.
- `menu.sta.rpt` shows no new critical timing paths beyond baseline.
- The new RBF deployed to device boots and behaves identically to the `--fast` version from step 6.
- One commit: `chore(rtl): final phase-9 RBF (full compile)` (or rebuild-and-stash; do NOT commit the RBF binary — `.rbf` is in `.gitignore` per Phase 7 step 1).

### Dependencies
All previous steps committed and verified working.

### What NOT to do
- DO NOT use `--fast` for this build.
- DO NOT kill the build mid-flight per `feedback-quartus-process-mgmt.md`.
- DO NOT publish a release. Per `feedback-no-premature-release.md`.
- DO NOT touch the SDC unless step 1 added a known-needed `set_clock_groups` constraint.

### Failure mode + recovery
- **Compile fails at full but succeeded at --fast:** typically means timing is tighter at the higher fMAX target. Check the failing report (`menu.sta.rpt`). The most common fix is adding a `set_clock_groups -exclusive {clk_pix_43} {clk_pix_169}` line to the SDC.
- **Compile takes > 4 hours:** check the colima VM resource allocation (`feedback-quartus-fast-build.md` notes 2+ hours is normal in QEMU; 4+ hours indicates a different issue). Confirm no other Quartus process is competing.
- **Output RBF behaves differently than --fast version:** rare but possible if the fitter chose different routing. Re-run step 6's verification on the full-compile RBF.

---

## Step 8 — Wrap-up: commit lingering changes, append wrap-up status

### Title
Phase 9 wrap-up commit + status append

### Why it matters
The user is asleep. They wake up wanting to know what landed and what didn't. The plan ends with a wrap-up status section appended to THIS document so the next-morning conversation has a clean state-of-the-world.

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-9-plan.md` — append a new bottom section:
  ```markdown
  ## Phase 9 wrap-up status
  **Date:** YYYY-MM-DD (UTC)

  ### Landed
  - Step 1: dual-PLL + glitch-free mux + mode-keyed VTG/reader (commit <SHA>)
  - Step 2: CONF_STR rewrite (combined commit with step 1, or separate <SHA>)
  - Step 3: wrapper env-var emission + video.cpp ternary (commit <SHA>)
  - Step 4: engine env-var ingest (commit <SHA>)
  - Step 5: NativeVideoWriter runtime dims (commit <SHA>)
  - Step 6: hardware verification (commit <SHA>) — log excerpts attached below
  - Step 7: final RBF build — RBF SHA256 attached below

  ### Verification log excerpts
  4:3 boot:
  ```
  <paste relevant lines from /media/fat/games/sonic-mania/logs/wrapper-*.log>
  ```

  16:9 boot:
  ```
  <paste relevant lines>
  ```

  ### Issues deferred / open
  - <if any: precise repro, hypothesis, what was tried>

  ### What is shippable as of end-of-phase
  - 4:3 NTSC-exact + 16:9 widescreen native modes, both verified on hardware.
  - OSD CONF_STR matches user spec.
  - Engine honors three new env vars.
  - S-Video color preserved on both modes (CRT-tested if available).
  - Input not regressed.
  - Final RBF (non-`--fast`) committed for release packaging.
  ```

### Success criteria
- Wrap-up section appended.
- Final commit: `docs(phase-9): wrap-up status` (single commit summarizing the phase).
- `git log --oneline` shows clean phase-9 commit history on `mister` branch.
- `git status` is clean (no orphaned untracked files).

### Dependencies
Step 7 completed.

### What NOT to do
- DO NOT publish or push to GitHub.
- DO NOT tag.
- DO NOT delete this plan file (it's a permanent record).

### Failure mode + recovery
N/A — this is a docs-only step.

---

## Phase 9 risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R-1 | Quartus fitter rejects M=101 PLL for 16:9 | Medium | M=89/N=5/C=25 fallback documented in step 1 (35.6 MHz, H_TOTAL=555, V_TOTAL=267). Auto-trigger if first compile fails. |
| R-2 | Glitch-free clock mux rings or doesn't propagate | Medium-High | 2-FF synchronizer + AND/OR pattern is canonical. If rings, add `set_clock_groups -exclusive` to SDC. If 2-FF chain too short, lengthen to 3-FF. |
| R-3 | Status[12] reuse breaks legacy `ar_full` HDMI scaler aspect | Low | `ar_full` and `aspect_169` semantically compatible (both want widescreen scaler when widescreen native is selected). Move the `ar_full` use to `aspect_169` and drop the duplicate name. |
| R-4 | DDR3 region 0x60000 too small for 16:9 (203,520*2 + 256 = 407,296 > 393,216) | High (silent corruption) | Bump REGION_SIZE to 0x80000 in step 5 + verify wrapper mmap also uses the new size. |
| R-5 | Engine static initializers read getenv before `main` | Low | Step 4 explicitly defers env reads to first-use functions (Init / Pacer init), not static-init time. |
| R-6 | macOS host build breaks because `RSDK_USE_MISTER` guards differ | Low | Follow the existing `#if defined(RSDK_USE_MISTER)` pattern from Phase 7 step 4. CMake emits the macro; Mac builds skip the new code paths. |
| R-7 | S-Video grayscale on 16:9 because video.cpp literal mismatches actual PLL | Medium | Step 6.5 explicit S-Video test. If grayscale, swap literal to `1780.0/50.0` per the M=89 fallback. |
| R-8 | Input freeze after OSD interaction | Low (already fixed) | The `input_switch(0)` fix (lines 3415/3422/3430) is in place from earlier. Step 6.6 regression-tests it. |
| R-9 | Mods env var doesn't reach engine (wrapper bug) | Medium | Step 4 logs to engine log; step 6 verifies log content. If missing, check wrapper's `setenv` runs BEFORE `execve`. |
| R-10 | Quartus full compile (step 7) takes > 4 hours | Low | Per `feedback-quartus-fast-build.md`, 2+ hours is normal in QEMU. > 4 hours warrants investigation but not abort. |
| R-11 | parallel agents committing simultaneously orphan work | Low (this plan is single-agent) | Per `feedback-parallel-agent-git.md`, serialize commits — this plan does so by ordering steps strictly. |
| R-12 | Engine pixWidth=424 + writer expecting 320 | High (covered by step 5) | Step 5 makes writer dims runtime; step 4 sets pixWidth from env BEFORE step-5's setter is called from MiSTerRenderDevice::Init. |

---

## Quick reference — locked values

### PLL parameters (4:3 mode)
| Param | Value |
|---|---|
| M | 81 |
| N | 5 |
| C | 30 |
| VCO | 810 MHz |
| CLK_VIDEO | 27.000000 MHz exact |
| CE_PIXEL | ÷4 |
| Pixel clock | 6.750000 MHz |
| H_TOTAL | 429 |
| V_TOTAL | 262 |
| H_FP / H_SYNC / H_BP | 14 / 32 / 63 |
| V_FP / V_SYNC / V_BP | 6 / 3 / 13 |
| Refresh | 60.07 Hz |
| H-freq | 15,734 Hz (NTSC-exact) |
| video.cpp literal | `27.0` |
| `output_clock_frequency0` string | `"27.000000 MHz"` |

### PLL parameters (16:9 primary)
| Param | Value |
|---|---|
| M | 101 |
| N | 5 |
| C | 29 |
| VCO | 1010 MHz |
| CLK_VIDEO | 1010/29 = 34.827586 MHz |
| CE_PIXEL | ÷4 |
| Pixel clock | 8.7069 MHz |
| H_TOTAL | 545 |
| V_TOTAL | 266 |
| H_FP / H_SYNC / H_BP | 21 / 32 / 68 |
| V_FP / V_SYNC / V_BP | 9 / 3 / 14 |
| Refresh | 60.06 Hz |
| H-freq | 15,976 Hz |
| video.cpp literal | `1010.0 / 29.0` |
| `output_clock_frequency0` string | `"34.827586 MHz"` |

### PLL parameters (16:9 fallback if M=101 fails)
| Param | Value |
|---|---|
| M | 89 |
| N | 5 |
| C | 25 |
| VCO | 890 MHz |
| CLK_VIDEO | 35.600000 MHz |
| CE_PIXEL | ÷4 |
| Pixel clock | 8.900000 MHz |
| H_TOTAL | 555 |
| V_TOTAL | 267 |
| H_FP / H_SYNC / H_BP | 23 / 32 / 76 |
| V_FP / V_SYNC / V_BP | 10 / 3 / 14 |
| Refresh | 60.06 Hz |
| H-freq | 16,036 Hz |
| video.cpp literal | `1780.0 / 50.0` |
| `output_clock_frequency0` string | `"35.600000 MHz"` |

### CONF_STR status-bit map (LOCKED)
| Bit(s) | Meaning | Default |
|---|---|---|
| 9 | NATIVE_VID (preserved baseline) | (unchanged) |
| 10 | Mods | 0 = On |
| 12:11 | FPS Overlay | 00 = Off |
| 13 | Aspect Ratio | 0 = 4:3 |
| 21 | Reset to Default (toggle) | n/a |
| 22 | Restart (toggle) | n/a |
| 28:25 | H Position | 0 |
| 32 | Vertical Crop | 0 = Disabled |
| 36:33 | Crop Offset | 0 |
| 38:37 | Scale | 00 |
| 42:39 | H Size | 0 |
| 46:43 | V Position | 0 |

### Env vars (LOCKED)
| Name | Values | Consumer |
|---|---|---|
| `SONIC_MANIA_MODS` | `"0"` (off) / `"1"` (on, default) | RetroEngine.cpp:73 — gates InitModAPI |
| `SONIC_MANIA_FPS_OVERLAY` | `"0"` / `"1"` / `"2"` | MiSTerRenderDevice::Init — seeds RenderDevice::showFPSOverlay / fpsOverlayMode |
| `SONIC_MANIA_ASPECT` | `"43"` (default) / `"169"` | MiSTerRenderDevice::Init — sets pixWidth (320 vs 424) |

### DDR3 memory map (LOCKED)
| Symbol | Value | Notes |
|---|---|---|
| NV_DDR_PHYS_BASE | 0x3A000000 | Unchanged |
| NV_DDR_REGION_SIZE | 0x00080000 | BUMPED from 0x60000 to fit 16:9 buffers |
| NV_CTRL_OFFSET | 0x00000000 | Unchanged |
| NV_FEEDBACK_OFFSET | 0x00000040 | Unchanged |
| NV_BUF0_OFFSET | 0x00000100 | Unchanged (FPGA reader hardcoded) |
| NV_BUF1_OFFSET (4:3) | 0x00025900 | Unchanged from Phase 4 |
| NV_BUF1_OFFSET (16:9) | 0x00031C00 | NEW |
| NV_FRAME_BYTES (4:3) | 153,600 | Unchanged |
| NV_FRAME_BYTES (16:9) | 203,520 | NEW |

---

## End of Phase 9 plan
