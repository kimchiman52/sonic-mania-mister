# UFO Item 2 Plan — Review Findings

**Reviewer:** plan-reviewer agent
**Date:** 2026-04-25
**Plan under review:** `docs/ufo-special-stage-perf-item2-plan.md`
**Source HEAD at review:** `c525d06b` (per `git log -1`)

## Summary

**Verdict: needs-fix (small).** The plan is technically sound on the math, the disasm anchor independently reproduces, the math is solid for the divisor-sequence-shared-across-callbacks claim, the Q30 precision argument holds within stated NUM bounds, and the locked-decisions / 8-field-step structure all check out. **2 P-1 findings** (one wrong type declaration in the change sketch; one unjustified NUM bound that the plan's own algebra doesn't actually need but cites incorrectly), and **3 P-2 findings** (a redundant cache-key field, a sentinel-collision risk, and an unverified threading assumption that's stated as verified). None of the findings invalidate Approach C or the locked decisions. The fix-agent should patch the change sketch, re-derive the NUM bound from the actual code, and tighten three small wording issues. Biggest concern: the `static uint16 ufo_setup_cached_angle = 0;` declaration in the change sketch is a type mismatch with `entity->angle` (which is `int32` per `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.hpp:108`); the comparison `camera->angle == ufo_setup_cached_angle` will silently compare a 16-bit truncation, defeating the cache key.

---

## P-1 — Must Fix

### P1-A. Cache-key type mismatch: `uint16 ufo_setup_cached_angle` vs `int32 angle`

**Plan reference:** Step 1 change sketch, lines 218–219:
```c
static uint16 ufo_setup_cached_angle  = 0;
static int32  ufo_setup_cached_angleX = 0x7FFF;
```

**What's wrong:** The plan declares `ufo_setup_cached_angle` as `uint16`, but the actual field type is `int32`. Evidence:
- `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.hpp:108` — `int32 angle;` is the entity-base field.
- `SonicMania/Objects/UFO/UFO_Camera.h:22` — `int32 angleX;` (the plan got this one right).
- `SonicMania/Objects/UFO/UFO_Camera.c:96` — `self->angle &= 0x3FF;` masks angle into `[0, 0x3FF]` so the *value* always fits in `uint16`, but the type used to compare against the cached value is `int32`.

The comparison `camera->angle == ufo_setup_cached_angle` will compile (implicit conversion), but if a future mod or path produces an angle value outside `[0, 0xFFFF]` before the `& 0x3FF` mask is applied, the truncation could mask a real difference. More importantly, **using `uint16` here is inconsistent with the field type and is a code-review smell** — a reader reasonably expects the cache key to match the source field type.

**Suggested correction:** change the declaration to `static int32 ufo_setup_cached_angle = -1;` (matching `int32 angleX = 0x7FFF` style: a sentinel outside the legitimate runtime range). The legitimate range of `camera->angle` post-mask is `[0, 0x3FF]`, so `-1` (or any negative value) is a clean sentinel. Alternatively use a larger sentinel like `0x7FFFFFFF` to match `int32` width.

If the plan author wants to keep the `uint16` storage to save 2 bytes (negligible), they should at minimum document the truncation explicitly, but the correct fix is to match `int32`.

---

### P1-B. NUM bound claim (`NUM ≤ 2^25`) cites stale numbers; recompute from `UFO_Camera.c`

**Plan reference:** Step 1 "Failure mode + recovery" line 378 says:
> NUM ≤ 2^25 (largest is 3DFloor's `0x400000 + 0x1000000 = 0x1400000 ≈ 2^24.3`)

**What's wrong:** The plan's bound calculation uses `0x400000` as the base for `camera->height`, but `camera->height` can be substantially larger. From `SonicMania/Objects/UFO/UFO_Camera.c`:
- Line 33 (Create): `self->height = 0x300000;` — fine.
- Line 104 (Springboard branch in `State_Normal`): `self->height = (target->height >> 1) - (RSDK.Sin1024(self->angleX) << 14) + 0x400000;`. `Sin1024` returns up to `±1024 = ±2^10`, then `<< 14` gives `±2^24`. So `camera->height` can swing to `(target->height >> 1) + 0x400000 + 2^24 ≈ 2^24 + 2^22 + 2^24 ≈ 2^25.3` even ignoring `target->height`.
- Line 110 (default branch): `self->height = (target->height >> 2) + 0x400000;` — typically modest.
- Line 134 (`State_CourseOut`): `self->height += 0x20000;` — accumulates unbounded over time within the state, but the state runs only at end-of-stage for ~60–120 frames.
- Line 155 (`State_UFOCaught`): `self->height += 0x80000;` — same caveat.

The 3DFloor NUM is `camera->height + 0x1000000`. With the Springboard path's swing, camera->height alone can hit ~`2^25.3`, and adding `0x1000000 = 2^24` gives NUM up to ~`2^26`.

**Why this still works (but the plan should say so):** The plan's own risk-table at line 689 says the right thing — "NUM * recip < 2^29 × 2^30 = 2^59 — fits in int64. Estimate margin is 16 bits; safe." That's the correct, conservative bound. But the precision claim earlier (line 35: "Q30 worst-case error `|h_new - h_old| ≤ 1` ... NUM ≤ 2^25") leans on the tighter `2^25` bound. The error-term derivation `NUM * r / (div * 2^30) < NUM / 2^30 < 2^-5 < 1` requires NUM < `2^30` for the bound `< 1` to hold, NOT NUM < `2^25`. With NUM up to `2^26` we have `NUM/2^30 < 2^-4 = 0.0625 < 1` — still well under 1 LSB.

**Suggested correction:** in Step 1 line 378, replace the `2^25` claim with `2^29` (matching the risk-table line 689, derived from camera->height ≤ 2^29 worst-case). Recompute the precision claim as `error < NUM/2^30 ≤ 2^29/2^30 = 0.5 < 1`. The bottom-line conclusion (`|h_new - h_old| ≤ 1`) is unchanged; only the headroom margin shrinks. The fix-agent needs to update both the precision-analysis discussion (around line 35) and the "Multiplication overflow" failure-mode bullet (line 378) to use the consistent `2^29` figure derived from the `UFO_Camera.c:104` Springboard path.

---

## P-2 — Should Fix

### P2-A. Cache key `(angle, angleX)` is over-keyed; angle alone has no effect on `div`

**Plan reference:** "Locked decisions" line 36, "Cache key: `(camera->angle, camera->angleX)`."

**What's wrong:** The plan's own analysis (line 22) correctly notes:
> Strictly only `angleX` enters the divisor — `angle` doesn't — but caching on both is safer than caching on `angleX` alone in case future code introduces another call site.

This is true but slightly weakens the cache hit rate without benefit. The divisor sequence is a pure function of `angleX` (verified by reading `UFO_Setup.c:194-195` — only `angleX` feeds `sinX/cosX`, only `sinX/cosX` feed `cosVal` and `div`). `camera->angle` rotates ~once per second during normal play (`UFO_Camera.c:84-94` shows angle damping toward target at 1/8 per frame), so the angle-key change rate is approximately 1 per frame in motion. This means the cache will rebuild EVERY frame even when angleX is stable — cancelling the cross-callback win when only Playfield+Floor (no Roof) are running. Wait — actually re-reading: the rebuild is once per frame regardless of angle change, because the engine processes one frame's draws in sequence. The angle-key change is only relevant if the same frame somehow saw multiple `(angle, angleX)` pairs, which doesn't happen.

So the actual issue is cosmetic: the over-keying does NOT cost a per-frame rebuild it would otherwise save (since the cache is module-static, it survives across frames; angle changes between frames cause a rebuild, but that rebuild was going to happen on the first callback of the next frame anyway, since each frame's "first call" is the only place a rebuild happens).

**Verdict:** The over-keying is harmless; the plan correctly identifies it as defensive. **However**, the plan claims the angle-key check provides cross-frame caching when angles are stable: "Cache lifetime: module-static. Survives across frames." This means a frame where camera neither rotates nor pitches reuses the prior-frame table — saving the 240 build divides. If the cache were keyed only on `angleX` (the actually-relevant field), the cache would hit MORE often (whenever `angleX` is stable, even if `angle` rotates). With both keys, hits are rarer. For a typical UFO5 scene where the player turns continuously but pitch is stable, the dual-key cache misses every frame even though the divisor sequence is unchanged.

**Suggested correction:** drop `angle` from the cache key. Key on `angleX` only. The "future safety" argument doesn't apply because the divisor formula is fixed in this very file — any future call site adding a new dependence on `angle` would necessarily edit this code. Saves a per-frame 240-divide rebuild during normal turning. If the plan author insists on dual-keying, that's defensible but a perf regression in the common case worth flagging.

---

### P2-B. Sentinel `0x7FFF` for `angleX` could collide if a future stage extends the range

**Plan reference:** line 60, line 219, line 684.

**What's wrong:** The plan correctly cites that `UFO_Camera_HandleCamPos` and the State_* functions enforce `angleX ∈ [-0x100, 0x100]` in practice. Verified at `UFO_Camera.c:107` (set to 0), `:98` (`-(target->height >> 18)` with target->height bounded), `:136-137` (`-= 4` clamped at `-0x100`), `:156-157` (`-= 8` clamped at `-0x100`). So `0x7FFF` IS outside the runtime range today. **However**, no enforcement comment exists in the struct definition or a constant; a future Mania mod or UFO state could plausibly push `angleX` to 0x7FFF.

**Suggested correction:** use a wider sentinel that's not a plausible angle-resolution value. `INT32_MIN` (`0x80000000`) is the canonical "sentinel" for `int32` and unambiguously can never be a real angle. Alternatively `0x7FFFFFFF`. The two-byte saving `uint16 -> int32` for `angleX` is irrelevant; it's already `int32`. The plan's choice of `0x7FFF` is fine but defensive-coding-wise INT32_MIN is stronger.

---

### P2-C. Threading assumption stated as "verified" without primary citation

**Plan reference:** Risk table line 692:
> | **MiSTer multi-layered draw flow re-entrancy** | low | RSDK is single-threaded per `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp`. No locks needed for the static cache. | Confirmed by the engine's main loop being a single thread. |

**What's wrong:** No specific line number cited. The single-threadedness is correct (RSDKv5's main loop and ProcessObjectDrawLists run on one thread; this is reproducible across the codebase) but the plan's "verified" claim should point to a primary source. The mod-loader callbacks `MODCB_ONSCANLINECB` and `MODCB_ONDRAW` (Object.cpp:780-797) execute synchronously within the same thread, so even with mods the cache access is single-threaded.

**Suggested correction:** Cite `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:739` (the `for (int32 l = 0; l < DRAWGROUP_COUNT; ++l)` driving all draw dispatch) as evidence the caller is a single straight-line loop, and note that the SDL2 main thread is the only thread that enters this loop. This is a documentation tightness issue, not a correctness bug.

---

## Approved / Verified Correct

The following load-bearing claims were independently verified and the fix-agent should NOT re-litigate them:

### Verified: Disasm anchor reproduces exactly
`docker exec sonic-mania-mister-arm-build arm-linux-gnueabihf-objdump -d /work-mister/build/mister-telemetry/CMakeFiles/SonicMania.dir/SonicMania/Objects/All.c.o` shows:
- `002d0598 <UFO_Setup_Scanline_Playfield>:` containing `2d06f0: bl 0 <__aeabi_idiv>` — exactly one divide.
- `002d082c <UFO_Setup_Scanline_3DFloor>:` containing `2d098c: bl 0 <__aeabi_idiv>` — exactly one divide.
- `002d0a68 <UFO_Setup_Scanline_3DRoof>:` containing `2d0bf0: bl 0 <__aeabi_idiv>` — exactly one divide.

The pre-divide pattern `cmp r1, #1; movls r1, #1` (the `if(!div) div=1` zero-guard) appears at `2d06e8`-`2d06ec` in Playfield. The plan's Disassembly anchor section is accurate.

### Verified: All three callbacks compute identical `div` sequence
Cross-read of `UFO_Setup.c:192-205`, `:239-252`, `:292-306`:
- All three callbacks call `RSDK.Sin1024(camera->angle) >> 2`, `RSDK.Cos1024(camera->angle) >> 2`, `RSDK.Sin1024(-camera->angleX) >> 2`, `RSDK.Cos1024(-camera->angleX) >> 2`. Reading from the SAME `EntityUFO_Camera *camera` (same `RSDK_GET_ENTITY(SLOT_UFO_CAMERA, UFO_Camera)`).
- All three set `int32 cosVal = -SCREEN_YCENTER * cosX;` and advance `cosVal += cosX;` at end of each iteration — verified at lines 197/226, 244/273, 297/327.
- All three compute `int32 div = sinX + (cosVal >> 8); if (!div) div = 1;` identically — lines 203-205, 250-252, 304-306.
- The ONLY difference is NUMERATOR. Verified: Playfield `camera->height` (line 207), 3DFloor `camera->height + 0x1000000` (line 254), 3DRoof `height` where `height = (camera->height >> 2) - 0x600000` (line 298, 308).

The plan's fundamental insight is correct: the divisor sequence is identical across the three callbacks within one frame.

### Verified: Index mapping `recip[i + SCREEN_YCENTER]` is correct
At iteration `i ∈ [-SCREEN_YCENTER, SCREEN_YCENTER)`, the original loop has `cosVal = i * cosX` (derivable: cosVal starts at `-SCREEN_YCENTER * cosX`, increments by `cosX` per iter, so at iter k from start, cosVal = (-SCREEN_YCENTER + k) * cosX = i * cosX where i = -SCREEN_YCENTER + k). In `BuildRecipTable`, table index `j ∈ [0, SCREEN_YSIZE)` has `cosVal = (j - SCREEN_YCENTER) * cosX`. Setting `j = i + SCREEN_YCENTER` gives the matching cosVal. Index mapping is sound.

### Verified: Sign handling for negative NUM (3DRoof when camera->height < 0x1800000)
Roof's `height = (camera->height >> 2) - 0x600000`. With camera->height starting at 0x300000 (Create line) and Roof callback active, `(0x300000 >> 2) - 0x600000 = 0xC0000 - 0x600000 = -0x540000` — NEGATIVE. So the original `h = negative_NUM / positive_div` is negative. The plan's `h = (int64)NUM * recip >> 30` with signed `int64` multiply preserves sign correctly. ARM `asr` on signed int32 (which is what `>> 30` compiles to for signed operand) is arithmetic shift. C language: signed right-shift is implementation-defined, but every modern compiler used here (clang, gcc) does arithmetic shift. The plan correctly notes this in failure-mode (line 379).

### Verified: 240 iterations × 3 callbacks = 720 divides → 240 + 720 muls (saving 480 divides)
Loop bounds `for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i)` is exactly 240 iterations (SCREEN_YCENTER = 120 per `GameLink.h:49`). Three callbacks × 240 = 720 divides per frame, replaced by 240 build-divides + 720 muls. Net win 480 divides. Plan's win-sizing table is arithmetically correct.

### Verified: Item-4 early-return preserved before BuildRecipTable in 3DRoof
Plan correctly places `BuildRecipTable(camera)` AFTER `if (camera->clipY <= 48) return;` (line 326 of plan, matching `UFO_Setup.c:289-290` today). Roof skips the rebuild when fully clipped, which is correct — Floor or Playfield will rebuild later in the same frame. No correctness risk; one wasted rebuild cost is the worst case if Roof would have been first AND Floor and Playfield both also short-circuit (no realistic scenario where all three short-circuit, since Playfield has no early-return).

### Verified: Engine drawGroup ordering is 0 → 15 monotone
`dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:739` `for (int32 l = 0; l < DRAWGROUP_COUNT; ++l)` confirms ascending iteration. UFO_Setup.c:95 (`floor3D->drawGroup[0] = 0;`), :104 (`roof3D->drawGroup[0] = 0;`) put Floor and Roof in drawGroup 0, while Playfield is in its layer's drawGroup 1 (default). So within one frame: Roof or Floor runs first (one observes cache miss, builds), Playfield runs later in drawGroup 1 (cache hit). Plan's "first-callback-per-frame builds" is correct.

### Verified: Sin1024/Cos1024 are pure LUT lookups
`dependencies/RSDKv5/RSDKv5/RSDK/Core/Math.hpp:52-53`:
```c
inline int32 Sin1024(int32 angle) { return sin1024LookupTable[angle & 0x3FF]; }
inline int32 Cos1024(int32 angle) { return cos1024LookupTable[angle & 0x3FF]; }
```
Pure functions of input. Same `(angle, angleX)` → same `(sinX, cosX)`. Plan's invariant holds.

### Verified: 8-field steps present
Steps 0, 1, 2, 3, 4 each have all 8 fields (Title, Why it matters, Files to read first, Files to create/modify, Procedure, Success criteria, Dependencies, Out of scope, Failure mode + recovery). Step 5 is documented as user-gated and explicitly NOT executed by /implement, so the partial-fields are appropriate (the procedure section is for the user). Acceptable.

### Verified: Locked-decisions section present and matches prior plan style
"Locked decisions (DO NOT REVISIT)" block at lines 32-40 matches the prior plan's structure. Single commit, Approach C, Q30, cache key, lifetime, build-on-first-miss, zero-guard, no-SIMD all explicitly listed.

### Verified: Scope confined to `SonicMania/Objects/UFO/UFO_Setup.c`
"Files to create/modify" sections in Step 1 list only `UFO_Setup.c`. "What NOT to do" line 43 prohibits RSDKv5 changes. "Out of scope" Step 1 line 369 prohibits modifying other UFO_*_Draw or UFO_Setup_Deform_*. Scope is correctly bounded.

### Verified: Validation strategy adequate
Step 2 documents desktop SDL2 A/B with `git stash` + `compare -metric AE`. Step 3 documents cross-build + deploy + 10s smoke. Step 5 user-gated documents the specific UFO5 visual checks (band shifts, swimming, frame rate). Tolerance documented (≤1 LSB → ≤1/65536 pixel; AE < 100 acceptable). Comprehensive enough.

### Verified: Fallback Approach F is concrete
Lines 720-741 give the F implementation sketch (memoize prev_div, only divide on change), document its win profile (best/worst/typical), and instruct the implement agent to pivot if C breaks within 30 min. Concrete and actionable.

### Verified: `if (!div) div = 1` zero-guard preserved in BuildRecipTable
Plan line 235-236 places the guard inside the table-build loop. Correct semantic preservation: when the original would have computed `h = NUM / 1`, the new code computes `recip[i] = (1<<30) / 1 = 2^30`, then `h = (NUM * 2^30) >> 30 = NUM`. Bit-exact for the guard case.

---

## Verdict

The plan is **largely correct and ready to ship after the P-1 fixes**. Approach C is well-chosen and the algebra is sound. The fix-agent should:

1. Change `static uint16 ufo_setup_cached_angle = 0;` → `static int32 ufo_setup_cached_angle = -1;` in the Step 1 change sketch (P1-A).
2. Reconcile the NUM bound — replace `2^25` with `2^29` in the precision-analysis discussion and overflow-check failure-mode (P1-B).
3. Optionally drop `angle` from the cache key for better hit rate (P2-A).
4. Optionally use `INT32_MIN` instead of `0x7FFF` as the `angleX` sentinel (P2-B).
5. Optionally cite `Object.cpp:739` for the threading verification claim (P2-C).

P-1 items are blockers; P-2 items are nice-to-haves the fix-agent can apply if time permits.
