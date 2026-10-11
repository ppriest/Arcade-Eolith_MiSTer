#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the .mra files and prove each one byte for byte.

    python scripts/build_mra.py                      # every set -> releases/
    python scripts/build_mra.py crazywar             # one set
    python scripts/build_mra.py --check              # verify only, write nothing
    python scripts/build_mra.py --image crazywar out.bin   # the download image, for the benches

The image is the SDRAM layout of rtl/eo_sdram_map.svh, whose SD_* localparams are read here. Each
region is built twice: by this script's loader from the driver's ROM_START records
(scripts/extract_romstart.py), and by re-reading the written .mra with scripts/mra.py (mra-tools-c's
semantics); the two must be identical. The interleave map of a ROM_LOAD32_WORD_SWAP pair is not
reasoned about: each candidate is tried against the ROM_START image and the one that reproduces it
is written. scripts/mame_cpuview.py checks the ROM_START image against what MAME's CPU reads.
After Arcade-Vamphalf_MiSTer's scripts/build_mra.py.
"""
import argparse
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
import extract_dips as edips       # noqa: E402
import extract_romstart as ers     # noqa: E402
import mra as mra_lib              # noqa: E402
from coretools import setting      # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DRIVER_DIR = Path(setting("MAME_SRC") or "E:/mame/src/mame/eolith/eolith.cpp").parent
ROMDIRS = [Path(p) for p in (setting("MAME_ROMPATH") or "F:/Emulation/roms/MAME ROMs").split(";")]
OUT_DIR = REPO / "releases"

# set: (parent or None, driver file, board type for the mod byte (Eolith.sv), MAME rotation)
BOARD_VEGA, BOARD_GRAD, BOARD_E16 = 0, 1, 2
SETS = {
    "crazywar": (None, "vegaeo.cpp", BOARD_VEGA, 0),
    "hidnctch": (None, "eolith.cpp", BOARD_GRAD, 0),
    "hidnctcha": ("hidnctch", "eolith.cpp", BOARD_GRAD, 0),
    "linkypip": (None, "eolith.cpp", BOARD_GRAD, 0),
    "ironfort": (None, "eolith.cpp", BOARD_GRAD, 0),
    "ironfortc": ("ironfort", "eolith.cpp", BOARD_GRAD, 0),
    "puzzlekg": (None, "eolith.cpp", BOARD_GRAD, 0),
    "candy": (None, "eolith.cpp", BOARD_GRAD, 0),
    "hidctch2": (None, "eolith.cpp", BOARD_GRAD, 0),
    "hidctch2a": ("hidctch2", "eolith.cpp", BOARD_GRAD, 0),
    "hidnc2k": (None, "eolith.cpp", BOARD_GRAD, 0),
    "landbrk": (None, "eolith.cpp", BOARD_GRAD, 0),
    "landbrka": ("landbrk", "eolith.cpp", BOARD_GRAD, 0),
    "landbrkb": ("landbrk", "eolith.cpp", BOARD_GRAD, 0),
    "nhidctch": (None, "eolith.cpp", BOARD_GRAD, 0),
    "penfan": (None, "eolith.cpp", BOARD_GRAD, 0),
    "penfana": ("penfan", "eolith.cpp", BOARD_GRAD, 0),
    "stealsee": (None, "eolith.cpp", BOARD_GRAD, 0),
    "fort2b": (None, "eolith.cpp", BOARD_GRAD, 0),
    "fort2ba": ("fort2b", "eolith.cpp", BOARD_GRAD, 0),
    "hidctch3": (None, "eolith.cpp", BOARD_GRAD, 0),
    "raccoon": (None, "eolith.cpp", BOARD_GRAD, 0),     # MACHINE_NOT_WORKING in MAME: "animation & timers seem too fast?"
    "klondkp": (None, "eolith16.cpp", BOARD_E16, 0),
}
# mod byte bits above the board type: [2] light pens (hidctch3_state)
MOD_EXTRA = {"hidctch3": 0x04}
# Memory wait states (rtl/eo_busws.sv), clocks of 57.27 MHz per access: (MEM3, MEM0-2), the .mra's bytes 1-2.
# From the BCR the set writes at boot (MAME traces, debug/bcr; e132xs.cpp update_bus_control): raccoon 0xfa1501c4,
# MEM3 11 + 1 hold cycles and MEM0-2 2 cycles at 45 MHz, 15 and 2 clocks; on the board it then runs at about
# the right speed (the user), which it does not at 0. The other sets' BCRs ask for MEM3 8 + 1 and 2-cycle RAM
# (about 11 and 2 clocks); left at 0 until measured.
WAITS = {"raccoon": (15, 2)}
# A default 93C66, sent as <rom index="2"> before the <nvram> tag, so a saved .nvm replaces it
# (Main_MiSTer mra_loader.cpp sends each <rom> at its end tag and the .nvm at <nvram>'s). {offset: bytes}, FF
# elsewhere. hidctch3: what the game writes from a blank EEPROM in MAME, with PEN TEST clicked at the centre
# by each pen at 80, 60 and RESET DATA READING (debug/hc3cal): MAIN SETUP's defaults at 0x00 (level 6, life 3,
# 2 coins a credit, demo sound off, game sound on, Korea, free play off), COIN / CREDIT / SERVICE CREDIT at
# 0x14 / 0x18 / 0x1c, the pens' offsets at 0x20 (P1 X, Y, P2 X, Y; 16-bit sign-magnitude, dots). Language
# English (0x06 = 1, as the game saved it on the board when set from MAIN SETUP) instead of Korea (0).
EEPROM_DEFAULT = {"hidctch3": {0x00: bytes.fromhex("cb06030200010100"), 0x14: bytes(20)}}
# MAME's patch_mcu_protection (eolith.cpp 1726-1730): the program ROM's dword at the address gets 0x0300 in
# its high halfword ("Change BR to NOP"; the region is the CPU's big-endian view, so bytes 03 00 at the
# address). The AT89C52 sets run a substitute sound program that fails a check the patch skips.
PATCHES = {
    "hidctch2": [(0x0bcc8, b"\x03\x00")],
    "hidnc2k": [(0x17b2c, b"\x03\x00")],
    "landbrka": [(0x14f00, b"\x03\x00")],
    "landbrkb": [(0x14da8, b"\x03\x00")],
}
# per game (parent): the panel's button names, from the game where it shows them
BUTTONS = {
    # four slots, "-" unused: mame_keys puts keys on buttons 3-4, so Start and Coin sit at bits 8-9
    "crazywar": ["Shot", "Button 2", "-", "-"],   # "SHOT": the tutorial (debug capture f1545); button 2 not seen named
    # the how-to-play screens show only "A": the joystick moves the marker, A marks the spot (attract
    # capture debug/hidnctch-attract f1600); MAME's button 2 is not shown
    "hidnctch": ["Mark", "-", "-", "-"],
    # the game shows no name; in the demo the hand cursor picks a card up and puts it down
    # (debug/klondkp-attract)
    "klondkp": ["Pick", "-", "-", "-"],
    # the Hidden Catch games share hidnctch's controls (MAME: the same ports, hidctch2 adds nothing)
    "hidctch2": ["Mark", "-", "-", "-"],
    "hidnc2k": ["Mark", "-", "-", "-"],
    "nhidctch": ["Mark", "-", "-", "-"],
    "hidctch3": ["Pen", "-", "-", "-"],   # the light pen's button (MAME: BUTTON1 on IN0 23:16); the pen is the left stick
    # not seen named yet: MAME's buttons
    "linkypip": ["Button 1", "Button 2", "Button 3", "-"],
    "ironfort": ["Button 1", "Button 2", "-", "-"],
    "puzzlekg": ["Button 1", "Button 2", "-", "-"],
    "candy": ["Button 1", "Button 2", "-", "-"],
    "landbrk": ["Button 1", "Button 2", "-", "-"],
    "penfan": ["Button 1", "Button 2", "-", "-"],
    "stealsee": ["Button 1", "Button 2", "-", "-"],
    "fort2b": ["Button 1", "Button 2", "-", "-"],
    "raccoon": ["Button 1", "Button 2", "-", "-"],
}
CATEGORY = {"crazywar": "Shooter", "hidnctch": "Puzzle", "klondkp": "Card", "hidctch2": "Puzzle", "hidnc2k": "Puzzle",
            "nhidctch": "Puzzle", "linkypip": "Puzzle", "ironfort": "Shooter", "puzzlekg": "Puzzle", "candy": "Puzzle",
            "landbrk": "Puzzle", "penfan": "Puzzle", "stealsee": "Puzzle", "fort2b": "Shooter", "hidctch3": "Puzzle",
            "raccoon": "Platform"}


def sdram_map():
    text = (REPO / "rtl" / "eo_sdram_map.svh").read_text(encoding="utf-8")
    m = {k: int(v, 16) for k, v in re.findall(r"localparam \[26:0\] (SD_\w+)\s*=\s*27'h([0-9a-fA-F]+);", text)}
    for k in ("SD_DATA", "SD_PRG", "SD_SNDPRG", "SD_SNDCPU", "SD_SMP", "SD_SNDDATA", "SD_WRAM", "SD_IMAGE_END",
              "SD_IMAGE_END_G", "SD_IMAGE_END_K"):
        if k not in m:
            sys.exit(f"{k} missing from rtl/eo_sdram_map.svh")
    return m


def game_info(text, setname):
    m = re.search(r"GAME\(\s*(\d+)\s*,\s*" + setname + r"\s*,\s*(\w+)\s*,.*?,\s*ROT(\d+)\s*,\s*\"([^\"]*)\"\s*,\s*\"([^\"]*)\"", text)
    if not m:
        sys.exit(f"no GAME line for {setname}")
    # GAME(year, name, parent, machine, input, class, init, ...): the input ports' name
    f = [x.strip() for x in text[m.start():].split("(", 1)[1].split(",")[:7]]
    return {"year": m.group(1), "rot": int(m.group(3)), "manufacturer": m.group(4), "title": m.group(5),
            "ports": f[4]}


def zips_for(setname):
    names = [setname + ".zip"]
    if SETS[setname][0]:
        names.append(SETS[setname][0] + ".zip")
    found = []
    for n in names:
        for d in [REPO / "roms"] + ROMDIRS:
            if (d / n).exists():
                found.append(d / n)
                break
    return names, found


def load_region(zs, records, size):
    """ROM_START records -> region bytes, as MAME's loader puts them (zero fill)."""
    out = bytearray(size)
    for kind, name, dest, length, crc, *rest in records:
        data = mra_lib._zip_read(zs, name, crc)
        assert len(data) == length, (name, len(data), length)
        if kind == "load":
            out[dest:dest + length] = data
        elif kind == "load16_wswap":
            for k in range(length // 2):
                out[dest + 2 * k:dest + 2 * k + 2] = data[2 * k:2 * k + 2][::-1]
        elif kind in ("load32_word", "load32_word_swap"):
            for k in range(length // 2):
                w = data[2 * k:2 * k + 2]
                out[dest + 4 * k:dest + 4 * k + 2] = w if kind == "load32_word" else w[::-1]
        else:
            sys.exit(f"record kind {kind} not handled")
    return bytes(out)


def region_size(body, region):
    m = re.search(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + re.escape(region) + '"', body)
    return int(m.group(1), 16) if m else 0


# DIP names longer than the OSD's 28 columns allow with their settings
DIP_NAME = {"Show Dip-switch Information": "Show DIP Info"}


def switches(ports):
    """The DSW1 <switches> lines (MAME's DSW1, bits 0-7) and the default byte, or ([], None)."""
    edips.SRC = str(DRIVER_DIR / "eolith.cpp")
    all_blocks = edips.load()
    missing = set()
    dips = edips.parse_ports(all_blocks[ports], all_blocks, missing).get("DSW1", [])
    if missing:
        sys.exit(f"{setname}: DEF_STR missing: {', '.join(sorted(missing))}")
    default = 0
    out = []
    for name, mask, dflt, settings in dips:
        default |= dflt
        if settings is None:
            continue
        pos = [i for i in range(8) if mask & (1 << i)]
        assert mask < 0x100 and pos, (name, mask)
        ids = []
        for idx in range(1 << len(pos)):
            v = sum(1 << b for j, b in enumerate(pos) if idx & (1 << j))
            lab = settings.get(v, "-")
            if "," in lab:
                sys.exit(f"{setname}: dip {name!r}: label {lab!r} contains a comma")
            ids.append(lab)
        name = DIP_NAME.get(name, name)
        out.append(f'        <dip name="{escape(name, {chr(34): "&quot;"})}" bits="{",".join(map(str, pos))}" '
                   f'ids="{escape(",".join(ids), {chr(34): "&quot;"})}"/>')
    return out, default & 0xff


def build(setname, sm, write=True):
    parent, drv, board, rot = SETS[setname]
    grad, e16 = board == BOARD_GRAD, board == BOARD_E16
    text = (DRIVER_DIR / drv).read_text(encoding="utf-8", errors="replace")
    body = ers.blocks(text)[setname]
    info = game_info(text, setname)
    assert info["rot"] == rot, setname
    names, paths = zips_for(setname)
    if not paths:
        print(f"{setname}: no zip found ({' / '.join(names)}); skipped")
        return False
    zs = [zipfile.ZipFile(p) for p in paths]
    regions = (("maincpu", "maindata", "oki") if e16 else
               ("maincpu", "maindata", "qs1000:cpu", "qs1000") + (("soundcpu", "sounddata") if grad else ()))
    rec = {}
    for r in regions:
        recs, unknown = ers.region_records(body, r)
        if unknown:
            sys.exit(f"{setname}: region {r}: unparsed {unknown}")
        rec[r] = recs

    # the image this script expects
    end = sm["SD_IMAGE_END_G"] if grad else sm["SD_IMAGE_END_K"] if e16 else sm["SD_IMAGE_END"]
    img = bytearray(end)
    data = load_region(zs, rec["maindata"], region_size(body, "maindata"))
    assert len(data) == (0x200000 if e16 else 0x2000000)
    img[sm["SD_DATA"]:sm["SD_DATA"] + len(data)] = data
    prg = load_region(zs, rec["maincpu"], region_size(body, "maincpu"))
    assert len(prg) == 0x80000
    img[sm["SD_PRG"]:sm["SD_PRG"] + len(prg)] = prg
    for off, pb in PATCHES.get(setname, []):
        img[sm["SD_PRG"] + off:sm["SD_PRG"] + off + len(pb)] = pb
    if e16:
        oki = load_region(zs, rec["oki"], region_size(body, "oki"))
        assert len(oki) == 0x80000 and sm["SD_SMP"] + len(oki) == end
        img[sm["SD_SMP"]:sm["SD_SMP"] + len(oki)] = oki
    snd = load_region(zs, rec["qs1000:cpu"], region_size(body, "qs1000:cpu")) if not e16 else b""
    assert e16 or len(snd) == (0x8000 if grad else 0x80000)
    img[sm["SD_SNDPRG"]:sm["SD_SNDPRG"] + len(snd)] = snd
    if grad:
        scpu = load_region(zs, rec["soundcpu"], region_size(body, "soundcpu"))
        assert len(scpu) == 0x8000 and sm["SD_SNDPRG"] + len(snd) <= sm["SD_SNDCPU"]
        img[sm["SD_SNDCPU"]:sm["SD_SNDCPU"] + len(scpu)] = scpu
        sdat = load_region(zs, rec["sounddata"], region_size(body, "sounddata"))
        assert len(sdat) == 0x80000 and sm["SD_SNDDATA"] + len(sdat) == end
        img[sm["SD_SNDDATA"]:sm["SD_SNDDATA"] + len(sdat)] = sdat
    if not e16:
        smp = load_region(zs, rec["qs1000"], region_size(body, "qs1000"))
        smp_len = (sm["SD_SNDDATA"] if grad else sm["SD_IMAGE_END"]) - sm["SD_SMP"]
        assert not any(smp[smp_len:]), "sample data beyond the space SD_SMP leaves"
        img[sm["SD_SMP"]:sm["SD_SMP"] + smp_len] = smp[:smp_len]
    img = bytes(img)

    # the .mra, part by part, in SDRAM order
    L = []
    pos = 0

    def pad_to(addr, why):
        nonlocal pos
        if addr > pos:
            L.append(f'        <part repeat="0x{addr - pos:X}">00</part>  <!-- {why} -->')
            pos = addr
        assert pos == addr, (why, hex(pos), hex(addr))

    def plain(region, base):
        nonlocal pos
        for kind, name, dest, length, crc, *rest in sorted(rec[region], key=lambda r: r[2]):
            if kind != "load":
                sys.exit(f"{setname}: {region}: {kind} where a plain load was expected")
            pad_to(base + dest, f"{region} 0x{dest:x}")
            L.append(f'        <part name="{escape(name)}" crc="{crc:08x}"/>')
            pos += length

    gl = sorted(rec["maindata"], key=lambda r: r[2])
    if e16:
        L.append("        <!-- maindata: ROM_LOAD16_WORD_SWAP -->")
        for kind, name, dest, length, crc, *rest in gl:
            assert kind == "load16_wswap", kind
            pad_to(sm["SD_DATA"] + dest, f"maindata 0x{dest:x}")
            want = data[dest:dest + length]
            raw = mra_lib._zip_read(zs, name, crc)
            chosen = next((m for m in ("21", "12") if mra_lib.interleave([(raw, m)], 16) == want), None)
            if not chosen:
                sys.exit(f"{setname}: no map reproduces maindata 0x{dest:x}")
            L.append('        <interleave output="16">')
            L.append(f'            <part name="{escape(name)}" crc="{crc:08x}" map="{chosen}"/>')
            L.append('        </interleave>')
            pos += length
        gl = []
    else:
        L.append("        <!-- maindata: ROM_LOAD32_WORD_SWAP pairs -->")
    for i in range(0, len(gl), 2):
        lo, hi = gl[i], gl[i + 1]
        assert lo[0] == hi[0] == "load32_word_swap" and hi[2] == lo[2] + 2 and lo[3] == hi[3], (lo, hi)
        pad_to(sm["SD_DATA"] + lo[2], f"maindata 0x{lo[2]:x}")
        want = data[lo[2]:lo[2] + 2 * lo[3]]
        dlo, dhi = mra_lib._zip_read(zs, lo[1], lo[4]), mra_lib._zip_read(zs, hi[1], hi[4])
        chosen = next(((a, b) for a, b in (("0021", "2100"), ("0012", "1200"), ("2100", "0021"), ("1200", "0012"))
                       if mra_lib.interleave([(dlo, a), (dhi, b)], 32) == want), None)
        if not chosen:
            sys.exit(f"{setname}: no interleave map reproduces maindata 0x{lo[2]:x}")
        L.append('        <interleave output="32">')
        L.append(f'            <part name="{escape(lo[1])}" crc="{lo[4]:08x}" map="{chosen[0]}"/>')
        L.append(f'            <part name="{escape(hi[1])}" crc="{hi[4]:08x}" map="{chosen[1]}"/>')
        L.append('        </interleave>')
        pos += 2 * lo[3]
    pad_to(sm["SD_PRG"], "maindata end")
    L.append("        <!-- maincpu -->")
    plain("maincpu", sm["SD_PRG"])
    pad_to(sm["SD_SNDPRG"], "maincpu end")
    if e16:
        pad_to(sm["SD_SMP"], "maincpu end")
        L.append("        <!-- oki -->")
        plain("oki", sm["SD_SMP"])
        pad_to(len(img), "image end")
    else:
        L.append("        <!-- qs1000:cpu -->")
        plain("qs1000:cpu", sm["SD_SNDPRG"])
        if grad:
            pad_to(sm["SD_SNDCPU"], "qs1000:cpu end")
            L.append("        <!-- soundcpu -->")
            plain("soundcpu", sm["SD_SNDCPU"])
            pad_to(sm["SD_SMP"], "soundcpu end")
        else:
            pad_to(sm["SD_SMP"], "qs1000:cpu end")
        L.append("        <!-- qs1000 samples -->")
        plain("qs1000", sm["SD_SMP"])
        if grad:
            pad_to(sm["SD_SNDDATA"], "samples end")
            L.append("        <!-- sounddata -->")
            plain("sounddata", sm["SD_SNDDATA"])
        pad_to(len(img), "image end")
    assert pos == len(img), (hex(pos), hex(len(img)))

    game = BUTTONS[parent or setname]
    named = [n for n in game if n != "-"]
    btn_names = ",".join(game + ["Start", "Coin", "Pause", "Service Coin", "Service Mode"])
    btn_def = ",".join(["A", "B", "X", "Y"][:len(named)] + ["Start", "Select", "L", "R"])
    title = info["title"]
    sw, sw_def = switches(info["ports"]) if grad else ([], None)
    sw_xml = ([f'    <switches default="{sw_def:02X}" base="0">', *sw, "    </switches>", ""] if sw else [])
    ee_xml = []
    if setname in EEPROM_DEFAULT:
        assert grad, setname
        ee = bytearray([0xff] * 512)
        for off, b in EEPROM_DEFAULT[setname].items():
            ee[off:off + len(b)] = b
        ee_xml = ["    <!-- the default EEPROM (build_mra.py EEPROM_DEFAULT); a saved .nvm, sent at <nvram>, replaces it -->",
                  '    <rom index="2"><part>',
                  *["        " + " ".join(f"{x:02X}" for x in ee[i:i + 32]) for i in range(0, 512, 32)],
                  "    </part></rom>", ""]
    xml = [
        "<misterromdescription>",
        f"    <!-- Generated by scripts/build_mra.py from MAME {drv}; the layout is",
        "         rtl/eo_sdram_map.svh. Do not edit by hand. -->",
        f"    <name>{escape(title)}</name>",
        f"    <setname>{setname}</setname>",
        "    <rbf>Eolith</rbf>",
        f"    <mameversion>{mame_version()}</mameversion>",
        f"    <year>{info['year']}</year>",
        f"    <manufacturer>{escape(info['manufacturer'])}</manufacturer>",
        f"    <category>{CATEGORY[parent or setname]}</category>",
        "    <rotation>horizontal</rotation>",
        f'    <buttons names="{btn_names}" default="{btn_def}" count="{len(named)}"/>',
        "",
        "    <!-- mod byte (Eolith.sv): [1:0] board type, 0 Vega, 1 Gradation 2D, 2 eolith16; [2] light pens; then the",
        "         memory wait states, clocks per MEM3 and per MEM0-2 access (rtl/eo_busws.sv) -->",
        f'    <rom index="1"><part>{board | MOD_EXTRA.get(setname, 0):02X} {WAITS.get(parent or setname, (0, 0))[0]:02X} '
        f'{WAITS.get(parent or setname, (0, 0))[1]:02X}</part></rom>',
        "",
        "    <!-- address: the HPS puts the image in DDR3 and the core copies it to SDRAM (rtl/memory/vh_rom_loader.sv) -->",
        f'    <rom index="0" zip="{"|".join(names)}" md5="none" address="0x30000000">',
        *L,
        *[f'        <patch offset="0x{sm["SD_PRG"] + off:X}">{" ".join(f"{x:02X}" for x in pb)}</patch>'
          f'  <!-- patch_mcu_protection(0x{off:x}) -->' for off, pb in PATCHES.get(setname, [])],
        "    </rom>",
        "",
        *sw_xml,
        *ee_xml,
        "    <!-- the .nvm: AT28C16 (Vega, 2 KB) or 93C66 (512 x 8) -->",
        f'    <nvram index="2" size="{2048 if board == BOARD_VEGA else 512}"/>',
        "</misterromdescription>",
        "",
    ]
    def safe(t):
        return re.sub(r'[\\/:*?"<>|]', "-", t)
    # a clone goes in _alternatives/_<parent's title>/ (MiSTer's arcade folder convention)
    odir = OUT_DIR / "_alternatives" / ("_" + safe(game_info(text, parent)["title"])) if parent else OUT_DIR
    fname = odir / (safe(title) + ".mra")
    odir.mkdir(parents=True, exist_ok=True)
    tmp = fname.with_suffix(".mra.tmp")
    tmp.write_text("\n".join(xml), encoding="utf-8", newline="\n")
    got = mra_lib.build_image(str(tmp), [str(p) for p in paths])
    for z in zs:
        z.close()
    if got != img:
        diff = next((i for i in range(min(len(got), len(img))) if got[i] != img[i]), min(len(got), len(img)))
        tmp.unlink()
        sys.exit(f"{setname}: the .mra image differs from the ROM_START image at 0x{diff:x} "
                 f"({len(got)} vs {len(img)} bytes)")
    if write:
        tmp.replace(fname)
        print(f"{setname}: {fname.name}, image {len(img)} bytes, identical to ROM_START")
    else:
        tmp.unlink()
        print(f"{setname}: image {len(img)} bytes, identical to ROM_START (not written)")
    return img


def mame_version():
    exe = Path(setting("MAME_DIR") or "C:/Emulation/Emulators/MAME") / (setting("MAME_EXE") or "mame.exe")
    out = subprocess.run([str(exe), "-version"], capture_output=True, text=True, timeout=30).stdout
    m = re.match(r"\s*0\.(\d+)", out)
    if not m:
        sys.exit(f"cannot read the MAME version from {exe}")
    return "%04d" % int(m.group(1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--image", nargs=2, metavar=("SET", "OUT"))
    a = ap.parse_args()
    sm = sdram_map()
    if a.image:
        img = build(a.image[0], sm, write=False)
        if img is False:
            return 1
        Path(a.image[1]).write_bytes(img)
        print(f"wrote {a.image[1]}")
        return 0
    ok = True
    for s in a.sets or list(SETS):
        if s not in SETS:
            sys.exit(f"unknown set {s}")
        ok = build(s, sm, write=not a.check) is not False and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
