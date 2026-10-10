# rtl/e1 provenance

Copied from `Arcade-Vamphalf_MiSTer/rtl/e1/` (GPL-3.0). The commit each file was taken at is in
`scripts/vendor.json`; `python scripts/vendor_sync.py` reports a local edit to a `copy` file (an error) and
any upstream commit since. `e1_cpu.sv` and `e1_regram.sv` are unchanged copies.

`e1_pipe.sv` is `track`: timing changes for this core's 57.27 MHz `clk_sys` (Vamphalf runs it at 56 MHz),
each marked `[EO]`, behaviour unchanged. The register-write queue is a ring whose positions are not reset
when it empties, and its head is read from the start-of-clock positions. The single result write of the
ALU, move and set instructions is pushed once, after the execute code, at the start-of-clock position.
STW.S queues its base update before the register-file store; the zero-pointer update of the
register-indirect forms sits inside its own branch. Vamphalf's later changes are merged by hand
(`vendor_sync.py --diff rtl/e1/e1_pipe.sv`); the `[EO]` changes are candidates to go back upstream.

Origin: written in Vamphalf from MAME's E1 interpreter (`src/devices/cpu/e132xs/e132xs.cpp`,
`e132xsop.hxx`, `e1defs.h`; BSD-3-Clause, copyright-holders Pierpaolo Prazzoli and the MAME team).
Its verification (conformance suite, MAME traces) is in Vamphalf's `docs/ROADMAP.md`; this core's
checks on Eolith code are in `docs/ROADMAP.md`, Phase 0.
