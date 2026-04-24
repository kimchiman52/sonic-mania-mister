# Menu_MiSTer Vendor Metadata (Sonic Mania fork)

- Source repository: `https://github.com/MiSTer-devel/Menu_MiSTer.git`
- Pinned commit (inherited via 3S-ARM seed): `b0a2b9298d7a7a355e4e0a97277d3d4218eb2f55`
- Seed fork source: `3sx-mister/vendor/Menu_MiSTer` (the Menu-derived native-video wrapper used to ship 3S-ARM.rbf)
- Local vendor path: `vendor/Menu_MiSTer`
- Import date: `2026-04-24`
- Notes:
  - Forked from the `3S-ARM` Quartus project (Menu_MiSTer seed + native_video_* RTL additions from 3sx-mister) and re-parameterized for Sonic Mania.
  - Staged builds rename the project from `menu` to `Sonic_Mania` (underscore, for Quartus PROJECT_REVISION compatibility) and patch the visible `CONF_STR` to `"Sonic Mania;;"`.
  - Parameter changes from 3S-ARM → Sonic Mania (per `docs/phase-4-plan.md` §0):
    - `native_video_timing.sv`: 384x224 @ 59.5995 Hz → 320x240 @ 59.587 Hz (H_TOTAL=391, V_TOTAL=264)
    - `native_video_reader.sv`: 768 B/line burst → 640 B/line (80 beats); V_ACTIVE 224 → 240; BUF1_ADDR `0x07405440` → `0x07404B20`
    - `pll_video/pll_video_0002.v`: output_clock_frequency0 31.153846 MHz → 24.603175 MHz (target M=62 / N=3 / C=42)
  - Excluded upstream `.git/`, Quartus `db/`, `incremental_db/`, `output_files/` from the vendored copy.
