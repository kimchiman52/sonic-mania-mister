# Phase 7 — Polish Implementation Plan

**Document date:** 2026-04-24
**Status:** Draft plan, awaiting user sign-off before `/implement` cycles begin.
**Scope:** Polish and release-readiness. Ships a clean, user-installable build on top of the Phase 0–6 stack.
**Track:** Track L (Linux-userland) only. No FPGA RTL changes. No Quartus rebuilds.

**Companion docs (canonical — read before implementing any step):**
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md` — Phase 7 scope at lines ~266–278, Phase 8 non-scope at ~280–288
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-research.md` §2.10 (cutscene YUV), §4.5 (open design decisions)
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — Phase 0–4 operational state (libtheora bundling, deploy script, INI contract)
- `/Users/sb/Developer/3sx-mister/tools/mister/release-readme.txt` — canonical release README shape (136 lines; we mirror structure, not content)
- `/Users/sb/Developer/3sx-mister/docs/mister-wrapper.md` — 465-line source-of-truth wrapper doc (we produce a much shorter analog)
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/mister_joy_shm.h` — 22-line SHM struct; exact path `/dev/shm/thirdsarm-joy`, magic `0x33534152` ("3SAR"), two players, analog stick state

**Baked-in decisions (do NOT revisit):**
- **D1:** Internal resolution is 320×240 4:3 (from master plan).
- **D5:** Cutscenes were stubbed in Phase 0–4. Phase 7 revisits *only if* libtheora armhf is already building (it is — see Phase 0 `build-libtheora.sh`). Always allowed to skip.
- **D8:** Telemetry/clean flavor split is live. Dev default is telemetry (per `feedback-always-telemetry.md`).

**Memory rules this plan obeys (every step respects these):**
- `feedback-release-readme-path.md` — canonical release README path is `tools/mister/release-readme.txt`.
- `feedback-releases-are-ours.md` — releases go to the user's own GitHub org (`kimchiman52/…`), not upstream `RSDKModding/*`.
- `feedback-always-telemetry.md` — default dev builds are telemetry flavor.
- `feedback-read-runbooks-before-deploy.md` — before any on-device verification in this phase, re-read `docs/mister-runbook.md`.
- `feedback-no-rsync-delete.md` — deploy/release workflows never `rsync --delete` outside a whitelisted path.
- `project-release-naming.md` — release tags use dates, NOT version numbers like "0.2.0".
- `feedback-debug-build-for-live-tests.md` — live on-device tests ship a telemetry (debug-flavor) binary so we get diagnostics the first time.

**Non-scope (Phase 8 territory):**
- Mod loader distribution / ecosystem
- Widescreen 424×240 alternate modeline
- Netplay / rollback
- Upstream contributions

---

## 0. Background (what Phase 0–6 already built that Phase 7 leans on)

- `dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}` (~690 LOC), with SDL2 input+audio, NativeVideoWriter pixel output, and YUV/ImageTexture explicit stubs at lines 167–215. Stubs to reactivate in Phase 7 are already named and guarded.
- `tools/mister/build-game.sh --flavor telemetry|clean|both` produces `build/mister-{telemetry,clean}-install/bin/RSDKv5U` + a matching `…-package/` tree with `scripts/run-mania.sh` launcher. `ENABLE_PERF_TELEMETRY=$<BOOL:…>` compile define flows through.
- `tools/mister/package.sh` bundles cairo-free `libtheora.so.0` + `libtheoradec.so.1` into `<output>/lib/`; launcher prepends that to `LD_LIBRARY_PATH`.
- `tools/mister-wrapper/deploy-step5.sh` currently ships `MiSTer_SonicMania`, RBF, test-frame-writer, INI stanza. Runtime home is `/media/fat/games/sonic-mania/` (lowercase) per wrapper source (`vendor/Main_MiSTer/sonicmania_wrapper.cpp:55–59`).
- Save location today: `SKU::InitUserDirectory()` at `UserStorage.cpp:1150–1171` calls `SetUserFileCallbacks("./", …)` under `RETRO_PLATFORM == RETRO_LINUX`. With the existing launcher doing `cd "${APP_DIR}"` and `exec ./bin/RSDKv5U`, Mania will read/write `SGame.bin`, `Replay_*.bin`, `Settings.ini`, `log.txt`, and `gamecontrollerdb.txt` **at `/media/fat/games/sonic-mania/`** (the APP_DIR) — not at `./bin/`. This is already acceptable; Step 5 just tightens it.
- `vendor/Main_MiSTer/sonicmania_wrapper.cpp` is a full 3046-line fork of `thirdsarm_wrapper.cpp`, already using the constants `kRuntimeHome = "/media/fat/games/sonic-mania"`, `kRuntimeBinary = ".../bin/RSDKv5U"`, `kRuntimeArchive = ".../Data.rsdk"`, `kLogDir = ".../logs"`. Direct-P2P symbol `g_direct_p2p_handoff_armed` (line ~50) is dormant netplay scaffolding carried from 3sx; it is not wired up for Mania and MUST NOT be activated in this phase.

---

## 1. Plan overview — eight ordered steps

Each step below is sized for a single `/implement` cycle. Steps are ordered so early steps deliver release-blocking polish (saves, docs, packaging) and late, optional steps add cosmetic features (cutscenes, wrapper SHM input).

| # | Step | Priority | LOC / effort | Build? | Deploy? |
|---|---|---|---|---|---|
| 1 | Repo housekeeping: `.gitignore` coverage, drop stale build artifacts | medium | ~30 diff | No | No |
| 2 | `docs/mister-wrapper.md` — user-facing INI contract + launch flow | medium | new ~200-line doc | No | No |
| 3 | Release packaging: `tools/mister/release-readme.txt` + `tools/mister-wrapper/build-release.sh` | medium | ~250 LOC + 136-line text file | Yes (clean flavor) | No |
| 4 | Save-game path: add `RETRO_MISTER` arm in `InitUserDirectory()` + launcher invariants | medium | ~30 LOC | Yes (telemetry) | Yes |
| 5 | `.ini` defaults + first-run onboarding (Data.rsdk-missing UX) | medium | ~80 LOC | Yes (telemetry) | Yes |
| 6 | Controller binding defaults review (defer fix if no issue found) | low-gate | 0–50 LOC | maybe | maybe |
| 7 | Cutscene support: CPU YUV→RGB565 in `SetupVideoTexture_YUV{420,422,444}` | low (skippable) | ~120 LOC | Yes (both flavors) | Yes |
| 8 | Wrapper-SHM input: `/dev/shm/sonicmania-joy` reader in the MiSTer backend | low (skippable) | ~150 LOC | Yes (both flavors) | Yes |

**Cut-line.** If time runs out after Step 5 we still have a shippable v-with-date release; Steps 6–8 are upgrade fodder. Hard sequencing is 1 → 2 → 3, and 4 before 5. Step 7 and Step 8 are independent of each other and of 4–6; they can slide to a later phase without blocking release.

**Final release build.** After the last landed step, run `build-game.sh --flavor both` and rerun Step 3's `build-release.sh` to produce the ZIP. Tag per `project-release-naming.md`.

---

## Step 1 — Repo housekeeping

### Why it matters
Several Phase 0–4 build artifacts ended up tracked or nearly tracked (the `.gitignore` enumerates 13 build trees by name). Releases land in `build/` too. A clean `.gitignore` prevents accidental commits of large binaries, `log.txt` from on-device runs, and `*.rsdk` archives. Unblocks Step 3 (release packaging), which writes a new tree under `build/`.

### Files to read before implementing
- `/Users/sb/Developer/sonic-mania-mister/.gitignore` (existing, ~60 lines)
- `/Users/sb/Developer/sonic-mania-mister/` root — `git status -s` to see what's currently untracked but should stay untracked
- `/Users/sb/Developer/3sx-mister/.gitignore` for reference

### Files to create / modify
- **Modify** `/Users/sb/Developer/sonic-mania-mister/.gitignore`:
  - Collapse the 13 explicitly-listed `build-mister-*` / `build-sdl2-*` / `build-ph3-*` trees into a single `build/` glob (already present on line 26 as `[Bb]uild/`, so those explicit lines are redundant — delete them).
  - Add: `/log.txt`, `Settings.ini` at repo root (engine writes these when run from the tree), `*.rsdk` already present line 41.
  - Add: `/docker-bootstrap-*.log`, `tools/mister/*.log` (phase-0 artifacts).
  - Add: `/build/mister-release/` (new tree that Step 3 produces).
  - Add: `/Sonic Mania/Static/*` already present line 42 (keep).
  - Keep all existing entries that look intentional.
- **Delete** (via `git rm --cached`) any currently-tracked files that match new patterns — expect zero hits if we've been disciplined, but verify.

### Success criteria
- `git status --ignored` after implementation shows zero unexpected untracked files at the repo root; all `build-*` trees appear under "Ignored files".
- `git check-ignore -v build/mister-release/foo/bar` reports the rule that caught it.
- `git log -1 --stat` on the resulting commit shows only `.gitignore` changed (no accidental file removals from the index).

### Depends on
Nothing. This step is prerequisite for Step 3.

### What NOT to do
- Do NOT delete any `docs/` files — Phase 0–4 plan docs stay in tree.
- Do NOT add `dependencies/` or any submodule path to ignore (they're already ignored via the `[Bb]uild/` glob only if they're under build/; the RSDKv5 submodule is checked in and must stay visible).
- Do NOT change tracked files' ignore status without a `git rm --cached` (otherwise git will keep tracking them).

### If it fails
- If `git rm --cached` catches something important (e.g., a legitimate log in `docs/`), revert that file's removal and narrow the glob.
- If CMake/Docker still deposits a file outside `build/` (e.g., `compile_commands.json` at root), add a specific rule and re-run the check.

---

## Step 2 — `docs/mister-wrapper.md` user-facing INI contract

### Why it matters
Phase 0–4 docs are engineer-facing. Users installing from a release ZIP need a canonical reference describing what goes where, which INI keys are required, and why `vga_scaler=0` matters. 3sx has a 465-line equivalent at `docs/mister-wrapper.md`; we produce a shorter Mania-specific one (~200 lines) aimed at end users. This doc also unblocks Step 3, which cites it from the release README.

### Files to read before implementing
- `/Users/sb/Developer/3sx-mister/docs/mister-wrapper.md` (all 465 lines — note the structure, not the content; most of it is Phase 1 wrapper-bringup history we don't need)
- `/Users/sb/Developer/3sx-mister/tools/mister/release-readme.txt` (release-side INI snippet at lines 64–67, 80–89)
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` (Phase 4 block at lines ~100–140 — source of truth for the `[Sonic Mania]` INI section and install paths)
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp:55–59` — runtime path constants
- `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/deploy-step5.sh` — actual install layout the deploy script produces

### Files to create / modify
- **Create** `/Users/sb/Developer/sonic-mania-mister/docs/mister-wrapper.md` with sections:
  1. **Overview.** One paragraph: what the wrapper is, how it boots, what it launches.
  2. **Install layout.** File tree of `/media/fat/` showing wrapper, RBF, game binary, lib/, scripts/, logs/, saves/, resources/Data.rsdk. Match what Step 3's release ZIP produces and what Step 4 resolves for the save path.
  3. **INI contract.** The minimal `[Sonic Mania]` block: `main=MiSTer_SonicMania`, `vga_scaler=0`. Explicit note: if the user has `vga_scaler=1` globally, override it here — same rationale as 3sx (HDMI scaler routing, grayscale S-Video).
  4. **CRT notes.** Cross-reference to `docs/mister-runbook.md` for S-Video color validation; mention that Mania runs native 320×240 @ ~59.59 Hz (cite the Phase 4 PLL integer-N M=62/N=3/C=42 from runbook line 105).
  5. **Launch flow.** Menu → `Sonic Mania` → wrapper (`MiSTer_SonicMania`) → core load → HPS `execve` `/media/fat/games/sonic-mania/bin/RSDKv5U` → engine reads `Data.rsdk` → title.
  6. **Troubleshooting.** Missing `Data.rsdk`, black screen (`vga_scaler`), no S-Video color, glibc mismatch.
  7. **Upgrading from a dev build.** What to wipe (`rm -rf /media/fat/games/sonic-mania/bin /lib /scripts`) and what to keep (saves, `Data.rsdk`).

### Success criteria
- File exists, renders as valid Markdown (no unterminated code fences).
- `grep '^## ' docs/mister-wrapper.md | wc -l` returns 7.
- Every absolute path mentioned in the doc matches (a) `sonicmania_wrapper.cpp:55–59` constants or (b) `deploy-step5.sh` SCP destinations.
- The INI snippet compiles cleanly into an actual MiSTer `MiSTer.ini` section (no stray leading spaces, no smart-quotes).
- Cross-references to other docs all resolve (relative Markdown links work from `docs/`).

### Depends on
Step 1 (for the ignore rules; otherwise new artifacts under `build/mister-release/` would need tracking decisions).

### What NOT to do
- Do NOT describe Phase 0–4 build procedure here (that's `mister-runbook.md`'s job; just cross-reference).
- Do NOT promise features not shipped (cutscenes, SHM input, widescreen) — those are Phase 7 Steps 7/8 or Phase 8.
- Do NOT include 3sx's phase-1 wrapper-bringup history. This is a user-facing doc, not an archeological record.
- Do NOT embed `.ini` snippets with `video_mode=` overrides — native timing is core-owned per decision D1.

### If it fails
- If the install-layout section drifts from `deploy-step5.sh`, fix the script first; the doc describes reality.
- If a user-facing piece needs info we don't have (e.g., save path), mark it TODO and let Step 4/5 fill it in.

---

## Step 3 — Release packaging

### Why it matters
Per `feedback-release-readme-path.md` the canonical release README lives at `tools/mister/release-readme.txt`. We need a matching build-release script that produces a single downloadable ZIP containing wrapper binary, RBF, game binary, libs, launcher, README, LICENSE, and the INI snippet. Without this step there is no clean installable artifact — users would have to hand-assemble from `build/mister-*-package/` and the `build-hps` output.

### Files to read before implementing
- `/Users/sb/Developer/3sx-mister/tools/mister/release-readme.txt` (136 lines — our structural template)
- `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-release.sh` if present, else `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/publish-release.sh`
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh` (current Phase 0 packager; release builds on top)
- `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/deploy-step5.sh` (install layout source of truth)
- `/Users/sb/Developer/sonic-mania-mister/LICENSE.md` (non-commercial upstream license; release ships it)

### Files to create / modify
- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister/release-readme.txt` (new, ~150 lines):
  - Mirror 3sx's structure: title, blurb, upgrade-notes (skip — first release), requirements (user supplies `Data.rsdk`), installation (ZIP extracts onto SD card, paths land correctly), CRT troubleshooting, running, overclock notes (same 800/1000/1200 story), more information (link to user's repo).
  - Substitute: "3S-ARM" → "Sonic Mania"; `SF33RD.AFS` → `Data.rsdk`; `/media/fat/games/3s-arm/` → `/media/fat/games/sonic-mania/`; `MiSTer_3S-ARM` → `MiSTer_SonicMania`; `3S-ARM.rbf` → `Sonic Mania.rbf`; repo URL per `feedback-releases-are-ours.md`.
- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/build-release.sh` (canonical 3sx sibling at `/Users/sb/Developer/3sx-mister/tools/mister-wrapper/build-release.sh` — structural model):
  - Defaults (env-var overridable): `RUNTIME_INSTALL_PREFIX=${ROOT_DIR}/build/mister-clean-install`, `HPS_BINARY=${ROOT_DIR}/build/mister-wrapper-hps/MiSTer_SonicMania`, `CORE_RBF=${ROOT_DIR}/build/mister-wrapper-core/Sonic_Mania.rbf`, `WORK_DIR=${ROOT_DIR}/build/mister-release`, `RELEASE_DATE=$(date -u +%Y-%m-%d)`, `OUTPUT_ZIP=${WORK_DIR}/sonic-mania-mister-${RELEASE_DATE}.zip`.
  - Release flavor is `clean`. For dev iteration with telemetry binaries, override explicitly: `RUNTIME_INSTALL_PREFIX=${ROOT_DIR}/build/mister-telemetry-install bash tools/mister-wrapper/build-release.sh` — this matches `feedback-always-telemetry.md`'s "override release-script clean default" guidance.
  - Invoke `tools/mister/build-game.sh --flavor clean` if `RUNTIME_INSTALL_PREFIX` is missing, else use what's there.
  - Invoke `tools/mister-wrapper/build-hps.sh` if `HPS_BINARY` is missing.
  - Require `CORE_RBF` exists; do NOT auto-build (Quartus is not Phase 7's problem).
  - Stage a `${WORK_DIR}/stage/` tree mirroring the FAT-rooted deploy layout:
    ```
    MiSTer_SonicMania
    _Other/Sonic Mania.rbf
    games/sonic-mania/bin/RSDKv5U
    games/sonic-mania/lib/{libtheora.so.0,libtheoradec.so.1}
    games/sonic-mania/scripts/run-mania.sh
    games/sonic-mania/saves/            (empty, placeholder)
    games/sonic-mania/resources/        (empty, README tells user to drop Data.rsdk here per Step 5's decision)
    README.txt          (from tools/mister/release-readme.txt)
    LICENSE.md          (from repo root)
    ```
    Date uses `date -u +%Y-%m-%d` (`project-release-naming.md` — no version numbers).
  - Produce a ZIP at `${OUTPUT_ZIP}`.
  - Emit SHA256 sidecar `.sha256` for the ZIP.
- **Create** `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/release-manifest.txt` — plain-text expected `unzip -l` listing for CI drift detection.

### Success criteria
- `bash tools/mister-wrapper/build-release.sh` exits 0 on a clean checkout (after `setup-build-container.sh` + a Quartus RBF present).
- ZIP contains exactly the tree above; `unzip -l` listing matches `tools/mister-wrapper/release-manifest.txt`.
- Inside the ZIP, `bin/RSDKv5U` is the clean-flavor armhf ELF (`file` output matches runbook expectations).
- `README.txt` at ZIP root renders monospaced at 80 columns (check with `awk 'length > 80' README.txt | head` returns empty).
- The script refuses to package if any of: wrapper binary missing, RBF missing, clean-flavor install tree missing. Each case exits with a nonzero code and a specific error string.

### Depends on
Step 1 (ignore rules), Step 2 (release README cross-references `docs/mister-wrapper.md` indirectly).

### What NOT to do
- Do NOT push to GitHub, create tags, or call `gh release create`. `build-release.sh` only builds the artifact; publishing is a separate manual step per `feedback-releases-are-ours.md`.
- Do NOT include any `Data.rsdk` in the ZIP (copyright — user supplies).
- Do NOT include the telemetry-flavor binary in the release ZIP.
- Do NOT auto-increment a version number or write one into the filename (per `project-release-naming.md`).
- Do NOT write into `/media/fat/` from a local script — that's the deploy flow's job.

### If it fails
- If `build-hps.sh` fails (see 3sx's `feedback-build-terminology.md` — "wrapper" = build-hps.sh), resolve the HPS build first; release script should report which sub-build failed.
- If ZIP mtime reproducibility matters, use `TZ=UTC zip -X` and pin filesystem timestamps.

---

## Step 4 — Save-game path routing

### Why it matters
Mania writes `SGame.bin`, `Replay_*.bin`, `Settings.ini`, `log.txt`, `gamecontrollerdb.txt` via `SKU::userFileDir` (see `UserStorage.cpp:1037` and `UserCore.cpp:287,577`, `Debug.cpp:108`, `Input/SDL2/SDL2InputDevice.cpp:241`). The Linux arm of `InitUserDirectory()` (`UserStorage.cpp:1164`) sets `userFileDir = "./"` — relative to cwd. Our launcher already does `cd "${APP_DIR}"` (= `/media/fat/games/sonic-mania/`), so saves currently co-mingle with the binary, launcher, Data.rsdk, and libs.

Problems with the current situation:
- `log.txt` in that directory gets wiped by deploy scripts that lay down fresh files at the root.
- Upgrades (Step 3 release ZIP overwrites `bin/`, `lib/`, `scripts/`) risk colliding with save files if we ever tighten the deploy whitelist.
- A separate `saves/` subdirectory is the conventional shape and maps to what Step 3's release ZIP provisions.

Fix: route saves to `/media/fat/games/sonic-mania/saves/` by adding a MiSTer arm to `InitUserDirectory()`. Keep the launcher invariant: `cd` to APP_DIR and pass nothing — the engine computes `userFileDir` itself.

### Files to read before implementing
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserStorage.cpp:1150–1171` — `InitUserDirectory` arms
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/RetroEngine.hpp:89,143` — `RETRO_LINUX` / `RETRO_PLATFORM` detection (MiSTer currently compiles as `RETRO_LINUX`; see `mister-port-plan.md` decision D3)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake:139–159` — where `RSDK_USE_MISTER=1` and `RETRO_MISTER=1` are emitted
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/Global/APICallback.c:130–141` (save via APICallback → RSDK.SaveUserFile) — confirms Mania uses the `SKU::` machinery
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh` — launcher `cd` and `exec` lines

### Files to create / modify
- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserStorage.cpp` at `InitUserDirectory` (lines 1150–1171):
  - Add `<sys/stat.h>` and `<sys/types.h>` includes at the top, guarded on MiSTer. **Verified:** `UserStorage.cpp:1` currently includes only `RSDK/Core/RetroEngine.hpp`; the existing `RETRO_LINUX` arm does not need `mkdir` so these headers are NOT pulled in transitively.
    ```cpp
    #if defined(RSDK_USE_MISTER)
    #include <sys/stat.h>
    #include <sys/types.h>
    #endif
    ```
  - Add an `#elif defined(RSDK_USE_MISTER)` arm *before* the `RETRO_LINUX` arm (order matters — MiSTer also reports `RETRO_PLATFORM == RETRO_LINUX`, so the MiSTer arm must short-circuit first).
  - Body:
    ```cpp
    // MiSTer: route user files to a dedicated saves/ subdir so release zip
    // upgrades can replace bin/lib/scripts without colliding with save data.
    // Launcher already cd's to APP_DIR (/media/fat/games/sonic-mania/), so
    // relative path is stable.
    char buffer[0x100];
    sprintf_s(buffer, sizeof(buffer), "./saves/");
    (void)mkdir(buffer, 0755);   // ignore EEXIST
    SKU::SetUserFileCallbacks(buffer, NULL, NULL);
    ```
- **Modify** `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh` launcher HEREDOC:
  - Before `exec ./bin/RSDKv5U`, add `mkdir -p saves resources logs` (idempotent; guarantees `userFileDir` exists even if the user wiped it).
- **Modify** `/Users/sb/Developer/sonic-mania-mister/tools/mister-wrapper/deploy-step5.sh`:
  - After rsync, `ssh` to run `mkdir -p /media/fat/games/sonic-mania/{saves,resources,logs}`.

### Success criteria
- Built clean-flavor binary writes saves to `/media/fat/games/sonic-mania/saves/SGame.bin` on device, verified by:
  - Run, reach save point, exit cleanly.
  - `ssh root@192.168.1.188 'ls -la /media/fat/games/sonic-mania/saves/'` shows `SGame.bin`, `Settings.ini`.
  - `ssh root@192.168.1.188 'ls /media/fat/games/sonic-mania/'` shows `saves/`, `resources/`, `logs/`, `bin/`, `lib/`, `scripts/` — no `SGame.bin` at that level.
- The binary also compiles on Mac (the MiSTer arm is `#if defined(RSDK_USE_MISTER)`-guarded, Mac still takes the `RETRO_OSX` path).
- `docs/mister-wrapper.md` Step 2 install-layout section is updated in the same commit to mention `saves/`.

### Depends on
Step 2 (wrapper doc must be updated to reflect the new path), Step 3 (release ZIP provisions `saves/` as empty directory).

### What NOT to do
- Do NOT introduce a compile-time `SONICMANIA_SAVE_ROOT` macro — simple hardcode inside the `RSDK_USE_MISTER` arm is simpler and consistent with the other `InitUserDirectory` arms.
- Do NOT route to `$HOME/.local/share/...`; MiSTer has no `$HOME` meaningfully set under the stock init, and the SD card layout is the user-facing contract.
- Do NOT break the Linux (non-MiSTer) build — keep `"./"` as the RETRO_LINUX default.
- Do NOT migrate existing saves from APP_DIR to `saves/` with any auto-move code; users on dev builds can move by hand if they care.
- Do NOT touch `customUserFileDir` (that's the mod-loader override and has its own callsites).

### If it fails
- If `mkdir` at engine startup fails (permission, read-only FS), the engine should still load — treat `userFileDir` as effectively `"./saves/"` even if it doesn't exist; `fOpen(..., "wb")` will fail and Mania will log "Nope!" which is the existing no-save-dir behavior.
- If the guard is wrong (we're still inside the RETRO_LINUX branch on MiSTer), verify `platforms/MiSTer.cmake` actually emits `RSDK_USE_MISTER=1` per the file we read (line 155).

---

## Step 5 — INI defaults doc + first-run onboarding

### Why it matters
First-run is the worst-first-impression moment. Today, launching without `Data.rsdk` produces a terse "Nope!" in `log.txt` and a silent exit — on MiSTer that looks like the core hung. We can do better with zero engine changes: (a) a tiny sentinel file the launcher checks before `exec`, and (b) a real doc on what INI/settings knobs exist.

### Files to read before implementing
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserCore.cpp:287,577` — where `Settings.ini` is read/written
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserCore.cpp` — scan for every `iniparser_getstring` / `getint` / `getboolean` call to enumerate the defaults surface
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Core/Reader.cpp:114,286,298` — how `Data.rsdk` is opened (so we know what the launcher sentinel check should pattern-match)
- `/Users/sb/Developer/3sx-mister/tools/mister/release-readme.txt:93–102` — "if the core immediately exits, missing data file is the most common cause" — good user-facing phrasing
- `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh` launcher HEREDOC

### Files to create / modify
- **Modify** `/Users/sb/Developer/sonic-mania-mister/tools/mister/package.sh` launcher HEREDOC (before `cd`):
  - Resolve `DATA_PATH="${APP_DIR}/Data.rsdk"`. If missing, `echo` a 3-line user-friendly error to stdout AND write to `logs/first-run.log`:
    ```
    Sonic Mania: required file Data.rsdk not found.
    Please copy your legally-owned Data.rsdk to:
      /media/fat/games/sonic-mania/Data.rsdk
    ```
  - Exit nonzero so the wrapper's failure path surfaces an OSD error (`sonicmania_wrapper.cpp` already has `exit_to_menu` semantics on child failure).
- **Create** `/Users/sb/Developer/sonic-mania-mister/docs/mister-settings.md` (~150 lines):
  - Enumerate every `Settings.ini` key the engine reads. **Enumeration source:** grep `iniparser_get` in `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserCore.cpp` — expect ≥25 keys across `[Game]` (language, dataFile, devMenu, region, faceButtonFlip, enableControllerDebugging, disableFocusPause, fastForwardSpeed, txtScripts, gameType, gameLogic, username), `[Video]` (windowed, border, exclusiveFS, vsync, tripleBuffering, pixWidth, winWidth, winHeight, fsWidth, fsHeight, refreshRate, shaderSupport, screenShader, maxPixWidth), plus `[Audio]` and `[Dev]` sections.
  - Each row: key, default, description, "editable on MiSTer? yes/no/effectively-no".
  - Flag which are safe to edit (`Game:language`, `Audio:*`, `Dev:*`), which are stored by the engine (`Keyboard:*`, `Controller:*` via bindings), and which are effectively read-only on MiSTer (`Video:windowed` — always fullscreen, `Video:refreshRate` — FPGA-owned at ~59.59 Hz, `Video:pixWidth` — clamped to 320 in `MiSTerRenderDevice::Init` line 33).
  - Include a "known differences from desktop builds" section: widescreen is disabled (pixWidth clamped to 320), fullscreen is the only mode, audio device selection is fixed to SDL2/ALSA.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/docs/mister-wrapper.md` (Step 2 output) — add a cross-reference link to `mister-settings.md`.

### Success criteria
- On a device with no `Data.rsdk`: launching the core from the menu produces a visible error (OSD text or log-tail), not a silent exit.
  - Manual verification: `ssh root@192.168.1.188 'rm -f /media/fat/games/sonic-mania/Data.rsdk && /media/fat/games/sonic-mania/scripts/run-mania.sh'` prints the 3-line message and exits nonzero.
  - Restore: `sshpass … scp Data.rsdk …` back.
- `Settings.ini` section count in `mister-settings.md` is ≥ 4 (Game, Video, Audio, Dev); total row count ≥ 20.
- Every `iniparser_get*` callsite in `UserCore.cpp:287-700` has a corresponding row (cross-check: `grep -c 'iniparser_get' UserCore.cpp` ≤ row count in the doc).
- No engine source changes in this step (all edits are launcher + doc).

### Depends on
Step 3 (launcher HEREDOC owner), Step 4 (launcher already `cd`'s to APP_DIR).

### What NOT to do
- Do NOT modify engine source to add a Data.rsdk-missing dialog — that adds a dependency on having a framebuffer up, which is circular (engine init needs `Data.rsdk`).
- Do NOT pre-populate `Settings.ini` in the release ZIP; let the engine write defaults on first run so user's global Input mappings aren't clobbered.
- Do NOT expose hidden dev-mode keys (`dev menu`, engine hotkeys) to users in the doc — document only what's safe to change.
- Do NOT add a wrapper-level OSD dialog box; the existing `exit_to_menu` + log file is enough for v1.

### If it fails
- If the wrapper doesn't surface the launcher's stderr: write the error into the wrapper's log at `logs/osd-wrapper.log` via a `printf` before `execve` — that log IS persisted and readable.

---

## Step 6 — Controller binding defaults review (gated)

### Why it matters
Mania's default gamepad bindings target a mainstream pad (XInput layout). MiSTer users on arcade sticks (6-button layout common for the 3sx crowd) may find default bindings awkward (jump on 'A', drop-dash on 'B' etc.). Before changing anything, we verify whether this is actually a problem — may be no-op.

**Resolved at review time (2026-04-24):** Mania ships its own in-game rebinder UI at `SonicMania/Objects/Menu/UIKeyBinder.{c,h}` with a matching `OptionsMenu.c` hook chain that exposes "Controls WIN / KB / PS4 / XB1 / NX / NX Grip / NX Joycon / NX Pro" rebinding pages (see `OptionsMenu.c:58-90`). Users can rebind to any layout from within Mania. **Step 6 is a DOCUMENTATION-ONLY step; zero engine or build changes.**

### Files to read before implementing
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/Menu/UIKeyBinder.h` — confirm it exists (verified)
- `/Users/sb/Developer/sonic-mania-mister/SonicMania/Objects/Menu/OptionsMenu.c:58-168` — controls-page dispatch
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/SDL2/SDL2InputDevice.cpp:241-242` — `gamecontrollerdb.txt` loading via `SDL_GameControllerAddMappingsFromFile` (the user-override escape hatch, now also documented)

### Files to create / modify
- **Modify** `/Users/sb/Developer/sonic-mania-mister/docs/mister-settings.md` (Step 5 output): add an "Input rebinding" section pointing users to Options → Controls for in-game rebinding, and note that `gamecontrollerdb.txt` can be dropped into `/media/fat/games/sonic-mania/saves/` for SDL2-level mapping overrides.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/docs/mister-wrapper.md` (Step 2 output): add a one-line cross-reference to the rebinding section.
- No engine source changes. No launcher changes. No release ZIP changes.

### Success criteria
- `docs/mister-settings.md` has an "Input rebinding" subsection (≥ 8 lines).
- `docs/mister-wrapper.md` has the cross-reference link rendered correctly.
- No diff in `dependencies/RSDKv5/**` or `tools/**` from this step.

### Depends on
Step 5 (creates `docs/mister-settings.md`), Step 2 (creates `docs/mister-wrapper.md`).

### What NOT to do
- Do NOT ship a default `gamecontrollerdb.txt` in the release ZIP — the engine already falls back to SDL2's built-in mappings if the file is absent, and shipping one would need per-controller maintenance.
- Do NOT hardcode bindings in engine source.

### If it fails
- Nothing mechanical can fail in this step. If a user later reports a controller problem, reopen as a new issue; the `gamecontrollerdb.txt` escape hatch is documented and self-service.

---

## Step 7 — Cutscene + image-texture unstub (optional, ~120 LOC)

**STATUS: SHIPPED — hardware sign-off pending.** See
`docs/phase-7-step-7-plan.md` for the implemented design and edits;
landed in submodule commit `ffa9330` / parent `ddfd97f1`. Mac-host
build green; live-hardware playback test of attract-mode `Mania.ogv`
remains as the user-driven follow-up.

### Why it matters
Mania's attract mode plays a short libtheora cutscene on the title loop. Today `SetupVideoTexture_YUV{420,422,444}` AND `SetupImageTexture` are explicit stubs (`MiSTerRenderDevice.cpp:167-215`). Mania still boots fine without it — the title screen appears — but the attract loop is silent/black where the video should play, and `SHADER_RGB_IMAGE` (title cards, transition images per `mister-port-research.md` §2.7) renders as garbage/nothing. Mid-game cutscenes (e.g., Titanic Monarch intro) fail the same way. This is cosmetic; decision D5 lets us defer. We revisit because Phase 0 already ships cairo-free libtheora bundled, so the dep is free.

**Scope note.** Master plan Phase 7 table pegs "Cutscene support" at ~80 LOC. This step bundles `SetupImageTexture` alongside because they share the "write into framebuffer, don't scale" pattern — combined ~120 LOC. If the budget is strict, split: YUV only in this step, `SetupImageTexture` deferred to a later phase. Call that split at implementation time if we hit a 2-hour ceiling.

### Files to read before implementing
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/Video.cpp:196–286` — decode loop, YUV buffer layout, `th_decode_ycbcr_out` contract
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/SDL2/SDL2RenderDevice.cpp:1081–1128` — reference impl (via `SDL_PIXELFORMAT_YV12` GPU-side)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp:108–133` — where `screens[0].frameBuffer` lives (our target), and `CopyFrameBuffer`/`FlipScreen` semantics
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_app.c:186–220` — NEON-accelerated pixel conversion pattern (we likely skip NEON here; Mania cutscenes are 60 kB/frame at 320×240, bandwidth is trivial)

### Files to create / modify
- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`:
  - Replace the three `SetupVideoTexture_YUV*` stubs with real CPU conversion.
  - `SetupVideoTexture_YUV420`: upsample chroma (2×2 nearest) inline, apply BT.601 limited-range YUV→RGB, pack RGB565, write into `screens[0].frameBuffer`. Scale to fit `(NV_FRAME_WIDTH × NV_FRAME_HEIGHT)` — engine provides `width/height` params which are the encoded dims.
  - `SetupVideoTexture_YUV422`: same but chroma x2 horizontal only.
  - `SetupVideoTexture_YUV444`: same but no chroma upsampling.
  - Common helper `yuv_to_rgb565(y, u, v)` → `uint16` with clamp.
  - Add an option: if engine-encoded dims differ from our 320×240, centre-crop/letterbox (fill borders with 0x0000); do NOT bilinear-scale (keeps LOC budget small; cutscenes are typically 320×240 or 424×240 anyway).
  - ~120 LOC total; the stub comment block already at the top can be retained as documentation of the contract.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp` at `SetupImageTexture` (line 167):
  - Implement RGBA8888 → RGB565 conversion for title-card / transition images. Engine calls this for `SHADER_RGB_IMAGE`. ~20 LOC. This is the other Phase 7 unstub worth doing alongside YUV because they share the "write into framebuffer, don't scale" pattern.

### Success criteria
- After deploying a telemetry-flavor build, on a MiSTer with `Data.rsdk` present, the attract-mode cutscene plays with video + audio synced to completion.
- `log.txt` shows no `[stub]` lines from `SetupVideoTexture_YUV420` during the cutscene (we removed those prints).
- On Mac host build with `PORT_MISTER=ON`, the YUV paths still compile to a no-op-equivalent (the NativeVideoWriter early-outs on Mac; the engine calls `SetupVideoTexture_YUV*` but the write targets the CPU `frameBuffer` which is always allocated).
- Frame rate during cutscene stays ≥ 55 fps on 800 MHz stock; measure with the Phase 6 show-fps overlay.

### Depends on
Step 4 (save path is stable so we don't lose replay data during cutscene tests). Not dependent on Step 5.

### What NOT to do
- Do NOT bring in a NEON SIMD path in this step — CPU math on 320×240 YUV is ~4 Mpix/s, trivial.
- Do NOT allocate per-frame — use a single `static uint16 cutscene_scratch[NV_FRAME_WIDTH*NV_FRAME_HEIGHT]` if needed, or write directly into `screens[0].frameBuffer`.
- Do NOT change `Video.cpp` upstream — the conversion happens entirely inside the backend, same shape as SDL2's GPU-texture approach.
- Do NOT ship if the attract cutscene visibly tears or frame-drops below 30 fps — kick back to a future phase and leave stubs.

### If it fails
- If BT.601 colors look wrong (greenish tint common bug): check Y offset (16) and U/V offset (128); BT.709 is for 1080p+, Mania uses BT.601.
- If frame rate craters: early-out if engine dims exceed our scanout (cut crop/letterbox and just letterbox).
- Cut-line: if this step spills >2 hours, revert and leave the stubs. Decision D5 allows it.

---

## Step 8 — Wrapper SHM input (optional)

### Why it matters
MiSTer's wrapper can forward OSD menu button presses via a `/dev/shm/thirdsarm-joy` SHM region (see `vendor/Main_MiSTer/mister_joy_shm.h` on the 3sx side). This lets the user open the MiSTer OSD while Mania is running and navigate with the same pad. Today Mania uses SDL2 exclusively — it sees the gamepad but bypasses the wrapper's menu. This step adds the SHM reader so OSD nav works.

This is explicit low-priority per the master plan; most users will not notice. Ship only if Step 7 landed and there's time.

### Files to read before implementing
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/mister_joy_shm.h` (22 lines — struct, magic, path)
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/mister_joy_shm.h` — verified identical vendored copy still using `MISTER_JOY_SHM_PATH = /dev/shm/thirdsarm-joy` and magic `0x33534152`
- `/Users/sb/Developer/3sx-mister/src/port/sdl/sdl_pad.c` — SHM reader implementation (search for `SDLPAD_INPUT_MISTER_SHM`)
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Input/SDL2/SDL2InputDevice.cpp` — where we would splice the SHM read
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp:2771,2786-2790` — wrapper side already opens SHM at `MISTER_JOY_SHM_PATH`, sets magic/version, and **exports the path to the child via `setenv("SONIC_MANIA_JOY_SHM", MISTER_JOY_SHM_PATH, 1)` at line 2789.** The child is meant to read the env var rather than hardcode the path — use this hook.

### Files to create / modify
- **Create** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_joy_shm.h` — copy of `mister_joy_shm.h` with Mania-specific constants:
  - `SONICMANIA_JOY_SHM_DEFAULT_PATH = "/dev/shm/sonicmania-joy"`
  - `SONICMANIA_JOY_SHM_MAGIC = 0x4D414E49` ("MANI")
  - Keep struct binary-compatible with `MisterJoyShm` — only the path/magic constants change.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp`:
  - Switch `MISTER_JOY_SHM_PATH` / `MISTER_JOY_SHM_MAGIC` references (lines 2398, 2771, 2786, 2789-2790) to the new `SONICMANIA_*` constants.
  - Keep the `setenv("SONIC_MANIA_JOY_SHM", ..., 1)` line — it's the contract with the child.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.cpp`:
  - In `Init()`, after `InitInputDevices()`, read `getenv("SONIC_MANIA_JOY_SHM")`. If set and non-empty, `open(O_RDONLY)` + `mmap(PROT_READ, MAP_SHARED)` that path. Cache the pointer in a file-static `g_joy_shm`. Guard on `RSDK_USE_MISTER`. If `getenv` returns null or mmap fails, log once and fall back to SDL2-only.
  - In `ProcessEvents()` (existing, lifted from SDL2 backend, ~line 700+), after the SDL2 pump, poll `g_joy_shm->joy_mask[0]` and inject synthetic `SDL_CONTROLLERBUTTONDOWN`/`UP` events for any state change. Alternative: call the RSDK input layer directly (`InputDeviceFromID` / SDL2 `InputDevice` update hooks). Pick whichever matches the existing shape.
  - In `Release()`, `munmap` if `g_joy_shm` is valid.
- **Modify** `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/platforms/MiSTer.cmake`: add the new `.h` to target_sources for IDE surface (no .cpp — SHM handling is inside MiSTerRenderDevice.cpp).

### Success criteria
- On device: open the MiSTer OSD (F12 equivalent — depends on keyboard config), press D-pad, confirm OSD menu cursor moves while Mania is still running (frozen but not crashed).
- On Mac host: SHM path is guarded out; binary still runs unmodified.
- No input regression: close OSD, gameplay resumes with pad mapping intact.

### Depends on
Step 7 (only if doing the cutscene step freed time). Independent technically.

### What NOT to do
- Do NOT gate game input behind SHM availability — SDL2 gamepad path stays primary; SHM is an *additional* source for wrapper-menu navigation only.
- Do NOT use the 3sx magic `0x33534152` ("3SAR") — the wrapper side is fresh code and a distinct namespace is cleaner.
- Do NOT add a full MiSTer OSD integration (menu hotkey → `core.mgl` → pause-and-save). That's Phase 8+ mod-ecosystem territory.
- Do NOT spin a dedicated thread to poll SHM — poll inside the existing `ProcessEvents` frame hook.

### If it fails
- If SHM attach fails (wrapper not writing): fall back to SDL2-only. Log the path and `errno` once at Init, don't retry.
- If synthetic SDL events collide with real pad events: prioritize real SDL; SHM is an OSD-only overlay.
- Cut-line: this is the last and most optional step. Revert cleanly on any bug that blocks a release.

---

## Release checklist (after the last step lands)

1. `bash tools/mister/build-game.sh --flavor both` succeeds (both flavors cached so dev can switch).
2. `bash tools/mister-wrapper/build-hps.sh` produces `MiSTer_SonicMania`.
3. Quartus RBF present at `build/mister-wrapper-core/Sonic_Mania.rbf` (do NOT rebuild as part of Phase 7; if modified, that's a Phase 4 revisit).
4. `bash tools/mister-wrapper/build-release.sh` (clean-flavor install default) produces a dated ZIP + SHA256 sidecar at `build/mister-release/sonic-mania-mister-<DATE>.zip`.
5. Manual installer test on device: wipe `/media/fat/games/sonic-mania/`, drop in ZIP contents, drop in `Data.rsdk`, boot from menu, play Green Hill Act 1.
6. Tag the commit with `release-$(date -u +%Y-%m-%d)` — no version number per `project-release-naming.md`.
7. Push to the user's own repo (per `feedback-releases-are-ours.md`) and create a GitHub release with the ZIP attached.

---

## Open questions

1. **Save-migration.** Should dev users auto-migrate `SGame.bin` from `/media/fat/games/sonic-mania/` → `./saves/` on first launch post-Step 4? **Recommendation:** no auto-migrate; provide a one-liner in the doc. Fewer failure modes.
2. **libtheora size vs. cutscene benefit.** libtheora.so.0 adds ~120 KB to the release ZIP. Cutscenes are optional. If Step 7 gets cut, do we still bundle libtheora? **Recommendation:** check at implementation time with `readelf -d build/mister-clean-install/bin/RSDKv5U | grep -E 'libtheora|libogg'`. If either SONAME is present in the NEEDED list even with the YUV stubs in place, we must continue bundling. (Expected: yes — `Video.cpp:196-286` calls `th_decode_*` unconditionally; the only way to drop the link is a compile-time `-DRETRO_NO_VIDEO` guard that RSDKv5 does not ship. Confirm don't assume.)
3. **SHM magic churn.** If we change `sonicmania_wrapper.cpp`'s SHM path/magic in Step 8, dev builds already deployed with the older magic will silently stop reading SHM. **Recommendation:** land Steps 7 + 8 together in a single release; don't ship an interim version with the wrapper and engine on different magics.
4. **Settings.ini scope.** Some engine keys (render driver, fullscreen) are no-ops on MiSTer. Do we *suppress writing* them (requires engine patch) or just document them? **Recommendation:** document only; no engine patch. Keeps MiSTer arm minimal.
5. **Date format for releases.** `2026-04-24` (ISO-8601) or `2026Apr24`? **Recommendation:** ISO-8601 for shell-sortability. Confirm with user before tagging.

## Blockers

None identified. All steps have cut-lines. Phase 6 (vsync + perf) does not gate Phase 7; any outstanding Phase 6 work can land in parallel.

---

## References

- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-plan.md` — Phase 7 scope table (lines 266–278)
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-port-research.md` §2.10, §4.5
- `/Users/sb/Developer/sonic-mania-mister/docs/mister-runbook.md` — Phase 0–4 operational state
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/Graphics/MiSTer/MiSTerRenderDevice.{cpp,hpp}`
- `/Users/sb/Developer/sonic-mania-mister/dependencies/RSDKv5/RSDKv5/RSDK/User/Core/UserStorage.cpp:1150–1171`
- `/Users/sb/Developer/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_wrapper.cpp`
- `/Users/sb/Developer/3sx-mister/tools/mister/release-readme.txt` — canonical release README structure
- `/Users/sb/Developer/3sx-mister/vendor/Main_MiSTer/mister_joy_shm.h`
