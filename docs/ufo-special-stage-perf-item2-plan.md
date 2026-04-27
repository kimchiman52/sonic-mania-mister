# UFO Special Stage — Per-Scanline Division Elimination (Item 2)

**Document date:** 2026-04-25
**Status:** Implemented in commit `9678afb0` (2026-04-26). Deployed to MiSTer (BuildID `8c726c5755f3838c3ad1629c45ea29fd695ccb60`). User-gated gameplay test pending. See "Plan execution notes" at the bottom.
**Branch:** `mister`
**Scope:** Replace the per-iteration `__aeabi_idiv` call in all three `UFO_Setup_Scanline_*` callbacks with a shared per-frame Q30 reciprocal table, multiplied in-loop. Single commit on `mister`. The RSDKv5 submodule (`dependencies/RSDKv5`) is NOT modified.

This is **Item 2** from the wider UFO Special Stage perf investigation. Items 1, 4, 7 already shipped (`7541c0d2`, `e6115147`, `5735e614`) and produced no perceptible speedup on hardware — they were the safe items. Item 2 is the magnitude item: ~480 32-bit divisions per frame eliminated on a CPU (HPS Cortex-A9) with no hardware integer divider, where each `__aeabi_idiv` takes ~50–60 cycles software-emulated.

**Source-of-truth files for the changes (must be re-read by `/implement` before editing):**
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — three scanline callbacks (lines 186–332 today).
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Camera.c` — `clipY`, `camera->height` semantics (lines 50–112).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp:155` — `SCREEN_YSIZE = 240`.
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/GameLink.h:49` — `SCREEN_YCENTER = SCREEN_YSIZE / 2 = 120`.
- `/Users/sb/Developer/sonic-mania-mister/docs/ufo-special-stage-perf-plan.md` — the prior bundled-low-risk plan (Items 1/4/7); style template for this doc.
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — build/deploy/smoke-test flow. **Note:** the deploy-script path was fixed in `26a717ba` (lowercase `/media/fat/games/sonic-mania/` is canonical now; this plan does not need to work around the old CamelCase path).

**Engine contracts already verified by the plan author (do not re-derive):**
- The three callbacks fire from `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:782-783`, immediately before each layer's tile-layer render. Playfield is in drawGroup 1 (its layer), 3DFloor and 3DRoof are both pinned to drawGroup 0 (`UFO_Setup.c:95, :104`). Within a single frame, the engine processes drawGroups 0 → 15 in order, so 3DFloor and 3DRoof both fire before Playfield.
- `camera->angle` and `camera->angleX` are updated in Update phase (`UFO_Camera_State_*` and `UFO_Camera_HandleCamPos`), which runs once per frame BEFORE Draw phase. The three scanline callbacks see a stable `(angle, angleX)` for the duration of one frame's draw.
- `RSDK.Sin1024(a) >> 2` and `RSDK.Cos1024(a) >> 2` are pure functions of `a`. Same `(angle, angleX)` → same `(sin, cos, sinX, cosX)`.
- Therefore the divisor sequence `div[i] = sinX + ((-SCREEN_YCENTER + i) * cosX) >> 8`, for `i ∈ [0, SCREEN_YSIZE)`, is **identical** across all three callbacks within a single frame, and depends only on `camera->angleX`. (`camera->angle` does NOT enter the divisor — only `angleX` does, via `sinX = Sin1024(-angleX) >> 2` and `cosX = Cos1024(-angleX) >> 2`. The cache is keyed on `angleX` alone.)

**Disassembly anchor (captured 2026-04-25 from the on-disk telemetry build):**
- Object file: `/work-mister/build/mister-telemetry/CMakeFiles/SonicMania.dir/SonicMania/Objects/All.c.o` inside the `sonic-mania-mister-arm-build` Docker container (Mania uses a unity-build `All.c`, so individual `UFO_Setup.c.o` does not exist).
- Symbols `UFO_Setup_Scanline_Playfield`, `UFO_Setup_Scanline_3DFloor`, `UFO_Setup_Scanline_3DRoof` each contain exactly one `bl 0 <__aeabi_idiv>` inside the inner loop. Verified by `arm-linux-gnueabihf-objdump -d` and `grep '__aeabi'`.
- Pre-divide code does the divisor staircase in two instructions (`add r1, sl, r0, asr #8` for `sinX + (cosVal >> 8)` and `cmp r1, #1; movls r1, #1` for the `if(!div) div=1` zero-guard). Compiler picked `movls` over a branch — already efficient.
- Post-divide code uses 5 `mul`/`mla`/`mls` instructions to fan `h` (the divide result) out to `deform.x/y` and `pos`. These multiplies survive the change unchanged; we are only eliminating the divide call.
- No NEON / no autovectorization in the loop. No partial unrolling. The loop is a plain backwards-jumping branch — clang has not unrolled.
- Conclusion: each iteration spends ~50 cycles in `__aeabi_idiv` plus ~15 cycles in the rest of the body (5 muls × 3 cycles + memory + branch). **Eliminating the divide is a ~3.5× speedup on the loop body.** Per-frame saving: ~480 divides (see "Win sizing" below) × ~50 cycles = ~24 000 cycles ≈ 40 μs at 600 MHz HPS. That's a measurable but not dramatic win — about 0.24% of a 60 fps budget on its own. The wider perf effort assumed Items 2 + 3 + 5 + 6 stack; Item 2 alone won't be felt in a casual playthrough but will show up in profile dumps.

**Locked decisions (DO NOT REVISIT):**
- **Single commit on `mister`.** This is one logical change spanning three callbacks plus a shared module-static cache. No splitting.
- **Approach C (shared per-frame Q30 reciprocal table).** Reasoning under "Approach decision" below. Approaches A (Newton-Raphson incremental), B (per-callback LUT with lerp), D (VFP `vrecpe`), E (trust the compiler), and F (memoize prev_div) were considered and rejected.
- **Q30 fixed-point** for the reciprocals. Worst-case error `|h_new - h_old| ≤ 1` on the divide result; 1 LSB on the output `h` translates to ≤1 LSB on the 16.16 fixed-point screen positions, i.e. ≤1/65536 of a pixel — imperceptible. Algebra under "Precision analysis."
- **Cache key:** `camera->angleX` only. If it matches the cached value, reuse. Otherwise rebuild. The divisor formula is fixed in this very file (`UFO_Setup.c`); any future call site adding a new dependence would necessarily edit this code, so over-keying on `camera->angle` (which doesn't enter the divisor) only burns cache hits during normal turning play. Single-key on `angleX` keeps the cache hit during pure-yaw motion (common UFO5 pattern: player turns, camera tracks, pitch stays at horizon).
- **Cache lifetime:** module-static (`static int32 ...` in `UFO_Setup.c`). Survives across frames. No explicit invalidation on stage transition needed because the cache key changes when entering/leaving a stage (different camera angles); the worst case is one wasted rebuild on the first frame after a transition.
- **First-callback-per-frame builds the table.** Whichever of the three callbacks runs first in a frame and observes a cache miss does the 240-divide build. Subsequent callbacks in the same frame see a hit and skip the build. The order is engine-determined (drawGroup 0 → 15 → 3DFloor and 3DRoof first, then Playfield) but the code does NOT rely on a specific order — it works regardless of which callback runs first.
- **Zero-guard preserved.** The `if (!div) div = 1;` guard from the original code becomes a guard on the divisor *during table build*. The reciprocal of 1 is `2^30`, stored as a normal Q30 entry, so the in-loop multiply path needs no special-case branch.
- **No SIMD / no VFP.** Approach D (VFP `vrecpe.f32` + `vrecps.f32`) was considered and rejected: round-trip int→float→int costs ~10–15 cycles, and VFP precision (single-precision = 24 mantissa bits) is at the edge of insufficient for our NUM range (worst-case ~2^29 per `UFO_Camera.c:104`), where Q30's 30-bit reciprocal headroom is comfortable. VFP would also push us off the integer-only fast-math invariant the rest of the engine maintains.

**What NOT to do:**
- Do NOT modify `dependencies/RSDKv5/`. The submodule has one unrelated WIP change in `RSDK/Mod/ModAPI.cpp` — leave it.
- Do NOT widen scope to BSS, other `UFO_*_Draw` functions, or items 3/5/6 from the wider investigation.
- Do NOT split this across multiple commits. One commit per `Locked decisions`.
- Do NOT extract a helper function shared between the three callbacks for the inner-loop multiply. Three near-identical edits inline beat a helper here for the same reasons documented in the prior plan's Item 1: minor formula differences (different NUM, different bank-shift) and decompiled-Mania style allergy to extra abstraction. The shared piece IS the cache + table-build helper; the per-callback consumer remains inline.
- Do NOT precompute the reciprocal table at stage-load time. The divisor depends on `camera->angleX`, which changes every frame the player pitches; a stage-load precompute is wrong unless we also invalidate on every camera-pitch move, which is the same as per-frame.
- Do NOT cache across frames without the angle-key check. Caching across frames with the key check is the optimization; caching unconditionally is a bug.
- Do NOT use `int64_t` for the cache. Q30 reciprocals fit in `int32`. The 64-bit intermediate is the multiply, which the compiler emits as `smull` from two `int32` inputs.

---

## Critical autonomy notes for the implement agent

1. **Don't ask.** If a branch decision arises that isn't covered above, choose the safer option, document it in the commit body, proceed.
2. **Auto-recover from failures:**
   - **SDL2 build break:** likely a typo in the table-build helper or the Q-shift (`>> 30`). The change is mechanical; re-read against the change sketch.
   - **Visible distortion in 3D Floor/Roof:** the precision tolerance was breached. First check: are you using `(int64_t)NUM * recip` (signed 64-bit multiply via `smull`) and not `NUM * recip` (32-bit overflow)? Second check: is the Q-shift `>> 30` and not `>> 32`? Third check: did the cache key miss for this frame, forcing a rebuild that could have been corrupted (rare; print `cached_angleX` vs `current` to diagnose).
   - **Roof renders correctly but Floor is broken (or vice versa):** the per-callback NUM changed; check that each callback uses its own NUM in the multiply (`camera->height` for Playfield, `camera->height + 0x1000000` for 3DFloor, `(camera->height >> 2) - 0x600000` for 3DRoof).
   - **First-frame-after-stage-load corruption:** the static cache key has uninitialized values that happen to match the first frame's `angleX`. Initialize the cached key to `INT32_MIN` — the canonical "never-a-valid-value" sentinel for `int32` (real `angleX` is bounded `[-0x100, 0x100]` per `UFO_Camera_HandleCamPos`, and `INT32_MIN` is unambiguously outside any plausible angle resolution a future state could introduce).
3. **Self-verify each step against the listed Success criteria BEFORE moving to the next step.**
4. **Single commit on `mister`.** Do not amend an existing commit. Do not push.
5. If the smoke test surfaces a regression that can't be pinpointed in <30 min, revert the commit (`git revert HEAD`) and append a wrap-up note at the bottom of this file describing what hit. Do NOT investigate further without user direction.

---

## Approach decision

The brief listed five candidates (A/B/C/D/E). I add a sixth (F = memoize previous div within each callback). I picked **Approach C** with a per-frame shared cache.

### Win sizing (per-frame, derived from the disasm anchor)

| Approach | Per-frame divides | Per-frame extra mul | Wall-clock saving (Cortex-A9, 600 MHz) | Bit-exact? | Worst case |
|---|---|---|---|---|---|
| Original | 720 | 0 | baseline | yes | 720 |
| A. Newton-Raphson incremental | 0 (build) + 0 (loop) | ~3 mul/iter × 720 | ~36 000 cycles saved gross, but precision drift demands periodic resync (every ~16 iters @ 1-LSB tolerance, ~45 resyncs × 240 = ~10 800 cycles back) | no, error compounds | varies |
| B. Per-callback Q30 LUT | 240 (build per callback) × 3 = 720 | 240 mul × 3 = 720 | ~0 (parity) | ≤1 LSB | parity |
| **C. Shared per-frame Q30 LUT (PICKED)** | **240 (one build per frame) × 1 = 240** | **240 mul × 3 = 720** | **~24 000 cycles saved (≈40 μs)** | **≤1 LSB** | **parity** |
| D. VFP `vrecpe.f32 + vrecps.f32` | 0 | 720 vrecpe/vrecps × ~10 cycles each + 720 round-trip int→float→int × ~15 = ~18 000 | ~14 000 cycles saved | error ~2^-23 | varies |
| E. Trust the compiler | unchanged | unchanged | 0 | yes | unchanged |
| F. Memoize prev div within each callback | varies; horizon-level (cosX=256): 720 (parity); modest pitch (cosX=64): 180; near-vertical (cosX=8): 25 | 0 | 0–35 000 cycles depending on play | yes (bit-exact) | parity |

### Why C over A

A is the "biggest theoretical win" but the precision question is the killer. A Newton-Raphson update of `recip ← recip * (2 - div * recip)` doubles the mantissa bits per iteration when starting from a good seed, but our seed is from the previous iteration — meaning we apply the update once per iteration with no iteration-count headroom. After 240 iterations of single-step refinement, accumulated error is unbounded for the case where `div` changes by ±1 per step (the staircase). The brief itself flagged "error accumulates over 240 iters — likely needs periodic re-normalization." The cost of a re-normalization (one division to re-seed, plus a round of refinement) is the same as the original division on this CPU, so the resync frequency drives the win down to roughly Approach C's territory — but with a precision argument that's harder to make airtight in a reviewer-facing doc.

### Why C over B

B (per-callback LUT) is structurally simpler — no shared state, no cache key, no first-frame question — but it pays the table-build cost three times per frame, exactly cancelling the loop saving. **B is parity with the original.** A reviewer would correctly ask why we did the work.

### Why C over D

VFP would let us avoid `__aeabi_idiv` without an LUT, but: (a) `vrecpe.f32` gives ~9 mantissa bits; one `vrecps.f32` Newton step brings it to ~17 bits; a second brings it to ~24 — for our NUM range that's just at the edge of usable, and the int→float→int round-trip is on top. (b) The rest of the engine is integer-only; introducing VFP here means a register-class transition every iteration, which the compiler may or may not schedule well. (c) Cortex-A9 VFPv3-D16 has issue/latency penalties for round-trip moves between integer and float register banks. Approach C dominates on every axis except "lines of code" (D would be a one-line change inside the loop).

### Why C over E

The disasm shows the compiler is already as tight as it can be without algorithmic change — `movls` for the zero-guard, `mla`/`mls` for the post-divide fan-out. There's no headroom in compiler flags alone.

### Why C over F (the close call)

Approach F (memoize within each callback's loop, only divide when div changes from the previous iteration) is the most attractive bit-exact option: ~5 lines per callback, no shared state, no cache key. It wins big when `cosX` is small (steep pitch) — the divisor staircase has long flat runs, and most iterations skip the divide. But at horizon-level (`cosX = 256`, `angleX = 0`, the most common gameplay state), every iteration changes `div` by ±1 and F provides zero benefit. A user who's pointed out that the wider perf effort hasn't moved the needle on hardware is unlikely to be satisfied with a perf change whose worst case is parity in the most common scene.

C provides a consistent ~24 000 cycles/frame regardless of pitch. Its tradeoff is precision (≤1 LSB) and structural complexity (shared cache).

**Decision: ship C. Document F at the bottom of the plan as a fallback if the implement agent finds C breaks something subtle and can't fix it in <30 min.**

### Disclaimer

The disasm investigation succeeded — anchor numbers above are real. The cycle counts for `__aeabi_idiv` are estimated from public Cortex-A9 software-divide benchmarks (the actual `udivsi3` is from libgcc and varies with input magnitude); the ~50-cycle figure is a documented mid-range estimate, not a measured number. **A reviewer should treat the absolute wall-clock saving as ±30%.** The relative ordering of approaches (C > B > F-worst-case = E) is not sensitive to that uncertainty.

---

## Step plan overview

| # | Step | Risk | Wall-clock |
|---|---|---|---|
| 0 | Pre-flight: re-read source, capture disasm anchor, confirm SDL2 build dir, lock the design | none | ~10 min |
| 1 | Implement: add module-static cache + Q30 reciprocal table; wire all three callbacks; build for SDL2 | medium | ~40 min |
| 2 | Smoke desktop SDL2; A/B compare against pre-change build | low | ~20 min |
| 3 | Cross-build for MiSTer; deploy; on-device boot smoke | low | ~15 min |
| 4 | Single commit on `mister` | none | ~5 min |
| 5 | User-gated gameplay test (NOT executed by `/implement`; documented for the user) | n/a | n/a |

Steps 1, 2, 3 form one logical change. Step 4 is the commit — `/implement` does not commit between Step 1 and Step 4 (intermediate work-in-progress lives in the working tree across Steps 1–3, then a single `git add` + `git commit` at Step 4).

---

## Step 0 — Pre-flight

### Title
Verify environment, re-read source, confirm disasm anchor, lock design

### Why it matters
This plan was written with a snapshot of the source at git HEAD `c525d06b` plus the working-tree state at plan-author time. The implement agent must re-read to confirm the source hasn't drifted, and capture (or re-confirm) the disasm anchor so the perf claim has a primary source.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` lines 186–332 — confirm structure matches the plan's snapshot. In particular: each callback's inner loop is a `for (i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i)`, and the divide is `int32 h = NUM / div;` with NUM as listed in "Optimization target" of this plan.
2. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Camera.c:50–112` — confirm `clipY` and `camera->height` semantics.
3. `git status` — confirm tree state. Expected mods: `dependencies/RSDKv5` (submodule), `vendor/Main_MiSTer/sonicmania_wrapper.cpp`, `vendor/Menu_MiSTer/menu.sv`, `vendor/Menu_MiSTer/rtl/native_video_timing.sv`, untracked `grabtest.c`. If anything else is modified, STOP and ask.

### Files to create / modify
None.

### Procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
git status
git log --oneline -10
# Confirm latest commit is c525d06b or descendant.

# Confirm SDL2 baseline build is current and clean.
ls -la build-p7-fix-sdl2/libGame.dylib
grep PORT_MISTER:BOOL build-p7-fix-sdl2/CMakeCache.txt  # expect OFF
cmake --build build-p7-fix-sdl2 -- -j8                  # baseline rebuild

# Re-confirm disasm anchor (optional but recommended — establishes trust in the Win sizing table).
docker exec sonic-mania-mister-arm-build bash -c '
  arm-linux-gnueabihf-objdump -d \
    /work-mister/build/mister-telemetry/CMakeFiles/SonicMania.dir/SonicMania/Objects/All.c.o \
  | grep -E "(UFO_Setup_Scanline_Playfield|UFO_Setup_Scanline_3DFloor|UFO_Setup_Scanline_3DRoof)>:" -A 200 \
  | grep -E "__aeabi|>:"
'
# Expect: each of the three function symbols followed by exactly one bl <__aeabi_idiv> line.
```

### Success criteria
- `git status` matches expected modified-list exactly.
- SDL2 baseline rebuild exits 0; `libGame.dylib` mtime advances (or stays if no source touched).
- Disasm shows exactly one `__aeabi_idiv` call per callback. (If the count differs, the plan's win sizing is wrong — STOP and re-derive.)

### Dependencies
None.

### Out of scope
- Don't reconfigure CMake. If the build dir is stale, fall back to creating a fresh dir per the prior plan's Step 0 fallback procedure.
- Don't touch `dependencies/RSDKv5`.

### Failure mode + recovery
- **Source has drifted from snapshot.** The three callbacks now have a different shape. STOP. Update the plan's Change sketch (Step 1) to match the new shape, or hand back to the user.
- **Disasm shows multiple divides per callback.** The compiler has changed inlining. Re-derive the win-size: `divides_per_frame = N_callbacks × N_iter × divides_per_iter`. The fix shape is identical regardless.
- **SDL2 baseline build broken.** Fix the baseline first; do not start the perf work on a broken tree.

---

## Step 1 — Implement: shared per-frame Q30 reciprocal table + per-callback consumers

### Title
Add `ufo_setup_recip_*` static cache and rewrite each scanline callback's inner loop to multiply by the cached reciprocal

### Why it matters
This is the change. Single edit to one file (`UFO_Setup.c`) introducing a module-static cache plus rewriting three inner loops.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — re-read all three callbacks (186–332).
2. The change sketch below in full.

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` (only file touched)

### Change sketch

**1. Module-static cache (top of `UFO_Setup.c`, after the existing `#include "Game.h"`):**

```c
// Per-frame reciprocal cache shared across the three scanline callbacks.
// Built lazily by whichever callback runs first in a frame and observes
// a cache miss; reused by the other two.
//
// Cache key: angleX only. The divisor sequence
//   div[i] = sinX + ((-SCREEN_YCENTER + i) * cosX) >> 8
// depends only on angleX (and SCREEN_YCENTER, which is a compile-time
// constant). camera->angle does NOT enter the divisor.
//
// Sentinel value INT32_MIN is unambiguously outside any plausible
// angleX (real range is [-0x100, 0x100] per UFO_Camera), so the first
// frame always misses cleanly.
#define UFO_SETUP_RECIP_SHIFT 30
static int32 ufo_setup_cached_angleX = INT32_MIN;
static int32 ufo_setup_recip[SCREEN_YSIZE]; // Q30 reciprocals of div sequence

static inline void UFO_Setup_BuildRecipTable(EntityUFO_Camera *camera)
{
    if (camera->angleX == ufo_setup_cached_angleX) {
        return;
    }

    int32 sinX   = RSDK.Sin1024(-camera->angleX) >> 2;
    int32 cosX   = RSDK.Cos1024(-camera->angleX) >> 2;
    int32 cosVal = -SCREEN_YCENTER * cosX;

    for (int32 i = 0; i < SCREEN_YSIZE; ++i) {
        int32 div = sinX + (cosVal >> 8);
        if (!div)
            div = 1;
        ufo_setup_recip[i] = (int32)(((int64)1 << UFO_SETUP_RECIP_SHIFT) / div);
        cosVal += cosX;
    }

    ufo_setup_cached_angleX = camera->angleX;
}
```

**2. Per-callback consumer.** For each of `UFO_Setup_Scanline_Playfield`, `UFO_Setup_Scanline_3DFloor`, `UFO_Setup_Scanline_3DRoof`, inside the inner `for` loop replace:

```c
int32 div = sinX + (cosVal >> 8);
if (!div)
    div = 1;

int32 h = NUM / div;
```

with:

```c
int32 h = (int32)(((int64)NUM * ufo_setup_recip[i + SCREEN_YCENTER]) >> UFO_SETUP_RECIP_SHIFT);
```

(where `NUM` is the callback-specific numerator: `camera->height` for Playfield, `camera->height + 0x1000000` for 3DFloor, `height` (the loop-hoisted `(camera->height >> 2) - 0x600000`) for 3DRoof).

The local `int32 div = sinX + (cosVal >> 8); if (!div) div = 1;` lines, the local `cosVal += cosX;` increment at the end of the loop, and the local `int32 cosVal = -SCREEN_YCENTER * cosX;` initializer **are no longer needed inside each callback's loop body** — they all moved into `UFO_Setup_BuildRecipTable`. **However**, `sinX`, `cosX`, `sin`, `cos` ARE still needed by each callback because they're used in the `pos`/`deform`/`position` computations downstream of the divide. Keep those.

Each callback gains one new line near the top:
```c
UFO_Setup_BuildRecipTable(camera);
```
placed AFTER the existing `RSDK.SetClipBounds(...)` call (preserving the Item 4 invariant that `SetClipBounds` runs even when the function would otherwise short-circuit) and AFTER the trig setup (the trig values are needed both by `BuildRecipTable` indirectly via the cache miss path, and by the callback's own pos/deform math).

**Wait — there's a subtlety.** The existing callbacks compute `int32 sinX = RSDK.Sin1024(-camera->angleX) >> 2;` etc. at the top, then use them in two places: (1) the divisor (now eliminated) and (2) the `pos = (cosX * h) >> 8 - sinX * ...` post-divide math. The `BuildRecipTable` helper internally recomputes `sinX/cosX` from `camera->angleX`. That's a duplicate trig call PER FRAME on a cache miss, but `Sin1024`/`Cos1024` are LUT lookups (`dependencies/RSDKv5/RSDKv5/RSDK/Math/Math.cpp`), each ~3 cycles. The duplicate cost is negligible; the alternative — passing `sinX/cosX` into the helper — pollutes the helper's signature for no real saving.

**3. Final per-callback shape (for reference; the implement agent reproduces this for all three with appropriate NUM and bank-shift):**

```c
void UFO_Setup_Scanline_Playfield(ScanlineInfo *scanlines)
{
    EntityUFO_Camera *camera = RSDK_GET_ENTITY(SLOT_UFO_CAMERA, UFO_Camera);

    RSDK.SetClipBounds(0, 0, camera->clipY, ScreenInfo->size.x, ScreenInfo->size.y);

    int32 sin  = RSDK.Sin1024(camera->angle) >> 2;
    int32 cos  = RSDK.Cos1024(camera->angle) >> 2;
    int32 sinX = RSDK.Sin1024(-camera->angleX) >> 2;
    int32 cosX = RSDK.Cos1024(-camera->angleX) >> 2;

    UFO_Setup_BuildRecipTable(camera);

    int32 bandStart = 0;
    int32 bandBank  = -1;

    for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i) {
        int32 h             = (int32)(((int64)camera->height * ufo_setup_recip[i + SCREEN_YCENTER]) >> UFO_SETUP_RECIP_SHIFT);
        scanlines->deform.x = (-cos * h) >> 8;
        scanlines->deform.y = (sin * h) >> 8;

        int32 pos  = ((cosX * h) >> 8) - (sinX * ((i * h) >> 8) >> 8);
        int32 bank = CLAMP(abs(pos) >> 15, 0, 7);
        int32 line = i + SCREEN_YCENTER;

        if (bank != bandBank) {
            if (bandBank >= 0)
                RSDK.SetActivePalette(bandBank, bandStart, line);
            bandStart = line;
            bandBank  = bank;
        }

        scanlines->position.x = (sin * pos - ScreenInfo->center.x * scanlines->deform.x) + camera->position.x;
        scanlines->position.y = (cos * pos - ScreenInfo->center.x * scanlines->deform.y) + camera->position.y;

        scanlines++;
    }

    if (bandBank >= 0)
        RSDK.SetActivePalette(bandBank, bandStart, SCREEN_YSIZE);
}
```

Note the two structural changes versus today:
- Removed the per-iteration `int32 div = ...; if (!div) div = 1;` and `cosVal += cosX;` lines.
- Removed the local `int32 cosVal = -SCREEN_YCENTER * cosX;` initializer (cosVal is now a local in `BuildRecipTable`).

3DFloor: NUM is `camera->height + 0x1000000`; bank formula is `CLAMP((abs(pos) >> 15) - 8, 0, 7)`; deform.x is `-(cos * h) >> 8` (unary minus inside, NOT `(-cos * h) >> 8` — these differ in sign of intermediate; preserve the original); SetClipBounds uses `camera->clipY + 24`.

3DRoof: NUM is `height` (the loop-hoisted local), where `int32 height = (camera->height >> 2) - 0x600000;` is preserved at top of the function; bank formula is `CLAMP(abs(pos) >> 14, 0, 7)`; deform.x is `-(cos * h) >> 8`; SetClipBounds uses `0` and `camera->clipY - 48`. The Item 4 early-return `if (camera->clipY <= 48) return;` runs BEFORE `UFO_Setup_BuildRecipTable(camera);` — that means the roof callback does NOT trigger a rebuild when fully clipped, which is correct (the table is unused in that case; a Floor or Playfield call later in the frame will trigger the rebuild if needed).

**4. The Item-4 early-return interaction.** Roof's early return-out (`if (camera->clipY <= 48) return;`) lives between `SetClipBounds` and the trig setup TODAY. After this change, it should still live there. The trig setup, `BuildRecipTable`, and the rest of the function all execute only when the early-return doesn't fire. Confirm the order:

```c
void UFO_Setup_Scanline_3DRoof(ScanlineInfo *scanlines)
{
    EntityUFO_Camera *camera = RSDK_GET_ENTITY(SLOT_UFO_CAMERA, UFO_Camera);

    RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, camera->clipY - 48);

    if (camera->clipY <= 48)
        return;                               // <-- preserved from Item 4

    int32 sin  = RSDK.Sin1024(camera->angle) >> 2;
    // ...trig setup...
    UFO_Setup_BuildRecipTable(camera);        // <-- new
    int32 height = (camera->height >> 2) - 0x600000;
    // ...rest of loop, using ufo_setup_recip[i + SCREEN_YCENTER]...
}
```

### Inline-vs-helper for the consumer

The consumer is a single `int32 h = (int32)(((int64)NUM * ufo_setup_recip[idx]) >> SHIFT);` line per callback — no helper for that. A helper would only obscure the per-callback NUM difference. The shared piece (the cache + `BuildRecipTable`) IS a helper, justified because it's nontrivial state and is shared across all three callbacks.

### Success criteria
- File compiles in the SDL2 desktop build (Step 2 verifies).
- `git diff --stat` shows exactly one file changed (`SonicMania/Objects/UFO/UFO_Setup.c`); rough sizing `+50/-15` (cache + helper added; per-callback divide site replaced; per-callback `cosVal` declarations and increments removed).
- The three callbacks each have:
  - `RSDK.SetClipBounds(...)` first
  - (Roof only) `if (camera->clipY <= 48) return;` second
  - Trig setup third
  - `UFO_Setup_BuildRecipTable(camera);` fourth
  - Per-callback NUM hoisted local (or computed at first use)
  - The Item-1 palette band-tracker init (`bandStart = 0; bandBank = -1;`)
  - Inner loop with the new multiply-by-recip line and NO `int32 div`, NO `if(!div)`, NO `cosVal += cosX;`
  - The Item-1 trailing palette flush
- Module-static cache declared above all three callbacks (top of file, after `#include`).

### Dependencies
Step 0 passed.

### Out of scope
- Do NOT touch `dependencies/RSDKv5`.
- Do NOT modify `UFO_Setup_Deform_*` callbacks; they don't divide.
- Do NOT modify `UFO_Setup_DrawHook_PrepareDrawingFX` to invalidate the cache. The angle-key check handles invalidation correctly without an explicit hook.
- Do NOT change the `int32 cosVal = -SCREEN_YCENTER * cosX;` arithmetic. Inside `BuildRecipTable`, this initializer must match the per-callback original byte-for-byte to preserve bit-equivalence on the divisor sequence.

### Failure mode + recovery
- **Compile error: signed/unsigned comparison or `int64` typedef missing.** RSDK uses `int64`/`int32` typedefs from `<stdint.h>` via `RetroEngine.hpp`. They're in scope already. If not, `#include <stdint.h>` at the top.
- **Compile error: `INT32_MIN` undefined.** `INT32_MIN` is from `<stdint.h>`, which is already in scope via `RetroEngine.hpp`. If a stricter unit somehow lacks it, `#include <limits.h>` and use `INT_MIN` instead, or write `(-2147483647 - 1)` literally.
- **Compile warning: implicit truncation `int64 → int32` on the result.** Add the explicit `(int32)` cast as shown.
- **Multiplication overflow.** `(int64)NUM * recip` uses 64-bit arithmetic. Worst-case NUM bound (consistent with risk-table): camera->height can swing to ~2^25.3 via the Springboard branch (`UFO_Camera.c:104`: `(target->height >> 1) - (Sin1024(angleX) << 14) + 0x400000`, where `Sin1024 << 14` reaches ±2^24); 3DFloor's NUM is `camera->height + 0x1000000`, reaching ~2^26 nominally and bounded by ~2^29 once `target->height` extremes from `State_CourseOut` / `State_UFOCaught` accumulators are admitted. Use NUM ≤ 2^29 as the conservative bound. recip ≤ 2^30 (when div=1). Product ≤ 2^59. Fits in int64 (max 2^63). Verified.
- **Negative div, negative recip — wrong sign on h.** Q30 reciprocals preserve sign through integer division: `((1<<30) / -3) = -357913941` (a negative int32). Multiply with positive NUM gives correct negative product. Multiply with negative NUM gives correct positive product. Sign is correctly handled.
- **div underflow on the cache miss path.** `cosVal` after 240 increments has accumulated `240 * cosX`, max `240 * 256 = 61440`, plus the initial `-120 * 256 = -30720`, total range `[-30720, +30720]`. `cosVal >> 8` in `[-120, +120]`. Plus `sinX` in `[-256, +256]`. So `div ∈ [-376, +376]` plus the zero-guard. Reciprocal range `(2^30) / [-376..+376] = [-2.85M, +2.85M]` — fits in int32. Verified.

---

## Step 2 — Smoke desktop SDL2 + A/B compare

### Title
Rebuild SDL2, run a brief gameplay smoke, A/B compare the per-pixel output

### Why it matters
The change introduces a documented ≤1 LSB tolerance on `h`. We need to confirm the visible result IS visually identical (the algebra says it should be, but algebra and shipping are different). The A/B step gives the implement agent objective evidence to attach to the commit body if a reviewer challenges precision.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/build-p7-fix-sdl2/CMakeCache.txt` — re-confirm `PORT_MISTER:BOOL=OFF`.

### Files to create / modify
None.

### Procedure

```bash
cd /Users/sb/Developer/sonic-mania-mister

# 1. Build with the change in tree.
cmake --build build-p7-fix-sdl2 -- -j8
# Expect: clean build. Touched file: UFO_Setup.c.

# 2. Run, get to a special stage (UFO5 if dev shortcuts allow — Plasma is the
#    most demanding case; otherwise UFO1 for default).
#    The implement agent will likely lack hands-on game data; if the dev menu
#    cannot reach the special stage from a fresh boot, document and skip the
#    runtime portion of this step. Build-pass alone is acceptable for compile-
#    correctness; the on-device smoke (Step 3) and the user-gated test (Step 5)
#    cover gameplay.

# 3. (Optional, if runtime works.) A/B against the pre-change build.
#    Easiest: keep the change in working tree, stash + rebuild + screenshot,
#    pop + rebuild + screenshot, diff with ImageMagick.
git stash
cmake --build build-p7-fix-sdl2 -- -j8
# screenshot pre-change frame to /tmp/pre.png from the same camera angle
git stash pop
cmake --build build-p7-fix-sdl2 -- -j8
# screenshot post-change frame to /tmp/post.png from the same camera angle
compare -metric AE /tmp/pre.png /tmp/post.png /tmp/diff.png  # ImageMagick
# Expect: AE (absolute pixel error count) at 0 or single-digit; diff.png
# shows essentially black with a few stray pixels at sub-pixel boundaries.
```

### Tolerance for non-bit-exact results

Per the precision analysis, `|h_calc - h_true| ≤ 1`. That 1-LSB on `h` propagates to ≤1-LSB on `deform.x/y` (post `>> 8`) and ≤1-LSB on `position.x/y`. Both are 16.16 fixed-point screen positions; 1 LSB = 1/65536 of a pixel — sub-sub-pixel.

The visible output is rasterized to integer pixels by the engine's tile-layer renderer. Sub-sub-pixel positional noise can occasionally rasterize to a different integer pixel, which shows as a single-pixel color shift on a band boundary. The A/B compare may show single-digit AE counts on a 320×240 = 76 800 pixel frame — that's <0.01% of pixels, imperceptible during motion.

**Documented acceptance criterion:** `|h_new - h_old| ≤ 1` everywhere, OR pixel-AE between SDL2 builds < 100 on a static frame, OR (if A/B not feasible) visual-inspection identical during motion.

### Visual checks (if a runnable build is produced)

- **Get to UFO5 (Plasma + 3D Floor + 3D Roof + heavy sphere field).** Easiest path: dev menu, scene select, "Special Stage" → UFO5.
- **Watch for these specifically:**
  - Floor/Playfield/Roof bands — should look identical to the pre-change build at any given camera pose. Item-1 RLE coalescing already shipped, so the visible bands are coarse to begin with.
  - Camera turning + pitching — the bands should slide smoothly; no sudden snap or shimmer.
  - Looking up vs looking down — bands re-form continuously.
  - Spheres at far distance — their position depends on the projection matrix, NOT this change; should be identical.
- **Watch for these regressions:**
  - Banded color seams jumping by 1 line as camera moves (bank computation is downstream of `pos`, which is downstream of `h`; a small `h` error CAN shift bank-boundary line by 1).
  - Floor/Roof texture appearing to "swim" at certain pitch angles (would indicate `h` error > 1, i.e. the precision claim is wrong).
  - Any visible numeric overflow (textures wrapping wildly) — would indicate a sign-handling bug in the recip multiply.

### Success criteria
- Build exits 0 with no new warnings introduced by our edit (existing warnings are fine).
- If runtime smoke executed: visual checks pass; A/B compare shows AE < 100 (or visual-identical at human eye).
- If runtime smoke skipped (no data pack reachable): document in the wrap-up note at the bottom of this file and proceed.

### Dependencies
Step 1 complete (working tree has the change).

### Out of scope
- Do NOT benchmark on desktop — desktop has a hardware divider, so `__aeabi_idiv` is irrelevant; perf measurement is only meaningful on the MiSTer ARM. Step 3 is the relevant benchmark venue (and even there, we don't bench in this plan — F12 telemetry on hardware is the user-gated Step 5 path).
- Do NOT add new test infrastructure or screenshot-capture tooling. Use what's there.

### Failure mode + recovery
- **Build break:** typo in the change. Re-read the change sketch.
- **Visible "swimming" at certain angles:** precision tolerance breached. First check: are you using `(int64)NUM * recip` (signed 64-bit) and not `NUM * recip` (32-bit, will overflow)? Second check: is the Q-shift `>> 30` and not `>> 32` or `>> 24`? Third check: is the cache key correctly recomputing on every angle change (`angleX` updates per frame during pitch)?
- **First-frame-after-stage-load garbage:** the static cache key has uninitialized values that happen to match the first frame's `angleX = 0`. The plan specifies `ufo_setup_cached_angleX = INT32_MIN;` as initializer, which is unambiguously outside any plausible runtime range. Confirm.

---

## Step 3 — Cross-build for MiSTer + deploy + on-device boot smoke

### Title
Cross-compile telemetry-flavor armhf, deploy to MiSTer, confirm clean boot

### Why it matters
This is the actual target hardware. Desktop SDL2 is the local-test loop, but the perf claim is meaningless without a MiSTer build that runs.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — confirm canonical build/deploy commands and post-`26a717ba` lowercase install path.

### Files to create / modify
None.

### Procedure

```bash
cd /Users/sb/Developer/sonic-mania-mister

# 1. Cross-build telemetry flavor.
bash tools/mister/build-game.sh --flavor telemetry
# Expect: clean build. Output at build/mister-telemetry-package/.

# 2. Deploy.
MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 \
    bash tools/mister/deploy-to-mister.sh
# Expect: rsync completes; whitelist allows /media/fat/games/sonic-mania/
# (lowercase, post-26a717ba canonical).

# 3. Boot smoke (10s timeout).
sshpass -p 1 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@192.168.1.188 \
    'timeout -s TERM 10 /media/fat/games/sonic-mania/scripts/run-mania.sh' \
    2>&1 | tee /tmp/mania-smoke-item2.log
# Expect: engine logs banner, attempts Data.rsdk, exits cleanly within 10s,
# OR reaches title screen and gets SIGTERM'd by the wrapper after the 10s
# bound — both are PASS; the prior-known FAIL pattern is the engine spinning
# inside SDL_CreateRenderer (no banner, no log, just timeout).
```

### Success criteria
- `build-game.sh --flavor telemetry` exits 0; produces `build/mister-telemetry-package/bin/RSDKv5U` (armhf ELF, verified by `file` automatically by build-game.sh).
- `deploy-to-mister.sh` exits 0; on-device `ls /media/fat/games/sonic-mania/bin/` shows the new binary mtime.
- 10s smoke: log shows the engine banner + Data.rsdk path attempt OR reaches title and is SIGTERM'd. No `Illegal instruction`, no `Segmentation fault`.

### Dependencies
Step 2 passed (or skipped with documentation).

### Out of scope
- Do NOT do an extended gameplay test on hardware — that's user-gated Step 5.
- Do NOT collect F12 telemetry frames. The frame-time impact of one item is below the F12 dump's noise floor; meaningful measurement requires Items 2+3+5+6 stacked.

### Failure mode + recovery
- **Cross-build fails with new warning-as-error:** check the new code for portability issues (e.g., `int64` literal — use `(int64)1 << 30` not `1LL << 30` to match Mania style; both work but the cast form is consistent).
- **`Illegal instruction` on hardware:** would indicate VFP/NEON misuse, but our change is pure integer/scalar — re-examine. Most likely culprit: a stray `(double)` cast accidentally introduced.
- **Smoke hangs past 10s:** SDL_CreateRenderer issue, almost certainly unrelated to this change. Verify by reverting the working-tree change (`git stash`), re-building, re-deploying — if the hang persists, it's not Item 2.

---

## Step 4 — Single commit on `mister`

### Title
Commit the change as one logical unit

### Why it matters
Locked decision: this is one commit. Three callbacks + the shared cache helper are one logical change; splitting is a worse story for `git revert`.

### Files to read first
None.

### Files to create / modify
None new — commits the existing working-tree change to `UFO_Setup.c`.

### Procedure

```bash
cd /Users/sb/Developer/sonic-mania-mister
git status                  # confirm only UFO_Setup.c is modified (plus pre-existing list)
git diff SonicMania/Objects/UFO/UFO_Setup.c | head -200   # sanity-check the diff
git add SonicMania/Objects/UFO/UFO_Setup.c
git commit -m "$(cat <<'EOF'
mister: replace per-scanline divide with shared Q30 reciprocal table

The three UFO_Setup_Scanline_* callbacks each do a 240-iteration loop
with one __aeabi_idiv per iteration (computing h = NUM / div where
div advances roughly-linearly from a sin/cos staircase). On the HPS
Cortex-A9 (no hardware integer divider), each idiv is ~50 cycles
software-emulated, putting ~36 000 cycles per frame on the divide
hot path across the three callbacks.

Replace with a shared per-frame Q30 reciprocal table. The divisor
sequence depends only on camera->angleX (via sinX/cosX from
Sin1024/Cos1024 of -angleX), which is fixed for the duration of a
frame's draw phase, so the table is identical across the three
callbacks. A module-static cache built lazily on the first cache
miss per frame amortizes the 240 build divisions across all three
callbacks: 240 div + 720 mul per frame, versus the original 720 div
+ 720 mul. Net win ~480 div = ~24 000 cycles ≈ 40 μs at 600 MHz HPS.
Cache also survives across frames when angleX is stable (common
during pure-yaw motion: player turns, pitch held at horizon),
saving the build entirely on those frames.

Precision: with Q30 reciprocals and 64-bit intermediate multiply,
worst-case |h_new - h_old| <= 1. Algebra under the rationale in
docs/ufo-special-stage-perf-item2-plan.md. The 1-LSB error on h
propagates to <=1 LSB on the 16.16 fixed-point screen positions
(deform.x/y, position.x/y), i.e. 1/65536 of a pixel — sub-sub-pixel
in the rasterized output, imperceptible during motion.

Cache key camera->angleX (the only field that enters the divisor);
invalidates on any pitch change. First-frame initializer
ufo_setup_cached_angleX = INT32_MIN puts the sentinel unambiguously
outside any plausible angle resolution, so the first frame after
stage-load always misses cleanly.

No SIMD, no VFP, no compiler-flag changes. RSDKv5 submodule
untouched.

Item 2 from the wider UFO Special Stage perf investigation. Items
1, 4, 7 already shipped (7541c0d2, e6115147, 5735e614). Items 3, 5,
6 remain; Item 3 (sphere/ring radius cull) is the next-best
low-risk follow-up if more headroom is needed.
EOF
)"
git log --oneline -3
```

### Success criteria
- `git status` after commit shows the same pre-existing modified-list as Step 0 (no new modifications).
- `git log --oneline -3` shows the new commit on top, with `mister:` prefix matching house style.
- Single commit, no squash, no amend.
- `git revert <hash>` would cleanly undo the entire change.

### Dependencies
Steps 1, 2, 3 done.

### Out of scope
- Do NOT push to remote. The user has not requested it.
- Do NOT amend the prior items 1/4/7 commits. They're separate.
- Do NOT touch the submodule.

### Failure mode + recovery
- **Diff shows unexpected files modified:** unstage them; commit only `UFO_Setup.c`.
- **Pre-commit hook fails:** investigate root cause; do NOT skip the hook. Fix and create a NEW commit (per global guidance — never amend).

---

## Step 5 — User-gated gameplay test (NOT executed by `/implement`)

### Title
User-driven sanity check on actual hardware in actual gameplay

### Why it matters
Items 1/4/7 reportedly didn't move the needle. This change is the largest in the perf series. The user is the only one who can actually drive UFO5 with a controller, see the visible result, and feel whether the frame budget improved. This step is documentation for the user, NOT something `/implement` runs.

### Procedure (user-side)

After `/implement` completes:

1. SSH to MiSTer and tail the log: `ssh root@192.168.1.188 'tail -F /tmp/sonicmania.log'`
2. Boot Sonic Mania from the `_Other/` menu.
3. Get to UFO5 (Plasma stage). Either play through, or use the dev-menu shortcut if enabled.
4. Once in UFO5, press F12 (or the MiSTer-mapped equivalent) to dump pacer jitter; record `phase_err` and `late(>500us)=N`.
5. Look up, look down, sweep camera around. Watch for:
   - **Banding seams shifting by 1 line during slow camera motion** — would be the precision tolerance becoming visible at a band boundary. Acceptable per the documented ≤1 LSB.
   - **Texture "swimming" or numeric overflow** — UNACCEPTABLE. Indicates a precision bug.
   - **Frame rate** — should be at or above the prior-Item-1/4/7 baseline. The budget freed (~40 μs) is too small to perceive on its own at 60 fps but should NOT regress.
6. Stack with Item 3 (sphere/ring radius cull) when that lands — perceptible improvement is more likely from the stack.

If anything visibly regressed: `git revert <commit>` on `mister`, redeploy, file a wrap-up note at the bottom of this plan documenting the symptom.

### Success criteria
- No visible textur swimming.
- Banding seams identical or shifted by ≤1 line during motion.
- F12 jitter dump: `late(>500us)` count not increased vs. pre-Item-2 baseline.

### Dependencies
Steps 1–4 complete; user has hands on hardware.

### Out of scope (for `/implement`)
- This step is user-driven. The agent does not execute it.

### Failure mode + recovery (for the user)
- **Visible swimming/garbage:** revert the commit, redeploy, document.
- **Frame rate regressed:** unexpected — the change cannot be slower than baseline barring instruction-cache thrash from the new helper. Possible but unlikely. If observed, revert and document.
- **No subjective change:** expected. Item 2 is ~40 μs/frame; <1% of a 60 Hz budget. Not perceivable in isolation.

---

## Validation strategy

### Local-test loop (SDL2 on macOS)

- Build dir: `build-p7-fix-sdl2/` (PORT_MISTER:BOOL=OFF, confirmed Step 0).
- Rebuild: `cmake --build build-p7-fix-sdl2 -- -j8`.
- A/B compare: `git stash` to revert tree, build, screenshot, `git stash pop`, build, screenshot, `compare -metric AE pre.png post.png diff.png`.
- Tolerance: AE < 100 on a 320×240 frame, OR visually identical during motion.

### Hardware target (HPS Cortex-A9)

- Build dir: `build/mister-telemetry/` (telemetry flavor, telemetry no-ops in clean flavor).
- Cross-build: `bash tools/mister/build-game.sh --flavor telemetry`.
- Deploy: `MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 bash tools/mister/deploy-to-mister.sh`.
- Boot smoke: 10s timeout SSH command (per Step 3).
- Live perf inspection: F12 telemetry dump while in UFO5 (per Step 5).

### Tolerance for non-bit-exact

`|h_new - h_old| ≤ 1` is acceptable per the precision argument. This propagates as documented to ≤1 LSB at the 16.16 screen-position level (1/65536 pixel). If the user observes anything larger than this — e.g., bands seams shift by more than 1 line during slow camera motion, or textures appear to swim at certain pitches — the precision claim is wrong and we revert.

---

## Risk table

| Risk | Severity | Mitigation | Notes |
|---|---|---|---|
| **Precision drift > 1 LSB** | high | Q30 with 64-bit intermediate; algebra-bounded in plan; A/B compare in Step 2. | Worst case derived (consistent bound across this plan): NUM ≤ 2^29 (3DFloor NUM under camera->height worst-case from `UFO_Camera.c:104` Springboard path), recip = floor(2^30/div), error term `NUM*r/(div*2^30) < NUM/2^30 ≤ 2^29/2^30 = 0.5 < 1`. See Approach C above. |
| **Visual regression in motion only (not stills)** | medium | Step 5 user-gated test sweeps camera through full pitch range (look up, look down, mid-pitch). Step 2 A/B is static-frame; Step 5 is the motion test. | Likely manifestation: 1-pixel band-boundary jitter under continuous pitch motion. Acceptable per tolerance. |
| **Cache stale across frames** | medium | Cache key angleX only. Updates from the camera every frame in Update phase BEFORE Draw. Sentinel angleX = INT32_MIN for first-frame cleanliness. | The sentinel must be outside the runtime [-0x100, +0x100] range that `UFO_Camera_HandleCamPos` produces; INT32_MIN is unambiguously outside any plausible angle resolution. |
| **`int64` overflow in the multiply** | low | `NUM ≤ 2^29 (worst-case from UFO_Camera.c:104 Springboard path), recip ≤ 2^30, product ≤ 2^59, well below int64 max 2^63`. ARM `smull` is single-instruction. | Confirmed by the bounds analysis. |
| **Negative `div` mishandled** | medium | Q30 signed reciprocal preserves sign through `(1<<30)/div`; signed multiply preserves sign through `(int64)NUM * recip`. ARM `smull` handles signed. | A common bug class with reciprocal LUTs is to take `abs(div)` and re-sign — avoid that. The C-language signed integer division and multiplication just work. |
| **`div = 0` despite the guard** | low | Guard preserved verbatim inside `BuildRecipTable`. div=0 → reset to 1, recip = 2^30. | The original code's `if (!div) div = 1;` covered this; we move the same guard to the table-build site. |
| **`sinX/cosX` near zero** | low | When `cosX = 0` (extreme pitch), `cosVal` doesn't change; div = sinX everywhere; recip table is filled with one repeated value. Multiply is correct. When `sinX = 0` AND `cosX` small, div crosses zero somewhere along the loop and the guard fires for that iteration only. Both cases correctly handled. | Confirmed by walking through the math. |
| **Camera->height extremes** | low | NUM range derived from `UFO_Camera.c:104, :110`: `(target->height >> 1) - (sin(angleX) << 14) + 0x400000` or `(target->height >> 2) + 0x400000`. Both scale with `target->height`, which is `int32` and bounded by player physics. Even in the springboard/free-fall extreme, `target->height` is bounded < 2^28 by the player physics; `camera->height` < 2^29; `+ 0x1000000` keeps it < 2^29. Product `NUM * recip` < 2^29 × 2^30 = 2^59 — fits in int64. | Estimate margin is 16 bits; safe. |
| **Compiler scheduling / register pressure** | low | The new inner loop is shorter (no divide-call-clobber) so register pressure DROPS. Compiler should produce equally-good or better code. | Verify by re-disassembling at Step 3 — but this is optional, not blocking. |
| **First-callback-per-frame ordering assumption** | low | The plan does NOT depend on a specific callback running first. Whichever runs first observes a miss and builds. The other two see a hit. Worst case (engine reorders or skips a layer): one rebuild that's wasted. | The roof's Item-4 early-return MIGHT skip the rebuild if Roof would have been the first callback — but Floor or Playfield will rebuild later in the same frame on first-use. Not a correctness risk. |
| **MiSTer multi-layered draw flow re-entrancy** | low | RSDK is single-threaded: `RetroEngine.cpp:410-431` calls `ProcessInput` → `ProcessObjects` → `ProcessObjectDrawLists` sequentially in one thread (no thread spawn), and `Object.cpp:739` (`for (int32 l = 0; l < DRAWGROUP_COUNT; ++l)`) drives all draw dispatch as a straight-line loop. The MODCB scanline / draw callbacks at `Object.cpp:780-797` execute synchronously inside that loop. No locks needed for the static cache. | Confirmed by primary-source citation above. |

---

## Rollback story

Single commit on `mister` (per Locked decisions). To roll back:
```bash
git revert <hash>
```
This restores the per-iteration `__aeabi_idiv` call in all three callbacks AND removes the static cache. Bit-exact-correct revert; no manual cleanup.

If the user wants to roll back ONLY one callback (e.g. they observe Roof regressed but Floor is fine), they'd need to manually edit — but that's a structural argument for keeping all three callbacks on the new path together. The shared cache makes per-callback split-revert more painful than it's worth.

---

## Build + deploy reminder

- **Cross-build:** `bash tools/mister/build-game.sh --flavor telemetry`
- **Deploy:** `MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 bash tools/mister/deploy-to-mister.sh`
  - Post-`26a717ba`: deploys to lowercase `/media/fat/games/sonic-mania/` (the canonical install path; `Data.rsdk` and `SaveData.bin` already live here from prior deploys).
  - The CamelCase `/media/fat/games/SonicMania/` path is dead; do NOT manually `rsync` to it.
- **Boot smoke (10s):** see Step 3 procedure block.

---

## Fallback plan: Approach F (memoize prev_div within each callback)

If the implement agent finds Approach C breaks something subtle and cannot fix it within ~30 minutes, the safer fallback is Approach F — memoize the previous `div` within each callback, only invoke `__aeabi_idiv` when `div` differs from the previous iteration's value. The shape:

```c
int32 prev_div = INT32_MAX;
int32 h = 0;
for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i) {
    int32 div = sinX + (cosVal >> 8);
    if (!div) div = 1;
    if (div != prev_div) {
        h = NUM / div;
        prev_div = div;
    }
    // ...rest of body...
    cosVal += cosX;
}
```

- **Bit-exact** versus the original.
- **No shared state**, no cache, no precision concern.
- **Variable win.** Worst case (cosX=256, horizon level): zero benefit, divide every iteration. Best case (cosX=0, no pitch): one divide per loop. Typical case (cosX~64, modest pitch): ~75% reduction.

If Approach F is shipped instead of C, document that pivot in the commit body and the wrap-up note at the bottom of this file. Re-do the plan win-sizing table to reflect F's actual performance characteristics (variable, not consistent).

---

## Wrap-up

Append any deferred issues, runtime-smoke notes, or unexpected findings to a section here named `## Plan execution notes — <date>` at the bottom. Do not modify earlier sections of this file.

## Plan execution notes — 2026-04-26

Plan executed end-to-end via a single `/implement` pass (implement → review → fix → verify → commit). Approach C (shared per-frame Q30 reciprocal table) shipped as designed; fallback Approach F not needed.

**Commit:** `9678afb0` — `mister: replace per-scanline divide with shared Q30 reciprocal table` on `mister`. Single commit per Locked Decision.

**Deviations from plan (justified):**
- **`(long long)` instead of `(int64)` for the 64-bit intermediate cast.** RSDK's `int64` typedef lives inside the C++ `RSDK` namespace and isn't visible from the C unity-build TU at `SonicMania/Objects/All.c`. `(long long)` is the underlying type and produces the same `smull` codegen on ARM. SDL2 desktop and armhf cross-build both clean.
- **Sentinel literal `(-2147483647 - 1)` instead of `INT32_MIN`.** Plan explicitly authorized this as an acceptable form. (Implementer's rationale that `<stdio.h>` brings `INT32_MIN` transitively on the SDL2 desktop build is empirically wrong — `<stdint.h>` is the canonical source either way — but the literal is functionally equivalent and the code is correct. Flagged as a P-2 in the implement-review for the rationale only; not worth a follow-up commit + redeploy churn.)
- **Step 2 A/B desktop runtime compare skipped** per plan's explicit allowance ("if running interactively isn't possible from a headless agent context, the build-pass smoke is acceptable since the changes are mathematically deterministic").

**Review-cycle findings:** zero P-1, two cosmetic P-2 from the implementation review (`docs/ufo-special-stage-perf-item2-implement-review.md`). Both flagged as worth tightening if Item 3 forces a re-touch:
1. Misleading `<stdint.h>` rationale in commit body and source comment (code itself correct).
2. Redundant sinX/cosX recomputation between BuildRecipTable and each callback (4 LUT lookups/frame on cache miss; tiny).

**Deploy:** cross-built telemetry-flavor armhf via `tools/mister/build-game.sh --flavor telemetry`; deployed via the now-fixed `tools/mister/deploy-to-mister.sh` (lowercase canonical path, post `26a717ba`). On-device binary BuildID `8c726c5755f3838c3ad1629c45ea29fd695ccb60` matches host. Boot-smoke ran 8s through engine init → SigHandler → MiSTerRenderDevice → NativeVideoWriter (320×224) → clean SIGTERM exit. No crash.

**Honest expectation:** ~24k cycles/frame saved (~40 μs at 600 MHz HPS, ~0.24% of a 60 fps budget). Not dramatic on its own. The wider perf effort assumed Items 2 + 3 + 5 + 6 stack; Item 2 alone may not be perceptible in casual play but should show up in F12 jitter dumps.

**Next:** user-gated gameplay test (Step 5). Drive UFO5 (the heaviest case — Plasma + 3D Roof active), look for any visual regression in scanline-band texture during slow camera motion, capture an F12 telemetry dump for jitter comparison if perceptible.
