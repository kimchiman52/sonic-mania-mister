# Main_MiSTer Vendor Metadata (Sonic Mania fork)

- Source repository: `https://github.com/MiSTer-devel/Main_MiSTer.git`
- Pinned commit (inherited from 3sx-mister): `3380931329b8acb442bd3d35a24d89f88641b7cf`
- Overlay fork source: `3sx-mister/vendor/Main_MiSTer` (the 3S-ARM wrapper overlay)
- Import intent: `MiSTer_SonicMania` HPS wrapper foundation
- Local vendor path: `vendor/Main_MiSTer`

This snapshot is an overlay, not a full vendored copy. The full pinned upstream tree is fetched on
demand by `tools/mister-wrapper/build-hps.sh`; the `vendor/Main_MiSTer` overlay files are applied on
top before compilation.

The overlay subset was renamed from 3sx-mister's `thirdsarm_*` files to `sonicmania_*` for this
project. See `tools/mister-wrapper/main-mister-overlay.files` for the authoritative manifest.

Key overlay edits from 3sx-mister:
- `sonicmania_wrapper.{cpp,h}`: renamed from `thirdsarm_wrapper.{cpp,h}`, with constants
  retargeted to `/media/fat/games/sonic-mania/` and `Sonic Mania` core name.
- `sonicmania_main.cpp`, `sonicmania_core_context.{cpp,h}`, `sonicmania_support_stubs.cpp`:
  mechanical rename of 3sx sources.
- `video.cpp`: `core_CLK_VIDEO` hardcode updated from `405.0/13.0` (31.1538 MHz, 3S-ARM PLL) to
  `1550.0/63.0` (24.6032 MHz, Sonic Mania PLL). Required for correct S-Video YC subcarrier phase.
