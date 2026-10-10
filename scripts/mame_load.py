#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Per-frame CPU load and memory traffic of Eolith sets, from MAME.

    python scripts/mame_load.py <set> [<set> ...] [--frames 1800] [--coin 600] [--out debug/load]

Runs scripts/mame/load.lua and prints, per set:
  work   fraction of each frame the main CPU is not in its vblank wait, at MAME's E1 timing
         (no bus wait states: a lower bound on the chip's load); a frame with no wait is saturated
  traffic per frame: VRAM write accesses and halfwords stored, data-ROM reads, buffer flips, and
         VRAM traffic at or beyond line 240
The vblank wait is the set's PC in MAME's eolith_speedup.cpp table (stealsee: the PC in
stealsee_speedup_vblank_r); load.lua says how it is timed.
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (NO_WINDOW, check_lua_error, load_env, lua_env, lua_runner_env,  # noqa: E402
                          mame_cmd, mame_paths, regions)

STEALSEE_IDLE = 0x400081EC  # eolith_speedup.cpp stealsee_speedup_vblank_r

# Other boards of the family: load.lua's taps, from each driver's address map. The VRAM counters
# assume eolith.cpp's 16-bit pixels; on these boards only work, ROM reads and flips mean anything.
BOARD = {
    # vegaeo.cpp vega_map 116-129: VRAM 0x80000000, custom read 0xfcc00000, buffer bit 0 at 0xfca00000
    "crazywar": dict(LD_VRAM_LO="80000000", LD_VRAM_HI="80013fff", LD_CUSTOM="fcc00000",
                     LD_FLIP="fca00000", LD_FLIP_BIT="0"),
    # eolith16.cpp eolith16_map 79-92: VRAM bank 0x50000000, ROM 0xff000000, custom 0xffea0000,
    # buffer bit 7 of the EEPROM write at 0xffe80000; 16-bit bus
    "klondkp": dict(LD_VRAM_LO="50000000", LD_VRAM_HI="5000ffff", LD_ROM_LO="ff000000",
                    LD_ROM_HI="ff1fffff", LD_CUSTOM="ffea0000", LD_CUSTOM_HI="ffea0001",
                    LD_FLIP="ffe80000", LD_FLIP_BIT="7"),
}


def idle_pcs():
    src = Path(os.environ.get("MAME_SRC", load_env().get("MAME_SRC", "")))
    text = (src.parent / "eolith_speedup.cpp").read_text(encoding="utf-8")
    table = {m.group(1): int(m.group(2), 16)
             for m in re.finditer(r'\{\s*"(\w+)",\s*0x([0-9a-fA-F]+)', text)}
    table["stealsee"] = STEALSEE_IDLE
    return table


def run(game, frames, coin, out, idle_pc):
    mame_dir, exe = mame_paths()
    r = regions()
    inp = r.get("inputs", {})
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_env(r), **lua_runner_env("load.lua"),
                   CORE_OUT=out.parent.as_posix(), LD_OUT=out.as_posix(),
                   LD_FRAMES=str(frames), LD_COIN=str(coin), LD_IDLE_PC=f"{idle_pc:x}",
                   LD_IN_COIN=inp.get("coin", "Coin 1"), LD_IN_START=inp.get("start", "1 Player Start"),
                   LD_IN_HOLD=inp.get("hold", "P1 Right"), LD_IN_PULSE=inp.get("pulse", "P1 Button 1"),
                   LD_COIN_PERIOD=str(inp.get("coin_period", 97)),
                   LD_START_PERIOD=str(inp.get("start_period", 211)),
                   LD_PRESS_LEN=str(inp.get("press_len", 5)), **BOARD.get(game, {}))
        cmd = mame_cmd(exe, game, "load.lua", mame_dir,
                       ["-nvram_directory", nv, "-seconds_to_run", str(frames // 60 + 60)])
        subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out.parent)


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p / 100 * len(xs)))] if xs else 0


def summarise(game, path, skip):
    lines = path.read_text().splitlines()
    if not lines or lines[-1] != "done":
        print(f"{game}: incomplete run ({path})")
        return
    fr, pcs, vmax, regs = [], {}, None, {}
    for ln in lines:
        t = ln.split()
        if t[0] == "F":
            fr.append([int(t[1]), float(t[2])] + list(map(int, t[3:])))
        elif t[0] == "vmax":
            vmax = (int(t[1]), int(t[2]))
        elif t[0] == "reg":
            regs[t[1]] = t[2]
        elif t[0] == "pc":
            pcs[t[1]] = int(t[2])
    fs = [x for x in fr if x[0] > skip]
    n = len(fs)
    work = [1.0 - min(x[1], 1.0) for x in fs]
    sat = sum(1 for w in work if w >= 0.999)
    print(f"\n{game}: {n} frames after frame {skip}")
    print(f"  work, fraction of a frame: mean {statistics.mean(work):.3f}  median {statistics.median(work):.3f}"
          f"  p95 {pct(work, 95):.3f}  saturated {sat} ({100 * sat / n:.1f}%)")
    for i, name in ((2, "vram write acc"), (3, "vram halfwords"), (4, "vram dropped"),
                    (5, "vram read acc"), (6, "rom read acc"), (7, "rom bytes"), (8, "flips"),
                    (9, "offscreen hw"), (10, "offscreen rd")):
        col = [x[i] for x in fs]
        print(f"  {name:15s} median {statistics.median(col):>9.0f}  p95 {pct(col, 95):>9}  max {max(col):>9}")
    print(f"  game frame rate: {sum(x[8] for x in fs) / n * 60:.1f} buffer flips per second")
    if vmax:
        print(f"  highest VRAM halfword stored 0x{vmax[0]:x} (line {vmax[0] // 336}), "
              f"read 0x{vmax[1]:x} (line {vmax[1] // 336})")
    if regs:
        print("  " + "  ".join(f"{k}={v}" for k, v in regs.items()))
    top = sorted(pcs.items(), key=lambda kv: -kv[1])[:4]
    print("  vblank-port readers: " + ", ".join(f"{pc}x{c}" for pc, c in top))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=600, help="first coin frame; 0 = attract only")
    ap.add_argument("--skip", type=int, default=300, help="frames of boot left out of the summary")
    ap.add_argument("--out", default=str(REPO / "debug" / "load"))
    ap.add_argument("--summary-only", action="store_true")
    a = ap.parse_args()
    pcs = idle_pcs()
    for game in a.sets:
        tag = f"{game}_{'play' if a.coin else 'attract'}"
        out = Path(a.out) / f"{tag}.txt"
        if not a.summary_only:
            run(game, a.frames, a.coin, out, pcs.get(game, 0))
        summarise(tag, out, a.skip)


if __name__ == "__main__":
    main()
