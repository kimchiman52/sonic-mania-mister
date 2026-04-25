# Phase 10: dual-RBF static aspect-ratio dispatch

**Date:** 2026-04-25
**Branch:** `mister`
**Status:** Scaffolding landed (build script, wrapper, engine, deploy
script, docs). 4:3 Quartus build (Phase 9c retune) is in flight under
`colima quartus2` PID 872712; 16:9 Quartus build is queued for the
user (or a follow-up agent) to launch sequentially after.

---

## Why "Option A"

Phase 9 originally locked in dual-aspect (4:3 + 16:9) with a static
two-PLL + glitch-free clock-mux topology. We hit a hard Cyclone V
constraint: `sys_top.v`'s `hdmi_clk_sw` / `vga_clk_sw` clock-select
blocks demand that `inclk` be driven directly by a clock pin or a PLL
CLK output. Cascaded clock muxes (combinational AND/OR or `altclkctrl`)
are rejected at fitter time. See `docs/phase-9-scopecut-report.md` for
the full archaeology.

The only on-chip path to runtime aspect switching is `altpll_reconfig`
(Avalon-MM coefficient reconfig with explicit blanking + reset
handshake). That's a 100+ LOC state machine plus IP wizard config plus
SDC discipline — over budget for an overnight win.

"Option A" is the simpler shape: ship two RBFs from one source tree,
each carrying a single static aspect ratio. The MiSTer menu's existing
core-loader picks one by filename. No on-chip reconfig, no shared-clock
mux, no runtime toggling. Aesthetic trade-off: switching aspect requires
reloading the core from the menu, not toggling an OSD bit.

---

## Decisions

### RBF naming convention

| RBF filename                  | Aspect | CONF_STR header           |
|-------------------------------|--------|---------------------------|
| `Sonic_Mania.rbf`             | 4:3    | `Sonic Mania;...`         |
| `Sonic_Mania_169.rbf`         | 16:9   | `Sonic Mania (16:9);...`  |

The `_169` suffix is canonical and is the marker the wrapper detects
in `argv[1]` to decide which `SONIC_MANIA_ASPECT` to emit. The wrapper
also accepts `(16:9)`, `(16-9)`, and `16x9` substrings for robustness
against manual deployment renames, but `_169` is what the build script
produces and what `tools/mister-wrapper/deploy-step5.sh` ships.

The deployed RBF basenames preserve the build-output names with a
space-for-underscore swap on the 4:3 only ("Sonic Mania.rbf"); the 16:9
RBF keeps the underscore form ("Sonic Mania_169.rbf") because the `_169`
detection is required for the wrapper to do its job, and a literal "16:9"
in a filename has parentheses/colons that some tooling chokes on.

### Env var contract

Set by `vendor/Main_MiSTer/sonicmania_wrapper.cpp` (in
`set_runtime_environment`, just before the runtime exec):

```
SONIC_MANIA_ASPECT="widescreen"   # for the 16:9 RBF
SONIC_MANIA_ASPECT="4:3"          # for the 4:3 RBF (and any unknown)
```

Read by `dependencies/RSDKv5/.../MiSTerRenderDevice.cpp`:

```
videoSettings.pixWidth = (SONIC_MANIA_ASPECT == "widescreen") ? 424 : 320
NativeVideoWriter_SetDims(pixWidth, SCREEN_YSIZE)   // before NativeVideoWriter_Init
```

The engine accepts `"widescreen"`, `"16:9"`, and `"169"` as positive
matches; everything else (including unset) falls back to 4:3.

### MiSTer.ini section name

Two distinct sections are added by `deploy-step5.sh`:

```
[Sonic Mania]
main=MiSTer_SonicMania
vga_scaler=0

[Sonic Mania (16:9)]
main=MiSTer_SonicMania
vga_scaler=0
```

Both route through the same wrapper binary and both disable the HDMI
scaler so native_video reaches the CRT. MiSTer firmware matches the
section header against the core's CONF_STR display name, which the
build script patches to `"Sonic Mania (16:9);..."` for the 16:9 RBF.

### Per-aspect Verilog patching

We chose **in-script ruby-pattern substitution** over alternative
approaches:

- **Not chosen: pre-baked `.169.template` files** alongside canonical
  sources. This bloats the source tree and creates a drift surface —
  if someone edits the canonical 4:3 file but not the 16:9 template,
  the 16:9 RBF silently misses the change.
- **Not chosen: Verilog `\`define` ifdefs.** Quartus accepts them but
  scattering build-time switches across four files makes the source
  tree noisier than necessary. We need to change six numeric constants;
  ifdefs would replace each constant with two-line conditional blocks.
- **Chosen: in-place patches against the prepared (rsync'd) source tree.**
  The canonical tree stays in its 4:3 (Phase 9c) shape — the same shape
  that builds without `--aspect 16:9`. The 16:9 patch is a small ruby
  block in `build-core.sh` that rewrites six known literals in three
  files plus one CONF_STR header. The patches are exact-match
  substitutions; if the canonical source drifts (e.g. a new H_FP value),
  the 16:9 patch fails loudly at build time rather than silently
  producing a broken core.

### 16:9 PLL coefficients

**Primary: M=101, N=5, C=29 → CLK_VIDEO = 34.8276 MHz, pixel = 8.7069 MHz**

This is the choice locked in Phase 9's original plan (`docs/phase-9-plan.md`).
With H_TOTAL=545, V_TOTAL=266: refresh = 8,706,900 / (545×266) = 60.05 Hz,
H_freq = 8,706,900 / 545 = 15,975 Hz. (NTSC's nominal H-freq is 15,734 Hz;
the 16:9 modeline is intentionally a bit higher because the wider active
area at the same vertical line count requires a faster pixel clock to
hit ~60 Hz refresh. This is well within CRT phase-lock range.)

**Fallback: M=89, N=5, C=25 → CLK_VIDEO = 35.6 MHz, pixel = 8.9 MHz**

If Quartus's altera_pll fitter rejects M=101 (the M-counter has a
device-specific upper bound that depends on VCO range), the user (or
a follow-up agent) should:

1. Edit `tools/mister-wrapper/build-core.sh` `apply_169_patches`,
   change the substitution target from `"34.827600 MHz"` to
   `"35.600000 MHz"`.
2. Re-run `--aspect 16:9 --prepare-source` to regenerate.
3. Re-launch Quartus.

The 35.6 MHz fallback shifts H_freq slightly higher (15,975 → 16,330);
any NTSC-compliant CRT will still phase-lock. Refresh stays within
60 Hz ±2%.

Both coefficient choices are documented in code comments inside
`apply_169_patches` so future investigators can find them without
re-reading this doc.

---

## Files modified

### Build tooling

- `tools/mister-wrapper/build-core.sh`
  - Added `--aspect {4:3|16:9}` flag (env override:
    `MISTER_WRAPPER_CORE_ASPECT`).
  - 4:3 builds the canonical source tree as-is to
    `build/mister-wrapper-core/Sonic_Mania.rbf`.
  - 16:9 stages a separate prepared source tree at
    `build/mister-wrapper-core/src_169/`, runs
    `apply_169_patches` to retarget PLL coefficients, modeline totals
    + porches, DDR3 reader BUF1/LINE_BURST/LINE_STRIDE, and the CONF_STR
    header. Builds to `build/mister-wrapper-core/Sonic_Mania_169.rbf`.
  - Made the existing `prepare_source` ruby-pass CONF_STR substitution
    idempotent — it now accepts any of `MENU`, `Sonic Mania`, or
    `Sonic Mania (16:9)` as the input header and rewrites to the
    `--aspect`-derived display name. Pre-Phase-10, the script aborted
    if the seed had already been edited to `Sonic Mania;UART31250,MIDI;`,
    which it had been since Phase 4 — so the in-flight 4:3 build had
    been kicked off via a manual rsync rather than this script.

- `tools/mister-wrapper/deploy-step5.sh`
  - Copies `Sonic_Mania.rbf` and (if present) `Sonic_Mania_169.rbf` to
    `/media/fat/_Other/`.
  - Appends `[Sonic Mania (16:9)]` section to `MiSTer.ini` (idempotent).

### Wrapper

- `vendor/Main_MiSTer/sonicmania_wrapper.cpp`
  - Added `detect_aspect_from_rbf(const char *)` — case-insensitive
    substring scan over the RBF basename for `_169` / `(16:9)` /
    `(16-9)` / `16x9`.
  - In `sonicmania_wrapper_run`, immediately after seeding
    `g_wrapper_aspect_ratio` from persisted config, the RBF detection
    overrides it (RBF is authoritative).
  - In `set_runtime_environment`, emits
    `SONIC_MANIA_ASPECT={widescreen,4:3}` based on
    `g_wrapper_aspect_ratio`.
  - Updated the `phase9: ...` log line to include the resolved
    `SONIC_MANIA_ASPECT` and `g_wrapper_aspect_ratio` for on-device
    diagnostics.

### Engine

- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
  - In `RenderDevice::Init`, reads `SONIC_MANIA_ASPECT` and selects
    `videoSettings.pixWidth` (320 vs 424) before calling
    `NativeVideoWriter_SetDims(pixWidth, SCREEN_YSIZE)` and
    `NativeVideoWriter_Init`.
  - Default (env unset / unrecognized) is 4:3, matching Phase 9c.
  - Logs the resolved aspect and pixWidth for on-device verification.
  - The `nv_buf1_offset_runtime` math
    (`NV_BUF0_OFFSET + width*height*2`) already scales correctly:
    16:9 yields BUF1 = `0x100 + 424*240*2 = 0x31C00`, matching the
    reader.sv's `BUF1_ADDR = 29'h07406380` (= `0x3A031C00 >> 3`).

### Documentation

- `docs/phase-10-plan-and-implementation.md` (this file)

## Files NOT modified

- `vendor/Menu_MiSTer/menu.sv` — keeps the canonical Phase 9c
  4:3-only CONF_STR + single `pll_video pll_vid` instantiation. The
  16:9 build script patches the **prepared** copy, not the canonical
  source. status[13] stays RESERVED.
- `vendor/Menu_MiSTer/rtl/native_video_timing.sv` — canonical 4:3 values
  preserved (H_FP=26, H_BP=51, V_FP=2, V_BP=17 from the user's current
  Phase 9c session). 16:9 patches H_TOTAL/V_TOTAL/H_ACTIVE/V_FP/V_BP via
  `apply_169_patches`.
- `vendor/Menu_MiSTer/rtl/native_video_reader.sv` — canonical 4:3
  values preserved.
- `vendor/Menu_MiSTer/rtl/pll_video/pll_video_0002.v` — canonical
  27.0 MHz preserved. 16:9 retargets to 34.8276 MHz via patch.
- `vendor/Main_MiSTer/video.cpp` — `core_CLK_VIDEO = 27.0` literal kept.
  Phase 10 does NOT change this. The MiSTer YC encoder runs from this
  value to derive PHASE_INC and COLORBURST_START/END for S-Video. For
  the 16:9 RBF, the colorburst frequency math is technically wrong
  (since the RBF's PLL is 34.8276 MHz, not 27.0 MHz). **This is an
  open question — see "Open questions" below.**
- `vendor/Menu_MiSTer/sys/pll_q17.qip`,
  `vendor/Menu_MiSTer/sys/sys_top.sdc` — single-PLL configuration
  preserved. The 16:9 RBF retargets the existing pll_video PLL via
  output_clock_frequency0; no new IP instances added.
- `dependencies/RSDKv5/.../NativeVideoWriter.{c,h}` — runtime-dim
  plumbing already aspect-aware, no change needed.

---

## Build invocation

### Set up

The 4:3 path is the default; running `tools/mister-wrapper/build-core.sh`
without flags produces the 4:3 RBF, exactly like before Phase 10.

### 4:3

```
tools/mister-wrapper/build-core.sh                # default
tools/mister-wrapper/build-core.sh --aspect 4:3   # explicit
```

Output: `build/mister-wrapper-core/Sonic_Mania.rbf`

### 16:9

```
tools/mister-wrapper/build-core.sh --aspect 16:9
```

Output: `build/mister-wrapper-core/Sonic_Mania_169.rbf`

The script picks up Quartus from the host (local install) or from the
established `sonic-mania-mister-wrapper-quartus17` Docker image, same
as before.

The actual on-Mac build path goes through the colima quartus2 VM via
nohup (per `feedback-quartus-nohup.md` — never run Quartus directly,
SSH timeout will kill long compiles). The user's current pattern:

```
# inside colima quartus2
cd /home/sb.linux/build/sonic-mania-mister-core/src_169
nohup quartus_sh --flow compile Sonic_Mania_169 -c Sonic_Mania_169 \
    > /home/sb.linux/build/sonic-mania-169-build.log 2>&1 &
```

**Quartus license is single-instance.** Do NOT run a 4:3 and a 16:9
build simultaneously — the second one will fail at license-checkout
time. Sequence them: wait for the first `EXIT=0` marker before
launching the next.

### Per-aspect verification (no Quartus required)

```
tools/mister-wrapper/build-core.sh --aspect 16:9 --prepare-source
grep "output_clock_frequency0" build/mister-wrapper-core/src_169/rtl/pll_video/pll_video_0002.v
grep -E '^localparam' build/mister-wrapper-core/src_169/rtl/native_video_timing.sv
grep -E 'BUF1_ADDR|LINE_BURST|LINE_STRIDE' build/mister-wrapper-core/src_169/rtl/native_video_reader.sv
grep "CONF_STR" build/mister-wrapper-core/src_169/Sonic_Mania_169.sv
```

Expected (from this Phase 10 implementation):
- `output_clock_frequency0("34.827600 MHz")`
- `H_ACTIVE=10'd424`, `H_TOTAL=10'd545`, `V_TOTAL=10'd266`
- `BUF1_ADDR=29'h07406380`, `LINE_BURST=8'd106`, `LINE_STRIDE=29'd106`
- `"Sonic Mania (16:9);UART31250,MIDI;"`

---

## Deploy

After both RBFs exist locally:

```
tools/mister-wrapper/deploy-step5.sh
```

This:
1. Copies `MiSTer_SonicMania` (wrapper) to `/media/fat/`.
2. Copies `Sonic_Mania.rbf` to `/media/fat/_Other/Sonic Mania.rbf`.
3. Copies `Sonic_Mania_169.rbf` to `/media/fat/_Other/Sonic Mania_169.rbf`
   (skipped if the local 16:9 RBF doesn't exist yet).
4. Adds `[Sonic Mania]` and `[Sonic Mania (16:9)]` sections to
   `MiSTer.ini` (both idempotent).

After deploy, the MiSTer's `Cores` menu shows two entries:
"Sonic Mania" and "Sonic Mania (16:9)". Pick one. The wrapper runs
the same binary either way; pixel geometry is selected at engine init
from the env var the wrapper emits based on the loaded RBF.

---

## Open questions / verification steps

1. **video.cpp's `core_CLK_VIDEO` literal.** Currently 27.0 MHz hardcoded
   for the YC subcarrier math. For the 16:9 RBF, the actual CLK_VIDEO is
   34.8276 MHz, so `PHASE_INC` and `COLORBURST_START/END` are derived from
   the wrong base. Effect at the CRT: S-Video colorburst phase is off,
   which on a 4:3-tuned NTSC CRT manifests as either grayscale or
   miscolored hue. **This needs an empirical check on the 16:9 RBF first
   light** before deciding whether to add a runtime selection. Options:

   - **(a) Make `video.cpp` aspect-aware:** ternary on
     `g_wrapper_aspect_ratio` or on a wrapper-set int, similar to the
     Phase 9 pre-scope-cut prototype.
   - **(b) Document that S-Video color is broken for the 16:9 RBF**
     and tell users to use HDMI-output mode for widescreen.
   - **(c) Recompute coefficients in firmware:** the CXA2075/CVBS path
     can derive from `current_video_info.ctime / ptime` if measured
     correctly — verify whether the measurement loop runs reliably with
     `vga_scaler=0`.

   Tracking as a follow-up; not blocking the Phase 10 RBF build.

2. **Fitter acceptance of M=101.** The altera_pll IP for Cyclone V GX
   (5CSEBA6U23I7) accepts M up to 320 in theory; 101 should fit. If the
   fitter complains, swap to M=89 / N=5 / C=25 (35.6 MHz pixel = 8.9 MHz)
   per the comment block in `apply_169_patches`.

3. **DDR3 region size headroom.** `NV_DDR_REGION_SIZE` was bumped to
   `0x80000` in Phase 9 specifically to cover Phase 10's 16:9 buffers.
   Two 16:9 frames + control word = `2 * 0x31B00 + 0x100 = 0x63700`,
   well under `0x80000`. No change needed.

4. **First-light test for 16:9.** Per `feedback-no-premature-release.md`
   and `feedback-debug-build-for-live-tests.md`, the 16:9 RBF should be
   smoke-tested with the telemetry-flavor wrapper + game build before
   any release artifact is cut. Specifically:
   - Confirm the wrapper logs
     `phase9: ... SONIC_MANIA_ASPECT=widescreen ... aspect=1` at startup.
   - Confirm the engine logs
     `MiSTerRenderDevice::Init: SONIC_MANIA_ASPECT=widescreen -> aspect=widescreen pixWidth=424`.
   - Confirm the FPGA's native_video_top sees a 424×240 frame (e.g. via
     `test-frame-writer bars`).
   - Confirm the CRT phase-locks (no rolling, no garbage on left/right
     edges).

5. **The user's uncommitted `H_FP=26 / H_BP=51 / V_FP=2 / V_BP=17`
   tuning** in `vendor/Menu_MiSTer/rtl/native_video_timing.sv` is what
   the in-flight 4:3 Quartus build is using. Phase 10 keeps these as the
   canonical 4:3 values. If the Phase 9d hardware test reveals they need
   to shift again, edit the canonical file directly — both 4:3 (passes
   through unchanged) and 16:9 (whose patch only touches H_ACTIVE /
   H_TOTAL / V_TOTAL / V_FP / V_BP, leaving H_FP and H_BP as the user
   set them) will pick up the change on next build.

6. **Wrapper / engine binary builds.** This phase only added source-code
   changes to the wrapper and engine. The binaries on the device are
   still the Phase 9c builds. They need to be rebuilt + redeployed:
   ```
   tools/mister-wrapper/build-hps.sh    # wrapper -> MiSTer_SonicMania
   tools/...build-game.sh               # engine -> RSDKv5U
   tools/mister-wrapper/deploy-step5.sh # ship both
   ```
   This is independent of the Quartus RBF builds and can run in parallel.

7. **Submodule pointer bump.** The engine change in
   `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`
   lives inside the RSDKv5 submodule. Phase 10 commits should:
   - Commit inside the submodule first (`(cd dependencies/RSDKv5 && git
     add ... && git commit ...)`).
   - Bump the superproject's submodule pointer in a follow-up commit.

   Same pattern as the existing Phase 9 RSDKv5 bumps.
