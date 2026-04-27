# UFO Item 6 Implementation — Review Findings

## Summary

The Item 6 implementation in commit `575c2c1f` is a clean, minimal, single-file change that matches the plan's locked decisions exactly. The parity gate, the heavy-work scope, the unconditional state-reset, and the commit-message accuracy all check out. Build artifacts on host and on-device are byte-identical (BuildID match). **Approve as-is. 0 P-1 findings, 0 P-2 findings.** One purely informational note about the `EntityUFO_Setup.timer` shadow, which is not a bug.

## P-1 — Must Fix (correctness/safety bugs)

None.

## P-2 — Should Fix (design/robustness/clarity)

None.

## Verified correct

### 1. Parity gate condition (matches locked decision)
`SonicMania/Objects/UFO/UFO_Plasma.c:32` — `if (!(UFO_Setup->timer & 1)) {` — heavy work runs on EVEN frames as locked by the plan ("locked: parity-0 path = heavy"). Stage entry has `UFO_Setup->timer = 0` (object zero-init by RSDK; only the entity's `self->timer` is set to 512 in `UFO_Setup_Create`), parity 0, so the first Plasma frame draws — matches the plan's intended visual at stage entry.

### 2. SetClipBounds and SetActivePalette OUTSIDE the gate (load-bearing)
`UFO_Plasma.c:51-53` — both calls live below the closing brace of the `if (!(UFO_Setup->timer & 1)) { ... }` block. Verified by reading lines 32–53: gate opens at line 32, closes at line 49 after `DrawDeformedSprite`, comment marker at line 51 explicitly notes "Unconditional state reset — runs on both parity-0 and parity-1 frames," and the two `RSDK.*` calls follow at lines 52–53. This is the P-1A failure mode the original plan reviewer caught; correctly avoided.

Confirmed engine-side: `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Palette.hpp:44-47` — `SetActivePalette(0, 0, h)` iterates `gfxLineBuffer[l] = newActiveBank` for every line in `[startLine, endLine)`, which is the gfxLineBuffer reset path the plan calls out.

### 3. Scanline-loop AND DrawDeformedSprite INSIDE the gate
- `UFO_Plasma.c:33-46` — the 240-iter scanline table setup is inside the gate.
- `UFO_Plasma.c:48` — `RSDK.DrawDeformedSprite(UFO_Plasma->aniFrames, INK_MASKED, 0x100);` is inside the gate.
Both heavy paths are correctly gated; the trailing two calls are the only thing outside.

### 4. No new globals or static state
The diff adds zero new declarations. The implementation reads `UFO_Setup->timer` directly. Verified by `git show 575c2c1f -- SonicMania/Objects/UFO/UFO_Plasma.c`.

### 5. `UFO_Setup->timer` field exists
`SonicMania/Objects/UFO/UFO_Setup.h:24` — `int32 timer;` is a member of `struct ObjectUFO_Setup`. Note: there is also a shadowed `int32 timer;` at line 42 in `struct EntityUFO_Setup`, but the reference `UFO_Setup->timer` resolves to the singleton object pointer (line 47: `extern ObjectUFO_Setup *UFO_Setup;`), not the entity, so the lookup is unambiguous.

### 6. timer parity drift / monotonicity — no resets, parity preserved across wrap
- `SonicMania/Objects/UFO/UFO_Setup.c:63-64` is the only mutation to `UFO_Setup->timer`: `++UFO_Setup->timer; UFO_Setup->timer &= 0x7FFF;`. Monotonic, no reset.
- `grep -rn "UFO_Setup->timer\s*=" SonicMania/` returns no other matches in the SonicMania tree (the `=` line is the increment-and-mask). The `self->timer = 512;` assignment at `UFO_Setup.c:89` is `EntityUFO_Setup.timer`, not the object timer (different field; entity-shadowed name).
- Wrap behavior at `0x7FFF` (odd → 0): parity flips correctly at wrap (odd → even), so half-rate cadence does not stick on a single parity. Plan's claim that timer is "the same parity source the existing scanline LUT computation uses" is correct; the new code reads the same `UFO_Setup->timer` value the gate-skipped code on lines 33–34 would read on a parity-0 frame, so the parity-0 frame's deformation parameters are exactly what they were pre-Item-6.

### 7. Commit body accuracy
`git show 575c2c1f` body is accurate against the plan and against the actual code change:
- Describes Plasma's heavy work as 240-iter scanline + 320×240 INK_MASKED blit (matches `UFO_Plasma.c:33-48`).
- Cites engine `Drawing.cpp ~3877-4082` for the per-pixel cost class (range matches plan engine-contract item 1).
- Names the parity gate as `UFO_Setup->timer & 1` and identifies the heavy path as the EVEN-frame path implicitly (the diff makes this clear).
- Correctly attributes the palette-reset preservation reasoning: trailing `SetActivePalette` is the only `gfxLineBuffer[]` reset path because `UFO_Plasma_StageLoad` overwrites the drawGroup-3 prepare hook with `StateMachine_None`. Verified at `UFO_Plasma.c:87` — `RSDK.SetDrawGroupProperties(3, false, StateMachine_None);` (line number is 87 post-edit, plan referenced "line 71" pre-edit, both refer to the same call; the call is present).
- Lists prior shipped items as `Items 1, 4, 7, 2 already shipped (7541c0d2/e6115147/5735e614/9678afb0)` — matches the prompt's expected list of Items 1, 4, 7, 2 = `7541c0d2`, `e6115147`, `5735e614`, `9678afb0` exactly.
- Correctly states Item 5 deferred per user direction; Item 3 closed-out as never-fires.
- Validation block honest about user-driven gameplay test being the gating step.

### 8. On-device binary BuildID match
- Host: `build/mister-telemetry-install/bin/RSDKv5U` — ARM EABI5 ELF, BuildID `b4c234baebc1c90f391918051a8cde3e4d209d8b`, 6,645,440 bytes.
- Device: `/media/fat/games/sonic-mania/bin/RSDKv5U` — BuildID `b4c234baebc1c90f391918051a8cde3e4d209d8b`, 6,645,440 bytes.
Match confirmed. Device file mtime is `Apr 27 13:57` (UTC) versus host `Apr 27 09:57` (local-time/EDT) — same instant, formats differ.

### 9. Pre-existing unrelated working-tree state
`git show 575c2c1f --stat` shows exactly one file: `SonicMania/Objects/UFO/UFO_Plasma.c | 44 +++++++++++++++++++++++++------------`. No `LogoSetup.c`, no submodule pointer, no other files in the commit. The pre-existing modifications to `SonicMania/Objects/Menu/LogoSetup.c`, `dependencies/RSDKv5`, and `docs/ufo-special-stage-perf-items356-plan.md` remain in the working tree (`git status` confirms) and were correctly NOT staged into the Item 6 commit.

### 10. Plan-doc execution-notes append
`git diff docs/ufo-special-stage-perf-items356-plan.md` shows a new `## Plan execution notes — 2026-04-25` section appended at the bottom (line 695+). Content is accurate:
- Item 6 commit hash `575c2c1f` matches.
- Item 5 deferred per explicit user direction.
- Diff stat claim "+30/-14" matches `git show 575c2c1f --stat` (`44 +++++++++++++++++++++++++------------`, 30 insertions/14 deletions).
- BuildID `b4c234baebc1c90f391918051a8cde3e4d209d8b` and byte size `6,645,440` match host and device.
- On-device boot smoke notes (`NativeVideoWriter_Init`, SIGTERM exit code 124) match the verification commands' result class.
- Append-only, no edits to earlier sections — matches the plan's wrap-up rule.

The note is in the working tree but unstaged, consistent with the implementer's "single commit only" constraint.

## Build status

- **SDL2 desktop build (`build-p7-fix-sdl2`):** clean. `cmake --build build-p7-fix-sdl2 -- -j8` exited 0; final lines `[  8%] Built target SonicMania` / `[100%] Built target RetroEngine`. No new warnings.
- **Host armhf binary:** `build/mister-telemetry-install/bin/RSDKv5U` present, ARM EABI5 ELF, BuildID `b4c234baebc1c90f391918051a8cde3e4d209d8b`, 6,645,440 bytes.
- **On-device binary BuildID match:** confirmed identical (`b4c234baebc1c90f391918051a8cde3e4d209d8b`, 6,645,440 bytes) at `/media/fat/games/sonic-mania/bin/RSDKv5U`.
- **On-device boot smoke:** per the implementer's execution notes, clean exit on SIGTERM after engine + render-device init. The current review did not re-run the smoke (deemed redundant given BuildID match), but the verification commands confirm the deployed file is the freshly-built one.
- **Git state:** `mister` HEAD is `575c2c1f`; working tree has only the three pre-existing unrelated dirty paths.

## Bottom line

Approve. No fixes required.
