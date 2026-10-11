# `rtl/video` provenance

| File | Source | Changes |
|---|---|---|
| `screen_rotate_two.sv` | `Arcade-Vamphalf_MiSTer/rtl/video/screen_rotate_two.sv` (commit in `scripts/vendor.json`): Sorgelig's HDMI rotator from the MiSTer arcade cores, GPL-2.0-or-later (its header) | none |
| `crt_adjust.sv` | `Arcade-Vamphalf_MiSTer/rtl/video/crt_adjust.sv` (commit in `scripts/vendor.json`): rmonic79's CRT Adjust from Arcade-Raiden_MiSTer, by way of Arcade-Fuuki_MiSTer and Arcade-Seta_MiSTer, GPL-3.0-or-later | none here; its header records Seta's one change (`hoff_s`'s zero branch signed) |
| `eo_crt.sv` | `Arcade-Vamphalf_MiSTer/rtl/video/vh_crt.sv` at `c3f3256` (from Seta's `seta_crt.sv`) | the raster's totals as parameters (`VTOTAL` was 264), Eolith's 455 x 262 at 8 clk a dot |
