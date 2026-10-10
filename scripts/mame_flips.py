#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""MAME's frame-buffer flip cadence, the reference for the core's flip probes (rtl/debug/eo_perf.sv).

    python scripts/mame_flips.py hidnctch [--frames 600] [--coin 400] [--start 470] [--from 240]

Runs scripts/mame/flips.lua and prints, over frames --from to --frames, the flips and the gaps between them
in eo_perf's buckets (1, 2, 3, 4+ frames), the form `sys_tb +perf=1` and `read_issp.py F` print. The per-frame
log is in debug/flips/<set>.txt.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402
from build_mra import SETS, BOARD_VEGA, BOARD_GRAD  # noqa: E402

# the buffer bit's register per board (vegaeo.cpp 105, eolith.cpp 285, eolith16.cpp 65)
FLIP = {BOARD_VEGA: ("fca00000", 0), BOARD_GRAD: ("fc400000", 7), 2: ("ffe80000", 7)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--coin", type=int, default=-1)
    ap.add_argument("--start", type=int, default=-1)
    ap.add_argument("--from", dest="first", type=int, default=1)
    a = ap.parse_args()
    addr, bit = FLIP[SETS[a.set][2]]
    out = (REPO / "debug" / "flips" / f"{a.set}.txt").resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    (out.parent / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_env(regions(a.set)), **lua_runner_env("flips.lua"),
                   CORE_OUT=out.parent.as_posix(), FL_OUT=out.as_posix(), FL_ADDR=addr, FL_BIT=str(bit),
                   FL_LEN="2" if SETS[a.set][2] == 2 else "4",
                   FL_FRAMES=str(a.frames), FL_COIN=str(a.coin), FL_START=str(a.start))
        r = subprocess.run(mame_cmd(exe, a.set, "flips.lua", mame_dir,
                                    ["-nvram_directory", nv, "-seconds_to_run", str(a.frames // 60 + 60)]),
                           cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out.parent)
    if "FLIPS_OK" not in r.stdout:
        sys.exit("MAME did not finish the run")
    per = [tuple(map(int, ln.split())) for ln in out.read_text().splitlines()]
    gaps = {1: 0, 2: 0, 3: 0, 4: 0}
    flips, gap, max_gap = 0, 0, 0
    for frame, k in per:
        gap += 1
        if frame < a.first:
            gap = 0 if k else gap
            continue
        for _ in range(k):
            flips += 1
            gaps[min(max(gap, 1), 4)] += 1
            max_gap = max(max_gap, gap)
            gap = 0
    n = a.frames - a.first + 1
    print(f"{a.set}: frames {a.first}-{a.frames} ({n}): flips {flips} gaps 1:{gaps[1]} 2:{gaps[2]} 3:{gaps[3]} "
          f"4+:{gaps[4]} max {max_gap}")


if __name__ == "__main__":
    main()
