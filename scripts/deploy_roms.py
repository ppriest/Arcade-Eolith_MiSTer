#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Copy MAME ROM zips to the MiSTer's games/mame, checked by MD5.

    python scripts/deploy_roms.py hidnctch klondkp      # these sets' zips
    python scripts/deploy_roms.py --all                  # every set in build_mra.py's SETS

A set's zip is looked up as build_mra.py does (repo roms/, then MAME_ROMPATH); a clone with no zip of its own
is covered by its parent's (merged sets). A zip already on the device with the same MD5 is left alone.
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_mra import SETS, zips_for   # noqa: E402
from coretools import load_env         # noqa: E402
from hw import Mister                  # noqa: E402

REMOTE = "/media/fat/games/mame"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    sets = list(SETS) if a.all else a.sets
    zips = []
    for s in sets:
        if s not in SETS:
            sys.exit(f"unknown set {s}")
        for z in zips_for(s)[1]:
            if z not in zips:
                zips.append(z)
    m = Mister(load_env())
    for z in zips:
        local = hashlib.md5(z.read_bytes()).hexdigest()
        have = m.sh(f"md5sum '{REMOTE}/{z.name}' 2>/dev/null", check=False).split()
        if have and have[0] == local:
            print(f"  {z.name}: on the device, MD5 {local}")
            continue
        p = subprocess.run([m.pscp, "-batch", "-pw", m.pw, str(z), f"{m.user}@{m.host}:{REMOTE}/{z.name}"],
                           capture_output=True, text=True, timeout=1800)
        if p.returncode:
            sys.exit(f"copy failed: {z.name}\n{p.stderr.strip()}")
        remote = m.sh(f"md5sum '{REMOTE}/{z.name}'").split()[0]
        print(f"  {z.name}: copied, MD5 {'match' if remote == local else 'MISMATCH ' + remote}")
        if remote != local:
            sys.exit(1)


if __name__ == "__main__":
    main()
