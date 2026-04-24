# Phase 4 — FPGA Core Implementation Plan (Track F)

**Document date:** 2026-04-24
**Status:** Draft plan, awaiting user sign-off before `/implement` cycles begin.
**Scope:** FPGA RBF core + paired HPS wrapper binary for Sonic Mania on MiSTer.
**Tracks:** This is **Track F** (FPGA/RTL). It is fully independent of Track L
(Linux-userland). Phase 4 does **not** plan userland/SDK work, input wrapper
polish, or HUD cropping — those live in other tracks/phases.

**Companion docs (canonical — read before implementing any step):**
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-research.md` §3, §3.7
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md` Phase 4 (lines ~174–228), plus the Decisions table at the top
- `/Users/sb/Developer/3sx-mister/docs/spec-fpga-native-video.md` — the gold FPGA spec (1716 lines, the ground truth for PLL math, VTG, DDR3 reader, mux wiring)
- `/Users/sb/Developer/3sx-mister/docs/design-fpga-native-video.md` — design rationale
- `/Users/sb/Developer/3sx-mister/docs/reference-native-analog-video.md` — the **current-shipped** 3S-ARM configuration (differs from the original spec in several numbers; §4 PLL and §5 VTG give the working values)
- `/Users/sb/Developer/3sx-mister/docs/mister-wrapper.md` — HPS wrapper launch contract
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.cpp` — wrapper source to adapt
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/` — the Menu-derived Quartus project that 3S-ARM was forked from
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-core.sh` — reference build driver

**Baked-in decisions (do NOT revisit, see Decisions table in `mister-port-plan.md`):**
- **D1:** Internal resolution is **320×240 4:3**, not widescreen 424×240.
- **D2:** Separate FPGA core forked from `3S-ARM`. Do not unify one core to carry both modelines.
- **D7:** Core filename `Sonic Mania.rbf` preferred; `SonicMania.rbf` is an acceptable fallback if a tool refuses spaces.

**Memory rules that constrain implementation (the /implement cycle MUST respect):**
- Quartus 17 lives in the colima `quartus2` VM. **NOT Docker** on this host. Path: `/home/sb.linux/intelFPGA_lite/17.0/`. (See memory `reference-quartus-build-env.md`.)
- Always use `nohup` when launching a Quartus build in the VM. SSH will time out and kill a direct build otherwise. (Memory `feedback-quartus-nohup.md`.)
- Always use the `--fast` flag during dev iteration. Regular compile is 2+ hours; `--fast` is ~50–70% faster with a small fMAX trade-off. Only use full compile for a final release RBF. (Memory `feedback-quartus-fast-build.md`.)
- Never kill a running Quartus build without user approval. If in doubt, ask. (Memory `feedback-quartus-process-mgmt.md`.)
- Deploy to MiSTer via SSH at `root@192.168.1.188`, password `1`. RBF target path is **`/media/fat/_Other/Sonic Mania.rbf`** (a space, not underscore). Wrapper binary goes to `/media/fat/MiSTer_SonicMania` (see step 7). Never `rsync --delete` outside `/media/fat/games/sonic-mania/`. (Memories `reference-mister-credentials.md`, `feedback-read-runbooks-before-deploy.md`, `feedback-no-rsync-delete.md`.)

---

## 0. Parameter changes from 3S-ARM baseline (reference only — each step cites the numbers it needs)

| Module | 3S-ARM (current shipped) | Mania (this plan) |
|---|---|---|
| `NV_FRAME_WIDTH` | 384 | **320** |
| `NV_FRAME_HEIGHT` | 224 | **240** |
| `NV_FRAME_BYTES` | 172,032 | **153,600** |
| `NV_BUF1_OFFSET` | `0x0002A200` | **`0x00025900`** |
| `NV_DDR_PHYS_BASE` | `0x3A000000` | unchanged (same contract) |
| `NV_DDR_REGION_SIZE` | `0x00060000` (384 KB) | unchanged (still fits — 2×153,600 + ctrl/feedback ≈ 300 KB) |
| Pixel reader line burst | 768 B/line (96 beats × 8 B) | **640 B/line (80 beats × 8 B)** |
| Pixel reader frame bytes | 172,032 | **153,600** |
| VTG active H / V | 384 / 224 | **320 / 240** |
| VTG H/V totals | 495 / 264 (shipped) | **see §2 — 341 / 264 selected; two alternates flagged** |
| Pixel clock (DAC) | 7,788,461.5 Hz | **~6,151 kHz at selected timing — see §2** |
| PLL CLK_VIDEO / CE_PIXEL | 31.1538 MHz ÷4 | **see §3 — two candidate M/N/C configs documented** |
| `vga_scaler=0` requirement | yes | **same (critical invariant)** |

**Important discrepancy note:** `spec-fpga-native-video.md` (the 1716-line spec) documents the *originally planned* PLL and VTG (M=15/N=1/C=93, H_TOTAL=512, pixel clock ~8.06 MHz). `reference-native-analog-video.md` §4 documents the **currently shipped** 3S-ARM PLL (M=81/N=5/C=26 with CE_PIXEL=÷4, H_TOTAL=495, pixel clock ~7.79 MHz). **Follow the reference doc for actual 3sx configuration**; use the spec for module structure, DDR3 protocol, and integration patterns. The shipped config was arrived at to hit the exact NTSC H-freq of 15,734.266 Hz — we will do the analogous math for Mania.

---

## 1. Plan overview — seven ordered steps

Each step below is sized for a single `/implement` cycle. Because a full Quartus build with `--fast` takes ~40–60 minutes in the colima VM and a regular build takes 2+ hours, we **stage** the bitstream changes into groups that can be verified together. We do **not** bake a build-per-parameter.

| # | Step | /implement target | Quartus build? | Wall-clock estimate |
|---|---|---|---|---|
| 1 | Fork Menu/3S-ARM project, rename to `Sonic_Mania`, patch CONF_STR, verify project opens. | `--prepare-source` only; no compile | No | ~15 min |
| 2 | Regenerate `pll_video` IP for Mania pixel clock, update VTG parameters in `native_video_timing.sv`. Dry-run Quartus fit on just those changes (no DDR3/burst change yet). | Edit IP + RTL, first full `--fast` compile | Yes (1×) | ~60–90 min |
| 3 | Update pixel reader burst, frame bytes, buffer offsets in `native_video_reader.sv` and `native_video_top.sv`. Build `--fast`. Deploy and verify test pattern on HDMI. | RTL edits + compile | Yes (1×) | ~60–90 min + deploy/test |
| 4 | Adapt `thirdsarm_wrapper.cpp` → `sonicmania_wrapper.cpp`, retarget paths/names, build HPS binary `MiSTer_SonicMania`. (No FPGA build.) | HPS build only | No | ~20 min |
| 5 | Integrate — deploy RBF + wrapper, write `[Sonic Mania]` INI section, smoke-test on HDMI with a known 320×240 RGB565 test frame produced on the host or by a tiny test binary. | No edits, deploy + verify | No | ~20 min + live test |
| 6 | CRT S-Video validation (`vga_scaler=0`, color check, sync stability). Includes modeline tuning loop if CRT refuses sync (may require going back to step 2 with adjusted H/V totals). | Potentially iterate RTL | Possibly 1× | 45 min + iteration risk |
| 7 | Final release-flavor Quartus build (no `--fast`) to produce shippable `Sonic Mania.rbf`. Sanity-check fMAX and pin assignments; archive into the repo. | Yes (1× full) | Yes | 2+ hours wall-clock |

Steps 1–4 can be executed in any order where marked independent; the natural ordering above minimizes Quartus spin-ups. Steps 5–7 are strictly sequential. The user gets a sign-off gate before each Quartus build per instructions.

---

## 2. Modeline derivation — 320×240 @ 60 Hz

Goal: produce a 320×240 active-area modeline that (a) targets ~60 Hz to match the RSDKv5 engine's default tick rate (see `mister-port-research.md` §2.11 and `RetroEngine.hpp:154-155`), (b) falls within 15-kHz CRT H-frequency tolerance (roughly 15.4–16.0 kHz for standard NTSC CRTs; 15.625–15.750 kHz for strict NTSC), and (c) lands on a PLL-achievable pixel clock from the 50 MHz reference.

### 2.1 Three candidate families

There are three standard ways to produce 320×240 @ ~60 Hz on a 15-kHz CRT:

| Family | Approach | Example vtotal/htotal | Pixel clock | Pro | Con |
|---|---|---|---|---|---|
| **A: Arcade-NTSC custom** | H_freq = 15,734.266 Hz (exact NTSC), H_total chosen to land on 6.0–6.4 MHz pixel clock | 480×240 doublescan is the reference, 320 active; we use V_total=264 lines like NTSC | **~6.15 MHz** for H_total=391, or **~6.23 MHz** for H_total=396 | Exact NTSC H-freq ⇒ maximum CRT compatibility | Custom modeline, narrow community-tested support |
| **B: NES-derivative** | Follow NES/Genesis's 15,734 Hz at 256 active horizontal, scaled up to 320 active — same H_total as console-like cores | H_total=341 dots (like NES); V_total=262 | **~5.37 MHz** | Proven on broad range of CRTs through console cores | Pixel clock is well below the 3sx baseline and off our previous DE10-nano experience |
| **C: VGA 320×240 doublescan** | Double-scan 640×480 VGA → 320×240. Runs at 31.469 kHz H-freq (doubled), which is NOT 15 kHz — HDMI/VGA LCD friendly but **will not sync on classic 15-kHz CRTs** | H_total=400×2, V_total=525 | **~12.59 MHz / 2 = 6.297 MHz at DAC with scandoubler** | HDMI-ideal; trivial on VGA LCDs | Explicitly blocks 15-kHz CRT use; breaks Decision #1 intent (arcade-aesthetic) |

### 2.2 Selected candidate: Family A (Arcade-NTSC custom)

We pick **Family A** because:
1. Decision #1 (4:3 320×240) frames this as an arcade-style crop of Mania, and the wrapper inherits 3sx's `vga_scaler=0` posture, which implies "arcade CRT users are first-class."
2. The current 3S-ARM shipped configuration uses the exact same H-freq = NTSC standard (15,734.266 Hz) and is known-working on a wide range of CRTs including Sony PVM/BVM and Blast City arcade monitors (see `reference-native-analog-video.md` §4, §10).
3. Reusing the exact H-freq means we can carry forward the yc_out PHASE_INC calculation pattern and S-Video color fix from 3sx without re-deriving it.

### 2.3 Derivation

Target V_total and V-freq identical to 3sx (V_total = 264 lines):
- V_active = 240
- V_total = 264  (so V blanking = 24 lines, larger than 3sx's 40-line blanking for the same 224-active case — we lose 16 lines of back porch, which is **acceptable and standard for a 240-line mode** — see NES/Genesis canonical: 224 active + 38 blank = 262 lines, or 240 active + 22–24 blank = 262–264 lines)

Allocate V blanking (chosen to balance top/bottom porches around the larger V_active):
- V_front_porch = 6 lines
- V_sync = 3 lines
- V_back_porch = 15 lines
- V_active + V_FP + V_Sync + V_BP = 240 + 6 + 3 + 15 = **264 ✓**

**Rationale for V_FP=6 / V_BP=15 split:** with V_active=240 (up from 3sx's 224) and V_total pinned at 264, the blanking budget shrinks from 40 lines (3sx) to 24 lines (Mania). The shipped 3sx uses V_FP=15 / V_Sync=3 / V_BP=22; conventional NTSC often uses V_FP≈3 / V_BP≈18. We pick V_FP=6 and V_BP=15 to keep V_active roughly centered within V_total (equal-ish top/bottom porch: BP is slightly larger than FP+Sync to sit below the sync pulse, matching NTSC convention). This diverges deliberately from 3sx's larger-FP shipped split because the tighter Mania blanking budget does not permit it — we preserve the more-critical V_Sync=3 width unchanged.

Target H-freq = 15,734.266 Hz (NTSC standard exact, same as 3S-ARM shipped) is our *aspirational* target. **Achieved H-freq after PLL fit (§3.2) is 15,731 Hz** (a 3 Hz / ~200 ppm low miss, well within any NTSC CRT tolerance — see m-2 note below).

**Achieved V-freq after PLL fit = 15,731 / 264 = 59.587 Hz** (the plan's single source of truth for refresh rate; see §3.2). This is the value the Linux-userland pacer must match.

**Why 59.587 Hz and not 59.59949 (3sx) or 60.00 Hz:** The best integer-M/N/C PLL fit for 320×240×391×264 timing at 50 MHz reference lands on CLK_VIDEO = 24,603,175 Hz (M=62/N=3/C=42; see §3.2) which corresponds to 59.587 Hz V-freq. Hitting 59.59949 exactly (matching 3sx's 1-μHz-error configuration) would require an M/N/C search that returned no equally-clean fit — we accept the 200 ppm H-freq miss and the 0.013 Hz frame-rate delta from 3sx's value. RSDKv5 is robust to this: the engine's timing is controlled by the Linux-userland `TARGET_FPS` constant, which this plan sets to **59.587 Hz** throughout (§6.7, §10.5). No RTL re-tuning is required.

**Horizontal totals.** Working from the NTSC-exact H-freq target (15,734.266 Hz) to pick a usable H_total: pixel_clock_target = H_total × V_total × V_freq_target = H_total × 264 × 59.59949 = H_total × 15,734.266 Hz. (Once we commit to an M/N/C, the *achieved* H-freq will shift slightly — 15,731 Hz at M=62/N=3/C=42 — and the achieved V-freq becomes 59.587 Hz per §3.2. The H_total selection is unaffected.)

We want a pixel clock the Fractional PLL can hit cleanly from 50 MHz. Two specific H_total choices are on the table:

| H_total option | Pixel clock (Hz) | H blanking | Notes |
|---|---|---|---|
| **391** | 391 × 15,734.266 = **6,152,098.0 Hz** | 71 pixels | Preferred: pixel clock lands cleanly on an integer-N PLL config, keeps H blanking tight |
| 396 | 396 × 15,734.266 = 6,230,769.3 Hz | 76 pixels | Easier PLL fraction but slightly slower-than-ideal-looking image width |
| 408 | 408 × 15,734.266 = 6,419,580.6 Hz | 88 pixels | Matches generic "arcade 320" H_total from MAME modelines; pixel clock less neat |

**Recommended: H_total = 391** (pixel clock 6.152 MHz). Allocate H blanking:
- H_active = 320
- H_front_porch = 14 pixels (~2.3 μs)
- H_sync = 32 pixels (~5.2 μs, standard NTSC HS width)
- H_back_porch = 25 pixels (~4.1 μs)
- H_total = 320 + 14 + 32 + 25 = **391 ✓**

**Note on H_FP = 14** (vs 3sx's shipped H_FP = 23): we are tighter than 3sx by 9 pixels (~1.5 μs) on the front porch. This is still comfortably above the NTSC-minimum H_FP of ~1.5 μs (≈9 pixels at our 6.15 MHz clock). We trade a touch of front-porch slack for sync pulse width + back porch budget, keeping H_sync at a full NTSC-standard 5.2 μs. If a specific CRT rejects sync, R-1 mitigation in §11 includes reallocating toward H_FP=20 / H_BP=19.

H_SYNC_START = 320 + 14 = 334
H_SYNC_END   = 334 + 32 = 366
V_SYNC_START = 240 + 6 = 246
V_SYNC_END   = 246 + 3 = 249

### 2.4 Final modeline (selected)

```
"320x240_59.587"  6.151  320  334  366  391   240  246  249  264   +hsync +vsync
```

(Polarity notation uses `+hsync` / `+vsync` because the 3sx VTG emits MiSTer-convention active-high sync. `xrandr` readers of this modeline should interpret accordingly.)

### 2.5 Sync polarities

**Active HIGH** H and V (MiSTer convention, matches shipped 3S-ARM VTG — see `vendor/Menu_MiSTer/rtl/native_video_timing.sv` lines 37–38 comments "active high (MiSTer convention)"). The downstream `sys_top.v` / `vga_out` pipeline handles any inversion needed for the VGA DAC and analog outputs. **Do not change polarity** when forking — inherit 3sx's exact VTG behavior.

**Spec/shipped divergence flagged:** `3sx-mister/docs/spec-fpga-native-video.md` lines 77–78 state "H sync: negative polarity / V sync: negative polarity" — but the shipped VTG asserts both sync lines **active-high** (see the comments at lines 37–38 and the sync assertion logic at lines 128/144 of `native_video_timing.sv`, which set `hsync <= 1'b1` / `vsync <= 1'b1` inside the sync region). The spec doc predates the shipped design; this plan follows the **shipped pattern** (active-high) because it is known-working on the 3sx hardware (CRTs + HDMI). The modeline notation `+hsync +vsync` in §2.4 reflects this.

### 2.6 Open question flagged

**OQ-1:** Should H_total be 391 (tighter blanking) or 396 (cleaner PLL rational fraction)? **Default: 391.** The choice interacts with step 3 (PLL math). See §11 Risks item R-1 for the modeline-fallback procedure if a specific CRT rejects the chosen H-total.

**OQ-2 (design-level, not a blocker):** Alternative V allocation (242 active + ~22 blanking total) would give V-freq closer to 60.00 Hz at higher pixel clock. We stick with V_total=264 to match the exact NTSC H-freq philosophy above. If a user reports engine stutter blaming the 59.587 Hz refresh, we can revisit — **but the engine will adapt via `TARGET_FPS`; no RTL change will be needed.**

---

## 3. PLL parameter derivation — 5CSEBA6U23I7 Fractional-N

Target: 6,152,098 Hz pixel clock at the DAC. The 3S-ARM shipping design uses a "PLL output → CE_PIXEL divider" pattern (CLK_VIDEO at 31.154 MHz, CE_PIXEL=÷4 to produce the 7.789 MHz pixel rate). We carry the same shape for Mania.

### 3.1 Design posture choice: match 3sx's integer-N style

Per `reference-native-analog-video.md` §4 "Why Not Fractional-N PLL":

> "The Cyclone V supports fractional-N PLLs, but the design uses integer-N only. Fractional-N introduces delta-sigma modulated jitter on the pixel clock, which causes visible horizontal position jitter on CRT displays."

We mirror that discipline: **integer-N only**, CE_PIXEL divider chosen to land on the target after a /4 divide. This preserves CRT image stability.

### 3.2 Math

Target pixel clock (at DAC) = **6,152,098 Hz** (from §2.3: 391 × 264 × 59.59949 Hz as the *aspirational* NTSC-exact target; achieved will be 6,150,794 Hz ≈ 212 ppm low, corresponding to 59.587 Hz V-freq — see the final fit below).
CLK_VIDEO (the PLL output) = pixel_clock × CE_PIXEL divider. If CE_PIXEL = ÷4 (matching 3sx's `always @(posedge CLK_VIDEO)` divide in menu.sv:189–198), CLK_VIDEO = **24,608,392 Hz**.

Cyclone V VCO range: 600–1300 MHz. M upper bound for Quartus 17 Lite is ~120 (per `reference-native-analog-video.md` §4).

Search: need integers (M, N, C) such that:
- 50 MHz × M / N is in [600, 1300]
- (50 × M / N) / C = 24,608,392 Hz → 50,000,000 × M / (N × C) = 24,608,392
- M ≤ 120
- ppm error < ~100 ppm (for frame-rate match drift < 1 stale frame per minute)

Rearrange: M / (N × C) = 24,608,392 / 50,000,000 = 0.49216784.

Trying N=1 with integer C and small M:

| M / N / C | Result (Hz) | Error from 24,608,392 Hz | ppm |
|---|---|---|---|
| 25 / 1 / 51 | 24,509,804 | −98,588 | −4006 ppm (bad) |
| 49 / 1 / 100 | 24,500,000 | −108,392 | −4405 ppm (bad) |
| **61 / 2 / 62** | 24,596,774 | −11,618 | **−472 ppm** (good) |
| **86 / 7 / 25** | 24,571,429 | −36,963 | −1502 ppm |
| **115 / 3 / 78** | 24,572,650 | −35,742 | −1453 ppm |
| 79 / 1 / 161 | (illegal — C > max) |  |  |

Extending to N > 5 (matching 3sx's M=81/N=5/C=26 style):
- **M / N / C = 91 / 77 / 25** → VCO = 50×91/77 = 59.09 MHz (**below VCO min**, rejected)
- **M / N / C = 105 / 5 / 43** → VCO = 1050 MHz ✓, CLK_VIDEO = 24,418,605 Hz → error −7729 ppm
- **M / N / C = 91 / 5 / 37** → VCO = 910 MHz ✓, CLK_VIDEO = 24,594,595 Hz → error −560 ppm, then ÷4 = 6,148,649 Hz (error vs target −3449 Hz = −561 ppm)

**Selected primary:** `M=61, N=2, C=62` → VCO = 1525 MHz — **EXCEEDS VCO MAX (1300 MHz)**. Rejected.

Re-tried with VCO compliance:
- **M=61, N=2, C=62:** VCO = 50 × 61 / 2 = 1525 MHz — FAIL (>1300).
- **M=43, N=2, C=44:** VCO = 1075 MHz ✓, CLK_VIDEO = 50 × 43 / (2 × 44) = 24,431,818 Hz → error −7210 ppm (bad).
- **M=91, N=5, C=37:** VCO = 910 MHz ✓, CLK_VIDEO = 24,594,595 Hz → error −561 ppm ✓.
- **M=64, N=3, C=40:** VCO = 50×64/3 = 1066.67 MHz ✓, CLK_VIDEO = 50×64/(3×40) = 26,666,667 Hz (much too high, bad).
- **M=62, N=3, C=42:** VCO = 1033.33 MHz ✓, CLK_VIDEO = 50×62/(3×42) = 24,603,175 Hz → error −211 ppm ✓ **STRONGER**.
- **M=82, N=4, C=42:** VCO = 1025 MHz ✓, CLK_VIDEO = 50×82/(4×42) = 24,404,762 Hz → error −8282 ppm (bad).

**Selected primary configuration:**
- **M = 62, N = 3, C = 42**
- VCO = 50 × 62 / 3 = **1033.33 MHz** (within 600–1300 MHz) ✓
- CLK_VIDEO = 50,000,000 × 62 / (3 × 42) = **24,603,174.6 Hz** ✓ (exact rational: 1550/63 MHz — used as-is in §6.8 wrapper-side PHASE_INC math)
- CE_PIXEL divider = ÷4 (same as 3sx)
- Actual pixel clock = 24,603,174.6 / 4 = **6,150,793.7 Hz**
- Target pixel clock = 6,152,098 Hz
- Error = **−1,304 Hz = −212 ppm**
- Resulting frame rate (with H_total=391, V_total=264) = 6,150,793.7 / 103,224 = **59.587 Hz**
- H-freq = 6,150,793.7 / 391 = **15,731 Hz** (vs NTSC-exact 15,734 Hz; 3 Hz low ≈ 200 ppm, well inside CRT tolerance).
- Delta from 3sx TARGET_FPS (59.59949 Hz) = −0.013 Hz.

**The "drift from 3sx" framing is the wrong lens.** Sonic Mania does not need to match 3sx's 59.59949 Hz — it only needs its FPGA and its userland pacer to agree. This plan aligns both at **59.587 Hz** (§2.3 and §6.7), so there is no drift: the engine and the FPGA tick at the same rate. The 59.587 Hz value is the shipping target for Phase 4 (including step 7 release build). If a user later reports audio/video drift traceable to the deviation from 59.60, a future phase can re-run a broader M/N/C search, but there is no Phase-4 requirement to do so.

### 3.3 Secondary configuration (finer-grained search, harder to hit in Quartus 17 Lite)

If the exhaustive search during /implement finds a better rational fraction (lower ppm error, within M ≤ 120 and VCO 600–1300 MHz):

- Use the Python script pattern from `3sx-mister/docs/reference-native-analog-video.md` §4 (described as "exhaustive computational search over M: 1–120, N: 1–50 … C: 1–512 … H_TOTAL: 488–520, V_TOTAL: 260–270").
- **Target:** pixel clock 6,152,098 Hz ± 100 Hz (ppm < 20 relative to 24.60 MHz CLK_VIDEO).
- The chosen M/N/C will be baked into the `pll_video.qsys` / `pll_video_0002.v` regenerated by the Quartus MegaWizard.

**The /implement step 2 will run this search before committing to the PLL IP parameters.** It is NOT a post-compile adjustment.

### 3.4 Concrete IP generation instructions

The shipped 3sx `pll_video_0002.v` parameterizes `altera_pll` via the frequency-string interface, not raw M/N/C. Verbatim excerpt (lines 1–25 of `vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v`):

```verilog
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
		.output_clock_frequency0("31.153846 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
```

**Important `operation_mode` note.** Line 20 contains `.operation_mode("direct")`. In the raw altera_pll IP, "direct" would force N=1 and produce CLK_VIDEO = 50 MHz × M / C directly (no N divider). However, the **shipped 3sx configuration is provably M=81 / N=5 / C=26** (producing 31.153846 MHz — see `reference-native-analog-video.md` §4, which calls out "PLL: 50 MHz × 81/5 = 810 MHz VCO, /26 = 31.1538 MHz") and yet `operation_mode("direct")` is present in the shipped `.v`. This demonstrates that **Quartus's frequency-string parser overrides the `operation_mode` string** at synthesis time: the tool picks whichever M/N/C hits the `output_clock_frequency0` string best within VCO and M/N/C bounds, regardless of the `operation_mode` label. The "direct" string is effectively stale/cosmetic on the shipped `.v` — it does not constrain the fit. Our Mania config relies on the same mechanism.

This plan's approach: **do NOT manually change `operation_mode`.** Leave it as `"direct"` exactly as shipped. Quartus will fit the new 24.603175 MHz string to whatever M/N/C it finds optimal (expected M≈62, N≈3, C≈42 per §3.2, or a nearby rational fraction), and the "direct" label will again be a cosmetic no-op — the same pattern shipped and working in 3S-ARM.

**Procedure:**

Option A (fastest, recommended for dev iteration): Hand-edit `vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` line 22, changing:
```verilog
.output_clock_frequency0("31.153846 MHz"),
```
to:
```verilog
.output_clock_frequency0("24.603175 MHz"),    // targets 6.150794 MHz at DAC after ÷4
```
Do not touch any other field, including `operation_mode("direct")`. Quartus picks M/N/C from the frequency string (shipped 3sx demonstrates this works even with `operation_mode("direct")` in the Verilog — the frequency string takes precedence). Target: `24.603175 MHz` at the CLK_VIDEO output. Expect Quartus to pick M≈62, N≈3, C≈42 (or close).

Option B (authoritative, recommended for final release RBF): Regenerate via Quartus Platform Designer (Qsys):
1. In the colima VM: `quartus --open_project Sonic_Mania.qpf`
2. Right-click the `pll_video` IP in Project Navigator → Edit.
3. Change Output 0 frequency string to `24.603175 MHz`. Leave input freq (50 MHz), `fractional_vco_multiplier("false")`, and `operation_mode` exactly as they are in the shipped 3sx `.v`. Do NOT try to manually set `operation_mode` to `"normal"` to "force" N>1 — Quartus's fit-from-frequency-string behavior handles this for us, and changing the string has historically required re-running the MegaWizard with matching VCO settings, which is unnecessary churn.
4. Regenerate. Quartus overwrites `pll_video_0002.v`.

**Verification:** after Quartus fit (step 2 compile), check the compile report for PLL fitter messages. Quartus will report the actual M/N/C it picked. Log these in the commit message or a comment for future reference. Expect the actual hit rate to be within 100 ppm of the target.

**Caveat:** the frequency-string approach gives Quartus freedom to hit 24.603175 MHz via a nearby rational fraction. The exact M/N/C Quartus picks may differ from the §3.2 candidate (62/3/42). That's fine as long as ppm error is acceptable.

### 3.5 Open question flagged

**OQ-3:** Exact M/N/C pair is an open search at /implement time. Plan fixes the *target pixel clock* at 6,152,098 Hz (corresponding to H_total=391 from §2) and the *achieved V-freq* at 59.587 Hz (corresponding to M=62/N=3/C=42). The /implement agent should adopt M=62/N=3/C=42 as the primary config — ~212 ppm H-freq miss, 59.587 Hz V-freq matched by userland `TARGET_FPS`, shippable. A fuller search is optional and not a gate. Document whichever is chosen in the regenerated `pll_video_0002.v` comment header.

---

## 4. Pixel reader parameter changes

File: `rtl/native_video_reader.sv` (forked from `3sx-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv`).

### 4.1 Burst size change

Current 3S-ARM (verified at `vendor/Menu_MiSTer/rtl/native_video_reader.sv:76-77`): 768 bytes/line = 96 beats × 8 B.
Mania: **640 bytes/line = 80 beats × 8 B.**

Exact edits to `native_video_reader.sv`:
```verilog
localparam [7:0]  LINE_BURST  = 8'd80;         // was 96 (768 B/line); Mania uses 640 B/line = 80 beats
localparam [28:0] LINE_STRIDE = 29'd80;        // was 96; DDRAM qword stride per scanline
```

### 4.2 Frame geometry

Verified at `native_video_reader.sv:78`:
```verilog
localparam [8:0]  V_ACTIVE    = 9'd240;        // was 224 (CPS3); Mania is 320×240
```

### 4.3 Buffer addresses (DDRAM 29-bit qword)

Per `reference-native-analog-video.md` §6 and `mister-port-plan.md` Phase 2 table. The 3sx reader stores the two buffers as DDRAM-qword addresses, not byte offsets:

```verilog
localparam [28:0] CTRL_ADDR   = 29'h07400000;  // unchanged (0x3A000000 >> 3)
localparam [28:0] BUF0_ADDR   = 29'h07400020;  // unchanged (0x3A000100 >> 3)
localparam [28:0] BUF1_ADDR   = 29'h07404B20;  // was 29'h07405440 for 3sx; (0x3A025900 >> 3)
```

**Do not change** `CTRL_ADDR` or `BUF0_ADDR` — both inherited from 3sx. The only address-level edit is `BUF1_ADDR`.

**Arithmetic check:** 153,600 bytes = 0x25800. Control region reserved at offset 0x000–0x0FF (256 bytes). Buf0 starts at 0x100, ends at 0x25900 - 1 = 0x258FF. Buf0 has 153,600 bytes, so Buf0 end byte = 0x100 + 0x25800 - 1 = 0x258FF ✓. Buf1 starts at 0x25900. Buf1 end = 0x25900 + 0x25800 - 1 = 0x4B0FF. Buf1 end is well below NV_DDR_REGION_SIZE = 0x60000. **Fits with 86,271 bytes (≈ 56 KB) of slack** ✓.

### 4.4 FIFO / back-pressure check

The 3S-ARM dcfifo is sized at **256 × 64-bit entries = 2048 bytes = 2.67 scanlines** (per `reference-native-analog-video.md` §3 — "FIFO depth: 256 × 64-bit = 2.67 scanlines of buffer").

For Mania, 2048 / 640 = **3.2 scanlines** of buffer. This is *more* headroom than 3sx had, so the FIFO does not need to grow. **No IP regeneration needed for the FIFO.**

### 4.5 Address arithmetic sanity

Per spec §6 and §3:
- DDR3 phys base: 0x3A000000 (unchanged)
- DDRAM_ADDR (29-bit) for buf0 start: 0x3A000100 / 8 = **29'h07400020** (unchanged — same address as 3sx)
- DDRAM_ADDR for buf1 start: 0x3A025900 / 8 = **29'h07404B20** (new — was `29'h07405440` for 3sx)
  - Arithmetic: 0x25900 = 153,856 decimal; 153,856 / 8 = 19,232 = 0x4B20; 0x07400000 + 0x4B20 = 0x07404B20 ✓
- DDRAM_ADDR increment per scanline: 640 / 8 = **80 = 0x50** (new — was 96 = 0x60 for 3sx)

### 4.6 Additional check — `NATIVE_VID` status bit and vertical line count CDC

Ensure the CDC logic in the 3sx reader that uses `new_line` to advance scanline count still operates at the Mania vertical rate: 240 lines × 59.587 Hz = ~14,301 `new_line` pulses/s, a *faster* rate than 3sx's (224 × 59.5995 = ~13,350 new_line/s — within 10%). The CDC is rising-edge from clk_pix (6.15 MHz) to clk_sys (100 MHz), slow-to-fast — inherently safe with 2-FF synchronizer. **No CDC change needed.**

### 4.7 Stale-frame timeout

3sx deasserts frame_ready after 30 consecutive stale vblanks (~500 ms). Keep that value unchanged for Mania.

---

## 5. Frame buffer geometry

Already covered in §4.3 and in `mister-port-plan.md` Phase 2 (the Linux side writes to the same contract). Repeating the arithmetic for an independent cross-check:

| Symbol | Value |
|---|---|
| NV_FRAME_WIDTH | 320 |
| NV_FRAME_HEIGHT | 240 |
| NV_FRAME_BYTES | 320 × 240 × 2 = **153,600** |
| NV_CTRL_OFFSET | 0x00000000 |
| NV_FEEDBACK_OFFSET | 0x00000040 |
| NV_BUF0_OFFSET | 0x00000100 (256 B reserved for ctrl+feedback+pad) |
| NV_BUF1_OFFSET | 0x00025900 (0x100 + 0x25800) |
| NV_DDR_REGION_SIZE | 0x00060000 (unchanged — contains both buffers + ctrl + ~56 KB slack) |
| NV_DDR_PHYS_BASE | 0x3A000000 (unchanged — shared with 3sx region, but no conflict since the two cores never run simultaneously) |

**Region contract with 3S-ARM:** Both cores use the same `0x3A000000` base. This is safe because **only one core is loaded on the FPGA at a time** — the RBF switch between them power-cycles the region. Nothing coexists.

---

## 6. Wrapper HPS binary

The wrapper is the HPS binary that sits between the MiSTer menu (`MiSTer` executable) and the game binary (`RSDKv5U` / Mania's runtime). It handles video init (pointedly NOT calling `video_fb_enable(1)` / `set_vga_fb(1)`, per native-video pattern), OSD, joystick SHM (deferred), and `execve()` of the game.

### 6.1 Source to adapt

Copy from `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/`:

```
thirdsarm_wrapper.cpp      → sonicmania_wrapper.cpp
thirdsarm_wrapper.h        → sonicmania_wrapper.h
thirdsarm_main.cpp         → sonicmania_main.cpp
thirdsarm_core_context.cpp → sonicmania_core_context.cpp
thirdsarm_core_context.h   → sonicmania_core_context.h
thirdsarm_support_stubs.cpp → sonicmania_support_stubs.cpp
```

(File `thirdsarm_support_stubs.cpp` verified present in `vendor/Main_MiSTer/` at /Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_support_stubs.cpp, 1125 bytes.)

**Mechanical rename sweep:**
- `thirdsarm_` → `sonicmania_` in all file/symbol names
- `3S-ARM` / `3s-arm` (case-preserving) → `Sonic Mania` / `sonic-mania` (with appropriate quoting for the spaced core name in path contexts)
- `SF33RD.AFS` → `Data.rsdk` in asset-path constants (for `kRuntimeArchive`)
- `/media/fat/games/3s-arm/` → `/media/fat/games/sonic-mania/`
- Wrapper binary name `MiSTer_3S-ARM` → `MiSTer_SonicMania` (no space, since filesystems accept it easily and MiSTer menu reads `[section-name] main=BinaryName` from INI without requiring spaces in the binary).

### 6.2 Key constants (in `sonicmania_wrapper.cpp` after rename)

```cpp
constexpr const char *kCoreName = "Sonic Mania";
constexpr const char *kRuntimeHome = "/media/fat/games/sonic-mania";
constexpr const char *kRuntimeBinary = "/media/fat/games/sonic-mania/bin/RSDKv5U";
constexpr const char *kRuntimeArchive = "/media/fat/games/sonic-mania/Data.rsdk";
constexpr const char *kRuntimeLibDir = "/media/fat/games/sonic-mania/lib";
constexpr const char *kLogDir = "/media/fat/games/sonic-mania/logs";
constexpr const char *kWrapperLogPath = "/media/fat/games/sonic-mania/logs/osd-wrapper.log";
constexpr const char *kLastRunLogPath = "/media/fat/games/sonic-mania/logs/last-run.log";
```

### 6.3 RBF filename contract

The MiSTer menu-to-wrapper handoff reads `[Sonic Mania] main=...` from MiSTer.ini and loads the RBF whose basename matches the section name in `_Other/`. **The core is `Sonic Mania.rbf` with a space** (see §7 and `mister-port-plan.md` Decision #7). Verify via the test in step 5 that `MiSTer` resolves the space-containing path correctly. If any tool fights the space, fall back to `SonicMania.rbf` (also acceptable per Decision #7) and change the INI section name to match (`[SonicMania]`).

### 6.4 Video init path

Keep 3sx's native-video discipline: `sonicmania_wrapper.cpp` does **not** call `video_fb_enable(1)` or `set_vga_fb(1)`. Leave those lines commented/removed exactly as 3sx does, so `vga_fb` stays at 0 and the DAC mux routes core video through `vga_o` (see spec §5.1 "DAC Mux Logic Analysis"). The `vga_scaler=0` invariant is enforced by the user's INI (§7).

**`THIRDSARM_NATIVE_VIDEO=1` → `SONIC_MANIA_NATIVE_VIDEO=1`:** if 3sx's current code relies on this environment variable to gate `NativeVideoWriter_Init()`, rename accordingly in the wrapper code *and* in any userland gate. **This is a /implement-time check** — grep `3sx-mister/src` for `THIRDSARM_NATIVE_VIDEO` to confirm the gate exists.

### 6.5 Input SHM (deferred)

`mister_joy_shm.h` and the `/dev/shm/thirdsarm-joy` contract are used by 3sx for wrapper-driven OSD menus. **Deferred for Phase 4** per the plan scope — Mania will use SDL2 gamepad directly until polish phase (see `mister-port-plan.md` Phase 7 row "Wrapper SHM input"). Keep the SHM-related code commented or `#ifdef DEFERRED_WRAPPER_SHM` gated during the rename, so a future phase can re-enable it.

### 6.6 Build flow for the HPS wrapper

Mirror `3sx-mister/tools/mister-wrapper/build-hps.sh`, adapting:
- Pinned upstream Main_MiSTer commit (inherited: `3380931329b8acb442bd3d35a24d89f88641b7cf` per `3sx-mister/docs/mister-wrapper.md` §"Pinned HPS Foundation"). Use the same commit unless /implement finds a reason to advance.
- Overlay file manifest: `tools/mister-wrapper/main-mister-overlay.files` — edit to reference the renamed files. 3sx's shipped manifest lists 5 entries (`thirdsarm_core_context.{cpp,h}`, `thirdsarm_main.cpp`, `thirdsarm_wrapper.{cpp,h}`). **Add `sonicmania_support_stubs.cpp`** to the Mania manifest — 3sx has that file at `vendor/Main_MiSTer/thirdsarm_support_stubs.cpp` but the shipped manifest omits it (likely because it's compiled directly into MiSTer's main binary via another include path); verify at /implement time whether the Mania build needs it enumerated. If yes, add.
- Build target name: `MiSTer_SonicMania` (instead of `MiSTer_3S-ARM`).
- Overlay patch: copy `3sx-mister/tools/mister-wrapper/main-mister-full-menu.patch` and `Makefile.full.3s-arm` → `Makefile.full.sonic-mania`. **Extend the patch** to include the `video.cpp` CLK_VIDEO edit from §6.8 (either as an additional hunk in `main-mister-full-menu.patch` or as a new overlay file `video.cpp` that replaces the upstream).

Sonic Mania tree layout: **`/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/`** (new dir; copy the 3sx wrapper build scripts into it, renaming as above). The HPS binary output will be `build/mister-wrapper-hps/MiSTer_SonicMania`.

### 6.7 Wrapper launch contract changes

The wrapper's `execve()` call invokes the game binary. For Mania:
- Game binary path: `/media/fat/games/sonic-mania/bin/RSDKv5U` (per `mister-port-plan.md` Phase 0 exit criteria).
- Required env vars (from 3sx wrapper experience):
  - `SDL_VIDEODRIVER=dummy` (we render to DDR3 directly, not to an SDL window)
  - `LD_LIBRARY_PATH=/media/fat/games/sonic-mania/lib`
  - `SONIC_MANIA_HOME=/media/fat/games/sonic-mania`
  - `SONIC_MANIA_NATIVE_VIDEO=1` (activate NativeVideoWriter path)
- On child exit or signal, restart into `MiSTer` with `menu.rbf` (identical 3sx pattern).
- **`TARGET_FPS` / engine pacing constant:** if the Mania runtime reads a `TARGET_FPS`-equivalent from env or config, set it to **59.587** Hz (matching the §3.2 M=62/N=3/C=42 PLL fit), not the 3sx value of 59.59949 Hz. See §2.3 for the derivation; the Linux-userland pacer must match the FPGA refresh exactly to avoid drift.

### 6.8 `video.cpp` CLK_VIDEO hardcode (ARM-side YC subcarrier)

**Critical:** `vendor/Main_MiSTer/video.cpp` hardcodes `core_CLK_VIDEO` when `native_video_enabled` is true. For 3sx this value is `405.0/13.0 = 31.153846 MHz` (the exact CLK_VIDEO the shipped 3sx PLL produces). The value drives the YC subcarrier `PHASE_INC` and `COLORBURST_START`/`COLORBURST_END` computations (lines 3113–3116 in 3sx's `video.cpp`), which in turn control **S-Video color** generation. If not updated for Mania's new CLK_VIDEO, the subcarrier phase is synthesized with a factor of `31.1538 / 24.6032 ≈ 1.266` off and **S-Video output will be grayscale or wrong-color** on a CRT.

**File to modify:** `vendor/Main_MiSTer/video.cpp` (in our Sonic Mania wrapper tree — this is part of the HPS-side overlay files inherited from 3sx; the Mania fork must carry its own edited copy).

**Exact edit (lines 3072–3073 in the 3sx file; locate the equivalent in the overlaid Mania copy):**

```cpp
// was (3sx):
const double core_CLK_VIDEO = native_video_enabled
    ? (405.0 / 13.0)  // dedicated pll_video: 50 * 81/5 / 26 = 31.153846 MHz
    : ...

// new (Sonic Mania):
const double core_CLK_VIDEO = native_video_enabled
    ? (1550.0 / 63.0) // dedicated pll_video: 50 * 62/3 / 42 = 24.603175 MHz
    : ...
```

`1550.0 / 63.0 = 24.60317460317...` MHz is the exact rational for the M=62/N=3/C=42 PLL target. Using the rational (not the rounded decimal) keeps the PHASE_INC computation bit-exact across toolchain/optimizer differences.

**Wrapper-tree file-modification list (summary for step 4 /implement):**
- `vendor/Main_MiSTer/sonicmania_wrapper.cpp` (renamed from thirdsarm_wrapper.cpp)
- `vendor/Main_MiSTer/sonicmania_wrapper.h`
- `vendor/Main_MiSTer/sonicmania_main.cpp`
- `vendor/Main_MiSTer/sonicmania_core_context.{cpp,h}`
- `vendor/Main_MiSTer/sonicmania_support_stubs.cpp` (renamed from thirdsarm_support_stubs.cpp)
- **`vendor/Main_MiSTer/video.cpp`** — edit CLK_VIDEO hardcode at lines 3072–3073 as above. This is an overlay/patch on the upstream Main_MiSTer `video.cpp`; follow the same overlay pattern 3sx uses (apply as a local delta via the `main-mister-full-menu.patch` or an equivalent).

This change is cross-referenced in §11 R-5 — the S-Video grayscale risk is **no longer "Low likelihood"** without this wrapper edit; it is a **pre-required fix** without which S-Video will be wrong.

---

## 7. `.ini` contract (user-facing)

MiSTer users edit `/media/fat/MiSTer.ini` to add a section for the new core. The section name matches the RBF basename (with or without space, matching Decision #7).

### 7.1 Primary contract (with space in core name)

```ini
[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0
```

### 7.2 Fallback contract (if space breaks something)

```ini
[SonicMania]
main=MiSTer_SonicMania
vga_scaler=0
```

**In that fallback case, rename the RBF to `SonicMania.rbf` too** — the MiSTer menu resolves `[section] → _Other/section.rbf`. Keep the INI section name and RBF basename identical.

### 7.3 Critical invariant

**`vga_scaler=0` is required**, not optional. Without it the FPGA routes HDMI-scaler output to the VGA DAC and both grayscale S-Video on CRT and wrong aspect ratio result (see `reference-native-analog-video.md` §12 "Critical Invariants" and `mister-port-plan.md` Phase 4 exit criteria). The wrapper should log a warning at startup if `get_vga_scaler()` returns 1; the wrapper cannot force-override a user's INI but can surface the problem.

### 7.4 Naming asymmetry (intentional)

Three related names deliberately use different conventions:

| Artifact | Name | Why |
|---|---|---|
| Quartus project | `Sonic_Mania` (underscore) | Quartus `PROJECT_REVISION` identifiers disallow spaces; underscores are mandatory for the build system. |
| Shipped RBF | `Sonic Mania.rbf` (space) | MiSTer menu convention matches section name → RBF basename. Space is more human-readable in the `_Other/` listing. Fallback `SonicMania.rbf` is acceptable per Decision #7. |
| Wrapper binary | `MiSTer_SonicMania` (concat, no space, no underscore between words) | Binary filename portability (tooling and shell quoting simpler without spaces) and matches the MiSTer convention of `MiSTer_CoreName` for HPS wrapper binaries. |

The deploy step (§10.1) renames `Sonic_Mania.rbf` (Quartus output) → `Sonic Mania.rbf` (MiSTer path) at SCP time. The INI section `[Sonic Mania]` matches the RBF basename, not the wrapper binary name — this is standard MiSTer behavior.

### 7.5 Quirks to document for users

- MiSTer.ini is case-sensitive for section names; `[sonic mania]` (lowercase) will be ignored silently. Document the exact `[Sonic Mania]` casing.
- If the user's global `MiSTer.ini` sets `vga_scaler=1` at the top, the per-core section override must come AFTER the `[MiSTer]` section, not before. Document the ordering.
- Users on HDMI-only do NOT strictly need `vga_scaler=0` — the scaler will upscale our 320×240 core video to HDMI cleanly — but we still require it to keep a single code path and avoid the S-Video regression for any CRT user.

---

## 8. Repo layout

| Location | Role |
|---|---|
| `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/` | Sonic Mania wrapper HPS source (`sonicmania_wrapper.cpp`, `sonicmania_main.cpp`, `sonicmania_core_context.{cpp,h}`, adapted from 3sx's `vendor/Main_MiSTer/`). **New directory** for this project. |
| `/Users/sb/Developer/sonic-mania-mister/vendor/Menu_MiSTer/` | Quartus project seed — **copied from 3sx's `vendor/Menu_MiSTer/`** (which was the Menu core fork + native-video additions that shipped as 3S-ARM). Renamed project: `Sonic_Mania`. **New directory** for this project. |
| `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/` | Build scripts: `build-core.sh`, `build-hps.sh`, `package-wrapper.sh`, mirroring 3sx's. **New directory** for this project. |
| `/Users/sb/Developer/sonic-mania-mister/docs/` | Plan docs (this file) + any runtime docs added during later phases. |
| colima `quartus2` VM, path `/home/sb.linux/build/sonic-mania-mister-core/` | Quartus build output. Not synced back to repo automatically — only the final RBF artifact gets pulled back (into `build/mister-wrapper-core/` on macOS). |

**Pinning philosophy:** mirror 3sx's — the Menu_MiSTer seed is pinned to the 3sx-validated commit (`b0a2b9298d7a7a355e4e0a97277d3d4218eb2f55` per 3sx `docs/mister-wrapper.md`). The Main_MiSTer upstream is pinned to `3380931329b8acb442bd3d35a24d89f88641b7cf`. Both shown in `vendor/*.UPSTREAM.md` metadata files.

---

## 9. Build procedure

### 9.1 FPGA (Quartus in colima VM)

Per `feedback-quartus-nohup.md` and `feedback-quartus-fast-build.md`:

```sh
# From the macOS host.
colima --profile quartus2 ssh -- bash -lc '
  export PATH=/home/sb.linux/intelFPGA_lite/17.0/quartus/bin:$PATH LC_ALL=C LANG=C &&
  cd /Users/sb/Developer/sonic-mania-mister &&
  nohup env OUTPUT_DIR=/home/sb.linux/build/sonic-mania-mister-core \
    bash tools/mister-wrapper/build-core.sh --fast --seed menu \
    > /home/sb.linux/build/sonic-mania-build.log 2>&1 &
  echo "Quartus build PID: $!"
'
```

**Expected wall-clock:** 40–90 minutes with `--fast` on the colima VM. Do NOT `tail -f` from the host over SSH during the build — SSH connection drops kill nohup's parent and the build dies. Poll periodically with a separate `ssh` that reads the log tail:

```sh
colima --profile quartus2 ssh -- tail -n 200 /home/sb.linux/build/sonic-mania-build.log
```

**Check-in rule:** wait for log line `Quartus Prime Shell was successful.` or `Quartus Prime Shell command failed.`. Only then proceed.

### 9.2 Expected artifact

`/home/sb.linux/build/sonic-mania-mister-core/Sonic_Mania.rbf` (underscore — Quartus convention). The deploy step (§10) renames to `Sonic Mania.rbf` (with space) during SCP.

### 9.3 Release flavor (no `--fast`) for final ship

For Phase 4's final step (step 7), drop `--fast`. Expected wall-clock: 2+ hours. Per memory rules, DO NOT kick this off without user approval — the user signs off on the flip from `--fast` to release first.

### 9.4 HPS wrapper build (independent, fast)

Mirrors 3sx's build-hps.sh. Runs locally on macOS via Docker fallback, or on a local cross-toolchain if available. Expected wall-clock: ~10–15 minutes.

```sh
tools/mister-wrapper/build-hps.sh --check-env  # sanity
tools/mister-wrapper/build-hps.sh              # build
```

Artifact: `build/mister-wrapper-hps/MiSTer_SonicMania` (ARM hard-float ELF).

---

## 10. Test procedure

**Precondition:** Phase 0–3 Linux-side Track L has not shipped yet at the time Phase 4 completes. We test the FPGA path independently with a **synthetic test frame writer** — a tiny armhf binary that writes a known 320×240 RGB565 pattern to DDR3 at `0x3A000000` and flips the control word. This is written at /implement step 5 as a 60-line C program, not a userland engine port.

### 10.1 Deploy (pass 1 — HDMI-only validation)

```sh
# From macOS host. MISTER_PASSWORD=1 (see reference-mister-credentials.md)
sshpass -p 1 scp \
  /Users/sb/Developer/sonic-mania-mister/build/mister-wrapper-core/Sonic_Mania.rbf \
  root@192.168.1.188:"/media/fat/_Other/Sonic Mania.rbf"

sshpass -p 1 scp \
  build/mister-wrapper-hps/MiSTer_SonicMania \
  root@192.168.1.188:/media/fat/MiSTer_SonicMania

# Install INI section (via remote ini helper if wrapper ships one; otherwise
# edit /media/fat/MiSTer.ini manually). See §7.
sshpass -p 1 ssh root@192.168.1.188 \
  'cat >> /media/fat/MiSTer.ini << EOF

[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0
EOF'
```

**NEVER** use `rsync --delete` — see `feedback-no-rsync-delete.md`.

### 10.2 Boot the core — HDMI check

1. On the MiSTer, navigate to the `_Other/` menu. Select "Sonic Mania". Core should load.
2. On HDMI: expect a **dark screen with stable sync** (the wrapper starts but no frames are being written — the FPGA reader blanks per the 30-stale-vblank rule).
3. SSH in, launch the test-frame writer:
   ```sh
   sshpass -p 1 ssh root@192.168.1.188 \
     '/media/fat/games/sonic-mania/test-frame-writer &'
   ```
4. HDMI should now show the test pattern (typically a checkerboard or color-bar gradient).

**Pass criteria (HDMI):**
- Stable sync, no rolling, no interlace artifacts.
- 4:3 aspect ratio on a correctly-configured HDMI TV (with aspect-ratio auto-detect or manual 4:3 lock).
- Expected resolution: 320×240 scaled by the MiSTer ascal to whatever the user's HDMI mode is (1080p, 4K, etc.) — that's the standard scaler path; we verify it scales cleanly.
- OSD overlay test: press the MiSTer menu button (F12 / OSD key). Wrapper OSD should appear composited over the test pattern (per `reference-native-analog-video.md` §5.5 — OSD is automatic on the core VGA path).

### 10.3 CRT S-Video check

**Only attempted if an S-Video or composite CRT is physically connected to the user's MiSTer.** Assumes user has the standard MiSTer analog I/O board.

1. Verify `vga_scaler=0` in the user's MiSTer.ini (both the global `[MiSTer]` section AND the per-core `[Sonic Mania]` section).
2. Boot the core, launch test-frame writer.
3. Expected output on CRT:
   - Stable H/V sync (CRT does not roll or tear).
   - Color (red test patch shows red, green shows green, blue shows blue — not grayscale).
   - 4:3 aspect ratio (320 pixels × 240 lines, centered on the CRT).

**`vga_scaler` runtime verification (run BEFORE attempting S-Video):** after the wrapper boots the core:
1. SSH in and tail the wrapper log for the `vga_scaler` state line the wrapper emits at startup:
   ```sh
   sshpass -p 1 ssh root@192.168.1.188 \
     'grep -i "vga_scaler\|scaler" /media/fat/games/sonic-mania/logs/osd-wrapper.log | tail -20'
   ```
2. If the wrapper doesn't log the scaler state, probe the scaler control register directly via `devmem2` on the MiSTer. The scaler-enable bit lives in the `cfg` register region (details in `3sx-mister/docs/spec-fpga-native-video.md` §5 "DAC Mux Logic Analysis" — the cfg bitfield mapping is stable across cores).
3. Confirm `vga_scaler=0` appears under the active core's INI section via `grep vga_scaler /media/fat/MiSTer.ini`.

**If grayscale appears:** the `vga_scaler=0` invariant is not in effect **OR** the `video.cpp` CLK_VIDEO hardcode was not updated (see §6.8 — this is the most likely cause for Mania specifically). Debug sequence:
1. Verify §6.8 edit was applied: `strings build/mister-wrapper-hps/MiSTer_SonicMania | grep -E "24.603|1550.0/63"` — should show evidence of the Mania value baked in. If not, rebuild wrapper with the §6.8 edit applied.
2. SSH to MiSTer: `cat /media/fat/MiSTer.ini | grep vga_scaler` — should show `vga_scaler=0` under the active core section.
3. Check wrapper log: `cat /media/fat/games/sonic-mania/logs/osd-wrapper.log` — look for startup-time warning from wrapper about `vga_scaler`.
4. If §6.8 and `vga_scaler=0` both look correct but grayscale persists, re-examine the DAC mux chain in `menu.sv` — see `spec-fpga-native-video.md` §5.4 for the S-Video signal path.

**If sync fails on CRT:** see §11 Risks item R-1 — go back to step 2 and try an alternate H_total.

### 10.4 Latency check (optional)

Use `THIRDSARM_VSYNC_FEEDBACK`-equivalent pattern: the userland test-writer can record the nanosecond timestamp when the control word is written and the FPGA's feedback word reports the frame counter on next vblank. Expected round-trip: < 16.8 ms (one frame). This is informational only for Phase 4 — the Linux-side Track L Phase 6 handles closed-loop frame pacing.

### 10.5 Exit criteria

Phase 4 is complete when:
1. `Sonic Mania.rbf` (or `SonicMania.rbf` fallback) loads on MiSTer without error. ✓
2. Wrapper binary `MiSTer_SonicMania` launches via the core and stays running. ✓
3. Test-frame writer produces visible output on HDMI: 320×240, stable sync, 4:3 aspect. ✓
4. Test-frame writer produces visible output on CRT (if CRT available): 320×240, stable sync, 4:3 aspect, **color** (not grayscale). ✓
5. MiSTer OSD overlays correctly on both outputs. ✓

---

## 11. Risks

### R-1: CRT rejects the modeline (sync fails)
- **Impact:** CRT goes blank, out-of-sync, or shows "NO SIGNAL." User cannot play on CRT.
- **Likelihood:** Medium. 6.15 MHz pixel clock is unusually low (most arcade-CRT-friendly cores run 7–8 MHz). Some consumer CRTs with tight NTSC filtering may refuse. PVM/BVM and Blast City should be fine per 3sx experience at 7.79 MHz.
- **Mitigation:**
  1. First fallback: try H_total = 396 or 408 (raises pixel clock to 6.23 MHz / 6.42 MHz), iterate PLL math, rebuild with `--fast`.
  2. Second fallback: Family B (NES-derivative) — H_total = 341, pixel clock 5.37 MHz. Lower clock, but H_total=341 is extensively CRT-tested in NES/Genesis cores.
  3. Third fallback: document that Mania requires a specific CRT generation and ship anyway. Acceptable for a hobby project.

### R-2: Mania HUD cropped at 320 active pixels
- **Impact:** Cosmetic — title cards, transitions, and the act-name banner are sized for `pixWidth >= ~400`. At 320, elements will clip at screen edges.
- **Likelihood:** High (this is how the engine works — see `mister-port-plan.md` Phase 4 decision-consequence note under Decision #1).
- **Mitigation:** Phase 5 / Phase 7 cosmetic pass only. **Not a Phase 4 blocker.** Mania remains playable.

### R-3: DDR3 buffer offset collision with 3S-ARM reserved regions
- **Impact:** If a user boots 3S-ARM after booting Sonic Mania (or vice versa) without a power-cycle in between, stale frame data from one could leak into the other's DDR3 region.
- **Likelihood:** Low. The RBF switch on MiSTer implicitly clears FPGA state, and the DDR3 region is rewritten before the first frame by each core's NativeVideoWriter_Init (memset to 0 per `3sx-mister/src/port/sdl/native_video_writer.c:44-45` — the file is only 153 lines; the dual-buffer memset is near the top of the init routine).
- **Mitigation:** Verify `NativeVideoWriter_Init` clears both buffers before first use — inherited from 3sx, already does this. **No action for /implement.**

### R-4: PLL fails to lock
- **Impact:** Core boots but no video; `pll_vid_locked` signal stays 0.
- **Likelihood:** Low if M/N/C are within Quartus-accepted ranges. Historically 3sx had issues with M>120 (rejected by Quartus 17 Lite). Our selected M=62 is well under.
- **Mitigation:** /implement step 2 must verify `pll_video_0002.v` synthesizes cleanly in `--fast` and `pll_vid_locked` is asserted by time `cfg[15]` is set (examined via ILA / SignalTap if available, or by checking the test-frame writer produces output on HDMI — PLL lock is transitive through NATIVE_VID gating).

### R-5: Grayscale / wrong-color S-Video on CRT
- **Impact:** Grayscale (or visibly mis-tinted color) on S-Video when booted to a CRT.
- **Likelihood (updated):** **Medium-High if `video.cpp`'s `core_CLK_VIDEO` hardcode is not updated.** Not just an inherited `vga_scaler=0` issue — §6.8 documents a **pre-required wrapper edit** to change `core_CLK_VIDEO = 405.0/13.0` (31.1538 MHz, 3sx value) to `1550.0/63.0` (24.6032 MHz, Mania value). That constant drives the YC subcarrier `PHASE_INC` and `COLORBURST_START/END`. Running with the 3sx value against a Mania-clocked core produces subcarrier phase skewed by ~1.266× — the S-Video color will be wrong.
- **Mitigation:**
  1. **Confirm §6.8 edit has been applied** before the first S-Video test. This is the primary fix — not optional.
  2. Verify `vga_scaler=0` is present in the user's MiSTer.ini and the per-core section.
  3. Do NOT patch the S-Video / YC encoder logic (`yc_out.sv`) itself. Inherit whatever 3sx shipped. The FPGA-side YC chain is pixel-clock-agnostic; all subcarrier phase math lives ARM-side in `video.cpp`.
  4. If grayscale persists after §6.8 and `vga_scaler=0` are both confirmed, grep the inherited menu.sv for `yc_out` / `vga_fb_yc_en` — should match 3sx's working version (commit `bc77d52a` in 3sx fixed the inherited S-Video path).

### R-6: Wrapper startup races core video path
- **Impact:** Wrapper calls `video_fb_enable(1)` accidentally (via inherited Main_MiSTer code), briefly flashes the scaler output, confuses CRT.
- **Likelihood:** Low-medium. 3sx wrapper has careful guards; any rename-induced regression risks re-breaking them.
- **Mitigation:** During step 4 (wrapper adaptation), grep for `video_fb_enable` and `set_vga_fb` calls and confirm they remain conditional on a "not native video" branch (or removed entirely). Cross-check against `3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.cpp:1669-1677` (the known-working section).

### R-7: Quartus build takes unexpectedly long or fails
- **Impact:** 2+ hour iterations, schedule drift.
- **Likelihood:** Medium for first build, low subsequently (project is already Menu_MiSTer-shape).
- **Mitigation:** Always use `--fast` during dev per memory. First build after a Quartus IP regeneration can take longer because Quartus re-maps the PLL; subsequent incremental builds are faster. Budget 90 min for step 2, not 60.

### R-8: Modeline math has three equally valid answers (§2.6 OQ-1 and §3.5 OQ-3)
- **Impact:** /implement agent picks arbitrarily, may diverge from user preference.
- **Likelihood:** Certain — OQ-1 and OQ-3 are genuine open questions.
- **Mitigation:** This plan *specifies* H_total = 391 and the M=62/N=3/C=42 PLL config. The /implement agent should follow the plan as written unless a hard technical block is hit (Quartus rejects the PLL config, CRT rejects the H-total). Any divergence must be flagged to the user before continuing.

### R-9: Core filename with space breaks a MiSTer tool
- **Impact:** Core won't load from `_Other/Sonic Mania.rbf`; the menu doesn't find it.
- **Likelihood:** Low. MiSTer's menu code generally handles spaces in section names (see 3sx pattern which works). But some build scripts or deploy scripts might quote badly.
- **Mitigation:** Decision #7 already sanctions `SonicMania.rbf` as fallback. If step 5 shows the space-version doesn't load, rename at deploy time, update the INI section name to match, re-test.

---

## 12. Exit criteria (Phase 4)

Defined in §10.5. Restated for top-level clarity:

1. **`Sonic Mania.rbf` (or `SonicMania.rbf` fallback) loads on MiSTer** from `/media/fat/_Other/` via the menu.
2. **Wrapper binary `MiSTer_SonicMania` launches** and stays running (no crash, no spontaneous return to menu).
3. **320×240 native video visible on HDMI** using a synthetic test-frame writer. Stable sync. Correct 4:3 aspect.
4. **320×240 native video visible on CRT via S-Video** (if a CRT is available on the test setup). Stable sync. 4:3 aspect. **COLOR**, not grayscale — this is the `vga_scaler=0` path working.
5. **MiSTer OSD overlays correctly** on top of either output (HDMI or CRT) when the user presses the OSD key.

Anything beyond this — actual Mania gameplay, sound, input, performance — is Track L (Phase 5+) and is NOT a Phase 4 gate.

---

## 13. The seven /implement steps (detailed)

### Step 1 — Fork 3S-ARM Quartus project, rename to Sonic_Mania

**Why it matters:** Baseline for everything that follows. We can't regenerate IP or change parameters without a project to work in.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-core.sh` (the 3sx build driver, especially `configure_seed()`, `prepare_source()`, and the CONF_STR-patching section)
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/menu.qpf` (Quartus project file)
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/files.qip`
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/menu.sv` (top-level RTL, contains CONF_STR)

**Files to create/modify:**
- NEW `vendor/Menu_MiSTer/` — rsync-copy from `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/`, preserving directory structure.
- NEW `vendor/Menu_MiSTer.UPSTREAM.md` — metadata file recording the 3sx seed commit.
- NEW `tools/mister-wrapper/build-core.sh` — adapted from 3sx's. Changes:
  - `PROJECT_NAME="Sonic_Mania"` (was `3S-ARM`)
  - `CONF_STR_TOKEN="MENU;UART31250,MIDI;"` is the **search string** in `menu.sv` that the Ruby patch-step rewrites; the script substitutes it with `"${project};;"` → for Mania, the patched CONF_STR becomes `"Sonic Mania;;"`. This token stays the same as 3sx because the seed file (`menu.sv`) still contains the untouched MENU CONF_STR until the patch step runs.
  - Output artifact path uses `Sonic_Mania.rbf` (underscore in build system; deploy-time rename to space).
- NO MANUAL EDIT of `vendor/Menu_MiSTer/menu.qpf` or `menu.sv` at this step — the Ruby patch in `build-core.sh --prepare-source` does the rename by copy-into-staging-area and rewrite. This is exactly the 3sx pattern (see `3sx-mister/tools/mister-wrapper/build-core.sh` lines 120–158).
- MODIFY the copied build-core.sh so that running `bash tools/mister-wrapper/build-core.sh --prepare-source --seed menu` produces, in `build/mister-wrapper-core/src/`: a `Sonic_Mania.qpf` with `PROJECT_REVISION = "Sonic_Mania"`, a patched `Sonic_Mania.sv` (or `menu.sv`, depending on template rename convention) with CONF_STR = `"Sonic Mania;;"`, and a `files.qip` referencing `Sonic_Mania.sdc` / `Sonic_Mania.sv`.

**Success criteria:**
- In the colima VM: `quartus_sh --flow check Sonic_Mania.qpf` completes without errors (a "check" flow, not a full compile, verifies the project opens and its file manifest is intact).
  ```sh
  colima --profile quartus2 ssh -- bash -lc '
    export PATH=/home/sb.linux/intelFPGA_lite/17.0/quartus/bin:$PATH &&
    cd /home/sb.linux/build/sonic-mania-mister-core/src &&
    quartus_sh --flow check Sonic_Mania
  '
  ```
- `grep -r "thirdsarm\|3S-ARM\|3s-arm" tools/mister-wrapper/build-core.sh` returns no matches.
- `grep -r "Sonic Mania" vendor/Menu_MiSTer/menu.sv` finds the patched CONF_STR.

**Dependencies:** None (this is the first step).

**What NOT to do:**
- Do NOT modify any RTL parameters yet (dimensions, PLL, burst). That's step 2.
- Do NOT launch a full Quartus compile — only `check` flow.
- Do NOT change the wrapper HPS binary — that's step 4.

**Fallback on failure:**
- If rename introduces a project-file inconsistency Quartus rejects, diff the output `.qpf`/`.qsf` against the 3sx original and fix missing references.
- If the CONF_STR patch fails to apply (3sx uses a specific token that differs from fresh Menu_MiSTer), fall back to a manual edit of menu.sv and commit.

---

### Step 2 — Regenerate pll_video IP + update VTG parameters

**Why it matters:** This is the core modeline change. After this step compiles, the FPGA *timing generator* is Mania-ready even if DDR3 reader is not.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/docs/spec-fpga-native-video.md` §2.2 (VTG module)
- `/Users/sb/Developer/3sx-mister/docs/reference-native-analog-video.md` §4 (shipping PLL config), §5 (shipping VTG config)
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/rtl/native_video_timing.sv` (the shipped VTG)
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` (the shipped PLL config)
- This plan §2 (modeline math) and §3 (PLL math)

**Files to create/modify:**
- MODIFY `vendor/Menu_MiSTer/rtl/native_video_timing.sv` — exact edits (current 3sx values cited from file lines 62–72):
  ```verilog
  localparam H_ACTIVE = 320;   // was 384
  localparam H_FP     = 14;    // was 23
  localparam H_SYNC   = 32;    // was 38
  localparam H_BP     = 25;    // was 50
  localparam H_TOTAL  = 391;   // was 495   (320+14+32+25)

  localparam V_ACTIVE = 240;   // was 224
  localparam V_FP     = 6;     // was 15
  localparam V_SYNC   = 3;     // unchanged
  localparam V_BP     = 15;    // was 22
  localparam V_TOTAL  = 264;   // unchanged (240+6+3+15)
  ```
  Update the file header comment block (lines 5–15) to reflect the new modeline:
  - `// 320x240 active area @ ~59.587 Hz (391x264 total)`
  - `// CLK_VIDEO: 24.6032 MHz (target); pixel clock: 24.6032/4 = 6.1508 MHz`
  - `// H: 320 active + 14 FP + 32 sync + 25 BP = 391 total`
  - `// V: 240 active + 6 FP + 3 sync + 15 BP = 264 total`
  - `// Frame rate: 6,150,794 / (391 * 264) = 59.587 Hz`
  - `// H_freq: 6,150,794 / 391 = 15,731 Hz (within NTSC tolerance; target 15,734)`

  The hcount/vcount bit-widths (10 and 9 bits) already fit 391/264 without change.
  **Do not change** sync polarity (active high, MiSTer convention — see §2.5 of this plan).
  **Do not change** `h_offset`/`v_offset` OSD-position port signatures — they're harmless carry-forward.

- EDIT `vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` per §3.4 Option A. Change only:
  - Line 22: `.output_clock_frequency0("31.153846 MHz")` → `.output_clock_frequency0("24.603175 MHz")`
  - Update any top-of-file comment that documents the old frequency.

- NO CHANGE to `vendor/Menu_MiSTer/menu.sv`: the CLK_VIDEO-rate-dependent YC subcarrier PHASE_INC is computed by the ARM-side (`video.cpp`), not by the FPGA. That adjustment lives in the wrapper (step 4).

**Success criteria:**
- Quartus `--fast` compile completes without errors.
- Output log contains `Successful`.
- `pll_video_0002.v` top comment matches the selected M/N/C.
- Static timing analysis (`quartus_sta`) shows no slack violations on the new clock network. Acceptable if CE_PIXEL-derived nets are within 0–100 ns of setup slack (standard for a /4-divided 24.6 MHz clock).

**Dependencies:** Step 1 complete.

**What NOT to do:**
- Do NOT change pixel reader parameters yet — that's step 3.
- Do NOT commit the .qar archive (Quartus project archive) — just the source files. The .qar is build-output, not source.
- Do NOT skip the PLL rational-fraction search beyond what §3.2 provides unless M=62/N=3/C=42 is accepted as the stopping point.

**Fallback on failure:**
- If PLL IP regeneration fails (Quartus rejects the M value), try progressively smaller M: M=42, N=2, C=42.6 → round to C=43 → new pixel clock 6,110,048 Hz (−600 ppm, cosmetic but acceptable for dev). Iterate.
- If VTG parameter change breaks synthesis (unlikely — all values stay in same bit-widths as 3sx), check for stray hardcoded `224` or `384` in surrounding modules (`grep -rn "224\|384" vendor/Menu_MiSTer/rtl/`).
- If the `--fast` build takes > 2 hours, abort, re-check `.qsf` for accidental full-optimization settings leaking through from a non-`--fast` base.

---

### Step 3 — Pixel reader burst + frame bytes + buffer offsets

**Why it matters:** After this step, the FPGA actually reads the right amount of data per line and correctly addresses both buffers. Without it, the video output would scan whatever random DDR3 bytes follow the first Mania buffer.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/vendor/Menu_MiSTer/rtl/native_video_reader.sv` (the reader state machine and parameters)
- This plan §4 (pixel reader changes) and §5 (frame buffer geometry)
- `/Users/sb/Developer/3sx-mister/docs/spec-fpga-native-video.md` §2.3, §3 (DDR3 memory map)

**Files to create/modify:**
- MODIFY `vendor/Menu_MiSTer/rtl/native_video_reader.sv` (verified localparam names from line 76–78):
  - `LINE_BURST`: `8'd96` → **`8'd80`**
  - `LINE_STRIDE`: `29'd96` → **`29'd80`**
  - `V_ACTIVE`: `9'd224` → **`9'd240`**
  - `BUF1_ADDR`: `29'h07405440` → **`29'h07404B20`**
  - `CTRL_ADDR` and `BUF0_ADDR`: unchanged
  - Header comment block (lines 15–18): update "384x224 RGB565 = 172,032 bytes" → "320x240 RGB565 = 153,600 bytes"; update "+ 0x2A200" → "+ 0x25900"
- MODIFY `vendor/Menu_MiSTer/rtl/native_video_top.sv` ONLY if it parameter-passes any of the above into the reader — inspect first to confirm. Current 3sx version probably just wires ports; no constants to change. Run `grep -n '384\|224\|768\|96' rtl/native_video_top.sv` during /implement to confirm.
- Verify no changes needed to `dcfifo_native` or FIFO depth. Comment at reader line 374 says "Depth 256: holds ~2.67 scanlines (96 beats/line * 2.67 = 256)". For Mania: 256 / 80 = 3.2 scanlines. Update that comment accordingly.

**Success criteria:**
- Quartus `--fast` compile completes without errors.
- Post-compile deploy (use the local deploy tooling; §10.1):
  - SCP the new RBF to `/media/fat/_Other/Sonic Mania.rbf` on MiSTer.
  - SCP the 3sx wrapper (unchanged yet) to `/media/fat/MiSTer_3S-ARM` as a **fallback test** — we just want to know the RBF loads.
  - Boot the core via MiSTer menu. Core loads, menu OSD is visible. (No pixels in DDR3 yet, so FPGA blanks the video — only sync + OSD is expected.)

**Dependencies:** Step 2 complete.

**What NOT to do:**
- Do NOT write a test-frame writer yet — that's in step 5.
- Do NOT modify `ddram.sv` or `sys_top.v` — all needed changes are in the native_video_* files.

**Fallback on failure:**
- If the core loads but OSD is garbled or shifted, the VTG math from step 2 might have an off-by-one. Re-verify counter widths and blanking regions.
- If the core fails to load, diff against 3sx's known-good build. A parameter that escaped the rename pass (e.g., a leftover 768 in a file-level comment that somehow drives logic) is the most likely culprit.

---

### Step 4 — Adapt `thirdsarm_wrapper.cpp` → `sonicmania_wrapper.cpp`

**Why it matters:** The wrapper is what the MiSTer menu actually invokes. Without it, the core loads but nothing spawns to draw frames.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.cpp` (3045 lines — skim the constants at top and the main `wrapper_run()` / `wrapper_main()` entrypoints)
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_main.cpp`
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_wrapper.h`
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/thirdsarm_core_context.{cpp,h}`
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-hps.sh`
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/main-mister-overlay.files`
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/main-mister-full-menu.patch`
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/Makefile.full.3s-arm`
- This plan §6 (wrapper HPS binary)

**Files to create/modify:**
- NEW `vendor/Main_MiSTer/sonicmania_wrapper.cpp` — cp of 3sx's, with mechanical rename (§6.1 list) applied. Search/replace: `thirdsarm_` → `sonicmania_`, `3S-ARM` → `Sonic Mania`, `3s-arm` → `sonic-mania`, `SF33RD.AFS` → `Data.rsdk`.
- NEW `vendor/Main_MiSTer/sonicmania_wrapper.h`
- NEW `vendor/Main_MiSTer/sonicmania_main.cpp`
- NEW `vendor/Main_MiSTer/sonicmania_core_context.{cpp,h}`
- NEW `vendor/Main_MiSTer/sonicmania_support_stubs.cpp` (renamed from 3sx's `thirdsarm_support_stubs.cpp`)
- MODIFY `vendor/Main_MiSTer/video.cpp` — overlay edit per §6.8 (change `core_CLK_VIDEO = 405.0/13.0` at lines 3072–3073 to `1550.0/63.0` for the Mania PLL). **Required for correct S-Video color** — not optional.
- NEW `vendor/Main_MiSTer.UPSTREAM.md` — metadata file noting pinned 3sx commit `3380931329b8acb442bd3d35a24d89f88641b7cf`.
- NEW `tools/mister-wrapper/build-hps.sh` — copy 3sx's, retarget output binary name to `MiSTer_SonicMania` and overlay manifest to sonic-mania file names.
- NEW `tools/mister-wrapper/main-mister-overlay.files` — copy 3sx's, rename entries.
- NEW `tools/mister-wrapper/Makefile.full.sonic-mania` — copy 3sx's `Makefile.full.3s-arm`, rename target → `MiSTer_SonicMania`.
- NEW `tools/mister-wrapper/main-mister-full-menu.patch` — copy 3sx's unchanged (the patch operates on fetched upstream Main_MiSTer, not on our files).

**Deferred items (gated with `#ifdef DEFERRED_WRAPPER_SHM`):**
- All `mister_joy_shm.h`-related code. Leave the include but conditionally compile out the reader/writer setup.
- Any OSD-driven input (F1/F2/etc. menu bindings) that uses wrapper SHM. Keep F12/OSD open/close path intact — that uses SPI, not SHM.

**Success criteria:**
- `tools/mister-wrapper/build-hps.sh --check-env` passes.
- `tools/mister-wrapper/build-hps.sh` (full build) produces `build/mister-wrapper-hps/MiSTer_SonicMania` as a valid ARM ELF:
  ```sh
  file build/mister-wrapper-hps/MiSTer_SonicMania
  # Expected: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), ...
  ```
- `grep -c 'thirdsarm' build/mister-wrapper-hps/MiSTer_SonicMania` returns 0 (no residual 3sx symbols in stripped binary — verify with `strings` if needed).

**Dependencies:** Step 1 complete (for wrapper tooling scaffolding). Independent of steps 2–3.

**What NOT to do:**
- Do NOT implement wrapper SHM input. Gate it behind `#ifdef DEFERRED_WRAPPER_SHM` and leave `DEFERRED_WRAPPER_SHM` undefined.
- Do NOT add cutscene / libtheora support. Phase 7 polish.
- Do NOT enable netplay / Gekko integration — 3sx's wrapper has this code; remove/gate for Mania.

**Fallback on failure:**
- If the build fails due to a missing Main_MiSTer upstream file (e.g., 3sx applied a local delta to `video.cpp` that doesn't auto-merge into the Mania build), capture the diff, apply it manually as a local overlay, re-run.
- If the wrapper loads on device but doesn't find the game binary (which doesn't exist yet in Track L's Phase 4 window), the wrapper should fail cleanly with an OSD error message. That's the expected behavior for this step — Track L will provide the game binary in Phase 5.

---

### Step 5 — Deploy RBF + wrapper + test-frame writer, verify HDMI

**Why it matters:** This is the first-light moment. If this step passes, the RTL pipeline is fundamentally healthy.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/src/port/sdl/native_video_writer.c` (the NativeVideoWriter pattern — we replicate a subset as a tiny test tool)
- `/Users/sb/Developer/3sx-mister/docs/mister-runbook.md` (deploy procedure — `misterctl.sh deploy-wrapper` style)
- This plan §10 (test procedure)

**Files to create/modify:**
- NEW `tools/mister-wrapper/test-frame-writer.c` — ~80 LOC standalone armhf binary that:
  1. Opens `/dev/mem` with `O_RDWR | O_SYNC`.
  2. mmap's 0x3A000000 size 0x60000.
  3. Writes a known 320×240 RGB565 pattern (checkerboard, or gradient) into buffer 0 at offset 0x100.
  4. Writes control word `(frame_counter << 2) | 0` at offset 0x000.
  5. Every ~16 ms: flip buffer, re-write pattern (shifted by 1 pixel for visual animation), update control word.
  6. Runs forever until SIGINT.
- NEW `tools/mister-wrapper/test-frame-writer-build.sh` — cross-compile the above for armhf using the **clang-20 toolchain from the Phase 0 Docker container** (the same container used by `3sx-mister/tools/mister/build-game.sh`). Standalone invocation pattern:
  ```sh
  docker run --rm -v "$(pwd):/work" -w /work mister-build:clang20 \
    clang-20 --target=arm-linux-gnueabihf -mfloat-abi=hard -O2 \
    -o tools/mister-wrapper/test-frame-writer \
    tools/mister-wrapper/test-frame-writer.c
  ```
  Alternative: if the test writer proves too fiddly to cross-compile, **rewrite it in Python** using `mmap` + `ctypes` — a DDR3 writer probe is I/O-bound, so a Python implementation is equivalent and removes the cross-compile dependency entirely. The MiSTer ships Python 3 by default.
- NEW `tools/mister-wrapper/deploy-step5.sh` — helper that scp's RBF, wrapper, test-frame-writer to MiSTer and edits MiSTer.ini.

**Success criteria:**
- Deploy script succeeds (all three files land in correct places).
- On MiSTer: boot Sonic Mania core from the menu. Wrapper log shows startup, no crashes.
- SSH in, run `/media/fat/games/sonic-mania/test-frame-writer &`. HDMI shows the test pattern animating.
- Pattern is **correct aspect ratio** — 320 wide × 240 tall. No skew, no shifted columns.
- OSD test: press MiSTer menu button, wrapper OSD overlays on pattern without corruption.

**Dependencies:** Steps 1–4 complete. Physical access to MiSTer for HDMI observation (or a test tool that captures HDMI frames).

**What NOT to do:**
- Do NOT test on CRT yet (that's step 6).
- Do NOT test with a real Mania build (that's Track L's concern).
- Do NOT set `vga_scaler=1` at any point — INI contract must be `=0`.

**Fallback on failure:**
- If HDMI shows nothing: SSH in, run `devmem2 0x3A000000 w`. Should show a non-zero control word (proving the test-writer is writing DDR3).
  - If control word is 0: test-writer is broken. Fix the userland.
  - If control word is non-zero but HDMI is black: FPGA is not reading DDR3. Check that the FPGA's NATIVE_VID status bit is set by the wrapper (grep wrapper log). Check that `cfg[15]` is set (post-boot).
- If HDMI shows wrong-aspect output (e.g., 384 wide squashed into 320): likely a VTG parameter from step 2 didn't take effect. Re-verify `grep -rn "H_ACTIVE" vendor/Menu_MiSTer/rtl/` shows **320**, not 384.
- If HDMI shows tearing: FIFO sizing or CDC bug. Check FIFO depth didn't accidentally shrink — should still be 256 entries (2048 bytes).

---

### Step 6 — CRT S-Video validation + modeline iteration loop

**Why it matters:** 4:3 CRT via S-Video is a first-class Phase 4 exit criterion (§10.5). This step confirms the `vga_scaler=0` path and the arcade-CRT modeline.

**Files to read before implementing:**
- `/Users/sb/Developer/3sx-mister/docs/reference-native-analog-video.md` §8 (YC encoding), §9 (S-Video color fix history), §13 (troubleshooting)
- This plan §11 (risks R-1, R-5, R-9)

**Files to create/modify:**
- Potentially none. If CRT sync and color both work on first try, no edits.
- If CRT rejects sync (R-1 fires): back to step 2 with updated H_total. Pick per §11 R-1 mitigation sequence.
- If CRT shows grayscale (R-5 fires): do NOT re-patch YC encoder logic — this is almost certainly an INI / `vga_scaler` config issue, not RTL. Verify INI, wrapper log, then only if both look OK inspect the inherited menu.sv YC chain.

**Success criteria:**
- On CRT via S-Video: 320×240 test pattern visible, stable sync, correct 4:3 aspect, full color.
- Verify each RGB primary: test-writer shows a known pure-red frame → CRT shows red (not gray). Pure-green → green. Pure-blue → blue.
- OSD overlays correctly over CRT output too.

**Dependencies:** Step 5 HDMI validation passing.

**What NOT to do:**
- Do NOT modify YC encoder logic (`yc_out.sv`). It is inherited from 3sx and works for arbitrary pixel clocks as long as PHASE_INC is correct.
- Do NOT attempt CRT if no physical CRT is available — document as UNVERIFIED and move to step 7.

**Fallback on failure:**
- R-1 mitigation (CRT won't sync): adjust H_total, rebuild, redeploy. Expect one to two iterations.
- R-5 mitigation (grayscale): debug INI → wrapper log → RTL, in that order.

---

### Step 7 — Release-flavor Quartus build

**Why it matters:** Final shippable RBF. `--fast` builds are dev-quality; release builds optimize for fMAX and timing margin.

**Files to read before implementing:**
- User confirmation that `--fast` build is working end-to-end (steps 1–6 complete with all pass criteria).

**Files to create/modify:** None. This step re-runs the build without `--fast`.

**Success criteria:**
- Quartus full compile (no `--fast`) completes without errors.
- Final RBF passes the same deploy + smoke test as step 5 (HDMI visible 320×240 test pattern).
- Static timing analysis shows positive slack on all user clocks; no warnings about clock-domain crossings.
- Output RBF archived at:
  - Colima VM: `/home/sb.linux/build/sonic-mania-mister-core/Sonic_Mania.rbf`
  - macOS host: `/Users/sb/Developer/sonic-mania-mister/build/mister-wrapper-core/Sonic_Mania.rbf`
  - Deploy-time renamed to: `/media/fat/_Other/Sonic Mania.rbf` on MiSTer.

**Dependencies:** User approval (per memory rules, flipping from `--fast` to release needs explicit sign-off). Steps 1–6 all passing.

**What NOT to do:**
- Do NOT kick off the full build without user approval. **Ask first.**
- Do NOT delete the `--fast` RBF — keep both for A/B diagnosis.

**Fallback on failure:**
- If the full build produces a worse-behaving RBF than `--fast` (e.g., new timing violations show up because full optimization moves cells), A/B compare. Report findings to user; likely stay on `--fast` RBF for this phase and re-plan the release-flavor build for Phase 7.

---

## 14. Summary — what to ask the user before /implement

- **Sign-off on modeline OQ-1:** H_total = 391 (tight) or 396 (cleaner PLL)? Plan selects 391.
- **Sign-off on PLL OQ-3:** accept M=62/N=3/C=42 with ~212 ppm error off the NTSC-exact 15,734 Hz target (yielding 59.587 Hz V-freq; engine pacer matches FPGA — no drift), or wait for /implement to run the full search? Plan defaults to the former.
- **Sign-off on deferred scope:** wrapper SHM input deferred to Phase 7, cutscenes/libtheora deferred, netplay not planned — confirm.
- **Physical CRT access:** user has / does not have a CRT for step 6? If not, step 6 becomes documentation-only pass.
- **Step 7 go/no-go:** user signs off on the ~2-hour release build after step 6 passes.

End of plan.
