# MiSTer RBF Naming Convention

Every FPGA core RBF that ships under `/media/fat/_Other/` (or `_Console/`,
`_Computer/`, etc.) follows the standard MiSTer convention:

```
<CoreName>_YYYYMMDD.rbf
```

The 8-digit date is the build date in `YYYYMMDD` form. Real-world examples
from a stock MiSTer SD card:

```
Atari800_20260325.rbf
C64_20250828.rbf
AcornAtom_20251001.rbf
NeoGeo_20240502.rbf
```

## Why dates

MiSTer firmware looks for files matching `<prefix>_*.rbf` and **picks the
newest dated file** when multiple exist. That means:

- Multiple revisions can coexist in `_Other/` without ambiguity.
- Rolling back is `mv NewName_YYYYMMDD.rbf .disabled`; firmware falls back to
  the next-newest.
- Update servers (e.g. update_all.sh, downloader scripts) detect new
  versions by date comparison, not checksum.
- Casual users see a clear changelog by listing the directory.

Skipping the date suffix is technically valid (firmware will still load
`Sonic_Mania.rbf`) but breaks all of the above. We do **not** ship undated
RBFs.

## Sonic Mania RBFs

This port ships two variants from one source tree. **16:9 is the default**
(most users have modern displays); **4:3 is the named variant** for CRT
users.

| Filename | Aspect | CONF_STR header | MiSTer.ini section |
|---|---|---|---|
| `Sonic_Mania_YYYYMMDD.rbf` | 16:9 widescreen (default) | `Sonic Mania;...` | `[Sonic Mania]` |
| `Sonic_Mania_43_YYYYMMDD.rbf` | 4:3 (named) | `Sonic Mania (4:3);...` | `[Sonic Mania (4:3)]` |

The `_43` marker in the 4:3 filename is required — the wrapper's
`detect_aspect_from_rbf()` substring-matches it (along with `(4:3)`,
`(4-3)`, `4x3`) and emits `SONIC_MANIA_ASPECT=4:3` to the engine.
Absence of any aspect marker resolves to widescreen (the default).

The MiSTer.ini section name comes from the **CONF_STR header**, NOT the
filename. So renaming an RBF on disk doesn't break the section match —
the firmware looks up `[Sonic Mania]` because that's what the core's
CONF_STR declares as its first token.

## Build flow

`tools/mister-wrapper/build-core.sh` produces dated RBFs automatically.
The default `--aspect` is `16:9` (post-Phase-10c default-swap):

```
$ ./tools/mister-wrapper/build-core.sh                # default = 16:9
$ ./tools/mister-wrapper/build-core.sh --aspect 16:9  # explicit
# -> build/mister-wrapper-core/Sonic_Mania_20260426.rbf
# -> build/mister-wrapper-core/Sonic_Mania.rbf  (symlink to latest)

$ ./tools/mister-wrapper/build-core.sh --aspect 4:3
# -> build/mister-wrapper-core/Sonic_Mania_43_20260426.rbf
# -> build/mister-wrapper-core/Sonic_Mania_43.rbf  (symlink to latest)
```

The undated `Sonic_Mania.rbf` / `Sonic_Mania_169.rbf` symlinks always
point at the most recent build of that aspect variant — convenient for
deploy scripts and CI to grab the latest without recomputing the date.

Override the date via `MISTER_BUILD_DATE` if you need reproducible output:

```
$ MISTER_BUILD_DATE=20260426 ./tools/mister-wrapper/build-core.sh --aspect 4:3
```

## Deploy

`tools/mister-wrapper/deploy-step5.sh` resolves the symlink (or
glob-newest) and copies the dated file onto the MiSTer device, preserving
the date in the destination filename:

```
build/mister-wrapper-core/Sonic_Mania_20260426.rbf
  -> /media/fat/_Other/Sonic_Mania_20260426.rbf
```

When deploying a new build, **old undated copies (`Sonic Mania.rbf`,
`Sonic Mania (16-9).rbf`) should be removed manually** the first time —
they predate this convention and will show up as duplicate menu entries
otherwise. After cleanup, every subsequent deploy adds a new dated file
and MiSTer auto-picks the newest.

## When this convention applies

Every time a new RBF is built and deployed. The date is stamped at
build-script invocation time (`date +%Y%m%d` in the build host's locale).

For builds in colima/Docker that spans midnight, the date should be set
via `MISTER_BUILD_DATE` so the artifact reflects the build *start* date,
not the moment `cp` ran.
