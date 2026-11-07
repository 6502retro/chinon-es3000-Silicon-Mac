# Chinon ES-3000 serial protocol

Reverse-engineered in November 2026 from the original *ES-3000 for Windows v1.0* driver
(`ESC3K100.DLL`, Monsoon Software, 1995) and serial captures of the original software
talking to a working camera. Every command below has been verified on real hardware
unless marked otherwise.

The ES-3000 was also sold as the **Dycam 10-C**, **Promaster Digital One**, and under
Kodak and Dakota labels. They are reported to be technically identical, so this
document probably applies to them too (untested).

## Physical link

| | |
|---|---|
| Connector | 8-pin mini-DIN on the camera; the PC cable ends in DB9 (RS-232) |
| Settings | **9600 baud, 8 data bits, EVEN parity, 1 stop bit** |
| Wake-up | Hold the line in **BREAK for ~200 ms** before the first command |
| Fast mode | 57600 or 115200 baud for image transfers (switched by command `41`) |

The camera must be on (lens cover slid open). While linked, the LCD shows only
the PC-link icon. The camera drops the link after about 3 minutes of inactivity.

## Commands

Every command is 8 bytes:

```
CMD 00 a b c d e 1A
```

The camera answers with one byte: **`D1` = accepted** or **`E1` = rejected**
(for example, no such picture). After an accepted command it does the work, sends any
data, and then sends **one completion byte: `00` = success**. Anything else is a failure
code. Leave at least 100 ms between commands.

| Cmd | Args | Function (name in DLL) | Completion timeout |
|---|---|---|---|
| `7E` | – | Hello / open session (`Open`) | 5 s |
| `7F` | – | Camera status, one 256-byte packet (`GetCameraStatus`) | 5 s |
| `55` | `00 n` | Info for picture *n*, one 256-byte packet (`GetImageInfo`) | 5 s |
| `56` | `00 n` | Thumbnail for picture *n*, 1024-byte packets (`GetThumbnail`) | 5 s |
| `51` | `00 n` | Full image *n*, 1024-byte packets (`GetImage`) | 5 s |
| `41` | `hh ll` | Switch link speed (`ChangeSpeed`); see below | – |
| `71` | `v` | Resolution: 0 Superfine, 1 Fine, 2 Normal (`SetResolution`) | 5 s |
| `72` | `v` | Flash: 0 Auto, 1 Fill, 2 Off (`SetFlashMode`) | 5 s |
| `73` | `v` | Focus: 0 Multi-spot, 1 Single-spot, 2 Macro (`SetAutoFocusMode`) | 5 s |
| `78` | `v` | Zoom level 0–6 (`SetZoomLevel`) | 5 s |
| `79` | `v` | Zoom mode 0–1 (`SetZoomMode`) | 5 s |
| `74` | `v` | Self-timer 0 off / 1 on (`SetTimer`) | 5 s |
| `75` | `t0 t1 t2 t3 00` | Set clock: *t* = half-seconds since 1994-01-01 00:00, little-endian (`SetTime`) | 5 s |
| `77` | – | Take picture, internal memory (`Shoot`) | 11–25 s by resolution |
| `7C` | – | Take picture, PC card (untested) | 11–25 s |
| `7A` | – | **Erase all pictures**, internal memory (`EraseImages`) | 80 s |
| `7B` | – | Erase all pictures, PC card (untested) | 240 s |
| `76` | – | Copy image to card (`CardCopyImage`, untested) | 30 s |

The value labels for flash and focus follow the order of the original software's icons.
After `77`/`7A` the camera stays silent for a few seconds while it works, so poll `7F`
until it answers.

## Link speed (`41`)

The argument is the first four decimal digits of the baud rate, written as BCD:

| Bytes | Speed |
|---|---|
| `96 00` | 9600 |
| `19 20` | 19200 |
| `38 40` | 38400 |
| `57 60` | 57600 (tested) |
| `11 52` | 115200 (in the original software's speed table; being tested) |

The camera answers `D1` at the old speed; the host then switches its UART. Always switch
back to 9600 before ending a session. If a fast link fails, a 200 ms BREAK followed by
`7E` at 9600 recovers it.

## Data packets

Data comes in fixed-size packets of N bytes followed by an XOR checksum byte
(XOR of all N data bytes). The host acknowledges every packet with **`D2`**.

* status and info: one packet of 256 bytes
* thumbnails and images: packets of 1024 bytes until the completion `00`

A Superfine image is 190 packets (194,560 bytes) and takes about 40 s at 57600 baud.

## Status packet (`7F`)

| Byte | Meaning |
|---|---|
| 11 | pictures left |
| 14–17 | clock: half-seconds since 1994-01-01, little-endian (set with `75`) |
| 21 | lens: bits 0–3 zoom 0–6, bits 4–5 focus mode, bit 6 zoom mode (from `InterpretCameraStatus`) |
| 22 | self-timer (0/1) |
| 23 | resolution (0/1/2) |
| 24 | flash (0/1/2) |
| 29 | battery: 0 good, 1 low (from `UpdateBatteryIcon`; 0 verified on fresh cells) |

## Picture info packet (`55`)

| Byte | Meaning |
|---|---|
| 2 | picture number |
| 4 | resolution (0 SF, 1 F, 2 N) |
| 6–9 | image data size in bytes (192000 / 96000 / 24000), little-endian |
| 10–13 | time taken: half-seconds since 1994-01-01, little-endian |

A camera whose clock was never set counts from 1994-01-01 00:00 at power-up.

## Thumbnails (`56`)

There is no separate thumbnail image. The camera sends the **first byte(s) of every
compressed block of the full picture**, in the same order as the `.DCT` data, padded with
`FF` to a whole number of 1024-byte packets:

| Resolution | Luma blocks | Bytes per luma block | Chroma blocks (Cr then Cb) | Bytes per chroma block | Total → packets |
|---|---|---|---|---|---|
| Superfine | 2400 | 2 (10-bit DC + 6 bits) | 2400 | 2 | 9600 → 10 |
| Fine | 2400 | 1 or 2 (decodes correctly either way) | 2400 | 2 | 7200/9600 → 8/10 |
| Normal | 600 | 1 (8-bit DC) | 600 | 2 | 1800 → 2 |

Decoding only the DC terms gives a 1/8-scale picture: 80×60 for Superfine/Fine and
40×30 for Normal. `decode_thumbnail()` in `chinon_decode.py` does this.

## Typical download session

```
BREAK 200 ms
→ 7E 00 00 00 00 00 00 1A    ← D1 00
→ 7F 00 00 00 00 00 00 1A    ← D1 [256+1] → D2  ← 00
→ 41 00 57 60 00 00 00 1A    ← D1          (now switch the UART to 57600)
→ 55 00 00 01 00 00 00 1A    ← D1 [256+1] → D2  ← 00
→ 51 00 00 01 00 00 00 1A    ← D1 [1024+1] → D2 ... ← 00
→ 41 00 96 00 00 00 00 1A    ← D1          (back to 9600)
```

The raw image bytes, with the 384-byte header described in
[DCT_FORMAT.md](DCT_FORMAT.md), form exactly the `.DCT` file the original software saves.
