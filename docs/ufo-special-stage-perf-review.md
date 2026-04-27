# UFO Special Stage Perf Plan — Review Findings

## Summary

The plan is **technically sound and approve-with-minor-fixes**. All three optimizations target real hot-path costs, the engine-API reasoning is correct, the file paths and line numbers verify against the current source, and the audit of "which UFO_*_Draw functions need fixing" is accurate (only `UFO_Sphere_Draw` has the bad pattern).

There is **one P-1 issue** about a load-bearing factual claim in Item 7's justification (the "collected sphere double-draw" rationale is wrong — the engine's per-frame draw-list rebuild dispatches each entity from exactly one drawGroup based on its CURRENT `drawGroup` field, so a collected sphere only gets one Draw() call from pass 12). The actual bug fix (early-return when `zdepth < 0x100`) is still valid, but the commit message and Step 3 "Why it matters" need to be rewritten so the change isn't justified by a non-bug.

There are **5 P-2 issues** about minor accuracy in audit-table descriptions, one wrong claim about the prepare-hook draw-group registration that affects how UFO5 (Plasma) interacts with bank state, and a small clarity issue around bandStart sentinel rationale.

Counts: **1 P-1, 5 P-2.**

---

## P-1 — Must Fix

### 1. Step 3 / Item 7 — "double-draw of collected spheres" justification is factually wrong

**Reference:** `ufo-special-stage-perf-plan.md` lines 334–336 (Step 3 "Why it matters", consequence #2) and lines 419–421 (commit-message body), and the recovery hint on line 45.

**Claim in the plan:** "Collected spheres (`drawGroup == 12`, set in `UFO_Sphere_State_Collected` via line 122)\: when the drawGroup-4 pass dispatches `Draw`, `drawGroup != 4` so projection is not updated, but `DrawSprite` still runs at whatever `drawPos` was. Then the drawGroup-12 pass ALSO calls `Draw` ... meaning collected spheres double-draw, once from the stale pass-4 dispatch and once from the legitimate pass-12 dispatch."

**Why it's wrong:** The engine rebuilds `drawGroups[].entries[]` from scratch every frame in `ProcessObjects` at `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:347` (zero out) and `:454-455` (add the entity to the bucket matching its CURRENT `drawGroup`). The per-entity flow at `Object.cpp:450-456` is:

```
if (entity->inRange) {
    if (...).update();                             // may modify entity->drawGroup
    if (entity->drawGroup < DRAWGROUP_COUNT)
        drawGroups[entity->drawGroup].entries[...] = entitySlot;  // exactly ONE bucket
}
```

So in the very same frame that `UFO_Sphere_State_Fixed` changes `drawGroup` from 4 to 12 (`UFO_Sphere.c:122`), the sphere is enrolled in `drawGroups[12]` only — never in `drawGroups[4]` for that frame or any subsequent frame. The `Draw()` callback fires exactly once per frame for a collected sphere, from pass 12, with a drawPos that `Sphere_State_Collected` (`UFO_Sphere.c:233-234`) updates each frame.

The plan author actually notices this in lines 343-346 of the plan ("the original code's `drawGroup == 4` check is actually defensive (and likely redundant)") — but never goes back to retract the double-draw rationale higher up, and the commit-message body still claims a correctness fix for a bug that doesn't exist. The behind-camera (`zdepth < 0x100`) bug IS real, but the "collected sphere" arm is not.

**Suggested correction:**
- Step 3 "Why it matters": delete the entire "Collected spheres ... double-draw" bullet (consequence #2). Keep consequence #1 (behind-camera stale drawPos). Note that the `drawGroup != 4` half of the early-return is purely defensive code preserved from the original — not a fix for an observable bug — and explain that as the reason it's still in the new condition.
- Step 3 commit-message body: replace "Collected spheres (drawGroup=12) double-drew via the pass-4 dispatch's stale DrawSprite plus the pass-12 legit one" with something like "The `drawGroup == 4` half of the original guard is preserved as defensive code (the engine's draw-list rebuild already dispatches each entity from exactly one drawGroup, so it is unreachable in normal operation)."
- Recovery hint at line 45 ("Spheres disappear or pin to wrong location after Item 7"): the explanation in the parenthetical ("which they will, naturally, because Object.cpp dispatches Draw per drawGroup") is correct as-is — the rest of the plan just needs to be made consistent with that.

The actual code change in Step 3 (the early-return condition `drawGroup != 4 || zdepth < 0x100`) is correct and should NOT be modified — only the surrounding rationale.

---

## P-2 — Should Fix

### 2. Audit table mis-classifies UFO_Circuit as "not 3D-projected"

**Reference:** Step 3 audit table, line 364: "`UFO_Circuit.c` | 44 | not 3D-projected | leave alone".

**Why it's wrong:** `UFO_Circuit_Draw` at `SonicMania/Objects/UFO/UFO_Circuit.c:44-66` is fully 3D-projected — it builds a transform/normal matrix pair and calls `RSDK.AddMeshFrameTo3DScene`/`Draw3DScene`. The reason it doesn't need a fix is that the entire body is correctly wrapped in `if (self->zdepth >= 0x4000)` (line 48), which means both the projection AND the draw calls are gated together — exactly the right pattern.

**Suggested correction:** Change the audit-table row to: "`UFO_Circuit.c` | 44 | 3D scene path, fully gated by `zdepth >= 0x4000` | leave alone".

This is just a description fix; the conclusion (leave alone) is correct.

### 3. "drawGroup-1 and drawGroup-3 prepare hook" claim is partially undermined by UFO_Plasma

**Reference:** Plan lines 19-20: "`gfxLineBuffer` defaults to bank 0 from `UFO_Setup_DrawHook_PrepareDrawingFX` ... which is registered as the draw-group-1 and draw-group-3 prepare hook."

**Why it's incomplete:** That's the state immediately after `UFO_Setup_StageLoad`, but in stage UFO5 (the only stage with Plasma), `UFO_Plasma_StageLoad` at `SonicMania/Objects/UFO/UFO_Plasma.c:71` does:
```c
RSDK.SetDrawGroupProperties(3, false, StateMachine_None);
```
which OVERWRITES the prepare hook for drawGroup 3. So in UFO5, only drawGroup 1's prepare hook resets the line buffer to bank 0. The 3D Floor and 3D Roof tile layers are placed in `drawGroup[0] = 0` (`UFO_Setup.c:95, :104`), and the playfield is in whatever drawGroup the scene file assigned, which presumably is one that gets the prepare hook either before it or via the drawGroup-1 hook.

This doesn't break the RLE coalescer — Item 1's correctness only relies on the loop ASSIGNING a bank to every line `[0, SCREEN_YSIZE)` in each callback (which the original code does and the new code preserves), regardless of what the line buffer's "default" is.

**Suggested correction:** In the Engine contracts block, soften the claim to: "The Setup prepare hook (`UFO_Setup_DrawHook_PrepareDrawingFX`) resets gfxLineBuffer to bank 0 each frame in stages that use it (drawGroup-1 hook, plus drawGroup-3 in non-Plasma stages). Item 1's coalescer doesn't depend on this — it writes a bank for every scanline `[0, SCREEN_YSIZE)` exactly as the original per-line loop does, so no scanline is ever left at the prepare-hook default during a UFO callback's region."

### 4. "Item 4 saves 240 SetActivePalette calls" undercounts savings of bundling Item 4 with Item 1

**Reference:** Step 1 "Why it matters", line 119: "240 trig-heavy iterations + 240 `SetActivePalette` calls."

**Issue:** This is the count BEFORE Item 1 lands. After Item 1 lands and Item 4's early-return fires, Item 4 saves 240 trig iterations + 1 `SetActivePalette` call (the trailing flush) — not 240 calls. The plan order has Item 4 → Item 1, so Item 4 lands first and at that moment the savings ARE 240 calls; but by the end of the patch series the perf description in Step 1 is stale.

**Suggested correction:** Add a parenthetical in Step 1's "Why it matters": "(After Item 1 lands later in this plan, the per-call count is reduced to ~7 emits/frame, but the trig-heavy 240-iteration loop is still wall-clock dominant and that's what the early-out is targeting.)" Also note in Step 2 that the Roof callback's coalescer runs only when the early-return doesn't fire.

### 5. Engine clip-bounds reset between draw groups — explanatory note for reviewer trust

**Reference:** Plan line 19, and CRITICAL note at lines 25, 151, in Step 1.

**Observation (verified, not a contradiction — just worth annotating):** `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:800-820` clamps `clipBound_*` back to `[0, screen->size.{x,y}]` AFTER each draw group's tile-layer pass. So clip "leaks" only WITHIN a single draw group's tile-layer iteration, not across draw groups.

The 3D Floor and 3D Roof are both placed in `drawGroup[0] = 0` (`UFO_Setup.c:95, :104`), and the Playfield's drawGroup is whatever the scene file specifies. So when 3D Floor's scanlineCallback narrows the clip and 3D Roof's scanlineCallback runs next within the SAME drawGroup-0 tile-layer loop, the leak is real and Item 4's "keep SetClipBounds before the early-return" guidance IS correct. The plan's caution is right; this finding is just a request to add the verification reference for the next reviewer.

**Suggested correction:** In the engine-contracts block (around line 19), add: "Verified: `Object.cpp:800-820` resets clip bounds to full screen at the END of each drawGroup's tile-layer loop, so the leak window is only between adjacent layers within the same drawGroup. Both 3D Floor and 3D Roof are placed in drawGroup 0 (`UFO_Setup.c:95, :104`), so the leak path is real for them."

### 6. `bandBank = -1` sentinel — minor justification gap

**Reference:** Step 2, lines 279-280 ("Why `int32 bandBank = -1` sentinel").

**Observation:** The justification given (the bank is a non-negative `uint8`, so `-1` is unreachable) is correct, but the plan never explains WHY the sentinel exists — i.e. that without it, the first iteration's `if (bank != bandBank)` would either:
- always trigger and emit an empty band of length 0 if you initialized bandStart to 0, or
- never trigger and skip the first band's start if you initialized bandBank to whatever the first computed bank is (which is unknowable at init time because it depends on `pos`).

The current code as written is fine; the explanation just doesn't make the alternative-failure-mode obvious. A future reader could wonder "why not `bandBank = 0`?".

**Suggested correction:** Add one sentence: "`bandBank = 0` would not work as the sentinel because the first computed bank could legitimately be 0; we'd then suppress the first band-open and the leading region of the screen could be left writing to wherever the line buffer was set at the start of the loop (the prepare hook's bank 0, or stale state from the previous frame in UFO5's drawGroup-3 case)."

---

## Approved as-is

The following claims and reasoning were verified against the source and confirmed correct. The fix-agent does not need to re-litigate these.

### Engine-API contracts (lines 16-20 of the plan)
- `SetActivePalette(bank, start, end)` writes `gfxLineBuffer[start..end-1]` — confirmed at `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Palette.hpp:44-48`. Coalescing N adjacent same-bank single-line calls into one `[start, end)` call is bit-equivalent.
- `SetClipBounds` clamps each value to `[0, screen->size.{x,y}]` — confirmed at `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:325-337`. With `clipY <= 48`, the roof's `SetClipBounds(0, 0, 0, w, clipY-48)` clamps `y2` to 0, which combined with `y1 = 0` produces an empty clip → tile-layer renders zero rows.
- Scanline callbacks fire from `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:782-783` (verified).
- `SetClipBounds` must occur BEFORE the early-return in Item 4 to avoid leaking the prior callback's clip — confirmed by the per-drawGroup tile-layer loop structure at `Object.cpp:776-794` and the placement of both 3D layers in drawGroup 0.

### Source-line accuracy (Items 1, 4)
- `UFO_Setup.c:209` — `UFO_Setup_Scanline_Playfield`'s `SetActivePalette(CLAMP(abs(pos) >> 15, 0, 7), i + SCREEN_YCENTER, i + SCREEN_YCENTER + 1)` — CONFIRMED.
- `UFO_Setup.c:242` — `UFO_Setup_Scanline_3DFloor`'s `SetActivePalette(CLAMP((abs(pos) >> 15) - 8, 0, 7), ...)` — CONFIRMED.
- `UFO_Setup.c:275` — `UFO_Setup_Scanline_3DRoof`'s `SetActivePalette(CLAMP(abs(pos) >> 14, 0, 7), ...)` — CONFIRMED.
- `UFO_Setup.c:255` — `RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, camera->clipY - 48)` for the Roof — CONFIRMED. The threshold `<= 48` is exactly equivalent to "y2 clamps to 0".
- `UFO_Camera.c:70` — `self->clipY = CLAMP(ScreenInfo->center.y - offset + 8, -0x40, ScreenInfo->size.y)` — CONFIRMED. The lower bound `-0x40 = -64` does allow `clipY` to be negative, which Item 4's `<= 48` check correctly handles (negative is also `<= 48`).

### Audit table — only UFO_Sphere has the bad pattern
The plan's audit table conclusion is correct: only `UFO_Sphere_Draw` has a `DrawSprite` outside an `if`-zdepth gate. Each row was verified:

- `UFO_Ring.c:35-53` — DrawSprite is INSIDE `if (self->zdepth >= 0x100)`. Correctly gated. Leave alone. CONFIRMED.
- `UFO_Dust.c:38-51` — DrawSprite INSIDE `if (self->zdepth >= 0x400)`. CONFIRMED.
- `UFO_Springboard.c:76-96` — entire body INSIDE `if (self->zdepth >= 0x4000)`. CONFIRMED.
- `UFO_Decoration.c:51-` — entire body INSIDE `if (self->zdepth >= 0x4000)`. CONFIRMED.
- `UFO_Shadow.c:49-62` — entire body INSIDE `if (self->zdepth >= 0x4000)`. CONFIRMED.
- `UFO_Player.c:38-` — entire body INSIDE `if (self->zdepth >= 1)`. CONFIRMED.
- `UFO_SpeedLines.c:60-81` — DrawLine INSIDE per-iteration `if (depth >= 0x400)`. CONFIRMED.
- `UFO_ItemBox.c:50-79` — `DrawSprite(&self->contentsAnimator, ...)` runs unconditionally; the 3D scene/projection update is inside `if (state == HasContents)`. The plan classifies as "intentional — itemboxes after collection still draw the contents sprite as a collect animation". I verified the surrounding code. The drawPos is updated in HasContents and then RE-USED when state != HasContents to draw the contents sprite at the post-collection screen position. This may or may not be intentional in the original (the same kind of "stale drawPos draws the contents" issue the plan diagnoses for Sphere), but the plan has explicitly chosen NOT to touch this — fine. Leave alone. CONFIRMED.
- `UFO_Plasma.c:18-38` — full-screen scanline blit, no zdepth concept. CONFIRMED.
- `UFO_Circuit.c:44-66` — fully gated by `zdepth >= 0x4000` (see P-2 #2 above re: the row description). Conclusion (leave alone) CONFIRMED.
- `UFO_HUD.c:57-` — 2D HUD, no zdepth. CONFIRMED.
- `UFO_Camera.c:25` — empty body. CONFIRMED.
- `UFO_Water.c:25` — empty body. CONFIRMED.
- `UFO_Message.c:23-34` — 2D HUD, no zdepth. CONFIRMED.

### Behind-camera stale-drawPos bug in UFO_Sphere
Confirmed real. `UFO_Sphere.c:42-50` skips the projection update when `zdepth < 0x100` but still calls `RSDK.DrawSprite(&self->animator, &self->drawPos, true)` at the previous frame's drawPos. Item 7's early-return fixes this. The fix is correct.

### Build-dir choice
`build-p7-fix-sdl2/CMakeCache.txt` confirmed:
- `PORT_MISTER:BOOL=OFF`
- `RETRO_SUBSYSTEM:STRING=SDL2`
- `CMAKE_BUILD_TYPE:STRING=Release`
- `RETRO_REVISION:STRING=3`
- SDL2 found at `/opt/homebrew/lib/libSDL2.dylib`

This is the correct desktop SDL2 build for validation.

### Step ordering
Item 4 → Item 1 → Item 7 is sound. The "smallest first so failure is easy to attribute" justification is reasonable. Item 4 is one early-return; Item 1 is the structural change with the largest blast radius (palette state, three callbacks); Item 7 is one function. Each step touches a different region and the commits are independently revertible.

### "Why" reasoning per item
- Item 4: per-frame trig + 240 SetActivePalette calls when the result is discarded by an empty clip — verified in source. Worth optimizing.
- Item 1: 720 single-line SetActivePalette calls/frame across three callbacks, replaceable with ~7 multi-line emits. Bit-equivalent because the engine's loop `for (l=start; l<end; ++l) gfxLineBuffer[l] = bank` is the same whether end-start=1 or end-start=N. Verified.
- Item 7: behind-camera stale DrawSprite is a real correctness issue (not just perf). The "double-draw of collected spheres" arm is wrong (see P-1 #1) but the core fix is justified.

### Step scope and bundling
All five steps fit in one /implement pass. Each step is a small, mechanical change (1-3 file edits, single-digit lines for Items 4 and 7, ~30 lines for Item 1). The plan's structure (5 steps with explicit Pre-flight, three independent edits, build-and-smoke, and final verification) is well-suited to a single-pass run.

### Submodule cleanliness
The plan correctly forbids touching `dependencies/RSDKv5/`. No proposed change requires engine modifications.
