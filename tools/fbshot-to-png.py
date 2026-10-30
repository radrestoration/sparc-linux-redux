#!/usr/bin/env python3
"""Convert a framebuffer screenshot taken on the Ultra with fbcat into a PNG.

    (on the Ultra)  fbcat /dev/fb0 > /tmp/shot.ppm
    (on the PC)     tools/fbshot-to-png.py shot.ppm [shot.png]

The Ultra's framebuffer is 16 bits per pixel (RGB565) in big-endian byte order; fbcat's PPM comes out with each pixel's two bytes
the wrong way round, so the colours are scrambled. This undoes that: it rebuilds each 16-bit pixel from the PPM channels, swaps its
bytes and expands it properly. Needs only python3 (no PIL, no numpy).
"""
import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, 'rb').read()
    fields, pos = [], 0
    while len(fields) < 4:                       # P6 width height maxval, whitespace-separated, # comments allowed
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b'#':
            pos = data.index(b'\n', pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b'P6' or fields[3] != b'255':
        sys.exit('not a P6 PPM with maxval 255')
    return int(fields[1]), int(fields[2]), data[pos + 1:]       # exactly one whitespace byte follows maxval


def png_chunk(tag, body):
    return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) == 3 else src.rsplit('.', 1)[0] + '.png'
    w, h, pix = read_ppm(src)
    if len(pix) < w * h * 3:
        sys.exit('PPM is truncated')
    # look-up tables from the 5/6/5-bit fields to 8 bits
    e5 = [v * 255 // 31 for v in range(32)]
    e6 = [v * 255 // 63 for v in range(64)]
    rows = []
    for y in range(h):
        row = bytearray(b'\0')                   # PNG filter type 0
        for x in range(w):
            i = (y * w + x) * 3
            word = ((pix[i] >> 3) << 11) | ((pix[i + 1] >> 2) << 5) | (pix[i + 2] >> 3)
            word = ((word & 255) << 8) | (word >> 8)
            row += bytes((e5[word >> 11], e6[(word >> 5) & 63], e5[word & 31]))
        rows.append(bytes(row))
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    with open(dst, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', ihdr) + png_chunk(b'IDAT', zlib.compress(b''.join(rows), 6)) + png_chunk(b'IEND', b''))
    print(dst)


main()
