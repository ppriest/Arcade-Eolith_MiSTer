#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A MIDI file through the Gradation 2D's QS1000 firmware, for comparing with a recording of the same file on
a QS1000 device (docs/QS1000_FEATURES.md, MIDI recordings).

    python scripts/qs1000_midi.py bytes <file.mid> <bytes.txt> [--lead S]
    python scripts/qs1000_midi.py run <set> <file.mid> --out DIR [--secs S] [--lead S]
    python scripts/qs1000_midi.py render <set> <wave.txt> <out.wav> [--loop keyed] [--release exp:MS] ...
    python scripts/qs1000_midi.py compare <render.wav> <recording.wav>

bytes: the file's channel messages in time order, each with its status byte (no running status), as
"<seconds> <hex bytes>" lines, from --lead seconds (1.0: the 8052 starts its firmware first); System
Exclusive and meta events are left out, tempo changes applied.
run: sim/snd_tb on a Gradation 2D image (+board=1 +midi): the QS1000's 8052 runs the set's own firmware,
the bytes arrive on its serial input at 31.25 kbps, and its voice-register writes go to DIR/wave.txt with
750 kHz ticks, its output (the core's own voice engine, as Eolith.sv has it) to DIR/audio.wav at 46,875 Hz:
compare takes either that or a render.
render: scripts/qs1000_render.py's renderer on the set's sample region (the image's SD_SMP, 2.5 MB) with
IMA decoding.
"""
import argparse
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

SD_SMP, SMP_LEN = 0x2100000, 0x280000


def vlq(d, i):
    v = 0
    while True:
        b = d[i]; i += 1
        v = (v << 7) | (b & 0x7f)
        if not b & 0x80:
            return v, i


def parse_midi(path):
    """-> [(seconds, bytes)] of channel messages."""
    d = Path(path).read_bytes()
    assert d[:4] == b"MThd", "not a Standard MIDI File"
    hlen = struct.unpack(">I", d[4:8])[0]
    fmt, ntrk, div = struct.unpack(">HHH", d[8:14])
    assert not div & 0x8000, "SMPTE time division not handled"
    i = 8 + hlen
    events = []          # (tick, order, kind, data): kind "t" tempo (us/quarter), "m" channel message
    order = 0
    for _ in range(ntrk):
        while d[i:i + 4] != b"MTrk":
            i += 8 + struct.unpack(">I", d[i + 4:i + 8])[0]
        tlen = struct.unpack(">I", d[i + 4:i + 8])[0]
        j, end = i + 8, i + 8 + tlen
        tick, status = 0, 0
        while j < min(end, len(d)) - 1:
            dt, j = vlq(d, j)
            if j >= len(d):
                break
            tick += dt
            b = d[j]
            if b == 0xff:                                   # meta
                typ = d[j + 1]
                ln, k = vlq(d, j + 2)
                if typ == 0x51 and ln == 3:
                    events.append((tick, order, "t", (d[k] << 16) | (d[k + 1] << 8) | d[k + 2])); order += 1
                j = k + ln
                if typ == 0x2f:
                    break
                continue
            if b in (0xf0, 0xf7):                           # SysEx
                ln, k = vlq(d, j + 1)
                j = k + ln
                continue
            if b >= 0xf1:                                   # system common / real time: no running status
                j += 1 + {0xf1: 1, 0xf2: 2, 0xf3: 1}.get(b, 0)
                continue
            if b & 0x80:
                status = b; j += 1
            n = 1 if (status & 0xf0) in (0xc0, 0xd0) else 2
            if not status or j + n > len(d):
                break
            msg = bytes([status]) + d[j:j + n]
            j += n
            if len(msg) == n + 1 and not any(x & 0x80 for x in msg[1:]):
                events.append((tick, order, "m", msg)); order += 1
        i = end
    events.sort(key=lambda e: (e[0], e[1]))
    out, tempo, last_tick, t = [], 500000, 0, 0.0
    for tick, _, kind, data in events:
        t += (tick - last_tick) * tempo / 1e6 / div
        last_tick = tick
        if kind == "t":
            tempo = data
        else:
            out.append((t, data))
    return out


def write_bytes(mid, path, lead):
    ev = parse_midi(mid)
    with open(path, "w") as f:
        for t, msg in ev:
            f.write(f"{t + lead:.6f} {' '.join(f'{b:02x}' for b in msg)}\n")
    return ev


def image(setname):
    img = REPO / "debug" / "img" / f"{setname}.bin"
    if not img.exists():
        img.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([sys.executable, str(REPO / "scripts" / "build_mra.py"), "--image", setname, str(img)], check=True)
    return img


def run(a):
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    ev = write_bytes(a.mid, out / "bytes.txt", a.lead)
    secs = a.secs or (ev[-1][0] + a.lead + 3.0 if ev else 5.0)
    exe = REPO / "obj_verilator" / "snd_tb" / "Vtb_snd.exe"
    if not exe.exists():
        subprocess.run(["bash", "scripts/run_verilator.sh", "snd_tb", "+frames=0"], cwd=REPO, check=False)
    r = subprocess.run([str(exe), f"+img={image(a.set)}", "+board=1", f"+midi={out / 'bytes.txt'}",
                        f"+wout={out / 'wave.txt'}", f"+aout={out / 'audio.wav'}", f"+secs={secs:.2f}"],
                       cwd=REPO, capture_output=True, text=True)
    print(r.stdout[-800:], r.stderr[-400:])


def render(a):
    import qs1000_render as qr
    img = image(a.set).read_bytes()
    rom = qr.Rom(img[SD_SMP:SD_SMP + SMP_LEN], adpcm=a.adpcm)
    writes = qr.load_writes(a.wave)
    hi = writes[-1][0] + int(a.tail * qr.TICK)
    L, R = qr.render(rom, qr.notes_of(writes), 0, hi, a.loop, a.release, a.velocity, a.balance, None, a.min_loop)
    qr.write_wav(a.out, L, R)
    print(f"{a.out}: {len(L) / qr.RATE:.1f} s")


def read_wav(path):
    """Samples as float, at 48 kHz (snd_tb's 46,875 Hz interpolated), and 48000."""
    import wave
    import numpy as np
    with wave.open(str(path)) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels())
        x, sr = x.astype(np.float32) / 32768, w.getframerate()
    if sr != 48000:
        t = np.arange(int(len(x) * 48000 / sr)) * (sr / 48000)
        x = np.stack([np.interp(t, np.arange(len(x)), x[:, c]) for c in range(x.shape[1])], axis=1).astype(np.float32)
    return x, 48000


def compare(a):
    """Render against recording: alignment, spectral match, and the stereo test ([206]/[207])."""
    import numpy as np
    import qs1000_pcb_evidence as ev
    r, sr_r = read_wav(a.render)
    g, sr_g = read_wav(a.recording)
    assert sr_r == sr_g == 48000, (sr_r, sr_g)
    mr, mg = r.mean(axis=1), g.mean(axis=1)
    Dr, Dg = ev.bandspec(mr), ev.bandspec(mg)
    fr = np.maximum(np.diff(Dr, axis=0), 0).sum(1); fg = np.maximum(np.diff(Dg, axis=0), 0).sum(1)
    fr = (fr - fr.mean()) / (fr.std() + 1e-9); fg = (fg - fg.mean()) / (fg.std() + 1e-9)
    n = min(len(fr), len(fg))
    lags = range(-int(5 * 100), int(5 * 100))            # +-5 s at 10 ms
    def score(k):
        a0, b0 = max(0, k), max(0, -k)
        m = min(n - a0, n - b0)
        return np.dot(fr[a0:a0 + m], fg[b0:b0 + m]) / m
    k = max(lags, key=score)
    print(f"alignment: recording {'later' if k < 0 else 'earlier'} by {abs(k) * 0.01:.2f} s (flux correlation {score(k):.3f})")
    a0, b0 = max(0, k), max(0, -k)
    m = min(len(Dr) - a0, len(Dg) - b0)
    R, G = Dr[a0:a0 + m], Dg[b0:b0 + m]
    def shape(X):
        X = X - X.mean(axis=1, keepdims=True)
        return X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-9)
    loud = R.max(axis=1) > R.max() - 40
    print(f"spectral shape correlation over loud frames: {(shape(R) * shape(G)).sum(axis=1)[loud].mean():.3f}")
    gain = np.median(G - R, axis=0)
    cells = R > R.max() - 40
    print(f"mean |recording - render| after a per-band gain: {np.abs(G - (R + gain))[cells].mean():.2f} dB")
    # stereo: per-cell L-R level difference, render against recording
    off = int(k * 480)
    rs, gs = (r[off:], g) if off >= 0 else (r, g[-off:])
    nn = min(len(rs), len(gs))
    RL, RR = ev.bandspec(rs[:nn, 0]), ev.bandspec(rs[:nn, 1])
    GL, GR = ev.bandspec(gs[:nn, 0]), ev.bandspec(gs[:nn, 1])
    c = np.maximum(RL, RR) > max(RL.max(), RR.max()) - 40
    dr = (RL - RR)[c]; dg = (GL - GR)[c]
    side = 20 * np.log10(np.sqrt(((gs[:nn, 0] - gs[:nn, 1]) ** 2).mean()) / (np.sqrt(((gs[:nn, 0] + gs[:nn, 1]) ** 2).mean()) + 1e-12))
    print(f"stereo: recording side/mid {side:.1f} dB; L-R difference correlation, render vs recording: "
          f"{np.corrcoef(dr, dg - np.median(dg))[0, 1]:+.3f} (negative: the render's left and right are swapped)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bytes"); b.add_argument("mid"); b.add_argument("out"); b.add_argument("--lead", type=float, default=1.0)
    r = sub.add_parser("run"); r.add_argument("set"); r.add_argument("mid"); r.add_argument("--out", required=True)
    r.add_argument("--secs", type=float); r.add_argument("--lead", type=float, default=1.0)
    n = sub.add_parser("render"); n.add_argument("set"); n.add_argument("wave"); n.add_argument("out")
    n.add_argument("--loop", default="keyed"); n.add_argument("--release", default="exp:250")
    n.add_argument("--velocity", default="off"); n.add_argument("--balance", default="pcb")
    n.add_argument("--adpcm", default="ima-wrap"); n.add_argument("--min-loop", type=int, default=1)
    n.add_argument("--tail", type=float, default=2.0)
    c = sub.add_parser("compare"); c.add_argument("render"); c.add_argument("recording")
    a = ap.parse_args()
    if a.cmd == "compare":
        compare(a); return
    if a.cmd == "bytes":
        ev = write_bytes(a.mid, a.out, a.lead)
        print(f"{len(ev)} messages, {ev[-1][0]:.1f} s" if ev else "no messages")
    elif a.cmd == "run":
        run(a)
    else:
        render(a)


if __name__ == "__main__":
    main()
