# Mania Screen Height Investigation

## TL;DR

**Qualified yes**: overriding `SCREEN_YSIZE` to 224 at compile time will boot, render, and play. The engine is already platform-overridable by upstream design (the `#ifndef SCREEN_YSIZE` guard was added by RHCP-team member Mefiresu in PR #201, July 2023, exactly so platforms can pick a different height). Gameplay-affecting code paths almost universally use the *runtime* `ScreenInfo->size.y` / `currentScreen->size.y` and scale correctly. **However**: there is one concrete cosmetic regression — the `TitleCard` zone-intro animation hardcodes `TO_FIXED(240)` as the bottom Y of its colored strip vertices and curtains (32 occurrences in `Objects/Global/TitleCard.c`), which will leave a 16-pixel band of background visible at the bottom during zone-name animations. There is also no upstream precedent for shipping at any non-240 height — every public fork and port (Vita, 3DS, Switch, Wii U, Sonic Mania Plus Decomp) keeps `SCREEN_YSIZE = 240`.

## Evidence by sub-question

### 1. Engine architecture

**`SCREEN_YSIZE` is a compile-time default that upstream explicitly made overridable by platforms, but the runtime `videoSettings.pixHeight` API was never exposed for runtime height changes.**

- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp:154-158`:
  ```c
  #ifndef SCREEN_YSIZE
  #define SCREEN_YSIZE (240)
  #endif

  #define SCREEN_CENTERY (SCREEN_YSIZE / 2)
  ```
  The `#ifndef` guard exists.
- `SonicMania/GameLink.h:45-49` has the matching guard for the game-side header.
- Upstream commit `1d7e4a492cf3f4daff83af9ab75039b1469507aa` by **Mefiresu** (15 Jul 2023): "Wrap SCREEN_XMAX, SCREEN_YSIZE and SCREEN_COUNT in #ifndef" — commit message: *"Allows platforms to redefine them at compile time."* Merged via PR [RSDKModding/Sonic-Mania-Decompilation #201](https://github.com/RSDKModding/Sonic-Mania-Decompilation/pull/201) by `stxticOVFL`.
- `dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserCore.cpp:273`:
  ```c
  videoSettings.pixHeight = SCREEN_YSIZE;
  ```
  `pixHeight` is initialized from the compile-time macro and is never read from `Settings.ini` (compare: `pixWidth = iniparser_getint(ini, "Video:pixWidth", DEFAULT_PIXWIDTH)` at line 354 — pixWidth has an INI key, pixHeight does not).
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:133-158`: `enum VideoSettingsValues` exposes `VIDEOSETTING_WINDOW_HEIGHT` and `VIDEOSETTING_FSHEIGHT` via `RSDK.GetVideoSetting` / `RSDK.SetVideoSetting`, but **there is no `VIDEOSETTING_PIXHEIGHT`**. Game scripts cannot get/set the internal canvas height through the official API.
- Every render-device backend assigns `screens[s].size.y = videoSettings.pixHeight` at setup time (SDL2:486, DX9:612, DX11:722, GLFW:272, Vulkan:534, EGL:334). The engine is mechanically capable of any height the platform sets at boot. The MiSTer backend hardcodes `SCREEN_YSIZE` for its single screen (`MiSTerRenderDevice.cpp:196`: `SetScreenSize(0, videoSettings.pixWidth, SCREEN_YSIZE);`).
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:78`:
  ```c
  uint16 frameBuffer[SCREEN_XMAX * SCREEN_YSIZE];
  ```
  The framebuffer in `ScreenInfo` is **statically sized at compile time**. Same compile-time sizing in `SonicMania/GameLink.h:403`.
- Aspect-ratio dev menu (`Dev/Debug.cpp:1126-1145`) only changes **width** (`videoSettings.windowWidth`). It iterates 16:9 / 4:3 / 3:2 / 16:10 / 5:3 with `pixHeight` as the *constant denominator*: `width = 3 - (int32)(videoSettings.pixHeight * -1.3333334f)`. This is direct evidence of upstream intent — the user-facing knob varies width, height is fixed.

**Pattern**: `videoSettings.pixHeight` ↔ `currentScreen->size.y` / `ScreenInfo->size.y` are runtime-readable and used throughout for clipping, layer rendering, and HUD positioning. They are sourced from `SCREEN_YSIZE` at boot.

### 2. Game support

**Mania uses the runtime `ScreenInfo->size.y` for almost all genuine gameplay positioning, but compile-time `SCREEN_YSIZE` references exist in 17 non-dev gameplay files.** No upstream Mania port (Vita, 3DS, Wii U, Switch, Sonic Mania Plus Decomp, RhamaKiya, Leonx254 forks) ships at any height ≠ 240.

Gameplay-relevant `SCREEN_YSIZE` references (after filtering out `showGizmos()` debug-only sites):

- `SonicMania/Objects/LRZ/Drillerdroid.c:287`:
  ```c
  Zone->cameraBoundsT[0] = Zone->cameraBoundsB[0] - SCREEN_YSIZE;
  ```
  Sets boss-arena top camera bound. At 224, the arena is 16px shorter — internally consistent (player and camera both use the same value), so playable, but tighter than designed.
- `SonicMania/Objects/LRZ/DrillerdroidO.c:323, 703`: Same pattern, same effect.
- `SonicMania/Objects/AIZ/EncoreIntro.c:219, 220, 356, 357`: `Zone->cameraBoundsT[0] = Zone->cameraBoundsB[0] - SCREEN_YSIZE;` and same for `playerBoundsT`. Encore mode opening cinematic camera/player bound.
- `SonicMania/Objects/AIZ/AIZSetup.c:123`: `Zone->cameraBoundsB[0] = SCREEN_YSIZE;` — initial bottom bound set to the screen height literal.
- `SonicMania/Objects/LRZ/KingClaw.c:223, 225`: `self->position.y += SCREEN_YSIZE << 15;` — but inside `if (showGizmos())`, dev-only.
- `SonicMania/Objects/MSZ/UberCaterkiller.c:442`: `self->bodyPositions[i].y = (ScreenInfo->position.y + SCREEN_YSIZE) << 16;` — caterkiller body initial position. Internally consistent at 224.
- `SonicMania/Objects/Title/TitleBG.c:117, 140`: `RSDK.SetClipBounds(0, 0, 0, ScreenInfo->size.x, SCREEN_YSIZE / 2)` and `(0, 0, 168, ScreenInfo->size.x, SCREEN_YSIZE)`. At 224 the clip is 8px shorter — the decorative title-screen background is clipped from 168 to 224 instead of 168 to 240, so the bottom 16px of the BG won't render. Cosmetic.
- `SonicMania/Objects/Menu/LogoSetup.c:129, 134`: scrolls between logo splashes by `SCREEN_YSIZE`. Internally consistent.
- `SonicMania/Objects/Menu/UITransition.c:110`: `UIWidgets_DrawParallelogram(positions[i].x, positions[i].y, 0, SCREEN_YSIZE, SCREEN_YSIZE, ...)` — menu-transition diamond is drawn `SCREEN_YSIZE x SCREEN_YSIZE`. At 224 the diamond is smaller — visually slightly different.
- `SonicMania/Objects/FBZ/FBZSetup.c:160-190`: water/scanline effect iterates `for (int32 i = 0; i < SCREEN_YSIZE; ++i)` and `MIN(end, SCREEN_YSIZE)`. Self-consistent at 224.
- `SonicMania/Objects/Cutscene/CutsceneRules.c:102`: `size->y = SCREEN_YSIZE << 16;` — cutscene region size. Self-consistent.
- `SonicMania/Objects/OOZ/OOZ2Outro.c:62`: `self->size.y = SCREEN_YSIZE << 16;` — outro element. Self-consistent.
- `SonicMania/Objects/Global/SignPost.c:70`: `self->vsBoundsSize.y = TO_FIXED(SCREEN_YSIZE);` — competition mode signpost transition. Self-consistent.
- `SonicMania/Objects/Global/TitleCard.c:791`: `RSDK.SetClipBounds(SceneInfo->currentScreenID, 0, 170, screen->size.x, SCREEN_YSIZE);` — clip 170-to-bottom for title card. Self-consistent.
- `SonicMania/Objects/Menu/UIWinSize.c:108, 133`, `OptionsMenu.c:294, 596`, `MenuSetup.c:1981, 2076`: window-scale options. PC-only, irrelevant on MiSTer.
- `SonicMania/Objects/Global/Camera.c:467`: `DrawHelpers_DrawRectOutline(... TO_FIXED(SCREEN_YSIZE), 0xFF0000)` — dev menu only.

Boss arena outlines (`DERobot.c:1382`, `DDWrecker.c:939`, `KingClaw.c:224`, `HeavyRider.c:1320`, `Drillerdroid.c:1417`, `DrillerdroidO.c:1166`, `HeavyKing.c:1256`, `HeavyMystic.c:1744`, `AmoebaDroid.c:797`, `PhantomEgg.c:1238`, `ERZKing.c:516`, `CrimsonEye.c:1353`, `Shiversaw.c:1298`, `HeavyShinobi.c:1119`, `Gachapandora.c:1901`, `EggPistonsMKII.c:832`, `WeatherMobile.c:1028`, `EggJanken.c:1301`, `MSFactory.c:163`, `HotaruHiWatt.c:1281`, `GigaMetal.c:1233`, `MetalSonic.c:2177`, `SpiderMobile.c:1255`) all use `DrawHelpers_DrawArenaBounds(...)` *inside `if (showGizmos())`* — dev-mode-only, no shipping impact.

**No upstream port has ever modified `SCREEN_YSIZE`.** The Vita port (`SonicMastr/Sonic-Mania-Vita`) keeps 240 and only varies pixWidth (424 / 480 in its `Settings.ini`). The Wii U port (`Clownacy/Sonic-Mania-Decompilation-Wii-U`) keeps 240. The 3DS port keeps 240 ([GBAtemp release thread](https://gbatemp.net/threads/sonic-mania-3ds-port-released.617944/) explicitly notes the 3DS top screen is 400×240, conveniently matching). Sonic Mania Plus Decomp binaries on Internet Archive ship 424×240.

### 3. HUD/UI positioning

**The main gameplay HUD is correctly anchored to the runtime screen edges**; only the title card has hardcoded 240-Y vertices.

- `Objects/Global/HUD.c:433-440` — main HUD `Create`:
  ```c
  self->scorePos.y = TO_FIXED(12);
  self->timePos.y  = TO_FIXED(28);
  self->ringsPos.y = TO_FIXED(44);
  self->lifePos.y  = TO_FIXED(ScreenInfo->size.y - 12);
  ```
  Score/time/rings are top-anchored at fixed offsets from y=0, lives is bottom-anchored to `ScreenInfo->size.y - 12`. **Correct at any height.**
- `Objects/Global/HUD.c:366-406` — multiplayer-split letterbox borders all use `ScreenInfo->size.y` and `ScreenInfo[1].size.y`. Runtime, correct.
- `Objects/UFO/UFO_HUD.c:62`: `drawPos.y = 0x240000;` — that's `TO_FIXED(36)` (0x240000 = 36 << 16). UFO HUD is anchored at Y=36 (top), works at 224.
- `Objects/BSS/BSS_HUD.c:24-36`: anchored at Y=13 and Y=17. Top of screen, fine at 224.
- `Objects/Pinball/PBL_HUD.c:263, 267`: `RSDK.SetClipBounds(... ScreenInfo->size.y)` — runtime.
- Pause menu (`Objects/Global/PauseMenu.c:614-622, 804-823`): the visible `TO_FIXED(240)` and `TO_FIXED(232)` literals are **X-axis** offsets (`headerPos.x`, `yellowTrianglePos.x`); function signature `MathHelpers_Lerp2Sin1024(Vector2 *pos, int32 percent, int32 startX, int32 startY, int32 endX, int32 endY)` (`MathHelpers.c:73`) confirms positions 3 and 5 are X. **Not a Y-height issue.**

**The TitleCard regression (`Objects/Global/TitleCard.c:197-248, 457-474, 758`)**:

```c
self->stripVertsBlue[0].y   = TO_FIXED(240);  // …Blue[1..3].y all = 240
self->stripVertsRed[0].y    = TO_FIXED(240);  // …Red[1..3].y
self->stripVertsOrange[0].y = TO_FIXED(240);  // …Orange[1..3].y
self->stripVertsGreen[0].y  = TO_FIXED(240);  // …Green[1..3].y
self->bgLCurtainVerts[2].y  = TO_FIXED(240);
self->bgLCurtainVerts[3].y  = TO_FIXED(240);
self->bgRCurtainVerts[2].y  = TO_FIXED(240);
self->bgRCurtainVerts[3].y  = TO_FIXED(240);
```

These define the bottom Y of the four colored strips and the L/R bg curtains used during the zone-name slide-in/out animation. At 224, these vertices extend 16px below the screen — the strips are clipped at the bottom but the curtain region between y=224 and y=240 in *world* space is empty, so during the title card animation a 16px band of underlying scene/background may be visible at screen bottom. Lines 457-474 use `(self->vertMovePos[..] - TO_FIXED(240))` as a translation offset; line 758 uses `if (self->vertMovePos[1].x < TO_FIXED(240))` for animation timing. None of the latter affects geometry, just timing relative to a 240-unit traversal.

### 4. Upstream precedent

- **PR [RSDKModding/Sonic-Mania-Decompilation#201](https://github.com/RSDKModding/Sonic-Mania-Decompilation/pull/201)** (Mefiresu, merged July 15 2023): added `#ifndef` around `SCREEN_XMAX`, `SCREEN_YSIZE`, `SCREEN_COUNT`. Description: *"Allows platforms to redefine them at compile time."* No discussion thread visible, no breakage warnings. Accepted by `stxticOVFL`.
- **No issue or PR mentioning `pixHeight`** in either repository (verified search results: `is:pr pixHeight` and `is:issue pixHeight` on both `RSDKModding/Sonic-Mania-Decompilation` and `RSDKModding/RSDKv5-Decompilation` return zero results).
- **No issue mentioning a non-240 height**. The Sonic Mania issue #325 ("Replay Ghost missing Circle when off-screen display is active") is unrelated.
- **Community modding precedent is width-only**:
  - [PCGamingWiki Sonic Mania](https://www.pcgamingwiki.com/wiki/Sonic_Mania) and the [4:3 Aspect Ratio Mod](https://gamebanana.com/mods/31160), [Ultrawide mod](https://www.codenamegamma.com/mods/Ultrawide_/_Super_Ultrawide_Aspect_Ratio_Mods_-_Sonic_Mania_Plus/) all change `pixWidth` only. Settings.ini has `pixWidth` (engine-recognized, default 424) but **no `pixHeight`** key.
  - Steam community guides ([How to change to higher resolution](https://steamcommunity.com/sharedfiles/filedetails/?id=1123136089), [Hidden pixWidth setting](https://steamcommunity.com/app/584400/discussions/0/1696048426816108756/)): documentation of `winWidth`/`winHeight`/`fsWidth`/`fsHeight` (window-size scalars) and the hidden `pixWidth`. **`pixHeight` is never mentioned by any community resource.**
  - The [shmups.system11.org thread "Literally unplayable, Sonic Mania is upscaled from 424x240"](https://shmups.system11.org/viewtopic.php?f=6&t=60701) confirms the canonical internal resolution as 424×240.
- **Forks**:
  - [SonicMastr/Sonic-Mania-Vita](https://github.com/SonicMastr/Sonic-Mania-Vita): GameLink.h still defines `SCREEN_YSIZE (240)`. Settings.ini uses `pixWidth=424` or `480`.
  - [Clownacy/Sonic-Mania-Decompilation-Wii-U](https://github.com/Clownacy/Sonic-Mania-Decompilation-Wii-U): keeps default 240.
  - [thesupersonic16/RSDKv5u-Origins](https://github.com/thesupersonic16/RSDKv5u-Origins): RSDKv5 fork for Sonic Origins, no height override.
  - 3DS port (Rubberduckycooly/Chuli): native 240p screen, no height override needed.
- **No public Mania build at 224p exists** (extensive web search across GitHub, PCGamingWiki, GameBanana, Steam Community, Sega-16 Forums, NeoGAF, GBAtemp, Famiboards, RSDKModding wiki).

### 5. Concrete failure modes (compile-time SCREEN_YSIZE → 224)

**Cosmetic regressions (rendering, no crash, no logic break):**

- `SonicMania/Objects/Global/TitleCard.c:197-248` — 32 occurrences of `TO_FIXED(240)` as zone-card strip / curtain vertex Y. **Visible 16px gap at screen bottom during zone-name introduction animation.** This is the single highest-confidence concrete regression.
- `SonicMania/Objects/Global/TitleCard.c:457, 459, 462, 464, 467, 469, 472, 474` — `(self->vertMovePos[i].x - TO_FIXED(240))` used as a translation offset feeding into the strip animations. The 240 is the "design target" of the animation; the strips' Y is also 240, so visually the animation reaches the *intended position* off-screen at the bottom rather than the *visible bottom*. Reinforces the same regression above.
- `SonicMania/Objects/Title/TitleBG.c:117, 140` — title-screen background clip `SetClipBounds(0, 0, 0, x, SCREEN_YSIZE/2)` and `(0, 0, 168, x, SCREEN_YSIZE)`. At 224 the clip rectangle is 8/16px shorter — the title-screen BG bottom 16px would not render (replaced by whatever is below in the draw stack — likely the engine clear color).
- `SonicMania/Objects/Menu/UITransition.c:110` — menu transition diamond `SCREEN_YSIZE × SCREEN_YSIZE` becomes 224×224 instead of 240×240. Visually slightly smaller; menu still transitions correctly.

**Gameplay logic that becomes 16px tighter (internally consistent, no break):**

- `SonicMania/Objects/LRZ/Drillerdroid.c:287` — boss-arena top camera bound 16px lower (gameplay still consistent because boss object positions Y are also expressed relative to `cameraBoundsB[0]`, not to absolute world Y).
- `SonicMania/Objects/LRZ/DrillerdroidO.c:323, 703` — same pattern.
- `SonicMania/Objects/AIZ/EncoreIntro.c:219, 220, 356, 357` — Encore opening cinematic camera/player top bound.
- `SonicMania/Objects/AIZ/AIZSetup.c:123` — initial Zone->cameraBoundsB.
- `SonicMania/Objects/MSZ/UberCaterkiller.c:442` — caterkiller body initial Y.
- `SonicMania/Objects/Cutscene/CutsceneRules.c:102`, `OOZ/OOZ2Outro.c:62`, `Global/SignPost.c:70`, `Global/TitleCard.c:791` — internally consistent (use SCREEN_YSIZE for both the size *and* the boundary they compare against).
- `SonicMania/Objects/FBZ/FBZSetup.c:160, 161, 190` — scanline iterator for water effect now iterates 224 lines (vs 240). Top 224 lines covered correctly; below that is outside `currentScreen->size.y` anyway.

**No break:**

- All bosses' `DrawHelpers_DrawArenaBounds(...)` calls (≈25 sites) — gated on `showGizmos()`, dev menu only.
- HUD elements (`HUD.c`, `UFO_HUD.c`, `BSS_HUD.c`, `PBL_HUD.c`) — all anchored to runtime `ScreenInfo->size.y` or top-of-screen offsets.
- Camera (`Objects/Global/Camera.c`) — only line 467 references `SCREEN_YSIZE` and that's a `DrawRectOutline` debug call.
- Player (`Objects/Global/Player.c`), Zone (`Objects/Global/Zone.c`) — no `SCREEN_YSIZE` references at all; everything goes through runtime screen-info.
- Engine clipping (`Drawing.cpp:3627`, `Object.cpp:814-816`, `Scene.cpp:1088, 1152, 1198, 1451, 1469, 1582`) — all use `currentScreen->size.y` (runtime) and respect the new value.
- Framebuffer allocation (`Drawing.hpp:78`, `GameLink.h:403`) — sized at compile time as `SCREEN_XMAX * SCREEN_YSIZE`, so at 224 it's correctly sized to 1280×224 with no overrun.
- MiSTer render device (`MiSTerRenderDevice.cpp:93, 196, 340`) — uses `SCREEN_YSIZE` directly for `NativeVideoWriter_SetDims`, `SetScreenSize(0, pixWidth, SCREEN_YSIZE)`, and the `*height` accessor, so it tracks the override correctly.

**Pause menu literal `TO_FIXED(240)` is X-axis, not Y** (verified via `MathHelpers.c:73` Lerp2Sin1024 signature). Not a regression.

## What is intended

The `#ifndef SCREEN_YSIZE` guard added in PR #201 (July 2023) is direct evidence that **upstream maintainers intended platforms to be able to redefine `SCREEN_YSIZE` at compile time**. The author Mefiresu and reviewer stxticOVFL are members of the RSDKModding org. Every render backend pulls from `videoSettings.pixHeight = SCREEN_YSIZE`, so the engine internals propagate the new value uniformly. The framebuffer is statically sized from `SCREEN_YSIZE`, so a recompile is required (not a runtime change) and there is no risk of buffer overrun at any value `<= SCREEN_YSIZE_default`. Game scripts that access `ScreenInfo->size.y` (the overwhelming majority of gameplay/HUD/clipping code) automatically scale.

## What is NOT intended

**Variable height at runtime** is not supported. There is no `Video:pixHeight` ini key (compare `Video:pixWidth` at `UserCore.cpp:354`), no `VIDEOSETTING_PIXHEIGHT` enum value (`Drawing.hpp:133-158`), and the dev-menu aspect-ratio toggle (`Debug.cpp:1126-1145`) treats `pixHeight` as constant. Runtime aspect changes are width-only.

**Per-game-script height awareness in non-runtime paths** is not designed for. The 17-or-so `SCREEN_YSIZE` references in Mania's gameplay scripts (boss bounds, cutscene outros, FBZ scanline effect, etc.) treat `SCREEN_YSIZE` as a "screen height" that the *zone designer* chose, not as a runtime value. These will compile and execute, but the original level/cutscene geometry was *authored against 240*. At 224 the geometry is technically self-consistent but slightly tighter than the artist intended.

**The single hardcoded literal `TO_FIXED(240)` in `TitleCard.c` is a clear oversight** — it should have been `TO_FIXED(SCREEN_YSIZE)` to match the rest of the codebase. This was never fixed because no upstream consumer ever changed SCREEN_YSIZE. Filing an upstream PR to swap these literals to `TO_FIXED(SCREEN_YSIZE)` would be a clean fix.

## Recommendation

For the 3SX MiSTer port targeting CRT 240p output: **prefer FPGA-side approach over compile-time `SCREEN_YSIZE` override**, unless the goal is *specifically* to reduce active video lines for CRT underscan / NTSC overscan compensation.

**Three options, ranked:**

1. **Recommended — leave engine at 240, do FPGA-side cropping or modeline tightening.** This avoids: (a) the TitleCard cosmetic regression, (b) every "16px tighter than artist intended" boss/cutscene case, (c) drift from the upstream binary that all reference video / playthroughs / TASes target. The MiSTer scaler/RTL is the natural place to crop top/bottom lines, add letterboxing, or retune the modeline porches. This is what the existing Phase 9/10 work in `docs/phase-9-plan.md` already does (4:3 NTSC-exact retune, dual-aspect dispatch).

2. **Acceptable for 224p experiments — compile-time `SCREEN_YSIZE=224` with a one-line TitleCard patch.** Add `-DSCREEN_YSIZE=224` to the MiSTer cmake target. Patch `SonicMania/Objects/Global/TitleCard.c` lines 197-248 / 457-474 / 758 to use `TO_FIXED(SCREEN_YSIZE)` instead of `TO_FIXED(240)`. Ship it. The 16px-tighter boss/cutscene geometry is internally consistent and will not break gameplay; speedrunners will dislike the asymmetry from the canonical build, which is fine since this is a hardware port. *No upstream port has done this, so you'd be the first.*

3. **Not recommended — runtime override (`videoSettings.pixHeight = 224` after init).** The engine's framebuffer is statically sized from `SCREEN_YSIZE` (`Drawing.hpp:78`), so a runtime height different from the compile-time `SCREEN_YSIZE` causes either wasted memory (height < 240) or out-of-bounds writes (height > 240). Only "<240 at runtime" is safe, and it gets you nothing that compile-time override doesn't get you, while leaving every `SCREEN_YSIZE`-referencing game script using the wrong constant.

**If the goal is specifically "reduce active video lines on the CRT"**, FPGA-side modeline retune (option 1) is strictly better: it gives bit-identical pixels for HUD/gameplay/cutscenes (which are the things players notice) and lets the CRT see exactly the line count desired, with no risk to the title card or boss arenas.

**If the goal is genuinely "render at 224p internally"** (e.g. for a Genesis-aesthetic or a perfect 4:3 PAR at 320×224 SAR), use option 2 with the TitleCard patch. Plan to do a full playthrough and confirm there are no other authored-at-240 cosmetic regressions in cutscenes / outros / Encore intro / Drillerdroid / Phantom Egg final battle.
