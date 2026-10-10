#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""E1 interrupt entries per frame, from MAME (scripts/mame/irqcount.lua says how they are seen).

    python scripts/mame_irqcount.py <set> [<set> ...] [--frames 3000]

Prints, per set, the total entries per trap over the run, how many frames had any, and the
timer registers at the end. Raw counts in debug/irq/<set>.txt.
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

NAMES = ["timer", "INT1", "INT2", "INT3", "INT4"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--frames", type=int, default=3000)
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    for game in a.sets:
        out = REPO / "debug" / "irq" / f"{game}.txt"
        out.parent.mkdir(parents=True, exist_ok=True)
        (out.parent / "lua_error.txt").unlink(missing_ok=True)
        with tempfile.TemporaryDirectory() as nv:
            env = dict(os.environ, **lua_env(regions(game)), **lua_runner_env("irqcount.lua"),
                       CORE_OUT=out.parent.as_posix(), IC_OUT=out.as_posix(), IC_FRAMES=str(a.frames))
            cmd = mame_cmd(exe, game, "irqcount.lua", mame_dir,
                           ["-nvram_directory", nv, "-nodrc", "-seconds_to_run", str(a.frames // 60 + 60)])
            subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
        check_lua_error(out.parent)
        lines = out.read_text().splitlines()
        rows = [list(map(int, ln.split()[1:])) for ln in lines if ln.startswith("F ")]
        regs = " ".join(f"{ln.split()[1]}={ln.split()[2]}" for ln in lines if ln.startswith("reg "))
        tot = [sum(r[i + 1] for r in rows) for i in range(5)]
        fr = [sum(1 for r in rows if r[i + 1]) for i in range(5)]
        print(f"{game}: {len(rows)} frames; " + ", ".join(f"{NAMES[i]} {tot[i]} in {fr[i]} frames"
                                                       for i in range(5)) + f"; {regs}")


if __name__ == "__main__":
    main()
