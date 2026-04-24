# Sonic Mania MiSTer — Settings Reference

User-facing reference for `Settings.ini` keys read by the RSDKv5 engine
when running on MiSTer, plus rebinding guidance and known constraints.

`Settings.ini` lives at `/media/fat/games/sonic-mania/saves/Settings.ini`
on a Phase 7+ build (per the save-path routing in
`dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserStorage.cpp` MiSTer arm).
The engine writes the file on first launch with all defaults populated,
then reads from it on every subsequent boot.

This document describes the keys that exist; it does NOT instruct end
users to hand-edit the file. In-game menus expose every safely-editable
key, and the list below is intended for power users debugging behaviour
or migrating settings from a desktop install.

## How to Read the Tables

| Column | Meaning |
|---|---|
| Key | `Section:KeyName` as it appears in `Settings.ini` |
| Default | Value the engine writes if the key is absent |
| Editable on MiSTer? | `yes` (engine respects edits), `no` (engine ignores or clamps), `effectively-no` (engine reads but the FPGA pipeline overrides it) |
| Description | What the key does |

## [Game] Section

| Key | Default | Editable on MiSTer? | Description |
|---|---|---|---|
| `Game:language` | `0` (LANGUAGE_EN) | yes | UI language. 0=English, 1=French, 2=Italian, 3=German, 4=Spanish, 5=Japanese, 6=Korean, 7=Chinese (S), 8=Chinese (T) |
| `Game:dataFile` | `Data.rsdk` | no | Asset archive path. The wrapper enforces `/media/fat/games/sonic-mania/Data.rsdk` |
| `Game:devMenu` | `false` | yes | Enables the engine's developer menu (Stage Select etc.) |
| `Game:region` | `-1` (auto) | yes | Region code; -1 lets the engine auto-detect from `language` |
| `Game:faceButtonFlip` | `false` | yes | Swaps A/B confirm/cancel button semantics |
| `Game:enableControllerDebugging` | `false` | yes | Logs raw input events to `log.txt` |
| `Game:disableFocusPause` | `false` | effectively-no | Window focus has no meaning on MiSTer (no SDL window); pause-on-blur never fires |
| `Game:fastForwardSpeed` | `8` | yes | Multiplier when fast-forward is held in dev menu |
| `Game:txtScripts` | `false` | yes | Loads dev `.txt` scripts instead of compiled bytecode (mod-loader-adjacent) |
| `Game:gameType` | `1` | no | Reserved engine constant — do not edit |
| `Game:gameLogic` | `Game` | no | Reserved engine constant — do not edit |
| `Game:username` | `""` | yes | Optional player name used by the engine for save-slot tagging |

## [Video] Section

Most `Video:*` keys are inherited from RSDKv5's desktop frontend and have
no effect on MiSTer because the FPGA core owns scan-out timing. The
engine still reads them; we list them for completeness.

| Key | Default | Editable on MiSTer? | Description |
|---|---|---|---|
| `Video:windowed` | `true` | effectively-no | No SDL window on MiSTer; engine renders into DDR3 directly |
| `Video:border` | `true` | effectively-no | Window border — no window |
| `Video:exclusiveFS` | `false` | effectively-no | Exclusive fullscreen — no display surface |
| `Video:vsync` | `false` | effectively-no | The MiSTer pacer (`MiSTerPacer.cpp`) drives frame timing against the FPGA scan-out feedback word, not SDL vsync |
| `Video:tripleBuffering` | `false` | effectively-no | The FPGA reader uses a double-buffer in DDR3 (`BUF0`/`BUF1`); engine writes one, FPGA reads the other |
| `Video:pixWidth` | `424` (engine default) | no | Clamped to `320` at render-device init (`MiSTerRenderDevice::Init` line 33). FPGA core RBF expects 320 |
| `Video:winWidth` | `424` | effectively-no | No window |
| `Video:winHeight` | `240` | effectively-no | No window |
| `Video:fsWidth` | `0` (auto) | effectively-no | Fullscreen surface — no surface |
| `Video:fsHeight` | `0` (auto) | effectively-no | Fullscreen surface — no surface |
| `Video:refreshRate` | `60` | effectively-no | FPGA PLL fixes scan-out at ~59.59 Hz |
| `Video:shaderSupport` | `true` | effectively-no | OpenGL/Direct3D shaders — MiSTer renders RGB565 frames into DDR3 directly |
| `Video:screenShader` | `0` (SHADER_NONE) | effectively-no | Same reason — no shader pipeline |
| `Video:maxPixWidth` | `424` | no | Clamped same as `pixWidth` |

## [Audio] Section

| Key | Default | Editable on MiSTer? | Description |
|---|---|---|---|
| `Audio:streamsEnabled` | `true` | yes | Master toggle for streaming audio (music) |
| `Audio:streamVolume` | `0.8` | yes | Music volume (0.0–1.0) |
| `Audio:sfxVolume` | `1.0` | yes | Sound-effect volume (0.0–1.0) |

## [Keyboard Map N] Sections (N = 1..4)

For each player N from 1 to 4, the engine reads twelve keyboard scancodes.
SDL2's keyboard input on MiSTer requires the `SDLToWinAPIMappings` table
fix that landed in Phase 3 (`KBInputDevice.cpp:13,822,856` widened to
`RETRO_INPUTDEVICE_SDL2`).

Keys per player (Win32 virtual-key codes; the engine remaps SDL scancodes
through `SDLToWinAPIMappings`):

`Keyboard Map N:up`, `…:down`, `…:left`, `…:right`,
`…:buttonA`, `…:buttonB`, `…:buttonC`, `…:buttonX`, `…:buttonY`, `…:buttonZ`,
`…:start`, `…:select`.

Default values come from `defaultKeyMaps[N]` in
`dependencies/RSDKv5/RSDKv5/RSDK/Input/Input.cpp`. Player 1 — use the
in-game Options → Controls → KB rebinder rather than hand-editing.
Players 2–4: hand-edit the `[Keyboard Map N]` sections if needed; the
in-game UI may not expose them on this build.

## [GamePad Map N] Sections

Up to N gamepads worth of binding overrides. Each entry has `name`,
`type`, `vendorID`, `productID`, `mappingTypes`, and `offsets`. These
are written by the engine when a controller is mapped via Options →
Controls; do not hand-edit.

## [Dev] Section (Telemetry Builds Only)

Telemetry builds (`tools/mister/build-game.sh --flavor telemetry`) gate
some development-only logging behind `Dev:*` keys. The clean-flavor
release does not surface these keys. They are intended for development
work, not end users; documenting them here would only encourage
breakage.

## Input Rebinding

Sonic Mania ships an in-game rebinder that handles every controller
type the engine recognises:

- `SonicMania/Objects/Menu/UIKeyBinder.{c,h}` — binder UI implementation
- `SonicMania/Objects/Menu/OptionsMenu.c:58–168` — top-level "Controls
  WIN / KB / PS4 / XB1 / NX / NX Grip / NX Joycon / NX Pro" page dispatch

From the title screen, navigate to Options → Controls. The active
controller's profile is auto-detected; rebinds are written into
`Settings.ini` under the appropriate `[Keyboard Map N]` or
`[GamePad Map N]` section and persist across launches.

### SDL2 Controller Mapping Override

If your controller is not auto-recognised (common with arcade pads or
generic USB devices), drop a custom `gamecontrollerdb.txt` file into:

```
/media/fat/games/sonic-mania/saves/gamecontrollerdb.txt
```

The engine loads this file at startup via
`SDL_GameControllerAddMappingsFromFile`
(`dependencies/RSDKv5/RSDKv5/RSDK/Input/SDL2/SDL2InputDevice.cpp:242`).
Mappings here apply at the SDL2 layer — the engine still treats the
device as a normal controller afterwards, so you can rebind buttons
in-game on top of the SDL mapping.

The community-maintained source for current `gamecontrollerdb.txt`
content is https://github.com/gabomdq/SDL_GameControllerDB.

## Known Differences from Desktop Builds

The MiSTer port differs from upstream RSDKv5 desktop builds in a few
hard-baked ways:

- **Render width is clamped to 320 pixels.** The FPGA core scan-out is
  fixed at 320×240; widescreen `Video:pixWidth` values up to 424 are
  silently clamped at engine init. This is per design decision D1 in
  `docs/mister-port-plan.md` (4:3 aspect ratio matches the era's CRTs).
- **Fullscreen is the only mode.** There is no window manager.
- **Audio device selection is fixed.** The SDL2 audio backend opens
  the default ALSA device; there is no `Audio:device=` knob on MiSTer.
- **Shaders / triple-buffering are inert.** The MiSTer render device
  writes RGB565 frames into DDR3 for the FPGA pixel reader; there is
  no GPU pipeline to apply shaders to.
- **Cutscenes are stubbed.** Attract-mode and inter-zone YUV cutscenes
  currently render black with audio only. Tracked as Phase 7 Step 7
  (deferred — see `docs/phase-7-plan.md` Step 7).
- **OSD overlay is unreachable while running.** The MiSTer OSD (F12)
  cannot be opened mid-game. Exit the core to access OSD options.

## Settings.ini Location Migration (Dev Builds Only)

If you previously ran a development build that wrote `Settings.ini`
directly into `/media/fat/games/sonic-mania/`, the file location moved
to `saves/` in Phase 7. To migrate:

```sh
ssh root@<mister-ip>
mv /media/fat/games/sonic-mania/Settings.ini \
   /media/fat/games/sonic-mania/saves/Settings.ini
```

The engine will not auto-migrate. New installs hit `saves/` directly
on first launch.

## See Also

- `docs/mister-wrapper.md` — install layout, MiSTer.ini, troubleshooting
- `docs/mister-runbook.md` — engineering operational state
- `docs/phase-7-plan.md` — full rationale for save-path routing and
  the rebinder verification (Steps 4 + 6)
