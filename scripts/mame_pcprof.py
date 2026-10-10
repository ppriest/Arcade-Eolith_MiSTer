#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Instructions per frame and where the main CPU spends them, from a MAME PC trace.

    python scripts/mame_pcprof.py <set> [--start 600] [--frames 60] [--coin 0] [--top 12]

Runs scripts/mame/pcprof.lua under -debug -nodrc and prints, per frame, instructions executed
(MAME's folded loops expanded), 0xfc000000 reads and buffer flips; then the PCs with the most
instructions over the window. Instruction counts are MAME's; MAME's E1 timing has no bus wait
states. The trace is kept in debug/pcprof/ (gitignored).
"""
import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402

LOOP = re.compile(r"\(loops for (\d+) instructions\)")


def run(game, start, frames, coin, out):
    mame_dir, exe = mame_paths()
    out.parent.mkdir(parents=True, exist_ok=True)
    for p in (out, Path(str(out) + ".done")):
        if p.exists():
            p.unlink()
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_env(regions()), **lua_runner_env("pcprof.lua"),
                   CORE_OUT=out.parent.as_posix(), PP_OUT=out.as_posix(),
                   PP_START=str(start), PP_FRAMES=str(frames), PP_COIN=str(coin))
        cmd = mame_cmd(exe, game, "pcprof.lua", mame_dir,
                       ["-nvram_directory", nv, "-nodrc", "-seconds_to_run", "3600"])
        cmd[cmd.index("-nodebug")] = "-debug"
        subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out.parent)
    if not Path(str(out) + ".done").exists():
        sys.exit(f"{game}: no completion marker")


def parse(path):
    frames, cur = [], {"instr": 0, "reads": 0, "flips": 0}
    hist = collections.Counter()
    last_pc = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("# V"):
                frames.append(cur)
                cur = {"instr": 0, "reads": 0, "flips": 0}
            elif line.startswith("# R"):
                cur["reads"] += 1
            elif line.startswith("# S"):
                cur["flips"] += 1
            else:
                m = LOOP.search(line)
                if m:
                    k = int(m.group(1))
                    cur["instr"] += k
                    if last_pc is not None:
                        hist[last_pc] += k
                elif len(line) > 9 and line[8] == ":":
                    last_pc = line[:8]
                    cur["instr"] += 1
                    hist[last_pc] += 1
    return frames, hist


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--start", type=int, default=600)
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--parse-only", action="store_true")
    a = ap.parse_args()
    out = REPO / "debug" / "pcprof" / f"{a.game}_{a.start}_{a.frames}{'_play' if a.coin else ''}.trace"
    if not a.parse_only:
        run(a.game, a.start, a.frames, a.coin, out)
    frames, hist = parse(out)
    print(f"{a.game}: frames {a.start}..{a.start + len(frames)}")
    for i, fr in enumerate(frames):
        print(f"  {a.start + i + 1:5d} instr {fr['instr']:8d}  reads {fr['reads']:6d}  flips {fr['flips']}")
    total = sum(hist.values())
    print(f"top PCs of {total} instructions:")
    for pc, c in hist.most_common(a.top):
        print(f"  {pc} {c:10d} {100 * c / total:5.1f}%")


if __name__ == "__main__":
    main()
