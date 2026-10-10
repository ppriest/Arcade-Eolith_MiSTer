#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The scan-out RTL against MAME, frame by frame.

    python scripts/video_check.py <capture dir> [--frames 300,600]

For each frame in the capture's manifest (or --frames), runs sim/video_tb on the frame's dumps
and compares the RTL's picture with MAME's screenshot pixel for pixel. The PPMs stay in
obj_verilator/video_tb/out/.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402
from render_model import read_manifest  # noqa: E402


def git_bash():
    """Git for Windows' bash: a bare "bash" from Python can be WSL's, which sees no MSYS2."""
    import os
    import shutil
    for c in (Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe",):
        if c.exists():
            return str(c)
    return shutil.which("bash") or "bash"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--frames", default="")
    ap.add_argument("--flip", action="store_true", help="the core flipped, against MAME's frame turned 180 degrees")
    a = ap.parse_args()
    d = Path(a.dir).resolve()
    man = read_manifest(d)
    frames = [int(x) for x in a.frames.split(",")] if a.frames else sorted(man)
    outdir = REPO / "obj_verilator" / "video_tb" / "out"
    outdir.mkdir(parents=True, exist_ok=True)
    env = dict(__import__("os").environ)
    env.setdefault("MSYS2_ROOT", load_env().get("MSYS2_ROOT", ""))
    same = 0
    for n in frames:
        ppm = outdir / f"{d.name}_f{n}.ppm"
        r = subprocess.run([git_bash(), "scripts/run_verilator.sh", "video_tb", f"+dir={d.as_posix()}",
                            f"+frame={n}", f"+buf={man[n]}", f"+out={ppm.as_posix()}", f"+flip={int(a.flip)}"],
                           cwd=REPO, capture_output=True, text=True, env=env)
        if r.returncode or not ppm.exists():
            print(f"f{n}: bench failed\n{r.stdout[-1500:]}{r.stderr[-1500:]}")
            continue
        rtl = np.asarray(Image.open(ppm).convert("RGB"))
        ref = Image.open(d / f"f{n}.png").convert("RGB")
        ref = np.asarray(ref.rotate(180) if a.flip else ref)
        bad = int(np.any(rtl != ref, axis=-1).sum())
        same += bad == 0
        print(f"f{n}: {'identical' if bad == 0 else f'{bad} pixels differ'}")
    print(f"{same} of {len(frames)} frames identical")
    sys.exit(0 if same == len(frames) else 1)


if __name__ == "__main__":
    main()
