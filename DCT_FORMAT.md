# Chinon `.DCT` image format

`.DCT` is what the original ES-3000 software saved: a 384-byte header followed by the
raw image data exactly as the camera sends it.

## Header (384 bytes)

| Offset | Value |
|---|---|
| 0 | `Cdcx` |
| 7 | `02` |
| 8 | `80` |
| 9–10 | image length in 256-byte blocks, minus 1 (little-endian) |
| 12 | resolution: 0 Superfine, 1 Fine, 2 Normal |
| others | `00` |

## Image data

The first 128 bytes are an info block. Then come three planes of **fixed-size
DCT-coded blocks**. It is a simplified JPEG with no entropy coding: every block gets
the same number of bits, which is why every picture at a given resolution is exactly the
same size.

| Mode | Image | Luma blocks (8×16 px) | Chroma blocks (8×8, 4:2:0) | Data |
|---|---|---|---|---|
| Superfine | 640×480 | 2400 × 48 bytes | 2 × 1200 × 32 bytes | 192,000 B |
| Fine | 640×480 | 2400 × 24 bytes | 2 × 1200 × 16 bytes | 96,000 B |
| Normal | 320×240 | 600 × 24 bytes | 2 × 300 × 16 bytes | 24,000 B |

Plane order: Y, then Cr, then Cb. Blocks are in raster order.

Inside a block, bits are read **LSB-first**:

* **DC**: luma is unsigned (10 bits in SF, 8 in F/N). Chroma is two's complement,
  **10 bits in SF and 9 bits in F/N**. Reading chroma DC as only 8 bits works for most
  pictures but wraps strongly coloured areas (e.g. orange wood) into the opposite colour.
  Luma DC spans the full brightness range and never wraps, so it must not be "unwrapped".
* **AC**: signed fixed-width fields in zigzag order. The widths shrink toward high
  frequencies, for example `10 9 10 8 10 10 7 8 7 8 …` for Superfine luma.

The exact field widths and dequantisation scales are in `chinon_params.json`. They were
recovered by fitting against pairs of `.DCT` files and the TIFFs the original software
made from them, and the decoder reaches about 29–32 dB PSNR against those TIFFs.

The `post` entry in the parameters is a learned 5×5 filter that reproduces the original
software's output (a half-pixel horizontal shift, mild sharpening, tone) and smooth
chroma upsampling.

## Thumbnails

The camera's thumbnail (command `56`) is the first one or two bytes of every block above,
in the same order: 1 byte per luma block in Normal (2 in Superfine), 2 bytes per chroma
block, padded with `FF`. Decoding just the DC terms gives a 1/8-scale picture.
See [PROTOCOL.md](PROTOCOL.md#thumbnails-56).
