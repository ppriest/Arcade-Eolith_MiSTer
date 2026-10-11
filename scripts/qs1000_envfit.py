#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Each instrument's envelope, fitted jointly over recordings of MIDI files on a QS1000 device against the
firmware's register writes for the same files (scripts/qs1000_midi.py run; docs/QS1000_FEATURES.md, Envelopes).

    python scripts/qs1000_envfit.py stems <set> <wave.txt> <recording.wav> <stems.npz>
    python scripts/qs1000_envfit.py fit <set> <stems.npz> ... [--gamma 0,1,2] [--min-notes 20] [--csv out.csv]

stems: every note rendered alone (looping while keyed and after key-off, no envelope) as 60-band power
spectra at 100 frames a second, with the recording's spectra aligned to them (on note onsets).
fit: the recording's band power is modelled as G_track(band) x sum over notes of stem x env(descriptor, time
bin) x (velocity / 127)^gamma, the time bins counted from note-on while keyed and from key-off after, and
solved by non-negative least squares over every frame and band of every track (each cell weighted by the
inverse of the unenveloped render's power there, so the error is relative), alternating with the band gains.
Overlapping notes are explained together rather than masked out.
"""
import argparse
import collections
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import qs1000_render as qr  # noqa: E402
import qs1000_midi as qm  # noqa: E402
import qs1000_pcb_evidence as ev  # noqa: E402

FPS = 100                                   # frames a second: ev.bandspec's hop of 480 at 48 kHz
TPF = qr.TICK // FPS                        # 7,500 ticks a frame
NB = 60
# time bins, in frames; a frame's window is 43 ms long, so finer bins only trade resolution for noise
ON_EDGES = np.array([0, 3, 7, 12, 20, 35, 60, 100, 160, 250, 400, 600])   # after note-on, while keyed
OFF_EDGES = np.array([0, 5, 12, 25, 45, 75, 115, 150])                     # after key-off
REF = (2, 4)                                # the on bins (70-200 ms) the curves are given relative to


def bands(x):
    return ev.bandspec(x.astype(np.float32), nb=NB, fmin=100, fmax=8000)


def mono(L, R):
    return (qr.to48k(L) + qr.to48k(R)) / 2


def stems(a):
    img = qm.image(a.set).read_bytes()
    rom = qr.Rom(img[qm.SD_SMP:qm.SD_SMP + qm.SMP_LEN], adpcm="ima-wrap")
    writes = qr.load_writes(a.wave)
    notes = qr.notes_of(writes)
    hi = writes[-1][0] + 2 * qr.TICK
    S_all = bands(mono(*qr.render(rom, notes, 0, hi, loop="keyed", release="exp:1000000", balance="pcb")))
    Dg = bands(qm.read_wav(a.recording)[0].mean(axis=1))
    # alignment on note onsets: a pulse at each key-on (spread over +-30 ms, weighted by velocity) against the
    # recording's onset strength, the recording from 5 s earlier to 2 s later (spectral flux misleads where the
    # timbres differ)
    onset = np.maximum(np.diff(Dg, axis=0), 0).sum(1)
    onset = (onset - onset.mean()) / (onset.std() + 1e-9)
    imp = np.zeros(len(S_all))
    for n in notes:
        f = n["t0"] // TPF
        if f < len(imp):
            imp[f] += 1 + n["regs"][0][1][0xd] / 64
    imp = np.convolve(imp, np.exp(-0.5 * (np.arange(-3, 4) / 1.5) ** 2), "same")

    def score(lag):
        b0 = max(0, lag); a0 = b0 - lag
        m = min(len(imp) - a0, len(onset) - b0)
        return np.dot(imp[a0:a0 + m], onset[b0:b0 + m]) / max(m, 1) if m > 100 else -1e9
    lag = max(range(-5 * FPS, 2 * FPS), key=score)
    print(f"alignment: recording = render {lag / FPS:+.2f} s (onset score {score(lag):.3f})")
    G = np.full_like(S_all, np.nan)
    f = np.arange(len(S_all)); g = f + lag; ok = (g >= 0) & (g < len(Dg))
    G[f[ok]] = Dg[g[ok]]

    rec = {k: [] for k in ("desc", "f0", "kon", "vel", "len")}
    P = []
    for n in notes:
        r0 = n["regs"][0][1]
        table = r0[1] << 16 | r0[2] << 8 | r0[3]
        if not rom.entry(table)[0]:
            continue
        t0 = n["t0"]
        t_off = n["off"] if n["off"] is not None else (n["end"] or hi)
        t_end = min(n["end"] or hi, t_off + OFF_EDGES[-1] * TPF, t0 + ON_EDGES[-1] * TPF, hi)
        f0, f1 = t0 // TPF, t_end // TPF
        if f1 - f0 < 2 or f1 > len(S_all):
            continue
        # rendered from frame f0's first tick, so the stem's frame i is the track's frame f0 + i
        x = mono(*qr.render(rom, [n], f0 * TPF, f1 * TPF + 2048 * qr.TICK // 48000 + 64, loop="keyed",
                            release="exp:1000000", balance="pcb"))
        S = bands(x)[: f1 - f0]
        rec["desc"].append(rom.rb(table + 4) << 8 | rom.rb(table + 5)); rec["f0"].append(f0)
        rec["kon"].append((t_off - t0) // TPF); rec["vel"].append(r0[0xd]); rec["len"].append(len(S))
        P.append(S.astype(np.float16))
    np.savez_compressed(a.out, S_all=S_all.astype(np.float16), G=G.astype(np.float16), P=np.concatenate(P),
                        **{k: np.array(v) for k, v in rec.items()})
    print(f"{a.out}: {len(P)} notes")


def entries(track):
    """-> per stem frame of every note: (track frame, descriptor, 0 on / 1 off, time bin, stem row, note)."""
    out = []
    row = 0
    for i, (d, f0, kon, ln) in enumerate(zip(track["desc"], track["f0"], track["kon"], track["len"])):
        fr = np.arange(ln)
        on = fr < kon
        b = np.where(on, np.searchsorted(ON_EDGES, fr, side="right") - 1,
                     np.searchsorted(OFF_EDGES, fr - kon, side="right") - 1)
        keep = np.where(on, b < len(ON_EDGES) - 1, b < len(OFF_EDGES) - 1)
        j = np.nonzero(keep)[0]
        out.append(np.stack([f0 + j, np.full(len(j), d), (~on[j]).astype(int), b[j], row + j, np.full(len(j), i)], 1))
        row += ln
    e = np.concatenate(out).astype(np.int64)
    return e[np.argsort(e[:, 0], kind="stable")]


def looped(rom, d):
    b0 = rom.rb(d)
    start = (b0 << 16 | rom.rb(d + 1) << 8 | rom.rb(d + 2)) & 0xffffff
    ls = ((b0 & 0xf0) << 16 | rom.rb(d + 3) << 12 | rom.rb(d + 4) << 4 | rom.rb(d + 5) >> 4) & 0xffffff
    le = ((b0 & 0xf0) << 16 | (rom.rb(d + 5) & 0xf) << 16 | rom.rb(d + 6) << 8 | rom.rb(d + 7)) & 0xffffff
    return le - ls >= 16 and ls >= start


def fit(a):
    img = qm.image(a.set).read_bytes()
    rom = qr.Rom(img[qm.SD_SMP:qm.SD_SMP + qm.SMP_LEN], adpcm="ima-wrap")
    paths = list(a.npz)
    held = [p for i, p in enumerate(paths) if a.holdout and i % a.holdout == a.holdout - 1]
    tracks = [dict(np.load(p)) for p in paths if p not in held]
    count = collections.Counter()
    for t in tracks:
        count.update(int(d) for d in t["desc"])
    descs = sorted(d for d, c in count.items() if c >= a.min_notes)
    desc_bytes = {d: bytes(rom.rb(d + i) for i in range(16)) for d in descs}
    # the envelope's owner: each descriptor, the descriptors sharing bytes 9-13, or one for all; samples that
    # do not loop have a single level (the sample is its own envelope)
    grp = {}
    for d in descs:
        if not looped(rom, d):
            grp[d] = None
        elif a.group == "desc":
            grp[d] = f"{d:04x}"
        elif a.group == "bytes":
            grp[d] = desc_bytes[d][9:14].hex(" ")
        else:
            grp[d] = "all"
    groups = sorted({g for g in grp.values() if g is not None})
    env_keys = [(g, 0, b) for g in groups for b in range(len(ON_EDGES) - 1)] + \
               [(g, 1, b) for g in groups for b in range(len(OFF_EDGES) - 1)]
    one_keys = [("one", d) for d in descs if grp[d] is None]
    keys = env_keys + one_keys
    col = {k: i for i, k in enumerate(keys)}
    K = len(keys)
    dcol = {d: i for i, d in enumerate(descs)}
    loops = np.array([grp[d] is not None for d in descs])
    def make(t):
        e = entries(t)
        u, inv = np.unique(e[:, 1:4], axis=0, return_inverse=True)

        def key_col(d, kind, b):
            if d not in grp:
                return -1
            return col[("one", d)] if grp[d] is None else col.get((grp[d], kind, b), -1)
        S = 10 ** (t["S_all"].astype(np.float32) / 10)
        G = t["G"].astype(np.float32)
        floor = S.max() * 1e-5
        cd = np.array([dcol.get(int(d), -1) for d in e[:, 1]])
        return dict(e=e, P=10 ** (t["P"].astype(np.float32) / 10), S=S,
                    R=10 ** (np.nan_to_num(G, nan=-120) / 10), valid=np.isfinite(G).all(1),
                    W=1.0 / (S + floor) ** 2, vel=t["vel"].astype(np.float64) / 127,
                    col_env=np.array([key_col(int(d), k, b) for d, k, b in u])[inv.ravel()],
                    col_desc=cd, is_loop=(cd >= 0) & loops[np.maximum(cd, 0)])
    prep = [make(t) for t in tracks]
    print(f"{len(tracks)} tracks, {len(descs)} descriptors with {a.min_notes}+ notes, {len(groups)} envelopes "
          f"({a.group}), {len(one_keys)} one-shots, {K} unknowns")

    def accumulate(cols, scale, Kn, gains, gamma):
        Q = np.zeros((Kn, Kn)); c = np.zeros(Kn); yy = 0.0
        for pr, gb in zip(prep, gains):
            e = pr["e"]; cc = cols(pr); sc = scale(pr) * pr["vel"][e[:, 5]] ** gamma
            fr = e[:, 0]
            bounds = np.r_[0, np.nonzero(np.diff(fr))[0] + 1, len(fr)]
            for s0, s1 in zip(bounds[:-1], bounds[1:]):
                f = fr[s0]
                if not pr["valid"][f]:
                    continue
                y = pr["R"][f] / gb
                yy += (y * y * pr["W"][f]).sum()
                m = (cc[s0:s1] >= 0) & (sc[s0:s1] > 0)
                if not m.any():
                    continue
                u, inv = np.unique(cc[s0:s1][m], return_inverse=True)
                A = np.zeros((len(u), NB))
                np.add.at(A, inv, pr["P"][e[s0:s1, 4][m]] * sc[s0:s1][m][:, None])
                AW = A * pr["W"][f]
                Q[np.ix_(u, u)] += AW @ A.T
                c[u] += AW @ y
        return Q, c, yy

    def levels(pr, g_d):
        """each entry's descriptor level: g_d for a looped descriptor, 1 for a one-shot (its column is its level)"""
        return np.where(pr["is_loop"], g_d[np.maximum(pr["col_desc"], 0)], (pr["col_desc"] >= 0) * 1.0)

    def band_gains(pr, gb, x, g_d, gamma):
        """-> the track's band gains fitted to the model with x and g_d fixed, and the model (before the gains)"""
        e = pr["e"]; cc = pr["col_env"]; m = cc >= 0
        w = x[cc[m]] * levels(pr, g_d)[m] * pr["vel"][e[m, 5]] ** gamma
        M = np.zeros(pr["S"].shape)
        np.add.at(M, e[m, 0], pr["P"][e[m, 4]] * w[:, None])
        v = pr["valid"][:, None] & (M > 0)
        num = np.where(v, pr["R"] * M * pr["W"], 0).sum(0); den = np.where(v, M * M * pr["W"], 0).sum(0)
        return np.where(den > 0, num / np.maximum(den, 1e-30), gb), M

    best = None
    for gamma in [float(v) for v in a.gamma.split(",")]:
        gains = [np.nansum(np.where(pr["valid"][:, None], pr["R"], 0), 0) / np.sum(pr["S"], 0) for pr in prep]
        g_d = np.ones(len(descs))
        x = np.ones(K)
        for it in range(a.iterations):
            # envelopes (and the one-shots' levels), with the looped descriptors' levels fixed
            Q, c, yy = accumulate(lambda pr: pr["col_env"], lambda pr: levels(pr, g_d), K, gains, gamma)
            x = nnls_cd(Q + a.smooth * smoothing(env_keys, col, np.diag(Q)), c, x)
            res = (yy - 2 * c @ x + x @ Q @ x) / yy
            # each descriptor's level, with the envelopes fixed (a one-shot's goes into its column)
            Qd, cdv, _ = accumulate(lambda pr: pr["col_desc"],
                                    lambda pr: x[np.maximum(pr["col_env"], 0)] * (pr["col_env"] >= 0) * levels(pr, g_d),
                                    len(descs), gains, gamma)
            k = nnls_cd(Qd, cdv, np.ones(len(descs)))
            k = np.where(k > 0, k, 1.0)
            for i, d in enumerate(descs):
                if grp[d] is None:
                    x[col[("one", d)]] *= k[i]
            g_d = np.where(loops, g_d * k, g_d)
            # each envelope's descriptors to a mean level of 1 (the envelope takes the rest), so that levels and
            # envelopes cannot drift together
            for g in groups:
                m = np.array([grp[d] == g for d in descs])
                gm = np.exp(np.mean(np.log(g_d[m])))
                g_d[m] /= gm
                for kind, nb in ((0, len(ON_EDGES) - 1), (1, len(OFF_EDGES) - 1)):
                    for b in range(nb):
                        x[col[(g, kind, b)]] *= gm
            gains = [band_gains(pr, gb, x, g_d, gamma)[0] for pr, gb in zip(prep, gains)]
            print(f"gamma {gamma}: iteration {it}, relative residual {res:.4f}")
        if best is None or res < best[0]:
            best = (res, gamma, x.copy(), g_d.copy())
    rr, gamma, x, g_d = best
    if held:
        # the held-out tracks: their band gains fitted with everything else fixed, then the same residual
        num = den = 0.0
        for p in held:
            pr = make(dict(np.load(p)))
            gb = np.nansum(np.where(pr["valid"][:, None], pr["R"], 0), 0) / np.sum(pr["S"], 0)
            for _ in range(4):
                gb, M = band_gains(pr, gb, x, g_d, gamma)
            rows = pr["valid"] & np.isin(np.arange(len(pr["valid"])), pr["e"][:, 0])
            y = pr["R"][rows] / gb
            num += (pr["W"][rows] * (y - M[rows]) ** 2).sum(); den += (pr["W"][rows] * y * y).sum()
        print(f"held out: {len(held)} tracks, relative residual {num / den:.4f}")
    print(f"\nbest gamma {gamma} (relative residual {rr:.4f}); dB relative to {ON_EDGES[REF[0]] * 10}-"
          f"{ON_EDGES[REF[1]] * 10} ms after note-on\n")
    on_mid = [f"{(ON_EDGES[b] + ON_EDGES[b + 1]) * 5:.0f}" for b in range(len(ON_EDGES) - 1)]
    off_mid = [f"{(OFF_EDGES[b] + OFF_EDGES[b + 1]) * 5:.0f}" for b in range(len(OFF_EDGES) - 1)]
    print(f"{'envelope':16s} notes  descriptors                on (ms): " + " ".join(f"{m:>5}" for m in on_mid) +
          "   off (ms): " + " ".join(f"{m:>5}" for m in off_mid))
    rows = []
    for g in groups:
        on = np.array([x[col[(g, 0, b)]] for b in range(len(ON_EDGES) - 1)])
        of = np.array([x[col[(g, 1, b)]] for b in range(len(OFF_EDGES) - 1)])
        ref = on[REF[0]:REF[1]].mean()
        with np.errstate(divide="ignore", invalid="ignore"):
            don, dof = 10 * np.log10(on / ref), 10 * np.log10(of / ref)
        ds = [d for d in descs if grp[d] == g]
        n = sum(count[d] for d in ds)
        who = " ".join(f"{d:04x}" for d in ds[:3]) + (f" +{len(ds) - 3}" if len(ds) > 3 else "")
        print(f"{g:16s} {n:5d}  {who:26s}   " + " ".join(f"{v:+5.1f}" for v in don) + "             " +
              " ".join(f"{v:+5.1f}" for v in dof))
        rows.append((g, n, " ".join(f"{d:04x}" for d in ds), don, dof))
    if a.csv:
        with open(a.csv, "w") as f:
            f.write("envelope,notes,descriptors," + ",".join(f"on{m}" for m in on_mid) + "," +
                    ",".join(f"off{m}" for m in off_mid) + "\n")
            for g, n, ds, don, dof in rows:
                f.write(f"{g},{n},{ds}," + ",".join(f"{v:.2f}" for v in np.r_[don, dof]) + "\n")


def smoothing(keys, col, diag):
    """D'D for the first differences between neighbouring time bins of each descriptor's on and off curves, each
    pair scaled by the smaller of the two bins' weights (so the penalty is relative, as the fit's error is)."""
    R = np.zeros((len(diag), len(diag)))
    for d, kind, b in keys:
        j = col.get((d, kind, b + 1))
        if j is None:
            continue
        i = col[(d, kind, b)]
        w = min(diag[i], diag[j])
        R[i, i] += w; R[j, j] += w; R[i, j] -= w; R[j, i] -= w
    return R


def nnls_cd(Q, c, x0, sweeps=400):
    """min x'Qx - 2c'x over x >= 0, by coordinate descent from x0."""
    x = np.maximum(x0, 0).astype(np.float64)
    d = np.diag(Q).copy()
    live = d > 0
    x[~live] = 0
    g = Q @ x - c
    for _ in range(sweeps):
        delta = 0.0
        for i in np.nonzero(live)[0]:
            xi = max(0.0, x[i] - g[i] / d[i])
            if xi != x[i]:
                g += Q[:, i] * (xi - x[i])
                delta = max(delta, abs(xi - x[i]) / (abs(xi) + 1e-12))
                x[i] = xi
        if delta < 1e-6:
            break
    return x


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stems"); s.add_argument("set"); s.add_argument("wave"); s.add_argument("recording")
    s.add_argument("out")
    f = sub.add_parser("fit"); f.add_argument("set"); f.add_argument("npz", nargs="+")
    f.add_argument("--gamma", default="0,1,2"); f.add_argument("--min-notes", type=int, default=20)
    f.add_argument("--smooth", type=float, default=0.3, help="the penalty on neighbouring bins' difference, "
                   "relative to the bins' own weight")
    f.add_argument("--group", choices=("desc", "bytes", "all"), default="bytes",
                   help="who shares an envelope: each descriptor, those with the same bytes 9-13, or all")
    f.add_argument("--iterations", type=int, default=4)
    f.add_argument("--holdout", type=int, default=0, help="hold out every Nth track and report the residual on them")
    f.add_argument("--csv")
    a = ap.parse_args()
    stems(a) if a.cmd == "stems" else fit(a)


if __name__ == "__main__":
    main()
