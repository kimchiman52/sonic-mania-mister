# UFO Special Stage — Bundled Low-Risk Perf Plan

**Document date:** 2026-04-25
**Status:** Plan only. To be executed in a single `/implement` pass.
**Branch:** `mister`
**Scope:** Three independent low-risk optimizations to the UFO Special Stage rendering hot path. All edits are in `SonicMania/Objects/UFO/`. The RSDKv5 submodule (`dependencies/RSDKv5`) is NOT modified.

**Companion docs (skim, but only for tone — this plan is self-contained):**
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-9-plan.md` — in-house plan-doc structure (8-field steps, success criteria, failure-mode + recovery).

**Source-of-truth files for the changes (must be re-read by `/implement` before editing):**
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — three scanline callbacks (Items 1 + 4).
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c` — Item 7's primary target.
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Camera.c` — `clipY` is set at line 70 (read for Item 4 verification).

**Engine contracts already verified by the plan author (do not re-derive):**
- `RSDK.SetActivePalette(bank, start, end)` writes `bank` to `gfxLineBuffer[start..end-1]` (`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Palette.hpp:44-48`). Coalescing N adjacent same-bank single-line calls into one `[start, end)` call is bit-equivalent.
- `RSDK.SetClipBounds(screen, x1, y1, x2, y2)` clamps each value to `[0, screen->size.{x,y}]` (`dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:325-337`). When `clipY <= 48`, the roof's `SetClipBounds(0, 0, 0, w, clipY-48)` clamps `y2` to 0 → empty clip → tile-layer renders zero rows.
- Scanline callbacks fire from `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:782-783`, immediately before that layer's tile-layer render. `SetClipBounds` is screen-wide state; if a callback is skipped, the prior callback's clip leaks. Item 4 must therefore still call `SetClipBounds` before early-returning. Verified: `Object.cpp:800-820` resets clip bounds back to full screen at the END of each drawGroup's tile-layer loop, so the leak window is only between adjacent layers WITHIN the same drawGroup. Both 3D Floor and 3D Roof are placed in `drawGroup[0] = 0` (`UFO_Setup.c:95, :104`), so the leak path is real for them — the Roof's `SetClipBounds` must run before any early-return.
- The Setup prepare hook (`UFO_Setup_DrawHook_PrepareDrawingFX`, `UFO_Setup.c:180-184`) resets `gfxLineBuffer` to bank 0 each frame in stages that use it — registered for drawGroup 1, plus drawGroup 3 in non-Plasma stages (UFO5's `UFO_Plasma_StageLoad` overwrites the drawGroup-3 hook at `UFO_Plasma.c:71`). Item 1's coalescer doesn't depend on this default — each callback writes a bank for every scanline `[0, SCREEN_YSIZE)` exactly as the original per-line loop does, so no scanline is ever left at the prepare-hook default during a UFO callback's region.

**Locked decisions (DO NOT REVISIT):**
- One `/implement` pass, three commits — one per item — so each is independently revertible. Commit order matches step order.
- No helper function for Item 1 — coalescing is inlined in each of the three callbacks. Justification under Step 2.
- Item 4's early-return MUST occur AFTER `SetClipBounds` to avoid leaking the prior callback's clip into the roof's tile render.
- Item 7's fix replaces the inner `if` with an early-return that gates BOTH projection-update AND `DrawSprite`. The early-return condition is `drawGroup != 4 || zdepth < 0x100`. The `zdepth < 0x100` arm is the actual correctness fix (behind-camera stale drawPos); the `drawGroup != 4` arm is defensive code preserved from the original guard (unreachable in normal operation given the engine dispatches each entity from exactly one drawGroup per frame).
- Other UFO_*_Draw functions were audited (see Step 3 "Audit results"); only `UFO_Sphere` exhibits the bad pattern. `UFO_Ring`, `UFO_Dust`, `UFO_Springboard`, `UFO_Decoration`, `UFO_Shadow`, `UFO_Player`, `UFO_SpeedLines` are already correctly gated. `UFO_ItemBox` has a different shape (gates on state, not zdepth) and is intentionally left alone.
- Validation is desktop SDL2 only (we cannot reach MiSTer hardware from this session). The freshest SDL2 build dir is `/Users/sb/Developer/sonic-mania-mister/build-p7-fix-sdl2/`. We rebuild in-place.

**What NOT to do:**
- Do NOT touch `dependencies/RSDKv5` (the submodule has one unrelated WIP change in `RSDK/Mod/ModAPI.cpp` — leave it).
- Do NOT do items 2/3/5/6 from the larger optimization investigation. Scope is bounded to items 1/4/7.
- Do NOT modify `UFO_ItemBox_Draw`, `UFO_Plasma_Draw`, `UFO_Circuit_Draw`, `UFO_HUD_Draw`, `UFO_Camera_Draw`, `UFO_Water_Draw`, `UFO_Message_Draw`. They are either already correct, intentionally always-draw, or 2D HUD-style.
- Do NOT add a helper function for the palette coalescer. Three near-identical inlined blocks beat a helper here (see Step 2 for the rationale).
- Do NOT publish a release. End condition is "desktop SDL2 build clean + smoke test passes + three commits on `mister`".

---

## Critical autonomy notes for the implement agent

1. Don't ask. If a branch decision arises that isn't covered above, choose the safer option, document it in the commit body, proceed.
2. Auto-recover from failures:
   - **SDL2 build break after Item 4 commit:** revert that commit, re-attempt; the change is one line of early-return — most likely cause is a typo in the early-return condition.
   - **Palette banding visibly changes after Item 1:** the coalescing logic is wrong. The flush-after-loop step is the most common bug — verify the trailing band gets emitted exactly once (not zero, not twice).
   - **Spheres disappear or pin to wrong location after Item 7:** the early-return is firing too aggressively. Check the `drawGroup != 4` condition — it must allow drawGroup=12 spheres to be drawn from the drawGroup-12 pass (which they will, naturally, because Object.cpp dispatches Draw per drawGroup, enrolling each entity in exactly one bucket per frame at `Object.cpp:454-455`).
3. Self-verify each step against the listed Success criteria BEFORE moving to the next step.
4. Each step ends in its own commit on `mister`. Do not squash. Do not amend.
5. If a step's smoke test surfaces a regression that can't be pinpointed in <15 min, revert the latest commit (`git revert HEAD`) and append a wrap-up note at the bottom of this file describing what hit; continue with remaining steps.

---

## Step plan overview (5 steps, dependency-ordered)

| # | Step | Risk | Wall-clock |
|---|---|---|---|
| 0 | Pre-flight: verify clean tree, identify SDL2 build dir, baseline build | none | ~5 min |
| 1 | Item 4 — `UFO_Setup_Scanline_3DRoof` early-out when `clipY <= 48` | very low | ~10 min |
| 2 | Item 1 — coalesce per-scanline `SetActivePalette` into RLE bands across all three callbacks | low | ~25 min |
| 3 | Item 7 — `UFO_Sphere_Draw` early-return + audit other UFO_*_Draw | low | ~20 min |
| 4 | Build + smoke test desktop SDL2 (post all three commits) | none | ~15 min |
| 5 | Verify three commits landed cleanly; nothing else | none | ~2 min |

Steps 1 → 2 → 3 are independent in code touch (no overlap), but ordered by smallest-first so if step 1 breaks the build it's trivially attributable.

---

## Step 0 — Pre-flight

### Title
Verify environment and baseline-build the SDL2 desktop target

### Why it matters
We need a known-good build before any change so a post-change build break is unambiguously ours. We also need to confirm the SDL2 desktop target still builds on the current `mister` branch.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/build-p7-fix-sdl2/CMakeCache.txt` — confirm `PORT_MISTER:BOOL=OFF` (this is the SDL2 desktop build, not the cross-compiled MiSTer one). Plan author has confirmed; re-confirm because `git status` may have moved.
2. `git status` — confirm tree is clean except for the known list (`vendor/Main_MiSTer/sonicmania_wrapper.cpp`, `vendor/Menu_MiSTer/menu.sv`, `vendor/Menu_MiSTer/rtl/native_video_timing.sv`, the submodule, and an untracked `grabtest.c`). If anything else is modified, STOP and ask.

### Files to create / modify
None.

### Procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
git status
# Expect the list above. Anything more, halt.

cmake --build build-p7-fix-sdl2 -- -j8
# Expect: completes without error. Produces build-p7-fix-sdl2/libGame.dylib (and likely a RSDKv5U executable).
```

If the build is broken on the current tree (unrelated to our changes), STOP and document; do not start the perf work.

### Success criteria
- `git status` shows exactly the expected pre-existing modifications, no more.
- `cmake --build build-p7-fix-sdl2 -- -j8` exits 0.
- `ls -la build-p7-fix-sdl2/libGame.dylib` shows a file with mtime newer than the start of this step (or unchanged if no .c source touched, which is the expected case here).

### Dependencies
None.

### Out of scope
- Don't update CMake configuration. Don't reconfigure. If the build fails to find a header, that's a pre-existing problem and we halt.
- Don't touch `dependencies/RSDKv5`.

### Failure mode + recovery
- Build fails with linker errors mentioning unrelated symbols → pre-existing; halt and report.
- Build fails because the build dir is stale (CMakeCache references a missing source) → re-run `cmake -B build-p7-fix-sdl2 -S .` with the same flags as originally configured, then retry. If unsure of original flags, fall back to creating a new build dir: `cmake -B build-ufo-perf-sdl2 -S . -DPORT_MISTER=OFF -DRETRO_USE_MOD_LOADER=ON` and use that going forward.
- Tree has unexpected modified files → halt and ask the user.

---

## Step 1 — Item 4: 3D Roof early-out when fully clipped

### Title
Skip `UFO_Setup_Scanline_3DRoof` body when `camera->clipY <= 48`

### Why it matters
The roof scanline callback runs unconditionally every frame — a 240-iteration loop dominated by per-iteration division (`camera->height / div`, with `div` recomputed each line from sin/cos terms) plus the trig setup — even when the player is looking down and the roof clip region is empty. `clipY` is computed in `UFO_Camera_HandleCamPos` (`UFO_Camera.c:70`) as `CLAMP(ScreenInfo->center.y - offset + 8, -0x40, ScreenInfo->size.y)`. With `ScreenInfo->center.y == 120` (240/2), this drops below 48 whenever `offset >= 80`, i.e. the camera is pitched far enough down that the horizon is within the bottom third of the screen. That's a common case during normal play (running uphill, fall onto a floor section). The work is wasted because `SetClipBounds(0, 0, 0, w, clipY-48)` clamps `y2` to 0 → empty clip → the roof tile layer renders zero rows.

Note: the original early-out also saved 240 single-line `SetActivePalette` calls, but once Item 1 lands later in this plan that drops to ~7 emits/frame and is no longer the dominant cost. The wall-clock win this step is targeting is the 240-iteration division/trig loop, not the palette calls.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — re-read lines 251-283 to confirm the structure hasn't drifted from this plan's snapshot.
2. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Camera.c:50-71` — confirm `clipY` semantics (already verified above; just re-confirm the line number).

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c`

### Change sketch

In `UFO_Setup_Scanline_3DRoof`, after the existing `SetClipBounds` call (line 255), insert an early return:

```c
void UFO_Setup_Scanline_3DRoof(ScanlineInfo *scanlines)
{
    EntityUFO_Camera *camera = RSDK_GET_ENTITY(SLOT_UFO_CAMERA, UFO_Camera);

    RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, camera->clipY - 48);

    // Phase 11 perf: when the roof clip region is empty, the tile layer renders
    // zero rows; setting up the 240 scanline entries (and 240 SetActivePalette
    // calls) is wasted work. SetClipBounds is preserved above so the screen-wide
    // clip state is still correct for this layer.
    if (camera->clipY <= 48)
        return;

    int32 sin  = RSDK.Sin1024(camera->angle) >> 2;
    // ...rest unchanged
}
```

CRITICAL: the early-return must occur AFTER the `SetClipBounds` call. `SetClipBounds` is screen-wide state; the previous scanline callback (`UFO_Setup_Scanline_3DFloor`, which set `y2 = ScreenInfo->size.y`) leaves the clip wide-open, and we MUST narrow it for the roof's tile-layer render even when we're skipping the per-scanline setup, otherwise the roof tile data could draw into the floor's region.

### Success criteria
- File compiles in the SDL2 desktop build: `cmake --build build-p7-fix-sdl2 -- -j8`.
- `git diff --stat` shows exactly one file changed (`SonicMania/Objects/UFO/UFO_Setup.c`) with `+5/-0` (or similar — the comment lines).
- One commit:
  ```
  perf(ufo): skip 3D Roof scanline setup when fully clipped

  Roof scanline callback ran 240 iterations every frame even when the
  clip region was empty (camera pitched down, clipY <= 48). The tile
  layer renders zero rows in that case, so the per-scanline division
  + trig (and 240 SetActivePalette calls, soon to be coalesced) was
  wasted work.

  SetClipBounds is preserved before the early-return so the prior
  callback's wide-open clip doesn't leak into the roof tile draw.
  ```

### Dependencies
Step 0 passed.

### Out of scope
- Do NOT touch `UFO_Setup_Scanline_3DFloor` or `UFO_Setup_Scanline_Playfield` in this step. Their clip thresholds differ (`clipY` and `clipY + 24` respectively) and the early-out math is not symmetric. If they need similar treatment, that's a future item.
- Do NOT use a different threshold than 48. The existing code uses `clipY - 48` to compute the y2 clamp; matching it keeps the early-out condition exactly equivalent to "y2 clamps to 0".

### Failure mode + recovery
- Roof tile artifacts visible (garbage scanline rendering when looking down) → the early-return fired before `SetClipBounds`. Reorder.
- Roof completely vanishes when looking up (clipY > 48 case visibly broken) → the condition is inverted. Fix the comparison direction.
- No visible change but build broken → typo in the conditional. Re-read.

---

## Step 2 — Item 1: Coalesce per-scanline `SetActivePalette` into RLE bands

### Title
Run-length-encode palette-bank assignments in all three UFO scanline callbacks

### Why it matters
Each of `UFO_Setup_Scanline_Playfield` (line 209), `UFO_Setup_Scanline_3DFloor` (line 242), `UFO_Setup_Scanline_3DRoof` (line 275) calls `RSDK.SetActivePalette(bank, i, i+1)` once per scanline inside a 240-iteration loop. That's 720 single-line calls per frame just for these three callbacks. `SetActivePalette` is `inline` and writes to `gfxLineBuffer[]` (verified `Palette.hpp:44-48`), but each call still incurs the function-call decision, the bound check, and a single-byte write — and inside a tight hot loop those add up. The palette-index formulas (`CLAMP(abs(pos) >> 15, 0, 7)` etc.) tend to produce only a few transitions across 240 lines because `pos` varies smoothly with `i`.

The fix is the standard RLE-emit pattern: track a `bandStart` line and a `bandBank`. When the computed bank for the current line differs from `bandBank`, emit one `SetActivePalette(bandBank, bandStart, i + SCREEN_YCENTER)` covering the closed band, then start a new band. After the loop, flush the trailing band with one final emit.

This is bit-equivalent because `SetActivePalette(b, a, c)` is exactly `for (l = a; l < c; ++l) gfxLineBuffer[l] = b` per the engine source. The new emit covers exactly the same `[bandStart, currentLine)` range that the original 1-line emits would have written.

### Inline vs. helper — decision

Two structures are possible:

**Option A: helper function.**
```c
static inline void emit_palette_band(uint8 bank, int32 start, int32 end) {
    RSDK.SetActivePalette(bank, start, end);
}
```
Plus a coalescer struct or a few stack vars in each callback.

**Option B: inline RLE in each callback.**
Three near-identical 5-line edits, no shared helper.

**Decision: Option B (inline).** Reasoning:
- The three callbacks have minor formula differences (`>> 15`, `(>> 15) - 8`, `>> 14`) and two of them apply a `CLAMP`. The shared logic ends at "compute bank" and starts again at "compare and emit." Wrapping that with a helper saves three lines per callback at the cost of a function-call indirection on the hot path.
- Each callback is short (~30 lines) and self-contained; readability cost of inlining is small.
- Mania decompiled style is allergic to extra abstraction layers — files in `SonicMania/Objects/` consistently inline patterns.
- `/implement` is one pass with one reviewer; three near-identical edits are easier to review side-by-side than a helper plus three call sites.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — re-read 186-283 (covers all three callbacks).

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c`

### Change sketch (per callback)

For each of the three callbacks, replace the per-iteration `SetActivePalette` call with a coalescing block. Concrete diff for `UFO_Setup_Scanline_Playfield` (the others are mechanically identical, swapping the bank-formula expression):

```c
void UFO_Setup_Scanline_Playfield(ScanlineInfo *scanlines)
{
    EntityUFO_Camera *camera = RSDK_GET_ENTITY(SLOT_UFO_CAMERA, UFO_Camera);

    RSDK.SetClipBounds(0, 0, camera->clipY, ScreenInfo->size.x, ScreenInfo->size.y);

    int32 sin  = RSDK.Sin1024(camera->angle) >> 2;
    int32 cos  = RSDK.Cos1024(camera->angle) >> 2;
    int32 sinX = RSDK.Sin1024(-camera->angleX) >> 2;
    int32 cosX = RSDK.Cos1024(-camera->angleX) >> 2;

    int32 cosVal = -SCREEN_YCENTER * cosX;

    int32 bandStart = 0;
    int32 bandBank  = -1;

    for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i) {
        int32 div = sinX + (cosVal >> 8);
        if (!div)
            div = 1;

        int32 h             = camera->height / div;
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
        cosVal += cosX;
    }

    if (bandBank >= 0)
        RSDK.SetActivePalette(bandBank, bandStart, SCREEN_YSIZE);
}
```

For `UFO_Setup_Scanline_3DFloor`, the bank formula becomes `CLAMP((abs(pos) >> 15) - 8, 0, 7)` (matching the original line 242).

For `UFO_Setup_Scanline_3DRoof`, the bank formula becomes `CLAMP(abs(pos) >> 14, 0, 7)` (matching the original line 275). The trailing flush still runs after the loop. Note that in the roof callback, the early-return added in Step 1 happens BEFORE the loop, so the coalescing-block init must also live AFTER the early-return — this is naturally the case if the change is applied cleanly (init lives just above the `for`). Consequence: when the roof's clip region is empty (Step 1's early-return fires), the roof's coalescer doesn't run at all — Step 1's win compounds with Step 2's, it doesn't replace it.

### Why `int32 bandBank = -1` (sentinel)
The bank is a non-negative `uint8` in the engine call (`CLAMP(..., 0, 7)` rules the range). We use `-1` as a sentinel for "no band started yet" so the first iteration always opens a fresh band without emitting an empty one.

`bandBank = 0` would NOT work as the sentinel: the first computed bank can legitimately be 0 (e.g. when `pos` is small near the horizon). If we initialized `bandBank = 0` and the first computed bank were also 0, the `if (bank != bandBank)` check would not fire, the first band-open would be suppressed, and the leading region of the screen would not get its bank explicitly written by this callback (it would be left at whatever `gfxLineBuffer` held — the prepare hook's bank 0 in non-Plasma stages, or potentially stale state from the previous frame in UFO5's drawGroup-3 case where the prepare hook is overwritten). Even when the answer happens to be 0, we want this callback to write it explicitly to match the original per-line loop's behavior.

After the loop, the `if (bandBank >= 0)` flush ensures we don't emit if the loop ran zero iterations (which can't happen here — `SCREEN_YCENTER == 120` is a compile-time positive constant — but the guard costs nothing and matches the band-tracking discipline).

### Why the trailing flush uses `SCREEN_YSIZE`, not `SCREEN_YCENTER + SCREEN_YCENTER`
They're equal (240 == 120 + 120) but `SCREEN_YSIZE` is the established Mania constant for "screen height in scanlines" and is the same constant `SetActivePalette` clamps against internally (`l < SCREEN_YSIZE`). Matches the engine contract.

### Success criteria
- File compiles in the SDL2 desktop build.
- `git diff --stat` shows exactly one file changed with roughly `+30/-3` (three callbacks × ~10 lines each, minus the three deleted single-line emit calls).
- Smoke test (Step 4) confirms no visible palette-banding regression in the special stage backgrounds. Specifically: the floor/playfield/roof regions show smooth banded color shifts as the camera turns, exactly as before — no flickering, no missed bands.
- One commit:
  ```
  perf(ufo): coalesce per-scanline SetActivePalette into RLE bands

  All three UFO_Setup_Scanline_* callbacks called SetActivePalette
  once per scanline inside a 240-iteration loop. With ~7 distinct
  banks across 240 lines, that was 720 single-line SetActivePalette
  calls/frame for ~21 actual band emits.

  Track (bandStart, bandBank) and emit only on transitions, plus
  one trailing flush after the loop. Bit-equivalent because
  SetActivePalette(b, a, c) writes the same gfxLineBuffer range
  whether called once or split per-line.
  ```

### Dependencies
Step 1 committed (so the roof's early-return is in place; the coalescing block is added after that early-return).

### Out of scope
- Do NOT extract a helper. See decision rationale above.
- Do NOT widen the optimization to other callers of `SetActivePalette` — `UFO_Plasma_Draw` already calls it just once on line 37 (full-screen reset), so there's nothing to coalesce there.
- Do NOT change the bank-formula. Keep `>> 15`, `>> 15) - 8`, `>> 14` exactly as today; the perf optimization is purely about call coalescing.

### Failure mode + recovery
- Visible banding artifact (a strip stuck on the wrong color) → the trailing flush is missing or the loop's transition emit is using the wrong end-of-range. Re-check that the transition emit uses `line` (the just-computed `i + SCREEN_YCENTER`, the START of the new band) as the end of the OLD band — not `line + 1`.
- Solid screen region renders as bank 0 (default) instead of the gradient → the loop is never entering its `if (bank != bandBank)` branch because `bandBank` is being initialized to a value the first computed bank matches, suppressing the first band-open. Confirm `bandBank = -1` (not `0`).
- Build error "comparison between signed and unsigned" → cast `bandBank` to `int32` everywhere (already shown in the sketch).

---

## Step 3 — Item 7: `UFO_Sphere_Draw` early-return + audit other UFO_*_Draw

### Title
Replace `UFO_Sphere_Draw`'s gating `if` with a hard early-return that also skips `DrawSprite`

### Why it matters
Current `UFO_Sphere_Draw` (`UFO_Sphere.c:38-51`):
```c
if (self->drawGroup == 4 && self->zdepth >= 0x100) {
    // ...update drawPos/scale via projection...
}
RSDK.DrawSprite(&self->animator, &self->drawPos, true);
```
The `if` only gates the projection UPDATE. `DrawSprite` runs unconditionally. The real bug is for **behind-camera spheres (`zdepth < 0x100`)**: `DrawSprite` is called against the LAST-VALID `drawPos`. Sprite is pinned at a stale screen location. Wasted CPU plus a possible visual glitch (a sphere "sticking" at the screen edge as you turn past it).

The fix is one early-return:
```c
if (self->drawGroup != 4 || self->zdepth < 0x100)
    return;
```

The `drawGroup != 4` half of the early-return is preserved purely as defensive code from the original guard — it is unreachable in normal operation. Verified at `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:347` (drawGroups[].entityCount zeroed each frame) and `:454-455` (each entity is enrolled in exactly ONE drawGroups bucket per frame, indexed by its CURRENT `drawGroup`). So a sphere whose state has flipped to drawGroup=12 (`UFO_Sphere_State_Fixed` at `UFO_Sphere.c:122`) is enrolled in `drawGroups[12]` only and receives exactly one `Draw()` per frame from pass 12. There is no double-draw and no stale pass-4 dispatch. `Sphere_State_Collected` (`UFO_Sphere.c:233-234`) updates `drawPos` directly each frame, so the pass-12 `DrawSprite` renders correctly without going through the projection block.

The behind-camera arm IS a real correctness issue and is the actual reason this change is worth shipping; the rest is perf + tightening.

### Audit results — other UFO_*_Draw functions

The plan author audited all UFO_*_Draw entries. Findings:

| File | Line | Pattern | Action |
|---|---|---|---|
| `UFO_Sphere.c` | 38 | `if (drawGroup==4 && zdepth>=0x100) { project } DrawSprite()` — BAD | **Fix this step** |
| `UFO_Ring.c` | 35 | `if (zdepth >= 0x100) { project + DrawSprite }` — already gated correctly | leave alone |
| `UFO_Dust.c` | 38 | `if (zdepth >= 0x400) { project + DrawSprite }` — already gated | leave alone |
| `UFO_Springboard.c` | 76 | `if (zdepth >= 0x4000) { 3D scene path }` — already gated | leave alone |
| `UFO_Decoration.c` | 51 | `if (zdepth >= 0x4000) { 3D scene path }` — already gated | leave alone |
| `UFO_Shadow.c` | 49 | `if (zdepth >= 0x4000) { 3D scene path }` — already gated | leave alone |
| `UFO_Player.c` | 38 | `if (zdepth >= 1) { 3D scene path }` — gated (Player threshold is much lower because the player is always near-camera) | leave alone |
| `UFO_SpeedLines.c` | 60 | per-line `if (depth >= 0x400)` inside loop — already gated | leave alone |
| `UFO_ItemBox.c` | 50 | `if (state == HasContents) { 3D + project } DrawSprite()` — DrawSprite outside if | **leave alone** (intentional — itemboxes after collection still draw the contents sprite as a collect animation; verified by the `state == HasContents` gate naming) |
| `UFO_Plasma.c` | 18 | full-screen scanline blit — not 3D-projected | leave alone |
| `UFO_Circuit.c` | 44 | 3D scene path, fully gated by `zdepth >= 0x4000` | leave alone |
| `UFO_HUD.c` | 57 | 2D HUD | leave alone |
| `UFO_Camera.c` | 25 | empty | leave alone |
| `UFO_Water.c` | 25 | empty | leave alone |
| `UFO_Message.c` | 23 | 2D message | leave alone |

So **only `UFO_Sphere_Draw` is touched in this step.** No sweep needed beyond the audit above.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c:38-51` — the function being changed.
2. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c:114-127` — `Sphere_State_Fixed` collision check that sets `drawGroup = 12` (line 122).
3. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c:229-247` — `Sphere_State_Collected` confirms it directly updates `drawPos.x`/`drawPos.y` (lines 233-234), so once collected the sphere has its own coherent drawPos and DrawSprite-from-pass-12 draws correctly.

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c`

### Change sketch

Replace `UFO_Sphere_Draw` (lines 38-51) with:

```c
void UFO_Sphere_Draw(void)
{
    RSDK_THIS(UFO_Sphere);

    if (self->drawGroup != 4 || self->zdepth < 0x100)
        return;

    self->direction = self->animator.frameID > 8;
    self->drawPos.x = (ScreenInfo->center.x + (self->worldPos.x << 8) / self->zdepth) << 16;
    self->drawPos.y = (ScreenInfo->center.y - (self->worldPos.y << 8) / self->zdepth) << 16;
    self->scale.x   = self->scaleFactor / self->zdepth;
    self->scale.y   = self->scaleFactor / self->zdepth;

    RSDK.DrawSprite(&self->animator, &self->drawPos, true);
}
```

Net change vs. the current code: the inner `if` becomes an early-return with the same conditions inverted, and `DrawSprite` moves inside the protected region.

### Why we don't add a comment explaining the change
Mania decompiled style: comments only for non-obvious WHY. The early-return shape is self-documenting — if a future reader wonders why we skip `DrawSprite`, they read the conditions and understand. The git commit message carries the historical justification.

### Success criteria
- File compiles in the SDL2 desktop build.
- `git diff --stat` shows one file changed with `+3/-2` (one new line for the early-return, the inner `if` and brace block flattened).
- Smoke test (Step 4) confirms:
  - Spheres at the far end of the playfield (small, deep) still render correctly until they pop out of the camera frustum.
  - Collecting a sphere shows the standard collect animation (sphere flies to the score widget) — unchanged from before this patch.
  - Spheres immediately behind the player (just past the camera) do not pin to a stale screen location during turns. (This is the actual bug the change fixes.)
- One commit:
  ```
  perf(ufo): early-return UFO_Sphere_Draw on near-zero zdepth

  The original gated only the projection update; DrawSprite ran
  unconditionally. Behind-camera spheres (zdepth < 0x100) drew at
  stale drawPos, pinning a sphere sprite at the last-valid screen
  location during turns.

  The `drawGroup == 4` half of the original guard is preserved as
  defensive code (the engine's draw-list rebuild dispatches each
  entity from exactly one drawGroup per frame, so it is unreachable
  in normal operation).

  Audit of other UFO_*_Draw functions confirmed only UFO_Sphere had
  this shape; UFO_Ring/Dust/Springboard/Decoration/Shadow/Player are
  already gated. UFO_ItemBox's pattern is intentional (contents
  sprite renders during collect animation).
  ```

### Dependencies
Step 2 committed.

### Out of scope
- Do NOT touch any other UFO_*_Draw function. The audit is the deliverable; the only edit is Sphere.
- Do NOT change `UFO_Ring_Draw` "for symmetry" — it's already correct, and editing it just to match style adds risk.
- Do NOT remove or modify `UFO_Sphere_Create`'s `drawGroup = 4` initialization (line 60) — that's load-bearing.

### Failure mode + recovery
- Spheres flicker or vanish in the playfield → the early-return condition is too aggressive. The `drawGroup != 4` guard should be true for live spheres (they're created with `drawGroup = 4` per line 60). Confirm no other code path silently changes `drawGroup` for a live sphere except `Sphere_State_Collected`.
- Collected sphere flies to the score widget but invisibly → the drawGroup-12 pass dispatch isn't running. That would be an engine-level issue independent of this change (this patch only adds an early-return; it does not interfere with pass-12 dispatch). Revert and investigate.
- Compile error about `direction` field type (the original ternary became a direct assignment) → check the `direction` field is `uint8` in the struct; if so, compare-to-bool produces 0/1 which assigns fine. If issues, add an explicit cast: `self->direction = (uint8)(self->animator.frameID > 8);`.

---

## Step 4 — Build + smoke test SDL2 desktop target

### Title
Rebuild SDL2 desktop, run the game, validate UFO Special Stage rendering

### Why it matters
Three commits have landed; before declaring done, we need to confirm the binary runs and the special stage renders without regression. Cannot run on MiSTer hardware from this session, so SDL2 desktop is the validation target.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/build-p7-fix-sdl2/CMakeCache.txt` — confirm still on SDL2 (`PORT_MISTER:BOOL=OFF`).

### Files to create / modify
None.

### Procedure

```bash
cd /Users/sb/Developer/sonic-mania-mister
cmake --build build-p7-fix-sdl2 -- -j8
# Expect: clean build. Touched files: UFO_Setup.c, UFO_Sphere.c.
# Build should re-link libGame.dylib and the engine binary.
```

If the build dir produces an executable (typical name `RSDKv5U` or `RSDKv5UDebug`), launch it:
```bash
# Locate the binary
find build-p7-fix-sdl2 -maxdepth 3 -name 'RSDKv5*' -perm -u+x
# Then run with whatever data-pack path the existing dev workflow uses; typically
# the project root contains a Data.rsdk or similar at:
#   /Users/sb/Developer/sonic-mania-mister/RSDKv5U.app  or
#   /Users/sb/Developer/sonic-mania-mister/Data.rsdk
# If no game data is reachable, document and skip the runtime smoke; the build
# pass alone is meaningful for compile-correctness.
```

### Visual checks (if a runnable build is produced)
- **Get to a special stage.** Easiest path: from the title screen, hold reset/dev keys to skip to the special stage select if the build has dev mode enabled, or play through Green Hill 1 and grab a giant ring. UFO5 specifically has Plasma (a known-bright background pattern) — picking UFO5 also exercises the Plasma path which we did not touch but want to confirm we didn't break tangentially.
- **Watch the floor/playfield/roof banding** as the camera turns and pitches:
  - Bands should transition smoothly with no flickering or sudden snap-to-wrong-color.
  - Looking down (so the roof clip drops below 48): no visible regression. The roof region just goes blank as it should — this is the case Item 4 was optimizing.
  - Looking up (roof fully visible): roof bands transition correctly with camera motion.
- **Spheres**:
  - Far spheres at the back of the field render small but cleanly.
  - Spheres just past the camera (when the camera turns past one) should not pin to a screen edge — they should disappear cleanly.
  - Collecting a sphere: the collect animation should look unchanged from before the patch — the patch does not affect the collect path.
- **Rings, item boxes, springboards**: should render exactly as before — these were not touched, we're confirming no tangential regression.

### Success criteria
- Build completes with no warnings introduced by our edits (existing warnings are fine).
- If runtime smoke executed: all visual checks pass.
- If runtime smoke skipped (no data pack reachable): document in the wrap-up note at the bottom of this file and proceed; build-pass alone is acceptable for this plan since the changes are mechanical.

### Dependencies
Steps 1, 2, 3 all committed.

### Out of scope
- Do NOT run on MiSTer hardware. That's a separate deploy operation, not part of this plan.
- Do NOT add new test infrastructure or dev-mode shortcuts. Use what's there.
- Do NOT benchmark — these are "free win" items, the gain is correctness + a small constant CPU saving; not measured here.

### Failure mode + recovery
- **Build break**: most likely typo in one of the three edits. Use `git diff HEAD~3` to see all changes; bisect by `git revert` if the error message is ambiguous.
- **Runtime crash on first special stage frame**: most likely Item 1's coalescer wrote past `gfxLineBuffer[SCREEN_YSIZE-1]`. Check the trailing flush uses `SCREEN_YSIZE` (not 240+1 or some larger constant). The engine's `SetActivePalette` clamps internally with `l < SCREEN_YSIZE`, so even a bug here should NOT be a buffer overrun, but a wrong-bank visual artifact is possible.
- **Visible banding regression**: revert Step 2's commit; the roof early-out and sphere early-return are independent and should not have visual impact. Re-attempt Step 2 with extra care on the trailing flush.
- **Sphere visual regression**: revert Step 3's commit; the other two are independent. Re-attempt Step 3.

---

## Step 5 — Verify three commits landed cleanly

### Title
Confirm three independent commits on `mister`, leave clean tree

### Why it matters
The user wants three commits one-per-item so each is independently revertible. Step 5 confirms that's the actual state.

### Files to read first
None.

### Files to create / modify
None.

### Procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
git log --oneline -5
# Expect (top to bottom):
#   <new>  perf(ufo): early-return UFO_Sphere_Draw on near-zero zdepth
#   <new>  perf(ufo): coalesce per-scanline SetActivePalette into RLE bands
#   <new>  perf(ufo): skip 3D Roof scanline setup when fully clipped
#   c525d06b docs: Phase 9 wake-up status — deployed, booted, running
#   ...
git status
# Expect: same pre-existing modified-list as Step 0 (no new modifications).
```

### Success criteria
- `git log --oneline -5` shows our three commits as the most recent on `mister`, in order: roof → palette RLE → sphere.
- `git status` shows the same modifications as at Step 0 start (the pre-existing mister-WIP state is untouched).
- Each commit can be independently reverted: `git revert <hash>` would cleanly undo just that item.

### Dependencies
Steps 1, 2, 3, 4 all done.

### Out of scope
- Do NOT push to remote. The user has not requested it.
- Do NOT squash, amend, or reorder.
- Do NOT touch the submodule.

### Failure mode + recovery
- Wrong commit count (one big squashed commit, or only two commits) → use `git log --stat` to see what's where; if recoverable via `git rebase -i`, do so — but only if the user is awake. If the user is not awake, leave the state as-is and document in the wrap-up section at the bottom of this file.
- Submodule touched accidentally → `git submodule status dependencies/RSDKv5` should show no change beyond the one pre-existing WIP mod. If touched, `git submodule update --recursive dependencies/RSDKv5` to reset.

---

## Risks for the reviewer to challenge

1. **Item 4's threshold is exactly `<= 48`.** The plan author derived this from `clipY - 48` clamping `y2` to 0. Confirm the engine's `SetClipBounds` clamps to `[0, screen->size.y]`, not some other range, before merging. Source verified at `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:333`. **Reviewer: confirm the SCREEN_YSIZE compile-time constant matches `screen->size.y` at runtime — they should, but a 224p mode (Phase 10b shipped 224p) means SCREEN_YSIZE != 240. If 224p is active, the threshold for "fully clipped" is still `<= 48` because the formula in UFO_Camera doesn't depend on SCREEN_YSIZE for the offset math, but reviewer should sanity-check this.** A safer formulation is `if (camera->clipY - 48 <= 0)` which is identical algebraically but more explicitly tied to the SetClipBounds y2 expression.

2. **Item 1's bandStart sentinel.** Using `-1` for `bandBank` works because `bank` is always `[0, 7]`. If a future edit to the bank formula could produce a negative value (e.g., signed overflow from `>> 15) - 8`), the sentinel collides. The current `CLAMP(..., 0, 7)` rules out that, but a defensive reviewer might prefer `int32 bandHasData = 0;` as a separate flag. Plan author chose the `-1` sentinel for compactness; reviewer can push back.

3. **Item 7's `drawGroup != 4` guard.** This was in the original code and we're keeping it, but it's only reachable if some code path calls `Draw` for a sphere from a non-4 pass. The scene draw loop dispatches by drawGroup, so this should never fire — making the guard pure defensive code. Reviewer: confirm no Mod or callback invokes `UFO_Sphere_Draw` directly from outside the engine's pass dispatcher. (`grep -rn "UFO_Sphere_Draw" SonicMania/` should show only the registration and the function definition.)

4. **No benchmarking.** These are "free wins" by inspection. The user explicitly said low-risk/free-win items, so we trust the inspection. A reviewer who pushes for numbers should be told no — the cost of instrumenting outweighs the value at this scope.

5. **Submodule cleanliness.** The `mister` branch has the `dependencies/RSDKv5` submodule marked modified pre-existing. Plan ensures we don't TOUCH that submodule, but reviewer should verify the post-commit `git status` shows the submodule mark unchanged from baseline (i.e., we didn't accidentally bump or reset it).

## Rollback story per item

- **Item 4 (roof early-out)**: `git revert <hash>` undoes the early-return. The function reverts to running its 240-iteration loop unconditionally. Roof renders identically pre/post — the early-out only saves work when the result was already empty.
- **Item 1 (palette RLE)**: `git revert <hash>` restores the per-scanline `SetActivePalette` calls. Visually identical pre/post — the RLE is bit-equivalent. Revert is purely a perf rollback.
- **Item 7 (sphere early-return)**: `git revert <hash>` restores the broken pattern (DrawSprite on stale drawPos for behind-camera spheres). This is also a CORRECTNESS fix, not just perf — reverting it brings back the behind-camera stale-drawPos bug. Reviewer may want a stronger commit message reflecting this.

Three independent commits in dependency order means partial revert (e.g., revert Item 7 only) is trivial.

---

## Wrap-up

Append any deferred issues, runtime-smoke notes, or unexpected findings to a section here named `## Plan execution notes — <date>` at the bottom. Do not modify earlier sections of this file.
