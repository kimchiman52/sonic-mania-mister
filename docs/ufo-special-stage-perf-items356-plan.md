# UFO Special Stage — Items 6 + 5 (Plasma half-rate, fat-scanline 3D Floor/Roof)

**Document date:** 2026-04-25
**Status:** Plan only. Not yet implemented.
**Branch:** `mister`
**Scope:** Two independent perf changes bundled into one `/implement` pass with **two independent commits** (one per item, each individually revertable). The RSDKv5 submodule (`dependencies/RSDKv5`) is NOT modified.

**Item 3 dropped during plan-fix (2026-04-25):** the original plan also included a sphere/ring radius cull at `(dx >> 16) > 0x600` against `updateRange.x = 0x400`. The reviewer found that `ACTIVE_RBOUNDS` (`dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp:435-446`) compares **squared** distance against `updateRange.x = 0x400`, so the engine's effective pass radius is √1024 ≈ 32 in `>> 16` units. Any entity reaching `LateUpdate` is at most ~32 in those units; the proposed `0x600 = 1536` threshold can never fire. Reformulating as a frustum / single-row-of-matrix cull would lengthen this plan and the magnitude was already noise-floor (~2–5 μs/frame). Dropped as not worth the planning overhead. Item 6 still ships and is the headliner.

This is the **third planning round** in the UFO Special Stage perf effort. Items 1, 4, 7 (`7541c0d2`, `e6115147`, `5735e614`) and Item 2 (`9678afb0`) have shipped. Combined estimated saving: ~30k cycles/frame ≈ 50 μs ≈ 0.3% of a 60 fps budget. **The user reports the minigame is "still slow af" on hardware.** That delta is consistent with the prior items not being on the dominant hot path. This plan attacks the next-most-likely candidates while being **honest that the bottleneck location has not been confirmed** — Step 0 is a user-gated measurement that gates whether item 5 is worth shipping at all (item 6 ships unconditionally because it's the highest expected magnitude and a single-file edit that's trivially revertable).

**Source-of-truth files (must be re-read by `/implement` before editing):**
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Plasma.c` — full file (currently 81 lines).
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` — lines ~263–353 (the 3DFloor and 3DRoof callbacks post-Items 1+2+4).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — `DrawDeformedSprite` lines 3877–4082 (read-only; anchor for Item 6 magnitude).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Scene/Scene.cpp` — `DrawLayerHScroll` lines 1308–1459 (read-only; anchor for Item 5 ceiling).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Scene/Object.cpp` — lines 780–807 (the scanlineCallback dispatch site).
- `/Users/sb/Developer/sonic-mania-mister/docs/ufo-special-stage-perf-plan.md` — bundled-low-risk Items 1/4/7 plan (style template).
- `/Users/sb/Developer/sonic-mania-mister/docs/ufo-special-stage-perf-item2-plan.md` — Item 2 plan (style template; locked-decisions section is the most prescriptive in-repo example).
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — build/deploy/F3/F6/F12 telemetry flow; post-`26a717ba` lowercase install path.

---

## Engine contracts already verified by the plan author (do not re-derive)

These were established by reading the actual engine code on 2026-04-25; the implement agent should re-read the cited spans only if the assertion is disputed during fix-up.

1. **`DrawDeformedSprite` with `INK_MASKED` is the same per-pixel cost class as `INK_NONE`.** Read `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:4044-4061`. The INK_MASKED loop body is:
   ```cpp
   uint8 palIndex = pixels[((FROM_FIXED(ly) & height) << lineSize) + (FROM_FIXED(lx) & width)];
   if (palIndex && *frameBuffer == maskColor)
       *frameBuffer = activePalette[palIndex];
   lx += dx; ly += dy; ++frameBuffer;
   ```
   Versus INK_NONE (lines 3914-3932): one less compare (`*frameBuffer == maskColor`). The cost dominator is the **240 lines × pitch (=320) = 76,800 iterations** of texture fetch + framebuffer store. There is **no expensive per-pixel branch** beyond the maskColor compare — no LUT lookup, no alpha blend, no multiplication. On Cortex-A9 estimate ~5–8 cycles/iteration ≈ 380k–615k cycles/frame ≈ 630 μs–1 ms at 600 MHz. **This is by far the largest single thing in the UFO5 frame budget that we have leverage over** — bigger than Items 1+2+4+7 combined by an order of magnitude. The prompt's hypothesis that Plasma's `Draw()` is the actual hog is well-founded.

2. **The engine reads `scanlines[]` per output line during tile-layer rasterization. There is no API to share one scanline entry across multiple output lines without modifying the submodule.** Read `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Scene.cpp:1308-1459` (`DrawLayerHScroll`, the mode used by Playfield/3DFloor/3DRoof). Line 1318: `for (int32 cy = currentScreen->clipBound_Y1; cy < currentScreen->clipBound_Y2; ++cy)` increments through every output line; line 1457 `++scanline;` at the bottom of the loop body advances the scanline pointer one entry per output line. **Consequence for Item 5:** halving the scanline-callback's iteration count (only writing every other entry) saves ~50% of OUR callback's per-line work, but the engine's tile rasterizer still runs at full per-line resolution; it just reads identical scanline data for the duplicated rows. Item 5's savings are **bounded to the callback math, not the rasterization** — see "Item 5 magnitude (honest)" below.

3. **`UFO_Plasma_Draw` ends with two engine-state mutations that downstream drawGroups depend on.** Read `UFO_Plasma.c:36-37`. The trailing `RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, ScreenInfo->size.y)` and `RSDK.SetActivePalette(0, 0, ScreenInfo->size.y)` are the **only** path that resets `gfxLineBuffer[]` after the prior drawGroup's tile-layer scanline callbacks (Playfield's per-line palette banks from Item 1's RLE coalescer). On UFO5, `UFO_Plasma_StageLoad` (`UFO_Plasma.c:71`) overwrites the drawGroup-3 prepare hook to `StateMachine_None`, so there is no other reset path. The engine's per-drawGroup cleanup at `Object.cpp:825-845` resets `clipBound` but **not** `gfxLineBuffer[]`. Consequence: Item 6's frame-skip MUST keep the trailing two calls unconditional, or sphere/ring DrawSprite at drawGroup 4 will use stale per-line palette bands and produce visible color flicker every other frame.

4. **Two commits is the right granularity.** Plasma half-rate (Item 6) is one logical change in one file. Fat-scanline (Item 5) is one logical change in two callbacks of the same file. Each can be `git revert`'d independently.

---

## Locked decisions (DO NOT REVISIT)

- **Two commits, in plan order:** Item 6 → Item 5. Biggest-expected-magnitude first; if a regression hits we know which item is to blame, and a `git revert` of the most recent commit pulls only that item.
- **Item 6 ships unconditionally regardless of Step 0 outcome.** It's the highest expected magnitude (~600 μs/frame estimate), the simplest change (one file, one branch), and trivially revertable. Even if Step 0 reveals the bottleneck is elsewhere, Item 6 is still the right thing.
- **Item 5 is gated on Step 0.** If Step 0 reveals `update ms` (game logic) is high (>10 ms) and `raster ms` is low, item 5 won't help — it's a rendering-side optimization. The plan documents this gate; the implement agent skips item 5 if the gate fails and notes the skip in the wrap-up.
- **Item 6 approach: half-rate the heavy work (scanline-table setup + DrawDeformedSprite) but keep the trailing engine-state reset calls unconditional.** The scanline-table setup (lines 20–33 of `UFO_Plasma.c`) iterates 240 times writing to `UFO_Plasma->scanlines`; the `DrawDeformedSprite` (line 35) is the 76,800-pixel deformed blit. Both are skippable on alternate frames. The trailing `SetClipBounds` (line 36) and `SetActivePalette(0, 0, h)` (line 37) **must run every frame** — they reset `gfxLineBuffer[]` so downstream drawGroup-4 sprites (UFO_Sphere, UFO_Ring) read clean palette bank data for `DrawSprite`, not the per-line bands left by Playfield's scanline callback. Half-rating the body without the reset would produce visible color flicker on spheres and rings every other frame. **Visual consequence (intended):** the lightning effect's animation rate halves from 60 Hz to 30 Hz. The state-reset cost is negligible compared to `DrawDeformedSprite`, so the magnitude estimate (~310–500 μs/frame) is unchanged.
- **Item 6 frame-skip key:** use `UFO_Setup->timer & 1` as the parity test. `timer` advances every static-update tick (`UFO_Setup.c:63`) and is the same parity source the existing scanline LUT computation uses (`UFO_Plasma.c:20`). The skip wraps the body, NOT the trailing reset.
- **Item 5 approach: fat scanlines for 3DFloor and 3DRoof only — write every other scanline-table entry, copy to the next, halve our loop iteration count.** The plan explicitly DOES NOT touch `UFO_Setup_Scanline_Playfield`. Playfield is the active gameplay surface; visual quality matters more there, and the band-tracking palette logic is the visible feature most sensitive to a fat-scanline regression. (Floor and Roof are background surfaces; the user's eye is on the player and the bumpers.)
- **Item 5 implementation shape:** for `UFO_Setup_Scanline_3DFloor` and `_3DRoof`, change the inner loop to step `i += 2` instead of `++i`, write the same `scanlines[]` entry to both even and odd positions, and update the band-tracking logic to operate on pairs of lines. The reciprocal table stays at full 240-entry resolution (it's already cached cross-frame via Item 2; rebuilding at half resolution would compromise Playfield, which still needs the full table).
- **No SIMD, no VFP, no compiler-flag changes.** Maintain the integer-only fast-math invariant the rest of the engine holds.
- **Don't modify `dependencies/RSDKv5/`.** Submodule has one unrelated WIP change in `RSDK/Mod/ModAPI.cpp` — leave it.

---

## What NOT to do

- Do NOT modify `UFO_Setup_Scanline_Playfield` in Item 5. Playfield is the active gameplay surface; fat-scanline there is more risky.
- Do NOT bundle the two items into a single commit. Two commits, in plan order. Each commit is independently revertable.
- Do NOT introduce a build-flag or runtime-toggle for half-rate Plasma. The visual feel of half-rate IS the new permanent behavior on this port.
- Do NOT change Item 6 to "alternate frames render full-rate to a back buffer, blend on intervening frames" or any cleverer approach. The whole point is to skip work; clever interpolation reintroduces work.
- Do NOT skip the trailing `SetClipBounds` + `SetActivePalette` calls in `UFO_Plasma_Draw` on the half-rate skip path. They reset `gfxLineBuffer[]`; skipping them produces visible color flicker on spheres/rings on the next drawGroup. See P-1A in the review for details.
- Do NOT measure on desktop SDL2. The macOS host has hardware divide and far more memory bandwidth than the HPS Cortex-A9; perf measurements on desktop don't generalize. Step 3's desktop step is for visual A/B only.
- Do NOT skip Step 0 for item 5. If the user can't run Step 0 right now, the implement agent ships Item 6 only and queues 5 for a follow-up `/implement` pass once Step 0 data exists.

---

## Critical autonomy notes for the implement agent

1. **Don't ask.** If a branch decision arises that isn't covered above, choose the safer option, document the choice in the commit body, proceed.
2. **The user is frustrated.** The plan's expected magnitudes are honest — see "Magnitude estimates (honest)" below. Don't oversell in commit messages. If post-deploy testing shows zero perceptible improvement, that's a possible outcome and the plan documents it.
3. **Auto-recover from failures:**
   - **SDL2 build break in Item 6:** typo in the parity-skip wrapper. Trivial. Re-read the change sketch.
   - **Color flicker on spheres/rings every other frame after Item 6 ships:** the trailing `SetClipBounds` + `SetActivePalette` calls were skipped on the parity-1 path. Move them out of the skip wrapper so they run unconditionally.
   - **Visible "fat scanline" artifact on 3DFloor/3DRoof in Item 5:** the band-tracking logic didn't follow the line-pair stepping. First check: is the band check still operating per-line or per-pair? Per-pair is correct. Second check: did `bandStart`/`bandBank` get correctly updated for both lines of a pair? See change sketch.
   - **Compile error: `INT32_MIN`/typedefs:** Item 2 already settled this in the codebase (see `9678afb0`'s wrap-up notes in `ufo-special-stage-perf-item2-plan.md`). Mirror its pattern: literal sentinels, `(long long)` for 64-bit casts inside the C unity TU.
4. **Two commits, no amends.** If a commit fails a hook, fix the issue and create a NEW commit per global guidance.
5. **Step 0 is user-gated.** Do not block Items 6/5 on Step 0; ship Item 6 unconditionally. If Step 0 hasn't been run by the user before this plan executes, document that in the wrap-up and ship Item 6 only; plan a follow-up `/implement` pass for Item 5 once Step 0 runs.
6. **Self-verify each step against its Success criteria BEFORE moving to the next.**
7. If on-device smoke surfaces a regression that can't be pinpointed in <30 min, revert the offending commit (`git revert HEAD`) and append a wrap-up note. Do NOT investigate deeper without user direction.

---

## Magnitude estimates (honest)

These numbers are **estimates anchored on Cortex-A9 instruction counts**, not measured. The wider perf effort's pattern of "each item moves the needle less than predicted" is itself evidence that microarchitectural effects (branch prediction, cache misses, NEON dispatch overhead) are eating headroom. Treat all numbers as ±50%.

| Item | Mechanism | Per-frame saving (est) | At 600 MHz | % of 60 fps budget |
|---|---|---|---|---|
| **6 — Plasma half-rate** | Skip 76,800-pixel deformed blit + 240-iter scanline setup every other frame | ~190k–300k cycles avg (half of full rate) | **~310 μs–500 μs** | **1.9% – 3%** |
| **5 — Fat-scanline 3DFloor + 3DRoof** | Halve callback iteration count (240→120) on 2 callbacks. ~30 cycles/iter saved per skipped iter × 120 × 2 = ~7,200 cycles/frame. Engine-side rasterization unchanged. | ~7k–10k cycles | ~12 μs–17 μs | 0.07% – 0.10% |
| **Stack (6+5)** | | ~197k–310k cycles | **~322 μs–517 μs** | **1.97% – 3.1%** |

**The dominant magnitude by 30× is Item 6.** Item 5 is small. It's worth shipping because it's cheap and unidirectional, but it will not be perceptible in isolation — it'll show up only in F12 jitter dumps if it shows up at all.

If after Item 6 ships the user STILL reports "still slow af," the diagnostic is:
- Re-run Step 0 with F6 detailed mode. If `update ms` is the high field, the bottleneck is game logic (audio mixer, state machines, large-N collision in UFO_Player); item 5 won't fix it.
- If `raster ms` is the high field, both of items 5/6 should help proportionally to their listed magnitude. If 6 didn't help, the engine is doing some uncategorized full-screen work we haven't identified.
- If `present ms` is the high field, the bottleneck is the framebuffer DMA / video output side — outside the game code entirely; this plan can't help.

---

## Step plan overview

| # | Step | Risk | Wall-clock | User-gated? |
|---|---|---|---|---|
| 0 | Measurement: F3/F6/F12 telemetry capture before changes | n/a | n/a | YES |
| 1 | Item 6: Plasma half-rate (1 file, ~5 lines) | low | ~10 min |  |
| 2 | Item 5: fat-scanline 3DFloor + 3DRoof (1 file, ~50 lines) | medium | ~30 min |  |
| 3 | SDL2 desktop build + visual A/B compare | low | ~15 min |  |
| 4 | Cross-build + deploy + on-device boot smoke | low | ~15 min |  |
| 5 | Two commits in plan order | none | ~10 min |  |
| 6 | User-gated gameplay test (NOT executed by `/implement`) | n/a | n/a | YES |

Steps 1–2 are independent edits that produce two working-tree changes. Step 5 commits them in plan order (Item 6 first as the highest expected magnitude, then 5) so a `git revert` strategy works cleanly.

---

## Step 0 — Measurement (user-gated; documents what to gather, not executed by `/implement`)

### Title
Capture F3/F6/F12 telemetry from a representative UFO5 run BEFORE any of the three changes ship

### Why it matters
The previous two perf rounds (~30k cycles total saved) didn't move the needle. Either the bottleneck is in places we haven't touched (Plasma — likely; engine tile rasterization — unlikely; game logic — possible) OR it isn't rendering at all. Without numbers, item 5 is spec-fishing: it assumes the per-callback math is the cost. F3/F6/F12 telemetry will tell us which side of the budget is loaded.

### Files to read first
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — Phase 6 section, "On-canvas FPS overlay" and "F12 jitter dump."

### Files to create / modify
None.

### Procedure (USER-EXECUTED, not the agent)
1. Boot Sonic Mania on MiSTer at the current `mister` HEAD (`9678afb0`).
2. From a host terminal, tail the log (F12 jitter dumps land here):
   ```bash
   sshpass -p "1" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o PubkeyAuthentication=no -o PreferredAuthentications=password \
       -o NumberOfPasswordPrompts=1 root@192.168.1.188 \
       'tail -F /tmp/sonicmania.log' | grep -E "MiSTerPacer|jitter|fps|Frame"
   ```
   (Or `scp` the full log post-run for offline analysis.)
3. Get to UFO5 (Plasma stage; the heaviest case).
4. Press **F3** to enable on-canvas FPS overlay.
5. Press **F6** to switch to detailed mode. Note the `60 u:X.X r:X.X p:X.X CL:e+NNNN` line:
   - `u` = update ms (game logic phase)
   - `r` = raster ms (Draw phase, including DrawDeformedSprite + DrawLayerHScroll)
   - `p` = present ms (frame-buffer copy / video output)
   - `CL:e+NNNN` = clock-domain error, secondary
6. Capture a 10-second window of values. Take the median of each.
7. Press **F12** to dump jitter stats to log; record `phase_err` and `late(>500us)=N` from the tailed output. F12 dump format: `[jitter] phase_err=Xus late(>500us)=N ...`
8. Report numbers back to the implement agent (or the user proceeds without — Item 6 ships unconditionally).

### What the numbers mean (decision table)
- **`u` ≥ 10 ms:** game-logic dominated. Item 5 won't help meaningfully. Ship Item 6 only. Document in wrap-up: "Item 6 shipped; item 5 deferred until logic profiling lands."
- **`r` ≥ 10 ms AND `u` < 5 ms:** rasterization dominated. Both items help, with Item 6 as the dominant contributor. Ship both.
- **`p` ≥ 5 ms:** present dominated (framebuffer DMA / vsync). Items 5 and 6 are both powerless. Ship Item 6 anyway (it's still a real saving in the right direction; it just won't be felt). Document `p` time as the next investigation target.
- **All three ≤ 5 ms BUT user reports "still slow af":** subjective slowness with the budget being met means a pacing problem — F12 jitter is the relevant metric. Investigate `late(>500us)` count and `phase_err` trend.

### Success criteria
- A baseline `(u, r, p)` triple is captured. The implement agent uses this triple to decide which items to ship per the decision table above.

### Dependencies
None. Step 0 must run BEFORE Step 1 if the user wants gating; if Step 0 is skipped, proceed with both items per the locked decision (Item 6 unconditional; 5 deferred only if Step 0 explicitly fails the gate).

### Out of scope
- The agent does not run Step 0. The user runs it.
- Don't add new telemetry instrumentation; the existing F3/F6/F12 path is the canonical budget probe.

### Failure mode + recovery
- **F3/F6 don't toggle** (key binding broken): document, ship Item 6, defer 5.
- **F12 doesn't dump** (log path stale): same — fall back on subjective report.
- **F6 numbers swing wildly** (>50% variance): camera angle / on-screen entity count varies. Have the user pick a consistent UFO5 starting position and capture the same 10-second window each time.

---

## Step 1 — Item 6: Plasma half-rate

### Title
Half-rate the heavy work in `UFO_Plasma_Draw` (scanline-table setup + DrawDeformedSprite); keep the trailing engine-state reset unconditional

### Why it matters
By the magnitude estimate, this is **30× larger than item 5**. It's the highest-expected single intervention in the entire perf series. The change is one parity-gated block wrapping the heavy path inside one function — pre-defeat the whole 240-iteration scanline-table setup AND the `DrawDeformedSprite` call on alternate frames. The visual cost is animation rate halving from 60 Hz to 30 Hz; the lightning effect is high-frequency by nature so the visual feel survives.

The trailing `RSDK.SetClipBounds(...)` and `RSDK.SetActivePalette(0, 0, h)` calls (`UFO_Plasma.c:36-37`) MUST stay unconditional. They are the only path on UFO5 that resets `gfxLineBuffer[]` after Playfield's drawGroup-1 scanline callback writes per-line palette banks (Item 1's RLE coalescer). `UFO_Plasma_StageLoad` (`UFO_Plasma.c:71`) overwrites the drawGroup-3 prepare hook to `StateMachine_None`, so there is no engine-side fallback. If the reset is skipped on the parity-1 path, drawGroup 4's `UFO_Sphere_Draw`/`UFO_Ring_Draw` would call `DrawSprite` against stale per-line palette banks, producing visible color flicker on every sphere and ring every other frame. The two reset calls are tiny (microseconds at most) compared to `DrawDeformedSprite`, so keeping them unconditional does not materially affect the magnitude estimate.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Plasma.c` — full file (currently 81 lines).
2. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` lines 61–69 — confirm `UFO_Setup->timer` advances by 1 each `StaticUpdate` (it does), wraps at 0x7FFF, and is the same source UFO_Plasma already uses for its scanline LUT indexing.

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Plasma.c` (only file touched)

### Change sketch
Wrap the scanline-table setup and `DrawDeformedSprite` in a parity gate; keep the trailing `SetClipBounds` and `SetActivePalette` calls outside the gate so they run every frame:

```c
void UFO_Plasma_Draw(void)
{
    // Phase 11+ perf (Item 6): half-rate the heavy work in Plasma's draw.
    // The 240-iteration scanline-table setup plus DrawDeformedSprite(INK_MASKED)
    // is by far the heaviest per-frame draw on UFO5. Skipping them on alternate
    // frames cuts ~310-500 us/frame at 600 MHz HPS. The lightning effect is
    // visually high-frequency (per-frame deformation noise), so 30 Hz
    // animation is acceptable.
    //
    // The trailing SetClipBounds + SetActivePalette MUST run every frame:
    // they reset gfxLineBuffer[] so drawGroup-4 sphere/ring DrawSprite reads
    // clean palette bank data instead of the per-line bands left by
    // Playfield's scanline callback. UFO_Plasma_StageLoad nulls the
    // drawGroup-3 prepare hook, so this is the only reset path on UFO5.
    if (!(UFO_Setup->timer & 1)) {
        int32 y          = (UFO_Setup->timer + 2 * ScreenInfo->position.y) << 14;
        uint8 scanlineID = ((ScreenInfo->position.y >> 1) + 2 * UFO_Setup->timer);

        ScanlineInfo *scanline = UFO_Plasma->scanlines;
        for (int32 i = 0; i < ScreenInfo->size.y; ++i) {
            scanline->position.x = TO_FIXED(ScreenInfo->position.x) + UFO_Plasma->scanlineList[scanlineID].position.x;
            scanline->position.y = y;
            scanline->deform.x   = UFO_Plasma->scanlineList[scanlineID].deform.x;
            scanline->deform.y   = 0;

            y += UFO_Plasma->scanlineList[(scanlineID + 1) & 0xFF].deform.y;
            scanline++;
            scanlineID++;
        }

        RSDK.DrawDeformedSprite(UFO_Plasma->aniFrames, INK_MASKED, 0x100);
    }

    // Unconditional state reset — runs on both parity-0 and parity-1 frames.
    RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, ScreenInfo->size.y);
    RSDK.SetActivePalette(0, 0, ScreenInfo->size.y);
}
```

The body of the function moves inside the `if (!(UFO_Setup->timer & 1))` block; the trailing two `RSDK.*` calls move out and run every frame.

**Why parity-of-`timer` and not a separate static `frame_parity = !frame_parity;`:** `UFO_Setup->timer` is the canonical UFO timer used by every UFO object; it's already used by Plasma's scanline LUT computation (line 20: `(UFO_Setup->timer + 2 * ScreenInfo->position.y) << 14`). Reading it for the parity check is free.

**Why even-runs (parity 0) and not odd-runs:** symmetric; the engine pauses at `timer = 0` and a few special states, and choosing the parity-0 path as the heavy path means the FIRST frame of the stage has Plasma drawn (timer starts at 512 per `UFO_Setup.c:89`, even, parity 0, draws). Stage entry feels visually correct.

### Success criteria
- File compiles in the SDL2 desktop build.
- `git diff --stat SonicMania/Objects/UFO/UFO_Plasma.c` shows roughly `+15/-0` (parity-gate wrapper + reindentation of the heavy-path body; the trailing two `RSDK.*` calls move below the wrapper).
- `RSDK.DrawDeformedSprite(...)` and the 240-iter scanline-table loop are INSIDE the `if (!(UFO_Setup->timer & 1)) { ... }` block.
- `RSDK.SetClipBounds(...)` and `RSDK.SetActivePalette(0, 0, ScreenInfo->size.y)` are OUTSIDE the parity block — they run on every call to `UFO_Plasma_Draw`. This is load-bearing per the engine-contract item 3 above (gfxLineBuffer reset for downstream drawGroup-4 sprites).
- No member writes to `UFO_Plasma` exist in the function (verified by inspection); skipping the heavy path is safe state-wise as long as the trailing reset runs.

### Dependencies
Step 0 not strictly required (Item 6 ships unconditionally per locked decision).

### Out of scope
- Do NOT split the Plasma effect into a "compute" and a "render" phase. The change is one branch at the top.
- Do NOT cache the scanline-table results across frames. The deformation parameters change every frame as `timer` advances; caching wouldn't be correct.

### Failure mode + recovery
- **Compile error:** typo in the parity-gate wrapper. Trivial.
- **Color flicker on spheres/rings every other frame:** the trailing `SetClipBounds` + `SetActivePalette` calls were left inside the parity block. Move them OUT of the block so they run unconditionally. This is the failure mode the review's P-1A flagged.
- **Visible flicker on UFO5 lightning itself:** the half-rate IS visible at slow camera motion. Acceptable. If unacceptable to the user (their subjective call), revert this commit only.
- **Performance regression** (impossible — we're skipping work, not adding any). If observed: I-cache thrash on the new branch; vanishingly unlikely.

---

## Step 2 — Item 5: Fat-scanline 3DFloor and 3DRoof

### Title
Halve the iteration count of `UFO_Setup_Scanline_3DFloor` and `_3DRoof` by writing each scanline pair from one computation

### Why it matters
After Item 2's reciprocal table eliminated the per-iter divide, each callback's body is roughly 5 multiplies + memory ops + band-tracking ≈ 30 cycles/iter on Cortex-A9. 240 iters × 2 callbacks × 30 cycles ≈ 14k cycles on the callbacks. Halving to 120 iters saves ~7k cycles ≈ 12 μs at 600 MHz. **Honest:** small. Modest budget recovery, but the change is unidirectional and non-risky for the BACKGROUND surfaces (Floor and Roof). Skip Playfield to preserve gameplay-surface visual quality.

The engine-side tile rasterization (`DrawLayerHScroll`, `Scene.cpp:1308-1459`) **still runs at full 240-line resolution** and reads scanline data per-line; we cannot save engine-side cost without modifying the submodule. So Item 5 only buys back the callback math; it does NOT halve the rasterizer's work. This is honestly stated in the magnitude table above.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` lines 263–353 — re-read both callbacks post-Items 1+2+4.
2. `dependencies/RSDKv5/RSDKv5/RSDK/Scene/Scene.cpp:1308-1459` — engine-side `DrawLayerHScroll` (read-only; already verified above).

### Files to create / modify
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/UFO/UFO_Setup.c` (only file touched)

### Change sketch
For both `UFO_Setup_Scanline_3DFloor` (current line 263) and `UFO_Setup_Scanline_3DRoof` (current line 304), the inner loop is:

```c
for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; ++i) {
    // ... compute h, deform, pos, bank, line ...
    // ... band-tracker SetActivePalette logic ...
    scanlines->position.x = ...;
    scanlines->position.y = ...;
    scanlines++;
}
```

Replace with a step-by-2 loop that writes both even and odd `scanlines[]` entries from the same computation. The reciprocal table at index `i + SCREEN_YCENTER` is used only at even `i` and the result is written to `scanlines[0]` and `scanlines[1]`:

```c
for (int32 i = -SCREEN_YCENTER; i < SCREEN_YCENTER; i += 2) {
    int32 h             = (int32)(((long long)NUM * ufo_setup_recip_table[i + SCREEN_YCENTER]) >> UFO_SETUP_RECIP_SHIFT);
    int32 deform_x      = -(cos * h) >> 8;          // 3DFloor & 3DRoof both use this sign convention
    int32 deform_y      = (sin * h) >> 8;

    int32 pos  = ((cosX * h) >> 8) - (sinX * ((i * h) >> 8) >> 8);
    int32 bank = CLAMP((abs(pos) >> SHIFT) - BIAS, 0, 7);   // 3DFloor: shift 15 / bias 8; 3DRoof: shift 14 / bias 0
    int32 line = i + SCREEN_YCENTER;

    if (bank != bandBank) {
        if (bandBank >= 0)
            RSDK.SetActivePalette(bandBank, bandStart, line);
        bandStart = line;
        bandBank  = bank;
    }

    int32 px = (sin * pos - ScreenInfo->center.x * deform_x) + POSITION_OFFSET_X;   // 3DFloor: camera->position.x;   3DRoof: camera->position.x >> 3
    int32 py = (cos * pos - ScreenInfo->center.x * deform_y) + POSITION_OFFSET_Y;

    // Write line `i + SCREEN_YCENTER` and line `i + SCREEN_YCENTER + 1` from the same computation.
    scanlines[0].deform.x   = deform_x;
    scanlines[0].deform.y   = deform_y;
    scanlines[0].position.x = px;
    scanlines[0].position.y = py;
    scanlines[1].deform.x   = deform_x;
    scanlines[1].deform.y   = deform_y;
    scanlines[1].position.x = px;
    scanlines[1].position.y = py;

    scanlines += 2;
}
```

Then the band-tracker flush:

```c
if (bandBank >= 0)
    RSDK.SetActivePalette(bandBank, bandStart, SCREEN_YSIZE);
```

stays unchanged.

**Per-callback differences (the implement agent must preserve):**
- **3DFloor** (`UFO_Setup_Scanline_3DFloor`): NUM is `camera->height + 0x1000000`; bank is `CLAMP((abs(pos) >> 15) - 8, 0, 7)`; SetClipBounds uses `camera->clipY + 24`; position offset is `camera->position.x` and `camera->position.y`.
- **3DRoof** (`UFO_Setup_Scanline_3DRoof`): NUM is the loop-hoisted local `int32 height = (camera->height >> 2) - 0x600000;`; bank is `CLAMP(abs(pos) >> 14, 0, 7)`; SetClipBounds uses `0` and `camera->clipY - 48`; position offset is `camera->position.x >> 3` and `camera->position.y >> 3`. The early-return `if (camera->clipY <= 48) return;` stays (post-Item-4 invariant).

**Subtlety: the band-tracker resolution.** Today the band check fires once per line. With the step-by-2 loop, it fires once per pair. That means a band boundary that would have hit at, say, line 137 (odd) will now snap to line 136 or 138 (the even line of its pair) — a 1-line shift in the band boundary. Acceptable visual degradation; this is the intended fat-scanline tradeoff.

**Subtlety: SCREEN_YSIZE is even (240).** The loop range `[-120, 120)` with step 2 produces 120 iterations writing 240 scanline entries — exactly correct. If `SCREEN_YSIZE` were odd we'd need a tail handler; since it's not, no special case.

### Success criteria
- File compiles in SDL2.
- `git diff --stat SonicMania/Objects/UFO/UFO_Setup.c` shows roughly `+50/-30` (loop bodies replaced).
- The two affected callbacks have:
  - Step-by-2 loop iterating `i = -SCREEN_YCENTER; i < SCREEN_YCENTER; i += 2`.
  - Reciprocal-table lookup at `i + SCREEN_YCENTER` (full table is fine; we just don't use the odd indices in this callback).
  - Single computation of `deform_x`, `deform_y`, `px`, `py` per pair.
  - Two writes to `scanlines[0]` and `scanlines[1]`, then `scanlines += 2`.
  - Band-tracker flush after the loop unchanged.
- `UFO_Setup_Scanline_Playfield` is **untouched**. `git diff` confirms it has no edits.
- The reciprocal table builder `UFO_Setup_BuildRecipTable` is **untouched** (still 240 entries; Playfield needs the full table, and the saving from a 120-entry table on cache rebuilds is negligible while the cost of varying table size between callbacks is high).

### Dependencies
Step 0 SHOULD have run; if `r` ms (raster) is < 5 ms, this step is unlikely to be perceptible — ship anyway, document expectations.

### Out of scope
- Do NOT touch `UFO_Setup_Scanline_Playfield`.
- Do NOT shrink the reciprocal table to 120 entries.
- Do NOT change the band-tracker semantics (still per-pair-of-lines is correct; not a refactor of the band representation).

### Failure mode + recovery
- **Visible "fat scanline" stripe pattern on Floor or Roof:** the texture sampler is reading stale per-line data because the scanline write was incomplete. First check: are we writing BOTH `scanlines[0]` AND `scanlines[1]` per iteration? Second check: did `scanlines += 2;` advance correctly (not `++scanlines`)?
- **Band boundaries jumping by 2 lines instead of 1 during slow camera motion:** that's the intended fat-scanline visual tradeoff. Acceptable.
- **Off-by-one off the bottom of screen:** if SCREEN_YSIZE was misread as odd, we'd write past the scanline buffer. Verify SCREEN_YSIZE = 240 (even).
- **Compile error in the consolidated assignment block:** maybe `deform_x`/`deform_y` aren't declared. Make them `int32` locals.

---

## Step 3 — SDL2 desktop build + visual A/B compare

### Title
Build the working tree (with both changes applied) on macOS, run a brief gameplay smoke, A/B compare against pre-change baseline if feasible

### Why it matters
The two changes are mechanical; SDL2 build is the local correctness loop. The A/B step is opportunistic — if the agent has no UFO5 reachable from a fresh boot, build-pass alone is the goal.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/build-p7-fix-sdl2/CMakeCache.txt` — re-confirm `PORT_MISTER:BOOL=OFF`.

### Files to create / modify
None.

### Procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
cmake --build build-p7-fix-sdl2 -- -j8
# Expect: clean build. Touched files: UFO_Plasma.c, UFO_Setup.c.
```

If runtime UFO5 is reachable: run, observe — Plasma stage should look subjectively similar with the lightning effect at half-rate, AND spheres/rings should retain correct palette colors every frame (not flicker). Floor/Roof bands should look essentially identical (1-line band-boundary shifts at most).

A/B (optional, if interactive):
```bash
git stash
cmake --build build-p7-fix-sdl2 -- -j8
# screenshot pre-change
git stash pop
cmake --build build-p7-fix-sdl2 -- -j8
# screenshot post-change
compare -metric AE /tmp/pre.png /tmp/post.png /tmp/diff.png
```

Expect: AE high on Plasma (because we're skipping a frame entirely; the lightning IS different). AE moderate on 3DFloor/Roof (1-line band shifts at boundaries). AE near zero on Playfield surface (untouched), HUD, sphere/ring palettes, and player sprite.

### Success criteria
- Build exits 0.
- Compile warnings: none new from the two edits.
- (Opportunistic) visual A/B is consistent with the magnitude expectations.
- (Opportunistic) sphere/ring colors do not flicker every other frame on UFO5 — that would indicate Item 6's trailing palette reset was incorrectly placed inside the parity-skip block.

### Dependencies
Steps 1 and 2 complete (working-tree changes applied).

### Out of scope
- Do NOT benchmark on desktop. Macs have hardware divide and faster memory; perf claims must come from MiSTer.

### Failure mode + recovery
- **Build break:** check the two files for typos.
- **Sphere/ring color flicker on UFO5:** Item 6's `SetClipBounds` + `SetActivePalette` ended up inside the parity gate. Move them OUT of the gate so they run unconditionally.
- **Visual A/B reveals unexpected regression on Playfield:** Playfield was supposed to be untouched. Inspect `git diff SonicMania/Objects/UFO/UFO_Setup.c` for unintended edits to `UFO_Setup_Scanline_Playfield`.

---

## Step 4 — Cross-build + deploy + on-device boot smoke

### Title
Cross-compile telemetry-flavor armhf with both changes, deploy to MiSTer, confirm clean boot

### Why it matters
This is the actual target hardware. The perf claim has no meaning until the binary runs there.

### Files to read first
1. `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — confirm canonical commands and post-`26a717ba` lowercase install path.

### Files to create / modify
None.

### Procedure
```bash
cd /Users/sb/Developer/sonic-mania-mister
bash tools/mister/build-game.sh --flavor telemetry
MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 \
    bash tools/mister/deploy-to-mister.sh

sshpass -p 1 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@192.168.1.188 \
    'timeout -s TERM 10 /media/fat/games/sonic-mania/scripts/run-mania.sh' \
    2>&1 | tee /tmp/mania-smoke-items56.log
# Expect: engine banner, Data.rsdk attempt, exits cleanly within 10s OR
# reaches title and gets SIGTERM'd. Either is PASS.
```

### Success criteria
- Cross-build exits 0; produces `build/mister-telemetry-package/bin/RSDKv5U` (armhf ELF).
- Deploy exits 0; on-device `ls /media/fat/games/sonic-mania/bin/` shows new mtime.
- 10s smoke: no `Illegal instruction`, no `Segmentation fault`. Banner + Data.rsdk attempt OR title-reach is PASS.

### Dependencies
Step 3 passed.

### Out of scope
- Do NOT run extended gameplay on hardware here — that's user-gated Step 6.
- Do NOT capture F12 telemetry yet. Stack effects are subtle; user runs that in Step 6.

### Failure mode + recovery
- **Cross-build fail with new warning-as-error:** check the two edits for portability — `(long long)` casts, no `1LL` literals (use `(long long)1`), `int32`/`uint32` types preferred over `int`/`unsigned int`. Mirror Item 2's wrap-up note about the C unity-build TU not seeing C++ namespace typedefs.
- **`Illegal instruction` on hardware:** unlikely (pure scalar/integer changes). Most likely culprit: a stray `(double)` or VFP-coercing expression. Re-examine.
- **Smoke hangs past 10s:** SDL_CreateRenderer issue, almost certainly unrelated. Stash the changes, redeploy stock binary, confirm hang is gone — if so, root-cause is one of the two edits.

---

## Step 5 — Two independent commits in plan order

### Title
Commit Item 6, then Item 5 — each as a standalone commit

### Why it matters
Two commits, plan order. `git revert HEAD` removes Item 5. `git revert HEAD~1..HEAD` removes both. Easy rollback maps to user feedback.

### Files to read first
None.

### Files to create / modify
None new — commits the existing working-tree changes.

### Procedure

**Commit 1 — Item 6 (Plasma half-rate):**
```bash
cd /Users/sb/Developer/sonic-mania-mister
git add SonicMania/Objects/UFO/UFO_Plasma.c
git commit -m "$(cat <<'EOF'
mister: half-rate UFO_Plasma_Draw heavy work (scanline setup + deformed blit)

UFO_Plasma_Draw is the heaviest single per-frame draw in UFO5: a
240-iteration scanline-table setup followed by DrawDeformedSprite
with INK_MASKED ink, a full 320x240 deformed blit (~76800 pixel
operations per frame). On the HPS Cortex-A9 at 600 MHz, estimate
~600us per frame on this single draw call.

Wrap the scanline-table setup and DrawDeformedSprite in a parity
gate (UFO_Setup->timer & 1); execute on parity-0 frames only.
Lightning effect drops from 60 Hz to 30 Hz visually; given the
per-frame deformation noise the effect already has, 30 Hz remains
visually acceptable.

The trailing SetClipBounds + SetActivePalette(0, 0, h) calls remain
unconditional. They are the only path that resets gfxLineBuffer[]
on UFO5 (UFO_Plasma_StageLoad nulls the drawGroup-3 prepare hook),
and downstream drawGroup-4 sphere/ring DrawSprite reads gfxLineBuffer
per line for palette bank selection. Skipping them on the parity-1
path would produce visible color flicker on every sphere and ring
every other frame.

Magnitude estimate: ~300us-500us saved per frame (averaged), ~2-3%
of a 60 fps budget. Treat as +/-50% given the architectural
sensitivity of the prediction. The two state-reset calls left
unconditional cost microseconds at most; magnitude is unchanged.

Item 6 from the wider UFO Special Stage perf investigation. Items
1, 2, 4, 7 already shipped (7541c0d2, 9678afb0, e6115147, 5735e614).
Item 5 (fat-scanline 3D Floor/Roof) follows as a separate commit;
rollback either item with git revert without affecting the other.
Item 3 (sphere/ring radius cull) was dropped during plan-fix:
the proposed threshold was in the wrong units versus the engine's
ACTIVE_RBOUNDS (squared-distance) cull and could never fire.
EOF
)"
```

**Commit 2 — Item 5 (fat-scanline 3DFloor + 3DRoof):**
```bash
git add SonicMania/Objects/UFO/UFO_Setup.c
git commit -m "$(cat <<'EOF'
mister: fat-scanline UFO_Setup_Scanline_3DFloor and _3DRoof

Halve the iteration count of both 3DFloor and 3DRoof scanline
callbacks by writing each pair of scanlines (lines i and i+1) from
one shared computation. The reciprocal table (Item 2) and tile-layer
rasterizer (engine-side, full-resolution per Scene.cpp:DrawLayerHScroll)
are unchanged.

Per-callback math drops from 240 iters to 120, saving ~3500 cycles
per callback per frame (~5800 ns at 600 MHz HPS) for ~7000 cycles
total across both callbacks. Engine-side rasterization runs at full
240-line resolution because the scanline-callback API contract is
per-line; this change only saves the callback math, not the
rasterizer.

UFO_Setup_Scanline_Playfield is intentionally NOT touched.
Playfield is the gameplay surface; the per-line band-tracking palette
logic is most visible there, and a 1-line band-boundary shift would
be more noticeable.

Magnitude estimate: ~10us-15us saved per frame, ~0.1% of a 60 fps
budget. Small. Worth shipping because unidirectional and low-risk
for background surfaces.

Item 5 from the wider UFO Special Stage perf investigation.
EOF
)"
```

Then verify:
```bash
git log --oneline -5
git status   # expect only pre-existing modified files
```

### Success criteria
- Two new commits on `mister`, in plan order: Item 6 → Item 5.
- Each commit touches the expected file(s) only (Item 6 → `UFO_Plasma.c`; Item 5 → `UFO_Setup.c`).
- `git revert HEAD` cleanly restores `UFO_Setup.c`; `git revert HEAD~1` cleanly restores `UFO_Plasma.c`.
- Commit messages match the in-house `mister:` prefix style and are honest about expected magnitude.

### Dependencies
Steps 1–4 complete.

### Out of scope
- Do NOT push.
- Do NOT amend.
- Do NOT touch the submodule.

### Failure mode + recovery
- **`git status` after commit shows extra modifications:** unstage them; commit only the planned files per item.
- **Pre-commit hook fails:** investigate root cause; do NOT skip the hook. Fix and create a NEW commit.

---

## Step 6 — User-gated gameplay test (NOT executed by `/implement`)

### Title
User drives UFO5 on hardware, captures F3/F6/F12, looks for visual regressions

### Why it matters
The plan's magnitude estimates are within ±50%; the user is the only one who can drive UFO5, see the visible result, and feel whether the frame budget improved.

### Procedure (user-side, after `/implement` completes)
1. SSH to MiSTer and tail the log: `ssh root@192.168.1.188 'tail -F /tmp/sonicmania.log'`.
2. Boot Sonic Mania from the `_Other/` menu.
3. Get to UFO5 (Plasma stage; heaviest case; same scenario as Step 0).
4. Press F3, then F6 — capture `60 u:X.X r:X.X p:X.X` for the same 10-second window as Step 0. Compare to pre-change baseline:
   - **`r` ms drops noticeably** (e.g., 11 ms → 8 ms): Items shipped as expected.
   - **`r` ms unchanged or up:** Plasma's cost is not where we thought it was, or microarchitectural effects (cache thrash, etc.) ate the saving. Flag for the wider investigation.
   - **`u` or `p` are still high:** the bottleneck is elsewhere; this plan was the wrong target. Document and pivot.
5. Press F12, dump jitter; record `phase_err` and `late(>500us)`.
6. Watch for color flicker on spheres/rings every other frame — that's the signature of Item 6's palette-reset getting incorrectly skipped (revert Item 6 if observed).
7. Look up at the roof texture; watch for "fat scanline" striping (Item 5 risk).
8. Stay in UFO5 for ~30 seconds with the lightning effect visible; assess subjective lightning visual feel (Item 6 risk).

### Success criteria (user's call)
- No visible texture regressions beyond the documented half-rate Plasma.
- No color flicker on spheres/rings (palette-reset bug indicator).
- F6 numbers consistent with magnitude estimates OR notably worse — either result is information.

### Dependencies
Steps 1–5 complete.

### Out of scope (for `/implement`)
- The agent does not run Step 6. Document for the user.

### Failure mode + recovery (for the user)
- **Color flicker on spheres/rings every other frame:** Item 6's palette-reset got skipped on the parity-1 path. Revert Item 6 (`git revert <Item 6 hash>`) and re-fix; redeploy.
- **Visible fat-scanline striping on Floor/Roof:** revert Item 5; redeploy.
- **Lightning effect feels broken:** revert Item 6; redeploy.
- **F6 numbers worse:** revert both (`git revert HEAD~1..HEAD`); redeploy. Document.

---

## Risk table

| Risk | Severity | Mitigation | Notes |
|---|---|---|---|
| **Item 6: 30 Hz lightning visually unacceptable** | medium | The lightning effect is per-frame deformation noise; humans don't have strong temporal acuity for fast-flashing patterns. User-gated Step 6 confirms. Revert is `git revert <Item 6 hash>`. | If unacceptable: revert this commit only; the deeper structural alternative (alternate-frame partial draw, blend) violates the locked decision and would need a new plan. |
| **Item 6: palette-reset skipped on parity-1 frame, sphere/ring colors flicker** | high | The change sketch and Step 1 success criteria both call out that the trailing `SetClipBounds` + `SetActivePalette` calls MUST be OUTSIDE the parity gate. Failure mode + recovery in Step 1 names the symptom. | If `/implement` puts the reset calls inside the gate, the failure is visible immediately on UFO5; revert and re-fix. |
| **Item 6: Plasma cost is NOT actually dominant** | medium | Step 0 measurement before the change tells us. If `r` (raster) ms is small, Item 6 won't help much; if `r` is large, Item 6 should bring it down by ~half-of-Plasma's-share. | Plan author's read of the engine code says Plasma is the dominant cost, but plan author has not measured. ±50% on the magnitude. |
| **Item 5: visible fat-scanline striping on 3DFloor/3DRoof** | medium | Floor and Roof are background surfaces; not the player's focal point. Most visible at high pitch (looking up/down) where bands are wider. User-gated Step 6 confirms. | If observed and unacceptable: revert this commit only. |
| **Item 5: band-boundary shift by 1 line** | low | Acceptable per locked decision. The fat-scanline tradeoff. | Will appear as a 1-line jitter at band-color transitions during slow camera pitch. |
| **Item 5: scanline buffer overrun on odd SCREEN_YSIZE** | low | SCREEN_YSIZE = 240 (even) per `RetroEngine.hpp:155`. Loop with step 2 from -120 to <120 produces exactly 120 iterations writing 240 entries — boundary safe. | Verified by inspection. |
| **Both items: instruction-cache thrash from new code paths** | low | The per-item changes are tiny; total new code is ~30 lines across 2 files. I-cache footprint impact is negligible. | If observed, hardware microarchitecture is the issue, not the code. |
| **Both items: assumed magnitudes way off** | high | Plan author's estimates are ±50%; the user is frustrated and shipping nothing-perceptible would be a bad outcome. The honest magnitude table makes this risk explicit and Step 0 is the gate. | The plan author cannot eliminate this risk; only honest disclosure mitigates it. |
| **Item 6 + Item 5 interaction** | low | Both are pure "do less work" — they don't share state, don't interact. Fine in any order. | |
| **Items + Item 2 cache interaction** | low | Item 5 reads the Item-2 reciprocal table at every other index; the table itself is unchanged. No correctness interaction. | |

---

## Rollback story

Two independent commits in plan order. To roll back:
- **Item 5 only:** `git revert HEAD` (most recent).
- **Both (back to current `mister` HEAD `9678afb0`):** `git revert HEAD~1..HEAD`.

Each `revert` is mechanical and clean — no shared helpers, no shared state.

If the user wants to preserve Item 5 but revert Item 6: `git revert HEAD~1` removes Item 6 only. They're independent because the changes touch different files (Item 6 → `UFO_Plasma.c`; Item 5 → `UFO_Setup.c`). No conflict on revert.

---

## Build + deploy reminder

- **Cross-build:** `bash tools/mister/build-game.sh --flavor telemetry`
- **Deploy:** `MISTER_HOST=192.168.1.188 MISTER_PASSWORD=1 bash tools/mister/deploy-to-mister.sh`
  - Post-`26a717ba`: deploys to lowercase `/media/fat/games/sonic-mania/`. The CamelCase path is dead; do NOT manually `rsync` to it.
- **Boot smoke (10s):** see Step 4 procedure block.

---

## Wrap-up

Append any deferred issues, runtime-smoke notes, or unexpected findings to a section here named `## Plan execution notes — <date>` at the bottom. Do not modify earlier sections of this file.

---

## Plan-fix notes — 2026-04-25

Two P-1 fixes and one P-2 applied per `docs/ufo-special-stage-perf-items356-review.md`:

- **P-1A (Item 6 palette-reset bug):** the original change sketch said "skip the entire `UFO_Plasma_Draw` body every other frame." The reviewer found that the trailing `SetClipBounds` + `SetActivePalette(0, 0, h)` calls (`UFO_Plasma.c:36-37`) are the only path on UFO5 that resets `gfxLineBuffer[]` after Playfield's drawGroup-1 per-line palette bands (`UFO_Plasma_StageLoad` nulls the drawGroup-3 prepare hook at line 71). Skipping them would produce visible color flicker on sphere/ring sprites at drawGroup 4 every other frame. Plan was rewritten to wrap only the heavy work (scanline-table setup + `DrawDeformedSprite`) in the parity gate; the trailing two calls are now unconditional. Magnitude estimate is unchanged (the two reset calls cost microseconds at most).

- **P-1B (Item 3 dropped):** the original cull threshold `(dx >> 16) > 0x600` was justified as "1.5× updateRange." The reviewer found that the engine's `ACTIVE_RBOUNDS` cull (`Object.cpp:435-446`) compares **squared** distance against `updateRange.x = 0x400`, so the engine's effective pass radius is √1024 ≈ 32 in `>> 16` units. Any entity reaching `LateUpdate` is at most ~32 in those units; a threshold of `0x600 = 1536` could never fire. Reformulating as a single-row-of-matrix frustum cull (compute `zdepth` only, skip the other two rows when `zdepth < 0x100`) was considered but the underlying magnitude (~2–5 μs/frame) was already noise-floor and the user is frustrated by small-magnitude items. Item 3 dropped entirely; subsequent steps renumbered (4→3, 5→4, 6→5, 7→6) and commit count reduced from three to two. P-2A (UFO_Dust audit) and P-2B (ItemBox rationale) became moot.

- **P-2C (Step 0 SSH/log-tail command):** Step 0 procedure now includes the `sshpass`/`tail -F /tmp/sonicmania.log` command for retrieving F12 jitter dumps, plus the dump format reminder.

The plan now ships two commits: Item 6 (Plasma half-rate, body-only) and Item 5 (fat-scanline 3DFloor + 3DRoof). Item 3 is closed-out, not deferred — if a future "every cycle counts" pass is wanted, it should be planned standalone with a frustum-cull framing rather than the broken 2D radius cull.
