#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Software model of the Eolith frame-buffer scan-out, checked against MAME's screenshots.

    python scripts/render_model.py compare <capture dir> [...] [--diff-dir DIR]

The model is the driver's screen_update, transcribed:
  vegaeo.cpp:173-183  pixel = vram[0x14000 * (vbuffer ^ 1) + y * 320 + x], 320 x 240,
                      through the 256-entry palette (xRGB555, 202-203)
MAME expands 5-bit components as (c << 3) | (c >> 2) (pal5bit).
Inputs are scripts/eolith_capture.py's: f<N>_vram.bin, f<N>_palette.bin, f<N>.png, manifest.txt.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def pal5bit(c):
    return (c << 3) | (c >> 2)


def palette_rgb(pal_be16):
    v = pal_be16.astype(np.uint32)
    rgb = np.stack([(v >> 10) & 31, (v >> 5) & 31, v & 31], axis=-1)
    return pal5bit(rgb).astype(np.uint8)


def render_vega(vram, buffer, pal_be16):
    base = 0x14000 * (buffer ^ 1)
    fb = vram[base:base + 320 * 240].reshape(240, 320)
    return palette_rgb(pal_be16)[fb]


def read_manifest(d):
    out = {}
    for ln in (Path(d) / "manifest.txt").read_text().splitlines():
        t = ln.split()
        out[int(t[1])] = int(t[3])
    return out


def load(d, n):
    d = Path(d)
    vram = np.frombuffer((d / f"f{n}_vram.bin").read_bytes(), dtype=np.uint8)
    pal = np.frombuffer((d / f"f{n}_palette.bin").read_bytes(), dtype=">u2")
    ref = np.asarray(Image.open(d / f"f{n}.png").convert("RGB"))
    return vram, pal, ref


def cmd_compare(a):
    total = same = 0
    for d in a.dirs:
        for n, buf in sorted(read_manifest(d).items()):
            vram, pal, ref = load(d, n)
            img = render_vega(vram, buf, pal)
            total += 1
            if img.shape != ref.shape:
                print(f"{d} f{n}: model {img.shape} vs MAME {ref.shape}")
                continue
            bad = np.any(img != ref, axis=-1)
            nb = int(bad.sum())
            if nb == 0:
                same += 1
            else:
                ys, xs = np.nonzero(bad)
                print(f"{d} f{n}: {nb} pixels differ, first at ({xs[0]},{ys[0]})")
                if a.diff_dir:
                    Path(a.diff_dir).mkdir(parents=True, exist_ok=True)
                    Image.fromarray(np.where(bad[..., None], 255, img // 3).astype(np.uint8)).save(
                        Path(a.diff_dir) / f"{Path(d).name}_f{n}_diff.png")
    print(f"{same} of {total} frames identical")
    return 0 if same == total else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("dirs", nargs="+")
    c.add_argument("--diff-dir")
    a = ap.parse_args()
    sys.exit(cmd_compare(a))


if __name__ == "__main__":
    main()
