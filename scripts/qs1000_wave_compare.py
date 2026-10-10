#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The sound board against MAME: latch commands and wavetable register writes, in order.

    python scripts/qs1000_wave_compare.py <set> --mame-out debug/snd/mame_wave.txt [--coin 400 --start 500]
                                         --rtl debug/snd/rtl_wave.txt [--frames 1200]

Captures MAME's log with scripts/mame/qs1000_wave.lua (unless --no-capture), then compares it with
sim/sys_tb's +wave log. Timing is not compared (the core runs behind MAME): the latch commands must be
the same sequence, and the register writes between one command and the next the same sequence too,
for every command both logs reach.
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402

LATCH = {"crazywar": "fc600000", "hidnctch": "fc800000"}


def parse(path):
    """-> [(latch byte, [(off, data), ...]), ...]; writes before the first command under None."""
    segs = [(None, [])]
    for ln in Path(path).read_text().splitlines():
        t = ln.split()
        if not t:
            continue
        if t[0] == "L":
            segs.append((int(t[2], 16), []))
        elif t[0] == "W":
            segs[-1][1].append((int(t[2], 16), int(t[3], 16)))
    return segs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--mame-out", required=True)
    ap.add_argument("--rtl", required=True)
    ap.add_argument("--coin", type=int, default=400)
    ap.add_argument("--start", type=int, default=500)
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--coinrep", type=int, default=0)
    ap.add_argument("--startrep", type=int, default=0)
    ap.add_argument("--no-capture", action="store_true")
    a = ap.parse_args()
    out = Path(a.mame_out).resolve()
    if not a.no_capture:
        mame_dir, exe = mame_paths()
        out.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as nv:
            env = dict(os.environ, **lua_env(regions(a.set)), **lua_runner_env("qs1000_wave.lua"),
                       CORE_OUT=out.parent.as_posix(), WV_OUT=out.as_posix(), WV_LATCH=LATCH[a.set],
                       WV_COIN=str(a.coin), WV_START=str(a.start), WV_FRAMES=str(a.frames),
                       WV_COINREP=str(a.coinrep), WV_STARTREP=str(a.startrep))
            subprocess.run(mame_cmd(exe, a.set, "qs1000_wave.lua", mame_dir,
                                    ["-nvram_directory", nv, "-seconds_to_run", str(a.frames // 60 + 60)]),
                           cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    m, r = parse(out), parse(a.rtl)
    mc, rc = [s[0] for s in m[1:]], [s[0] for s in r[1:]]
    print(f"latch commands: MAME {len(mc)}, core {len(rc)}")
    n = min(len(mc), len(rc))
    first = next((i for i in range(n) if mc[i] != rc[i]), None)
    if first is not None:
        print(f"command {first} differs: MAME {mc[first]:02x}, core {rc[first]:02x}")
        n = first
    else:
        print(f"the first {n} commands agree: {' '.join(f'{c:02x}' for c in mc[:n])}")
    same_w = total_w = 0
    for i in range(n + 1):
        mw, rw = m[i][1], r[i][1]
        # the segment after the last compared command may still be running in either log
        if i == n:
            k = min(len(mw), len(rw))
            mw, rw = mw[:k], rw[:k]
        k = next((j for j in range(min(len(mw), len(rw))) if mw[j] != rw[j]), None)
        if k is None and len(mw) == len(rw):
            same_w += len(mw)
        else:
            k = k if k is not None else min(len(mw), len(rw))
            print(f"after command {i - 1}: register write {k} differs "
                  f"(MAME {len(mw)} writes, core {len(rw)}): MAME {mw[k:k+3]}, core {rw[k:k+3]}")
            same_w += k
        total_w += max(len(mw), len(rw))
    print(f"register writes in agreement: {same_w} of {total_w}")


if __name__ == "__main__":
    main()
