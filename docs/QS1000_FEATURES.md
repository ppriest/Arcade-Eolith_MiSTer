# QS1000: what the games use that MAME ignores

MAME's `qs1000.cpp` ignores the following (both cores' `vh_qs1000_voice.sv` copied it until `loop_pcb`):
- the pitch registers [204]/[205]; the rate comes from the note entry;
- [209]-[20d] and [20f]/[210];
- key value 1;
- the note entry's second word;
- every descriptor byte but byte 8 bit 3 (ADPCM);
- looping: a voice stops at its loop end.

`scripts/qs1000_features.py` logs the 8052's register writes in MAME, with the note entry and descriptor
of each key-on (`scripts/mame/qs1000_features.lua`), and replays MAME's global/channel register split
over them. It ran on every QS1000 set of eolith.cpp, vegaeo.cpp and vamphalf.cpp: 5,400 frames each
(90 s), coin at 600, start at 700, 60,044 key-ons in all.

## Results

- **Notes loop while held.** Confirmed in the Mission Craft PCB recording at three points in the music
  (Recording, below). MAME stops every note at its loop end.
- **Key-off fades a note, it does not cut it.** A note released in its first pass keeps sounding and fades
  over roughly 200-400 ms.
- **The fade time differs by sample**, from under 150 ms to over 1.5 s; probably set by descriptor bytes
  9-13, not yet decoded.
- **In the cores:** looping and one fixed fade rate (`loop_pcb`), on in Eolith and Vamphalf. Eolith board
  build `Eolith_30000013.rbf` (`c9fa5a6`); not yet judged by ear.

## Games and the features they use

From the logs above. Clones log the same as their parent (hidnctcha, ironfortc, hidctch2a, landbrka/b,
penfana, fort2ba, misncrfta, wyvernwg/wyvernwga).

| Game | Core | Notes | Loops MAME cuts short | Velocity values | Live pitch bends | Pitch offsets at key-on | Live volume writes | [20F] |
|---|---|---|---|---|---|---|---|---|
| Hidden Catch | Eolith | 2,274 | 765 | 31 | **274** up | 2 | 0 | `00` |
| New Hidden Catch | Eolith | 2,240 | 750 | 31 | **242** up | 2 | 0 | `00` |
| Hidden Catch 2 | Eolith | 3,332 | 670 | 24 | 0 | 0 | 364 | `00` |
| Puzzle King | Eolith | 3,283 | 265 | 25 | **179** down | 7 | 398 | `00` |
| Land Breaker | Eolith | 2,504 | 457 | 3 | **6** up | 0 | 0 | `00` |
| Steal See | Eolith | 4,419 | 1,382 | 48 | 0 | 0 | 0 | `00` `01` `18` |
| Linky Pipe | Eolith | 2,526 | 608 | 22 | 0 | 0 | 6 | `00` |
| Penfan Girls | Eolith | 2,086 | 343 | 9 | 0 | 0 | 697 | `00` `1a` |
| Iron Fortress | Eolith | 1,573 | 248 | 63 | 0 | 0 | 603 | `00` `1a` |
| Raccoon World | Eolith | 7,291 | 217 | 40 | 0 | 0 | 36 | `00` |
| Candy Candy | Eolith | 2,653 | 135 | 51 | 0 | 0 | 0 | `00` `1a` |
| Wyvern Wings / Wivern Wings | Vamphalf | 1,748 | 266 | 8 | **366** both | 67 | 0 | `02` |
| Mission Craft | Vamphalf | 3,194 | 323 | 15 | 0 | 30 | 1,502 | `02` |
| Hidden Catch 3 | Eolith | 2 | not measured: too little sound in MAME's 90 s | | | | | |
| Fortress 2 | Eolith | 2 | not measured: too little sound in MAME's 90 s | | | | | |
| Hidden Catch 2000 | Eolith | 7 | not measured: too little sound in MAME's 90 s | | | | | |
| Yori Jori Kuk Kuk | Vamphalf | 1 | not measured: too little sound in MAME's 90 s | | | | | |
| Crazy War | Eolith | 0 | not measured: no QS1000 register writes in MAME's run | | | | | |

- **Loops MAME cuts short**: notes with a loop of 16 addresses or more still held (not keyed off or
  retriggered) more than 2 frames after MAME stops them at the loop end. Over all sets, 10,194 of 46,355
  such notes: median 2.6, 90th percentile 11.3 times MAME's play length.
- **Live volume writes**: [206]-[208] written to a playing voice; MAME and the cores already apply them.
- A zero means the feature did not appear in that window, not that the game never uses it.

## Registers and the sample descriptor

| Feature | Evidence | Reading |
|---|---|---|
| [204] pitch | 10 sets (5 games: hidnctch, nhidctch, puzzlekg, landbrk, wyvernwg) write it to sounding voices in channel mode, in steps a frame or two apart: hidnctch `80 87 8e 90 ... 89 84 81 80`, puzzlekg `1a 18 16 ... 04 01 80`, landbrk `80 84 87 8b 8f 90 90 00 80`. Before a key-on it is `80` on 48,897 of 49,171 writes; the rest are `8c`, `90`, `ff`, `1c`, `0c`, ... | Pitch bend, sign-magnitude: bit 7 up, `00` and `80` both zero. Seen from -28 to +16; the step size is unknown |
| [205] | `00` on every write | Coarse pitch or unused |
| [206]-[208] live | Written to sounding voices (ironfort [208]: 603 times) | Already applied: MAME reads the channel's volumes every sample |
| [209] | `40` on every key-on of the Eolith sets, `00` on every one of the Vamphalf sets | A per-firmware constant |
| [20a], [20b], [20c] | `ff`, `00`, `00` on every write | No information from these games |
| [20d] velocity | Set before every key-on, 3 to 63 values per game (ironfort `7f`, `5c`, `29`, ...) | MAME's header table maps MIDI velocity to it. It should scale the amplitude; the curve is unknown |
| [20f]/[210] | Channel mode, every voice, after its key-on: [210] `15`; [20f] `00`, `01`, `02`, `18` or `1a` | Modulation (LFO rate and depth?); MAME files them as globals and never reads them |
| Key value 1 | Always right after [211] = 0, closing a channel-mode block: `11=0, key 1`; `e, 11=3, f, 10, 11=0, key 1` | Part of the bank select, not a voice action |
| Descriptor size | All 798 descriptor addresses used are multiples of 16; spacing 0x10 is commonest | 16 bytes, not MAME's 24: bytes 16-23 are the next descriptor |
| Descriptor bytes 0-7 | Start (bytes 0-2), loop start (byte 0 [7:4], 3-4, 5 [7:4]), loop end (byte 0 [7:4], 5 [3:0], 6-7), as MAME | Known |
| Descriptor byte 8 | Bit 3 is ADPCM (MAME). High bits `c0`/`d0`/`e0`/`40`/`00`; low bits 0-3. Bits 1-0 = 2 covers both the zero-length loops and 7,682 loops of 16 bytes or more | Not a loop on/off flag. Otherwise unknown |
| Descriptor bytes 9, 10, 12, 13 | Vary per sample (byte 9: `ff`, `07`, `10`, `0d`, ...; 10: `03`, `0f`, `02`, ...; 12: `19`, `18`, `1f`, ...; 13: `f0`, `00`, `9d`, ...) | Candidates for the envelope and filter; release rates differ with them (Recording) |
| Descriptor byte 11 | `ff` on 59,815 of 60,044 key-ons | Fixed in these ROMs |
| Descriptor bytes 14, 15 | `00`, `ff` on 59,680 key-ons (`00 00` on the rest) | Padding or unused |
| Loop length 0 or below 16 | 6,025 key-ons with loop start = loop end, 7,664 with a loop under 16 addresses (`0a`: start 0f1643, loop 0f265e-0f265f) | One-shots that end on a loop of silence |
| Note entry word 1 | 85 values (`19af`, `69af`, `69ff`, `117f`, ...); `0000` on 4,890 key-ons | Unknown |

The usual sequence: `11=0, key 1`, the globals 3 2 1 4-d, `11=3`, [20e] = channel, `key 0`; then
`[20e], 11=3, [20f], [210], 11=0, key 1` sets the voice's modulation once it sounds; key-off is
`[20e], key 2`.

## Recording: Mission Craft

Tested against Vamphalf's PCB recording of a playthrough (`Arcade-Vamphalf_MiSTer/debug/pcb/misncrft_pcb.wav`,
from youtube.com/watch?v=ur5dur6w9L4):
- **Renderer.** `scripts/qs1000_render.py` renders the register writes per note. With MAME's behaviour its
  output against MAME's `-wavwrite` (misncrft, 60-90 s) has correlation 0.9991 and the same RMS.
- **Alignment.** The music of MAME's 10-70 s is in the recording at 10.1, 353.1 and 685.5 s, found by
  spectral correlation.
- **Method.** The recording is lossy and has the player's effects over the music, so loud renders win any
  level comparison. Shifting a sustain's repeats a semitone sharp still cut the error from 11.1 to 7.4 dB,
  against 6.6 at the right pitch. `scripts/qs1000_pcb_evidence.py` therefore measures pitch-specific evidence
  E: in a window of time, the recording's level where the right pitch is loud minus where a semitone-sharp
  copy is (dB, bands normalised).

```
python scripts/qs1000_pcb_evidence.py misncrft <wave.txt> <pcb.wav> --from 10 --to 70 --rec-at 10.1 353.1 685.5 --per-sample
```

| Window (music, 5,689 looped notes in 60 s) | E at the three positions (dB) | 5 s blocks positive |
|---|---|---|
| Keyed, after MAME's stop at the loop end | +1.75 +1.85 +1.96 | 83% |
| Keyed off in the first pass, 0-100 ms after | +1.35 +1.39 +1.33 | 89% |
| the same, 100-200 / 200-400 ms after | +0.41 +0.68 +0.60 / +0.54 +0.21 +0.37 | 83% / 72% |
| the same, 400-800 / 800-3200 ms after | +0.16 -0.66 -0.43 / -0.02 -0.51 -0.47 | 56% / 44% |
| Keyed off in the repeats, 0-100 / 100-200 ms after | +0.01 +0.26 +0.33 / +0.27 +0.04 +0.16 | 47% / 61% |

Readings:
- **Looping while keyed.** Supported.
- **Key-off.** It does not cut a note: the first pass carries on and fades over 200-400 ms. MAME's disabled
  code would play on unfaded to the loop end (first pass: median 1,011 ms).
- **Release per sample.** The fade varies by sample, with different descriptor bytes 9-13:

| Descriptor | Notes | Bytes 9-13 | E 0-150 ms | E 150-500 ms | E 500-1500 ms | Reading |
|---|---|---|---|---|---|---|
| 1170 | 1,212 | `14 2f ff 19 10` | +1.37 | +0.35 | +0.49 | Still sounding after 1.5 s |
| 08c0, 08b0 | 326, 162 | `ff 0f ff 1f 9d` | +0.57, +0.23 | +0.29, +0.45 | 0.00, -0.04 | Gone within about 0.5 s |
| 0870, 0880 | 117, 96 | `08`/`07 1f ff 1e 38` | -0.18, -0.05 | +0.19, +0.09 | -0.28, -1.81 | Gone within about 150 ms |

E within +/-0.5 dB is within the spread of the windows that should hold nothing.

## Recording: Wyvern Wings

youtube.com/watch?v=Z-N96wzJN7I, 336 s (`debug/qs1000_pcb/wivernwg_pcb.webm`, not in the repository):
**not usable this way.** No MAME window matched it by spectral correlation beyond 2 standard deviations; the
music is the 0x00xx table family, the effects 0x01xx. That held for:
- a plain run and one with P1 invincibility and infinite lives (`scripts/qs1000_capture.py --poke`);
- playback speeds 0.90-1.10;
- alignment on the stage start (recording silent 12.1-14.6 s; MAME's music resumes at 14.4 s), giving
  keyed-window E under +0.6 dB at every offset from 14.45 to 15.25 s.

The effects cover the music in this recording.

## In the cores

`vh_qs1000_voice.sv` (Arcade-Vamphalf_MiSTer `e2c2e27`, vendored here) with `loop_pcb` high:
- A voice whose address reaches its loop end goes back to its loop start, ADPCM with the decoder state it
  had before the loop start's nibble (MAME's disabled save/restore). The wrap is made in S2's write-back.
- Key-off fades the voice: env -= env >> 8 on every 732nd tick, a time constant of 0.25 s, the same for
  every sample (`docs/HACKS.md`); the voice stops below -48 dB.
- On in `Eolith.sv` and `Vamphalf.sv`; Limenko and the benches keep MAME's behaviour (`loop_pcb` low).

Checks: against `scripts/qs1000_model.py --loop pcb` (Vamphalf), 0 of 3,000,000 sums differ on misncrft and
on wivernwg (`sim/qs1000v_tb +loop=pcb`, ROM latency 40-55 clocks); with `loop_pcb` low, 0 of 3,000,000 differ
from MAME's model. The Eolith build meets timing (clk_sys +0.521 ns).

## Open

- The per-sample release rate, probably descriptor bytes 9-13: more instruments, from recordings whose music
  is not covered by effects. A Hidden Catch recording would also give the pitch-bend step size.
- Velocity, pitch bend, modulation and the rest of byte 8.
- The 8052 firmware's mapping from the commands it receives to these registers would give the velocity and
  pitch scaling exactly.

## Tools

```
python scripts/qs1000_features.py run [SET ...] --frames 5400      # register logs, debug/qs1000_feat/
python scripts/qs1000_features.py report [SET ...]
python scripts/qs1000_capture.py <set> --frames N [--poke ADDR=VAL,...] --out DIR   # tick-stamped capture
python scripts/qs1000_render.py <set> <wave.txt> --from S --to S --out x.wav [--loop keyed] [--release ...]
python scripts/qs1000_pcb_evidence.py <set> <wave.txt> <recording.wav> --from S --to S --rec-at S [S ...]
```
