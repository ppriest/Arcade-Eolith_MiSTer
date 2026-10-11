#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render QS1000 register writes fast, with the features MAME's qs1000.cpp leaves out as options, to test
each against a PCB recording (docs/QS1000_FEATURES.md).

    python scripts/qs1000_render.py <set> <wave.txt> --from S --to S --out x.wav
        [--loop off|keyed] [--release loopend|keyoff|exp:MS] [--velocity off|linear] [--balance mame|pcb]
        [--only music|sfx] [--sfx 01a9:01aa]

<wave.txt>: each write to 0x200-0x211 with its 750 kHz tick (Arcade-Vamphalf_MiSTer
scripts/mame_qs1000_wave.py). --from/--to are seconds of that tick count.

Per voice, as MAME's model (Vamphalf scripts/qs1000_model.py): the voice outputs sample
floor(t * freq / 2^18) of its descriptor at tick t after key-on, ADPCM addresses counting nibbles from the
start; volumes 6-8 as written, also after key-on. Each sample is decoded once; the output is taken at
the middle tick of every 16 (46.875 kHz, not MAME's box filter) and resampled to 48 kHz.
  --loop off      MAME: the voice stops at its loop end
  --loop keyed    MAME's disabled code: at the loop end a keyed voice goes back to the loop start, ADPCM
                  with the decoder state it had there; --release says what key-off does:
                  loopend (MAME's disabled code: play on to the loop end), keyoff (stop), exp:MS (fade,
                  time constant MS, from key-off)
  --min-loop N    loops shorter than N addresses count as none (one-shots ending on a loop of silence)
  --velocity linear   scale by [20d] / 127
"""
import argparse
import math
import sys
import wave
from pathlib import Path

import numpy as np

TICK = 750000
RATE = TICK // 16
VAMPHALF = Path("E:/Arcade-Vamphalf_MiSTer/scripts")


def load_writes(path):
    w = []
    for ln in open(path, encoding="utf-8"):
        if ln.startswith("W "):
            _, t, off, d = ln.split()
            w.append((int(t), int(off, 16), int(d, 16)))
    return w


def sample_rom(setname):
    sys.path.insert(0, str(VAMPHALF))
    import qs1000_model as qm
    return qm.sample_rom(setname)


def notes_of(writes):
    """MAME's register model -> notes: key-on tick, channel, [(tick, regs)] (the copy at key-on, then each
    channel-mode write), key-off tick, end tick (the channel's next key-on)."""
    wave_r = [0] * 0x12
    regs = [[0] * 16 for _ in range(32)]
    cur = [None] * 32
    notes = []
    for t, off, d in writes:
        if off == 0:
            ch = wave_r[0xe] & 31
            if d == 0:
                regs[ch] = list(wave_r[:16])
                if cur[ch] is not None:
                    cur[ch]["end"] = t
                cur[ch] = {"t0": t, "ch": ch, "regs": [(t, list(regs[ch]))], "off": None, "end": None}
                notes.append(cur[ch])
            elif d == 2 and cur[ch] is not None and cur[ch]["off"] is None:
                cur[ch]["off"] = t
        elif off <= 0xd:
            if wave_r[0x11] == 3:
                ch = wave_r[0xe] & 31
                regs[ch][off] = d
                if cur[ch] is not None:
                    cur[ch]["regs"].append((t, list(regs[ch])))
            else:
                wave_r[off] = d
        else:
            wave_r[off] = d
    return notes


# IMA ADPCM's step table (89 entries), for the decoder option: ADPCM may be IMA rather than MAME's OKI
# (docs/QS1000_FEATURES.md, A firmware reading)
IMA_STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
            97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
            724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
            4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
            18500, 20350, 22385, 24623, 27086, 29794, 32767]
IMA_INDEX = [-1, -1, -1, -1, 2, 4, 6, 8]


class Rom:
    """adpcm: "oki" (MAME), "ima-wrap" (16-bit signal wrapping) or "ima-sat" (saturating), each with
    "-lo" for the low nibble first (MAME reads the high nibble first)."""
    def __init__(self, rom, adpcm="oki"):
        self.rom = rom
        self.cache = {}
        self.adpcm = adpcm

    def rb(self, a):
        a &= 0xffffff
        return self.rom[a] if a < len(self.rom) else 0

    def entry(self, table):
        rb = self.rb
        freq = rb(table) << 8 | rb(table + 1)
        base = rb(table + 4) << 8 | rb(table + 5)
        b0 = rb(base)
        start = (b0 << 16 | rb(base + 1) << 8 | rb(base + 2)) & 0xffffff
        ls = ((b0 & 0xf0) << 16 | rb(base + 3) << 12 | rb(base + 4) << 4 | rb(base + 5) >> 4) & 0xffffff
        le = ((b0 & 0xf0) << 16 | (rb(base + 5) & 0xf) << 16 | rb(base + 6) << 8 | rb(base + 7)) & 0xffffff
        return freq, start, ls, le, bool(rb(base + 8) & 8)

    def decoded(self, start, le, adpcm):
        """The voice's output for address start + i, i < le - start (int8 values as MAME's model)."""
        k = (start, le, adpcm)
        if k not in self.cache:
            n = max(0, le - start)
            if not adpcm:
                raw = np.frombuffer(bytes(self.rb(start + i) for i in range(n)), dtype=np.uint8)
                self.cache[k] = raw.astype(np.int16) - 128
            elif self.adpcm == "oki":
                sys.path.insert(0, str(VAMPHALF))
                import qs1000_model as qm
                dec = qm.Adpcm()
                out = np.empty(n, np.int16)
                for i in range(n):
                    d = self.rb(start + (i >> 1))
                    s = dec.clock((d if i & 1 else d >> 4) & 0xf) >> 4
                    out[i] = ((s + 128) & 0xff) - 128
                self.cache[k] = out
            else:
                # IMA: the 16-bit signal in MAME's int8 units (/ 256), unrounded
                wrap = self.adpcm.startswith("ima-wrap")
                lo_first = self.adpcm.endswith("-lo")
                out = np.empty(n, np.float32)
                pred, idx = 0, 0
                for i in range(n):
                    d = self.rb(start + (i >> 1))
                    first = (i & 1) == 0
                    nib = (d & 0xf) if (first == lo_first) else (d >> 4)
                    step = IMA_STEP[idx]
                    diff = step >> 3
                    if nib & 4: diff += step
                    if nib & 2: diff += step >> 1
                    if nib & 1: diff += step >> 2
                    pred = pred - diff if nib & 8 else pred + diff
                    pred = ((pred + 32768) & 0xffff) - 32768 if wrap else max(-32768, min(32767, pred))
                    idx = max(0, min(88, idx + IMA_INDEX[nib & 7]))
                    out[i] = pred / 256.0
                self.cache[k] = out
        return self.cache[k]


def render(rom, notes, lo, hi, loop="off", release="loopend", velocity="off", balance="mame", keep=None,
           min_loop=1):
    """-> (left, right) float arrays at RATE for ticks [lo, hi)."""
    g_adpcm, g_pcm = {"mame": (4, 1), "pcb": (2, 4)}[balance]
    k0 = (lo - 8 + 15) // 16
    nk = (hi - lo) // 16
    L = np.zeros(nk, np.float64)
    R = np.zeros(nk, np.float64)
    tau = float(release[4:]) / 1000 * TICK if release.startswith("exp:") else None
    for n in notes:
        r0 = n["regs"][0][1]
        table = r0[1] << 16 | r0[2] << 8 | r0[3]
        if keep is not None and not keep(table):
            continue
        freq, start, ls, le, adpcm = rom.entry(table)
        if freq == 0 or le <= start:
            continue
        dec = rom.decoded(start, le, adpcm)
        Ln, Ls, LL = le - start, ls - start, le - ls
        t0 = n["t0"]
        t_end = n["end"] if n["end"] is not None else hi
        t_off = n["off"]
        # the ticks the voice could sound for: to MAME's stop, or to its end
        looped = loop != "off" and LL >= min_loop and Ls >= 0
        if not looped:
            last = t0 + -(-Ln * (1 << 18) // freq)            # first tick with position >= Ln
            last = min(last, t_end)
        else:
            last = t_end
            if t_off is not None:
                if release == "keyoff":
                    last = min(last, t_off)
                elif release == "loopend":
                    q_off = (t_off - t0) * freq >> 18
                    q_stop = Ln if q_off <= Ln else Ln + -(-(q_off - Ln) // LL) * LL
                    last = min(last, t0 + -(-q_stop * (1 << 18) // freq))
                elif tau is not None:
                    last = min(last, t_off + int(tau * 7))      # -60 dB
        a = max(t0, lo)
        b = min(last, hi)
        if b <= a:
            continue
        ks = np.arange(max((a - 8 + 15) // 16, k0), min((b - 8 + 15) // 16, k0 + nk))
        if len(ks) == 0:
            continue
        tk = ks * 16 + 8
        q = ((tk - t0) * freq) >> 18
        if looped:
            w = q >= Ln
            q = np.where(w, Ls + (q - Ls) % LL, q)
        q = np.clip(q, 0, Ln - 1)
        v = dec[q].astype(np.float64) * (g_adpcm if adpcm else g_pcm)
        # volumes: the regs in force at each tick
        rt = np.array([x[0] for x in n["regs"]])
        ri = np.searchsorted(rt, tk, side="right") - 1
        rr = np.array([x[1] for x in n["regs"]])[ri]
        gl = rr[:, 7] * rr[:, 8]          # [207] left, [206] right (docs/QS1000_FEATURES.md, Register map)
        gr = rr[:, 6] * rr[:, 8]
        if velocity == "linear":
            vel = rr[:, 0xd] / 127.0
            gl = gl * vel
            gr = gr * vel
        if tau is not None and t_off is not None and looped:
            fade = np.where(tk > t_off, np.exp(-(tk - t_off) / tau), 1.0)
            v = v * fade
        L[ks - k0] += v * gl
        R[ks - k0] += v * gr
    return L / 4096 / 32768, R / 4096 / 32768


def to48k(x):
    t = np.arange(int(len(x) * 48000 / RATE)) * (RATE / 48000)
    return np.interp(t, np.arange(len(x)), x)


def write_wav(path, L, R):
    s = np.stack([to48k(L), to48k(R)], axis=1)
    s = np.clip(s * 32767, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(s.tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("wave")
    ap.add_argument("--from", dest="lo", type=float, default=0.0)
    ap.add_argument("--to", dest="hi", type=float, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--loop", default="off", choices=["off", "keyed"])
    ap.add_argument("--release", default="loopend")
    ap.add_argument("--velocity", default="off", choices=["off", "linear"])
    ap.add_argument("--min-loop", type=int, default=1)
    ap.add_argument("--balance", default="mame", choices=["mame", "pcb"])
    ap.add_argument("--only", choices=["music", "sfx"])
    ap.add_argument("--sfx", default="01a9:01aa", help="16-bit table prefixes of the effects (misncrft)")
    a = ap.parse_args()
    writes = load_writes(a.wave)
    t0 = writes[0][0]
    rom = Rom(sample_rom(a.set))
    sfx = {int(x, 16) for x in a.sfx.split(":")}
    keep = None
    if a.only:
        keep = (lambda t: (t >> 8) not in sfx) if a.only == "music" else (lambda t: (t >> 8) in sfx)
    L, R = render(rom, notes_of(writes), t0 + int(a.lo * TICK), t0 + int(a.hi * TICK),
                  a.loop, a.release, a.velocity, a.balance, keep, a.min_loop)
    write_wav(a.out, L, R)
    print(f"{a.out}: {len(L) / RATE:.1f} s, peak {max(abs(L).max(), abs(R).max()):.3f}")


if __name__ == "__main__":
    main()
