#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Test the QS1000 features MAME leaves out against a PCB recording (docs/QS1000_FEATURES.md, Recording).

    python scripts/qs1000_pcb_evidence.py <set> <wave.txt> <recording.wav> --from S --to S --rec-at S [S ...]
        [--sfx 01a9:01aa] [--per-sample]

<wave.txt>: MAME's register writes with 750 kHz ticks (scripts/qs1000_capture.py, or Arcade-Vamphalf_MiSTer
scripts/mame_qs1000_wave.py);
--from/--to: the stretch of it to test (seconds of ticks), music only (table prefixes in --sfx dropped);
--rec-at: where that stretch starts in the recording, roughly (each is refined by spectral-flux correlation).

The recording is lossy and has the player's effects over the music, so levels are not compared directly: a
render that adds sound anywhere matches a loud recording better. Instead, for a window of time (after MAME's
stop while keyed; after key-off, in the first pass or in the loop's repeats), the notes' output in that window
is rendered at the right pitch and a semitone sharp; E = how much louder (dB, each band normalised by its
median) the recording is where the right pitch is loud than where the sharp one is. E > 0: the note is in the
recording in that window. Printed per recording position and over 5 s blocks.
"""
import argparse
import collections
import sys
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qs1000_render as qr  # noqa: E402

TK = qr.TICK
HOP, NB, FMIN, FMAX = 480, 60, 100, 6000          # 10 ms frames, 60 log bands


def bandspec(x, sr=48000, hop=HOP, N=2048, nb=NB, fmin=FMIN, fmax=FMAX):
    nf = max(0, (len(x) - N) // hop)
    idx = np.arange(N)[None, :] + hop * np.arange(nf)[:, None]
    win = np.hanning(N).astype(np.float32)
    freqs = np.fft.rfftfreq(N, 1 / sr)
    bi = np.clip(np.searchsorted(freqs, np.geomspace(fmin, fmax, nb + 1)), 1, len(freqs) - 1)
    M = np.zeros((len(freqs), nb), np.float32)
    for i in range(nb):
        a, b = bi[i], max(bi[i + 1], bi[i] + 1)
        M[a:b, i] = 1.0 / (b - a)
    out = np.empty((nf, nb), np.float32)
    for s in range(0, nf, 2000):
        out[s:s + 2000] = (np.abs(np.fft.rfft(x[idx[s:s + 2000]] * win, axis=1)) ** 2) @ M
    return 10 * np.log10(out + 1e-12)


def read_mono(path):
    with wave.open(str(path)) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels())
    return (x.astype(np.float32).mean(axis=1) / 32768).astype(np.float32)


class Test:
    def __init__(self, a):
        self.writes = qr.load_writes(a.wave)
        self.rom = qr.Rom(qr.sample_rom(a.set))
        self.notes = qr.notes_of(self.writes)
        sfx = {int(x, 16) for x in a.sfx.split(":")}
        self.keep = lambda t: (t >> 8) not in sfx
        self.lo, self.hi = int(a.lo * TK), int(a.hi * TK)
        L, R = qr.render(self.rom, self.notes, self.lo, self.hi, keep=self.keep)
        self.Dm = bandspec(((qr.to48k(L) + qr.to48k(R)) / 2).astype(np.float32))
        self.floor = self.Dm.max() - 50
        fm = np.maximum(np.diff(self.Dm, axis=0), 0).sum(1)
        fm = (fm - fm.mean()) / fm.std()
        rec = read_mono(a.recording)
        self.recs = []
        for at in a.rec_at:
            r0 = int((at - 1.0) * 48000)
            Dr = bandspec(rec[r0: r0 + int((a.hi - a.lo + 2) * 48000)])
            fr = np.maximum(np.diff(Dr, axis=0), 0).sum(1)
            fr = (fr - fr.mean()) / fr.std()
            k = max(range(len(fr) - len(fm)), key=lambda k: np.dot(fr[k:k + len(fm)], fm))
            if a.no_refine:
                k = int(1.0 * 48000 / HOP)
            print(f"recording at {at:.2f} s: refined to {at - 1.0 + k * HOP / 48000:.3f} s "
                  f"(flux correlation {np.dot(fr[k:k + len(fm)], fm) / len(fm):.3f})")
            D = Dr[k: k + len(self.Dm)]
            self.recs.append(D - np.median(D, axis=0, keepdims=True))

    def note_info(self, n):
        r0 = n["regs"][0][1]
        table = r0[1] << 16 | r0[2] << 8 | r0[3]
        freq, start, ls, le, adpcm = self.rom.entry(table)
        return table, freq, start, ls, le, adpcm

    def layer(self, sel, span, sharp):
        """sel: notes; span(n, t0, t_ln, t_off, t_end, Ln, Ls, LL, freq) -> (a, b, q_from, t_from) or None:
        render the note over ticks [a, b) from position q_from at tick t_from, looping if it has a loop."""
        k0 = (self.lo - 8 + 15) // 16
        out = np.zeros((self.hi - self.lo) // 16)
        for n in sel:
            table, freq, start, ls, le, adpcm = self.note_info(n)
            Ln, Ls, LL = le - start, ls - start, le - ls
            t0 = n["t0"]
            t_end = n["end"] if n["end"] is not None else self.hi
            t_ln = t0 + -(-Ln * (1 << 18) // freq)
            s = span(n, t0, t_ln, n["off"], t_end, Ln, Ls, LL, freq)
            if s is None:
                continue
            a, b, q_from, t_from = s
            a, b = max(a, self.lo), min(b, t_end, self.hi)
            if b <= a:
                continue
            dec = self.rom.decoded(start, le, adpcm)
            ks = np.arange(max((a - 8 + 15) // 16, k0), min((b - 8 + 15) // 16, k0 + len(out)))
            tk = ks * 16 + 8
            f2 = int(freq * 1.0595) if sharp else freq
            q = q_from + (((tk - t_from) * f2) >> 18)
            if LL >= 16 and Ls >= 0:
                q = np.where(q >= Ln, Ls + (q - Ls) % LL, q)
            else:
                m = q < Ln
                ks, tk, q = ks[m], tk[m], q[m]
                if len(ks) == 0:
                    continue
            v = dec[q].astype(np.float64) * (4 if adpcm else 1)
            rt = np.array([x[0] for x in n["regs"]])
            rr = np.array([x[1] for x in n["regs"]])[np.searchsorted(rt, tk, side="right") - 1]
            out[ks - k0] += v * (rr[:, 6] + rr[:, 7]) / 2 * rr[:, 8]
        return bandspec((qr.to48k(out / 4096 / 32768)).astype(np.float32))[:len(self.Dm)]

    def evidence(self, sel, span):
        c, s = self.layer(sel, span, False), self.layer(sel, span, True)
        Cc = (c > s + 10) & (c > self.floor)
        Cs = (s > c + 10) & (s > self.floor)
        if Cc.sum() < 50 or Cs.sum() < 50:
            return None
        E = [R[Cc].mean() - R[Cs].mean() for R in self.recs]
        blk = []
        for R in self.recs:
            for b0 in range(0, len(R), 500):
                cc, ss = Cc[b0:b0 + 500], Cs[b0:b0 + 500]
                if cc.sum() > 20 and ss.sum() > 20:
                    blk.append(R[b0:b0 + 500][cc].mean() - R[b0:b0 + 500][ss].mean())
        return E, np.array(blk), int(Cc.sum())


def ms(x):
    return int(x / 1000 * TK)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("set")
    ap.add_argument("wave")
    ap.add_argument("recording")
    ap.add_argument("--from", dest="lo", type=float, required=True)
    ap.add_argument("--to", dest="hi", type=float, required=True)
    ap.add_argument("--rec-at", type=float, nargs="+", required=True)
    ap.add_argument("--sfx", default="01a9:01aa")
    ap.add_argument("--per-sample", action="store_true")
    ap.add_argument("--no-refine", action="store_true", help="use --rec-at as given")
    a = ap.parse_args()
    T = Test(a)
    music = []
    for n in T.notes:
        table, freq, start, ls, le, adpcm = T.note_info(n)
        if T.keep(table) and freq and le > start:
            music.append(n)
    looped = [n for n in music if (lambda i: i[4] - i[3] >= 16 and i[3] >= i[2])(T.note_info(n))]

    def held(n, t0, t_ln, t_off, t_end, Ln, Ls, LL, f):
        b = t_off if t_off is not None else t_end
        return (t_ln, b, Ln, t_ln) if n in looped_set else None

    def first(d0, d1):
        def span(n, t0, t_ln, t_off, t_end, Ln, Ls, LL, f):
            if t_off is None or t_off >= t_ln:
                return None
            q_off = ((t_off - t0) * f) >> 18
            return (t_off + ms(d0), min(t_ln, t_off + ms(d1)), q_off, t_off)
        return span

    def repeats(d0, d1):
        def span(n, t0, t_ln, t_off, t_end, Ln, Ls, LL, f):
            if t_off is None or t_off < t_ln or n not in looped_set:
                return None
            q_off = ((t_off - t0) * f) >> 18
            return (t_off + ms(d0), t_off + ms(d1), q_off, t_off)
        return span

    looped_set = set(map(id, looped))
    looped_set = _IdSet(looped)
    rows = [("keyed, after MAME's stop at the loop end", held)]
    rows += [(f"keyed off in the first pass, {d0}-{d1} ms after", first(d0, d1))
             for d0, d1 in ((0, 100), (100, 200), (200, 400), (400, 800), (800, 3200))]
    rows += [(f"keyed off in the repeats, {d0}-{d1} ms after", repeats(d0, d1))
             for d0, d1 in ((0, 100), (100, 200), (200, 400), (400, 800), (800, 3200))]
    print(f"{'window':48s} {'E per recording position (dB)':32s} 5 s blocks positive, median")
    for name, span in rows:
        r = T.evidence(music, span)
        if r is None:
            print(f"{name:48s} too few cells")
            continue
        E, blk, nc = r
        print(f"{name:48s} {' '.join(f'{e:+5.2f}' for e in E):32s} {np.mean(blk > 0) * 100:3.0f}% {np.median(blk):+5.2f}"
              f"  ({nc} cells)")
    if a.per_sample:
        groups = collections.defaultdict(list)
        for n in music:
            if n["off"] is not None and T.lo <= n["off"] < T.hi:
                table = T.note_info(n)[0]
                groups[T.rom.rb(table + 4) << 8 | T.rom.rb(table + 5)].append(n)
        print("\nafter key-off, per descriptor (E averaged over the recording positions):")
        print("desc  notes  bytes 8-13          0-150 ms 150-500 500-1500   first pass, loop (ms)")

        def after(d0, d1):
            def span(n, t0, t_ln, t_off, t_end, Ln, Ls, LL, f):
                return (t_off + ms(d0), t_off + ms(d1), ((t_off - t0) * f) >> 18, t_off)
            return span
        for base, sel in sorted(groups.items(), key=lambda kv: -len(kv[1])):
            if len(sel) < 15:
                continue
            Es = []
            for d0, d1 in ((0, 150), (150, 500), (500, 1500)):
                r = T.evidence(sel, after(d0, d1))
                Es.append(np.mean(r[0]) if r else float("nan"))
            table, freq, start, ls, le, adpcm = T.note_info(sel[0])
            desc = bytes(T.rom.rb(base + i) for i in range(16))
            print(f"{base:04x}  {len(sel):5d}  {desc[8:14].hex(' ')}   " + "  ".join(f"{e:+6.2f}" for e in Es) +
                  f"   {(le - start) * (1 << 18) / freq / TK * 1000:6.0f} {(le - ls) * (1 << 18) / freq / TK * 1000:6.0f}")


class _IdSet:
    def __init__(self, items):
        self.ids = {id(x) for x in items}

    def __contains__(self, x):
        return id(x) in self.ids


if __name__ == "__main__":
    main()
