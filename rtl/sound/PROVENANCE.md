# rtl/sound provenance

The OKI M6295 of `eolith16.cpp` (`rtl/sound/eo_oki.sv`). All files are GPL-3.0-or-later, as this
repository (`LICENSE`); each is pinned in `scripts/vendor.json` and checked by `scripts/vendor_sync.py`.

| Path | Source | Changes |
|---|---|---|
| `jt6295/hdl/jt6295*.v`, `jt6295/LICENSE` | Arcade-Vamphalf_MiSTer `rtl/sound/jt6295` at `d659234` (jotego's JT6295 as Arcade-Fuuki_MiSTer vendored it; Vamphalf's `rtl/sound/PROVENANCE.md`) | none |
| `sample_cache.sv`, `oki_rom_bridge.sv` | Arcade-Vamphalf_MiSTer `rtl/sound/` at `d659234` (from Arcade-Fuuki_MiSTer; the cache ported there from the Psikyo core) | none |

jt6295's ROM bus expects a byte within two of its internal slots of the address changing; the bridge holds
each request and the cache keeps a 64-bit granule per channel resident with next-granule prefetch, so the
deadline is met from the cache rather than from SDRAM (Vamphalf's `rtl/sound/PROVENANCE.md`).
