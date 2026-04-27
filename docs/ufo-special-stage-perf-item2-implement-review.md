# UFO Item 2 Implementation — Review Findings

**Reviewer:** implement-review agent
**Date:** 2026-04-25
**Commit under review:** `9678afb0` "mister: replace per-scanline divide with shared Q30 reciprocal table"
**Plan:** `docs/ufo-special-stage-perf-item2-plan.md`
**Prior plan-review:** `docs/ufo-special-stage-perf-item2-review.md`

## Summary

**Verdict: APPROVE with no P-1 findings; 2 P-2 cosmetic findings.** The implementation cleanly executes the plan as revised by the prior plan-review pass. All locked decisions are honoured: cache key is `angleX` only (P2-A from prior review applied), Q30 reciprocal table sized to `SCREEN_YSIZE` (240), `(long long)` 64-bit intermediate multiplies, `>> 30` arithmetic right-shift, zero-guard correctly relocated into `BuildRecipTable`, Item-4 early-return preserved before `BuildRecipTable` in 3DRoof, three callbacks each use their correct callback-specific NUM. The SDL2 desktop build is clean; the armhf cross-build binary is on disk and matches the on-device deployed binary by BuildID. Working tree shows only the pre-existing RSDKv5 submodule WIP (no submodule pointer change). Single commit on `mister`, as planned.

The two P-2 findings are cosmetic / follow-up notes — neither blocks ship:
1. The implementer's claim in the commit body that `<stdint.h>` is brought transitively on the desktop SDL2 build but not on armhf is **false** in both directions; `<stdio.h>` does NOT pull in `INT32_MIN` on either platform (verified empirically). The literal sentinel they chose is functionally equivalent so the code is correct, but the rationale in the commit body misleads a future reader.
2. `sinX`/`cosX` are recomputed in both `BuildRecipTable` and each callback — 4 redundant `Sin1024`/`Cos1024` calls per frame on a cache miss. The plan explicitly identified this as acceptable; flagged here for future cleanup if Item 3 forces another touch of this file.

No P-1 issues. Ship.

## P-1 — Must Fix

(none)

## P-2 — Should Fix

### P2-1. Commit body's `<stdint.h>` rationale is empirically wrong (but the code is correct)

**Commit:** `9678afb0`
**Reference:** Commit message body lines (paragraph "The literal form is used instead of INT32_MIN because `<stdint.h>` is not in scope on the armhf cross-build (it is on the SDL2 desktop build via `<stdio.h>`)").
**File:line:** Comment at `SonicMania/Objects/UFO/UFO_Setup.c:19-21` repeats the same claim ("which gets `INT32_MIN` transitively from `<stdio.h>`").

**What's wrong:** Tested empirically: a translation unit that `#include <stdio.h>`s and references `INT32_MIN` fails to compile with clang on macOS:
```
/tmp/test_int32_min.c:2:21: error: use of undeclared identifier 'INT32_MIN'
```
`<stdio.h>` does NOT transitively bring `INT32_MIN` on the SDL2 desktop build either. `INT32_MIN` is from `<stdint.h>` (or `<cstdint>` for C++); it is not referenced or pulled in by any header in `RetroEngine.hpp`'s include chain. A grep across `dependencies/RSDKv5/RSDKv5/` shows `<stdint.h>` is only included in `MiSTer/MiSTerPacer.hpp` and `MiSTer/NativeVideoWriter.h`, neither of which `UFO_Setup.c` reaches.

**Why it doesn't matter for shipping:** the implementer's literal sentinel `(-2147483647 - 1)` is functionally equivalent to `INT32_MIN` and compiles in both desktop and armhf builds, so the code itself is correct. The fix-agent should NOT change the literal — it works.

**What should be fixed:** the commit body and the in-source comment. The justification should read something like "`INT32_MIN` requires `<stdint.h>` which is not in scope at this TU; rather than add an include, the literal form is used." This is a documentation-tightness issue only.

**Severity:** P-2 cosmetic. The plan explicitly listed `(-2147483647 - 1)` as an acceptable alternative (plan line 374: "or write `(-2147483647 - 1)` literally"); the implementer correctly took that path. The misleading rationale is a minor reviewer-irritant.

### P2-2. Redundant `sinX`/`cosX` computation on cache miss

**Commit:** `9678afb0`
**File:line:** `SonicMania/Objects/UFO/UFO_Setup.c:32-33` (inside `BuildRecipTable`), and lines 229-230, 271-272, 319-320 (in each callback).

**What's the inefficiency:** On a cache miss, `Sin1024(-camera->angleX) >> 2` and `Cos1024(-camera->angleX) >> 2` are computed 4 times per frame: once each in `BuildRecipTable` and once each in whichever callback fires first. (On hits, they're computed only in the callbacks — 6 calls total across the three callbacks.) The plan explicitly called this out at line 269: "duplicate trig call PER FRAME on a cache miss, but `Sin1024`/`Cos1024` are LUT lookups, each ~3 cycles. The duplicate cost is negligible; the alternative — passing `sinX/cosX` into the helper — pollutes the helper's signature for no real saving."

**Why it doesn't matter for shipping:** plan-author explicitly accepted this tradeoff as "negligible" (~6 cycles total worst case, in the same arithmetic class as one mul). It's not a regression — the original code computed sinX/cosX in each callback too.

**What could be tightened:** if Item 3 or another follow-up touches this file, the helper signature could be widened to `BuildRecipTable(EntityUFO_Camera *camera, int32 sinX, int32 cosX)` and the trig moved before the `BuildRecipTable` call. Saves 2 Sin1024 + 2 Cos1024 LUT lookups per frame on a miss; ~6 cycles. Below the noise floor of the perf target.

**Severity:** P-2 follow-up. Not actionable now.

## Verified correct

The following load-bearing claims were independently verified by reading the post-commit state of `UFO_Setup.c` and cross-referencing the plan:

### Cache + table-build helper

- **Cache key is `angleX` only** (line 24, 29, 44). `angle` is NOT in the key. Matches the prior plan-review's P2-A directive (drop `angle` from the key).
- **Sentinel is `(-2147483647 - 1)`** at line 23 (the `UFO_SETUP_ANGLEX_SENTINEL` macro), matching the literal form documented in the plan's Step 1 failure-mode (line 374). The implementer's stated reason is misleading (see P2-1) but the code is correct.
- **Table size is `SCREEN_YSIZE` = 240** at line 25 (`static int32 ufo_setup_recip_table[SCREEN_YSIZE]`), matching the plan and matching the original loop's iteration count of 240.
- **Zero-guard preserved** at lines 38-39 inside the `for` loop in `BuildRecipTable`. The guard `if (!div) div = 1;` runs before the reciprocal computation, identical to the original per-callback guard semantics.
- **Reciprocal arithmetic** at line 40: `(int32)(((long long)1 << UFO_SETUP_RECIP_SHIFT) / div)`. The cast to `long long` is on the `1` literal before the left-shift. `1 << 30` fits in int32 (2^30 = 1073741824 < INT32_MAX = 2147483647), but the explicit cast makes the type unambiguous and avoids any future confusion.
- **`UFO_SETUP_RECIP_SHIFT` is 30** at line 22.

### Per-callback consumer (all three callbacks)

- **Playfield (line 238):** NUM = `camera->height`. Multiply: `(long long)camera->height * ufo_setup_recip_table[i + SCREEN_YCENTER]`. Cast on NUM (left operand). Right-shift 30. Final cast to int32. **Correct.**
- **3DFloor (line 280):** NUM = `camera->height + 0x1000000`. Cast on parenthesized NUM expression. Right-shift 30. Final cast int32. **Correct.**
- **3DRoof (line 330):** NUM = `height` local (computed at line 324: `(camera->height >> 2) - 0x600000`). Cast on `height`. Right-shift 30. Final cast int32. **Correct.**

In all three callbacks the `(long long)` cast is on the left operand of the multiply, so the multiply itself is performed in 64-bit signed arithmetic (smull on ARM). No int32×int32 overflow risk.

### Index mapping

`ufo_setup_recip_table[i + SCREEN_YCENTER]` with `i ∈ [-SCREEN_YCENTER, SCREEN_YCENTER)` maps to `[0, SCREEN_YSIZE)`. The build loop fills indices `[0, SCREEN_YSIZE)`. Matches; no off-by-one.

### Loop body cleanup

For each of the three callbacks:
- The original `int32 cosVal = -SCREEN_YCENTER * cosX;` is removed (cosVal is now a local in `BuildRecipTable`).
- The original `int32 div = ...; if (!div) div = 1;` lines inside the inner loop are removed.
- The original `int32 h = NUM / div;` line is replaced with the multiply-by-recip line.
- The original `cosVal += cosX;` increment at end-of-loop is removed.
- `sinX` and `cosX` declarations are KEPT (still used in the `pos = ((cosX * h) >> 8) - (sinX * ((i * h) >> 8) >> 8)` formula).

Verified at lines 229-230 (Playfield trig), 232 (BuildRecipTable call), 237 (loop start with no cosVal/div/h_div), 256 (no cosVal increment after `scanlines++`). Same pattern at lines 271-274 / 296 (3DFloor) and 319-322 / 348 (3DRoof).

### 3DRoof step ordering with Item-4 early-return

Lines 304-322:
```
1. RSDK_GET_ENTITY (line 306)
2. SetClipBounds (line 308)
3. Item-4 early-return: if (camera->clipY <= 48) return; (line 314-315)
4. Trig setup: sin/cos/sinX/cosX (lines 317-320)
5. UFO_Setup_BuildRecipTable(camera) (line 322)
6. height = (camera->height >> 2) - 0x600000 (line 324)
```
Order matches the plan's Step 1 sketch exactly. `BuildRecipTable` is correctly placed AFTER the early-return, so a fully-clipped roof does not pay for table build. Floor or Playfield will rebuild later in the same frame on first-use if needed.

### Negative NUM correctness in 3DRoof

When `camera->height < 0x1800000`, `(camera->height >> 2) - 0x600000` is negative (e.g. at the Create default 0x300000: `0xC0000 - 0x600000 = -0x540000`). The `(long long)height` cast preserves sign through to int64; signed multiply by positive recip preserves sign; arithmetic right-shift on signed int64 (which is what `>> 30` compiles to) preserves sign on the negative product. C-language signed right-shift is implementation-defined, but clang and gcc both use arithmetic shift on ARM/x86_64. Verified.

### Build clean

- **SDL2 desktop:** `cmake --build build-p7-fix-sdl2 -- -j8` exits 0 with no new output (already-built target). Built target SonicMania.
- **armhf cross-build artifact on disk:** `build/mister-telemetry-install/bin/RSDKv5U` exists, is ARM ELF, BuildID `8c726c5755f3838c3ad1629c45ea29fd695ccb60`, mtime Apr 26 23:10. Confirmed a recently-built ARM binary.
- **On-device binary BuildID matches:** `/media/fat/games/sonic-mania/bin/RSDKv5U` on the MiSTer at 192.168.1.188 has identical `BuildID[sha1]=8c726c5755f3838c3ad1629c45ea29fd695ccb60`, mtime Apr 27 03:10 (4-hour timezone offset from host's 23:10 — UTC vs ET; same build). Deployed cleanly.

### Git state

- Latest commit on `mister`: `9678afb0` ✓
- Single commit, as planned ✓
- Working tree: only `dependencies/RSDKv5 (modified content)` — pre-existing WIP in the submodule (per plan's "What NOT to do" leave-alone item). Submodule pointer unchanged: `0977e6b3c06a2dadf1340f945b9422ec0f554241 (v1.1.1-19-g0977e6b)`. Matches the prior plan-execution state. ✓
- The previous task description mentioned untracked `grabtest.c` and modified `vendor/Main_MiSTer/sonicmania_wrapper.cpp` etc.; those have been cleaned up between the snapshot in the task description and this review. Not the implementer's responsibility.

### Plan adherence

All Step 1 success criteria from the plan (lines 350-361) are met:
- File compiles in SDL2 desktop ✓
- Single file changed (`UFO_Setup.c`) ✓
- Sizing roughly +50/-15: actual is +42/-21, well within the rough estimate ✓
- All three callbacks have the correct prologue ordering (SetClipBounds → optional early-return → trig → BuildRecipTable → loop) ✓
- Module-static cache declared above all three callbacks (line 22-25) ✓
- Item-1 palette band-tracker preserved (`bandStart = 0; bandBank = -1;` at lines 234-235, 276-277, 326-327; trailing flush at 259-260, 301-302, 351-352) ✓

## Build status

```
$ cmake --build build-p7-fix-sdl2 -- -j8
[  8%] Built target SonicMania
[100%] Built target RetroEngine

$ ls -la build/mister-telemetry-install/bin/RSDKv5U
-rwxr-xr-x@ 1 sb  staff  6641164 Apr 26 23:10 build/mister-telemetry-install/bin/RSDKv5U

$ file build/mister-telemetry-install/bin/RSDKv5U
build/mister-telemetry-install/bin/RSDKv5U: ELF 32-bit LSB pie executable, ARM, EABI5 version 1 (SYSV),
dynamically linked, interpreter /lib/ld-linux-armhf.so.3,
BuildID[sha1]=8c726c5755f3838c3ad1629c45ea29fd695ccb60, for GNU/Linux 3.2.0, not stripped

$ ssh root@192.168.1.188 'file /media/fat/games/sonic-mania/bin/RSDKv5U && ls -la ...'
/media/fat/games/sonic-mania/bin/RSDKv5U: ELF 32-bit LSB shared object, ARM, EABI5 version 1 (SYSV),
dynamically linked, interpreter /lib/ld-linux-armhf.so.3,
BuildID[sha1]=8c726c5755f3838c3ad1629c45ea29fd695ccb60, for GNU/Linux 3.2.0, not stripped
-rwxr-xr-x 1 root root 6641164 Apr 27 03:10 /media/fat/games/sonic-mania/bin/RSDKv5U
```

BuildID `8c726c5755f3838c3ad1629c45ea29fd695ccb60` matches between host and on-device binaries — the deployed binary IS this commit's build. Note the file-type mismatch ("pie executable" on host, "shared object" on device): this is a `file(1)` reporting quirk for PIE ELFs (PIE executables have ET_DYN like shared libraries; some `file` versions disambiguate via the program-header interpreter, others don't). Not a defect.

```
$ git log --oneline -3
9678afb0 mister: replace per-scanline divide with shared Q30 reciprocal table
73fb4746 docs: UFO Item 2 plan + review (per-scanline division elimination)
26a717ba mister: fix deploy-script path (CamelCase → lowercase canonical)

$ git submodule status dependencies/RSDKv5
 0977e6b3c06a2dadf1340f945b9422ec0f554241 dependencies/RSDKv5 (v1.1.1-19-g0977e6b)
```

Submodule pointer unchanged (no leading `+` or `-`); only working-tree WIP content. Matches plan's directive to not touch the submodule.

## Conclusion

Approve. No P-1 findings. Two P-2 documentation/follow-up items that do not affect correctness or perf. The fix-agent has the option to clean up the misleading `<stdint.h>` rationale in the commit body and source comment, but the code itself ships as-is.
