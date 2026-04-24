# Phase 6 — Performance + frame pacing (plan)

Status: draft, reviewed once. Do NOT execute until Phase 5 (end-to-end smoke
test, `docs/mister-port-plan.md:230-240`) has confirmed gameplay is observable
on real hardware.

## Goal

Sustain **60 fps** on three representative stages — Green Hill Zone Act 1
(low complexity), Studiopolis Act 1 (heavy sprite count), Titanic Monarch
Act 1 (pseudo-3D segments) — measured on-canvas via an FPS overlay, with the
vsync feedback loop closed (`pacer_phase_error` oscillating near zero).

Secondary: produce honest performance numbers for future tuning. Per
`feedback-headless-perf-unreliable.md`, only the on-canvas overlay is
trustworthy. Per `feedback-debug-build-for-live-tests.md`, the telemetry
flavor must ship the overlay enabled by default during dev testing.

## Non-goals

- 30 fps fallback mode (deferred; only revisit if A9 @ 800 MHz cannot reach 60 fps after tuning)
- NEON hand-vectorization of the rasterizer (only if profiling identifies a single dominant hotspot)
- Cutscene support (Phase 7)
- Widescreen 424×240 alternate modeline (Phase 8)
- Mod-loader perf support

## Background — what exists, what is missing

**Already wired (Phase 2 / Phase 0):**

- `NativeVideoWriter_ReadFeedback()` / `NativeVideoWriter_ReadFeedbackSeq()` —
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.{h,c}`.
  On non-MiSTer builds, both return 0; on MiSTer, they read `DDR3[0x40]`
  (feedback word) and `DDR3[0x44]` (sequence number). The helpers
  `NV_FeedbackFrameCounter()` and `NV_FeedbackTimestampUs()` are inline in
  the header.
- `MiSTerRenderDevice::FlipScreen()` —
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:118-133`.
  Calls `NativeVideoWriter_WriteFrame(screens[0].frameBuffer, 320, 240, pitch_bytes)`.
- `RenderDevice::InitFPSCap()` / `CheckFPSCap()` / `UpdateFPSCap()` — stubs in
  `MiSTerRenderDevice.cpp:565-578`. `CheckFPSCap` returns `true` unconditionally
  (free-running); `InitFPSCap` and `UpdateFPSCap` are no-ops / log-only.
- `targetFreq` / `curTicks` / `prevTicks` static storage already defined in
  `MiSTerRenderDevice.cpp:23-25`.
- `ENABLE_PERF_TELEMETRY` compile define plumbed through
  `dependencies/RSDKv5/platforms/MiSTer.cmake:156-158` (`$<BOOL:...>` genexpr
  — always defined to `0` or `1`, use `#if`, not `#ifdef`).
- ARM hardening flags (`-mcpu=cortex-a9 -mfpu=neon-vfpv3 -mfloat-abi=hard`)
  auto-enable on armhf cross build —
  `dependencies/RSDKv5/platforms/MiSTer.cmake:165-210`. Matches 3sx byte for
  byte (`3sx-mister/CMakeLists.txt:20-34,169-193`).
- `DrawDevString(text, x, y, align, rgb32)` is RSDK's built-in 8×8 stencil
  font that writes into `currentScreen->frameBuffer` —
  `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:4395-4470` and
  header in `Drawing.hpp:410`. Clips to `currentScreen->size.{x,y}`.
- `videoSettings.refreshRate` defaults to 60 via `UserCore.cpp:502`, overridable
  via `settings.ini [Video]refreshRate=60`.

**Missing (this phase fills):**

- Vsync-feedback poll + closed-loop phase correction (logic exists in 3sx
  `src/port/sdl/sdl_app.c:9519-9579, 10657-10757` — must be ported into
  `MiSTerRenderDevice` because Mania's engine owns the main loop, not a
  standalone SDL app).
- Per-frame FPS accumulator + on-canvas overlay.
- Open-loop pacer fallback (timer-based) for when feedback is unavailable
  (Mac dev build, first few frames before FPGA writes seq, or after
  staleness disengagement).
- Profiling hooks for stage-by-stage validation.
- Optional ARM clock override (800 / 1000 / 1200 MHz) gated by config —
  only ship if 800 MHz cannot sustain 60 fps.

## Design decisions (locked in before implementation)

### D1 — Where the feedback poll fires

**Decision:** call `poll_vsync_feedback()` at the TOP of
`RenderDevice::UpdateFPSCap()`, before advancing `prevTicks`.

**Rationale:** RSDK's main loop (`RetroEngine.cpp:110-322`) is:

```
while (isRunning) {
    ProcessEvents();
    if (CheckFPSCap()) {
        UpdateFPSCap();       // <-- pacer hook: feedback read + phase correction
        ... game logic ...
        FlipScreen();         // writes to DDR3
    }
}
```

`CheckFPSCap()` is called on every iteration — often many times per frame at
first if the deadline hasn't arrived. Putting the feedback poll in
`UpdateFPSCap` ensures we read exactly once per rendered frame, **before**
the game-logic work for that frame kicks off. The phase error is then
available for the next `CheckFPSCap` gate. This matches 3sx's structure where
`poll_vsync_feedback()` fires once per iteration of the outer frame loop
immediately before the pacer sleep (`sdl_app.c:10657-10668`).

**Not in `FlipScreen`:** FlipScreen runs after all game logic; by then the
frame's deadline has already passed. Feedback used there could only correct
the *next* frame, identical to using `UpdateFPSCap`. Pick the earlier of the
two for symmetry with 3sx and because the phase value is needed for overlay
display on the same frame it's computed.

**Not in `ProcessEvents`:** ProcessEvents runs in a tight inner loop while
`CheckFPSCap` returns false. Polling feedback there would be wasted work —
the sequence number only advances on FPGA vsync (~16.7 ms cadence). Once per
frame is sufficient.

### D2 — Feedback word format (verified)

Per `NativeVideoWriter.h:55-68`:

```c
// Feedback format: bits[31:8] = ARM timestamp (us, bottom 24 bits),
//                  bits[7:0]  = FPGA 8-bit frame counter.
static inline uint8_t  NV_FeedbackFrameCounter(uint32_t fb) { return (uint8_t)(fb & 0xFF); }
static inline uint32_t NV_FeedbackTimestampUs(uint32_t fb) { return fb >> 8; }
```

The 24-bit timestamp is `CLOCK_MONOTONIC` microseconds (bottom 24 bits),
written by the wrapper process that runs on the HPS side of the FPGA. The
8-bit counter wraps every 256 frames (~4.3 s at 60 Hz).

The ARM side must compare against the same `CLOCK_MONOTONIC` epoch, NOT
`SDL_GetTicksNS()` which counts from SDL init. See 3sx
`sdl_app.c:9554-9556`:

```c
struct timespec mono_ts;
clock_gettime(CLOCK_MONOTONIC, &mono_ts);
uint32_t mono_us = (uint32_t)(mono_ts.tv_sec * 1000000ULL +
                              mono_ts.tv_nsec / 1000) & 0x00FFFFFF;
int32_t delta_us = (int32_t)((mono_us - ts_us) & 0x00FFFFFF);
if (delta_us > 0x00800000) delta_us -= 0x01000000;  // handle 24-bit wrap
```

The pacer's deadline scheduling uses `SDL_GetPerformanceCounter()` (RSDK's
choice — `SDL2RenderDevice.cpp:394,400`), so the conversion back to the
pacer's clock domain happens once, analogous to 3sx's `now_ns -
(Uint64)delta_us * 1000`.

### D3 — Torn-read detection

Triple-read seq bracket, per 3sx `sdl_app.c:9536-9540`:

```c
uint32_t seq1 = NativeVideoWriter_ReadFeedbackSeq();
uint32_t word = NativeVideoWriter_ReadFeedback();
uint32_t seq2 = NativeVideoWriter_ReadFeedbackSeq();
if (seq1 != seq2 || seq1 == 0) return;  // torn or uninitialized
if (seq1 == last_feedback_seq) return;   // no new data
```

No lock, no atomic — the FPGA writes feedback word first, then seq second;
ARM reads seq, word, seq. If both seq reads match, the word is consistent.
Same protocol as 3sx, identical constraint: the wrapper must write word
before seq.

**Caveat — wrapper dependency:** this assumes the HPS wrapper we fork from
3sx (Phase 4 deferred to Phase 7 per `mister-port-plan.md:266-276`) writes
the feedback word in the documented order. Verify once during Step 4
integration before claiming feedback-loop success.

### D4 — Phase correction gain

Adopt 3sx's gain: blend `frame_deadline` by `error / 4` per frame (25%
convergence per frame, asymptotically closes error over ~4 frames). Snap to
ideal when error exceeds one frame time. Source:
`sdl_app.c:10700-10706`.

**Lead time:** `2 ms` default (`lead_time_ns = 2_000_000` — 3sx
`sdl_app.c:152`). Exposes a CMake compile define `MISTER_PACER_LEAD_TIME_US`
so it's a knob without a recompile-settings-round-trip during live tuning.

### D5 — FPS overlay placement and content

**Placement:** top-left corner, 2 px in from left edge, 2 px from top —
`DrawDevString(text, 2, 2, ALIGN_LEFT, 0x00FF00)` (green RGB888). Avoids
Mania's own HUD which is top-centered (life icon) and top-right (rings/score).

**Two display modes**, selected by a runtime flag (`engine.showFPS`, new
global) — toggle with F3 when `engine.devMenu` is active (F3 is already
taken for shader cycling on SDL2 but MiSTer has no shaders — safe to
rebind). Default: off in release, **on in telemetry flavor** per
`feedback-always-telemetry.md`.

- **FPS mode** (`0`): single integer — `"60"`.
- **Detailed mode** (`1`, telemetry only): `"60 u:16.3 r:12.5 p:1.2 CL:e003 j042 L0%"`
  - `u` = update (game logic) ms, `r` = raster ms, `p` = present (writer) ms
  - `CL:eNNN` = closed-loop phase error in μs (signed, `OL:` prefix when feedback disengaged)
  - `jNNN` = avg jitter μs
  - `LNN%` = late-frame percentage (frames where jitter > 500 μs)

Mirrors 3sx `sdl_app.c:9152-9186`. Keep stripped-down in the `clean` flavor
(only integer FPS — the detailed string references telemetry-only state).

**Call site:** from `FlipScreen()`, after the dimension-check early-exit but
BEFORE `NativeVideoWriter_WriteFrame`. That way the overlay text appears on
every frame actually delivered to the FPGA, and there's no torn-frame risk
(writer memcpy happens AFTER overlay bake).

### D6 — Profiling hooks

Add `PerfScope` RAII-style timers (C++ in the render device, C for writer):
a no-op when `ENABLE_PERF_TELEMETRY=0`, actual `SDL_GetTicksNS()` deltas
when `1`. Three scopes minimum:

1. `PERF_UPDATE` — covers the ProcessObjects / game-logic span (`RetroEngine.cpp:~200-310`)
2. `PERF_RASTER` — covers the rendering pass (Drawing.cpp sprite/tile loops)
3. `PERF_PRESENT` — covers the `NativeVideoWriter_WriteFrame` call

Exact scope start/end sites are identified in Step 5.

### D7 — ARM clock override

**Default: do NOT apply any clock override.** Ship stock 800 MHz in
both flavors. Add a gated config option `MISTER_ARM_CLOCK_MODE` (0=stock,
1=1000, 2=1200 MHz) that the binary writes to sysfs only when explicitly
set via command line (`--arm-clock=1000`) or environment
(`MISTER_ARM_CLOCK_MHZ=1000`). Per
`3sx-mister/src/port/sdl/sdl_app.c:9582-9610`, the sysfs sequence is:

1. Write `performance` to `scaling_governor`
2. If raising: `scaling_max_freq` first, then `scaling_min_freq`
3. If lowering: `scaling_min_freq` first, then `scaling_max_freq`
4. Register an atexit() to restore 800 MHz

**Why gated off by default:** overclock shortens MiSTer board lifespan and
voids implicit warranty. Only enable if post-profile measurements show 800
MHz cannot sustain 60 fps on Studiopolis/Titanic Monarch. Document
prominently in `docs/mister-wrapper.md`.

### D8 — Feedback staleness disengagement

100 ms without seq advance ⇒ drop back to open-loop pacing and log once
(`"Frame pacer: vsync feedback stale, falling back to open-loop"`). Matches
3sx `sdl_app.c:10660-10667`. Re-engages automatically when seq resumes.

### D9 — Pacer precision

On MiSTer, port 3sx's `precise_delay_ns()` —
`sdl_app.c:9519-9531`: sleep until `target - busywait_threshold_ns`, then
busy-wait with `yield` on ARM. 3sx default: `busywait_threshold_ns = 200000`
(200 μs — verified `sdl_app.c:9483`). Adopt same.

**SDL version reality check:** Mania's engine uses **SDL2** (`MiSTer.cmake:112`
links `${SDL2_LIBRARIES}`; `SDL2RenderDevice.cpp:400` uses
`SDL_GetPerformanceCounter()`; `MiSTerRenderDevice.hpp:13` includes
`<SDL2/SDL.h>`). **SDL_GetTicksNS and SDL_DelayNS are SDL3-only APIs** —
they are unavailable in this code base. The pacer must use SDL2 equivalents:

- Time source: `SDL_GetPerformanceCounter()` + `SDL_GetPerformanceFrequency()`.
  Convert to ns via `perf * 1000000000ULL / freq` — compute once, cache freq.
- Sleep: on MiSTer, call POSIX `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL)`
  for the coarse sleep, then busy-wait. This is cleaner than `SDL_Delay(ms)`
  which rounds to millisecond granularity. On Mac/host (non-MiSTer), use
  `SDL_Delay((uint32)(remaining_ns / 1000000))`.

Provide helpers `PacerNowNs()` and `PacerSleepUntilNs(uint64_t)` in
`MiSTerPacer.{hpp,cpp}` so every call site uses the same clock domain.

### D10 — Realtime scheduling (defer)

3sx elevates to `SCHED_FIFO` and `mlockall()` —
`sdl_app.c:9500-9517`. **Defer to a Phase 6.5** unless measurements show
GNU scheduler jitter exceeding 1 ms peak. Realtime priority risks stalling
audio and USB-gadget input on MiSTer; don't take on until the simpler
pacer has been demonstrated.

## Files modified / created (summary)

| File | Change |
|---|---|
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp` | Add new static members for pacer state, overlay state, profile counters |
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` | Implement pacer in `InitFPSCap` / `CheckFPSCap` / `UpdateFPSCap`; overlay in `FlipScreen` |
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.hpp` (NEW) | Pacer helper header (private to render device TU) |
| `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.cpp` (NEW) | `poll_vsync_feedback`, `precise_delay_ns`, `apply_arm_clock`, profile scope impl |
| `dependencies/RSDKv5/platforms/MiSTer.cmake` | Add new sources to `RetroEngine`; define `MISTER_PACER_LEAD_TIME_US` (default 2000); verify hardening flag audit |
| `CMakeLists.txt` (top-level) | No change expected |
| `tools/mister/build-game.sh` | No change (already passes `ENABLE_PERF_TELEMETRY`) |
| `docs/mister-wrapper.md` | Append `--arm-clock` CLI flag + `MISTER_ARM_CLOCK_MHZ` env var documentation |

**Why a separate `MiSTerPacer.{hpp,cpp}` TU?** `MiSTerRenderDevice.cpp` is
`#include`d into `Drawing.cpp` (`Drawing.cpp:132-146`, `MiSTerRenderDevice.cpp:7-10`).
It is NOT a standalone TU. Free functions for pacer helpers must live in a
separate `.cpp` that compiles standalone, or they'd collide when
Drawing.cpp itself includes headers that forward-declare them differently.
The render-device `#include`d-style keeps its static method bodies; the
new TU owns the free functions.

## Verification strategy

- **Mac host builds:** verify `NativeVideoWriter_ReadFeedback` stubs to 0;
  pacer degrades gracefully to open-loop; `poll_vsync_feedback` returns
  early. No hardware required. Build command:
  `cmake -S . -B build/mac -DCMAKE_BUILD_TYPE=Release && cmake --build build/mac`.
- **armhf telemetry:** `tools/mister/build-game.sh --flavor telemetry`.
  Result binary at `build/mister-telemetry-install/bin/RSDKv5U`.
- **On-device profiling:** SSH to MiSTer
  (`reference-mister-credentials.md`, `MISTER_PASSWORD=1`,
  host `192.168.1.188`), deploy via
  `tools/mister/deploy-to-mister.sh`, launch from Main menu, observe
  overlay for at least 60 seconds per test stage.
- **Stage targets:** Green Hill Zone 1 (baseline), Studiopolis Act 1
  (sprite stress), Titanic Monarch Act 1 (pseudo-3D stress). Load
  directly via devMenu (F1/F2 + F5) rather than playing through.

## Exit criteria

1. Binary builds clean on host (Mac) and armhf (Docker) — `0 warnings new`
   compared to Phase 5 baseline.
2. On real hardware, FPS overlay reports **60 fps ±1** sustained for 60
   seconds on all three test stages.
3. Closed-loop phase error `|CL:e|` oscillates ≤ 500 μs (within a sub-
   frame slice); no more than 1% late frames (`LNN%` ≤ 1).
4. `vsync_feedback_valid` engages within 500 ms of startup (once the HPS
   wrapper begins writing seq) and stays engaged through the full 60-second
   window.
5. ARM clock stays at 800 MHz (no override applied, no overheating
   reports). If requirement 2 cannot be met at 800, file a follow-up to
   tune `-O3 -flto` / profile rasterizer / consider overclock.

---

## Step 1 — Wire the vsync-feedback poller into MiSTerRenderDevice

**Why it matters:** unlocks every downstream perf improvement. Without a
feedback loop, the pacer is open-loop timer-driven and will drift against
the FPGA's actual vsync, causing visible tearing even at the correct average
FPS. This step makes the feedback word usable; later steps consume it.

**Read first (exact files / spans):**

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h` — entire file (74 lines); confirms API.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:23-25, 565-578` — existing FPSCap stubs and static storage.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp:85-93` — private static declarations.
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:9519-9579` — reference `poll_vsync_feedback` + `precise_delay_ns` implementation. Copy verbatim; adapt state to C++ static members.
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:142-153` — pacer state declaration block.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake:130-138` — source list.

**Create / modify:**

1. New files:
   - `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.hpp`
   - `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.cpp`

   `MiSTerPacer.hpp` declares, in an anonymous-namespace-hostile way (public
   symbols used by both the render device and tests):

   ```cpp
   namespace RSDK::MiSTer::Pacer {
       struct FeedbackState {
           uint8_t   last_fpga_frame_cnt;
           uint32_t  last_feedback_seq;
           uint64_t  last_feedback_update_ns;  // SDL_GetTicksNS at last successful read
           uint64_t  last_vsync_monotonic_ns;  // SDL_GetTicksNS projection of last observed vsync
           bool      vsync_feedback_valid;
           bool      vsync_feedback_disabled;
           int64_t   pacer_phase_error_ns;     // for overlay
       };

       // Polls feedback once. Returns true if state advanced (new seq).
       bool PollFeedback(FeedbackState *fs);

       // Unified ns clock — SDL2-compatible wrapper around
       // SDL_GetPerformanceCounter() / SDL_GetPerformanceFrequency().
       uint64_t PacerNowNs();

       // Sleep until the absolute deadline in the PacerNowNs() domain.
       // On MiSTer: clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, ...)
       // coarse sleep, then busy-wait tail (200 μs threshold, yield).
       // On Mac/non-MiSTer: SDL_Delay((remaining + 999) / 1000) ms-granularity.
       void PacerSleepUntilNs(uint64_t target_ns);

       // 0=800, 1=1000, 2=1200. No-op on non-MiSTer. Idempotent.
       void ApplyArmClock(int mode);
       void RestoreArmClock();
   }
   ```

   `MiSTerPacer.cpp` guards the bodies with `#if defined(__linux__) && defined(PORT_MISTER)`
   (mirrors `NativeVideoWriter.c:3`). Stubs outside. `PollFeedback` is the verbatim
   3sx logic translated to take the state struct as parameter and return bool.

2. `MiSTerRenderDevice.hpp` — inside `class RenderDevice`, extend the
   private-static block (lines ~85-93) with:

   ```cpp
   private:
       static RSDK::MiSTer::Pacer::FeedbackState pacerFeedback;
       static uint64_t                           pacerFrameDeadlineNs;
       static uint64_t                           pacerTargetFrameTimeNs;
   ```

3. `MiSTerRenderDevice.cpp` — define the storage near the top (after line
   25), replace `InitFPSCap`, `CheckFPSCap`, `UpdateFPSCap` bodies:

   ```cpp
   RSDK::MiSTer::Pacer::FeedbackState RenderDevice::pacerFeedback = {};
   uint64_t RenderDevice::pacerFrameDeadlineNs   = 0;
   uint64_t RenderDevice::pacerTargetFrameTimeNs = 0;

   void RenderDevice::InitFPSCap()
   {
       // Default 60 Hz; videoSettings.refreshRate comes from settings.ini
       int32 rr = videoSettings.refreshRate > 0 ? videoSettings.refreshRate : 60;
       pacerTargetFrameTimeNs = (uint64_t)(1e9 / (double)rr);
       pacerFrameDeadlineNs   = 0;
       pacerFeedback          = {};
       PrintLog(PRINT_NORMAL,
           "MiSTerRenderDevice::InitFPSCap: target=%lluns (%.3f Hz)",
           (unsigned long long)pacerTargetFrameTimeNs, (double)rr);
   }

   bool RenderDevice::CheckFPSCap()
   {
       // MiSTer: no host-clock gate — we always proceed so the closed-loop
       // pacer in UpdateFPSCap owns the sleep. Rationale: returning false
       // here puts us in a spin loop around ProcessEvents, which wastes ARM
       // cycles that should have gone to game logic.
       return true;
   }

   void RenderDevice::UpdateFPSCap()
   {
       using namespace RSDK::MiSTer::Pacer;

       PollFeedback(&pacerFeedback);

       // Staleness disengagement (100 ms). SDL2 has no SDL_GetTicksNS —
       // use the PacerNowNs() helper (perf counter * 1e9 / perf freq).
       uint64_t now_ns = PacerNowNs();
       if (pacerFeedback.vsync_feedback_valid &&
           pacerFeedback.last_feedback_update_ns > 0 &&
           (now_ns - pacerFeedback.last_feedback_update_ns) > 100000000ULL) {
           pacerFeedback.vsync_feedback_valid = false;
           PrintLog(PRINT_NORMAL,
               "MiSTerRenderDevice: vsync feedback stale, falling back to open-loop");
       }

       if (pacerFrameDeadlineNs == 0) {
           pacerFrameDeadlineNs = now_ns + pacerTargetFrameTimeNs;
       }

       // Closed-loop phase correction (ported from 3sx sdl_app.c:10679-10710)
       uint64_t lead_ns = (uint64_t)MISTER_PACER_LEAD_TIME_US * 1000ULL;
       if (pacerFeedback.vsync_feedback_valid &&
           now_ns >= pacerFeedback.last_vsync_monotonic_ns) {
           uint64_t elapsed = now_ns - pacerFeedback.last_vsync_monotonic_ns;
           uint64_t frames_since = elapsed / pacerTargetFrameTimeNs;
           uint64_t next_vsync = pacerFeedback.last_vsync_monotonic_ns +
                                 (frames_since + 1) * pacerTargetFrameTimeNs;
           uint64_t ideal = (next_vsync > lead_ns) ? (next_vsync - lead_ns) : 0;
           if (ideal <= now_ns) ideal += pacerTargetFrameTimeNs;

           int64_t error = (int64_t)(ideal - pacerFrameDeadlineNs);
           pacerFeedback.pacer_phase_error_ns = error;
           if (error >  (int64_t)pacerTargetFrameTimeNs ||
               error < -(int64_t)pacerTargetFrameTimeNs) {
               pacerFrameDeadlineNs = ideal;   // snap
           } else {
               pacerFrameDeadlineNs += error / 4;  // 25% blend
           }
       } else {
           pacerFeedback.pacer_phase_error_ns = 0;
       }

       // Sleep until deadline
       if (now_ns < pacerFrameDeadlineNs) {
           PacerSleepUntilNs(pacerFrameDeadlineNs);  // dispatches to PreciseDelayNs on MiSTer
           now_ns = PacerNowNs();
       }

       // Advance deadline; guard against >1 frame behind
       pacerFrameDeadlineNs += pacerTargetFrameTimeNs;
       if (now_ns > pacerFrameDeadlineNs + pacerTargetFrameTimeNs)
           pacerFrameDeadlineNs = now_ns + pacerTargetFrameTimeNs;
   }
   ```

4. `dependencies/RSDKv5/platforms/MiSTer.cmake` — append new sources to the
   `target_sources(RetroEngine PRIVATE ...)` block at line 133, and add the
   compile define:

   ```cmake
   target_sources(RetroEngine PRIVATE
       RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.hpp
       RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.h
       RSDKv5/RSDK/Graphics/MiSTer/NativeVideoWriter.c
       RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.hpp
       RSDKv5/RSDK/Graphics/MiSTer/MiSTerPacer.cpp
   )

   set(MISTER_PACER_LEAD_TIME_US "2000" CACHE STRING "Lead time (μs) for closed-loop pacer")
   target_compile_definitions(RetroEngine PRIVATE
       MISTER_PACER_LEAD_TIME_US=${MISTER_PACER_LEAD_TIME_US}
   )
   ```

**Success criteria:**

- `cmake -S . -B build/mister -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mister.cmake -DPORT_MISTER=ON -DRETRO_SUBSYSTEM=SDL2` — configure succeeds.
- `cmake --build build/mister` — compiles, no new warnings.
- Mac build: `cmake --build build/mac` — still compiles (stubs active).
- Deploy telemetry build to MiSTer; launch from Main menu; log at
  `/tmp/sonicmania.log` shows `MiSTerRenderDevice::InitFPSCap: target=16666667ns (60.000 Hz)`.
- After ≥ 2 seconds of runtime, log contains `vsync feedback engaged` (new
  log line added inside `PollFeedback` on first successful update).

**Depends on:** Phase 5 smoke-test pass (gameplay observable). Phase 4 RBF
deployed. HPS wrapper writing feedback seq.

**Do NOT:**

- Touch `NativeVideoWriter.{h,c}`. The feedback reader API is finalized and
  Phase-2-shaped.
- Add realtime scheduling (`SCHED_FIFO`, `mlockall`). Deferred per D10.
- Merge the pacer logic into `MiSTerRenderDevice.cpp` as more `#include`d
  free functions — they must live in `MiSTerPacer.cpp` because the render
  device file is text-included by `Drawing.cpp`.

**If it fails:**

- `configure` error referring to `MiSTerPacer.cpp` not found → confirm file
  was added under `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/`,
  consistent with the existing `NativeVideoWriter.c` location.
- Compile error about `RSDK::` namespace → confirm `MiSTerPacer.cpp`
  `#include`s `<RetroEngine.hpp>` (or uses no RSDK types) and declares its
  functions in `namespace RSDK::MiSTer::Pacer { ... }`.
- Runtime: no "vsync feedback engaged" log within 5 seconds → wrapper is
  not writing seq. Run `devmem2 0x3A000044` on MiSTer to confirm seq is
  nonzero. If zero, the wrapper needs Phase 4-style integration; block this
  step and escalate.
- Runtime: "vsync feedback stale" repeating → wrapper writes seq
  exactly once then stops. Same wrapper bug; escalate.

---

## Step 2 — Port `precise_delay_ns` and verify pacer behavior with synthetic load

**Why it matters:** on-target sleep precision. `SDL_DelayNS` on Linux
usually falls back to `nanosleep` which granularity can be 1-4 ms depending
on the kernel tick. That's an ENTIRE frame of jitter. The busy-wait tail
clips it to the ARM's yield instruction cadence (~μs).

**Read first:**

- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:9519-9531` — exact reference.
- 3sx default is `busywait_threshold_ns = 200000` (200 μs — verified at line 9483; tunable via runtime flag in 3sx, adopt the default here). No runtime knob initially; recompile-time `MISTER_PACER_BUSYWAIT_US` CMake cache var mirrors `MISTER_PACER_LEAD_TIME_US` from Step 1 if we need adjustability during tuning.

**Create / modify:**

- `MiSTerPacer.cpp` — implement `PreciseDelayNs` exactly per 3sx reference,
  guarded by `#if defined(__linux__) && defined(PORT_MISTER)`. Non-MiSTer
  builds fall through to `SDL_DelayNS`.

**Success criteria:**

- Mac build still compiles (stub path).
- On MiSTer: instrument `UpdateFPSCap` with a ring buffer of 60 jitter
  samples (`now_ns - pacerFrameDeadlineNs` at end of sleep). Add a
  log-dump triggered by pressing F12 on keyboard that prints min/avg/max
  jitter over the last 60 frames.
- F12 dump shows `max_jitter ≤ 500 μs` over a 60-sample window with no
  gameplay (static title screen).

**Depends on:** Step 1.

**Do NOT:**

- Skip the busywait_threshold guard — falling back to pure busy-wait
  will pin CPU to 100% and starve audio. Kernel reports the core as
  `performance` governor but still throttles on thermal limit.

**If it fails:**

- `max_jitter` > 1 ms → kernel HZ is too low. Check `/proc/config.gz |
  grep CONFIG_HZ`. If 100 Hz, need `CONFIG_HZ_1000` — out of scope here;
  file a follow-up, document the 1 ms floor, move on.

---

## Step 3 — FPS overlay (on-canvas, via `DrawDevString`)

**Why it matters:** honest perf numbers per
`feedback-headless-perf-unreliable.md`. Without this, every number we report
is guesswork.

**Read first:**

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp:4395-4470` — `DrawDevString` body.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.hpp:410` — declaration.
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:118-133` — FlipScreen.
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:9140-9190` — reference overlay string format.

**Create / modify:**

1. `MiSTerRenderDevice.hpp` — add static state:

   ```cpp
   static bool      showFPSOverlay;
   static int32     fpsOverlayMode;    // 0=simple, 1=detailed (telemetry only)
   static uint64_t  fpsAccumNs;
   static uint32_t  fpsSampleCount;
   static int32     fpsLastValue;
   static char      fpsLabel[96];
   ```

2. `MiSTerRenderDevice.cpp` — before `FlipScreen`, add:

   ```cpp
   bool     RenderDevice::showFPSOverlay  = (ENABLE_PERF_TELEMETRY != 0);
   int32    RenderDevice::fpsOverlayMode  = 0;  // default simple
   uint64_t RenderDevice::fpsAccumNs      = 0;
   uint32_t RenderDevice::fpsSampleCount  = 0;
   int32    RenderDevice::fpsLastValue    = 0;
   char     RenderDevice::fpsLabel[96]    = "--";

   static void updateFPSOverlay(uint64_t frame_ns, const RSDK::MiSTer::Pacer::FeedbackState &fs)
   {
       RenderDevice::fpsAccumNs += frame_ns;
       RenderDevice::fpsSampleCount++;

       // Refresh once per second
       if (RenderDevice::fpsAccumNs >= 1000000000ULL) {
           double avg_ns = (double)RenderDevice::fpsAccumNs / (double)RenderDevice::fpsSampleCount;
           RenderDevice::fpsLastValue = (int32)(1e9 / avg_ns + 0.5);

   #if ENABLE_PERF_TELEMETRY
           if (RenderDevice::fpsOverlayMode == 1) {
               const char *prefix = fs.vsync_feedback_valid ? "CL" : "OL";
               int64_t phase_us = fs.pacer_phase_error_ns / 1000;
               SDL_snprintf(RenderDevice::fpsLabel, sizeof(RenderDevice::fpsLabel),
                   "%d %s:e%+05lld",
                   RenderDevice::fpsLastValue,
                   prefix,
                   (long long)phase_us);
           } else
   #endif
           {
               SDL_snprintf(RenderDevice::fpsLabel, sizeof(RenderDevice::fpsLabel),
                   "%d", RenderDevice::fpsLastValue);
           }
           RenderDevice::fpsAccumNs = 0;
           RenderDevice::fpsSampleCount = 0;
       }
   }
   ```

3. Modify `FlipScreen`:

   ```cpp
   void RenderDevice::FlipScreen()
   {
       if (screens[0].size.x != NV_FRAME_WIDTH || screens[0].size.y != NV_FRAME_HEIGHT)
           return;

       uint64_t now = RSDK::MiSTer::Pacer::PacerNowNs();
       static uint64_t prevFrameNs = 0;
       if (prevFrameNs != 0 && showFPSOverlay) {
           updateFPSOverlay(now - prevFrameNs, pacerFeedback);
       }
       prevFrameNs = now;

       if (showFPSOverlay) {
           // DrawDevString writes into currentScreen->frameBuffer;
           // currentScreen == &screens[0] during the main loop.
           DrawDevString(fpsLabel, 2, 2, ALIGN_LEFT, 0x00FF00);
       }

       NativeVideoWriter_WriteFrame(screens[0].frameBuffer,
                                    NV_FRAME_WIDTH, NV_FRAME_HEIGHT,
                                    screens[0].pitch * (int)sizeof(uint16));
   }
   ```

4. Hotkey toggle — in `ProcessEvent`'s `SDL_KEYDOWN` switch, add/rebind
   F3 (currently shader cycle — safe to rebind, MiSTer has no shaders
   per `MiSTerRenderDevice.cpp:580-592`):

   ```cpp
   case SDL_SCANCODE_F3:
       // MiSTer: F3 in upstream cycles user shaders. `InitShaders` sets
       // `videoSettings.shaderSupport = false` here (MiSTerRenderDevice.cpp:580-585)
       // and `userShaderCount` stays 0, so the existing F3 branch
       // (lines 428-431) is a no-op. Replace the branch wholesale rather
       // than layering an extra conditional.
       showFPSOverlay = !showFPSOverlay;
       PrintLog(PRINT_NORMAL, "FPS overlay: %s", showFPSOverlay ? "on" : "off");
       break;

   case SDL_SCANCODE_F4:
       // MiSTer: cycle overlay mode. In clean flavor, only mode 0 is
       // visually different (mode 1 strings reference telemetry state).
       fpsOverlayMode = (fpsOverlayMode + 1) % 2;
       break;
   ```

   F4 currently toggles `engine.showEntityInfo` in the upstream scancode
   handler at `MiSTerRenderDevice.cpp:434-437` (devMenu-gated). Preserve
   that. Use `SDL_SCANCODE_F6` for overlay-mode cycle — upstream path at
   `MiSTerRenderDevice.cpp:460-463` fires only when `engine.devMenu &&
   videoSettings.screenCount > 1`. Mania runs with `screenCount == 1` so
   F6 is effectively unused; rebind wholesale.

   ```cpp
   case SDL_SCANCODE_F6:
       fpsOverlayMode = (fpsOverlayMode + 1) % 2;
       PrintLog(PRINT_NORMAL, "FPS overlay mode: %d", fpsOverlayMode);
       break;
   ```

**Success criteria:**

- Mac host build: FPS text visible in the overlay (SDL software renderer
  on host, if that path works; otherwise verify by stubbing
  `showFPSOverlay = true` and checking no crash).
- MiSTer armhf telemetry: FPS text visible top-left on all test stages.
  Rings counter at top-right is NOT obscured.
- After 5 seconds on title screen, overlay reads `60`.
- F3 toggles visibility; F6 switches between `60` and `60 CL:e...`.

**Depends on:** Step 1. (Step 2 is independent — can run in parallel.)

**Do NOT:**

- Add a background rectangle behind the text (would require
  `DrawRectangle`, which is entity-scoped and not safe to call from
  the render device). If readability is poor on bright backgrounds, use
  a darker green or add a 1-px black drop-shadow by calling
  `DrawDevString` twice at offset (+1,+1) black then (0,0) green.
- Write to the FPGA buffer DIRECTLY to paint the overlay. Go through the
  `DrawDevString` → frameBuffer → `WriteFrame` path so the overlay obeys
  Mania's RGB565 pixel format and clipping.

**If it fails:**

- Overlay text not visible on MiSTer: confirm `currentScreen == &screens[0]`
  at the time `FlipScreen` runs (add `PrintLog`). If not, store the
  screen pointer earlier.
- Text visible but garbled: `SDL_snprintf` with `%lld` on armhf clang
  may emit wrong format specifier warnings — confirm `-Wformat` does not
  flag; if it does, cast explicitly.

---

## Step 4 — Integration test: validate closed-loop engagement on real hardware

**Why it matters:** this is the first on-device confirmation that the
vsync-feedback protocol works end-to-end. Everything after this point
assumes the loop can close.

**Read first:**

- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — deployment steps.
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/deploy-to-mister.sh` — scp target paths.
- `reference-mister-credentials.md` — SSH host/user/password.

**Create / modify:** NONE. This is a runtime-only step.

**Success criteria:**

- Build: `tools/mister/build-game.sh --flavor telemetry`.
- Deploy: `tools/mister/deploy-to-mister.sh --flavor telemetry`.
- Launch from Main menu. Watch `ssh root@192.168.1.188 tail -F /tmp/sonicmania.log` (adapt path to deployment).
- Within 2 seconds, log shows one of:
  - `"vsync feedback engaged"` — SUCCESS
  - repeated `"vsync feedback stale"` — wrapper bug, raise.
  - no feedback log at all for 10 seconds — wrapper not writing seq, raise.
- Overlay on-canvas shows `CL:e` prefix with `|e|` stabilizing ≤ 500 μs
  after 5 seconds on static title screen.
- Power off (hard reset), boot again, confirm feedback re-engages on second
  run (idempotency).

**Depends on:** Steps 1, 2, 3.

**Do NOT:**

- Proceed to Step 5 (profiling) if feedback never engages. Without
  closed-loop phase error, all subsequent perf numbers are meaningful but
  the vsync phase criterion cannot be met.

**If it fails:**

- Feedback disabled but FPS reads 60 → pacer open-loop works, but
  closed-loop does not. Verify HPS wrapper via `devmem2 0x3A000040`
  (feedback word) and `devmem2 0x3A000044` (seq). If seq advances but our
  reads don't pick it up, check endianness assumption (ARMv7-A is
  little-endian; DDR3 writer is little-endian too).
- FPS < 60 → proceed anyway; Step 5 diagnoses via profiling.

---

## Step 5 — Add profiling scopes and capture baseline numbers

**Why it matters:** before considering optimizations, we need to know
*where* the time goes. 3sx's experience (`project-mts-sprite-raster-bottleneck.md`) was that
the rasterizer dominated; Mania's architecture differs (RSDK's sprite
engine is simpler, tilemap is different), so we cannot assume the same
hotspots.

**Read first:**

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.cpp:110-322` — engine main loop. Identify span boundaries.
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:9192-9270` — reference `fps_overlay_accumulate_timing` pattern.

**Create / modify:**

1. `MiSTerPacer.hpp` — add:

   ```cpp
   namespace RSDK::MiSTer::Perf {
       #if ENABLE_PERF_TELEMETRY
       enum Scope { SCOPE_UPDATE, SCOPE_RASTER, SCOPE_PRESENT, SCOPE_COUNT };
       void   BeginScope(int scope);
       void   EndScope(int scope);
       double AvgScopeMs(int scope);   // 60-frame rolling avg
       void   RotateRing();            // called once per frame from FlipScreen
       #else
       inline void BeginScope(int)  {}
       inline void EndScope(int)    {}
       inline double AvgScopeMs(int){ return 0.0; }
       inline void RotateRing()     {}
       #endif
   }
   ```

2. `MiSTerPacer.cpp` — implement the ring buffer. 60-slot `uint64_t[SCOPE_COUNT]`
   array, overwrite oldest.

3. Call sites (in `MiSTerRenderDevice.cpp`):
   - `BeginScope(SCOPE_PRESENT)` at top of `FlipScreen`, `EndScope` after `WriteFrame`.
   - `RotateRing()` at end of `FlipScreen`.

   For `SCOPE_UPDATE` and `SCOPE_RASTER`, hooks must live in
   `RetroEngine.cpp` inside `RSDK::ProcessEngine()` (defined at
   `RetroEngine.cpp:345`). The render pass is `ProcessObjectDrawLists()`
   (called at lines 404, 422, 439, 481, 494, 507 — once per `sceneInfo.state`
   case); the update pass is `ProcessInput()` + `ProcessSceneTimer()` +
   `ProcessObjects()` + `ProcessParallaxAutoScroll()` appearing immediately
   before each `ProcessObjectDrawLists()`. **Do NOT** wrap at the
   `ProcessEngine()` call site (`RetroEngine.cpp:272`): that span combines
   update and render, preventing separation.

   Narrowest approach:
   - At `RetroEngine.cpp:386` (`case ENGINESTATE_REGULAR:`), wrap
     `ProcessInput(); ProcessSceneTimer(); ProcessObjects(); ProcessParallaxAutoScroll();`
     (lines 387-390) in `BeginScope(SCOPE_UPDATE)` / `EndScope(SCOPE_UPDATE)`.
   - Wrap `ProcessObjectDrawLists();` (line 404) in `BeginScope(SCOPE_RASTER)`
     / `EndScope(SCOPE_RASTER)`.

   For Phase 6 measurement purposes, `ENGINESTATE_REGULAR` is the only state
   that runs during steady-state gameplay on the three test stages — skip
   instrumenting `ENGINESTATE_LOAD` / `ENGINESTATE_PAUSED` / `FROZEN` /
   `STEPOVER` which either run once or are dev-only.

   Guard ALL scope insertions with `#if RSDK_USE_MISTER` so other backends
   remain byte-identical.

4. Extend overlay mode-1 string (Step 3) to include the three averages:

   ```cpp
   SDL_snprintf(fpsLabel, sizeof(fpsLabel),
       "%d u:%4.1f r:%4.1f p:%4.1f %s:e%+05lld",
       fpsLastValue,
       RSDK::MiSTer::Perf::AvgScopeMs(RSDK::MiSTer::Perf::SCOPE_UPDATE),
       RSDK::MiSTer::Perf::AvgScopeMs(RSDK::MiSTer::Perf::SCOPE_RASTER),
       RSDK::MiSTer::Perf::AvgScopeMs(RSDK::MiSTer::Perf::SCOPE_PRESENT),
       prefix, (long long)phase_us);
   ```

**Success criteria:**

- On each test stage, the `u:` + `r:` + `p:` figures sum to ≤ 16.6 ms
  total at 60 fps. Example: Green Hill might read `u: 3.2 r: 6.1 p: 0.5`
  = 9.8 ms, leaving ~7 ms pacer slack.
- If any stage shows the sum > 16.6 ms: the rasterizer or game-logic
  block is the bottleneck; record the figure and escalate to Step 6.

**Depends on:** Steps 1, 3 (overlay must exist to display scopes). Can run after Step 4 validates loop closure.

**Do NOT:**

- Add profiling scopes inside hot inner loops (e.g., per-pixel). The ring
  buffer only handles once-per-frame start/end pairs.
- Sample `SDL_GetTicksNS()` more than twice per scope — it's a syscall
  on Linux (via VDSO, so cheap, but not free).
- Modify `RetroEngine.cpp` or `Drawing.cpp` in any way other than adding
  `BeginScope`/`EndScope` pairs inside `#if RSDK_USE_MISTER` guards. Every
  other behavior stays upstream-identical.

**If it fails:**

- Scopes read zero: `ENABLE_PERF_TELEMETRY` not plumbed to the RSDK TU. Verify via `strings build/mister-telemetry-install/bin/RSDKv5U | grep 'SCOPE_'` which should find symbols if compiled in.
- Sum exceeds 16.6 ms on Green Hill (simplest stage): something is
  seriously wrong — proceed to Step 6.

---

## Step 6 — (Conditional) ARM clock override and clock-gated rebuild

**Why it matters:** if 800 MHz cannot hit 60 fps, we have three options
(overclock, further optimization, 30 fps fallback). This step implements
option 1, which is the cheapest. Options 2 and 3 are deferred.

**PRECONDITION:** Step 5 data shows:
- Green Hill sum ≥ 15 ms (sustained, not a 1-frame spike), OR
- Studiopolis / Titanic Monarch sustained < 58 fps.

**Read first:**

- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:9582-9625` — reference `apply_arm_clock` + directional sysfs write order.
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/build-game.sh` — check how runtime flags are passed.

**Create / modify:**

1. `MiSTerPacer.cpp` — implement `ApplyArmClock(int mode)` and
   `RestoreArmClock()` exactly per 3sx reference. Register the restorer
   with `std::atexit`.

2. Wire a CLI flag in the main entry point (wherever `RunRetroEngine` is
   invoked — `SonicMania/main.cpp` or similar; identify during
   implementation). Accept `--arm-clock=1000` or `--arm-clock=1200`.
   Alternative: read env `MISTER_ARM_CLOCK_MHZ`. Ship both.

3. Document in `docs/mister-wrapper.md` at the bottom.

**Success criteria:**

- Default run (no flag, no env): sysfs untouched;
  `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq` reads
  `800000`.
- `--arm-clock=1000`: `scaling_max_freq` reads `1000000`; same for
  `min_freq`. Restored to `800000` on `SIGTERM` / clean exit.
- Perf measured with 1000 MHz clock: sum drops proportionally
  (~20% headroom improvement).
- Temperature not harmful: `cat /sys/class/thermal/thermal_zone0/temp`
  reads < 80000 (< 80 °C) after 10 minutes.

**Depends on:** Step 5 data confirming the need.

**Do NOT:**

- Apply overclock unconditionally. Must be opt-in.
- Exceed 1200 MHz. MiSTer community-documented safe ceiling for DE10-Nano.
- Skip the atexit restore — leaving the core clocked up affects the next
  MiSTer menu session.
- Run this step if Step 5 showed 60 fps at 800 MHz. Skip entirely and
  claim Phase 6 done.

**If it fails:**

- sysfs write returns EACCES → binary must run as root, and on MiSTer
  the wrapper does spawn it as root. Check with
  `id` in the game's initial log.
- Overclock unstable (hangs, corrupted pixels) → revert to 800, file a
  follow-up to investigate NEON hotspot optimization (option 3).

---

## Step 7 — (Optional) Rasterizer profile + NEON microoptimization

**Why it matters:** only if Steps 5 + 6 together cannot meet the 60-fps
target. This step is entered ONLY if `r:` (raster scope) dominates the
budget and overclock is insufficient or rejected.

**PRECONDITION:** Step 5 shows `r:` ≥ 10 ms at 800 MHz; Step 6 overclock to
1200 MHz brings `r:` to 6.6 ms but still blocks 60 fps due to other
factors, OR user rejects overclock.

**Read first:**

- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Drawing.cpp` — sprite/tile inner loops, ~4000 lines. Begin with `DrawSpriteFlipped`, `DrawQuad`, `DrawTileLayer`.
- `3sx-mister` project memory `project-mts-sprite-raster-bottleneck.md` for methodology.

**Success criteria:**

- Identify one hotspot via gprof / perf record on MiSTer (run
  `perf record -F 99 -p $(pidof RSDKv5U) -- sleep 10` on stage; then `perf report`).
- Hand-vectorize or algorithmically optimize ONE loop; re-measure;
  confirm `r:` drops by ≥ 20%.

**Depends on:** Step 5.

**Do NOT:**

- Change rendering semantics. No output-pixel differences allowed; any
  optimization must pass a frame-identity test (write a PNG of frame N
  before and after the change; diff = 0).
- Touch upstream RSDK files unless the optimization is trivially upstreamable. Prefer a
  MiSTer-gated override in a local overlay header.

**If it fails:**

- Re-examine whether the 30 fps fallback is acceptable; file a new
  Phase 6.5 plan.

---

## Step 8 — Exit criteria validation + commit

**Why it matters:** Phase 6 is done when, and only when, the exit criteria
(p. 3) are met on real hardware AND the code lands on the branch.

**Create / modify:**

- Update `docs/mister-port-plan.md` Phase 6 section to replace
  "UNVERIFIED" with a recorded number (e.g. "Measured 60.0 fps sustained
  on all three test stages at 800 MHz, closed-loop phase error ≤ 180 μs").
- Tag the commit `phase-6-complete`.

**Success criteria:**

- All five exit criteria bullets (p. 3) green.
- Telemetry build still passes `tools/mister/build-game.sh --flavor telemetry`.
- Clean flavor: `--flavor clean` — builds; overlay defaults to off; hotkey
  still toggles it. No telemetry-only symbols linked in.
- PR description includes the overlay screenshots (title, Green Hill,
  Studiopolis, Titanic Monarch).

**Depends on:** Steps 1–6 (Step 7 only if required).

**Do NOT:**

- Commit with exit criteria 2 or 3 unmet. A failing Phase 6 leaves the
  overlay and pacer code on a side branch for follow-up.

**If it fails:**

- Specific stage blocked: log which, what `r:` / `u:` / `p:` show,
  escalate to Phase 6.5 with one of the options in Step 7 /
  `mister-port-plan.md:255-260`.

---

## Changes made during self-review

- Corrected SDL API from SDL3 (`SDL_GetTicksNS` / `SDL_DelayNS`) to SDL2
  (`SDL_GetPerformanceCounter` + POSIX `clock_nanosleep`). Added
  `PacerNowNs()` / `PacerSleepUntilNs()` as unified helpers so every call
  site agrees on the clock domain.
- Corrected `busywait_threshold_ns` default from 250 μs to 200 μs
  (verified `3sx-mister/src/port/sdl/sdl_app.c:9483`).
- Rewrote the Step 5 scope-hook call sites against the real
  `RSDK::ProcessEngine()` at `RetroEngine.cpp:345-423`, naming the exact
  functions to bracket (`ProcessInput()`, `ProcessSceneTimer()`,
  `ProcessObjects()`, `ProcessParallaxAutoScroll()` → SCOPE_UPDATE;
  `ProcessObjectDrawLists()` → SCOPE_RASTER) and limiting instrumentation
  to `ENGINESTATE_REGULAR` since that is the only steady-state branch
  during gameplay.
- Clarified that F3 upstream branch (`MiSTerRenderDevice.cpp:428-431`) is
  dormant on MiSTer because `userShaderCount` stays 0, so the rebind is a
  wholesale replacement not a conditional overlay.

## Risks + open questions

- **Wrapper feedback protocol not yet validated on Mania's HPS binary.**
  The spec is copied from 3sx; the Mania wrapper (Phase 4 deferred to
  Phase 7 per `mister-port-plan.md:266-276`) must implement writing feedback
  word + seq. Without it, Step 4 blocks. Mitigate: the wrapper fork for
  Mania lives in `vendor/Main_MiSTer/` already; confirm the feedback write
  code has been ported during Phase 4 wrapper work before scheduling Phase 6 on hardware.
- **Kernel HZ.** Linux on the MiSTer HPS may run at `HZ=250` default,
  making 500 μs jitter the floor for naive `nanosleep`. `precise_delay_ns`
  handles this via the busy-wait tail, but if HZ is low the sleep portion
  is coarser. Baseline on a MiSTer: run `zcat /proc/config.gz |grep CONFIG_HZ`
  during Step 4.
- **Thermals on overclock.** DE10-Nano FPGA + A9 @ 1.2 GHz runs warm;
  with a passive heatsink and closed case, it may thermal-throttle during
  extended play. Document in `docs/mister-wrapper.md` alongside the
  override.
- **FPS overlay and Mania's palette rotation.** Some stages dim the
  screen during transitions; the green overlay text may look muddy
  during `ProcessDimming()`. Acceptable for dev overlay; re-evaluate if
  community asks for the overlay in release.
- **`engine.devMenu` gating.** F3/F6 hotkeys work at all times today
  (no devmenu gate in our handler). Upstream gates most F-keys behind
  `engine.devMenu`; we deliberately don't for the overlay, because the
  overlay is a telemetry tool, not a dev-menu feature. Call this out in
  the commit message.
- **`DrawDevString` clobbers game pixels.** The overlay paints after
  game rendering but before `WriteFrame`; the green text pixels replace
  whatever Mania drew. This is expected (it's an overlay) but confirm
  during Step 3 that `DrawDevString` respects
  `currentScreen->size.{x,y}` (it does, per `Drawing.cpp:4417,4432`).
- **What if FPS overlay itself costs > 100 μs per frame?** It's a small
  stencil blit (≤ 5-10 characters × 8×8 pixels) — ~640 pixels max.
  Negligible compared to game rendering. If profiling shows otherwise,
  move the FPS update itself inside `ENABLE_PERF_TELEMETRY` so the clean
  flavor has zero cost when overlay is off.

## Order of execution

- Step 1 (pacer scaffold) must land first.
- Step 2 (precise_delay) is prerequisite for meaningful Step 4 measurements but
  can be batched with Step 1 in a single `/implement` cycle if small.
- Step 3 (overlay) can be implemented in parallel with Step 2 — no
  dependency.
- Step 4 (on-device validation) gates everything after.
- Step 5 (profiling) is independent of Step 6; both feed the Step 8 exit
  decision.
- Step 6 and Step 7 are conditional; most likely Step 6 suffices.
- Step 8 closes the phase.

Total estimated agent cycles: 6–8. Total estimated wall-clock: 3–5 days,
most of which is on-device validation and waiting for user-driven
build/boot cycles.
