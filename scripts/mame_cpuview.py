#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The download image against the bytes MAME's CPU reads, for the ROM regions it maps.

    python scripts/mame_cpuview.py crazywar debug/img/crazywar.bin

The core's memory unit gives CPU byte address A the SDRAM byte at the image offset the decode maps it
to (rtl/eo_cpumem.sv: SDRAM words hold the even byte low, swapped at the seam), so the image must hold
the CPU's view. Compares the program ROM and three 256 KB stretches of maindata.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402
from build_mra import sdram_map  # noqa: E402

RANGES = {
    # (cpu address, length, image offset key)
    "crazywar": [(0xfff80000, 0x80000, "SD_PRG", 0), (0xfd000000, 0x40000, "SD_DATA", 0),
                 (0xfe000000, 0x40000, "SD_DATA", 0x1000000), (0xfefc0000, 0x40000, "SD_DATA", 0x1fc0000)],
    "hidnctch": [(0xfff80000, 0x80000, "SD_PRG", 0), (0xfd000000, 0x40000, "SD_DATA", 0),
                 (0xfe000000, 0x40000, "SD_DATA", 0x1000000), (0xfd7c0000, 0x40000, "SD_DATA", 0x7c0000)],
    # a protected set: the program ROM as patch_mcu_protection leaves it
    "hidctch2": [(0xfff80000, 0x80000, "SD_PRG", 0), (0xfd000000, 0x40000, "SD_DATA", 0)],
    "landbrka": [(0xfff80000, 0x80000, "SD_PRG", 0)],
    # eolith16: maindata at 0xff000000, 2 MB (eolith16_map 84)
    "klondkp": [(0xfff80000, 0x80000, "SD_PRG", 0), (0xff000000, 0x40000, "SD_DATA", 0),
                (0xff1c0000, 0x40000, "SD_DATA", 0x1c0000)],
}


def main():
    game, imgp = sys.argv[1], Path(sys.argv[2])
    img = imgp.read_bytes()
    sm = sdram_map()
    rs = RANGES[game]
    mame_dir, exe = mame_paths()
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "cv.bin"
        env = dict(os.environ, **lua_env(regions(game)), **lua_runner_env("cpuview.lua"), CORE_OUT=d,
                   CV_OUT=str(out), CV_RANGES=",".join(f"{a:x}:{n:x}" for a, n, _, _ in rs))
        subprocess.run(mame_cmd(exe, game, "cpuview.lua", mame_dir, ["-seconds_to_run", "30"]),
                       cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
        view = out.read_bytes()
    pos, bad = 0, 0
    for a, n, key, off in rs:
        want = view[pos:pos + n]
        got = img[sm[key] + off:sm[key] + off + n]
        pos += n
        if want == got:
            print(f"0x{a:08x} +0x{n:x}: identical")
        else:
            i = next(i for i in range(n) if want[i] != got[i])
            print(f"0x{a:08x} +0x{n:x}: differs at +0x{i:x}: MAME {want[i:i+8].hex()} image {got[i:i+8].hex()}")
            bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
