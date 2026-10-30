#!/usr/bin/env python3
"""Decode an ATA IDENTIFY block as printed by Linux in /sys/class/ata_device/devX.Y/id (256 words as 4-digit hex).

usage:  decode-ata-id.py FILE            (FILE = output of: cat /sys/class/ata_device/dev1.0/id)
        ssh root@HOST cat /sys/class/ata_device/dev1.0/id | decode-ata-id.py -

Focus: what the drive (or the bridge in front of it) CLAIMS about DMA/PIO modes and timing, since a bridge can advertise
modes it does not really handle. Field layout from the ATA/ATAPI command set (IDENTIFY DEVICE data).
"""
import sys

def words(text):
    w = [int(t, 16) for t in text.split() if all(c in "0123456789abcdefABCDEF" for c in t) and len(t) <= 4]
    if len(w) < 128:
        sys.exit(f"expected >=128 hex words, got {len(w)}")
    return (w + [0] * 256)[:256]

def string(w, a, b):
    # ATA strings: two characters per word, first character in the high byte
    s = "".join(chr(x >> 8) + chr(x & 0xFF) for x in w[a:b + 1])
    return " ".join(s.split())

def bits(v, names):
    return ", ".join(n for i, n in names if v >> i & 1) or "none"

def main():
    w = words(open(sys.argv[1]).read() if sys.argv[1] != "-" else sys.stdin.read())
    print(f"model:     {string(w, 27, 46)}")
    print(f"firmware:  {string(w, 23, 26)}     serial: {string(w, 10, 19)}")
    cfg = w[0]
    print(f"word 0:    0x{cfg:04x}  ({'ATAPI' if cfg >> 15 & 1 else 'ATA'} device, removable={cfg >> 7 & 1})")
    cap = w[49]
    print(f"word 49:   0x{cap:04x}  capabilities: {bits(cap, [(8, 'DMA'), (9, 'LBA'), (10, 'IORDY can be disabled'), (11, 'IORDY')])}")
    print(f"word 53:   0x{w[53]:04x}  words 64-70 valid={w[53] >> 1 & 1}  word 88 valid={w[53] >> 2 & 1}")
    print(f"word 59:   0x{w[59]:04x}  multi-sector PIO: {'enabled, ' + str(w[59] & 0xFF) + ' sectors' if w[59] & 0x100 else 'off'} (max {w[47] & 0xFF})")

    sw = w[62]
    print(f"word 62:   0x{sw:04x}  single-word DMA supported: {bits(sw & 7, [(0, 'SWDMA0'), (1, 'SWDMA1'), (2, 'SWDMA2')])}   selected: {bits(sw >> 8 & 7, [(0, 'SWDMA0'), (1, 'SWDMA1'), (2, 'SWDMA2')])}")
    mw = w[63]
    names = [(0, "MWDMA0"), (1, "MWDMA1"), (2, "MWDMA2")]
    print(f"word 63:   0x{mw:04x}  multiword DMA supported: {bits(mw & 7, names)}   selected: {bits(mw >> 8 & 7, names)}")
    print(f"word 64:   0x{w[64]:04x}  advanced PIO modes: {bits(w[64] & 3, [(0, 'PIO3'), (1, 'PIO4')])}")
    print(f"words 65-68 (ns): MWDMA min cycle={w[65]}  MWDMA recommended={w[66]}  PIO min no-IORDY={w[67]}  PIO min IORDY={w[68]}")
    if w[53] >> 2 & 1:
        ud = w[88]
        un = [(i, f"UDMA{i}") for i in range(8)]
        print(f"word 88:   0x{ud:04x}  UDMA supported: {bits(ud & 0xFF, un)}   selected: {bits(ud >> 8, un)}")
    print(f"word 80:   0x{w[80]:04x}  ATA major version bits: {bits(w[80], [(i, f'ATA-{i}') for i in range(3, 15)])}")
    lba48 = w[100] | w[101] << 16 | w[102] << 32 | w[103] << 48
    lba28 = w[60] | w[61] << 16
    print(f"sectors:   LBA28={lba28}  LBA48={lba48}  ({(lba48 or lba28) * 512 / 1e9:.1f} GB)")
    rot = w[217]
    print(f"word 217:  {rot}  ({'non-rotating media (SSD)' if rot == 1 else 'rotation rate ' + str(rot) + ' rpm' if rot > 1024 else 'not reported'})")
    print(f"word 93:   0x{w[93]:04x}  (hardware reset result / cable id; bit 13 = 80-conductor cable reported by device)")
    print()
    print("reading: DMA bit in word 49 and MWDMA2 in word 63 mean the drive/bridge ADVERTISES multiword DMA; a bridge that")
    print("advertises it but does not implement it shows up as DMA commands timing out (what the Ultra 10 saw) while PIO works.")

main()
