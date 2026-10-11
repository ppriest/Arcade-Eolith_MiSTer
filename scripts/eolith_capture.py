#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Frame-buffer captures from MAME for scripts/render_model.py.

    python scripts/eolith_capture.py <set> [--frames 300,600,...] [--coin 400] [--out DIR]

Runs scripts/mame/vcap.lua (what it writes and why is in its header). Default output:
debug/<set>-vcap/ (gitignored). The board's save-item names and palette address come from BOARD.
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
from mame_capture import (NO_WINDOW, check_lua_error, lua_env, lua_runner_env,  # noqa: E402
                          mame_cmd, mame_paths, regions)

BOARD = {
    # vegaeo.cpp: m_vram uint8[0x28000] (168), m_vbuffer (105); palette 0xfc200000, umask32 0x0000ffff (121)
    "crazywar": dict(VC_VRAM_ITEM="m_vram", VC_BUF_ITEM="m_vbuffer",
                     VC_PAL_BASE="fc200000", VC_PAL_STEP="4", VC_PAL_N="256"),
    # eolith.cpp: m_vram uint16[0x40000] (227-228), m_buffer (229), not listed as save items: copied by
    # vcap.lua's write taps; RGB555 direct, no palette
    "hidnctch": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "linkypip": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "hidctch2": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "ironfort": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "puzzlekg": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "candy": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "landbrk": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "penfan": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "stealsee": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "fort2b": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "hidctch3": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    "raccoon": dict(VC_MIRROR="eolith", VC_PAL_N="0"),
    # eolith16.cpp: m_vram, the memory share "vram" (uint8[0x20000], 34), the CPU's half the entry of
    # "vrambank" (125-129); the fixed palette, none to read
    "klondkp": dict(VC_SHARE=":vram", VC_BANK=":vrambank", VC_PAL_N="0"),
}
DEFAULT_FRAMES = [120, 300, 450, 600, 750, 900, 1050, 1200, 1350, 1500, 1650, 1800,
                  1950, 2100, 2250, 2400, 2550, 2700, 2850, 3000]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("--frames", default=",".join(map(str, DEFAULT_FRAMES)))
    ap.add_argument("--coin", type=int, default=400, help="first coin frame (0 = attract only)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--pulse", default=None, help="input field pulsed in play (default: regions.json's)")
    a = ap.parse_args()
    if a.set not in BOARD:
        sys.exit(f"no BOARD entry for {a.set}")
    out = (Path(a.out) if a.out else REPO / "debug" / f"{a.set}-vcap").resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    r = regions(a.set)
    inp = r.get("inputs", {})
    mame_dir, exe = mame_paths()
    frames = sorted(int(x) for x in a.frames.split(","))
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_env(r), **lua_runner_env("vcap.lua"), **BOARD[a.set],
                   CORE_OUT=out.as_posix(), VC_OUT=out.as_posix(),
                   VC_FRAMES=",".join(map(str, frames)), VC_COIN=str(a.coin),
                   VC_COINPERIOD=str(inp.get("coin_period", 97)),
                   VC_STARTPERIOD=str(inp.get("start_period", 211)),
                   VC_COINLEN=str(inp.get("press_len", 5)),
                   VC_IN_COIN=inp.get("coin", "Coin 1"), VC_IN_START=inp.get("start", "1 Player Start"),
                   VC_IN_HOLD=inp.get("hold", "P1 Right"),
                   VC_IN_PULSE=a.pulse or inp.get("pulse", "P1 Button 1"))
        cmd = mame_cmd(exe, a.set, "vcap.lua", mame_dir,
                       ["-nvram_directory", nv, "-seconds_to_run", str(frames[-1] // 60 + 60)])
        p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
    check_lua_error(out)
    if "VCAP_OK" not in p.stdout:
        sys.stdout.write(p.stdout[-2000:])
        sys.stderr.write(p.stderr[-2000:])
        sys.exit("no VCAP_OK")
    print(f"{len(frames)} frames in {out}")


if __name__ == "__main__":
    main()
