#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The QS1000's register writes with their 750 kHz ticks from MAME, with cheats, for scripts/qs1000_render.py
and scripts/qs1000_pcb_evidence.py (scripts/mame/qs1000_capture.lua).

    python scripts/qs1000_capture.py wivernwg --frames 21600 --coin 300 --fire 600 --latch 1500 \\
        --poke C9BCF=01,C9BD3=00,C9BA3=0A --out debug/qs1000_pcb/wv_cheat

--poke: bytes written to the main CPU's program space every frame (a MAME cheat's "run" actions:
wivernwg's P1 Invincibility is C9BCF=01, C9BD3=00, P1 Infinite Lives C9BA3=0A, from Pugsy's cheat.7z).
Writes <out>/<set>_wave.txt and MAME's audio as <out>/<set>.wav.
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_runner_env, mame_cmd, mame_paths  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--fire", type=int, default=0)
    ap.add_argument("--latch", default="")
    ap.add_argument("--latch-space", default="io")
    ap.add_argument("--poke", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "lua_error.txt").unlink(missing_ok=True)
    mame_dir, exe = mame_paths()
    env = dict(os.environ, **lua_runner_env("qs1000_capture.lua"), CORE_OUT=out.as_posix(),
               QC_OUT=(out / f"{a.set}_wave.txt").as_posix(), QC_FRAMES=str(a.frames), QC_COIN=str(a.coin),
               QC_FIRE=str(a.fire), QC_LATCH=a.latch, QC_LATCH_SPACE=a.latch_space, QC_POKES=a.poke)
    nv = out / "nvram"
    nv.mkdir(exist_ok=True)
    cmd = mame_cmd(exe, a.set, "qs1000_capture.lua", mame_dir,
                   ["-wavwrite", (out / f"{a.set}.wav").as_posix(), "-samplerate", "48000",
                    "-nvram_directory", nv.as_posix()])
    r = subprocess.run(cmd, cwd=str(mame_dir), env=env, capture_output=True, text=True, timeout=7200, **NO_WINDOW)
    check_lua_error(out)
    if "QC_OK" not in r.stdout:
        sys.exit(f"MAME said:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    w = out / f"{a.set}_wave.txt"
    print(f"{w}: {sum(1 for ln in w.open() if ln.startswith('W '))} writes")


if __name__ == "__main__":
    main()
