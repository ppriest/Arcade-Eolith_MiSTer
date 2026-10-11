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
- **The fade time may differ by sample** (Mission Craft: under 150 ms to over 1.5 s), perhaps set by
  descriptor bytes 9-13; 36 General MIDI recordings do not establish it (MIDI recordings, Envelopes).
- **ADPCM is IMA**, with a wrapping 16-bit signal, not MAME's OKI (A firmware reading, below).
- **[207] is the left volume and [206] the right**, the other way from MAME (MIDI recordings).
- **[204] bends the pitch**, linearly in the rate and about twice as far up as down: +16 is +195 cents on
  Hidden Catch's PCB recording (Recording: Hidden Catch); -24 to -2 are 6.8 cents a step on a General MIDI
  recording (MIDI recordings, Pitch bend). MAME ignores it.
- **In the cores** (In the cores, below): looping, one fixed fade rate, IMA decoding, the stereo order and
  pitch bend, in Eolith, Vamphalf and Limenko. Looping alone was on the board as `Eolith_30000013.rbf`, not
  yet judged by ear; the rest is not yet built here.

## Register map

The 8052 inside the QS1000 writes 0x200-0x211 of its external data space. Two pages: [211] = 0 stages
parameters for the next voice load, [211] = 3 writes the selected voice directly. Sources: our logs of every
QS1000 set (below), the firmware reading the user shared (A firmware reading), MAME's `qs1000.cpp`.

| Register | Meaning | Status | MAME | Cores |
|---|---|---|---|---|
| [200] | Command. Page 0: 1 begins a parameter group. Page 3: 0 stops the selected voice, 2 keys it off (release) | Shared reading; our logs agree (every page-3 stop is followed by a page-0 start) | Starts the voice on 0, clears a flag on 2 | As MAME; 2 starts the fade |
| [201]-[203] | Note table address, [201] most significant | MAME's code (its comment has the order reversed) | Used | Used |
| [204] | Pitch bend: bit 7 up, bits 0-6 magnitude | Shared reading; our logs (ramps 80-90 and 1a-01); the firmware writes floor((bend >> 7) x 2 / 7), a full MIDI bend 18 (MIDI recordings); **measured** +16 = +195 cents (Recording: Hidden Catch), -24..-2 at 6.8 cents a step (MIDI recordings) | Ignored | Rate x (1 + v/128) up, x (1 - v/256) down (`loop_pcb`) |
| [205] | Unknown; always 0 | Logs: `00` on every write | Ignored | Ignored |
| [206] | Right volume | Shared reading; **checked** on three MIDI recordings (MIDI recordings) | Left | Right |
| [207] | Left volume | As [206] | Right | Left |
| [208] | Volume: channel volume x expression, through a table | Shared reading | Used | Used |
| [209] | Unknown: `40` on a melodic key-on, `00` from the modulation handler and effects | Shared reading; logs (`40` Eolith, `00` Vamphalf) | Ignored | Ignored |
| [20a]-[20c] | Unknown; always `ff`, `00`, `00` | Logs | Ignored | Ignored |
| [20d] | Velocity, MIDI velocity through a table | Shared reading; the firmware's table is MAME's (41 `15`, 62 `25`, 90 `4f`, 99 `5b`: MIDI recordings) | Ignored | Ignored |
| [20e] | Voice select; in page 0 also loads the staged 201-210 into the voice and starts it | Shared reading; logs agree | Channel select | Channel select |
| [20f] | LFO depth: `00` off, `01` for mod wheel 1-29, `18` for 30-127, `1a` for automatic vibrato | Shared reading; logs (`00` `01` `02` `18` `1a`) | Ignored | Ignored |
| [210] | LFO rate; always `15` | Shared reading; logs | Ignored | Ignored |
| [211] | Page: 0 staging, 3 the selected voice | MAME, logs | Used | Used |

The sample descriptor (16 bytes) is under Registers and the sample descriptor, below.

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

## Recording: Hidden Catch

youtube.com/watch?v=eNncNAm6a0A: Hidden Catch 1 (`hidnctch`, Gradation 2D), three players, one coin, a full
clear, recorded from the board (its description), 1,483 s (`debug/qs1000_pcb/hidnctch_pcb.wav`, not in the
repository). **Mono**: left and right are equal, so it cannot test the stereo order.

Each sound command rendered alone by the core (`sim/snd_tb +board=1`, a latch file of `24` then the command,
`+aout`), searched for in the whole recording by onset strength (12 s from the render, slid by FFT):

| Commands | Found at (s) | Onset correlation | Notes |
|---|---|---|---|
| `00` | 1461.3 | 0.82 | The title tune, after the game ends; no effects over it |
| `01`, `0d` | 304.5, 5.2, 523, 858 | 0.57 | Round tune |
| `04`, `05`, `06` | 27.6, 326.9, 545.6 | 0.64 | Round tune; each variant best at its own rounds |
| `07`, `08`, `09` | 45.3, 1023.7 | 0.46-0.56 | Round tune |
| `0a`, `0b` | 597.1, 61.5-64.1 | 0.52 | Round tune |
| `10`, `16`, `17` | 227-247, 1142-1145 | 0.42-0.47 | Round tune |
| `19`-`1d` | 88-93, 182-185, 371-375, 1049-1054 | 0.51-0.63 | Round tune |

z-scores 12-18 against the rest of the recording. In the rounds the game's effects, which these renders do
not have, cover the music (level correlation 0.0-0.3), so only the title tune compares cleanly:
- **Notes and tempo** the same (onset correlation 0.82 at 1461.27 s); **tuning** the same within 5 cents.
- **Timbre**: per-frame spectral shape correlation 0.349; the recording has 8-11 dB less below 250 Hz and
  5-7 dB more at 600 Hz and 1.4-2.2 kHz. A fixed EQ raises the correlation to 0.560 (7.0 dB per cell left).
  Every tune found shows the low end 11-18 dB down at 100-160 Hz: a high-pass in the board's output or in the
  capture, which this recording cannot separate.
- **Pitch bend**: the title tune bends one sample (table `01193c`, four voices in unison) three times, up to
  [204] = +16 for 140-170 ms. That sample rendered alone, shifted, best matches the recording during two of
  the holds at +195 cents (correlation 0.25, 0.26; z 3.1, 3.2; 5-cent steps, half-height width 45-75 cents),
  where the unbent mix matches at 0 cents; the third gives no match (0.06). The core now bends (In the cores);
  against the recording in the three holds its spectrum correlates 0.472, 0.425, -0.069 (unbent: 0.468,
  0.409, -0.199).

## In the cores

`vh_qs1000_voice.sv` (Arcade-Vamphalf_MiSTer `f2deb5c`, vendored here). Always:
- ADPCM is IMA, high nibble first, the 16-bit signal wrapping (A firmware reading).
- [207] is the left volume, [206] the right (MIDI recordings).

With `loop_pcb` high (`Eolith.sv`, `Vamphalf.sv`, `Limenko.sv`; the benches keep MAME's behaviour):
- A voice whose address reaches its loop end goes back to its loop start, ADPCM with the decoder state it
  had before the loop start's nibble (MAME's disabled save/restore). The wrap is made in S2's write-back.
- Key-off fades the voice: env -= env >> 8 on every 732nd tick, a time constant of 0.25 s, the same for
  every sample (`docs/HACKS.md`); the voice stops below -48 dB.
- [204] bends the voice's rate by (1 + v/128) up, (1 - v/256) down (`bendmul`: 16384 + 128v, 16384 - 64v in
  2.14 fixed point): `kf_mem` keeps the table entry's rate, `fe_mem` the bent rate the pipeline adds, rewritten
  at key-on (the staged [204]) and on each channel write of [204] (three clocks, between ticks).
  `docs/HACKS.md`: the upward slope rests on one value.
- With `bal_pcb` high: ADPCM x8, PCM x4 (`docs/MAME_KLUDGES.md`, Sound).

Checks (`sim/qs1000v_tb` against `scripts/qs1000_model.py`, Vamphalf; ROM latency 40-63 clocks): with
`loop_pcb` high, 0 of 3,000,000 sums differ on misncrft and on wivernwg, and 0 of 1,000,000 on Hidden Catch's
title tune from its own firmware (32 bend writes; its samples in a bench image); with `loop_pcb` low, 0 of
3,000,000 on misncrft and wivernwg. Not yet built with the bend; the build before it met timing (clk_sys
+0.521 ns).

## Datasheet

HWA Sound Source Co., Ltd., "QS1000", 13 pages (theretroweb.com/chip/documentation/qs1000-67bb29f608df5206279971.pdf):
block diagram, function overview, electrical and timing characteristics, pins, a reference schematic, the
General MIDI instrument and drum lists. **No register map, no ROM descriptor format, no envelope or filter
parameters.** What it does settle or suggest:
- **Commands are MIDI**, 31.25 kbps into the 8052's RXD pin (block diagram, schematic); the firmware is a
  General MIDI interpreter and the hardware takes each voice's parameters from the ROM itself ("parameter
  self-extracting module"). Logging the MIDI into the chip against the register writes would give the
  velocity curve, the pitch-bend step and the controller mappings directly.
- **The voice hardware** has a wave generator, a digital filter ("multistage", 128 cutoff levels, slopes
  "from 12db to 96db", which can track note or velocity), "vibrato & LFO", a "2-dimensional envelope
  generator", and mixing and panning: the parts MAME leaves out.
- **Looping** has three modes: "auto reload looping", "non-looping" and "one short looping" (one-shot).
  Byte 8's low bits may select among them; untested.
- **Clock.** The reference design has a 24 MHz crystal; master clock mode 0 is an internal 48 MHz (Table 1).
  Playback is quoted as 44.1 kHz, which is mode 1's external 45.1584 MHz / 1024. At 48 MHz the same divider
  gives 46.875 kHz, the rate both cores output (an inference: the board's clock-select pins are not known).
- **Samples**: "Q-PCM", 16-bit sound compressed 8:1; sound ROM up to 16M x 8; HWA's General MIDI library ROMs
  QS1001 (4M) and QS1003 (16M), the size set on P3 pins. The Eolith sets' common `qs1001a.u96` is that library.

## MIDI recordings

wavetable.nl has General MIDI files with recordings on many devices, MP3 at 44.1 kHz stereo, kept in
`D:\wavetable_qs1000` (not in the repository; 42 tracks):
- **Serdaco Qwave**: a QS1000 with the QS1001A sample ROM (VOGONS, vogons.org/viewtopic.php?p=1043844), the
  ROM whose descriptor table Hidden Catch 3's `u97` copies. The reference. Where the site has a `_FIXED` MIDI
  file, the Qwave played the original.
- **LG MIDI ART GS1000R**: no source names its chip (LG Semicon took over AdMOS). Used for the first results
  below; the Qwave matches the render better on all five tracks compared (spectral shape: Nachtmusik 0.854
  against 0.731, Canyon 0.431/0.393, Passport 0.662/0.580, Gabriel Knight 0.770/0.763, Egypt 0.605/0.579).

`scripts/qs1000_midi.py run` plays a file into the
Gradation 2D QS1000's own firmware: `sim/snd_tb +midi` sends the bytes at 31.25 kbps on the 8052's serial input
(each a full 10-bit frame: a stop bit cut short dropped bytes in dense passages) and logs the voice
registers, and the core's own output to `audio.wav` (`+aout`; against `render` of the same writes, 10 ms
log-envelope correlation 0.9989 on Nachtmusik); `render` and `compare` set the result against the recording.
`compare`'s alignment (spectral flux) is wrong on some tracks; `scripts/qs1000_envfit.py` aligns on note onsets.
Hidden Catch 3's firmware and samples:
- **Note for note**: 177 key-ons for 174 note-ons in Canyon's first 9 s; a note-on's key-on follows in 1.2 ms
  (median).
- **Stereo**: each sound's left-right level difference against the recording's correlates -0.386 (Canyon),
  -0.287 (Doom E1M1) and -0.115 (Doom E1M8) with MAME's mapping: [206] is the right volume, [207] the left, as
  the shared reading says. Both cores now have it so (Arcade-Vamphalf_MiSTer `eee9828`): Canyon +0.386.
  Those were LG recordings; on the Qwave, at the onset alignment, Passport +0.350 (80% of the cells panned
  over 3 dB on the same side), Egypt +0.229, Gabriel Knight +0.176, Canyon -0.150 (51%).
- **The firmware's conversions**: velocity through MAME's table; pitch bend to [204] = floor((bend >> 7) x 2/7),
  sign-magnitude (Doom E1M1's bends +384 to +2048: 0, 1, 2, 3, 4), so a full bend is 18; [20f] `00` and [210]
  `15` written with every note.
- **Samples**: the start of Hidden Catch 3's `u97` is `qs1001a`'s descriptor table moved by 0x80000 (each
  descriptor's top nibble 8 higher), so the firmware plays HWA's General MIDI samples from `qs1001a`.
- **Timbre**: per-frame spectral shape correlation 0.13-0.65, against 0.78 for MAME's Mission Craft music on its
  PCB recording (LG). The Qwave and LG recordings correlate 0.71-0.89 with each other, more than either does
  with the render, so most of the difference is in the engine: the voice filter (the datasheet's 128-level
  multistage filter) and the envelopes, which nothing implements. Untested.
- **Pitch bend** (Qwave). Each bent note rendered alone and unbent, shifted against the recording in its
  bent stretches (a [204] value held 50 ms or more), the correlation summed over stretches per value:
  Descent's Level 1 ramps down through -24 to -2 (4-12 stretches a value) at 6.8 cents a step (rms 5.4 cents
  about the line; -24 at -165 cents, where 1/8 semitone gives -300). Rules against those 22 values (rms):
  x (1 + v/256) 6.4 cents, 1/16 semitone 9.5, 1/8 semitone 84, x (1 + v/128) 115. Upward, only Hidden Catch's
  +16 = +195 cents (Recording: Hidden Catch), so the cores bend x (1 + v/128) up, x (1 - v/256) down.
  The core against the recording in the bent stretches (log-spectrum correlation; none / 1/8 semitone /
  linear): Descent Level 1, 62 stretches, 0.719 / 0.722 / 0.755 (the data the downward slope came from);
  Descent II's briefing, -28 held in 447 stretches, 0.696 / 0.673 / 0.690, still below no bend (unexplained;
  its bent notes alone match best at -60 cents, barely above no shift); Quest for Glory 4's intro (+15, -2),
  69 stretches, 0.425 / 0.439 / 0.431. Whole-track spectral shape moves by 0.002 at most.
- **Envelopes** (`scripts/qs1000_envfit.py`, five 60 s runs against the Qwave: Nachtmusik, Canyon, Passport,
  Gabriel Knight, Egypt; 4,570 notes on 40 descriptors). Every note's stem, rendered with no envelope, times
  an envelope in time bins after note-on and after key-off, fitted to the recording's band power by
  non-negative least squares, with a level per descriptor and band gains per track:
  - One envelope for all: flat while keyed to about 500 ms, then -2 to -4 dB over seconds; after key-off -4 dB
    at 85 ms, -8 at 185, -12 at 350, -13.5 at 600, then a floor near -10 dB (the room or other notes). The
    cores' fade (tau 0.25 s) gives -6.4 dB at 185 ms and -12.2 at 350.
  - Per descriptor, some decay while keyed: 0950 (bytes 9-13 `ff 06 ff 1f 9d`) -9 dB at 475 ms, 0980 (`ff 04
    ...`) -6 dB at 800 ms, 0ef0 (`73 03 ff 19 08`) -3.4 dB at 2 s; 08c0 (`ff 0f ff 1f 9d`, 958 notes) releases to
    -13.7 dB at 350 ms and -22.7 at 950.
  - Bytes 9-13 as the envelope's key, over 36 tracks (all 42 but six that align poorly; 132 descriptors):
    one envelope per set of bytes 9-13 or per descriptor fits the tracks it was fitted on better (0.896,
    0.876 against 0.932 for one shared), but on held-out tracks (three folds, each fitted on 24 and scored
    on the other 12) neither does better than one shared envelope: mean 0.964 and 0.970 against 0.962. The
    per-instrument differences above are not established. Drums (no loop) are fitted as a level only.
  - Velocity: power proportional to [20d] fits better (0.2245) than [20d] squared (0.2477) or none (0.2311)
    (the per-descriptor fit, before descriptor levels).

## A firmware reading (shared by the user, not ours)

From someone working from the firmware and wavetable.nl's recordings, who reports a MAME change to come.
Not verified here except where noted:
- **ADPCM is IMA, not OKI, and the signal wraps instead of saturating.** Stock IMA (saturating) puts a
  large DC offset on the cymbals. Both cores decode OKI, as MAME does. **Checked** on the 10 ADPCM samples of
  Mission Craft's music (`scripts/qs1000_render.py` `Rom(adpcm=...)`):

  | Decoder | Median DC / RMS (90th percentile) | Most tonal decode (spectral flatness) |
  |---|---|---|
  | OKI (MAME, both cores) | 0.508 (0.910) | 2 of 10, by 1% |
  | IMA, 16-bit signal wrapping, high nibble first | **0.004 (0.008)** | **8 of 10** (258e69: 0.0008 against OKI's 0.0043) |
  | IMA, wrapping, low nibble first | 0.179 (0.623), large jumps throughout | - |
  | IMA, saturating | 0.005 (0.098) | 0 (26c36d: 0.2731 against wrapping's 0.2421) |

  **In the cores** (Arcade-Vamphalf_MiSTer `775c0ae`, vendored): IMA replaces OKI; with the PCB balance ADPCM
  x8 and PCM x4, since IMA's music is 12.9 dB lower at the same gain (`docs/HACKS.md`). `sim/qs1000v_tb`
  against `qs1000_model.py` (IMA): 0 of 3,000,000 sums differ on misncrft and wivernwg.

  Against the recording the two decoders are close: the error after a per-band gain fit is 0.30-0.35 dB
  lower with IMA at all three positions, the per-frame spectral shape correlation 0.022-0.025 higher with
  OKI. The sample statistics are the stronger evidence.
- [200]: page 0, 1 = begin a parameter group; page 3, 0 = stop the selected voice, 2 = key off (release).
  [20e] in page 0 loads the staged 201-210 into the voice and starts it. **Checked:** every [200] = 0 (page
  3, where MAME starts a voice) is followed within 40 writes by a page-0 [20e] start of the same voice, so
  MAME's start-on-stop gives the same notes: hidnctch 2,274 of 2,274, misncrft 3,194 of 3,194, wivernwg
  1,748 of 1,748, candy 2,652 of 2,653 (one spurious retrigger in MAME).
- [201]-[203]: the address, [201] the most significant byte (as MAME's code, not its comment).
- [204]: pitch multiplier offset, bit 7 up, bits 0-6 the magnitude (as read above; the scale unknown).
- **[206] right volume, [207] left**: MAME has them the other way round. **Checked** on three MIDI recordings
  (MIDI recordings); the cores now follow it.
- [208]: channel volume x expression through a table. [20d]: velocity through a table.
- [209]: `40` on a melodic key-on, `00` from the modulation handler and sound effects.
- [20f]: LFO depth: `00` off, `01` for mod wheel (CC1) 1-29, `18` for 30-127, `1a` for programs with
  automatic vibrato. [210]: LFO rate, always `15`. [205], [20a]-[20c]: always `00`, `ff`, `00`, `00`.

## Open

- The envelope format, probably descriptor bytes 9-13: 36 Qwave tracks do not resolve it (Envelopes). The
  fit explains little of the recordings (held-out residual near 0.96), so the voice filter and the timbre are
  the larger error and come first.
- Upward pitch bends past +16 and more upward measurements: the upward slope (+16 = +195 cents) rests on two
  bends of one Hidden Catch tune. Quest for Glory 4's intro bends up to +15 on the Qwave recordings.
- The PCB output's low-frequency roll-off (Recording: Hidden Catch): the board's or the capture's.
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
python scripts/qs1000_midi.py run <set> <file.mid> --out DIR [--secs S]   # firmware run: wave.txt, audio.wav
python scripts/qs1000_midi.py compare <render.wav|audio.wav> <recording.wav>
python scripts/qs1000_envfit.py stems <set> <wave.txt> <recording.wav> <stems.npz>
python scripts/qs1000_envfit.py fit <set> <stems.npz> ... [--group bytes|desc|all] [--gamma 1]
```
