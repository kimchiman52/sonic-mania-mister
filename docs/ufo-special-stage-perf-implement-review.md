# UFO Special Stage Perf Implementation — Review Findings

**Review date:** 2026-04-25
**Branch:** `mister`
**Commits reviewed (oldest → newest):**
- `7541c0d2` mister: skip 3D Roof scanline setup when fully clipped (Item 4)
- `e6115147` mister: coalesce per-scanline SetActivePalette into RLE bands (Item 1)
- `5735e614` mister: early-return UFO_Sphere_Draw on near-zero zdepth (Item 7)

## Summary

Implementation matches the plan exactly, in order, on three independent commits. All high-risk failure modes flagged by the plan are correctly handled (SetClipBounds-then-early-return ordering in Item 4; `bandBank = -1` sentinel and trailing flush present in all three callbacks for Item 1; `||` disjunction with DrawSprite inside the protected region for Item 7). Scope is clean — only `UFO_Setup.c` and `UFO_Sphere.c` were touched, no submodule modification, no other UFO files. Build is green with no new warnings. **0 P-1 findings, 0 P-2 findings — approve as landed.**

## P-1 — Must Fix (correctness/safety bugs)

None.

## P-2 — Should Fix (design/robustness/clarity)

None.

## Verified correct

### Item 4 (commit `7541c0d2`)
- `UFO_Setup.c:283` — `RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, camera->clipY - 48)` runs FIRST.
- `UFO_Setup.c:289-290` — `if (camera->clipY <= 48) return;` runs AFTER `SetClipBounds`. Plan's most-flagged failure mode (clip leak from prior callback) is correctly avoided.
- Condition direction is correct: when `clipY <= 48`, the `clipY - 48` y2 clamps to 0 → empty clip → roof tile-layer renders zero rows, so skipping the per-scanline setup is safe.
- Comment block at `UFO_Setup.c:285-288` clearly documents the WHY (Phase 11 perf, SetClipBounds preserved above).
- `git show --stat 7541c0d2` confirms exactly one file changed, +7/-0.

### Item 1 (commit `e6115147`)
- All three callbacks have the coalescer applied. Verified by reading final state:
  - `UFO_Setup_Scanline_Playfield` — `UFO_Setup.c:186-231`
  - `UFO_Setup_Scanline_3DFloor` — `UFO_Setup.c:233-278`
  - `UFO_Setup_Scanline_3DRoof` — `UFO_Setup.c:279-332`
- **`bandBank = -1` sentinel correctly initialized in all three callbacks:**
  - Playfield: `UFO_Setup.c:199-200`
  - 3DFloor: `UFO_Setup.c:246-247`
  - 3DRoof: `UFO_Setup.c:300-301`
- **Transition emit correctly uses OLD bank over `[bandStart, line)`** (exclusive end):
  - Playfield: `UFO_Setup.c:215-220` — emits `bandBank` (the previous bank) over `[bandStart, line)`, then opens new band with `bandStart = line; bandBank = bank;`.
  - Same shape in 3DFloor (`UFO_Setup.c:262-267`) and 3DRoof (`UFO_Setup.c:316-321`).
  - `line = i + SCREEN_YCENTER` is the START of the new band, used as the EXCLUSIVE END of the OLD band — matches the `SetActivePalette(bank, start, end)` `[start, end)` contract.
- **Trailing flush present in all three callbacks, all using `SCREEN_YSIZE`:**
  - Playfield: `UFO_Setup.c:229-230`
  - 3DFloor: `UFO_Setup.c:276-277`
  - 3DRoof: `UFO_Setup.c:330-331`
  - All gated on `if (bandBank >= 0)` for safety. This was the plan's #1 most-common-bug-source and it's correctly handled in all three places.
- **Bank formulas match originals exactly:**
  - Playfield: `CLAMP(abs(pos) >> 15, 0, 7)` — `UFO_Setup.c:212`
  - 3DFloor: `CLAMP((abs(pos) >> 15) - 8, 0, 7)` — `UFO_Setup.c:259`
  - 3DRoof: `CLAMP(abs(pos) >> 14, 0, 7)` — `UFO_Setup.c:313`
- **3DRoof coalescer init lives AFTER Item 4's early-return** (`UFO_Setup.c:289-290` early-return, `UFO_Setup.c:300-301` coalescer init). When the early-return fires, the coalescer doesn't run — wins compound correctly.
- All other rendering / scanline computation (`scanlines->position`, `scanlines->deform`, the `scanlines++` step, `cosVal += cosX`) is unchanged from the original loop bodies.

### Item 7 (commit `5735e614`)
- `UFO_Sphere.c:42-43` — `if (self->drawGroup != 4 || self->zdepth < 0x100) return;` confirmed as **disjunction (`||`)**, not conjunction. With the demorgan inversion of the original `if (drawGroup == 4 && zdepth >= 0x100)`, this is the correct shape.
- `UFO_Sphere.c:51` — `RSDK.DrawSprite(&self->animator, &self->drawPos, true);` is AFTER the early-return (inside the protected region). The behind-camera stale-drawPos bug (the actual correctness fix) is now resolved.
- `git show --stat 5735e614` confirms **exactly one file changed** (`SonicMania/Objects/UFO/UFO_Sphere.c`), +8/-7.
- No other UFO_*_Draw functions modified.

### Cross-cutting
- **Commit-message style.** All three commits use `mister:` prefix matching in-house convention (verified against `git log` history). Bodies clearly explain the WHY:
  - Item 4 explains the wasted-work scenario and the SetClipBounds-preserve invariant.
  - Item 1 explains bit-equivalence and the trailing-flush rationale.
  - Item 7 explains the actual correctness bug (behind-camera stale drawPos) and includes the audit summary.
  - **No "double-draw bug" mentions** — confirmed via `git log --format=%B HEAD~3..HEAD | grep -i double` returning no matches. The retracted-by-plan-fix-agent claim is correctly absent.
- **No scope creep.** `git diff HEAD~3 HEAD --stat` shows exactly:
  - `SonicMania/Objects/UFO/UFO_Setup.c`: +57/-4
  - `SonicMania/Objects/UFO/UFO_Sphere.c`: +8/-7
  No other UFO files (Ring/Dust/Springboard/Decoration/Shadow/Player/SpeedLines/ItemBox/Plasma/Circuit/HUD/Camera/Water/Message) touched.
- **No submodule modification.** `git diff HEAD~3 HEAD -- dependencies/RSDKv5` is empty. `git submodule status dependencies/RSDKv5` shows `0977e6b3...` clean (no `+` or `-` prefix). Note: the gitStatus snapshot at conversation start showed `m dependencies/RSDKv5`, but at review time `git status` shows a clean tree — the submodule's prior WIP state was either committed elsewhere or reset, but importantly **none of the three review commits touched it**, which is the load-bearing claim.
- **Three commits, plan order, on top of the docs commit.** `git log --oneline -5` confirms:
  ```
  5735e614 mister: early-return UFO_Sphere_Draw on near-zero zdepth
  e6115147 mister: coalesce per-scanline SetActivePalette into RLE bands
  7541c0d2 mister: skip 3D Roof scanline setup when fully clipped
  5349eab1 docs: UFO Special Stage perf plan + review (items 1, 4, 7)
  92a8e761 mister: Phase 10c default-swap — 16:9 default, 4:3 named ...
  ```
  Order matches plan: Item 4 (roof) → Item 1 (palette RLE) → Item 7 (sphere). Each is independently revertible.
- **Working tree clean.** `git status` returns "nothing to commit, working tree clean".

## Build status

```
$ cmake --build build-p7-fix-sdl2 -- -j8
[  8%] Built target SonicMania
[100%] Built target RetroEngine
```

Forced full rebuild of both touched files via `touch SonicMania/Objects/UFO/UFO_Setup.c SonicMania/Objects/UFO/UFO_Sphere.c && cmake --build build-p7-fix-sdl2 -- -j8`:

```
[  2%] Building C object CMakeFiles/SonicMania.dir/SonicMania/Objects/All.c.o
[  5%] Linking C shared library libGame.dylib
[  8%] Built target SonicMania
[100%] Built target RetroEngine
```

Exit 0. **No new warnings.** SonicMania uses unity-build via `All.c`, so the touched UFO files compiled cleanly through that path.

## Approval

The implementation is faithful to the plan. All plan-flagged failure modes (SetClipBounds ordering, sentinel correctness, trailing flush presence, disjunction operator, DrawSprite placement) are correctly handled. Build is green. No P-1 or P-2 findings. **The fix agent has nothing to do — this can ship as-is.**
