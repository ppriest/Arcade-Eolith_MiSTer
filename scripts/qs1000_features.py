#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Which of the QS1000's features MAME's qs1000.cpp ignores do the games use? (scripts/mame/qs1000_features.lua)

    python scripts/qs1000_features.py run [SET ...] [--frames 3600] [--jobs 4]   # MAME logs to debug/qs1000_feat/
    python scripts/qs1000_features.py report [SET ...]                          # summary of the logs

The default sets are every QS1000 set of eolith.cpp and vegaeo.cpp (this core) and vamphalf.cpp
(Arcade-Vamphalf_MiSTer); MAME runs both drivers. What MAME ignores (qs1000.cpp): the pitch registers
4-5 (the rate comes from the note entry), 9-0xd, 0xf-0x10, key value 1, the note entry's second word,
the descriptor's bytes 8-23 but byte 8's bit 3 (ADPCM), and looping (a voice stops at its loop end).
"""
import argparse
import collections
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, check_lua_error, lua_env, lua_runner_env, mame_cmd, mame_paths, regions  # noqa: E402

OUT = REPO / "debug" / "qs1000_feat"
EOLITH = ["crazywar", "hidnctch", "hidnctcha", "linkypip", "ironfort", "ironfortc", "puzzlekg", "candy",
          "hidctch2", "hidctch2a", "hidnc2k", "landbrk", "landbrka", "landbrkb", "nhidctch", "penfan", "penfana",
          "stealsee", "fort2b", "fort2ba", "hidctch3", "raccoon"]
VAMPHALF = ["misncrft", "misncrfta", "wyvernwg", "wyvernwga", "wivernwg", "yorijori"]
TICK = 750000          # the engine's sample rate in MAME (24 MHz / 32)


def run_one(game, frames, coin, start, rep):
    mame_dir, exe = mame_paths()
    log = OUT / f"{game}.log"
    work = OUT / f"{game}.run"
    work.mkdir(parents=True, exist_ok=True)
    (work / "lua_error.txt").unlink(missing_ok=True)
    env = dict(os.environ, **lua_env(regions(game)), **lua_runner_env("qs1000_features.lua"),
               CORE_OUT=work.as_posix(), QF_OUT=log.as_posix(), QF_FRAMES=str(frames),
               QF_COIN=str(coin), QF_START=str(start), QF_REP=str(rep))
    nv = work / "nvram"
    nv.mkdir(exist_ok=True)
    cmd = mame_cmd(exe, game, "qs1000_features.lua", mame_dir,
                   ["-nvram_directory", nv.as_posix(), "-seconds_to_run", "3600"])
    p = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, timeout=3600, **NO_WINDOW)
    ok = "QF_OK" in p.stdout
    return game, ok, (p.stdout + p.stderr)[-400:] if not ok else ""


def parse(path):
    """-> list of events: ('W', frame, off, data) / ('K', frame, ch, table, entry bytes, descriptor bytes)"""
    ev = []
    for line in path.read_text().splitlines():
        t = line.split()
        if t[0] == "W":
            ev.append(("W", int(t[1]), int(t[2], 16), int(t[3], 16)))
        elif t[0] == "K":
            ev.append(("K", int(t[1]), int(t[2]), int(t[3], 16), bytes.fromhex(t[4]), bytes.fromhex(t[5])))
    return ev


def decode(entry, desc):
    freq = entry[0] << 8 | entry[1]
    word1 = entry[2] << 8 | entry[3]
    b0 = desc[0]
    start = (b0 << 16 | desc[1] << 8 | desc[2]) & 0xffffff
    lstart = ((b0 & 0xf0) << 16 | desc[3] << 12 | desc[4] << 4 | desc[5] >> 4) & 0xffffff
    lend = ((b0 & 0xf0) << 16 | (desc[5] & 0xf) << 16 | desc[6] << 8 | desc[7]) & 0xffffff
    return dict(freq=freq, word1=word1, base=entry[4] << 8 | entry[5], start=start, lstart=lstart, lend=lend,
                adpcm=bool(desc[8] & 8))


def hist(c, n=12):
    return " ".join(f"{k:02x}:{v}" for k, v in c.most_common(n)) + (f" (+{len(c) - n})" if len(c) > n else "")


def analyse(game, ev):
    """MAME's register model replayed over the writes, with what it ignores counted."""
    glob = [0] * 0x12
    chan = [[0] * 16 for _ in range(32)]
    playing = {}                                   # ch -> (frame keyed on, decoded entry)
    r = collections.defaultdict(collections.Counter)
    notes = []                                     # (frame on, frame off or None, ch, decoded, desc)
    keyed = {}                                     # ch -> index in notes
    live = collections.defaultdict(collections.Counter)    # channel-mode writes to a playing voice, by offset
    key1 = []
    pats = collections.Counter()                   # the writes between two key commands ("c": channel mode)
    cur = []
    for e in ev:
        if e[0] == "K":
            _, fr, ch, table, entry, desc = e
            d = decode(entry, desc)
            if ch in keyed and notes[keyed[ch]][1] is None:
                notes[keyed[ch]][1] = ("retrig", fr)
            notes.append([fr, None, ch, d, desc, list(chan[ch])])
            keyed[ch] = len(notes) - 1
            continue
        _, fr, off, v = e
        ch = glob[0xe] & 31
        mode = "ch" if glob[0x11] == 3 else "gl"
        r[(off, mode)][v] += 1
        if off == 0:
            pats[" ".join(cur) + f" | key {v}"] += 1
            cur = []
        else:
            cur.append(f"{off:x}" + ("c" if mode == "ch" else "") + (f"={v}" if off == 0x11 else ""))
        if off == 0:
            r[("key", "")][v] += 1
            if v == 0:
                chan[ch] = glob[:16]
            elif v == 1:
                key1.append((fr, ch, keyed.get(ch) is not None and notes[keyed[ch]][1] is None))
            elif v == 2:
                if ch in keyed and notes[keyed[ch]][1] is None:
                    notes[keyed[ch]][1] = ("off", fr)
        elif off <= 0xd:
            if mode == "ch":
                chan[ch][off] = v
                if ch in keyed and notes[keyed[ch]][1] is None:
                    live[off][v] += 1
            else:
                glob[off] = v
        else:
            if off in (0xf, 0x10) and ch in keyed and notes[keyed[ch]][1] is None:
                live[off][v] += 1
            glob[off] = v
    return r, notes, live, key1, pats


def report(games):
    allr = collections.defaultdict(collections.Counter)
    alllive = collections.defaultdict(collections.Counter)
    w1 = collections.Counter()
    b8 = collections.Counter()       # (descriptor byte 8, loop region inside the sample, held past the loop end)
    gaps_bases = set()               # (set, descriptor address): the descriptors' spacing gives their size
    db = [collections.Counter() for _ in range(24)]
    for g in games:
        p = OUT / f"{g}.log"
        if not p.exists():
            print(f"{g}: no log")
            continue
        ev = parse(p)
        r, notes, live, key1, pats = analyse(g, ev)
        nw = sum(1 for e in ev if e[0] == "W")
        print(f"== {g}: {nw} writes, {len(notes)} key-ons, key values {hist(r[('key', '')])}, "
              f"[211] {hist(r[(0x11, 'gl')] + r[(0x11, 'ch')])}")
        for off in (4, 5, 9, 0xa, 0xb, 0xc, 0xd, 0xf, 0x10):
            gl, ch = r[(off, "gl")], r[(off, "ch")]
            if gl or ch:
                print(f"   [{0x200 + off:3x}] global {hist(gl, 8)}   channel {hist(ch, 8)}")
        if live:
            print("   written to a sounding voice (channel mode, after key-on, before key-off):")
            for off in sorted(live):
                print(f"     [{0x200 + off:3x}] {sum(live[off].values())} writes, {hist(live[off], 8)}")
        print("   commonest write sequences before a key command:")
        for k, c in pats.most_common(6):
            print(f"     {c:6d}  {k}")
        # loops: a voice keyed off (or retriggered) later than MAME's stop at its loop end
        held = 0
        loops = 0
        for fr, end, ch, d, desc, regs in notes:
            ln = d["lend"] - d["lstart"]
            region = 0 < ln < d["lend"] - d["start"]
            loops += region
            past = False
            if d["freq"] and end:
                nat = (d["lend"] - d["start"]) * (1 << 18) / d["freq"] / TICK * 60   # frames to the loop end
                past = end[1] - fr > nat + 2
                held += past
            b8[(desc[8], region, past)] += 1
            gaps_bases.add((g, d["base"]))
            w1[d["word1"]] += 1
            for i in range(24):
                db[i][desc[i]] += 1
        print(f"   notes with a loop region inside the sample: {loops} of {len(notes)}; "
              f"held past MAME's stop at the loop end: {held}")
        for k, c in r.items():
            allr[k] += c
        for k, c in live.items():
            alllive[k] += c
    print("\n== all sets")
    print("   descriptor byte 8 against the loop: byte8 region past count")
    for (b, region, past), c in sorted(b8.items()):
        print(f"     {b:02x} {region:d} {past:d} {c}")
    gaps = collections.Counter()
    for g in games:
        b = sorted(x for s_, x in gaps_bases if s_ == g)
        gaps.update(y - x for x, y in zip(b, b[1:]))
    print(f"   spacing of the descriptor addresses used (per set, sorted): {hist(gaps, 10)}")
    print(f"   note entry word 1: {len(w1)} values, {' '.join(f'{k:04x}:{v}' for k, v in w1.most_common(12))}")
    for i in range(8, 24):
        print(f"   descriptor byte {i:2d}: {hist(db[i], 10)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["run", "report"])
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--frames", type=int, default=3600)
    ap.add_argument("--coin", type=int, default=600)
    ap.add_argument("--start", type=int, default=700)
    ap.add_argument("--rep", type=int, default=0, help="repeat coin and start every N frames")
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    games = a.sets or EOLITH + VAMPHALF
    OUT.mkdir(parents=True, exist_ok=True)
    if a.cmd == "run":
        with ThreadPoolExecutor(a.jobs) as ex:
            for g, ok, tail in ex.map(lambda g: run_one(g, a.frames, a.coin, a.start, a.rep), games):
                print(f"{g}: {'ok' if ok else 'FAILED ' + tail}")
                if not ok:
                    err = OUT / f"{g}.run" / "lua_error.txt"
                    if err.exists():
                        print("   " + err.read_text().strip())
    else:
        report(games)


if __name__ == "__main__":
    main()
