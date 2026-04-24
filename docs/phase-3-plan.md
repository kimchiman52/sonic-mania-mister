# Phase 3 — Audio + Input (Implementation Plan)

**Document date:** 2026-04-24
**Status:** Plan (pre-implementation). Each step below is a self-contained `/implement` unit.
**Track:** L (Linux-userland). Independent of Track F (FPGA) — no FPGA bits visible in this phase.
**Companion docs:** [mister-port-research.md](mister-port-research.md) §3.5, §2.11; [mister-port-plan.md](mister-port-plan.md) line 158 (Phase 3 section header); [phase-1-plan.md](phase-1-plan.md); [phase-0-plan.md](phase-0-plan.md); [phase-4-plan.md](phase-4-plan.md).

> **Sequencing note:** Phase 3 is independent of Phase 2 (audio/input do not depend on pixel output) and can land before Phase 2 if FPGA work is blocked. Steps 1–5 are pure source edits; only Step 7 requires on-hardware verification.

---

## Goal

Sound plays and gamepad/keyboard input reach the game on MiSTer HPS. Still no pixels visible on screen — that's Phase 4. Phase 3 is small: it wires up the SDL2 audio/input plumbing already present upstream and patches the ONE real gap — `MiSTerRenderDevice` currently logs-and-returns for `Init()`, `ProcessEvents()`, and never calls `AudioDevice::Init()` or `InitInputDevices()`. Without those calls no audio opens and no gamepads are recognized.

---

## Baked-in decisions (from `mister-port-plan.md`, not revisitable)

| # | Decision | Value |
|---|---|---|
| 1 | Internal resolution | 320×240 4:3 (set in Phase 2, already live) |
| 3 | Platform identity | `RETRO_LINUX` via `__linux__`; backend picked by `RSDK_USE_MISTER` |
| 5 | Cutscenes | `SetupVideoTexture_YUV*` remain no-op stubs; video audio stream still plays via stb_vorbis |
| 8 | Build flavor | `telemetry` during dev per `feedback-always-telemetry.md` |

**Phase 3-specific decisions (baked in by the master plan; do NOT revisit):**
- **Wrapper SHM input** (`/dev/shm/thirdsarm-joy` pattern from 3sx) is **deferred to Phase 7**. Phase 3 is SDL2-only: gamepad via `SDL_GameController*`, keyboard via `SDL_Event`.
- **`USE_SDL_AUDIO=ON`** is already the default inside `platforms/MiSTer.cmake:27` and forced ON by `build-game.sh`. Audio goes through `RSDK/Audio/SDL2/SDL2AudioDevice.cpp`, not MiniAudio.
- **Video decode is still stubbed** (decision #5). Theora playback is skipped at `MiSTerRenderDevice::SetupVideoTexture_YUV*`, but attract-mode music (pure `.ogg`) still plays through the normal audio stream — so title music IS expected to play even though video frames never appear.

---

## Verified facts from source (read before planning each step)

These are the load-bearing facts this plan depends on. All cited with file:line so reviewers can spot-check.

1. **Every upstream backend (DX9/DX11/SDL2/EGL/Vulkan) calls `AudioDevice::Init()` and `InitInputDevices()` from its own `RenderDevice::Init()`.** Grepped:
   - `SDL2RenderDevice.cpp:72-75` — `if (!SetupRendering() || !AudioDevice::Init()) return false; InitInputDevices();`
   - `DX9RenderDevice.cpp:114-117` — same pattern
   - `EGLRenderDevice.cpp:143-145` — same pattern
   - **`MiSTerRenderDevice.cpp:27-33` does NOT** — it only calls `SetupRendering()` and returns. **This is the main gap Phase 3 closes.**

2. **`AudioDevice::Init()` is defined by the SDL2 audio backend at `SDL2AudioDevice.cpp:7-33`.** It calls `SDL_InitSubSystem(SDL_INIT_AUDIO)`, opens an `SDL_AudioDeviceID` via `SDL_OpenAudioDevice`, registers `AudioCallback`, and calls `SDL_PauseAudioDevice(device, SDL_FALSE)` to start playback. The backend is textually `#include`d from `Audio.cpp:33-34` when `RETRO_AUDIODEVICE_SDL2` is `(1)`.

3. **`RETRO_AUDIODEVICE_SDL2 (1)` is already flipped for our build.** Confirmed at `RetroEngine.hpp:364-373`:
   ```cpp
   #elif defined(RSDK_USE_MISTER)
   #undef RETRO_RENDERDEVICE_MISTER
   #define RETRO_RENDERDEVICE_MISTER (1)
   #undef RETRO_INPUTDEVICE_SDL2
   #define RETRO_INPUTDEVICE_SDL2 (1)
   #undef RETRO_AUDIODEVICE_MINI
   #define RETRO_AUDIODEVICE_MINI (0)
   #undef RETRO_AUDIODEVICE_SDL2
   #define RETRO_AUDIODEVICE_SDL2 (1)
   ```
   No macro-level work needed.

4. **`InitInputDevices()` at `Input.cpp:94-134`** checks `RETRO_INPUTDEVICE_KEYBOARD`, `RETRO_INPUTDEVICE_SDL2`, etc. and calls their respective `Init<X>InputAPI()`. For us this fires `SKU::InitKeyboardInputAPI()` (always ON, `RetroEngine.hpp:191`) and `SKU::InitSDL2InputAPI()`. The latter calls `SDL_InitSubSystem(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | SDL_INIT_HAPTIC)` at `SDL2InputDevice.cpp:238`.

5. **`SDL_PollEvent` requires `SDL_INIT_EVENTS`.** SDL2's `SDL_INIT_VIDEO`, `SDL_INIT_JOYSTICK`, and `SDL_INIT_GAMECONTROLLER` each implicitly initialize the events subsystem when first called, so explicit `SDL_InitSubSystem(SDL_INIT_EVENTS)` is optional when any of those is also active. Our build initializes JOYSTICK+GAMECONTROLLER in `InitSDL2InputAPI` — that is sufficient for `SDL_PollEvent` to function. (This is a potential subtle-bug surface — covered in Step 3 "failure mode".)

6. **`ProcessEvent` / `ProcessEvents` in the SDL2 backend live at `SDL2RenderDevice.cpp:694-1049`.** That's 355 lines. The meat we need for Phase 3:
   - `SDL_CONTROLLERDEVICEADDED` / `_REMOVED` (lines 723-747) — open `SDL_GameController`, call `SKU::InitSDL2InputDevice(id, game_controller)`, match on id.
   - `SDL_KEYDOWN` / `_KEYUP` (lines 814-1031) — call `SKU::UpdateKeyState(event.key.keysym.scancode)` / `SKU::ClearKeyState(...)` under `#if RETRO_INPUTDEVICE_KEYBOARD`.
   - `SDL_QUIT` / `SDL_WINDOWEVENT_CLOSE` / `SDL_APP_TERMINATING` — set `isRunning = false`.
   - Devmenu hotkeys (F1-F12, Backspace, Insert, Pause) — bound to `engine.devMenu`. Kept as-is to avoid drift.
   - Fullscreen toggle via Alt+Enter (line 820) — references `UpdateGameWindow()` which calls back into `RenderDevice` to recreate the window. **MiSTer has no window**, so Alt+Enter must be gated off.
   - Window focus events (lines 698-721) — reference `SKU::userCore->focusState` under `#if RETRO_REV02`. MiSTer has no focus events (no window) but the symbol still exists; benign.

7. **`SKU::UpdateKeyState` / `ClearKeyState` in `KBInputDevice.cpp:808-820, 841-852` do key-code remapping gated on `RETRO_RENDERDEVICE_SDL2`, not `RETRO_INPUTDEVICE_SDL2`:**
   ```cpp
   #if RETRO_RENDERDEVICE_SDL2
       keyCode = SDLToWinAPIMappings(keyCode);
   #elif RETRO_INPUTDEVICE_GLFW
       keyCode = GLFWToWinAPIMappings(keyCode);
   #endif
   ```
   **For MiSTer, `RETRO_RENDERDEVICE_SDL2` is `(0)` and `RETRO_INPUTDEVICE_GLFW` is `(0)`, so no remap happens.** SDL scancodes flow straight through to `keyMap` comparisons. The engine's default key-bindings in `RSDK/Dev/UserDefaults.cpp` / config files are stored as Windows `VK_*` scancodes (returned by `SDLToWinAPIMappings`), so keypresses will NOT match bindings. **This IS a Phase 3 bug that must be fixed** — detailed in Step 4.

8. **Mania's title music is `.ogg`.** Confirmed at `SonicMania/Objects/Title/TitleSetup.c:371,376`:
   ```c
   RSDK.PlayStream("IntroTee.ogg", Music->channelID, 0, 0, false);
   RSDK.PlayStream("IntroHP.ogg",  Music->channelID, 0, 0, false);
   ```
   Plus `Music->trackNames[...]` used in-game. `PlayStream` → `Audio.cpp:291` assembles a `Data/Music/%s` path that stb_vorbis decodes on the CPU. **No MIDI. No WAV. No theora in the audio path.** `libogg`/`libtheora` appear only for cutscene decode (decision #5 stubbed). This means the audio smoke test depends on `Data.rsdk` (which ships the music streams) being in place.

9. **`MiSTer.cmake` already emits `RSDK_USE_MISTER=1`, `RETRO_MISTER=1`, `PORT_MISTER=1`.** At `platforms/MiSTer.cmake:138-153`. `RETRO_AUDIODEVICE_SDL2=1` is emitted there too (line 118). **No CMake changes needed for audio.**

10. **`ProcessEvents` is currently stubbed to `return isRunning;` at `MiSTerRenderDevice.cpp:146-150`.** It pumps nothing. Events sit in the SDL queue until queue-full backpressure drops them. No keyboard, no gamepad, no quit signal. **This is the second main gap.**

---

## Dependency graph

```
Step 1 (Init hook: wire AudioDevice::Init + InitInputDevices into MiSTerRenderDevice::Init)
  └─> Step 2 (Release symmetry: pair with AudioDevice::Release + ReleaseInputDevices in Release())
        └─> Step 3 (Port SDL2RenderDevice::ProcessEvents/ProcessEvent into MiSTer backend, minus window-specific bits)
              └─> Step 4 (Fix keyboard key-code remap so MiSTer uses SDLToWinAPIMappings)
                    └─> Step 5 (Audio diagnostic logging: confirm device opened, sample rate, format)
                          └─> Step 6 (Mac acceptance: Mac build with PORT_MISTER=ON still boots, audio opens, events flow)
                                └─> Step 7 (MiSTer smoke test: armhf binary on hardware; title music audible; SDL events logged)
```

Steps 1–5 are pure source edits in the `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/` subtree plus one small patch in `KBInputDevice.cpp`. Step 6 is a Mac-host build sanity check. Step 7 is the on-hardware exit criterion.

---

## Decision resolved: ProcessEvents strategy — **option (c), lift-and-shift**

The research brief asks for a decision between three options:
- (a) use SDL2 directly in our backend (we're already doing this in spirit)
- (b) delegate to an upstream shared helper (none exists)
- (c) lift-and-shift `SDL2RenderDevice::ProcessEvent[s]` into `MiSTerRenderDevice`

**We pick (c).** Justification:

- Upstream has no shared `ProcessEvent` helper; each backend rolls its own (`SDL2RenderDevice.cpp:694`, `GLFWRenderDevice.cpp` uses GLFW callbacks). Delegating via a function pointer would require an upstream refactor we'd have to carry forever.
- Calling SDL2RenderDevice::ProcessEvent[s] directly from our backend would require the SDL2 backend to be compiled too — but `#ifdef` dispatch at `Drawing.cpp:132-146` picks exactly ONE backend. Dual-compile would trigger duplicate-symbol link errors on `RenderDevice::Init`, etc.
- Lifting-and-shifting is the same pattern every other `RenderDevice` takes. It costs ~320 LOC of copied-and-adapted event handling (~355 LOC upstream minus the ~25 LOC we strip for window/Alt+Enter branches). No upstream patches needed beyond what Phase 1 already landed.

The copy is not verbatim:
- Strip window-specific branches (focus gain/loss, window close, Alt+Enter fullscreen toggle) — we have no `SDL_Window*`.
- Strip `UpdateGameWindow()` call — MiSTer has no window to update.
- Keep controller add/remove, keyboard up/down, devmenu hotkeys, quit, mouse/touch (harmless on HPS, `touchInfo` is a global).

Phase 7 revisit: if we add wrapper-SHM input, we'll pump it from `ProcessEvents` ahead of `SDL_PollEvent`. Layout already fits.

---

## Step 1 — Wire `AudioDevice::Init()` + `InitInputDevices()` into `MiSTerRenderDevice::Init()`

### Why it matters

Without this, `AudioDevice::Init()` never runs, `SDL_OpenAudioDevice` never fires, and no sound ever plays. Without `InitInputDevices()`, `SKU::InitKeyboardInputAPI()` never registers the keyboard devices and `SKU::InitSDL2InputAPI()` never calls `SDL_InitSubSystem(SDL_INIT_JOYSTICK|SDL_INIT_GAMECONTROLLER|SDL_INIT_HAPTIC)`. Both are prerequisites for ANY Phase 3 work to be observable.

This is the single highest-value edit in the phase: without it, none of the other steps produce visible results.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` lines 27-43 (the current stub).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp` lines 21-77 (reference pattern; note lines 72-75 are the key).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Audio/Audio.hpp` — signature of `AudioDevice::Init()`.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/Input.hpp` — signature of `InitInputDevices()`.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp` lines 7-33 (what `AudioDevice::Init()` actually does when the SDL2 backend is picked — the body is already correct, we just need to call it).
- `/Users/sb/Developer/sonic-mania-mister/docs/phase-3-plan.md` §"Verified facts from source" point 1 (the one-line delta from the upstream pattern).

### Files to modify

**Only `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`.**

Replace the body of `RenderDevice::Init()` (lines 27-33 currently) with:

```cpp
bool RenderDevice::Init()
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Init()");

    if (!SetupRendering())
        return false;

    // Phase 3: match upstream pattern (SDL2RenderDevice.cpp:72-75, DX9RenderDevice.cpp:114-117,
    // EGLRenderDevice.cpp:143-145). Every other backend initializes audio + input from
    // inside Init(); the parent RunRetroEngine() flow assumes they're up by the time
    // Init() returns.
    //
    // NOTE: the SDL2AudioDevice implementation of `AudioDevice::Init()`
    // (SDL2AudioDevice.cpp:7-33) ALWAYS returns true — on `SDL_OpenAudioDevice`
    // failure it only logs and sets `audioState=false` internally. Upstream's
    // `if (!AudioDevice::Init()) return false;` branch therefore never fires
    // with the SDL2 audio backend. We match `SDL2RenderDevice`'s call pattern
    // by discarding the return value explicitly; failure detection comes from
    // `SDL2AudioDevice`'s own `ERROR: Unable to open audio device!` log line,
    // not from the Init return value.
    (void)AudioDevice::Init();

    InitInputDevices();
    return true;
}
```

No other change in this step. Later steps add `Release` symmetry and flesh out `ProcessEvents`.

### Success criteria

- `grep -c "AudioDevice::Init()" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1 (new call).
- `grep -c "InitInputDevices()" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1.
- Mac build regression: `cmake -S . -B build-mister -DPORT_MISTER=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build-mister -j` succeeds. (On Mac, the SDL2 audio subsystem opens CoreAudio; on MiSTer it opens ALSA. Both are fine — we just need the function to link.)
- Non-MiSTer build regression: `cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON && cmake --build build-sdl -j` still succeeds (we did NOT touch SDL2RenderDevice).
- Runtime smoke (Mac): launch `./build-mister/dependencies/RSDKv5/RSDKv5U`. The RSDK log at `~/Library/Application Support/RSDKv5/log.txt` now contains the Phase 1 stubs AND does NOT print `ERROR: Unable to open audio device!` (that error is what SDL2AudioDevice prints on open failure at `SDL2AudioDevice.cpp:28-29`). Do NOT look for `w: 0 h: 0` — that log line comes from `SDL2RenderDevice.cpp:70` (window dimensions) and our backend has no SDL window, so it will never be emitted.

### Dependencies

Phase 1 (backend skeleton). No changes to RetroEngine.hpp, Drawing.hpp, MiSTer.cmake.

### What NOT to do

- Do NOT add `#include <SDL.h>` or any other header. `AudioDevice::Init()` and `InitInputDevices()` are already visible because this file is textually `#include`d by `Drawing.cpp` after `Audio.hpp` / `Input.hpp` have been pulled in through `RetroEngine.hpp`.
- Do NOT move `AudioDevice::Init()` before `SetupRendering()`. Upstream pattern is render setup first, audio second — preserves ordering for any future feature gating that depends on display state.
- Do NOT call `ReleaseInputDevices()` or `AudioDevice::Release()` here — those are Step 2 (paired with `Release()`).
- Do NOT try to check `contextInitialized` or re-open the audio device. SDL2AudioDevice handles idempotency.

### Failure mode & recovery

- **Compile error `AudioDevice` undefined:** Either `Audio.hpp` is not pulled in when `Drawing.cpp` compiles MiSTerRenderDevice.cpp, or namespace scoping is off. SDL2RenderDevice.cpp uses the bare name `AudioDevice::Init()`; so must we. If that fails, prepend `RSDK::` or trace through `RetroEngine.hpp`'s include chain to see why `Audio.hpp` wasn't pulled in.
- **Link error `undefined reference to AudioDevice::Init`:** SDL2 audio backend not being compiled. Verify `RETRO_AUDIODEVICE_SDL2` is `(1)` at compile time for a MiSTer build: `cmake --build build-mister --target RetroEngine --verbose 2>&1 | grep -o 'RETRO_AUDIODEVICE_SDL2=[01]'`. Expect `=1`. If `=0`, check `platforms/MiSTer.cmake:117-119` and `RetroEngine.hpp:364-373`.
- **Runtime `ERROR: Unable to open audio device!`:** audio device open failed. On Mac that usually means CoreAudio is busy; harmless for Phase 3 (we're not testing audio on Mac, just that the code path runs). On MiSTer, check ALSA: `aplay -l` via SSH. If ALSA reports no devices, MiSTer's ALSA config is the issue, not our code. Note: this error is the ONLY observable signal of audio open failure — `AudioDevice::Init()` itself returns true even on failure (see code comment above and `SDL2AudioDevice.cpp:28-33`), so we cannot gate recovery on its return value.

---

## Step 2 — Keep `Release()` as a log-only stub (do NOT call `AudioDevice::Release` / `ReleaseInputDevices` from it)

### Why it matters

**Correction from plan-review:** an earlier draft of this step proposed calling `AudioDevice::Release()` and `ReleaseInputDevices()` from inside `RenderDevice::Release`. That was WRONG. Verified against source:

- `RetroEngine.cpp:326-328` (the engine main-loop shutdown block) already calls the following, in this exact order:
  ```cpp
  ReleaseInputDevices();
  AudioDevice::Release();
  RenderDevice::Release(false);
  ```
- **No upstream backend** (SDL2/DX9/DX11/EGL/Vulkan) calls `AudioDevice::Release` or `ReleaseInputDevices` from its `Release()`. Confirmed by grep of all backend `Release` bodies.
- If we added them to MiSTerRenderDevice::Release, they'd run twice — `ReleaseInputDevices` is not documented as idempotent (it `delete`s input device objects), and double-release would be at best a leak and at worst a double-free / use-after-free crash at engine exit.

**Conclusion: leave the existing Phase 1 stub body alone.** The only change this step makes is a one-line comment update to document WHY we don't mirror the Init pattern here.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp` lines 324-340 — confirm engine-level shutdown sequence.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp` lines 305-337 (`RenderDevice::Release` — note it does NOT call `AudioDevice::Release` or `ReleaseInputDevices`).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/EGL/EGLRenderDevice.cpp` — spot-check same pattern.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/DX9/DX9RenderDevice.cpp` — spot-check same pattern.

### Files to modify

**Only `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`.** Comment-only change.

Replace the current `RenderDevice::Release` (lines 77-80) with:

```cpp
void RenderDevice::Release(bool32 isRefresh)
{
    PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::Release(isRefresh=%d)", (int)isRefresh);

    // Intentional: do NOT call AudioDevice::Release() or ReleaseInputDevices()
    // here. The engine main loop (RetroEngine.cpp:326-328) already calls them
    // in order *before* invoking RenderDevice::Release(false). No upstream
    // backend (SDL2/DX9/DX11/EGL/Vulkan) redoes that work from inside their
    // Release; adding it would cause double-release / double-free.
    //
    // Phase 2 will wire real DDR3 teardown here (munmap the native_video_writer
    // region, close /dev/mem fd, etc.). For Phase 3 there's nothing to clean.
    (void)isRefresh;
}
```

### Success criteria

- `grep -c "AudioDevice::Release" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns **0** (we must NOT add it).
- `grep -c "ReleaseInputDevices" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns **0** (we must NOT add it).
- `grep "MiSTerRenderDevice::Release(isRefresh=" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` still returns one hit (the log line).
- Mac build passes as in Step 1.
- 10-minute soak in Step 7 exits cleanly with no `double free` / `free(): invalid pointer` / `SIGABRT` on shutdown.

### Dependencies

Step 1 (audio + input are actually opened so Release semantics matter).

### What NOT to do

- **Do NOT call `AudioDevice::Release()` or `ReleaseInputDevices()` from here.** The engine calls them already.
- Do NOT call `SDL_Quit()`. Upstream doesn't, and `SDL2AudioDevice::Release` handles `SDL_QuitSubSystem(SDL_INIT_AUDIO)` on its own.
- Do NOT delete the `PrintLog` line or the `(void)isRefresh;` — the log line is the smoke-test hook for confirming clean exit.

### Failure mode & recovery

- **10-minute soak shutdown crashes with `double free` / `SIGABRT`:** means someone elsewhere is double-releasing. First suspect is our own edit; confirm `grep AudioDevice::Release dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns 0. If so, the bug is elsewhere (Phase 1/2 state) and out of scope for Phase 3.
- **Release log line never appears on clean exit:** means the engine isn't reaching the shutdown block because `RSDKv5U` was killed via `SIGKILL` (no opportunity to unwind). In Step 7 we use `SIGTERM` (`pkill -TERM`) to allow clean exit.

---

## Step 3 — Port `ProcessEvents` / `ProcessEvent` into the MiSTer backend

### Why it matters

`ProcessEvents` is the only call site that drains SDL's event queue. Without it, `SDL_CONTROLLERDEVICEADDED` never fires → controllers are never opened via `SDL_GameControllerOpen` → `InputDeviceSDL::UpdateInput()` has no devices to poll → no input reaches the game. Same for keyboard: `SKU::UpdateKeyState` is only ever called from `SDL_KEYDOWN` inside `ProcessEvent`.

Currently `MiSTerRenderDevice::ProcessEvents` returns `isRunning` without polling. The event queue fills up silently.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp` lines 694-1049 (full `ProcessEvent` + `ProcessEvents`). **This is the reference implementation; read end-to-end.**
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/SDL2/SDL2InputDevice.cpp` lines 236-240 (`SDL_InitSubSystem`) and the whole file ~100-320 (what `InitSDL2InputDevice` does with the `SDL_GameController*`).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp` lines 791-860 (`UpdateKeyState` / `ClearKeyState`) — understand the mapping-remap behavior for Step 4.

### Files to modify

**Only `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`** (all changes).
**Only `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp`** (add `ProcessEvent` declaration).

#### 3a. Add `ProcessEvent` declaration to the .hpp

After the `static bool ProcessEvents();` line at `.hpp:63`, add:
```cpp
    static void ProcessEvent(SDL_Event event);
```

Because the .hpp currently avoids SDL includes (deliberate design choice, see the header comment at lines 7-10), we need to pull the SDL2 header in NOW. Three options — pick option **(ii)**:

- **(i) Forward-declare `SDL_Event`:** wouldn't work — `SDL_Event` is a union typedef with no tag name. Forward declaration is not allowed for `typedef union {...} SDL_Event;`.
- **(ii) `#include <SDL2/SDL.h>` at the top of the .hpp:** simplest, matches what SDL2RenderDevice.hpp does (`#include <SDL2/SDL.h>` at line 2). Our "no SDL includes" comment is replaced with a new comment explaining that Phase 3 needs SDL types for event processing.
- **(iii) Hide `ProcessEvent` as a private helper defined only in the .cpp:** possible but ugly — the static-member convention means every other method lives in the .hpp.

Go with (ii). Update the `.hpp` top-of-file comment block to drop the "free of SDL types" claim, add `#include <SDL2/SDL.h>`, and add the `ProcessEvent(SDL_Event)` declaration.

> **Phase 1 header comment update (required):** `MiSTerRenderDevice.hpp:6-10` currently says "Deliberately free of SDL / GLFW / Vulkan types — this backend talks to a native video writer that mmaps the MiSTer HPS->FPGA framebuffer directly." That claim becomes stale the moment Step 3a lands (we pull `SDL_Event` in for the `ProcessEvent` signature). Replace that sentence with: "Includes `<SDL2/SDL.h>` for `SDL_Event` in `ProcessEvent`; no SDL types appear in the render-path interface (still talks to a native video writer that mmaps the MiSTer HPS->FPGA framebuffer directly)." This keeps the Phase 1 skeleton comment honest post-Phase-3.

#### 3b. Replace `ProcessEvents` body in the .cpp

Replace the current `MiSTerRenderDevice.cpp:146-150`:

```cpp
bool RenderDevice::ProcessEvents()
{
    // Phase 3 will pump SDL2 input events here.
    return isRunning;
}
```

With the upstream SDL2 pattern:

```cpp
bool RenderDevice::ProcessEvents()
{
    SDL_Event sdlEvent;
    while (SDL_PollEvent(&sdlEvent)) {
        ProcessEvent(sdlEvent);
        if (!isRunning)
            return false;
    }
    return isRunning;
}
```

#### 3c. Add `ProcessEvent` definition

Copy `SDL2RenderDevice.cpp:694-1035` into `MiSTerRenderDevice.cpp`, placed **above** the new `ProcessEvents` (for forward-use), with these MiSTer-specific deletions (cited against the current upstream `SDL2RenderDevice.cpp` so reviewers can spot-check each deletion):

1. **Deletion A — entire `SDL_WINDOWEVENT` case (`SDL2RenderDevice.cpp:697-721`):** delete the whole `case SDL_WINDOWEVENT:` block, including all its nested `event.window.event` sub-cases (`SDL_WINDOWEVENT_MAXIMIZED`, `SDL_WINDOWEVENT_CLOSE`, `SDL_WINDOWEVENT_FOCUS_GAINED`, `SDL_WINDOWEVENT_FOCUS_LOST`) and the `SDL_RestoreWindow`/`SDL_SetWindowFullscreen`/`SDL_ShowCursor` calls inside `SDL_WINDOWEVENT_MAXIMIZED`. MiSTer has no window. The only behavior-relevant sub-case (`SDL_WINDOWEVENT_CLOSE` → `isRunning = false`) is subsumed by the standalone `case SDL_QUIT:` at the bottom of the switch, which is what the X11/wayland window close actually maps to on Linux when there's no window. The `focusState` writes under `#if RETRO_REV02` (lines ~709-719) are also dropped; MiSTer has no focus events (no window) but no consumer depends on them being asserted.
2. **Deletion B — Alt+Enter fullscreen toggle inside `SDL_KEYDOWN → SDL_SCANCODE_RETURN` (`SDL2RenderDevice.cpp:819-825`):** delete the `if (event.key.keysym.mod & KMOD_LALT) { videoSettings.windowed ^= 1; UpdateGameWindow(); changedVideoSettings = false; break; }` block. The outer `case SDL_SCANCODE_RETURN:` label stays; control now falls straight through to the `default:` label's `SKU::UpdateKeyState(event.key.keysym.scancode);` call under `#if RETRO_INPUTDEVICE_KEYBOARD`. No window to toggle.
3. **Deletion B side-effects:** the `changedVideoSettings = false;` assignment removed by Deletion B is the one at `SDL2RenderDevice.cpp:823` (inside the Alt+Enter block). It is NOT related to the other `changedVideoSettings` writes elsewhere in the file. The `UpdateGameWindow();` call at `SDL2RenderDevice.cpp:822` is likewise removed by Deletion B. Neither symbol is referenced elsewhere in the MiSTer copy of `ProcessEvent`.
4. **Everything else stays** — `SDL_CONTROLLERDEVICEADDED`, `SDL_CONTROLLERDEVICEREMOVED`, `SDL_APP_*`, `SDL_MOUSEBUTTON*`, `SDL_FINGER*`, the rest of `SDL_KEYDOWN` (devmenu hotkeys, `SDL_SCANCODE_ESCAPE`, etc.), `SDL_KEYUP`, `SDL_QUIT`.

The resulting `ProcessEvent` body is roughly 320 LOC (we strip ~25 LOC from the original ~355 — the full `SDL_WINDOWEVENT` case plus the Alt+Enter block). Lift it as-is with those deletions; don't restructure.

#### 3d. Add telemetry log lines (gated on `ENABLE_PERF_TELEMETRY`)

For the smoke test in Step 7, we need to see SDL events as they arrive. Add ONE log line at the top of `ProcessEvent`:

```cpp
void RenderDevice::ProcessEvent(SDL_Event event)
{
// Note: platforms/MiSTer.cmake:152 emits `ENABLE_PERF_TELEMETRY=0` or `=1`
// (always defined), so `#if ENABLE_PERF_TELEMETRY` is the correct gate.
// `#ifdef ENABLE_PERF_TELEMETRY` would fire unconditionally for any MiSTer
// build because the macro is always *defined* — just to 0 in clean flavor.
#if ENABLE_PERF_TELEMETRY
    // Quiet by default in release; noisy in telemetry flavor for Phase 3 smoke.
    if (event.type == SDL_CONTROLLERDEVICEADDED || event.type == SDL_CONTROLLERDEVICEREMOVED
        || event.type == SDL_KEYDOWN || event.type == SDL_KEYUP || event.type == SDL_QUIT) {
        PrintLog(PRINT_NORMAL, "MiSTerRenderDevice::ProcessEvent(type=0x%x)", (unsigned)event.type);
    }
#endif
    switch (event.type) {
        // ... (lifted switch body)
    }
}
```

Per `feedback-debug-build-for-live-tests.md` and `feedback-always-telemetry.md`, telemetry flavor is the default during dev, so the log lines will be live. Release/clean flavor (ENABLE_PERF_TELEMETRY=0) compiles the gate body out.

### Success criteria

- `grep -c "SDL_PollEvent" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1.
- `grep -c "SDL_CONTROLLERDEVICEADDED" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1.
- `grep -c "SDL_KEYDOWN" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1.
- `grep -c "SDL_QUIT" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns ≥ 1.
- `grep -c "SDL_WINDOWEVENT" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns **0** (we deleted it).
- `grep -c "UpdateGameWindow" dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` returns **0**.
- Mac build still succeeds (Step 1 criterion).
- Non-MiSTer build still succeeds.

### Dependencies

Step 2 (Release symmetry). Step 3 is the biggest single diff of the phase.

### What NOT to do

- Do NOT delete the devmenu hotkeys (F1-F12, Backspace, Insert, Pause). They're engine-wide dev conveniences and cost nothing to keep. `engine.devMenu` is a runtime flag; they're no-ops unless dev menu is active.
- Do NOT delete `SDL_APP_WILLENTERFOREGROUND` / `SDL_APP_WILLENTERBACKGROUND` — they're references to `SKU::userCore->focusState` under `#if RETRO_REV02`. MiSTer won't fire them (Linux doesn't emit APP_* on desktop), but the code paths are benign.
- Do NOT replace the entire switch body with a minimal `SDL_QUIT || SDL_KEYDOWN` stub — the mouse/touch handling is used by Mania's title-screen "tap to continue" fallback and would silently break interactivity later.
- Do NOT add #include `<SDL.h>` twice (once in .hpp is enough).

### Failure mode & recovery

- **Compile error `SDL_Event incomplete type`:** the `#include <SDL2/SDL.h>` line is missing or placed after the class declaration. Move it to the top of the `.hpp`.
- **Link error `undefined reference to SDLToWinAPIMappings`:** that function lives in `KBInputDevice.cpp`, included via `Input.cpp` under `#if RETRO_INPUTDEVICE_KEYBOARD` (always `(1)` for us). If it's missing, `RETRO_INPUTDEVICE_KEYBOARD` has been un-set. Check `RetroEngine.hpp:191`.
- **Events not arriving at all (no log lines from telemetry):** `SDL_PollEvent` requires `SDL_INIT_EVENTS`. `SDL_InitSubSystem(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER | ...)` from `SDL2InputDevice.cpp:238` implicitly initializes EVENTS (SDL2 joystick init depends on events internally). Confirm `InitSDL2InputAPI` actually ran by checking the RSDK log for its startup path — if absent, `InitInputDevices` wasn't called from Step 1 (revisit Step 1). **Defensive fix if events are still dead:** add a top-of-`MiSTerRenderDevice::Init` call to `SDL_InitSubSystem(SDL_INIT_EVENTS)` BEFORE `AudioDevice::Init`. The SDL2 backend does this with `SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS)` at `SDL2RenderDevice.cpp:25`; we drop VIDEO since we have no window, but keeping EVENTS is safe and cheap.
- **Controller events arrive but keyboard events don't trigger key-binding checks:** that's Step 4.
- **Runtime `SDL_PollEvent` segfault:** SDL wasn't initialized. Confirm `AudioDevice::Init` ran first (it calls `SDL_InitSubSystem(SDL_INIT_AUDIO)` which also brings up the SDL main state if nothing else has). If the fault persists, add an explicit `SDL_Init(SDL_INIT_EVENTS)` at the very top of `MiSTerRenderDevice::Init`.

---

## Step 4 — Fix keyboard key-code remapping for MiSTer

### Why it matters

`KBInputDevice.cpp:808-852` gates `SDLToWinAPIMappings` remap on `#if RETRO_RENDERDEVICE_SDL2`. For MiSTer, that macro is `(0)`. So SDL scancodes bypass the remap, land in the engine as raw SDL values (`SDL_SCANCODE_UP == 82`), but the engine's default keybindings store Windows `VK_*` codes (`VK_UP == 0x26 == 38`). **Keypresses will not match bindings and keyboard input will appear to do nothing** even though the events reach the game.

This is a purely upstream bug in our context. Fix is one line plus an explanatory comment.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp` lines 808-860.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp` lines 245-570 (`SDLToWinAPIMappings` and `WinAPIToSDLMappings`) to confirm the mapping covers the scancodes we care about (arrows, `Z`/`X`/`C`/`A`/`S`/`D`, Enter, Backspace).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp` lines 364-373 (MiSTer flips).

### Files to modify

**Only `dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp`.**

Two identical edits — one in `UpdateKeyState` (lines ~810-814), one in `ClearKeyState` (lines ~843-847). Change:

```cpp
#if RETRO_RENDERDEVICE_SDL2
    keyCode = SDLToWinAPIMappings(keyCode);
#elif RETRO_INPUTDEVICE_GLFW
    keyCode = GLFWToWinAPIMappings(keyCode);
#endif
```

To:

```cpp
// PHASE-3(MiSTer): key events arrive as SDL scancodes regardless of which
// RenderDevice delivered them. The historical gate on RETRO_RENDERDEVICE_SDL2
// was wrong — it should have been RETRO_INPUTDEVICE_SDL2 (the SDL2 input
// device is what emits SDL scancodes; the renderer is incidental). For
// MiSTer (RETRO_RENDERDEVICE_MISTER=1, RETRO_INPUTDEVICE_SDL2=1, no GLFW), we
// widen the predicate to also accept RETRO_INPUTDEVICE_SDL2. This is safe
// for every other backend: all existing consumers of SDLToWinAPIMappings
// also have RETRO_INPUTDEVICE_SDL2=1 in parallel.
#if RETRO_RENDERDEVICE_SDL2 || RETRO_INPUTDEVICE_SDL2
    keyCode = SDLToWinAPIMappings(keyCode);
#elif RETRO_INPUTDEVICE_GLFW
    keyCode = GLFWToWinAPIMappings(keyCode);
#endif
```

### Success criteria

- `grep -c "RETRO_RENDERDEVICE_SDL2 || RETRO_INPUTDEVICE_SDL2" dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp` returns exactly **2**.
- Non-MiSTer build (`-DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2`) still succeeds and behaves identically — both macros are `(1)` for that build, so `SDLToWinAPIMappings` fires either way.
- Non-MiSTer Linux build (`-DPLATFORM=Linux -DRETRO_SUBSYSTEM=SDL2`) still succeeds and behaves identically.
- Non-MiSTer GLFW build (if testable): the `RETRO_INPUTDEVICE_GLFW` branch still fires because both `RETRO_RENDERDEVICE_SDL2` and `RETRO_INPUTDEVICE_SDL2` are `(0)` in that config.

### Dependencies

None within Phase 3 (this is an isolated fix that could technically land in any phase). Keep it in Step 4 so keyboard is demonstrably working alongside gamepad in Step 7.

### What NOT to do

- Do NOT swap the predicate to ONLY `RETRO_INPUTDEVICE_SDL2` — that would break the GLFW fallback via `elif`. Using `||` preserves the existing chain.
- Do NOT add a new `#elif RETRO_INPUTDEVICE_SDL2` branch — simpler to widen the existing OR.
- Do NOT add a similar fix to any other file. This is the only place that gates on the wrong macro.
- Do NOT attempt to "fix" the upstream misnaming — leave a `// PHASE-3(MiSTer):` comment so future rebase reviewers see why the predicate is compound.

### Failure mode & recovery

- **Keyboard still doesn't work in smoke test:** check whether the binding itself is the issue. Mania's default keybindings live in the engine's `RSDK/User/Core/` defaults path; they store `VK_*` codes. If the user has overridden bindings via config, they may have been re-stored as raw SDL scancodes (because `UpdateKeyState` was writing them into `buttons[k]->keyMap == -1 → keyCode` at line 835-836). If so, wipe `~/.local/share/Mania/` or the on-HPS user data dir and retry. On a fresh `Data.rsdk`, defaults should work.
- **Regression in Linux SDL2 build:** impossible in theory (both macros are `(1)` there), but if it happens, revert and investigate. We should see zero behavior change on any non-MiSTer build.

---

## Step 5 — Audio diagnostic logging

### Why it matters

SDL2AudioDevice on MiSTer opens ALSA via the SDL2 audio driver. We want to know at smoke-test time: (a) which device opened, (b) what sample rate it negotiated (requested 44.1 kHz; ALSA may or may not honor it), (c) what buffer size. This is a ~10-line instrumentation pass gated on telemetry flavor. Cheap insurance for Step 7.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp` full file (58 lines).
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Audio/Audio.hpp` — find `AUDIO_FREQUENCY`, `AUDIO_CHANNELS`, `MIX_BUFFER_SIZE` defines.

### Files to modify

**Only `dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp`.**

After the successful-open branch at line 23-26, add:

```cpp
    if ((device = SDL_OpenAudioDevice(nullptr, 0, &want, &deviceSpec, SDL_AUDIO_ALLOW_SAMPLES_CHANGE)) > 0) {
        SDL_PauseAudioDevice(device, SDL_FALSE);
        audioState = true;

// `ENABLE_PERF_TELEMETRY` is always defined (0 or 1) in the MiSTer build;
// must use `#if`, not `#ifdef`. For the Darwin/Linux SDL2 non-MiSTer build,
// the macro may be undefined — fall back to `defined() && value` form so
// the log line compiles out cleanly when telemetry isn't wired.
#if defined(ENABLE_PERF_TELEMETRY) && ENABLE_PERF_TELEMETRY
        PrintLog(PRINT_NORMAL,
                 "SDL2AudioDevice::Init: opened device=%u freq=%d channels=%d samples=%u format=0x%x driver=%s",
                 (unsigned)device, deviceSpec.freq, (int)deviceSpec.channels, (unsigned)deviceSpec.samples,
                 (unsigned)deviceSpec.format, SDL_GetCurrentAudioDriver());
#endif
    }
```

No other change.

### Success criteria

- `grep -c "SDL2AudioDevice::Init: opened device=" dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp` returns ≥ 1.
- Telemetry Mac build: log contains `SDL2AudioDevice::Init: opened device=... freq=44100 channels=2 samples=... format=0x... driver=coreaudio`.
- Clean (non-telemetry) build: log does NOT contain that line (the `#if defined(ENABLE_PERF_TELEMETRY) && ENABLE_PERF_TELEMETRY` gate held — note `#if`, not `#ifdef`, because the MiSTer build always *defines* the macro with value 0 or 1).
- No regressions on any other platform.

### Dependencies

Steps 1-4 land first (audio is actually opened + input + ProcessEvents flows).

### What NOT to do

- Do NOT add a second `PrintLog` for the error path — `SDL2AudioDevice.cpp:28-29` already logs the error. Would be redundant.
- Do NOT print on every `AudioCallback` invocation. That fires ~86 times per second; logging there would swamp everything else.
- Do NOT add this under a MiSTer-specific guard — the telemetry flavor already gates it. Keeping it platform-agnostic means Linux/Mac devs benefit too.
- Do NOT upstream this without a PR — it's ours for now, line it up for a submodule patch doc later.

### Failure mode & recovery

- **Log line absent on a telemetry build:** `ENABLE_PERF_TELEMETRY` isn't `1`. Check `platforms/MiSTer.cmake:152` (`ENABLE_PERF_TELEMETRY=$<BOOL:${ENABLE_PERF_TELEMETRY}>`) and the build-game.sh flavor switch. Evaluate with `cmake --build build-mister --target RetroEngine --verbose 2>&1 | grep -o 'ENABLE_PERF_TELEMETRY=\w*'`. Reminder: the cmake generator-expression `$<BOOL:…>` expands to the literal `0` or `1`, so the macro is ALWAYS defined for MiSTer builds. `#ifdef` would fire always; `#if` gates on the value, which is the correct pattern.
- **Log line absent on a `PLATFORM=Darwin RETRO_SUBSYSTEM=SDL2` (non-MiSTer) build:** expected — non-MiSTer `CMakeLists.txt` path doesn't define `ENABLE_PERF_TELEMETRY` at all. The `defined(ENABLE_PERF_TELEMETRY) && ENABLE_PERF_TELEMETRY` guard compiles out harmlessly.
- **`SDL_GetCurrentAudioDriver` returns NULL:** SDL wasn't initialized when we got here. Impossible in our ordering (`SDL_InitSubSystem(SDL_INIT_AUDIO)` is called at line 9 before we log), but defensively wrap `SDL_GetCurrentAudioDriver()` in a null-check if it occurs.

---

## Step 6 — Mac acceptance test (local regression gate)

### Why it matters

Before burning a Docker cross-compile cycle and an on-hardware test, validate that the patches don't break the Mac-host build. Both regression matrices must pass:
- `-DPORT_MISTER=ON`: still compiles + links, audio opens on CoreAudio, no events fired (no controller attached / no keyboard in headless bash is fine), clean exit on SIGTERM.
- `-DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2`: untouched behavior.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/docs/phase-1-plan.md` Step 6 — the Mac acceptance flow already established.
- This file (Phase 3) Steps 1-5.

### Files to create/modify

**None.** Invocation + verification only.

### Acceptance test procedure

**Pre-flight (idempotent):**
```bash
brew install sdl2 libogg theora pkg-config
```

**Build & regression (Mac host, parallel):**
```bash
cd /Users/sb/Developer/sonic-mania-mister

# 1. MiSTer-profile build on Mac host
rm -rf build-mister
cmake -S . -B build-mister -DPORT_MISTER=ON -DENABLE_PERF_TELEMETRY=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build-mister -j

# 2. SDL2 baseline on Mac host (regression check)
rm -rf build-sdl
cmake -S . -B build-sdl -DPLATFORM=Darwin -DRETRO_SUBSYSTEM=SDL2 -DGAME_STATIC=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build-sdl -j
```

Both must compile and link cleanly.

**Runtime smoke (MiSTer-profile, Mac):**
```bash
rm -f "$HOME/Library/Application Support/RSDKv5/log.txt"
./build-mister/dependencies/RSDKv5/RSDKv5U &
RSDK_PID=$!
sleep 10
kill $RSDK_PID 2>/dev/null || true
wait $RSDK_PID 2>/dev/null || true
```

**Expected log content (order may interleave):**
```
MiSTerRenderDevice::Init()
MiSTerRenderDevice::SetupRendering()
MiSTerRenderDevice::InitGraphicsAPI() [stub]
MiSTerRenderDevice::InitVertexBuffer() [stub]
MiSTerRenderDevice::GetDisplays() [stub]
SDL2AudioDevice::Init: opened device=N freq=44100 channels=2 samples=... format=0x... driver=coreaudio
MiSTerRenderDevice::InitFPSCap() [stub]
MiSTerRenderDevice::InitShaders() [stub: no shaders]
```

**Verification one-liner:**
```bash
LOG="$HOME/Library/Application Support/RSDKv5/log.txt"
grep -c "SDL2AudioDevice::Init: opened device=" "$LOG"        # expect >=1
grep -c "MiSTerRenderDevice::Init()" "$LOG"                   # expect >=1
grep -c "ERROR: Unable to open audio device" "$LOG"           # expect 0
```

### Success criteria

- Both builds compile with zero errors (warnings tolerated).
- MiSTer-flavored binary runs, logs `MiSTerRenderDevice::Init()` and `SDL2AudioDevice::Init: opened device=...`, and does NOT log `ERROR: Unable to open audio device`.
- No `SIGSEGV` before audio init.
- SDL2 baseline binary still boots to the usual SDL window + title screen (unchanged behavior).

### Dependencies

Steps 1-5 landed.

### What NOT to do

- Do NOT attempt to provide `Data.rsdk` — the Phase 1 pattern of "fail after Init" is retained. We're not gameplay-testing on Mac.
- Do NOT skip the SDL2 baseline check — Step 4's keyboard fix is the highest-risk regression surface; we must prove it didn't break anything.
- Do NOT run this inside Docker — Mac host only. On-hardware is Step 7.

### Failure mode & recovery

- **SDL2 baseline build broke:** Step 4 regression. Revert the `KBInputDevice.cpp` predicate to the original single-macro form, re-evaluate.
- **Mac audio init fails (CoreAudio busy):** run another instance of a running app (Music.app, browser tab playing audio) is likely the cause. Kill it and retry. Not a blocker for Phase 3 — the goal is to prove the code path compiles and exercises, not audit CoreAudio.
- **`log.txt` empty after Phase 3 edits but present after Phase 1:** some crash before the logs flush. Rebuild Debug, run under `lldb`, get backtrace. Most likely cause would be `SDL_InitSubSystem(SDL_INIT_AUDIO)` racing with Mac's audio unit registration; try adding `SDL_Init(SDL_INIT_EVENTS)` explicitly at the very top of `MiSTerRenderDevice::Init`.

---

## Step 7 — On-hardware smoke test (Phase 3 exit criterion)

### Why it matters

This is the exit gate. If this step succeeds, Phase 3 is done and Phase 4 (FPGA) can absorb attention.

### Files to read first

- `/Users/sb/Developer/sonic-mania-mister/tools/mister/build-game.sh` — canonical Docker cross-build driver (Phase 0 output).
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/deploy-to-mister.sh` — canonical SSH deploy.
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — deploy paths, `vga_scaler=0` for CRT, etc.
- `reference-mister-credentials.md` memory — MISTER_PASSWORD=1, host=192.168.1.188.

### Files to create/modify

**None.** Invocation + verification only.

### Acceptance test procedure

**Build armhf (telemetry flavor):**
```bash
cd /Users/sb/Developer/sonic-mania-mister
./tools/mister/build-game.sh --flavor telemetry
# Output: build/mister-telemetry-install/bin/RSDKv5U (ELF 32-bit LSB ARM)
file build/mister-telemetry-install/bin/RSDKv5U
# Expect: "ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), ..."
```

**Deploy + user must pre-stage `Data.rsdk`** on the MiSTer at `$MISTER_REMOTE_BASE/Data.rsdk`. Without Data.rsdk, the engine exits before music plays — we cannot validate audio. (Data.rsdk is user-supplied from their legally owned copy; 3sx has the same posture with CPS3 ROMs.)

```bash
export MISTER_HOST=192.168.1.188
export MISTER_PASSWORD=1
./tools/mister/deploy-to-mister.sh
```

**Run on MiSTer over SSH, capture log:**
```bash
sshpass -p "$MISTER_PASSWORD" ssh "root@$MISTER_HOST" \
    'cd /media/fat/games/SonicMania && rm -f log.txt && ./RSDKv5U &> session.log &
     sleep 15
     pkill -TERM RSDKv5U || true
     sleep 2
     cat session.log'
```

**Expected in session.log (order may interleave; critical lines bolded):**

1. `MiSTerRenderDevice::Init()`
2. `MiSTerRenderDevice::SetupRendering()`
3. `MiSTerRenderDevice::InitGraphicsAPI() [stub]`
4. `MiSTerRenderDevice::InitVertexBuffer() [stub]`
5. `MiSTerRenderDevice::GetDisplays() [stub]`
6. **`SDL2AudioDevice::Init: opened device=N freq=44100 channels=2 samples=... format=0x... driver=alsa`**
7. `MiSTerRenderDevice::InitFPSCap() [stub]`
8. `MiSTerRenderDevice::InitShaders() [stub: no shaders]`
9. (engine loads Data.rsdk, reaches title screen — no visible output yet since FPGA not wired)
10. (title music starts — **audible over HDMI/analog audio**)
11. User presses any key on USB keyboard: **`MiSTerRenderDevice::ProcessEvent(type=0x300)` (SDL_KEYDOWN)** then `ProcessEvent(type=0x301)` (SDL_KEYUP).
12. User plugs in USB gamepad mid-run: **`MiSTerRenderDevice::ProcessEvent(type=0x653)` (SDL_CONTROLLERDEVICEADDED)**. (Value derived from `SDL_events.h` — SDL_CONTROLLERAXISMOTION=0x650, DEVICEADDED is +3. SDL_CONTROLLERDEVICEREMOVED=0x654.)
13. User presses D-pad / A button: stream of `ProcessEvent(type=0x650)` (axis) and `type=0x651` (SDL_CONTROLLERBUTTONDOWN) events flowing each frame.

Live audible verification:
- SSH into MiSTer and play the binary while listening.
- Title music should sound intact (no clicks, drops, wrong pitch). If pitch is wrong, ALSA negotiated a different sample rate and SDL's resampler is thrashing — see failure mode.

### Success criteria (ALL must hold)

1. **Audio:** user hears Mania title-screen music over their MiSTer's HDMI (or 3.5 mm analog jack). No audio dropouts over a ~60-second listen.
2. **SDL audio init log line present:** `SDL2AudioDevice::Init: opened device=... driver=alsa` with freq=44100 (or within ALSA tolerance).
3. **Keyboard events arrive:** `ProcessEvent(type=0x300)` line appears in log when user presses a USB keyboard key.
4. **Gamepad events arrive:** `ProcessEvent(type=0x653)` (SDL_CONTROLLERDEVICEADDED) appears when user plugs/detects a USB gamepad.
5. **Controller button press registers:** after controller is detected, button presses trigger `InputDeviceSDL::UpdateInput()` each frame and keymasks update. (Observable indirectly: log line count for generic events grows over a 10-second hold.)
6. **Clean exit:** on SIGTERM, `MiSTerRenderDevice::Release(isRefresh=0)` logs and the process exits with status 0. No lingering `RSDKv5U` in `ps aux` afterwards.
7. **10-minute soak:** run for 10 minutes with audio playing; no crash, no log line containing `ERROR`, `assertion`, or `Segmentation fault`.
8. **No regression on Mac `-DPORT_MISTER=ON` build.**
9. **No regression on Mac `-DRETRO_SUBSYSTEM=SDL2` build.**

### Dependencies

Steps 1-6 all green.

### What NOT to do

- Do NOT use `rsync --delete` (memory `feedback-no-rsync-delete.md`).
- Do NOT deploy to a path outside `$MISTER_REMOTE_BASE` (default `/media/fat/games/SonicMania`).
- Do NOT attempt to validate pixel output — Phase 4 gates that.
- Do NOT rebuild with `--flavor clean` for this test (per `feedback-always-telemetry.md`, telemetry is dev default and ships the `ENABLE_PERF_TELEMETRY` log lines we depend on for diagnostics).

### Failure mode & recovery

- **No audio at all, `SDL2AudioDevice::Init: opened` line present:** ALSA opened but nothing in the pipe. Most likely cause: ALSA route. MiSTer's HDMI vs analog-out is driver-configurable; check `alsamixer` over SSH. If HDMI is muted, unmute. Per user's hardware preference (they have an analog CRT), confirm the MiSTer's default ALSA device is set to the one they have plugged in.
- **Audio plays but pitch/speed wrong:** SDL negotiated a different sample rate (48000 instead of 44100) and the engine's pre-resampling is off. Check `deviceSpec.freq` in the log. Quick fix: set `SDL_AUDIO_ALLOW_FREQUENCY_CHANGE` in `SDL_OpenAudioDevice` flags (bitwise OR with `SDL_AUDIO_ALLOW_SAMPLES_CHANGE`). That lets the engine see the real rate via `deviceSpec.freq` and adapt.
- **Keyboard events arrive but game doesn't respond to them:** Step 4 regression or the user's save has corrupted keybindings stored as raw SDL scancodes. Wipe `/media/fat/games/SonicMania/settings.ini` (or whatever the RSDKv5 config file is), restart. On MiSTer path, RSDK's `SKU::userFileDir` is likely `/media/fat/games/SonicMania/` itself.
- **Gamepad not detected (`SDL_CONTROLLERDEVICEADDED` never fires):** gamepad isn't SDL-GameController-compatible. Confirm via `SDL_JoystickName` at the deeper level — but for Phase 3, most modern USB pads are supported. If the pad is exotic (arcade stick, fight pad), add a GameController config mapping via `SDL_GameControllerAddMapping`. Punt to a follow-up if this is the user's only pad.
- **`SIGSEGV` during engine ticks:** most likely a palette / rendering code path hit by the CPU rasterizer with no valid `ScreenInfo.frameBuffer` target. Phase 2 should have provisioned that via NativeVideoWriter. If `ScreenInfo.frameBuffer` is null, Phase 2 regressed; fix there, not here.
- **10-minute soak crashes at N minutes:** likely a Phase 1/Phase 2 bug, not Phase 3. Capture `dmesg` + `session.log` and open a follow-up ticket against the more probable cause. Don't block Phase 3 if Phase 1/2 has a latent issue.

---

## Risk register (phase-level)

| Risk | Severity | Mitigation |
|---|---|---|
| ALSA's MiSTer config doesn't map cleanly to SDL2's expectations | Medium | Add `SDL_AUDIO_ALLOW_FREQUENCY_CHANGE`/`SDL_AUDIO_ALLOW_FORMAT_CHANGE` flags if Step 7 reveals pitch issues. |
| SDL2 2.0.14 on MiSTer (kernel 5.15) missing some `SDL_CONTROLLER*` enums | Low | SDL_CONTROLLERDEVICEADDED/REMOVED are stable since SDL2 2.0.4. We're on 2.0.14 per `reference-mister-network-stack.md`. Safe. |
| `SDLToWinAPIMappings` predicate change breaks Linux SDL2 build | Low | Both macros are `(1)` on Linux+SDL2, so the `||` is logically equivalent. Step 6 regression check catches it. |
| `AudioDevice::Init` hangs during SDL subsystem init on ALSA | Low | ALSA init is well-exercised in SDL2; common failure is "can't open device", which we'd see as the existing error log. Hangs would be a kernel driver issue, not our code. |
| Mac CoreAudio hangs during our added `PrintLog` between `SDL_PauseAudioDevice` and the log statement | Very low | `PrintLog` is a blocking stdio/file write; no SDL callback runs while the audio device is paused. Safe. |
| Telemetry log lines swamp the RSDK log file during a long soak | Low | Gated on the `ENABLE_PERF_TELEMETRY` flavor; `ProcessEvent` logs only at event arrival (not per-frame), typically a few dozen lines per minute of play. |
| Keyboard input test requires a USB keyboard plugged into MiSTer at run time | None | User already has one connected per `reference-mister-network-stack.md` context. If not: disconnect the USB keyboard requirement and rely only on gamepad as the input proof — gamepad + audio is still ≥75% of the phase goal. |

---

## Rollback plan

All of Phase 3's edits are contained in:
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{hpp,cpp}` — submodule, revert via `cd dependencies/RSDKv5 && git checkout -- RSDKv5/RSDK/Graphics/MiSTer/`.
- `dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp` — submodule, revert via `cd dependencies/RSDKv5 && git checkout -- RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp`.
- `dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp` — submodule, revert via `cd dependencies/RSDKv5 && git checkout -- RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp`.

Full rollback under 30 seconds with no external dependents.

---

## Notes carried forward for later phases

- **Phase 4:** Before the FPGA scans, expect gameplay audio to be "playing blind". User can launch, hear a menu track, navigate by ear + gamepad rumble (where applicable). This is a valid Phase 3-complete / Phase 4-pending state for non-visual QA.
- **Phase 7:** Wrapper SHM input (`/dev/shm/thirdsarm-joy`) was deferred. When Phase 7 lands it, the insertion point is `ProcessEvents` — read the SHM region BEFORE calling `SDL_PollEvent`, feed it into `InputDeviceSDL::UpdateInput` equivalents, then drain SDL events as usual. No architectural conflict with Step 3.
- **Cutscene audio revisit (decision #5):** if we later enable libtheora decode, the YUV frames still won't display (we need Step 4 of Phase 4 for that). But the audio stream from libtheora is already piped through the normal channel mixer — should "just work" even on a Phase 3-like state.
- **`SDLToWinAPIMappings` predicate:** the edit in Step 4 is mechanically upstream-submittable. If/when we decide to PR to RSDKModding, this is a 2-line patch.

---

## Open questions (flagged, not blocking)

These came from the research brief. Answered where we could; others are called out for Step 7 to resolve experimentally.

1. **Does Mania use MIDI, OGG, or WAV for title music?** **Answered: OGG Vorbis.** Confirmed at `SonicMania/Objects/Title/TitleSetup.c:371,376` — `RSDK.PlayStream("IntroTee.ogg", ...)`. Decoded by `stb_vorbis` (`Audio.cpp:12`). No MIDI sequencer, no WAV, no MP3. libogg/libtheora on the link line matter ONLY for cutscene decode (which is stubbed); for music-only audio, `stb_vorbis` is sufficient and is embedded — no extra deps.

2. **Does MiSTer's SDL2 2.0.14 ALSA driver default to HDMI or analog audio out? Is it selectable via config?** **Experimentally determined in Step 7.** ALSA routing is user-configured at the system level (`/etc/asound.conf` or `/media/fat/linux/config.txt`-style). SDL2 opens whatever ALSA's default PCM is. The user's MiSTer likely routes HDMI by default; if they want analog out (for CRT setup), they tweak the config or we add an `$SDL_AUDIODRIVER=alsa` + specific device override via config (Phase 7 polish, not blocker).

3. **Should our `MiSTerRenderDevice::ProcessEvents` be a direct copy of `SDL2RenderDevice::ProcessEvents`, or can we call into a shared helper?** **Answered: direct (lifted) copy with window-specific branches deleted (option (c) in the brief).** Rationale captured in "Decision resolved" section above. Shared helper would require upstream refactor we don't want to maintain.

4. **What does `videoSettings.pixWidth=320` imply for input event coordinate mapping?** **Only relevant for mouse/touch.** SDL2's `SDL_RenderSetLogicalSize(renderer, pixWidth, SCREEN_YSIZE)` normalizes mouse coords into logical space at `SDL2RenderDevice.cpp:512`. MiSTer has no SDL_Renderer, so our `touchInfo.x/y` from `SDL_FINGER*` events come through raw. Mania uses touch for the mobile/Switch UI and title/menu tap-to-continue — **not used on HPS in practice**. The `ProcessEvent` copy handles `SDL_FINGER*` benignly (writes to the `touchInfo` global that's never consumed). For Phase 3 we accept the minor inconsistency; Phase 7 polish can re-scale if needed.

---

## References

- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}` — current Phase 1 skeleton, target of our edits.
- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp:694-1049` — the `ProcessEvent`/`ProcessEvents` reference.
- `dependencies/RSDKv5/RSDKv5/RSDK/Audio/SDL2/SDL2AudioDevice.cpp` — `AudioDevice::Init/Release` definitions.
- `dependencies/RSDKv5/RSDKv5/RSDK/Input/Input.cpp:94-141` — `InitInputDevices`/`ReleaseInputDevices`.
- `dependencies/RSDKv5/RSDKv5/RSDK/Input/SDL2/SDL2InputDevice.cpp:236-240` — `InitSDL2InputAPI`.
- `dependencies/RSDKv5/RSDKv5/RSDK/Input/Keyboard/KBInputDevice.cpp:808-852` — the keyboard remap predicate to fix in Step 4.
- `dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp:364-373` — our Linux arm for `RSDK_USE_MISTER`.
- `docs/mister-port-research.md` §3.5 (input layer), §2.11 (resolution model).
- `docs/mister-port-plan.md` line 158 — Phase 3 section header (scope).
- `docs/phase-1-plan.md` — skeleton backend foundation.
- `docs/phase-4-plan.md` — what visible output unblocks once Phase 3+4 both land.
- `tools/mister/build-game.sh` / `tools/mister/deploy-to-mister.sh` — canonical build/deploy.
- Memory `feedback-always-telemetry.md`, `feedback-debug-build-for-live-tests.md`, `feedback-no-rsync-delete.md`, `feedback-read-runbooks-before-deploy.md`, `reference-mister-credentials.md`.
