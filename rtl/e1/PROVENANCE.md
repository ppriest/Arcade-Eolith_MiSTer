# rtl/e1 provenance

Copied unchanged from `Arcade-Vamphalf_MiSTer/rtl/e1/` (GPL-3.0). The commit each file was taken at
is in `scripts/vendor.json`; `python scripts/vendor_sync.py` reports a local edit (an error) and any
upstream commit since. The CPU is changed in Vamphalf, then copied here with `vendor_sync.py --update`.
The register-write queue and operand forwarding timing changes in `e1_pipe.sv` were made in this core
(`449df7c`, `3f882db`, for its 57.27 MHz `clk_sys`) and went upstream as Vamphalf `8f1f21c`.

Origin: written in Vamphalf from MAME's E1 interpreter (`src/devices/cpu/e132xs/e132xs.cpp`,
`e132xsop.hxx`, `e1defs.h`; BSD-3-Clause, copyright-holders Pierpaolo Prazzoli and the MAME team).
Its verification (conformance suite, MAME traces) is in Vamphalf's `docs/ROADMAP.md`; this core's
checks on Eolith code are in `docs/ROADMAP.md`, Phase 0.
