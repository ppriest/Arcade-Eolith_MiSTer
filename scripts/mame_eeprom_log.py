#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The Gradation 2D's 93C66 pin traffic from MAME, for sim/ee_tb (scripts/mame/eeprom_log.lua).

    python scripts/mame_eeprom_log.py hidnctch [--frames 1200] [--out debug/ee/hidnctch.log]
    python scripts/mame_eeprom_log.py hidnctch --nvram DIR    # start from DIR's EEPROM, not a blank one

The EEPROM starts blank (an empty -nvram_directory) unless --nvram is given; MAME saves the new
contents there on exit when --keep-nvram names a directory to keep.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--frames", type=int, default=1200)
    ap.add_argument("--out", default=None)
    ap.add_argument("--nvram", default=None, help="an nvram directory to start from (copied)")
    ap.add_argument("--keep-nvram", default=None, help="keep the run's nvram directory here")
    a = ap.parse_args()
    mame_dir, exe = mame_paths()
    out = Path(a.out) if a.out else REPO / "debug" / "ee" / f"{a.game}.log"
    out = out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    (out.parent / "lua_error.txt").unlink(missing_ok=True)
    with tempfile.TemporaryDirectory() as nv:
        if a.nvram:
            shutil.copytree(a.nvram, nv, dirs_exist_ok=True)
        env = dict(os.environ, **lua_env(regions(a.game)), **lua_runner_env("eeprom_log.lua"),
                   CORE_OUT=out.parent.as_posix(), EE_OUT=out.as_posix(), EE_FRAMES=str(a.frames))
        cmd = mame_cmd(exe, a.game, "eeprom_log.lua", mame_dir,
                       ["-nvram_directory", nv, "-seconds_to_run", str(a.frames // 60 + 60)])
        r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
        if a.keep_nvram:
            shutil.copytree(nv, a.keep_nvram, dirs_exist_ok=True)
    check_lua_error(out.parent)
    if "EEPROM_LOG_OK" not in r.stdout:
        sys.exit(f"MAME did not finish the run:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    lines = out.read_text().splitlines()
    nw = sum(1 for ln in lines if ln.startswith("W "))
    print(f"{a.game}: {nw} system control writes, {len(lines) - nw} IN0 reads in {a.frames} frames -> {out}")


if __name__ == "__main__":
    main()
