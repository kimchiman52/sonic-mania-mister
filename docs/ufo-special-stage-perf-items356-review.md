# UFO Items 3/5/6 Plan — Review Findings

## Summary

**Verdict: needs-fix.** Two P-1 issues. One is a load-bearing correctness bug (Item 6 skips state-reset that the rest of the frame depends on); the other is a fundamental units error in Item 3's cull threshold that makes the cull a no-op as written. Item 5 and the magnitude estimates for Item 6 hold up to scrutiny — the engine-side rasterization claim is correctly bounded, the INK_MASKED cost analysis is correct. P-2 issues: an incomplete LateUpdate audit (UFO_Dust missed), a vague Step-0 measurement step (no log retrieval procedure), and a muddled rationale for excluding ItemBox from Item 3 (the audit says "duplicate work" but the actual matrix multiply is unconditional once state==HasContents).

Counts: **2 P-1, 3 P-2.** Biggest concern: Item 6 will produce visible color glitches every other frame on UFO5 sprites (spheres, rings) unless the state-reset calls are kept on the skipped frame.

---

## P-1 — Must Fix

### P-1a. Item 6 skip-the-whole-body breaks downstream sprites' palette banding

**Plan reference:** Step 1, "Locked decisions" line 55, change sketch lines 198–214.

**Claim:** "skip the entire Plasma `Draw()` body every other frame ... `if (UFO_Setup->timer & 1) return;` is one line." The plan's Success Criteria item (line 225) tries to verify this is safe by saying "by inspection, no: the function is pure draw, no member writes to `UFO_Plasma`."

**What's wrong:** the plan only checked for member writes, not for engine-state side effects. The function ends with two engine-state mutations that the rest of the frame depends on:

```c
RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, ScreenInfo->size.y);
RSDK.SetActivePalette(0, 0, ScreenInfo->size.y);
```

(`/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Plasma.c:36-37`)

The `SetActivePalette(0, 0, h)` at the bottom of `UFO_Plasma_Draw` is the **only** thing that resets `gfxLineBuffer[]` after the per-line palette banks written by the prior drawGroup's tile-layer scanline callbacks (`UFO_Setup_Scanline_Playfield` in drawGroup 1 — see `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c:209` and the Item 1 RLE coalescing logic shipped at e6115147). On UFO5 specifically, `UFO_Plasma_StageLoad` overwrites the drawGroup-3 prepare hook to a no-op (`UFO_Plasma.c:71` — `RSDK.SetDrawGroupProperties(3, false, StateMachine_None)`), so there is no other reset path on UFO5.

After Plasma's drawGroup-3 pass, drawGroup 4 contains `UFO_Sphere_Draw`/`UFO_Ring_Draw`/etc. which call `RSDK.DrawSprite`. Per `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` (the family of `Draw*Sprite` functions starting around line 2930), DrawSprite reads `gfxLineBuffer[y]` per-line for palette bank selection.

On the skipped frame:
- drawGroup 1 scanline callback writes per-line bands to `gfxLineBuffer[]` (Playfield's bank palette: Item 1's RLE coalescer)
- drawGroup 3 Plasma_Draw is skipped — the `SetActivePalette(0, 0, h)` reset never fires
- drawGroup 4 Sphere/Ring/etc. DrawSprite uses Playfield's leftover per-line banks for the sphere palette → wrong colors

This will produce visible color flicker on every sphere and ring every other frame — exactly the "every other frame visual glitch" failure mode the plan didn't anticipate. The plan's locked decision (line 55) explicitly mentions the scanline-table setup as a saving but does not call out the SetActivePalette reset's role.

The engine's per-drawGroup cleanup at `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:825-845` resets `clipBound` to full-screen between drawGroups but does **not** reset `gfxLineBuffer[]`. Verified directly.

**Suggested correction:** keep the trailing two calls on the skipped path. Restructure as:

```c
void UFO_Plasma_Draw(void)
{
    if (!(UFO_Setup->timer & 1)) {
        // even-frame heavy path
        int32 y = ...;
        // ...scanline-table setup loop...
        RSDK.DrawDeformedSprite(UFO_Plasma->aniFrames, INK_MASKED, 0x100);
    }
    // unconditional state-reset (cheap, runs every frame)
    RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, ScreenInfo->size.y);
    RSDK.SetActivePalette(0, 0, ScreenInfo->size.y);
}
```

This still saves the 240-iter scanline setup + the 76,800-pixel DrawDeformedSprite on skipped frames (which is the actual dominant cost) while preserving the palette/clip reset that the next drawGroup depends on. The magnitude estimate (~310–500 μs/frame avg) is essentially unchanged — the two SetClipBounds/SetActivePalette calls are tiny compared to DrawDeformedSprite.

The plan's Failure mode + recovery section (line 234) currently says "Visible flicker on UFO5 lightning: the half-rate IS visible at slow camera motion. Acceptable." — that text is about the lightning effect itself, not about sphere/ring color glitches, so the actual failure mode this P-1 surfaces would not be caught by the plan's existing recovery procedure.

### P-1b. Item 3 cull threshold is in wrong units; cull will never fire

**Plan reference:** Step 3, "Cull threshold derivation" lines 384–394, change sketches lines 408 and 436, "Why `>> 16` on the deltas" line 456.

**Claim:** the cull `if ((dx >> 16) > 0x600 || (dz >> 16) > 0x600)` with `0x600` justified as "1.5× updateRange" against `updateRange.x = 0x400`.

**What's wrong:** the plan's mental model of `updateRange.x` units is wrong. The engine's `ACTIVE_RBOUNDS` cull at `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:435-446` does:

```c
case ACTIVE_RBOUNDS:
    sceneInfo.entity->inRange = false;
    for (int32 s = 0; s < cameraCount; ++s) {
        int32 sx = FROM_FIXED(abs(sceneInfo.entity->position.x - cameras[s].position.x));
        int32 sy = FROM_FIXED(abs(sceneInfo.entity->position.y - cameras[s].position.y));
        if (sx * sx + sy * sy <= sceneInfo.entity->updateRange.x + cameras[s].offset.x) {
            sceneInfo.entity->inRange = true;
            break;
        }
    }
```

`FROM_FIXED` is `>> 16`. The comparison is `sx*sx + sy*sy <= 0x400` — a **squared-distance** check. With `updateRange.x = 0x400 = 1024`, the actual pass radius is √1024 ≈ 32 in upper-16-bit units (i.e., the entity's `position.x - cam.position.x` is at most ~32 in `>> 16` units, i.e., 32 × 0x10000 = 0x200000 in raw fixed-point).

The plan's cull computes `(dx >> 16)` (same upper-16-bit units) and compares to `0x600 = 1536`. Any entity that passed the engine's RBOUNDS cull is at most ~32 in those units. **The plan's cull at 1536 will never fire.** It's a no-op.

The "1.5× updateRange" justification on line 391 confuses 0x400-as-squared-distance with 0x400-as-linear-distance. They are not interchangeable.

**Evidence chain:**
- `Object.cpp:439-440` — `sx, sy` are `FROM_FIXED(abs(diff))` = `(diff) >> 16`.
- `Object.cpp:442` — `sx*sx + sy*sy <= 0x400`. Squared Euclidean.
- Plan line 408 — `if ((dx >> 16) > 0x600 ...)` uses the same `>> 16` units; comparing to 1536 when active entities are at most ~32. No-op.

If the cull threshold were instead `0x40` (decimal 64) in `>> 16` units, it would be ~2× the engine's effective radius and would also never fire. The mathematically correct cull region is approximately the engine's RBOUNDS region itself; a tighter cull requires a different metric (e.g., camera-frustum projection — exactly what the post-multiply zdepth gate provides).

**Suggested correction:** Either (a) drop Item 3 entirely — the plan acknowledges it's tiny (~2–5 μs/frame estimated, smaller than the magnitude noise floor), and the `zdepth < 0x100` Draw-time gate already handles the behind-camera case after Items 1/4/7 shipped — or (b) re-derive the threshold honestly. Honest derivation would likely require either:
  - a frustum cull using camera angle + position (computing approx z-depth from a 2D projection — but this approaches the cost of the matrix multiply we're trying to avoid), or
  - a small-radius prune in linear `>> 16` units (e.g., reject anything with `dx >> 16 > 64` — but this duplicates the engine's RBOUNDS at a slightly looser bound and saves nothing for entities the engine considered active).

Recommended: drop Item 3 from this round (the plan already calls it the lowest-priority item), and document in the wrap-up that an effective cull requires either inverse-projection or a different cull shape than 2D Manhattan distance.

If the implementer is determined to ship something, mention that the `_LateUpdate` matrix-multiply cost is small per-entity (~25 cycles) compared to the pre-Item-3 baseline of ~7,200 cycles for two scanline callbacks — Item 3 magnitude is genuinely below the noise floor.

---

## P-2 — Should Fix

### P-2a. LateUpdate audit incomplete — `UFO_Dust_LateUpdate` missing

**Plan reference:** "Engine contracts already verified" line 40 lists "Sphere, Ring, ItemBox, Springboard, Decoration, Shadow"; the Item 3 audit table at lines 376–382 omits `UFO_Dust`.

**Evidence:** `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Dust.c:14-34`. `UFO_Dust_LateUpdate` does an unconditional full 4×3 (3-row) world-matrix multiply (12 muls) when the entity isn't being destroyed — exactly the same shape as `UFO_Sphere_LateUpdate` and `UFO_Ring_LateUpdate`. The `Draw` function gates on `zdepth >= 0x400`. Plan author missed this entry.

The omission is small in practice — Dust is a transient effect, low N — but the audit table claims to be exhaustive ("Conclusion of audit: only `UFO_Sphere` and `UFO_Ring` lack a pre-multiply gate"). That's not actually true; `UFO_Dust` also lacks a pre-multiply gate; the audit just didn't list it. Small N is the actual reason to not cull it.

**Suggested correction:** add `UFO_Dust` to the audit table with a row noting "low N (transient effect, destroyed-on-anim-end); not worth a cull." If P-1b's recommendation (drop Item 3 entirely) is taken, this becomes moot.

### P-2b. ItemBox audit rationale is muddled

**Plan reference:** Step 3 audit table line 377.

**Claim:** "UFO_ItemBox: Full 4×3 multiply BUT only inside `if (state == HasContents)` ... NO — the `if (zdepth >= 0x2000)` post-multiply gate already filters most of the cost. Adding pre-multiply 2D cull is duplicate work."

**What's wrong:** the `if (zdepth >= 0x2000)` gate (`UFO_ItemBox.c:35`) filters only the SECONDARY single-row computation that follows; the primary 12-mul matrix multiply at `UFO_ItemBox.c:31-33` is unconditional once `state == HasContents`. The audit's conclusion ("post-multiply gate already filters most of the cost") is wrong — the post-multiply gate filters maybe 1 mul × 4 (the depth/visible check), but the 12-mul primary multiply isn't gated.

The actual reason to leave ItemBox alone is: (a) low N (typically <= 10 itemboxes per stage), and (b) the cull-threshold issue from P-1b applies to ItemBox too. So the conclusion "leave alone" is correct, but the rationale is wrong.

**Suggested correction:** rewrite the row to honestly say "Full 4×3 multiply unconditional once state==HasContents; left alone because N is low (~10 per stage), so the cull saving is small." If P-1b is taken (drop Item 3), this becomes moot.

### P-2c. Step 0 lacks log-retrieval procedure

**Plan reference:** Step 0 procedure lines 146–157.

**Claim:** Step 0 specifies which keys to press (F3, F6, F12) and what numbers to look at, with a decision table at lines 159–164. The plan author claims this is concrete enough.

**What's missing:** no SCP/SSH command for retrieving `/tmp/sonicmania.log` (which is where F12 dumps go per the runbook). Step 7 mentions "ssh root@192.168.1.188 'tail -F /tmp/sonicmania.log'" but Step 0 (which executes BEFORE the changes) doesn't reference it. A user new to this plan would not know to tail that path.

The decision table (lines 159–164) is concrete and specific — that part is fine.

**Suggested correction:** add a single line to Step 0 procedure block:

```bash
# Tail the F12 jitter log from another terminal:
ssh root@192.168.1.188 'tail -F /tmp/sonicmania.log'
# F12 dump format: "[jitter] phase_err=Xus late(>500us)=N ..."
```

This is a 1-line fix that materially improves Step 0's actionability. Without it, Step 0 says "record `phase_err` and `late(>500us)=N`" without saying where those numbers appear.

---

## Approved / Verified Correct

The following load-bearing claims I confirmed independently against the actual source. Fix-agent should not re-litigate these.

### Item 6: INK_MASKED cost class

`/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:4044-4061` (the `case INK_MASKED:` block) — the inner loop body is exactly:

```cpp
uint8 palIndex = pixels[((FROM_FIXED(ly) & height) << lineSize) + (FROM_FIXED(lx) & width)];
if (palIndex && *frameBuffer == maskColor)
    *frameBuffer = activePalette[palIndex];
lx += dx; ly += dy; ++frameBuffer;
```

Versus INK_NONE (3914-3932): one extra compare on `*frameBuffer == maskColor`. No LUT, no alpha blend, no multiplication. The plan's "5–8 cycles/iter on Cortex-A9" is on the optimistic end (8–12 is more realistic with DDR3 framebuffer access), but this is a low risk for the plan because **a higher per-iter cycle count makes the saving LARGER, not smaller** — so the plan is being conservative on its own magnitude claim. Honest direction.

### Item 6: 320×240 = 76,800 pixel iter count

`/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:84` sets `videoSettings.pixWidth = 424 (widescreen) or 320 (4:3)`. Line 208 calls `SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE)` where `SCREEN_YSIZE = 240` per `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp:155`. `Drawing.cpp:395-396` clamps `screen->size.y = height & 0xFFF0` (240 & 0xFFF0 = 240) and computes `screen->pitch = (size.x + 15) & ~0xF` (320 → 320; 424 → 432). The Item-2 wrap-up note's "320×224" mention was stray (a leftover from earlier mode work). For the current 4:3 MiSTer build, 320×240 = 76,800 is correct.

If user ships a widescreen RBF (424 wide), Plasma's deformed blit becomes 432×240 = 103,680 — 35% larger, which makes Item 6 even more compelling.

### Item 5: engine reads `scanlines[]` per output line

`/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Scene/Scene.cpp:1318` — `for (int32 cy = currentScreen->clipBound_Y1; cy < currentScreen->clipBound_Y2; ++cy)` iterates per output line; line 1457 advances `++scanline;` per line. There is no API for the callback to signal "use line N's data for line N+1," and no fast-path for matching adjacent scanline data. The plan's "Item 5 savings are bounded to the callback math, not the rasterization" is correct.

### Item 5: SCREEN_YSIZE evenness

`SCREEN_YSIZE = 240` per `RetroEngine.hpp:155`. `240 & 0xFFF0 == 240` (the clamp in `SetScreenSize`). Step-by-2 loop `i = -120; i < 120; i += 2` produces exactly 120 iterations writing 240 entries. No tail handler needed. Plan claim verified.

### Item 3: Sphere/Ring LateUpdate is unconditional 4×3 multiply

`/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Sphere.c:21-34` — full 3-row matrix multiply, no zdepth gate. `UFO_Ring.c:18-31` — same shape, no gate. Plan claim verified.

### Item 3: Springboard, Decoration, Shadow correctly gated

- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Springboard.c:54-72` — z-row only first (3 muls), then visibility check gated on `zdepth >= 0x4000`.
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Decoration.c:29-47` — same pattern.
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Shadow.c:14-45` — z-row only computed inside cascading gates (`parent->classID && tile != -1 && parent->drawGroup == 4`). Plan claim verified.

### `UFO_Setup->timer` parity is a valid frame-skip key

`/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c:63-64` — `++UFO_Setup->timer; UFO_Setup->timer &= 0x7FFF;` runs once per StaticUpdate (every frame). Wrap at 0x7FFF is even, so parity stays consistent across the wrap. Initial value `self->timer = 512` (line 89) is even, so the FIRST frame draws Plasma — verifies the plan's "Stage entry feels visually correct" claim.

### Three-commit independence

Verified disjoint files:
- Item 6 → `SonicMania/Objects/UFO/UFO_Plasma.c`
- Item 5 → `SonicMania/Objects/UFO/UFO_Setup.c`
- Item 3 → `SonicMania/Objects/UFO/UFO_Sphere.c` + `SonicMania/Objects/UFO/UFO_Ring.c`

No file overlap. `git revert` on any one cleanly undoes that item only.

### Magnitude honesty

The plan's Magnitude estimates (lines 99–106) are honest. Item 6 dominates by ~30×; Items 5 and 3 are explicitly tiny; "stack 6+5+3" is realistic at 2–3% of a 60 fps budget. The plan repeatedly notes the user is frustrated and that Items 5/3 won't be perceptible in isolation. Lines 108–112 lay out what to investigate if "still slow af" persists after the stack. This is the right tone for a third-round perf plan; not overselling.
